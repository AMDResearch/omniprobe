#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from code_object_model import CodeObjectModel
from common import detect_llvm_tool, find_amdgpu_metadata_note
from msgpack_codec import unpackb


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect an AMDGPU ELF code object and emit a JSON manifest."
    )
    parser.add_argument("input", help="Path to an extracted AMDGPU ELF code object")
    parser.add_argument(
        "--output",
        default=None,
        help="Output JSON path; defaults to <input>.manifest.json",
    )
    parser.add_argument(
        "--llvm-readelf",
        default=None,
        help="Path to llvm-readelf; auto-detected when omitted",
    )
    return parser.parse_args()


def run_readelf_json(readelf: str, input_path: Path) -> dict:
    result = subprocess.run(
        [
            readelf,
            "--elf-output-style=JSON",
            "--file-header",
            "--section-headers",
            "--symbols",
            "--notes",
            str(input_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    if not payload:
        raise SystemExit(f"empty llvm-readelf payload for {input_path}")
    return payload[0]


def find_note_string(note_sections: list[dict], note_type_name: str) -> str | None:
    for note_section in note_sections:
        notes = note_section.get("NoteSection", {}).get("Notes", [])
        for note in notes:
            if note.get("Type", "").startswith(note_type_name):
                metadata = note.get("AMDGPU Metadata")
                if metadata is not None:
                    return metadata
                desc = note.get("Description data", {})
                if isinstance(desc, dict) and isinstance(desc.get("Bytes"), list):
                    raw = bytes(desc["Bytes"]).decode("utf-8", errors="ignore")
                    return raw.rstrip("\x00")
    return None


def flatten_flag_names(flag_block: object) -> list[str]:
    flags = flag_block.get("Flags", []) if isinstance(flag_block, dict) else flag_block
    if not isinstance(flags, list):
        return []
    flattened = []
    for flag in flags:
        if isinstance(flag, dict):
            flattened.append(flag.get("Name", ""))
        elif isinstance(flag, str):
            flattened.append(flag)
    return flattened


def name_field(value: object) -> str | None:
    if isinstance(value, dict):
        return value.get("Name")
    if isinstance(value, str):
        return value
    return None


def extract_indented_block(lines: list[str], start_index: int, parent_indent: int) -> list[str]:
    block: list[str] = []
    for line in lines[start_index:]:
        if not line.strip():
            block.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= parent_indent:
            break
        block.append(line)
    return block


def split_list_items(lines: list[str], parent_indent: int) -> list[list[str]]:
    items: list[list[str]] = []
    current: list[str] = []
    item_indent: int | None = None
    for line in lines:
        stripped = line.strip()
        if not stripped:
            if current:
                current.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if stripped.startswith("- ") and indent > parent_indent and (
            item_indent is None or indent == item_indent
        ):
            if current:
                items.append(current)
            current = [line]
            item_indent = indent
            continue
        if current and item_indent is not None and indent >= item_indent:
            current.append(line)
    if current:
        items.append(current)
    return items


def parse_scalar_field(block: str, name: str) -> int | str | None:
    match = re.search(rf"^\s*(?:-\s+)?\.{re.escape(name)}:\s+(.+)$", block, flags=re.MULTILINE)
    if not match:
        return None
    value = match.group(1).strip()
    if re.fullmatch(r"\d+", value):
        return int(value)
    return value


def parse_kernel_args(block_lines: list[str]) -> list[dict]:
    block_text = "\n".join(block_lines)
    args_match = re.search(r"^(\s*)(?:-\s+)?\.args:\s*$", block_text, flags=re.MULTILINE)
    if not args_match:
        return []

    args_indent = len(args_match.group(1))
    args_line_index = next(
        index
        for index, line in enumerate(block_lines)
        if line.strip() in {".args:", "- .args:"}
    )
    args_block_lines = extract_indented_block(block_lines, args_line_index + 1, args_indent)
    args: list[dict] = []
    for item in split_list_items(args_block_lines, args_indent):
        item_text = "\n".join(item)
        arg = {
            "name": parse_scalar_field(item_text, "name"),
            "size": parse_scalar_field(item_text, "size"),
            "offset": parse_scalar_field(item_text, "offset"),
            "value_kind": parse_scalar_field(item_text, "value_kind"),
            "address_space": parse_scalar_field(item_text, "address_space"),
            "type_name": parse_scalar_field(item_text, "type_name"),
        }
        normalized = {key: value for key, value in arg.items() if value is not None}
        if normalized:
            args.append(normalized)
    return args


def parse_amdgpu_metadata(raw_metadata: str | None) -> dict:
    if not raw_metadata:
        return {}

    metadata: dict[str, object] = {"raw": raw_metadata}
    target_match = re.search(r"^amdhsa\.target:\s+(.+)$", raw_metadata, flags=re.MULTILINE)
    if target_match:
        metadata["target"] = target_match.group(1).strip()

    lines = raw_metadata.splitlines()
    kernels_header_index = None
    kernels_header_indent = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "amdhsa.kernels:":
            kernels_header_index = index
            kernels_header_indent = len(line) - len(line.lstrip(" "))
            break

    kernels: list[dict] = []
    if kernels_header_index is not None:
        kernel_lines = extract_indented_block(lines, kernels_header_index + 1, kernels_header_indent)
        kernel_items = split_list_items(kernel_lines, kernels_header_indent)
    else:
        kernel_items = []

    for block_lines in kernel_items:
        block = "\n".join(block_lines).rstrip()
        kernel = {
            "name": parse_scalar_field(block, "name"),
            "symbol": parse_scalar_field(block, "symbol"),
            "sgpr_count": parse_scalar_field(block, "sgpr_count"),
            "vgpr_count": parse_scalar_field(block, "vgpr_count"),
            "kernarg_segment_size": parse_scalar_field(block, "kernarg_segment_size"),
            "wavefront_size": parse_scalar_field(block, "wavefront_size"),
            "max_flat_workgroup_size": parse_scalar_field(block, "max_flat_workgroup_size"),
            "group_segment_fixed_size": parse_scalar_field(block, "group_segment_fixed_size"),
            "private_segment_fixed_size": parse_scalar_field(block, "private_segment_fixed_size"),
            "args": parse_kernel_args(block_lines),
        }
        kernels.append({key: value for key, value in kernel.items() if value is not None})

    metadata["kernels"] = kernels
    return metadata


def parse_amdgpu_metadata_object(metadata_obj: object) -> dict:
    if not isinstance(metadata_obj, dict):
        return {}

    metadata: dict[str, object] = {"object": metadata_obj}
    target = metadata_obj.get("amdhsa.target")
    if isinstance(target, str):
        metadata["target"] = target

    kernels = metadata_obj.get("amdhsa.kernels")
    normalized_kernels: list[dict] = []
    if isinstance(kernels, list):
        for kernel in kernels:
            if not isinstance(kernel, dict):
                continue
            args = kernel.get(".args", [])
            normalized_kernels.append(
                {
                    "name": kernel.get(".name"),
                    "symbol": kernel.get(".symbol"),
                    "sgpr_count": kernel.get(".sgpr_count"),
                    "vgpr_count": kernel.get(".vgpr_count"),
                    "kernarg_segment_size": kernel.get(".kernarg_segment_size"),
                    "wavefront_size": kernel.get(".wavefront_size"),
                    "max_flat_workgroup_size": kernel.get(".max_flat_workgroup_size"),
                    "group_segment_fixed_size": kernel.get(".group_segment_fixed_size"),
                    "private_segment_fixed_size": kernel.get(".private_segment_fixed_size"),
                    "args": [
                        {
                            "name": arg.get(".name"),
                            "size": arg.get(".size"),
                            "offset": arg.get(".offset"),
                            "value_kind": arg.get(".value_kind"),
                            "address_space": arg.get(".address_space"),
                            "type_name": arg.get(".type_name"),
                        }
                        for arg in args
                        if isinstance(arg, dict)
                    ],
                }
            )
    metadata["kernels"] = normalized_kernels
    return metadata


def decode_bits(value: int, shift: int, width: int = 1) -> int:
    return (value >> shift) & ((1 << width) - 1)


def section_records(payload: dict) -> list[dict]:
    return payload.get("Sections", []) or payload.get("SectionHeaders", []) or []


def symbol_records(payload: dict) -> list[dict]:
    return payload.get("Symbols", []) or []


def normalize_sections(payload: dict) -> list[dict]:
    records: list[dict] = []
    for raw_section in section_records(payload):
        section = raw_section.get("Section") or raw_section
        records.append(
            {
                "index": section.get("Index"),
                "name": name_field(section.get("Name")),
                "type": name_field(section.get("Type")),
                "address": int(section.get("Address", 0)),
                "offset": int(section.get("Offset", 0)),
                "size": int(section.get("Size", 0)),
                "alignment": int(section.get("AddressAlignment", 0) or 0),
                "flags": flatten_flag_names(section.get("Flags", [])),
            }
        )
    return records


def normalize_symbols(payload: dict) -> list[dict]:
    records: list[dict] = []
    for raw_symbol in symbol_records(payload):
        symbol = raw_symbol.get("Symbol") or raw_symbol
        section = symbol.get("Section", {})
        section_name = name_field(section) if isinstance(section, dict) else section
        records.append(
            {
                "name": name_field(symbol.get("Name")),
                "value": int(symbol.get("Value", 0)),
                "size": int(symbol.get("Size", 0)),
                "binding": name_field(symbol.get("Binding")),
                "type": name_field(symbol.get("Type")),
                "visibility": flatten_flag_names(symbol.get("Other", {})),
                "section": section_name,
            }
        )
    return [record for record in records if record.get("name")]


def read_symbol_bytes(input_path: Path, sections: list[dict], symbol: dict) -> tuple[int, bytes]:
    section_name = symbol.get("section")
    section = next((entry for entry in sections if entry["name"] == section_name), None)
    if section is None:
        raise SystemExit(f"section {section_name!r} not found for symbol {symbol['name']}")

    symbol_value = int(symbol.get("value", 0))
    symbol_size = int(symbol.get("size", 0))
    section_address = int(section.get("address", 0))
    section_offset = int(section.get("offset", 0))
    within_section = symbol_value - section_address
    if within_section < 0 or within_section + symbol_size > int(section.get("size", 0)):
        raise SystemExit(f"symbol {symbol['name']} does not fit inside section {section_name}")

    file_offset = section_offset + within_section
    file_bytes = input_path.read_bytes()
    return file_offset, file_bytes[file_offset : file_offset + symbol_size]


def read_section_bytes(input_path: Path, section: dict) -> tuple[int, bytes]:
    if section.get("type") == "SHT_NOBITS":
        return int(section.get("offset", 0)), b""

    file_offset = int(section.get("offset", 0))
    section_size = int(section.get("size", 0))
    file_bytes = input_path.read_bytes()
    return file_offset, file_bytes[file_offset : file_offset + section_size]


def decode_kernel_descriptor(symbol: dict, file_offset: int, data: bytes) -> dict:
    if len(data) != 64:
        raise SystemExit(
            f"kernel descriptor {symbol['name']} has unexpected size {len(data)} (expected 64)"
        )

    compute_pgm_rsrc3 = int.from_bytes(data[44:48], byteorder="little")
    compute_pgm_rsrc1 = int.from_bytes(data[48:52], byteorder="little")
    compute_pgm_rsrc2 = int.from_bytes(data[52:56], byteorder="little")
    kernel_code_properties = int.from_bytes(data[56:60], byteorder="little")

    return {
        "name": symbol["name"],
        "kernel_name": symbol["name"][:-3] if symbol["name"].endswith(".kd") else symbol["name"],
        "section": symbol.get("section"),
        "size": len(data),
        "file_offset": file_offset,
        "bytes_hex": data.hex(),
        "group_segment_fixed_size": int.from_bytes(data[0:4], byteorder="little"),
        "private_segment_fixed_size": int.from_bytes(data[4:8], byteorder="little"),
        "kernarg_size": int.from_bytes(data[8:12], byteorder="little"),
        "kernel_code_entry_byte_offset": int.from_bytes(
            data[16:24], byteorder="little", signed=True
        ),
        "compute_pgm_rsrc3": {
            "raw_value": compute_pgm_rsrc3,
            "shared_vgpr_count": decode_bits(compute_pgm_rsrc3, 0, 4),
            "inst_pref_size": decode_bits(compute_pgm_rsrc3, 4, 6),
            "trap_on_start": decode_bits(compute_pgm_rsrc3, 10),
            "trap_on_end": decode_bits(compute_pgm_rsrc3, 11),
            "image_op": decode_bits(compute_pgm_rsrc3, 31),
        },
        "compute_pgm_rsrc1": {
            "raw_value": compute_pgm_rsrc1,
            "granulated_workitem_vgpr_count": decode_bits(compute_pgm_rsrc1, 0, 6),
            "granulated_wavefront_sgpr_count": decode_bits(compute_pgm_rsrc1, 6, 4),
            "priority": decode_bits(compute_pgm_rsrc1, 10, 2),
            "float_round_mode_32": decode_bits(compute_pgm_rsrc1, 12, 2),
            "float_round_mode_16_64": decode_bits(compute_pgm_rsrc1, 14, 2),
            "float_denorm_mode_32": decode_bits(compute_pgm_rsrc1, 16, 2),
            "float_denorm_mode_16_64": decode_bits(compute_pgm_rsrc1, 18, 2),
            "enable_dx10_clamp": decode_bits(compute_pgm_rsrc1, 21),
            "enable_ieee_mode": decode_bits(compute_pgm_rsrc1, 23),
            "fp16_overflow": decode_bits(compute_pgm_rsrc1, 26),
            "workgroup_processor_mode": decode_bits(compute_pgm_rsrc1, 29),
            "memory_ordered": decode_bits(compute_pgm_rsrc1, 30),
            "forward_progress": decode_bits(compute_pgm_rsrc1, 31),
        },
        "compute_pgm_rsrc2": {
            "raw_value": compute_pgm_rsrc2,
            "enable_private_segment": decode_bits(compute_pgm_rsrc2, 0),
            "user_sgpr_count": decode_bits(compute_pgm_rsrc2, 1, 5),
            "enable_trap_handler_or_dynamic_vgpr": decode_bits(compute_pgm_rsrc2, 6),
            "enable_sgpr_workgroup_id_x": decode_bits(compute_pgm_rsrc2, 7),
            "enable_sgpr_workgroup_id_y": decode_bits(compute_pgm_rsrc2, 8),
            "enable_sgpr_workgroup_id_z": decode_bits(compute_pgm_rsrc2, 9),
            "enable_sgpr_workgroup_info": decode_bits(compute_pgm_rsrc2, 10),
            "enable_vgpr_workitem_id": decode_bits(compute_pgm_rsrc2, 11, 2),
            "exception_fp_ieee_invalid_op": decode_bits(compute_pgm_rsrc2, 24),
            "exception_fp_denorm_src": decode_bits(compute_pgm_rsrc2, 25),
            "exception_fp_ieee_div_zero": decode_bits(compute_pgm_rsrc2, 26),
            "exception_fp_ieee_overflow": decode_bits(compute_pgm_rsrc2, 27),
            "exception_fp_ieee_underflow": decode_bits(compute_pgm_rsrc2, 28),
            "exception_fp_ieee_inexact": decode_bits(compute_pgm_rsrc2, 29),
            "exception_int_div_zero": decode_bits(compute_pgm_rsrc2, 30),
        },
        "kernel_code_properties": {
            "raw_value": kernel_code_properties,
            "enable_sgpr_private_segment_buffer": decode_bits(kernel_code_properties, 0),
            "enable_sgpr_dispatch_ptr": decode_bits(kernel_code_properties, 1),
            "enable_sgpr_queue_ptr": decode_bits(kernel_code_properties, 2),
            "enable_sgpr_kernarg_segment_ptr": decode_bits(kernel_code_properties, 3),
            "enable_sgpr_dispatch_id": decode_bits(kernel_code_properties, 4),
            "enable_sgpr_flat_scratch_init": decode_bits(kernel_code_properties, 5),
            "enable_sgpr_private_segment_size": decode_bits(kernel_code_properties, 6),
            "enable_wavefront_size32": decode_bits(kernel_code_properties, 10),
            "uses_dynamic_stack": decode_bits(kernel_code_properties, 11),
            "kernarg_preload_spec_length": decode_bits(kernel_code_properties, 16, 7),
            "kernarg_preload_spec_offset": decode_bits(kernel_code_properties, 23, 9),
        },
    }


def build_manifest(payload: dict, input_path: Path) -> dict:
    notes = payload.get("Notes", []) or payload.get("NoteSections", []) or []
    rendered_metadata = find_note_string(notes, "NT_AMDGPU_METADATA")
    exact_note = find_amdgpu_metadata_note(input_path)
    exact_metadata = None
    note_encoding = None
    parsed_object = None
    if exact_note is not None:
        try:
            parsed_object = unpackb(exact_note["desc_bytes"])
            note_encoding = "msgpack"
        except Exception:
            exact_metadata = exact_note["desc_bytes"].decode("utf-8", errors="ignore").rstrip("\x00")
            note_encoding = "utf8-text"

    if parsed_object is not None:
        parsed_metadata = parse_amdgpu_metadata_object(parsed_object)
        if rendered_metadata:
            parsed_metadata["rendered"] = rendered_metadata
    else:
        raw_metadata = exact_metadata or rendered_metadata
        parsed_metadata = parse_amdgpu_metadata(raw_metadata or rendered_metadata)

    file_summary = payload.get("FileSummary", {}) or {}
    elf_header = payload.get("ElfHeader", {}) or payload.get("FileSummary", {}) or {}
    sections = normalize_sections(payload)
    symbols = normalize_symbols(payload)

    all_function_symbols = [
        symbol for symbol in symbols if symbol["type"] == "Function" and symbol["section"] == ".text"
    ]
    descriptor_symbols = [symbol for symbol in symbols if symbol["name"].endswith(".kd")]
    descriptor_records = []
    for symbol in descriptor_symbols:
        file_offset, descriptor_bytes = read_symbol_bytes(input_path, sections, symbol)
        descriptor_records.append(decode_kernel_descriptor(symbol, file_offset, descriptor_bytes))

    kernel_names = {
        kernel.get("name")
        for kernel in parsed_metadata.get("kernels", [])
        if kernel.get("name")
    }
    kernel_names.update(
        descriptor.get("kernel_name")
        for descriptor in descriptor_records
        if descriptor.get("kernel_name")
    )
    kernel_symbols = [symbol for symbol in all_function_symbols if symbol["name"] in kernel_names]
    helper_function_symbols = [
        symbol for symbol in all_function_symbols if symbol["name"] not in kernel_names
    ]

    for symbol in symbols:
        section = next((entry for entry in sections if entry["name"] == symbol["section"]), None)
        if section is None:
            symbol["section_offset"] = None
            continue
        symbol["section_offset"] = int(symbol["value"]) - int(section["address"])

    support_sections = []
    for section in sections:
        if section["name"] not in {".data", ".bss", ".rodata"}:
            continue
        section_file_offset, section_bytes = read_section_bytes(input_path, section)
        symbols_in_section = [
            symbol
            for symbol in symbols
            if symbol["section"] == section["name"] and symbol["type"] == "Object" and symbol["name"]
        ]
        support_sections.append(
            {
                "name": section["name"],
                "type": section["type"],
                "flags": section["flags"],
                "size": int(section["size"]),
                "alignment": int(section.get("alignment", 1) or 1),
                "address": int(section["address"]),
                "offset": int(section["offset"]),
                "file_offset": section_file_offset,
                "bytes_hex": section_bytes.hex(),
                "symbols": symbols_in_section,
            }
        )

    manifest = {
        "input": str(input_path),
        "input_file": str(input_path),
        "file_size": os.path.getsize(input_path),
        "format": file_summary.get("Format"),
        "arch": file_summary.get("Arch"),
        "address_size": file_summary.get("AddressSize"),
        "elf_header": {
            "class": elf_header.get("Class"),
            "type": name_field(elf_header.get("Type")) or elf_header.get("Type"),
            "machine": name_field(elf_header.get("Machine")) or elf_header.get("Machine"),
            "os_abi": name_field(elf_header.get("Ident", {}).get("OS/ABI", {})),
            "abi_version": elf_header.get("Ident", {}).get("ABIVersion"),
            "flags": flatten_flag_names(elf_header.get("Flags", [])),
            "section_count": int(elf_header.get("SectionHeaderCount", 0) or 0),
            "program_header_count": elf_header.get("ProgramHeaderCount"),
        },
        "sections": sections,
        "symbols": symbols,
        "functions": {
            "all_symbols": all_function_symbols,
            "helper_symbols": helper_function_symbols,
        },
        "support_sections": support_sections,
        "kernels": {
            "function_symbols": kernel_symbols,
            "descriptor_symbols": descriptor_symbols,
            "descriptors": descriptor_records,
            "metadata": parsed_metadata,
        },
    }
    if exact_note is not None:
        manifest["kernels"]["metadata_note"] = {
            "type": exact_note["type"],
            "encoding": note_encoding or "unknown",
            "section_name": exact_note["section_name"],
            "section_offset": exact_note["section_offset"],
            "section_size": exact_note["section_size"],
            "note_offset_in_section": exact_note["note_offset_in_section"],
            "note_size": exact_note["note_size"],
            "desc_size": len(exact_note["desc_bytes"]),
            "payload_utf8": exact_metadata,
            "payload_base64": base64.b64encode(exact_note["desc_bytes"]).decode("ascii"),
            "rendered_text_matches_exact": bool(rendered_metadata and exact_metadata == rendered_metadata),
        }
    return CodeObjectModel.from_manifest(manifest).to_manifest()


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_path = (
        Path(args.output).resolve()
        if args.output
        else input_path.with_suffix(input_path.suffix + ".manifest.json")
    )

    readelf = detect_llvm_tool("llvm-readelf", args.llvm_readelf)
    payload = run_readelf_json(readelf, input_path)
    manifest = build_manifest(payload, input_path)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        dir=str(output_path.parent),
    )
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        temp_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        temp_path.replace(output_path)
    finally:
        if temp_path.exists():
            temp_path.unlink()
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
