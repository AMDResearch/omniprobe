#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from code_object_model import CodeObjectModel
from common import detect_llvm_tool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Rebuild an AMDGPU code object from instruction-level IR and a manifest "
            "under an explicit Omniprobe rebuild mode."
        )
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument("manifest", help="Code-object manifest JSON")
    parser.add_argument("--output", required=True, help="Output code-object path")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("exact", "abi-preserving", "abi-changing"),
        help="Rebuild mode contract to enforce",
    )
    parser.add_argument(
        "--function",
        default=None,
        help="Optional kernel function to target when multiple kernels exist",
    )
    parser.add_argument(
        "--original-ir",
        default=None,
        help="Required for abi-preserving mode; original IR JSON used for descriptor-safety analysis",
    )
    parser.add_argument(
        "--asm-output",
        default=None,
        help="Optional assembly output path; defaults to <output>.s",
    )
    parser.add_argument(
        "--object-output",
        default=None,
        help="Optional object-file output path; defaults to <output>.o",
    )
    parser.add_argument(
        "--report-output",
        default=None,
        help="Optional JSON report path describing the chosen rebuild policy",
    )
    parser.add_argument(
        "--preserve-descriptor-bytes",
        action="store_true",
        help=(
            "Override the default descriptor policy and emit raw descriptor bytes "
            "from the manifest even in modes that would normally regenerate them"
        ),
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python interpreter to use for helper tools",
    )
    parser.add_argument(
        "--llvm-mc",
        default=None,
        help="Path to llvm-mc; auto-detected when omitted",
    )
    parser.add_argument(
        "--ld-lld",
        default=None,
        help="Path to ld.lld; auto-detected when omitted",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def function_name_for_mode(manifest: dict, explicit_name: str | None) -> str | None:
    if explicit_name:
        return explicit_name
    model = CodeObjectModel.from_manifest(manifest)
    primary_kernels = model.primary_kernel_names()
    if len(primary_kernels) == 1:
        return primary_kernels[0]
    kernel_names = model.kernel_names()
    return kernel_names[0] if len(kernel_names) == 1 else None


def run_json_command(command: list[str]) -> dict:
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def main() -> int:
    args = parse_args()
    ir_path = Path(args.ir).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()
    asm_path = (
        Path(args.asm_output).resolve()
        if args.asm_output
        else output_path.with_suffix(output_path.suffix + ".s")
    )
    obj_path = (
        Path(args.object_output).resolve()
        if args.object_output
        else output_path.with_suffix(output_path.suffix + ".o")
    )
    report_path = Path(args.report_output).resolve() if args.report_output else None

    manifest = load_json(manifest_path)
    ir = load_json(ir_path)
    arch = ir.get("arch")
    if not arch:
        raise SystemExit("IR does not contain an 'arch' field")

    tool_dir = Path(__file__).resolve().parent
    emit_tool = tool_dir / "emit_amdhsa_asm.py"
    safety_tool = tool_dir / "analyze_descriptor_safety.py"
    llvm_mc = detect_llvm_tool("llvm-mc", args.llvm_mc)
    ld_lld = detect_llvm_tool("ld.lld", args.ld_lld)

    function_name = function_name_for_mode(manifest, args.function)
    descriptor_policy = "regenerate"
    exact_encoding = True
    preserve_descriptor_bytes = False
    descriptor_safety_report: dict | None = None

    if args.mode == "exact":
        preserve_descriptor_bytes = True
        descriptor_policy = "preserve-original-bytes"
    elif args.mode == "abi-preserving":
        if not args.original_ir:
            raise SystemExit("--original-ir is required for abi-preserving mode")
        if not function_name:
            raise SystemExit(
                "--function is required for abi-preserving mode when multiple kernels exist"
            )
        descriptor_safety_report = run_json_command(
            [
                args.python,
                str(safety_tool),
                str(Path(args.original_ir).resolve()),
                str(ir_path),
                str(manifest_path),
                "--function",
                function_name,
                "--json",
            ]
        )
        if not descriptor_safety_report.get("likely_safe_to_preserve_descriptor_bytes", False):
            hazard_summary = "; ".join(descriptor_safety_report.get("hazards", []))
            raise SystemExit(
                "abi-preserving mode rejected this edit because descriptor safety "
                f"could not be proven: {hazard_summary or 'unknown hazard'}"
            )
        preserve_descriptor_bytes = True
        descriptor_policy = "preserve-original-bytes-after-safety-check"
    elif args.mode == "abi-changing":
        descriptor_policy = "regenerate"
    else:
        raise SystemExit(f"unsupported mode {args.mode!r}")

    if args.preserve_descriptor_bytes:
        preserve_descriptor_bytes = True
        descriptor_policy = "preserve-original-bytes-override"

    emit_command = [
        args.python,
        str(emit_tool),
        str(ir_path),
        str(manifest_path),
        "--output",
        str(asm_path),
    ]
    if exact_encoding:
        emit_command.append("--exact-encoding")
    if preserve_descriptor_bytes:
        emit_command.append("--preserve-descriptor-bytes")
    subprocess.run(emit_command, check=True)

    subprocess.run(
        [
            llvm_mc,
            "-triple=amdgcn-amd-amdhsa",
            f"-mcpu={arch}",
            "-filetype=obj",
            "-o",
            str(obj_path),
            str(asm_path),
        ],
        check=True,
    )
    subprocess.run(
        [
            ld_lld,
            "-shared",
            "-o",
            str(output_path),
            str(obj_path),
        ],
        check=True,
    )

    report = {
        "mode": args.mode,
        "function": function_name,
        "input_ir": str(ir_path),
        "input_manifest": str(manifest_path),
        "output_code_object": str(output_path),
        "output_asm": str(asm_path),
        "output_object": str(obj_path),
        "exact_encoding": exact_encoding,
        "preserve_descriptor_bytes": preserve_descriptor_bytes,
        "descriptor_policy": descriptor_policy,
        "descriptor_safety_report": descriptor_safety_report,
        "arch": arch,
    }
    if report_path is not None:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
