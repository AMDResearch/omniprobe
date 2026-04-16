#!/usr/bin/env python3
from __future__ import annotations

import re
from typing import Any


SCALAR_REG_RE = re.compile(r"^s(\d+)$")
SCALAR_REG_PAIR_RE = re.compile(r"^s\[(\d+):(\d+)\]$")
VECTOR_REG_RE = re.compile(r"^v(\d+)$")

DWORD_TYPES = {
    "bool",
    "u8",
    "u16",
    "u32",
    "i8",
    "i16",
    "i32",
    "uint8_t",
    "uint16_t",
    "uint32_t",
    "int8_t",
    "int16_t",
    "int32_t",
}
QWORD_TYPES = {
    "u64",
    "i64",
    "uint64_t",
    "int64_t",
    "uintptr_t",
    "intptr_t",
    "size_t",
    "ptrdiff_t",
}


def parse_scalar_reg(operand: str) -> int | None:
    match = SCALAR_REG_RE.fullmatch(operand.strip())
    return int(match.group(1)) if match else None


def parse_scalar_reg_pair(operand: str) -> tuple[int, int] | None:
    match = SCALAR_REG_PAIR_RE.fullmatch(operand.strip())
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def parse_vector_reg(operand: str) -> int | None:
    match = VECTOR_REG_RE.fullmatch(operand.strip())
    return int(match.group(1)) if match else None


def descriptor_enables_kernarg_segment_ptr(descriptor: dict[str, Any] | None) -> bool:
    if not isinstance(descriptor, dict):
        return False
    properties = descriptor.get("kernel_code_properties", {})
    if not isinstance(properties, dict):
        return False
    return bool(properties.get("enable_sgpr_kernarg_segment_ptr", 0))


def descriptor_allocated_vgpr_count(descriptor: dict[str, Any] | None) -> int | None:
    if not isinstance(descriptor, dict):
        return None
    granulated = descriptor.get("compute_pgm_rsrc1", {}).get("granulated_workitem_vgpr_count")
    if isinstance(granulated, int):
        return (granulated + 1) * 8
    return None


def descriptor_allocated_sgpr_count(descriptor: dict[str, Any] | None) -> int | None:
    if not isinstance(descriptor, dict):
        return None
    granulated = descriptor.get("compute_pgm_rsrc1", {}).get("granulated_wavefront_sgpr_count")
    if isinstance(granulated, int):
        return (granulated + 1) * 8
    return None


def call_argument_dword_count(
    *,
    explicit_type: str | None = None,
    size_bytes: int | None = None,
) -> int:
    normalized = explicit_type.strip() if isinstance(explicit_type, str) else None
    if normalized:
        if normalized in DWORD_TYPES:
            return 1
        if normalized in QWORD_TYPES or "*" in normalized:
            return 2
    if size_bytes in {1, 2, 4}:
        return 1
    if size_bytes == 8:
        return 2
    raise ValueError(
        f"unsupported call argument width: explicit_type={explicit_type!r}, size_bytes={size_bytes!r}"
    )


def layout_call_arguments(arguments: list[dict[str, Any]]) -> dict[str, Any]:
    layout: list[dict[str, Any]] = []
    next_vgpr = 0
    for argument in arguments:
        dword_count = call_argument_dword_count(
            explicit_type=argument.get("c_type"),
            size_bytes=argument.get("size_bytes"),
        )
        vgprs = list(range(next_vgpr, next_vgpr + dword_count))
        next_vgpr += dword_count
        entry = dict(argument)
        entry["dword_count"] = dword_count
        entry["vgprs"] = vgprs
        layout.append(entry)
    return {
        "arguments": layout,
        "total_dwords": next_vgpr,
        "max_vgpr": (next_vgpr - 1) if next_vgpr else -1,
    }


def _is_zero_like_offset(operand: str) -> bool:
    normalized = operand.strip().lower()
    return normalized in {"0", "0x0", "null", "0.0"}


def infer_kernarg_base_pair(function: dict[str, Any], max_scan_instructions: int = 32) -> dict[str, Any] | None:
    instructions = function.get("instructions", [])
    for index, instruction in enumerate(instructions[:max_scan_instructions]):
        mnemonic = str(instruction.get("mnemonic", ""))
        if not mnemonic.startswith("s_load_dword"):
            continue
        operands = instruction.get("operands", [])
        if len(operands) < 3:
            continue
        base_pair = parse_scalar_reg_pair(str(operands[1]))
        if base_pair is None:
            continue
        if not _is_zero_like_offset(str(operands[2])):
            continue
        return {
            "instruction_index": index,
            "instruction_address": instruction.get("address"),
            "mnemonic": mnemonic,
            "base_pair": [base_pair[0], base_pair[1]],
            "operands": operands,
        }
    return None


def infer_lifecycle_call_sequence(function: dict[str, Any], search_window: int = 16) -> dict[str, Any] | None:
    instructions = function.get("instructions", [])
    for index, instruction in enumerate(instructions):
        if instruction.get("mnemonic") != "s_swappc_b64":
            continue
        operands = instruction.get("operands", [])
        if len(operands) != 2:
            continue
        return_pair = parse_scalar_reg_pair(str(operands[0]))
        target_pair = parse_scalar_reg_pair(str(operands[1]))
        if return_pair is None or target_pair is None:
            continue

        marshalling: dict[int, int] = {}
        marshalling_addresses: dict[int, int] = {}
        start = max(0, index - search_window)
        for candidate in instructions[start:index]:
            if candidate.get("mnemonic") != "v_mov_b32_e32":
                continue
            candidate_operands = candidate.get("operands", [])
            if len(candidate_operands) != 2:
                continue
            dst = parse_vector_reg(str(candidate_operands[0]))
            src = parse_scalar_reg(str(candidate_operands[1]))
            if dst is None or src is None:
                continue
            if 0 <= dst <= 5:
                marshalling[dst] = src
                marshalling_addresses[dst] = int(candidate.get("address", 0) or 0)

        if not all(slot in marshalling for slot in range(6)):
            continue

        arg_pairs = []
        for arg_index in range(3):
            low_vgpr = arg_index * 2
            high_vgpr = low_vgpr + 1
            arg_pairs.append(
                {
                    "arg_index": arg_index,
                    "vgpr_pair": [low_vgpr, high_vgpr],
                    "source_sgpr_pair": [marshalling[low_vgpr], marshalling[high_vgpr]],
                    "marshall_addresses": [
                        marshalling_addresses[low_vgpr],
                        marshalling_addresses[high_vgpr],
                    ],
                }
            )
        return {
            "instruction_index": index,
            "instruction_address": instruction.get("address"),
            "call_kind": "s_swappc_b64",
            "return_pair": [return_pair[0], return_pair[1]],
            "target_pair": [target_pair[0], target_pair[1]],
            "arg_pairs": arg_pairs,
        }
    return None


def synthesize_lifecycle_call_sequence(kernarg_base: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(kernarg_base, dict):
        return None
    base_pair = kernarg_base.get("base_pair")
    if not isinstance(base_pair, list) or len(base_pair) != 2:
        return None

    base_low = int(base_pair[0])
    runtime_low = base_low + 4
    timestamp_low = base_low + 8
    target_low = base_low + 10
    return {
        "instruction_index": None,
        "instruction_address": None,
        "call_kind": "synthetic_s_swappc_b64",
        "return_pair": [30, 31],
        "target_pair": [target_low, target_low + 1],
        "arg_pairs": [
            {
                "arg_index": 0,
                "vgpr_pair": [0, 1],
                "source_sgpr_pair": [runtime_low, runtime_low + 1],
                "marshall_addresses": [],
            },
            {
                "arg_index": 1,
                "vgpr_pair": [2, 3],
                "source_sgpr_pair": [int(base_pair[0]), int(base_pair[1])],
                "marshall_addresses": [],
            },
            {
                "arg_index": 2,
                "vgpr_pair": [4, 5],
                "source_sgpr_pair": [timestamp_low, timestamp_low + 1],
                "marshall_addresses": [],
            },
        ],
    }


def analyze_kernel_calling_convention(
    *,
    function: dict[str, Any],
    descriptor: dict[str, Any] | None,
) -> dict[str, Any]:
    kernarg_base = infer_kernarg_base_pair(function)
    observed_lifecycle_call = infer_lifecycle_call_sequence(function)
    resolved_lifecycle_call = observed_lifecycle_call or synthesize_lifecycle_call_sequence(
        kernarg_base
    )
    return {
        "function": function.get("name"),
        "descriptor_has_kernarg_segment_ptr": descriptor_enables_kernarg_segment_ptr(descriptor),
        "inferred_kernarg_base": kernarg_base,
        "observed_lifecycle_call": observed_lifecycle_call,
        "resolved_lifecycle_call": resolved_lifecycle_call,
        "lifecycle_call_source": "observed" if observed_lifecycle_call is not None else (
            "synthetic_from_kernarg_base" if resolved_lifecycle_call is not None else None
        ),
        "supported_for_lifecycle_exit_stub": bool(
            descriptor_enables_kernarg_segment_ptr(descriptor)
            and kernarg_base is not None
            and resolved_lifecycle_call is not None
        ),
    }
