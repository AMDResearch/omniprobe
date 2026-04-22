#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from common import detect_llvm_tool
from disasm_to_ir import run_objdump, transform_ir
from inspect_code_object import build_manifest, run_readelf_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract a compact single-kernel entry-ABI fixture from either a real "
            "AMDGPU code object or an existing IR/manifest pair."
        )
    )
    parser.add_argument(
        "--function",
        required=True,
        help="Kernel function name to extract, for example mlk_xyz",
    )
    parser.add_argument(
        "--output-ir",
        required=True,
        help="Output path for the extracted single-function IR JSON",
    )
    parser.add_argument(
        "--output-manifest",
        required=True,
        help="Output path for the extracted single-kernel manifest JSON",
    )
    parser.add_argument(
        "--input-code-object",
        default=None,
        help="Optional input hsaco/code object to inspect and disassemble",
    )
    parser.add_argument(
        "--input-ir",
        default=None,
        help="Optional existing instruction IR JSON to slice instead of disassembling a code object",
    )
    parser.add_argument(
        "--input-manifest",
        default=None,
        help="Manifest JSON matching --input-ir or the optional input code object",
    )
    parser.add_argument(
        "--fixture-input-name",
        default=None,
        help=(
            "Optional logical path to store in manifest input/input_file instead of the "
            "original source path"
        ),
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


def load_source_inputs(args: argparse.Namespace) -> tuple[dict, dict]:
    if args.input_code_object:
        input_path = Path(args.input_code_object).resolve()
        readelf = detect_llvm_tool("llvm-readelf", args.llvm_readelf)
        objdump = detect_llvm_tool("llvm-objdump", args.llvm_objdump)
        readelf_payload = run_readelf_json(readelf, input_path)
        manifest = build_manifest(readelf_payload, input_path)
        arch = args.arch
        if arch is None:
            flags = manifest.get("elf_header", {}).get("flags", [])
            marker = "EF_AMDGPU_MACH_AMDGCN_"
            for flag in flags:
                if isinstance(flag, str) and flag.startswith(marker):
                    arch = flag[len(marker) :].lower()
                    break
        if arch is None:
            target = manifest.get("kernels", {}).get("metadata", {}).get("target")
            if isinstance(target, str) and "--" in target:
                arch = target.rsplit("--", 1)[-1]
        disassembly_text = run_objdump(objdump, input_path, arch)
        ir = transform_ir(input_path, disassembly_text, arch)
        return manifest, ir

    manifest = load_json(Path(args.input_manifest).resolve())
    ir = load_json(Path(args.input_ir).resolve())
    return manifest, ir


def extract_manifest(manifest: dict, *, function_name: str, fixture_input_name: str | None) -> dict:
    kernels = manifest.get("kernels", {})
    metadata = kernels.get("metadata", {}) if isinstance(kernels, dict) else {}

    extracted = {
        key: value
        for key, value in manifest.items()
        if key not in {"kernels", "symbols"}
    }
    extracted["input"] = fixture_input_name or manifest.get("input")
    extracted["input_file"] = fixture_input_name or manifest.get("input_file")
    extracted["kernels"] = {
        "function_symbols": [
            entry
            for entry in kernels.get("function_symbols", [])
            if isinstance(entry, dict) and entry.get("name") == function_name
        ],
        "descriptors": [
            entry
            for entry in kernels.get("descriptors", [])
            if isinstance(entry, dict)
            and (
                entry.get("kernel_name") == function_name
                or entry.get("name") == f"{function_name}.kd"
            )
        ],
        "metadata": {
            **{key: value for key, value in metadata.items() if key != "kernels"},
            "kernels": [
                entry
                for entry in metadata.get("kernels", [])
                if isinstance(entry, dict)
                and (
                    entry.get("name") == function_name
                    or entry.get("symbol") == f"{function_name}.kd"
                )
            ],
        },
    }
    return extracted


def extract_ir(ir: dict, *, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"function {function_name!r} not found in IR")
    return {
        "arch": ir.get("arch"),
        "functions": [function],
    }


def main() -> int:
    args = parse_args()
    output_ir = Path(args.output_ir).resolve()
    output_manifest = Path(args.output_manifest).resolve()

    manifest, ir = load_source_inputs(args)
    extracted_ir = extract_ir(ir, function_name=args.function)
    extracted_manifest = extract_manifest(
        manifest,
        function_name=args.function,
        fixture_input_name=args.fixture_input_name,
    )

    output_ir.write_text(json.dumps(extracted_ir, indent=2) + "\n", encoding="utf-8")
    output_manifest.write_text(
        json.dumps(extracted_manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    print(output_ir)
    print(output_manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
