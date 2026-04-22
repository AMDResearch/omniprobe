#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi
from code_object_model import CodeObjectModel
from common import detect_llvm_tool
from disasm_to_ir import run_objdump, transform_ir
from inspect_code_object import build_manifest, run_readelf_json
from regenerate_code_object import (
    ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES,
    classify_entry_handoff_supported_class,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Audit every kernel in a code object or IR/manifest pair and report the "
            "recognized entry-ABI class plus current runtime-wrapper implementation status."
        )
    )
    parser.add_argument(
        "--input-code-object",
        default=None,
        help="Optional input hsaco/code object to inspect and disassemble",
    )
    parser.add_argument(
        "--input-ir",
        default=None,
        help="Optional existing instruction IR JSON to audit instead of disassembling a code object",
    )
    parser.add_argument(
        "--input-manifest",
        default=None,
        help="Manifest JSON matching --input-ir or the optional input code object",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Optional JSON output path",
    )
    parser.add_argument(
        "--llvm-readelf",
        default=None,
        help="Path to llvm-readelf; auto-detected when omitted",
    )
    parser.add_argument(
        "--llvm-objdump",
        default=None,
        help="Path to llvm-objdump; auto-detected when omitted",
    )
    parser.add_argument(
        "--arch",
        default=None,
        help="Optional AMDGPU arch override when disassembling a code object",
    )
    args = parser.parse_args()

    using_code_object = bool(args.input_code_object)
    using_ir_pair = bool(args.input_ir) or bool(args.input_manifest)

    if using_code_object == using_ir_pair:
        raise SystemExit(
            "exactly one input mode is required: either --input-code-object or "
            "the pair --input-ir/--input-manifest"
        )
    if using_ir_pair and (not args.input_ir or not args.input_manifest):
        raise SystemExit("--input-ir and --input-manifest must be provided together")
    return args


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def infer_arch_from_manifest(manifest: dict) -> str | None:
    flags = manifest.get("elf_header", {}).get("flags", [])
    marker = "EF_AMDGPU_MACH_AMDGCN_"
    for flag in flags:
        if isinstance(flag, str) and flag.startswith(marker):
            return flag[len(marker) :].lower()
    target = manifest.get("kernels", {}).get("metadata", {}).get("target")
    if isinstance(target, str) and "--" in target:
        return target.rsplit("--", 1)[-1]
    return None


def load_source_inputs(args: argparse.Namespace) -> tuple[dict, dict]:
    if args.input_code_object:
        input_path = Path(args.input_code_object).resolve()
        readelf = detect_llvm_tool("llvm-readelf", args.llvm_readelf)
        objdump = detect_llvm_tool("llvm-objdump", args.llvm_objdump)
        readelf_payload = run_readelf_json(readelf, input_path)
        manifest = build_manifest(readelf_payload, input_path)
        arch = args.arch or infer_arch_from_manifest(manifest)
        disassembly_text = run_objdump(objdump, input_path, arch)
        ir = transform_ir(input_path, disassembly_text, arch)
        return manifest, ir

    manifest = load_json(Path(args.input_manifest).resolve())
    ir = load_json(Path(args.input_ir).resolve())
    return manifest, ir


def main() -> int:
    args = parse_args()
    manifest, ir = load_source_inputs(args)
    model = CodeObjectModel.from_manifest(manifest)
    functions_by_name = {
        entry.get("name"): entry
        for entry in ir.get("functions", [])
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }

    kernels: list[dict] = []
    for kernel_name in model.primary_kernel_names():
        function = functions_by_name.get(kernel_name)
        descriptor = model.descriptor_by_kernel_name(kernel_name)
        metadata = model.metadata_by_kernel_name(kernel_name)
        if function is None:
            kernels.append(
                {
                    "kernel_name": kernel_name,
                    "present_in_ir": False,
                    "recognized_class": None,
                    "implemented_in_runtime_wrapper": False,
                    "blockers": ["function-missing-from-ir"],
                }
            )
            continue

        analysis = analyze_kernel_entry_abi(
            function=function,
            descriptor=descriptor,
            kernel_metadata=metadata,
        )
        supported_class, blockers = classify_entry_handoff_supported_class(analysis)
        kernels.append(
            {
                "kernel_name": kernel_name,
                "present_in_ir": True,
                "recognized_class": supported_class,
                "implemented_in_runtime_wrapper": (
                    supported_class in ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES
                    if supported_class is not None
                    else False
                ),
                "blockers": blockers,
                "wavefront_size": analysis.get("wavefront_size"),
                "entry_workitem_vgpr_count": analysis.get("entry_workitem_vgpr_count"),
                "workitem_pattern": (
                    (analysis.get("observed_workitem_id_materialization", {}) or {}).get("pattern_class")
                ),
                "private_pattern": (
                    (analysis.get("observed_private_segment_materialization", {}) or {}).get("pattern_class")
                ),
            }
        )

    payload_obj = {
        "input": manifest.get("input"),
        "arch": ir.get("arch") or manifest.get("arch"),
        "implemented_classes": sorted(ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES),
        "kernels": kernels,
    }
    payload = json.dumps(payload_obj, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
