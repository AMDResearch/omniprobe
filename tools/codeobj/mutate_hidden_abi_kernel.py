#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import emit_hidden_abi_metadata as metadata_emitter
import rewrite_metadata_note as note_rewriter
from plan_hidden_abi import build_kernel_plan, select_kernels


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Apply a minimal true ABI-changing hidden-ABI mutation to one kernel "
            "in a code object by extending kernarg metadata and descriptor size."
        )
    )
    parser.add_argument("input", help="Input AMDGPU ELF code object")
    parser.add_argument("manifest", help="Manifest JSON emitted by inspect_code_object.py")
    parser.add_argument("--kernel", required=True, help="Kernel name or symbol to mutate")
    parser.add_argument("--output", required=True, help="Output AMDGPU ELF code object")
    parser.add_argument("--report-output", default=None, help="Optional JSON report path")
    parser.add_argument("--pointer-size", type=int, default=8)
    parser.add_argument("--alignment", type=int, default=8)
    return parser.parse_args()


def descriptor_record_for_kernel(manifest: dict, kernel: dict) -> dict:
    wanted_names = {str(kernel.get("symbol") or ""), f"{kernel.get('name')}.kd"}
    for descriptor in manifest.get("kernels", {}).get("descriptors", []):
        if descriptor.get("name") in wanted_names or descriptor.get("kernel_name") == kernel.get("name"):
            return descriptor
    raise SystemExit(f"descriptor for kernel {kernel.get('name')!r} not found")


def patch_descriptor_kernarg_size(
    data: bytearray,
    sections: list[dict],
    descriptor: dict,
    new_kernarg_size: int,
) -> int:
    section_name = descriptor.get("section")
    section = next((entry for entry in sections if entry.get("name") == section_name), None)
    if section is None:
        raise SystemExit(f"section {section_name!r} not found for descriptor {descriptor.get('name')!r}")
    section_offset = int(descriptor.get("file_offset", 0)) - int(section.get("offset", 0))
    file_offset = int(section.get("offset", 0)) + section_offset
    struct.pack_into("<I", data, file_offset + 8, new_kernarg_size)
    return file_offset


def metadata_output_format(manifest: dict) -> str:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    if isinstance(metadata.get("object"), dict):
        return "msgpack"
    return "yaml"


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()
    report_path = Path(args.report_output).resolve() if args.report_output else None

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    kernel = select_kernels(manifest, args.kernel)[0]
    plan = build_kernel_plan(kernel, pointer_size=args.pointer_size, alignment=args.alignment)
    descriptor = descriptor_record_for_kernel(manifest, kernel)
    output_format = metadata_output_format(manifest)
    metadata_payload = metadata_emitter.build_metadata_payload_with_inplace_update(
        manifest,
        source_kernel=kernel,
        pointer_size=args.pointer_size,
        alignment=args.alignment,
        output_format=output_format,
    )
    metadata_bytes = (
        metadata_payload
        if isinstance(metadata_payload, bytes)
        else metadata_payload.encode("utf-8")
    )

    data, sections, section_map = note_rewriter.load_sections(input_path)
    data, sections, section_map = note_rewriter.replace_metadata_note(
        data,
        sections,
        section_map,
        metadata_bytes,
        allow_grow=True,
    )
    descriptor_file_offset = patch_descriptor_kernarg_size(
        data,
        sections,
        descriptor,
        plan["instrumented_kernarg_length"],
    )

    output_path.write_bytes(data)
    report = {
        "operation": "hidden-abi-inplace-mutation",
        "input_code_object": str(input_path),
        "manifest": str(manifest_path),
        "output_code_object": str(output_path),
        "kernel": kernel.get("name"),
        "symbol": kernel.get("symbol"),
        "source_kernarg_length": plan["source_kernarg_length"],
        "instrumented_kernarg_length": plan["instrumented_kernarg_length"],
        "hidden_omniprobe_ctx": plan["hidden_omniprobe_ctx"],
        "descriptor_name": descriptor.get("name"),
        "descriptor_file_offset": descriptor_file_offset,
        "metadata_format": output_format,
    }
    if report_path is not None:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
