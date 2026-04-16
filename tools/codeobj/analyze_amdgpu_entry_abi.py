#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze the observed AMDGPU kernel-entry ABI shape for a kernel "
            "using Omniprobe's instruction IR and descriptor facts."
        )
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument(
        "--manifest",
        default=None,
        help="Optional code-object manifest JSON for descriptor and metadata facts",
    )
    parser.add_argument(
        "--function",
        required=True,
        help="Function name to analyze",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Optional JSON output path",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def find_function(ir: dict, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"function {function_name!r} not found in IR")
    return function


def find_descriptor(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    for descriptor in descriptors:
        if descriptor.get("kernel_name") == function_name or descriptor.get("name") == f"{function_name}.kd":
            return descriptor
    return None


def find_kernel_metadata(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == function_name or kernel.get("symbol") == f"{function_name}.kd":
            return kernel
    return None


def main() -> int:
    args = parse_args()
    ir = load_json(Path(args.ir).resolve())
    manifest = load_json(Path(args.manifest).resolve()) if args.manifest else None
    function = find_function(ir, args.function)
    descriptor = find_descriptor(manifest, args.function)
    kernel_metadata = find_kernel_metadata(manifest, args.function)
    result = {
        "arch": ir.get("arch"),
        **analyze_kernel_entry_abi(
            function=function,
            descriptor=descriptor,
            kernel_metadata=kernel_metadata,
        ),
    }
    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
