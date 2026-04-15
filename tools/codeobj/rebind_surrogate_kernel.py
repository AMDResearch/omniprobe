#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import emit_hidden_abi_metadata as metadata_emitter
from common import get_hidden_abi_instrumented_name
from plan_hidden_abi import build_kernel_plan, select_kernels
import rewrite_metadata_note as note_rewriter


ELF64_SYM_FORMAT = "<IBBHQQ"
DT_STRTAB = 5
DT_STRSZ = 10


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rebind an existing donor kernel slot as an Omniprobe hidden-ABI surrogate clone."
    )
    parser.add_argument("input", help="Input AMDGPU ELF code object")
    parser.add_argument("manifest", help="Manifest JSON emitted by inspect_code_object.py")
    parser.add_argument("--source-kernel", required=True, help="Kernel to clone logically")
    parser.add_argument(
        "--donor-kernel",
        required=True,
        help="Existing kernel slot to repurpose as the surrogate clone",
    )
    parser.add_argument("--output", required=True, help="Output ELF path")
    parser.add_argument(
        "--report-output",
        default=None,
        help="Optional JSON report path describing the abi-changing surrogate rewrite",
    )
    parser.add_argument("--pointer-size", type=int, default=8)
    parser.add_argument("--alignment", type=int, default=8)
    return parser.parse_args()


def dyn_symbols(manifest: dict) -> list[dict]:
    return manifest.get("symbols", [])


def kernel_symbol_map(manifest: dict) -> dict[str, dict]:
    return {symbol["name"]: symbol for symbol in dyn_symbols(manifest)}


def read_dynstr(data: bytearray, section_map: dict[str, dict]) -> tuple[dict, bytes]:
    section = section_map[".dynstr"]
    start = section["offset"]
    end = start + section["size"]
    return section, bytes(data[start:end])


def read_strtab(data: bytearray, section_map: dict[str, dict]) -> tuple[dict, bytes]:
    section = section_map[".strtab"]
    start = section["offset"]
    end = start + section["size"]
    return section, bytes(data[start:end])


def write_u32(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def write_u64(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<Q", data, offset, value)


def grow_dynstr_capacity(
    data: bytearray,
    sections: list[dict],
    section_map: dict[str, dict],
    required_size: int,
) -> int:
    dynstr = section_map[".dynstr"]
    start = dynstr["offset"]
    old_size = dynstr["size"]
    next_offsets = [
        section["offset"]
        for section in sections
        if section["offset"] > dynstr["offset"] and section["type"] != 8
    ]
    next_offset = min(next_offsets) if next_offsets else len(data)
    capacity = next_offset - start
    growth_needed = required_size - capacity
    if growth_needed <= 0:
        return capacity

    shift_amount = note_rewriter.choose_growth_shift(sections, next_offset, growth_needed)
    header_fields = note_rewriter.parse_elf_header(data)
    programs = note_rewriter.load_program_headers(data)
    next_alloc_addr = min(
        (
            section["addr"]
            for section in sections
            if (section["flags"] & note_rewriter.SHF_ALLOC) and section["offset"] >= next_offset
        ),
        default=None,
    )
    moved_alloc_section_indices = {
        section["index"]
        for section in sections
        if next_alloc_addr is not None
        and (section["flags"] & note_rewriter.SHF_ALLOC)
        and section["addr"] >= next_alloc_addr
    }

    data[next_offset:next_offset] = b"\x00" * shift_amount

    if header_fields[5] >= next_offset:
        header_fields[5] += shift_amount
    if header_fields[6] >= next_offset:
        header_fields[6] += shift_amount
    note_rewriter.write_elf_header(data, header_fields)

    for program in programs:
        file_end = program["offset"] + program["filesz"]
        mem_end = program["vaddr"] + program["memsz"]
        if program["header_offset"] >= next_offset:
            program["header_offset"] += shift_amount
        if program["offset"] > next_offset:
            program["offset"] += shift_amount
            if next_alloc_addr is not None and program["vaddr"] >= next_alloc_addr:
                program["vaddr"] += shift_amount
                program["paddr"] += shift_amount
        elif program["offset"] <= next_offset < file_end:
            program["filesz"] += shift_amount
            if next_alloc_addr is None:
                if program["type"] == note_rewriter.PT_LOAD:
                    program["memsz"] += shift_amount
            elif program["vaddr"] <= next_alloc_addr < mem_end:
                program["memsz"] += shift_amount
        note_rewriter.write_program_header(data, program)

    for section in sections:
        if section["header_offset"] >= next_offset:
            section["header_offset"] += shift_amount
        if section is not dynstr and section["offset"] >= next_offset:
            section["offset"] += shift_amount
        if (
            next_alloc_addr is not None
            and (section["flags"] & note_rewriter.SHF_ALLOC)
            and section["index"] in moved_alloc_section_indices
        ):
            section["addr"] += shift_amount

    note_rewriter.shift_symbol_table_values(
        data,
        section_map.get(".dynsym"),
        moved_alloc_section_indices,
        shift_amount,
    )
    note_rewriter.shift_symbol_table_values(
        data,
        section_map.get(".symtab"),
        moved_alloc_section_indices,
        shift_amount,
    )
    if next_alloc_addr is not None:
        note_rewriter.shift_dynamic_pointer_values(
            data,
            section_map.get(".dynamic"),
            shift_amount,
            next_alloc_addr,
        )

    for section in sections:
        note_rewriter.write_section_header(data, section)

    return capacity + shift_amount


def append_dynstr_strings(
    data: bytearray,
    sections: list[dict],
    section_map: dict[str, dict],
    strings: list[bytes],
) -> dict[bytes, int]:
    dynstr = section_map[".dynstr"]
    start = dynstr["offset"]
    old_size = dynstr["size"]
    end = start + old_size
    new_blob = bytearray(data[start:end])
    offsets: dict[bytes, int] = {}
    for string in strings:
        if string in new_blob:
            offsets[string] = new_blob.index(string)
            continue
        offsets[string] = len(new_blob)
        new_blob.extend(string)
    capacity = grow_dynstr_capacity(data, sections, section_map, len(new_blob))

    data[start : start + len(new_blob)] = new_blob
    data[start + len(new_blob) : start + capacity] = b"\x00" * (capacity - len(new_blob))
    dynstr["size"] = len(new_blob)
    struct.pack_into(
        note_rewriter.ELF64_SECTION_HEADER_FORMAT,
        data,
        dynstr["header_offset"],
        dynstr["name_offset"],
        dynstr["type"],
        dynstr["flags"],
        dynstr["addr"],
        dynstr["offset"],
        dynstr["size"],
        dynstr["link"],
        dynstr["info"],
        dynstr["addralign"],
        dynstr["entsize"],
    )
    return offsets


def append_trailing_strtab_strings(
    data: bytearray,
    sections: list[dict],
    section_map: dict[str, dict],
    strings: list[bytes],
) -> dict[bytes, int]:
    strtab = section_map[".strtab"]
    start = strtab["offset"]
    old_size = strtab["size"]
    end = start + old_size
    header_fields = list(struct.unpack_from(note_rewriter.ELF64_HEADER_FORMAT, data, 0))
    shoff = header_fields[6]
    capacity = shoff - start
    blob = bytearray(data[start:end])
    offsets: dict[bytes, int] = {}
    for string in strings:
        if string in blob:
            offsets[string] = blob.index(string)
            continue
        offsets[string] = len(blob)
        blob.extend(string)

    growth = max(len(blob) - capacity, 0)
    if growth:
        insert_offset = shoff
        data[insert_offset:insert_offset] = b"\x00" * growth
        header_fields[6] += growth
        struct.pack_into(note_rewriter.ELF64_HEADER_FORMAT, data, 0, *header_fields)
        for section in sections:
            if section["header_offset"] >= insert_offset:
                section["header_offset"] += growth
    data[start : start + len(blob)] = blob
    if len(blob) < old_size + growth:
        data[start + len(blob) : start + old_size + growth] = b"\x00" * (
            old_size + growth - len(blob)
        )
    strtab["size"] = len(blob)
    note_rewriter.write_section_header(data, strtab)
    for section in sections:
        if section is strtab:
            continue
        if growth and section["header_offset"] >= shoff:
            note_rewriter.write_section_header(data, section)
    return offsets


def patch_dynamic_strsz(data: bytearray, section_map: dict[str, dict], new_size: int) -> None:
    dynamic = section_map[".dynamic"]
    offset = dynamic["offset"]
    entsize = dynamic["entsize"]
    count = dynamic["size"] // entsize
    for index in range(count):
        entry_offset = offset + index * entsize
        tag, value = struct.unpack_from("<QQ", data, entry_offset)
        if tag == DT_STRSZ:
            struct.pack_into("<QQ", data, entry_offset, tag, new_size)
            return
    raise SystemExit("DT_STRSZ entry not found in .dynamic")


def patch_dynsym_name(data: bytearray, symbol: dict, new_name_offset: int) -> None:
    entry_offset = symbol["entry_offset"]
    _st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(
        ELF64_SYM_FORMAT, data, entry_offset
    )
    struct.pack_into(
        ELF64_SYM_FORMAT,
        data,
        entry_offset,
        new_name_offset,
        st_info,
        st_other,
        st_shndx,
        st_value,
        st_size,
    )


def load_dynsym_entries(data: bytearray, section_map: dict[str, dict]) -> list[dict]:
    dynsym = section_map[".dynsym"]
    _dynstr_section, dynstr_bytes = read_dynstr(data, section_map)
    entry_count = dynsym["size"] // dynsym["entsize"]
    entries: list[dict] = []
    for index in range(entry_count):
        entry_offset = dynsym["offset"] + index * dynsym["entsize"]
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(
            ELF64_SYM_FORMAT, data, entry_offset
        )
        end = dynstr_bytes.find(b"\x00", st_name)
        name = dynstr_bytes[st_name:end].decode("utf-8") if end != -1 else ""
        entries.append(
            {
                "index": index,
                "entry_offset": entry_offset,
                "st_name": st_name,
                "name": name,
                "st_info": st_info,
                "st_other": st_other,
                "st_shndx": st_shndx,
                "st_value": st_value,
                "st_size": st_size,
            }
        )
    return entries


def enrich_dynsym_entries(data: bytearray, section_map: dict[str, dict], manifest: dict) -> dict[str, dict]:
    names_to_symbols = {symbol["name"]: symbol for symbol in manifest.get("symbols", [])}
    enriched: dict[str, dict] = {}
    for entry in load_dynsym_entries(data, section_map):
        name = entry["name"]
        if name in names_to_symbols:
            enriched[name] = {
                **names_to_symbols[name],
                "entry_offset": entry["entry_offset"],
                "index": entry["index"],
            }
    return enriched


def load_symtab_entries(data: bytearray, section_map: dict[str, dict]) -> dict[str, dict]:
    symtab = section_map[".symtab"]
    _strtab_section, strtab_bytes = read_strtab(data, section_map)
    entry_count = symtab["size"] // symtab["entsize"]
    entries: dict[str, dict] = {}
    for index in range(entry_count):
        entry_offset = symtab["offset"] + index * symtab["entsize"]
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(
            ELF64_SYM_FORMAT, data, entry_offset
        )
        end = strtab_bytes.find(b"\x00", st_name)
        name = strtab_bytes[st_name:end].decode("utf-8") if end != -1 else ""
        if name:
            entries[name] = {
                "index": index,
                "entry_offset": entry_offset,
                "name": name,
            }
    return entries


def patch_descriptor_kernarg_size(data: bytearray, descriptor_symbol: dict, new_kernarg_size: int) -> None:
    descriptor_offset = descriptor_symbol["value"]
    write_u32(data, descriptor_offset + 8, new_kernarg_size)


def elf_hash(name: str) -> int:
    value = 0
    for ch in name.encode("utf-8"):
        value = (value << 4) + ch
        high = value & 0xF0000000
        if high:
            value ^= high >> 24
        value &= ~high
    return value & 0xFFFFFFFF


def gnu_hash(name: str) -> int:
    value = 5381
    for ch in name.encode("utf-8"):
        value = ((value << 5) + value + ch) & 0xFFFFFFFF
    return value


def rebuild_sysv_hash(data: bytearray, section_map: dict[str, dict], entries: list[dict]) -> None:
    hash_section = section_map.get(".hash")
    if not hash_section:
        return

    offset = hash_section["offset"]
    nbucket, nchain = struct.unpack_from("<II", data, offset)
    if nchain != len(entries):
        raise SystemExit(f".hash nchain mismatch: {nchain} != {len(entries)}")

    buckets = [0] * nbucket
    chains = [0] * nchain
    for entry in entries[1:]:
        name = entry["name"]
        if not name:
            continue
        bucket = elf_hash(name) % nbucket
        index = entry["index"]
        if buckets[bucket] == 0:
            buckets[bucket] = index
            continue
        current = buckets[bucket]
        while chains[current] != 0:
            current = chains[current]
        chains[current] = index

    cursor = offset + 8
    for value in buckets:
        struct.pack_into("<I", data, cursor, value)
        cursor += 4
    for value in chains:
        struct.pack_into("<I", data, cursor, value)
        cursor += 4


def rebuild_gnu_hash(data: bytearray, section_map: dict[str, dict], entries: list[dict]) -> None:
    hash_section = section_map.get(".gnu.hash")
    if not hash_section:
        return

    offset = hash_section["offset"]
    nbuckets, symoffset, bloom_size, bloom_shift = struct.unpack_from("<IIII", data, offset)
    if symoffset >= len(entries):
        raise SystemExit(f".gnu.hash symoffset {symoffset} is out of range for {len(entries)} symbols")

    buckets_to_indices: dict[int, list[int]] = {bucket: [] for bucket in range(nbuckets)}
    hashes_by_index: dict[int, int] = {}
    bloom = [0] * bloom_size

    for entry in entries[symoffset:]:
        name = entry["name"]
        if not name:
            continue
        index = entry["index"]
        hash_value = gnu_hash(name)
        hashes_by_index[index] = hash_value
        bucket = hash_value % nbuckets
        buckets_to_indices[bucket].append(index)
        word = (hash_value // 64) % bloom_size
        bloom[word] |= (1 << (hash_value % 64)) | (1 << ((hash_value >> bloom_shift) % 64))

    for bucket, indices in buckets_to_indices.items():
        if not indices:
            continue
        if indices[-1] - indices[0] + 1 != len(indices):
            raise SystemExit(
                f".gnu.hash bucket {bucket} would require dynsym reordering for renamed symbols"
            )

    buckets = [0] * nbuckets
    chain_count = len(entries) - symoffset
    chains = [0] * chain_count
    for bucket, indices in buckets_to_indices.items():
        if not indices:
            continue
        buckets[bucket] = indices[0]
        for position, index in enumerate(indices):
            chain_value = hashes_by_index[index] & ~1
            if position == len(indices) - 1:
                chain_value |= 1
            chains[index - symoffset] = chain_value

    cursor = offset + 16
    for value in bloom:
        struct.pack_into("<Q", data, cursor, value)
        cursor += 8
    for value in buckets:
        struct.pack_into("<I", data, cursor, value)
        cursor += 4
    for value in chains:
        struct.pack_into("<I", data, cursor, value)
        cursor += 4


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()
    report_path = Path(args.report_output).resolve() if args.report_output else None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    source_kernel = select_kernels(manifest, args.source_kernel)[0]
    donor_kernel = select_kernels(manifest, args.donor_kernel)[0]
    plan = build_kernel_plan(source_kernel, args.pointer_size, args.alignment)

    metadata_payload = metadata_emitter.build_metadata_payload_with_replacement(
        manifest,
        source_kernel=source_kernel,
        replace_kernel=donor_kernel,
        pointer_size=args.pointer_size,
        alignment=args.alignment,
        output_format="msgpack",
    )

    data, sections, section_map = note_rewriter.load_sections(input_path)
    clone_name = plan["hidden_abi_clone_name"]
    clone_descriptor = f"{clone_name}.kd"

    name_offsets = append_dynstr_strings(
        data,
        sections,
        section_map,
        [clone_name.encode() + b"\x00", clone_descriptor.encode() + b"\x00"],
    )
    symtab_name_offsets = append_trailing_strtab_strings(
        data,
        sections,
        section_map,
        [clone_name.encode() + b"\x00", clone_descriptor.encode() + b"\x00"],
    )
    patch_dynamic_strsz(data, section_map, section_map[".dynstr"]["size"])

    dynsym_entries = enrich_dynsym_entries(data, section_map, manifest)
    symtab_entries = load_symtab_entries(data, section_map)
    donor_function_symbol = dynsym_entries.get(donor_kernel["name"])
    donor_descriptor_symbol = dynsym_entries.get(donor_kernel["symbol"])
    if donor_function_symbol is None or donor_descriptor_symbol is None:
        raise SystemExit("failed to locate donor kernel symbols in .dynsym")
    donor_function_symtab = symtab_entries.get(donor_kernel["name"])
    donor_descriptor_symtab = symtab_entries.get(donor_kernel["symbol"])

    patch_dynsym_name(data, donor_function_symbol, name_offsets[clone_name.encode() + b"\x00"])
    patch_dynsym_name(data, donor_descriptor_symbol, name_offsets[clone_descriptor.encode() + b"\x00"])
    if donor_function_symtab is not None:
        patch_dynsym_name(data, donor_function_symtab, symtab_name_offsets[clone_name.encode() + b"\x00"])
    if donor_descriptor_symtab is not None:
        patch_dynsym_name(data, donor_descriptor_symtab, symtab_name_offsets[clone_descriptor.encode() + b"\x00"])
    patch_descriptor_kernarg_size(data, donor_descriptor_symbol, plan["instrumented_kernarg_length"])
    dynsym_entries = load_dynsym_entries(data, section_map)
    rebuild_sysv_hash(data, section_map, dynsym_entries)
    rebuild_gnu_hash(data, section_map, dynsym_entries)

    note_section = section_map[".note"]
    data, sections, section_map = note_rewriter.replace_metadata_note(
        data,
        sections,
        section_map,
        metadata_payload,
        allow_grow=True,
    )

    output_path.write_bytes(data)
    if report_path is not None:
        report = {
            "mode": "abi-changing",
            "operation": "surrogate-rebind",
            "input_code_object": str(input_path),
            "input_manifest": str(manifest_path),
            "output_code_object": str(output_path),
            "source_kernel": source_kernel.get("name"),
            "source_symbol": source_kernel.get("symbol"),
            "donor_kernel": donor_kernel.get("name"),
            "donor_symbol": donor_kernel.get("symbol"),
            "clone_kernel": clone_name,
            "clone_descriptor": clone_descriptor,
            "instrumented_kernarg_length": plan["instrumented_kernarg_length"],
            "source_kernarg_length": plan["source_kernarg_length"],
            "source_explicit_args_length": plan["source_explicit_args_length"],
            "source_hidden_args_length": plan["source_hidden_args_length"],
            "pointer_size": args.pointer_size,
            "alignment": args.alignment,
        }
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
