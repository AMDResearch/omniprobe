#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply a small targeted mutation to instruction-level IR."
    )
    parser.add_argument("input", help="Input IR JSON")
    parser.add_argument("--output", required=True, help="Output IR JSON")
    parser.add_argument(
        "--address",
        required=True,
        type=parse_int,
        help="Instruction address to modify",
    )
    parser.add_argument(
        "--mnemonic",
        default=None,
        help="Replacement mnemonic",
    )
    parser.add_argument(
        "--operand-text",
        default=None,
        help="Replacement operand text",
    )
    return parser.parse_args()


def split_operands(operand_text: str) -> list[str]:
    if not operand_text:
        return []
    parts = []
    current = []
    depth = 0
    for char in operand_text:
        if char == "[":
            depth += 1
        elif char == "]" and depth > 0:
            depth -= 1
        if char == "," and depth == 0:
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


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()

    ir = json.loads(input_path.read_text(encoding="utf-8"))
    changed = False
    for function in ir.get("functions", []):
        for instruction in function.get("instructions", []):
            if instruction.get("address") != args.address:
                continue
            if args.mnemonic is not None:
                instruction["mnemonic"] = args.mnemonic
            if args.operand_text is not None:
                instruction["operand_text"] = args.operand_text
                instruction["operands"] = split_operands(args.operand_text)
            # Force exact-encoding emitters to reassemble this instruction
            # from text instead of reusing the stale original machine words.
            instruction.pop("encoding_words", None)
            instruction.pop("encoding_hex", None)
            changed = True
            break
        if changed:
            break

    if not changed:
        raise SystemExit(f"instruction at address {args.address:#x} not found")

    output_path.write_text(json.dumps(ir, indent=2) + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
