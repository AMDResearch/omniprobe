#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from common import detect_llvm_tool, get_hidden_abi_instrumented_name, get_instrumented_name
from inspect_code_object import build_manifest, run_readelf_json
from plan_hidden_abi import select_kernels


INSTRUCTION_RE = re.compile(r"^\s*([a-z0-9_.]+)\s*(.*?)\s*(?://.*)?$")
RESOURCE_FIELDS = (
    "kernarg_segment_size",
    "sgpr_count",
    "vgpr_count",
    "group_segment_fixed_size",
    "private_segment_fixed_size",
    "wavefront_size",
    "max_flat_workgroup_size",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze a real instrumented carrier code object and derive a per-kernel "
            "recipe surface for future binary instrumentation."
        )
    )
    parser.add_argument("carrier", help="Instrumented carrier AMDGPU code object")
    parser.add_argument(
        "--kernel",
        required=True,
        help="Original kernel name or symbol in the carrier manifest",
    )
    parser.add_argument(
        "--clone",
        default=None,
        help="Explicit clone kernel name or symbol; auto-detected when omitted",
    )
    parser.add_argument(
        "--reference",
        default=None,
        help=(
            "Optional uninstrumented reference code object. When provided, the analysis "
            "also reports helper/global symbols added by the carrier."
        ),
    )
    parser.add_argument(
        "--llvm-readelf",
        default=None,
        help="Path to llvm-readelf; auto-detected when omitted",
    )
    parser.add_argument(
        "--llvm-objdump",
        default=None,
        help="Path to llvm-objdump; auto-detected when omitted",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON instead of a human-readable report",
    )
    return parser.parse_args()


def load_manifest(input_path: Path, readelf: str) -> dict:
    payload = run_readelf_json(readelf, input_path)
    return build_manifest(payload, input_path)


def kernel_records(manifest: dict) -> list[dict]:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    return [kernel for kernel in kernels if isinstance(kernel, dict)]


def clone_name_candidates(kernel: dict) -> list[str]:
    candidates: list[str] = []
    for field in (kernel.get("name"), kernel.get("symbol")):
        if not field:
            continue
        value = str(field)
        for candidate in (get_instrumented_name(value), get_hidden_abi_instrumented_name(value)):
            if candidate not in candidates:
                candidates.append(candidate)
    return candidates


def find_clone_kernel(manifest: dict, source_kernel: dict, explicit: str | None) -> dict:
    kernels = kernel_records(manifest)
    if explicit:
        return select_kernels(manifest, explicit)[0]

    candidates = set(clone_name_candidates(source_kernel))
    for kernel in kernels:
        for field in (kernel.get("name"), kernel.get("symbol")):
            if field and str(field) in candidates:
                return kernel
    raise SystemExit(
        f"failed to find clone kernel for {source_kernel.get('symbol') or source_kernel.get('name')}"
    )


def symbol_records(manifest: dict) -> list[dict]:
    symbols = manifest.get("symbols", [])
    return [symbol for symbol in symbols if isinstance(symbol, dict)]


def func_symbol_map(manifest: dict) -> dict[str, dict]:
    return {
        str(symbol["name"]): symbol
        for symbol in symbol_records(manifest)
        if symbol.get("name") and str(symbol.get("type")) in {"FUNC", "Function"}
    }


def section_map(manifest: dict) -> dict[str, dict]:
    sections = manifest.get("sections", [])
    return {
        str(section["name"]): section
        for section in sections
        if isinstance(section, dict) and section.get("name")
    }


def normalize_instruction(line: str) -> str | None:
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.endswith(":") or stripped.startswith("/"):
        return None
    if stripped.startswith("Disassembly of section"):
        return None
    if stripped.startswith("file format"):
        return None
    if stripped[0].isdigit() and stripped.endswith(":"):
        return None
    match = INSTRUCTION_RE.match(line)
    if not match:
        return None
    mnemonic = match.group(1)
    operands = re.sub(r"\s+", " ", match.group(2).strip())
    return mnemonic if not operands else f"{mnemonic} {operands}"


def load_symbol_disassembly(objdump: str, code_object: Path, symbol_name: str, mcpu: str) -> list[str]:
    result = subprocess.run(
        [
            objdump,
            "--arch-name=amdgcn",
            f"--mcpu={mcpu}",
            f"--disassemble-symbols={symbol_name}",
            str(code_object),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    instructions: list[str] = []
    for line in result.stdout.splitlines():
        normalized = normalize_instruction(line)
        if normalized is not None:
            instructions.append(normalized)
    return instructions


def common_prefix_length(lhs: list[str], rhs: list[str]) -> int:
    count = 0
    for left, right in zip(lhs, rhs):
        if left != right:
            break
        count += 1
    return count


def common_suffix_length(lhs: list[str], rhs: list[str], prefix_len: int) -> int:
    lhs_tail = lhs[prefix_len:]
    rhs_tail = rhs[prefix_len:]
    count = 0
    for left, right in zip(reversed(lhs_tail), reversed(rhs_tail)):
        if left != right:
            break
        count += 1
    return count


def window(seq: list[str], start: int, end: int, limit: int = 24) -> list[str]:
    if start >= end:
        return []
    slice_ = seq[start:end]
    if len(slice_) <= limit:
        return slice_
    head = limit // 2
    tail = limit - head
    return slice_[:head] + ["..."] + slice_[-tail:]


def word_hex_list(blob: bytes) -> list[str]:
    if len(blob) % 4 != 0:
        raise SystemExit(f"expected 4-byte aligned instruction stream, got {len(blob)} bytes")
    return [blob[index : index + 4][::-1].hex() for index in range(0, len(blob), 4)]


def read_function_bytes(code_object: Path, manifest: dict, func_symbol: dict) -> bytes:
    text = section_map(manifest).get(".text")
    if text is None:
        raise SystemExit(".text section not found in manifest")

    value = int(func_symbol.get("value", 0))
    size = int(func_symbol.get("size", 0))
    text_addr = int(text.get("address", 0))
    text_offset = int(text.get("offset", 0))
    text_size = int(text.get("size", 0))
    if value < text_addr or value + size > text_addr + text_size:
        raise SystemExit(
            f"function {func_symbol.get('name')} does not lie fully inside .text"
        )

    start = text_offset + (value - text_addr)
    end = start + size
    data = code_object.read_bytes()
    return data[start:end]


def kernel_resource_diff(source_kernel: dict, clone_kernel: dict) -> dict[str, dict[str, int | None]]:
    diff: dict[str, dict[str, int | None]] = {}
    for field in RESOURCE_FIELDS:
        source_value = source_kernel.get(field)
        clone_value = clone_kernel.get(field)
        if source_value == clone_value:
            continue
        diff[field] = {
            "source": int(source_value) if isinstance(source_value, int) else source_value,
            "clone": int(clone_value) if isinstance(clone_value, int) else clone_value,
        }
    return diff


def added_symbol_names(reference_manifest: dict, carrier_manifest: dict, clone_kernel: dict) -> list[str]:
    reference_names = {str(symbol.get("name")) for symbol in symbol_records(reference_manifest) if symbol.get("name")}
    clone_candidates = set(clone_name_candidates(clone_kernel))
    clone_candidates.update(
        value
        for value in (clone_kernel.get("name"), clone_kernel.get("symbol"))
        if value
    )

    added: list[str] = []
    for symbol in symbol_records(carrier_manifest):
        name = symbol.get("name")
        if not name or str(name) in reference_names:
            continue
        if str(name).startswith("__hip_cuid_"):
            continue
        if str(name) in clone_candidates:
            continue
        if symbol.get("type") not in {"FUNC", "OBJECT"}:
            continue
        added.append(str(name))
    return sorted(set(added))


def analyze_recipe(
    carrier_path: Path,
    carrier_manifest: dict,
    source_kernel: dict,
    clone_kernel: dict,
    objdump: str,
    reference_manifest: dict | None,
) -> dict:
    target = str(carrier_manifest.get("kernels", {}).get("metadata", {}).get("target") or "")
    mcpu = target.rsplit("--", 1)[-1] if "--" in target else target
    if not mcpu:
        raise SystemExit("failed to determine target ISA/mcpu from carrier metadata")

    source_name = str(source_kernel.get("name") or source_kernel.get("symbol"))
    clone_name = str(clone_kernel.get("name") or clone_kernel.get("symbol"))
    source_dis = load_symbol_disassembly(objdump, carrier_path, source_name, mcpu)
    clone_dis = load_symbol_disassembly(objdump, carrier_path, clone_name, mcpu)
    prefix_len = common_prefix_length(source_dis, clone_dis)
    suffix_len = common_suffix_length(source_dis, clone_dis, prefix_len)
    source_changed_end = len(source_dis) - suffix_len
    clone_changed_end = len(clone_dis) - suffix_len

    carrier_funcs = func_symbol_map(carrier_manifest)
    source_func_symbol = carrier_funcs.get(source_name) or carrier_funcs.get(str(source_kernel.get("symbol")))
    clone_func_symbol = carrier_funcs.get(clone_name) or carrier_funcs.get(str(clone_kernel.get("symbol")))
    if source_func_symbol is None or clone_func_symbol is None:
        raise SystemExit("failed to resolve function symbols for source or clone kernel")

    source_bytes = read_function_bytes(carrier_path, carrier_manifest, source_func_symbol)
    clone_bytes = read_function_bytes(carrier_path, carrier_manifest, clone_func_symbol)
    source_words = word_hex_list(source_bytes)
    clone_words = word_hex_list(clone_bytes)
    word_prefix_len = common_prefix_length(source_words, clone_words)
    word_suffix_len = common_suffix_length(source_words, clone_words, word_prefix_len)
    source_word_changed_end = len(source_words) - word_suffix_len
    clone_word_changed_end = len(clone_words) - word_suffix_len

    result = {
        "carrier": str(carrier_path),
        "target": target,
        "source_kernel": {
            "name": source_kernel.get("name"),
            "symbol": source_kernel.get("symbol"),
            "func_size": source_func_symbol.get("size") if source_func_symbol else None,
        },
        "clone_kernel": {
            "name": clone_kernel.get("name"),
            "symbol": clone_kernel.get("symbol"),
            "func_size": clone_func_symbol.get("size") if clone_func_symbol else None,
        },
        "resource_diff": kernel_resource_diff(source_kernel, clone_kernel),
        "instruction_alignment": {
            "source_count": len(source_dis),
            "clone_count": len(clone_dis),
            "common_prefix": prefix_len,
            "common_suffix": suffix_len,
            "source_changed_window": {
                "start": prefix_len,
                "end": source_changed_end,
                "instructions": window(source_dis, prefix_len, source_changed_end),
            },
            "clone_changed_window": {
                "start": prefix_len,
                "end": clone_changed_end,
                "instructions": window(clone_dis, prefix_len, clone_changed_end),
            },
        },
        "byte_alignment": {
            "source_size": len(source_bytes),
            "clone_size": len(clone_bytes),
            "common_prefix_words": word_prefix_len,
            "common_suffix_words": word_suffix_len,
            "source_changed_words": {
                "start": word_prefix_len,
                "end": source_word_changed_end,
                "hex_words": window(source_words, word_prefix_len, source_word_changed_end),
            },
            "clone_changed_words": {
                "start": word_prefix_len,
                "end": clone_word_changed_end,
                "hex_words": window(clone_words, word_prefix_len, clone_word_changed_end),
            },
        },
    }
    if reference_manifest is not None:
        result["added_symbols_vs_reference"] = added_symbol_names(
            reference_manifest,
            carrier_manifest,
            clone_kernel,
        )
    return result


def render_report(recipe: dict) -> str:
    lines = [
        f"carrier: {recipe['carrier']}",
        f"target: {recipe['target']}",
        f"source: {recipe['source_kernel']['name']} ({recipe['source_kernel']['symbol']})",
        f"clone: {recipe['clone_kernel']['name']} ({recipe['clone_kernel']['symbol']})",
    ]
    if recipe["source_kernel"].get("func_size") is not None or recipe["clone_kernel"].get("func_size") is not None:
        lines.append(
            "function sizes: source={} clone={}".format(
                recipe["source_kernel"].get("func_size"),
                recipe["clone_kernel"].get("func_size"),
            )
        )

    resource_diff = recipe["resource_diff"]
    if resource_diff:
        lines.append("resource deltas:")
        for field, values in resource_diff.items():
            lines.append(f"  {field}: {values['source']} -> {values['clone']}")
    else:
        lines.append("resource deltas: none")

    align = recipe["instruction_alignment"]
    lines.append(
        "instruction alignment: source_count={} clone_count={} common_prefix={} common_suffix={}".format(
            align["source_count"],
            align["clone_count"],
            align["common_prefix"],
            align["common_suffix"],
        )
    )
    lines.append(
        "source changed window [{}:{}]:".format(
            align["source_changed_window"]["start"],
            align["source_changed_window"]["end"],
        )
    )
    for line in align["source_changed_window"]["instructions"]:
        lines.append(f"  {line}")
    lines.append(
        "clone changed window [{}:{}]:".format(
            align["clone_changed_window"]["start"],
            align["clone_changed_window"]["end"],
        )
    )
    for line in align["clone_changed_window"]["instructions"]:
        lines.append(f"  {line}")

    byte_align = recipe["byte_alignment"]
    lines.append(
        "byte alignment: source_size={} clone_size={} common_prefix_words={} common_suffix_words={}".format(
            byte_align["source_size"],
            byte_align["clone_size"],
            byte_align["common_prefix_words"],
            byte_align["common_suffix_words"],
        )
    )
    lines.append(
        "source changed words [{}:{}]:".format(
            byte_align["source_changed_words"]["start"],
            byte_align["source_changed_words"]["end"],
        )
    )
    for word in byte_align["source_changed_words"]["hex_words"]:
        lines.append(f"  {word}")
    lines.append(
        "clone changed words [{}:{}]:".format(
            byte_align["clone_changed_words"]["start"],
            byte_align["clone_changed_words"]["end"],
        )
    )
    for word in byte_align["clone_changed_words"]["hex_words"]:
        lines.append(f"  {word}")

    added = recipe.get("added_symbols_vs_reference")
    if added is not None:
        lines.append("added symbols vs reference:")
        if added:
            lines.extend(f"  {name}" for name in added)
        else:
            lines.append("  none")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    carrier_path = Path(args.carrier).resolve()
    if not carrier_path.exists():
        raise SystemExit(f"carrier '{carrier_path}' not found")

    readelf = detect_llvm_tool("llvm-readelf", args.llvm_readelf)
    objdump = detect_llvm_tool("llvm-objdump", args.llvm_objdump)
    carrier_manifest = load_manifest(carrier_path, readelf)
    source_kernel = select_kernels(carrier_manifest, args.kernel)[0]
    clone_kernel = find_clone_kernel(carrier_manifest, source_kernel, args.clone)

    reference_manifest = None
    if args.reference:
        reference_manifest = load_manifest(Path(args.reference).resolve(), readelf)

    recipe = analyze_recipe(
        carrier_path,
        carrier_manifest,
        source_kernel,
        clone_kernel,
        objdump,
        reference_manifest,
    )
    if args.json:
        json.dump(recipe, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_report(recipe))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
