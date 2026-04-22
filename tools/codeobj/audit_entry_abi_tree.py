#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi
from audit_entry_abi_classes import infer_arch_from_manifest
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
            "Recursively audit every *.hsaco under a tree and summarize observed "
            "entry-ABI classes plus runtime-wrapper implementation coverage."
        )
    )
    parser.add_argument("root", help="Root directory to scan for *.hsaco files")
    parser.add_argument(
        "--output",
        default=None,
        help="Optional JSON output path",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional max number of hsaco files to audit",
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
    return parser.parse_args()


def increment(counter: dict[str, int], key: str) -> None:
    counter[key] = counter.get(key, 0) + 1


def summarize(results: list[dict]) -> dict:
    class_counts: dict[str, int] = {}
    implemented_counts: dict[str, int] = {"implemented": 0, "not_implemented": 0}
    kernel_count = 0

    for code_object in results:
        for kernel in code_object.get("kernels", []):
            kernel_count += 1
            recognized_class = kernel.get("recognized_class") or "unrecognized"
            increment(class_counts, str(recognized_class))
            if kernel.get("implemented_in_runtime_wrapper"):
                implemented_counts["implemented"] += 1
            else:
                implemented_counts["not_implemented"] += 1

    return {
        "code_object_count": len(results),
        "kernel_count": kernel_count,
        "recognized_class_counts": class_counts,
        "runtime_wrapper_coverage": implemented_counts,
    }


def audit_manifest_ir(manifest: dict, ir: dict) -> dict:
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

    return {
        "input": manifest.get("input"),
        "arch": ir.get("arch") or manifest.get("arch"),
        "implemented_classes": sorted(ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES),
        "kernels": kernels,
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    readelf = detect_llvm_tool("llvm-readelf", args.llvm_readelf)
    objdump = detect_llvm_tool("llvm-objdump", args.llvm_objdump)

    hsaco_paths = sorted(root.rglob("*.hsaco"))
    if args.limit is not None:
        hsaco_paths = hsaco_paths[: max(0, args.limit)]

    results: list[dict] = []
    for path in hsaco_paths:
        manifest = build_manifest(run_readelf_json(readelf, path), path)
        arch = infer_arch_from_manifest(manifest)
        ir = transform_ir(path, run_objdump(objdump, path, arch), arch)
        audit = audit_manifest_ir(manifest, ir)
        results.append(
            {
                "path": str(path),
                "arch": audit.get("arch"),
                "kernels": audit.get("kernels", []),
            }
        )

    payload_obj = {
        "root": str(root),
        "hsaco_paths": [str(path) for path in hsaco_paths],
        "summary": summarize(results),
        "code_objects": results,
    }
    payload = json.dumps(payload_obj, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
