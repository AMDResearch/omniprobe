#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path


ELF_MAGIC = b"\x7fELF"
ELF64_HEADER_FORMAT = "<16sHHIQQQIHHHHHH"
ELF64_SECTION_HEADER_FORMAT = "<IIQQQQIIQQ"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Patch one section in an ELF64 little-endian code object from another object."
    )
    parser.add_argument("base", help="Metadata-bearing ELF to preserve")
    parser.add_argument("donor", help="ELF providing replacement section bytes")
    parser.add_argument(
        "--section",
        default=".text",
        help="Section name to replace; defaults to .text",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Patched output path",
    )
    return parser.parse_args()


def read_c_string(blob: bytes, start: int) -> str:
    end = blob.find(b"\x00", start)
    if end == -1:
        end = len(blob)
    return blob[start:end].decode("utf-8")


def load_sections(path: Path) -> tuple[bytes, dict[str, dict]]:
    data = path.read_bytes()
    if not data.startswith(ELF_MAGIC):
        raise SystemExit(f"{path} is not an ELF file")

    header = struct.unpack_from(ELF64_HEADER_FORMAT, data, 0)
    section_offset = header[6]
    section_entry_size = header[11]
    section_count = header[12]
    shstr_index = header[13]

    sections = []
    for index in range(section_count):
        offset = section_offset + index * section_entry_size
        fields = struct.unpack_from(ELF64_SECTION_HEADER_FORMAT, data, offset)
        sections.append(
            {
                "index": index,
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
    return data, section_map


def main() -> int:
    args = parse_args()
    base_path = Path(args.base).resolve()
    donor_path = Path(args.donor).resolve()
    output_path = Path(args.output).resolve()

    base_data, base_sections = load_sections(base_path)
    donor_data, donor_sections = load_sections(donor_path)

    if args.section not in base_sections:
        raise SystemExit(f"{args.section} not found in {base_path}")
    if args.section not in donor_sections:
        raise SystemExit(f"{args.section} not found in {donor_path}")

    base_section = base_sections[args.section]
    donor_section = donor_sections[args.section]

    if base_section["size"] != donor_section["size"]:
        raise SystemExit(
            f"section size mismatch for {args.section}: "
            f"{base_section['size']} != {donor_section['size']}"
        )

    patched = bytearray(base_data)
    donor_bytes = donor_data[
        donor_section["offset"] : donor_section["offset"] + donor_section["size"]
    ]
    patched[
        base_section["offset"] : base_section["offset"] + base_section["size"]
    ] = donor_bytes

    output_path.write_bytes(patched)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
