#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from copy import deepcopy
from pathlib import Path

from common import OMNIPROBE_HIDDEN_ARG
from msgpack_codec import packb
import rewrite_metadata_note as note_rewriter


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Reclassify one existing kernel argument as hidden_omniprobe_ctx "
            "without changing its offset or the kernel descriptor size."
        )
    )
    parser.add_argument("input", help="Input AMDGPU ELF code object")
    parser.add_argument("manifest", help="Manifest JSON emitted by inspect_code_object.py")
    parser.add_argument("--kernel", required=True, help="Kernel name or symbol to mutate")
    parser.add_argument(
        "--arg-offset",
        type=int,
        default=None,
        help="Explicit byte offset of the argument to reclassify",
    )
    parser.add_argument("--output", required=True, help="Output AMDGPU ELF code object")
    parser.add_argument("--report-output", default=None, help="Optional JSON report path")
    parser.add_argument(
        "--keep-value-kind",
        action="store_true",
        help="Keep the original .value_kind instead of rewriting it to hidden_omniprobe_ctx",
    )
    return parser.parse_args()


def kernel_identity_matches(kernel: dict, needle: str) -> bool:
    return kernel.get("name") == needle or kernel.get("symbol") == needle


def select_kernel(manifest: dict, needle: str) -> dict:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if isinstance(kernel, dict) and kernel_identity_matches(kernel, needle):
            return kernel
    raise SystemExit(f"kernel {needle!r} not found in manifest metadata")


def find_kernel_object(metadata_obj: dict, kernel: dict) -> dict:
    for kernel_obj in metadata_obj.get("amdhsa.kernels", []):
        if not isinstance(kernel_obj, dict):
            continue
        if (
            kernel_obj.get(".name") == kernel.get("name")
            and kernel_obj.get(".symbol") == kernel.get("symbol")
        ):
            return kernel_obj
    raise SystemExit(
        f"exact metadata object for kernel {(kernel.get('name'), kernel.get('symbol'))!r} not found"
    )


def is_hidden_arg(arg: dict) -> bool:
    name = str(arg.get(".name", ""))
    value_kind = str(arg.get(".value_kind", ""))
    return name == OMNIPROBE_HIDDEN_ARG or value_kind.startswith("hidden_")


def choose_target_arg(args: list[dict], explicit_offset: int | None) -> dict:
    if explicit_offset is not None:
        for arg in args:
            if int(arg.get(".offset", -1)) == explicit_offset:
                return arg
        raise SystemExit(f"kernel metadata does not contain an argument at offset {explicit_offset}")

    explicit_args = [arg for arg in args if isinstance(arg, dict) and not is_hidden_arg(arg)]
    if not explicit_args:
        raise SystemExit("kernel metadata does not contain any explicit arguments to reclassify")

    pointer_sized = [arg for arg in explicit_args if int(arg.get(".size", 0)) == 8]
    if pointer_sized:
        return max(pointer_sized, key=lambda arg: int(arg.get(".offset", 0)))
    return max(explicit_args, key=lambda arg: int(arg.get(".offset", 0)))


def rewrite_metadata_object(
    manifest: dict,
    kernel: dict,
    arg_offset: int | None,
    keep_value_kind: bool,
) -> tuple[dict, dict]:
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    if not isinstance(metadata_obj, dict):
        raise SystemExit("manifest does not contain an exact metadata object")

    result = deepcopy(metadata_obj)
    kernel_obj = find_kernel_object(result, kernel)
    args = kernel_obj.get(".args")
    if not isinstance(args, list):
        raise SystemExit("kernel metadata is missing .args")

    target_arg = choose_target_arg(args, arg_offset)
    target_arg[".name"] = OMNIPROBE_HIDDEN_ARG
    if not keep_value_kind:
        target_arg[".value_kind"] = OMNIPROBE_HIDDEN_ARG

    return result, {
        "offset": int(target_arg.get(".offset", 0)),
        "size": int(target_arg.get(".size", 0)),
        "value_kind": str(target_arg.get(".value_kind", "")),
    }


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()
    report_path = Path(args.report_output).resolve() if args.report_output else None

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    kernel = select_kernel(manifest, args.kernel)
    metadata_obj, hidden_arg = rewrite_metadata_object(
        manifest,
        kernel,
        args.arg_offset,
        args.keep_value_kind,
    )
    metadata_bytes = packb(metadata_obj)

    data, sections, section_map = note_rewriter.load_sections(input_path)
    data, sections, section_map = note_rewriter.replace_metadata_note(
        data,
        sections,
        section_map,
        metadata_bytes,
        allow_grow=True,
    )
    output_path.write_bytes(data)

    report = {
        "operation": "reclassify-kernel-arg-as-hidden",
        "input_code_object": str(input_path),
        "manifest": str(manifest_path),
        "output_code_object": str(output_path),
        "kernel": kernel.get("name"),
        "symbol": kernel.get("symbol"),
        "hidden_omniprobe_ctx": hidden_arg,
        "kernarg_segment_size": kernel.get("kernarg_segment_size"),
    }
    if report_path is not None:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
