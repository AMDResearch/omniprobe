#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

from common import detect_llvm_tool


FUNCTION_HEADER_RE = re.compile(r"^([0-9a-fA-F]+)\s+<([^>]+)>:$")
INSTRUCTION_RE = re.compile(
    r"^\s*([a-z0-9_]+)\s*(.*?)\s*//\s*([0-9a-fA-F]+):\s*([0-9A-Fa-f ]+)(?:\s+<(.*?)>)?\s*$"
)
TARGET_ANGLE_RE = re.compile(r"^([^+>]+)(?:\+0x([0-9a-fA-F]+))?$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert llvm-objdump AMDGPU disassembly to an instruction-level IR."
    )
    parser.add_argument("input", help="Path to extracted AMDGPU code object")
    parser.add_argument(
        "--output",
        default=None,
        help="Output JSON path; defaults to <input>.ir.json",
    )
    parser.add_argument(
        "--llvm-objdump",
        default=None,
        help="Path to llvm-objdump; auto-detected when omitted",
    )
    parser.add_argument(
        "--arch",
        default=None,
        help="AMDGPU cpu name, for example gfx1030; inferred from the code object manifest when omitted",
    )
    parser.add_argument(
        "--manifest",
        default=None,
        help="Optional code-object manifest JSON emitted by inspect_code_object.py",
    )
    return parser.parse_args()


def infer_arch_from_manifest(manifest_path: Path | None) -> str | None:
    if not manifest_path or not manifest_path.exists():
        return None

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    flags = manifest.get("elf_header", {}).get("flags", [])
    for flag in flags:
        marker = "EF_AMDGPU_MACH_AMDGCN_"
        if flag.startswith(marker):
            return flag[len(marker) :].lower()

    target = manifest.get("kernels", {}).get("metadata", {}).get("target")
    if target and "--" in target:
        return target.rsplit("--", 1)[-1]
    return None


def run_objdump(objdump: str, input_path: Path, arch: str | None) -> str:
    command = [objdump, "-d", "--triple=amdgcn-amd-amdhsa"]
    if arch:
        command.append(f"--mcpu={arch}")
    command.append(str(input_path))
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return result.stdout


def split_operands(operand_text: str) -> list[str]:
    if not operand_text:
        return []

    parts = []
    current = []
    bracket_depth = 0
    for char in operand_text:
        if char == "[":
            bracket_depth += 1
        elif char == "]" and bracket_depth > 0:
            bracket_depth -= 1

        if char == "," and bracket_depth == 0:
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []
            continue
        current.append(char)

    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return parts


def classify_control_flow(mnemonic: str) -> str:
    if mnemonic == "s_endpgm":
        return "return"
    if mnemonic == "s_branch":
        return "branch_unconditional"
    if mnemonic.startswith("s_cbranch"):
        return "branch_conditional"
    if mnemonic.startswith("s_setpc") or mnemonic.startswith("s_swappc"):
        return "branch_indirect"
    return "linear"


def parse_target_ref(target_ref: str | None) -> dict | None:
    if not target_ref:
        return None
    match = TARGET_ANGLE_RE.match(target_ref)
    if not match:
        return {"raw": target_ref}
    symbol = match.group(1)
    offset_hex = match.group(2)
    return {
        "raw": target_ref,
        "symbol": symbol,
        "offset": int(offset_hex, 16) if offset_hex else 0,
    }


def parse_disassembly(text: str) -> list[dict]:
    functions: list[dict] = []
    current_function: dict | None = None
    current_section = None

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not line:
            continue
        if line.startswith("Disassembly of section "):
            current_section = line[len("Disassembly of section ") :].rstrip(":")
            continue
        if line.endswith(":") and "<" in line and ">" in line:
            match = FUNCTION_HEADER_RE.match(line)
            if not match:
                continue
            current_function = {
                "name": match.group(2),
                "start_address": int(match.group(1), 16),
                "section": current_section,
                "instructions": [],
            }
            functions.append(current_function)
            continue
        if current_function is None:
            continue

        stripped = line.lstrip()
        if stripped.startswith("/"):
            continue

        match = INSTRUCTION_RE.match(stripped)
        if not match:
            continue

        mnemonic = match.group(1)
        operand_text = match.group(2).strip()
        address = int(match.group(3), 16)
        encoding_words = match.group(4).split()
        target_ref = parse_target_ref(match.group(5))
        current_function["instructions"].append(
            {
                "address": address,
                "mnemonic": mnemonic,
                "operand_text": operand_text,
                "operands": split_operands(operand_text),
                "encoding_words": encoding_words,
                "encoding_hex": "".join(encoding_words),
                "control_flow": classify_control_flow(mnemonic),
                "target": target_ref,
                "is_padding": mnemonic == "s_code_end",
            }
        )

    return functions


def instruction_size_bytes(instruction: dict) -> int:
    return 4 * len(instruction.get("encoding_words", []))


def resolve_branch_target_address(function: dict, instruction: dict) -> int | None:
    target = instruction.get("target")
    if not target:
        return None
    symbol = target.get("symbol")
    if symbol != function["name"]:
        return None
    return function["start_address"] + target.get("offset", 0)


def build_basic_blocks(function: dict) -> None:
    instructions = function["instructions"]
    if not instructions:
        function["basic_blocks"] = []
        return

    leaders = {instructions[0]["address"]}
    address_to_index = {insn["address"]: index for index, insn in enumerate(instructions)}
    for index, instruction in enumerate(instructions):
        next_address = None
        if index + 1 < len(instructions):
            next_address = instructions[index + 1]["address"]

        target_address = resolve_branch_target_address(function, instruction)
        if target_address is not None and target_address in address_to_index:
            leaders.add(target_address)
            if instruction["control_flow"] != "branch_unconditional" and next_address is not None:
                leaders.add(next_address)
        elif instruction["control_flow"] in {"branch_conditional", "branch_indirect", "return"}:
            if next_address is not None:
                leaders.add(next_address)

    sorted_leaders = sorted(leaders)
    blocks = []
    for block_index, start_address in enumerate(sorted_leaders):
        start_index = address_to_index[start_address]
        end_index = len(instructions)
        if block_index + 1 < len(sorted_leaders):
            end_index = address_to_index[sorted_leaders[block_index + 1]]
        block_instructions = instructions[start_index:end_index]
        blocks.append(
            {
                "label": f"bb_{block_index}",
                "start_address": start_address,
                "end_address": block_instructions[-1]["address"]
                + instruction_size_bytes(block_instructions[-1]),
                "instruction_addresses": [insn["address"] for insn in block_instructions],
                "successors": [],
            }
        )

    leader_to_block = {block["start_address"]: block for block in blocks}
    for block in blocks:
        tail_address = block["instruction_addresses"][-1]
        tail_index = address_to_index[tail_address]
        tail_instruction = instructions[tail_index]
        next_address = None
        if tail_index + 1 < len(instructions):
            next_address = instructions[tail_index + 1]["address"]

        successors = []
        target_address = resolve_branch_target_address(function, tail_instruction)
        if tail_instruction["control_flow"] == "branch_unconditional":
            if target_address in leader_to_block:
                successors.append(leader_to_block[target_address]["label"])
        elif tail_instruction["control_flow"] == "branch_conditional":
            if target_address in leader_to_block:
                successors.append(leader_to_block[target_address]["label"])
            if next_address in leader_to_block:
                successors.append(leader_to_block[next_address]["label"])
        elif tail_instruction["control_flow"] == "linear" and next_address in leader_to_block:
            successors.append(leader_to_block[next_address]["label"])

        block["successors"] = successors

    function["basic_blocks"] = blocks


def annotate_functions(functions: list[dict]) -> None:
    for function in functions:
        build_basic_blocks(function)
        instruction_count = len(function["instructions"])
        function["instruction_count"] = instruction_count
        if instruction_count:
            last = function["instructions"][-1]
            function["end_address"] = last["address"] + instruction_size_bytes(last)
            function["size_bytes"] = function["end_address"] - function["start_address"]
        else:
            function["end_address"] = function["start_address"]
            function["size_bytes"] = 0


def transform_ir(input_path: Path, disassembly_text: str, arch: str | None) -> dict:
    functions = parse_disassembly(disassembly_text)
    annotate_functions(functions)
    return {
        "input_file": str(input_path),
        "arch": arch,
        "functions": functions,
    }


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_path = (
        Path(args.output).resolve()
        if args.output
        else input_path.with_suffix(input_path.suffix + ".ir.json")
    )

    manifest_path = Path(args.manifest).resolve() if args.manifest else None
    arch = args.arch or infer_arch_from_manifest(manifest_path)
    objdump = detect_llvm_tool("llvm-objdump", args.llvm_objdump)
    disassembly_text = run_objdump(objdump, input_path, arch)
    ir = transform_ir(input_path, disassembly_text, arch)
    output_path.write_text(json.dumps(ir, indent=2) + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
