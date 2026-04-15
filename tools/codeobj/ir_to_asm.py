#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render instruction-level AMDGPU IR back to assembly."
    )
    parser.add_argument("input", help="Path to instruction-level IR JSON")
    parser.add_argument(
        "--output",
        default=None,
        help="Output assembly path; defaults to <input>.s",
    )
    return parser.parse_args()


def render_instruction(function: dict, instruction: dict, labels: dict[int, str]) -> str:
    mnemonic = instruction["mnemonic"]
    operand_text = instruction.get("operand_text", "")
    target = instruction.get("target")
    if target and target.get("symbol") == function["name"]:
        target_address = function["start_address"] + target.get("offset", 0)
        if target_address in labels:
            operand_text = labels[target_address]

    if operand_text:
        return f"  {mnemonic} {operand_text}"
    return f"  {mnemonic}"


def render_function(function: dict) -> list[str]:
    lines = []
    lines.append(".text")
    lines.append(".p2align 8")
    lines.append(f".globl {function['name']}")
    lines.append(f".type {function['name']},@function")
    lines.append(f"{function['name']}:")

    leader_addresses = [block["start_address"] for block in function.get("basic_blocks", [])]
    labels = {
        address: f".L_{function['name']}_{address:016x}"
        for address in leader_addresses
        if address != function["start_address"]
    }

    for instruction in function["instructions"]:
        address = instruction["address"]
        if address in labels:
            lines.append(f"{labels[address]}:")
        lines.append(render_instruction(function, instruction, labels))

    lines.append(f".size {function['name']}, .-{function['name']}")
    return lines


def render_assembly(ir: dict) -> str:
    lines = [
        ".amdgcn_target \"amdgcn-amd-amdhsa--{}\"".format(ir["arch"])
        if ir.get("arch")
        else ""
    ]
    for function in ir.get("functions", []):
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(render_function(function))
    return "\n".join(line for line in lines if line != "") + "\n"


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_path = (
        Path(args.output).resolve()
        if args.output
        else input_path.with_suffix(input_path.suffix + ".s")
    )

    ir = json.loads(input_path.read_text(encoding="utf-8"))
    output_path.write_text(render_assembly(ir), encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
