#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import struct
from pathlib import Path


OMNIPROBE_PREFIX = "__amd_crk_"
OMNIPROBE_HIDDEN_ARG = "hidden_omniprobe_ctx"
ELF_MAGIC = b"\x7fELF"
ELF64_HEADER_FORMAT = "<16sHHIQQQIHHHHHH"
ELF64_SECTION_HEADER_FORMAT = "<IIQQQQIIQQ"
NOTE_HEADER_FORMAT = "<III"
SHT_NOTE = 7


def detect_llvm_tool(tool_name: str, explicit: str | None = None) -> str:
    candidates: list[str | None] = []
    if explicit:
        candidates.append(explicit)
    candidates.extend([shutil.which(tool_name), shutil.which("hipconfig")])

    for candidate in candidates:
        if not candidate:
            continue
        if Path(candidate).name == "hipconfig":
            try:
                hip_path = subprocess.run(
                    [candidate, "--path"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
            except subprocess.CalledProcessError:
                continue
            tool_path = Path(hip_path) / f"lib/llvm/bin/{tool_name}"
            if tool_path.exists():
                return str(tool_path)
            continue
        return candidate

    raise SystemExit(f"{tool_name} was not found")


def sanitize_bundle_id(bundle_id: str, max_length: int = 120) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9._-]+", "_", bundle_id).strip("_")
    if not sanitized:
        sanitized = "item"
    if max_length <= 0 or len(sanitized) <= max_length:
        return sanitized

    digest = hashlib.sha1(bundle_id.encode("utf-8")).hexdigest()[:12]
    keep = max_length - len(digest) - 1
    if keep <= 0:
        return digest[:max_length]
    return f"{sanitized[:keep].rstrip('._-')}_{digest}"


def get_instrumented_name(func_decl: str) -> str:
    result = func_decl
    pos = result.rfind(")")
    if pos != -1:
        result = result[:pos] + ", void*)" + result[pos + 1 :]
        pos = result.find(" ")
        ret_type = result.find("(")
        if pos > ret_type:
            pos = -1
        return result[: pos + 1] + OMNIPROBE_PREFIX + result[pos + 1 :]

    pos = result.rfind(".kd")
    if pos != -1:
        result = result[:pos] + "Pv" + result[pos:]
    else:
        result += "Pv"
    return OMNIPROBE_PREFIX + result


def get_hidden_abi_instrumented_name(func_decl: str) -> str:
    result = func_decl
    pos = result.rfind(")")
    if pos != -1:
        pos = result.find(" ")
        ret_type = result.find("(")
        if pos > ret_type:
            pos = -1
        return result[: pos + 1] + OMNIPROBE_PREFIX + result[pos + 1 :]
    return OMNIPROBE_PREFIX + result


def align_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        raise ValueError("alignment must be positive")
    return ((value + alignment - 1) // alignment) * alignment


def read_c_string(blob: bytes, start: int) -> str:
    end = blob.find(b"\x00", start)
    if end == -1:
        end = len(blob)
    return blob[start:end].decode("utf-8")


def load_elf_sections(path: Path) -> tuple[bytearray, list[dict], dict[str, dict]]:
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


def find_amdgpu_metadata_note(path: Path) -> dict | None:
    data, _sections, section_map = load_elf_sections(path)
    note_section = section_map.get(".note")
    if not note_section or note_section["type"] != SHT_NOTE:
        return None

    section_offset = note_section["offset"]
    section_size = note_section["size"]
    section_bytes = bytes(data[section_offset : section_offset + section_size])

    cursor = 0
    note_header_size = struct.calcsize(NOTE_HEADER_FORMAT)
    while cursor + note_header_size <= len(section_bytes):
        note_start = cursor
        namesz, descsz, note_type = struct.unpack_from(NOTE_HEADER_FORMAT, section_bytes, cursor)
        cursor += note_header_size
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
            return {
                "section_name": ".note",
                "section_offset": section_offset,
                "section_size": section_size,
                "note_offset_in_section": note_start,
                "note_size": cursor - note_start,
                "type": note_type,
                "owner": owner,
                "name_bytes": bytes(name_bytes),
                "desc_bytes": bytes(desc_bytes),
            }

    return None
