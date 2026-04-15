#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from common import (
    OMNIPROBE_HIDDEN_ARG,
    align_up,
    get_hidden_abi_instrumented_name,
    get_instrumented_name,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan an Omniprobe hidden-argument clone ABI for kernels in a code-object manifest."
    )
    parser.add_argument("manifest", help="Manifest JSON emitted by inspect_code_object.py")
    parser.add_argument(
        "--kernel",
        default=None,
        help="Restrict planning to one kernel name or symbol",
    )
    parser.add_argument(
        "--pointer-size",
        type=int,
        default=8,
        help="Size in bytes of the hidden Omniprobe context pointer",
    )
    parser.add_argument(
        "--alignment",
        type=int,
        default=8,
        help="Alignment used when appending hidden_omniprobe_ctx",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON instead of a human-readable summary",
    )
    return parser.parse_args()


def compute_explicit_args_length(args: list[dict]) -> int:
    explicit_end = 0
    for arg in args:
        if arg.get("name") == OMNIPROBE_HIDDEN_ARG:
            continue
        value_kind = str(arg.get("value_kind", ""))
        if value_kind.startswith("hidden_"):
            continue
        offset = int(arg.get("offset", 0))
        size = int(arg.get("size", 0))
        explicit_end = max(explicit_end, offset + size)
    return explicit_end


def collect_hidden_args(args: list[dict]) -> list[dict]:
    hidden_args = []
    for arg in args:
        if arg.get("name") == OMNIPROBE_HIDDEN_ARG:
            hidden_args.append(
                {
                    "name": OMNIPROBE_HIDDEN_ARG,
                    "value_kind": OMNIPROBE_HIDDEN_ARG,
                    "offset": int(arg.get("offset", 0)),
                    "size": int(arg.get("size", 0)),
                }
            )
            continue
        value_kind = str(arg.get("value_kind", ""))
        if value_kind.startswith("hidden_"):
            hidden_args.append(
                {
                    "name": arg.get("name"),
                    "value_kind": value_kind,
                    "offset": int(arg.get("offset", 0)),
                    "size": int(arg.get("size", 0)),
                }
            )
    return hidden_args


def build_kernel_plan(kernel: dict, pointer_size: int, alignment: int) -> dict:
    args = kernel.get("args", [])
    kernarg_size = int(kernel.get("kernarg_segment_size", 0) or 0)
    explicit_args_length = compute_explicit_args_length(args)
    hidden_args = collect_hidden_args(args)
    hidden_end = max((arg["offset"] + arg["size"] for arg in hidden_args), default=explicit_args_length)
    source_hidden_length = max(kernarg_size - explicit_args_length, 0)

    insertion_offset = align_up(max(kernarg_size, hidden_end), alignment)
    new_kernarg_size = insertion_offset + pointer_size

    kernel_name = kernel.get("name") or kernel.get("symbol")
    if kernel_name is None:
        raise SystemExit("kernel record is missing both name and symbol")

    return {
        "kernel": kernel_name,
        "symbol": kernel.get("symbol"),
        "legacy_explicit_clone_name": get_instrumented_name(str(kernel_name)),
        "hidden_abi_clone_name": get_hidden_abi_instrumented_name(str(kernel_name)),
        "source_explicit_args_length": explicit_args_length,
        "source_hidden_args_length": source_hidden_length,
        "source_kernarg_length": kernarg_size,
        "source_hidden_args": hidden_args,
        "hidden_omniprobe_ctx": {
            "name": OMNIPROBE_HIDDEN_ARG,
            "address_space": "generic",
            "value_kind": "global_buffer",
            "offset": insertion_offset,
            "size": pointer_size,
        },
        "instrumented_kernarg_length": new_kernarg_size,
        "notes": [
            "Hidden-ABI clones should retain original hidden args and append hidden_omniprobe_ctx.",
            "If original hidden args are present, runtime must remap by metadata rather than contiguous copy.",
        ],
    }


def select_kernels(manifest: dict, kernel_filter: str | None) -> list[dict]:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    if not kernel_filter:
        return kernels
    selected = [
        kernel
        for kernel in kernels
        if kernel.get("name") == kernel_filter or kernel.get("symbol") == kernel_filter
    ]
    if not selected:
        raise SystemExit(f"kernel {kernel_filter!r} not found in manifest")
    return selected


def render_text(plans: list[dict]) -> str:
    lines: list[str] = []
    for plan in plans:
        lines.append(f"kernel: {plan['kernel']}")
        if plan.get("symbol"):
            lines.append(f"symbol: {plan['symbol']}")
        lines.append(f"legacy explicit clone: {plan['legacy_explicit_clone_name']}")
        lines.append(f"hidden ABI clone: {plan['hidden_abi_clone_name']}")
        lines.append(
            "source layout: explicit={} hidden={} kernarg={}".format(
                plan["source_explicit_args_length"],
                plan["source_hidden_args_length"],
                plan["source_kernarg_length"],
            )
        )
        hidden_ctx = plan["hidden_omniprobe_ctx"]
        lines.append(
            f"hidden_omniprobe_ctx: offset={hidden_ctx['offset']} size={hidden_ctx['size']}"
        )
        lines.append(f"instrumented kernarg length: {plan['instrumented_kernarg_length']}")
        if plan["source_hidden_args"]:
            lines.append("existing hidden args:")
            for arg in plan["source_hidden_args"]:
                lines.append(
                    "  {} offset={} size={}".format(
                        arg["value_kind"], arg["offset"], arg["size"]
                    )
                )
        else:
            lines.append("existing hidden args: none described in metadata")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    kernels = select_kernels(manifest, args.kernel)
    plans = [
        build_kernel_plan(kernel, pointer_size=args.pointer_size, alignment=args.alignment)
        for kernel in kernels
    ]

    if args.json:
        json.dump(plans, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_text(plans))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
