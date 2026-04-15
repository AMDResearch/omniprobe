#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
ELF64_HEADER_FORMAT = "<16sHHIQQQIHHHHHH"
ELF64_SECTION_HEADER_FORMAT = "<IIQQQQIIQQ"
ELF64_PROGRAM_HEADER_FORMAT = "<IIQQQQQQ"
ELF64_SYMBOL_FORMAT = "<IBBHQQ"
ELF64_DYNAMIC_FORMAT = "<QQ"
NOTE_HEADER_FORMAT = "<III"
SHF_ALLOC = 0x2
SHT_NOTE = 7
PT_LOAD = 1
PT_NOTE = 4
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_INIT = 12
DT_FINI = 13
DT_SONAME = 14
DT_RPATH = 15
DT_SYMBOLIC = 16
DT_REL = 17
DT_RELSZ = 18
DT_RELENT = 19
DT_PLTREL = 20
DT_DEBUG = 21
DT_TEXTREL = 22
DT_JMPREL = 23
DT_BIND_NOW = 24
DT_INIT_ARRAY = 25
DT_FINI_ARRAY = 26
DT_INIT_ARRAYSZ = 27
DT_RUNPATH = 29
DT_PREINIT_ARRAY = 32
DT_PREINIT_ARRAYSZ = 33
DT_GNU_HASH = 0x6FFFFEF5

POINTER_DYNAMIC_TAGS = {
    DT_HASH,
    DT_STRTAB,
    DT_SYMTAB,
    DT_INIT,
    DT_FINI,
    DT_REL,
    DT_JMPREL,
    DT_INIT_ARRAY,
    DT_FINI_ARRAY,
    DT_PREINIT_ARRAY,
    DT_GNU_HASH,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rewrite the AMDGPU metadata note in an ELF code object without resizing sections."
    )
    parser.add_argument("input", help="Input AMDGPU ELF code object")
    parser.add_argument("metadata", help="Replacement AMDGPU metadata YAML text file")
    parser.add_argument("--output", required=True, help="Output ELF path")
    return parser.parse_args()


def align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def read_c_string(blob: bytes, start: int) -> str:
    end = blob.find(b"\x00", start)
    if end == -1:
        end = len(blob)
    return blob[start:end].decode("utf-8")


def load_sections(path: Path) -> tuple[bytearray, list[dict], dict[str, dict]]:
    data = bytearray(path.read_bytes())
    if not data.startswith(ELF_MAGIC):
        raise SystemExit(f"{path} is not an ELF file")

    header = struct.unpack_from(ELF64_HEADER_FORMAT, data, 0)
    section_offset = header[6]
    section_entry_size = header[11]
    section_count = header[12]
    shstr_index = header[13]

    sections: list[dict] = []
    for index in range(section_count):
        offset = section_offset + index * section_entry_size
        fields = struct.unpack_from(ELF64_SECTION_HEADER_FORMAT, data, offset)
        sections.append(
            {
                "index": index,
                "header_offset": offset,
                "name_offset": fields[0],
                "type": fields[1],
                "flags": fields[2],
                "addr": fields[3],
                "offset": fields[4],
                "size": fields[5],
                "link": fields[6],
                "info": fields[7],
                "addralign": fields[8],
                "entsize": fields[9],
            }
        )

    shstr = sections[shstr_index]
    shstr_data = data[shstr["offset"] : shstr["offset"] + shstr["size"]]
    section_map: dict[str, dict] = {}
    for section in sections:
        name = read_c_string(shstr_data, section["name_offset"]) if shstr_data else ""
        section["name"] = name
        section_map[name] = section
    return data, sections, section_map


def parse_elf_header(data: bytearray) -> list:
    return list(struct.unpack_from(ELF64_HEADER_FORMAT, data, 0))


def write_elf_header(data: bytearray, header_fields: list) -> None:
    struct.pack_into(ELF64_HEADER_FORMAT, data, 0, *header_fields)


def load_program_headers(data: bytearray) -> list[dict]:
    header = parse_elf_header(data)
    program_offset = header[5]
    program_entry_size = header[9]
    program_count = header[10]
    programs: list[dict] = []
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        fields = struct.unpack_from(ELF64_PROGRAM_HEADER_FORMAT, data, offset)
        programs.append(
            {
                "index": index,
                "header_offset": offset,
                "type": fields[0],
                "flags": fields[1],
                "offset": fields[2],
                "vaddr": fields[3],
                "paddr": fields[4],
                "filesz": fields[5],
                "memsz": fields[6],
                "align": fields[7],
            }
        )
    return programs


def write_section_header(data: bytearray, section: dict) -> None:
    struct.pack_into(
        ELF64_SECTION_HEADER_FORMAT,
        data,
        section["header_offset"],
        section["name_offset"],
        section["type"],
        section["flags"],
        section["addr"],
        section["offset"],
        section["size"],
        section["link"],
        section["info"],
        section["addralign"],
        section["entsize"],
    )


def write_program_header(data: bytearray, program: dict) -> None:
    struct.pack_into(
        ELF64_PROGRAM_HEADER_FORMAT,
        data,
        program["header_offset"],
        program["type"],
        program["flags"],
        program["offset"],
        program["vaddr"],
        program["paddr"],
        program["filesz"],
        program["memsz"],
        program["align"],
    )


def find_amdgpu_note(section_bytes: bytes) -> tuple[int, int, int, bytes, bytes]:
    cursor = 0
    while cursor + struct.calcsize(NOTE_HEADER_FORMAT) <= len(section_bytes):
        namesz, descsz, note_type = struct.unpack_from(NOTE_HEADER_FORMAT, section_bytes, cursor)
        cursor += struct.calcsize(NOTE_HEADER_FORMAT)
        name_start = cursor
        name_end = name_start + namesz
        name_bytes = section_bytes[name_start:name_end]
        cursor = align_up(name_end, 4)
        desc_start = cursor
        desc_end = desc_start + descsz
        desc_bytes = section_bytes[desc_start:desc_end]
        cursor = align_up(desc_end, 4)

        owner = name_bytes.rstrip(b"\x00").decode("utf-8", errors="ignore")
        if owner == "AMDGPU":
            return (
                name_start - struct.calcsize(NOTE_HEADER_FORMAT),
                cursor,
                note_type,
                name_bytes,
                desc_bytes,
            )

    raise SystemExit("NT_AMDGPU_METADATA note not found")


def rebuild_note(note_type: int, name_bytes: bytes, metadata_bytes: bytes) -> bytes:
    header = struct.pack(NOTE_HEADER_FORMAT, len(name_bytes), len(metadata_bytes), note_type)
    payload = bytearray()
    payload.extend(header)
    payload.extend(name_bytes)
    payload.extend(b"\x00" * (align_up(len(name_bytes), 4) - len(name_bytes)))
    payload.extend(metadata_bytes)
    payload.extend(b"\x00" * (align_up(len(metadata_bytes), 4) - len(metadata_bytes)))
    return bytes(payload)


def choose_growth_shift(sections: list[dict], insert_offset: int, growth_needed: int) -> int:
    if growth_needed <= 0:
        return 0
    max_alignment = max(
        (
            int(section.get("addralign", 0) or 1)
            for section in sections
            if section["offset"] >= insert_offset and int(section.get("addralign", 0) or 1) > 0
        ),
        default=1,
    )
    return align_up(growth_needed, max_alignment)


def contiguous_note_cluster(sections: list[dict], root_note_section: dict) -> list[dict]:
    cluster = [root_note_section]
    current_end = root_note_section["offset"] + root_note_section["size"]
    remaining = sorted(sections, key=lambda section: section["offset"])
    for section in remaining:
        if section["index"] == root_note_section["index"]:
            continue
        if section["type"] != SHT_NOTE or not (section["flags"] & SHF_ALLOC):
            continue
        if section["offset"] != current_end:
            continue
        cluster.append(section)
        current_end = section["offset"] + section["size"]
    return cluster


def shift_symbol_table_values(
    data: bytearray,
    section: dict | None,
    moved_alloc_section_indices: set[int],
    shift_amount: int,
) -> None:
    if section is None or section["entsize"] == 0:
        return
    entry_count = section["size"] // section["entsize"]
    for index in range(entry_count):
        entry_offset = section["offset"] + index * section["entsize"]
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(
            ELF64_SYMBOL_FORMAT, data, entry_offset
        )
        if st_shndx in moved_alloc_section_indices:
            struct.pack_into(
                ELF64_SYMBOL_FORMAT,
                data,
                entry_offset,
                st_name,
                st_info,
                st_other,
                st_shndx,
                st_value + shift_amount,
                st_size,
            )


def shift_dynamic_pointer_values(
    data: bytearray,
    section: dict | None,
    shift_amount: int,
    threshold_addr: int,
) -> None:
    if section is None or section["entsize"] == 0:
        return
    entry_count = section["size"] // section["entsize"]
    for index in range(entry_count):
        entry_offset = section["offset"] + index * section["entsize"]
        tag, value = struct.unpack_from(ELF64_DYNAMIC_FORMAT, data, entry_offset)
        if tag in POINTER_DYNAMIC_TAGS and value >= threshold_addr:
            struct.pack_into(ELF64_DYNAMIC_FORMAT, data, entry_offset, tag, value + shift_amount)


def replace_metadata_note(
    data: bytearray,
    sections: list[dict],
    section_map: dict[str, dict],
    metadata_bytes: bytes,
    *,
    allow_grow: bool = True,
) -> tuple[bytearray, list[dict], dict[str, dict]]:
    note_section = section_map.get(".note")
    if not note_section or note_section["type"] != SHT_NOTE:
        raise SystemExit(".note section not found")

    section_offset = note_section["offset"]
    section_size = note_section["size"]
    section_bytes = bytes(data[section_offset : section_offset + section_size])
    note_start, note_end, note_type, name_bytes, _old_desc = find_amdgpu_note(section_bytes)

    new_note = rebuild_note(note_type, name_bytes, metadata_bytes)
    replacement_section = section_bytes[:note_start] + new_note + section_bytes[note_end:]
    growth_needed = len(replacement_section) - section_size

    if growth_needed == 0:
        data[section_offset : section_offset + section_size] = replacement_section
        return data, sections, section_map

    if growth_needed < 0:
        shrink_amount = -growth_needed
        note_cluster = contiguous_note_cluster(sections, note_section)
        root_note_end_addr = note_section["addr"] + note_section["size"]
        delete_offset = section_offset + len(replacement_section)
        moved_alloc_section_indices = {
            section["index"]
            for section in sections
            if section["index"] != note_section["index"]
            and (section["flags"] & SHF_ALLOC)
            and section["addr"] >= root_note_end_addr
        }

        data[section_offset : section_offset + len(replacement_section)] = replacement_section
        del data[delete_offset : delete_offset + shrink_amount]

        header_fields = parse_elf_header(data)
        if header_fields[5] >= delete_offset:
            header_fields[5] -= shrink_amount
        if header_fields[6] >= delete_offset:
            header_fields[6] -= shrink_amount
        write_elf_header(data, header_fields)

        programs = load_program_headers(data)
        for program in programs:
            file_end = program["offset"] + program["filesz"]
            mem_end = program["vaddr"] + program["memsz"]
            if program["header_offset"] >= delete_offset:
                program["header_offset"] -= shrink_amount
            if program["offset"] > delete_offset:
                program["offset"] -= shrink_amount
                if program["vaddr"] >= root_note_end_addr:
                    program["vaddr"] -= shrink_amount
                    program["paddr"] -= shrink_amount
            elif program["offset"] <= delete_offset < file_end:
                program["filesz"] -= shrink_amount
                if program["vaddr"] <= root_note_end_addr < mem_end:
                    program["memsz"] -= shrink_amount
            write_program_header(data, program)

        for section in sections:
            if section["header_offset"] >= delete_offset:
                section["header_offset"] -= shrink_amount
            if section["index"] == note_section["index"]:
                section["size"] = len(replacement_section)
            elif section in note_cluster:
                section["offset"] -= shrink_amount
                section["addr"] -= shrink_amount
            elif section["offset"] >= delete_offset:
                section["offset"] -= shrink_amount
            if (section["flags"] & SHF_ALLOC) and section["index"] in moved_alloc_section_indices:
                section["addr"] -= shrink_amount

        shift_symbol_table_values(
            data,
            section_map.get(".dynsym"),
            moved_alloc_section_indices,
            -shrink_amount,
        )
        shift_symbol_table_values(
            data,
            section_map.get(".symtab"),
            moved_alloc_section_indices,
            -shrink_amount,
        )
        shift_dynamic_pointer_values(
            data,
            section_map.get(".dynamic"),
            -shrink_amount,
            root_note_end_addr,
        )

        for section in sections:
            write_section_header(data, section)
        return data, sections, section_map

    if not allow_grow:
        raise SystemExit(
            f"replacement metadata note is too large: {len(replacement_section)} > available {section_size}"
        )

    note_cluster = contiguous_note_cluster(sections, note_section)
    note_cluster_end_offset = max(section["offset"] + section["size"] for section in note_cluster)
    note_cluster_end_addr = max(section["addr"] + section["size"] for section in note_cluster)
    note_growth = len(replacement_section) - section_size
    shift_amount = choose_growth_shift(sections, note_cluster_end_offset, growth_needed)
    cluster_tail_padding = shift_amount - note_growth

    header_fields = parse_elf_header(data)
    programs = load_program_headers(data)
    moved_alloc_section_indices = {
        section["index"]
        for section in sections
        if section["index"] != note_section["index"]
        and (section["flags"] & SHF_ALLOC)
        and section["addr"] >= note_cluster_end_addr
    }

    data[note_cluster_end_offset:note_cluster_end_offset] = b"\x00" * shift_amount
    data[section_offset : section_offset + len(replacement_section)] = replacement_section

    if header_fields[5] >= note_cluster_end_offset:
        header_fields[5] += shift_amount
    if header_fields[6] >= note_cluster_end_offset:
        header_fields[6] += shift_amount
    write_elf_header(data, header_fields)

    for program in programs:
        file_end = program["offset"] + program["filesz"]
        mem_end = program["vaddr"] + program["memsz"]
        if program["header_offset"] >= note_cluster_end_offset:
            program["header_offset"] += shift_amount
        if program["type"] == PT_NOTE and program["offset"] <= section_offset < file_end:
            program["filesz"] += note_growth
            program["memsz"] += note_growth
        elif program["offset"] > note_cluster_end_offset:
            program["offset"] += shift_amount
            if program["vaddr"] >= note_cluster_end_addr:
                program["vaddr"] += shift_amount
                program["paddr"] += shift_amount
        elif program["offset"] <= note_cluster_end_offset < file_end:
            program["filesz"] += shift_amount
            if program["vaddr"] <= note_cluster_end_addr < mem_end:
                program["memsz"] += shift_amount
        write_program_header(data, program)

    for section in sections:
        if section["header_offset"] >= note_cluster_end_offset:
            section["header_offset"] += shift_amount
        if section["index"] == note_section["index"]:
            section["size"] = len(replacement_section)
        elif section in note_cluster:
            section["offset"] += note_growth
            section["addr"] += note_growth
        elif section["offset"] >= note_cluster_end_offset:
            section["offset"] += shift_amount
        if (section["flags"] & SHF_ALLOC) and section["index"] in moved_alloc_section_indices:
            section["addr"] += shift_amount

    if cluster_tail_padding > 0:
        pad_start = note_cluster_end_offset + note_growth
        data[pad_start : pad_start + cluster_tail_padding] = b"\x00" * cluster_tail_padding

    shift_symbol_table_values(data, section_map.get(".dynsym"), moved_alloc_section_indices, shift_amount)
    shift_symbol_table_values(data, section_map.get(".symtab"), moved_alloc_section_indices, shift_amount)
    shift_dynamic_pointer_values(data, section_map.get(".dynamic"), shift_amount, note_cluster_end_addr)

    for section in sections:
        write_section_header(data, section)

    return data, sections, section_map


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    metadata_path = Path(args.metadata).resolve()
    output_path = Path(args.output).resolve()

    metadata_bytes = metadata_path.read_bytes()
    data, sections, section_map = load_sections(input_path)
    data, _sections, _section_map = replace_metadata_note(
        data,
        sections,
        section_map,
        metadata_bytes,
        allow_grow=True,
    )
    output_path.write_bytes(data)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
