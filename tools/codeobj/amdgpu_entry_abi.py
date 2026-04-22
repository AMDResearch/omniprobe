#!/usr/bin/env python3
from __future__ import annotations

import re
from typing import Any

from amdgpu_calling_convention import (
    descriptor_allocated_sgpr_count,
    descriptor_allocated_vgpr_count,
    descriptor_enables_kernarg_segment_ptr,
    infer_kernarg_base_pair,
    parse_scalar_reg,
    parse_scalar_reg_pair,
)


SCALAR_REG_RANGE_RE = re.compile(r"^s\[(\d+):(\d+)\]$")


def _instruction_detail(instruction: dict[str, Any], index: int) -> dict[str, Any]:
    return {
        "instruction_index": index,
        "instruction_address": instruction.get("address"),
        "mnemonic": instruction.get("mnemonic"),
        "operand_text": instruction.get("operand_text", ""),
        "operands": instruction.get("operands", []),
    }


def _parse_scalar_reg_range(operand: str) -> tuple[int, int] | None:
    match = SCALAR_REG_RANGE_RE.fullmatch(operand.strip())
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def _parse_int_operand(operand: str) -> int | None:
    text = operand.strip().lower()
    if text.startswith("-0x"):
        try:
            return -int(text[3:], 16)
        except ValueError:
            return None
    if text.startswith("0x"):
        try:
            return int(text, 16)
        except ValueError:
            return None
    try:
        return int(text, 10)
    except ValueError:
        return None


def _operand_mentions_sgpr(operand: str, sgpr: int) -> bool:
    parsed = parse_scalar_reg(operand)
    if parsed is not None:
        return parsed == sgpr
    parsed_range = _parse_scalar_reg_range(operand)
    if parsed_range is not None:
        return parsed_range[0] <= sgpr <= parsed_range[1]
    return False


def _write_only_scalar_def(instruction: dict[str, Any]) -> list[int]:
    mnemonic = str(instruction.get("mnemonic", "") or "")
    operands = instruction.get("operands", [])
    if not isinstance(operands, list) or not operands:
        return []

    if mnemonic in {"s_mov_b32", "s_movk_i32"}:
        dst = parse_scalar_reg(str(operands[0]))
        return [dst] if dst is not None else []

    if mnemonic in {"s_mov_b64", "s_getpc_b64"}:
        dst_pair = parse_scalar_reg_pair(str(operands[0]))
        if dst_pair is not None:
            return [dst_pair[0], dst_pair[1]]
    return []


def observe_entry_dead_sgpr_pairs(
    function: dict[str, Any],
    descriptor: dict[str, Any] | None,
    search_window: int = 32,
) -> list[dict[str, Any]]:
    instructions = function.get("instructions", [])
    if not isinstance(instructions, list):
        return []

    liveins = set(entry_livein_sgprs(descriptor))
    first_access: dict[int, dict[str, Any]] = {}
    candidates: list[dict[str, Any]] = []

    for index, instruction in enumerate(instructions[:search_window]):
        detail = _instruction_detail(instruction, index)
        def_regs = _write_only_scalar_def(instruction)

        for reg in def_regs:
            if reg in first_access:
                continue
            first_access[reg] = {"kind": "write_only_def", "detail": detail}

        operands = instruction.get("operands", [])
        if not isinstance(operands, list):
            continue
        mentioned: set[int] = set()
        for operand_index, operand in enumerate(operands):
            text = str(operand)
            pair = parse_scalar_reg_pair(text)
            if pair is not None:
                mentioned.update(range(pair[0], pair[1] + 1))
                continue
            scalar = parse_scalar_reg(text)
            if scalar is not None:
                mentioned.add(scalar)
        for reg in sorted(mentioned):
            if reg in def_regs:
                continue
            if reg in first_access:
                continue
            first_access[reg] = {"kind": "read_or_readwrite", "detail": detail}

    sorted_regs = sorted(reg for reg, record in first_access.items() if record["kind"] == "write_only_def")
    for reg in sorted_regs:
        if reg % 2 != 0:
            continue
        mate = reg + 1
        if mate not in first_access:
            continue
        if first_access[mate]["kind"] != "write_only_def":
            continue
        if reg in liveins or mate in liveins:
            continue
        lo_detail = first_access[reg]["detail"]
        hi_detail = first_access[mate]["detail"]
        candidates.append(
            {
                "pair": [reg, mate],
                "registers": [reg, mate],
                "first_def_instruction_indices": [
                    lo_detail["instruction_index"],
                    hi_detail["instruction_index"],
                ],
                "first_def_instruction_addresses": [
                    lo_detail["instruction_address"],
                    hi_detail["instruction_address"],
                ],
                "first_def_operand_texts": [
                    lo_detail["operand_text"],
                    hi_detail["operand_text"],
                ],
            }
        )
    return candidates


def entry_livein_sgprs(descriptor: dict[str, Any] | None) -> list[int]:
    if not isinstance(descriptor, dict):
        return []
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {})
    if not isinstance(rsrc2, dict):
        return []
    user_sgpr_count = rsrc2.get("user_sgpr_count")
    if not isinstance(user_sgpr_count, int) or user_sgpr_count < 0:
        return []
    liveins = list(range(user_sgpr_count))
    cursor = user_sgpr_count
    for key in (
        "enable_sgpr_workgroup_id_x",
        "enable_sgpr_workgroup_id_y",
        "enable_sgpr_workgroup_id_z",
        "enable_sgpr_workgroup_info",
        "enable_private_segment",
    ):
        if int(rsrc2.get(key, 0) or 0):
            liveins.append(cursor)
            cursor += 1
    return liveins


def entry_system_sgpr_roles(descriptor: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(descriptor, dict):
        return []
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {})
    if not isinstance(rsrc2, dict):
        return []
    user_sgpr_count = rsrc2.get("user_sgpr_count")
    if not isinstance(user_sgpr_count, int) or user_sgpr_count < 0:
        return []
    cursor = user_sgpr_count
    roles: list[dict[str, Any]] = []
    for key, role in (
        ("enable_sgpr_workgroup_id_x", "workgroup_id_x"),
        ("enable_sgpr_workgroup_id_y", "workgroup_id_y"),
        ("enable_sgpr_workgroup_id_z", "workgroup_id_z"),
        ("enable_sgpr_workgroup_info", "workgroup_info"),
        ("enable_private_segment", "private_segment_wave_offset"),
    ):
        if int(rsrc2.get(key, 0) or 0):
            roles.append({"role": role, "sgpr": cursor})
            cursor += 1
    return roles


def infer_entry_workitem_vgpr_count(descriptor: dict[str, Any] | None) -> int:
    if not isinstance(descriptor, dict):
        return 0
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {})
    if not isinstance(rsrc2, dict):
        return 0
    encoded = rsrc2.get("enable_vgpr_workitem_id")
    if not isinstance(encoded, int) or encoded < 0:
        return 0
    return min(encoded + 1, 3)


def observe_entry_system_sgpr_uses(
    function: dict[str, Any],
    system_roles: list[dict[str, Any]],
    search_window: int = 32,
) -> list[dict[str, Any]]:
    instructions = function.get("instructions", [])
    if not isinstance(instructions, list):
        return []
    observations: list[dict[str, Any]] = []
    for role_entry in system_roles:
        role = role_entry.get("role")
        sgpr = role_entry.get("sgpr")
        if not isinstance(role, str) or not isinstance(sgpr, int):
            continue
        matches: list[dict[str, Any]] = []
        for index, instruction in enumerate(instructions[:search_window]):
            operands = instruction.get("operands", [])
            if not isinstance(operands, list):
                continue
            if any(_operand_mentions_sgpr(str(operand), sgpr) for operand in operands):
                matches.append(_instruction_detail(instruction, index))
        observations.append({"role": role, "sgpr": sgpr, "uses": matches})
    return observations


def observe_workitem_id_materialization(
    function: dict[str, Any],
    workitem_vgpr_count: int,
    search_window: int = 32,
) -> dict[str, Any] | None:
    instructions = function.get("instructions", [])
    if not isinstance(instructions, list) or workitem_vgpr_count <= 0:
        return None

    packed_y: dict[str, Any] | None = None
    packed_z: dict[str, Any] | None = None
    packed_x: dict[str, Any] | None = None
    direct_uses: list[dict[str, Any]] = []

    tracked_workitem_vgprs = {
        f"v{vgpr}" for vgpr in range(max(0, workitem_vgpr_count))
    }

    for index, instruction in enumerate(instructions[:search_window]):
        mnemonic = str(instruction.get("mnemonic", "") or "")
        operands = [str(value) for value in instruction.get("operands", [])]
        detail = _instruction_detail(instruction, index)

        if mnemonic == "v_bfe_u32" and len(operands) == 4 and operands[1] == "v0":
            shift = _parse_int_operand(operands[2])
            width = _parse_int_operand(operands[3])
            if shift == 10 and width == 10 and packed_y is None:
                packed_y = detail
            if shift == 20 and width == 10 and packed_z is None:
                packed_z = detail
        if mnemonic == "v_and_b32_e32" and len(operands) == 3 and operands[2] == "v0":
            if _parse_int_operand(operands[1]) == 0x3FF and packed_x is None:
                packed_x = detail
        if mnemonic.startswith("v_") and any(
            operand in tracked_workitem_vgprs for operand in operands[1:]
        ):
            direct_uses.append(detail)

    if workitem_vgpr_count >= 3 and packed_x and packed_y and packed_z:
        return {
            "pattern_class": "packed_v0_10_10_10_unpack",
            "details": {
                "packed_x_mask": packed_x,
                "packed_y_extract": packed_y,
                "packed_z_extract": packed_z,
            },
        }
    if workitem_vgpr_count >= 3 and direct_uses:
        return {
            "pattern_class": "direct_vgpr_xyz",
            "details": {
                "first_direct_uses": direct_uses[:4],
            },
        }
    if workitem_vgpr_count == 1:
        return {"pattern_class": "single_vgpr_workitem_id", "details": {}}
    if workitem_vgpr_count == 2:
        return {"pattern_class": "two_vgpr_workitem_id", "details": {}}
    return None


def observe_private_segment_materialization(
    function: dict[str, Any],
    search_window: int = 48,
) -> dict[str, Any] | None:
    instructions = function.get("instructions", [])
    if not isinstance(instructions, list):
        return None

    setreg_lo: dict[str, Any] | None = None
    setreg_hi: dict[str, Any] | None = None
    alias_lo: dict[str, Any] | None = None
    alias_hi: dict[str, Any] | None = None
    src_private_base: dict[str, Any] | None = None
    pair_updates: list[dict[str, Any]] = []

    window = instructions[:search_window]
    for index, instruction in enumerate(window):
        mnemonic = str(instruction.get("mnemonic", "") or "")
        operands = [str(value) for value in instruction.get("operands", [])]
        detail = _instruction_detail(instruction, index)

        if mnemonic == "s_setreg_b32" and len(operands) == 2:
            if operands[0] == "hwreg(HW_REG_FLAT_SCR_LO)" and setreg_lo is None:
                setreg_lo = detail
            if operands[0] == "hwreg(HW_REG_FLAT_SCR_HI)" and setreg_hi is None:
                setreg_hi = detail
            continue

        if mnemonic == "s_add_u32" and len(operands) == 3 and operands[0] == "flat_scratch_lo" and alias_lo is None:
            alias_lo = detail
            continue

        if mnemonic == "s_addc_u32" and len(operands) == 3 and operands[0] == "flat_scratch_hi" and alias_hi is None:
            alias_hi = detail
            continue

        if mnemonic == "s_mov_b64" and len(operands) == 2 and operands[1] == "src_private_base" and src_private_base is None:
            pair = parse_scalar_reg_pair(operands[0])
            src_private_base = {
                **detail,
                "pair": [pair[0], pair[1]] if pair is not None else None,
            }
            continue

        if mnemonic != "s_add_u32" or len(operands) != 3:
            continue
        dst = parse_scalar_reg(operands[0])
        src0 = parse_scalar_reg(operands[1])
        offset_sgpr = parse_scalar_reg(operands[2])
        if dst is None or src0 != dst or offset_sgpr is None:
            continue
        if index + 1 >= len(window):
            continue

        next_instruction = window[index + 1]
        next_mnemonic = str(next_instruction.get("mnemonic", "") or "")
        next_operands = [str(value) for value in next_instruction.get("operands", [])]
        if next_mnemonic != "s_addc_u32" or len(next_operands) != 3:
            continue
        next_dst = parse_scalar_reg(next_operands[0])
        next_src0 = parse_scalar_reg(next_operands[1])
        if next_dst != dst + 1 or next_src0 != dst + 1:
            continue
        if _parse_int_operand(next_operands[2]) != 0:
            continue

        pair_updates.append(
            {
                "pair": [dst, dst + 1],
                "offset_sgpr": offset_sgpr,
                "lo_instruction": detail,
                "hi_instruction": _instruction_detail(next_instruction, index + 1),
            }
        )

    if alias_lo is not None and alias_hi is not None:
        return {
            "pattern_class": "flat_scratch_alias_init",
            "details": {
                "flat_scratch_lo": alias_lo,
                "flat_scratch_hi": alias_hi,
                "pair_updates": pair_updates,
                "src_private_base": src_private_base,
            },
        }
    if setreg_lo is not None and setreg_hi is not None:
        return {
            "pattern_class": "setreg_flat_scratch_init",
            "details": {
                "flat_scratch_lo": setreg_lo,
                "flat_scratch_hi": setreg_hi,
                "pair_updates": pair_updates,
                "src_private_base": src_private_base,
            },
        }
    if src_private_base is not None:
        return {
            "pattern_class": "src_private_base",
            "details": {
                "src_private_base": src_private_base,
                "pair_updates": pair_updates,
            },
        }
    if pair_updates:
        return {
            "pattern_class": "scalar_pair_update_only",
            "details": {"pair_updates": pair_updates},
        }
    return None


def summarize_current_entry_stub_support(
    *,
    descriptor: dict[str, Any] | None,
    kernarg_base: dict[str, Any] | None,
    workitem_materialization: dict[str, Any] | None,
    private_materialization: dict[str, Any] | None,
) -> dict[str, Any]:
    reasons: list[str] = []

    if not descriptor_enables_kernarg_segment_ptr(descriptor):
        reasons.append("missing_kernarg_segment_ptr")
    if kernarg_base is None:
        reasons.append("kernarg_base_not_observed")

    workitem_pattern = (
        str(workitem_materialization.get("pattern_class"))
        if isinstance(workitem_materialization, dict)
        else None
    )
    if workitem_pattern not in {
        "direct_vgpr_xyz",
        "packed_v0_10_10_10_unpack",
        "single_vgpr_workitem_id",
        None,
    }:
        reasons.append("unrecognized_workitem_id_materialization")

    rsrc2 = descriptor.get("compute_pgm_rsrc2", {}) if isinstance(descriptor, dict) else {}
    if int(rsrc2.get("enable_private_segment", 0) or 0):
        private_pattern = (
            str(private_materialization.get("pattern_class"))
            if isinstance(private_materialization, dict)
            else None
        )
        if private_pattern not in {
            "setreg_flat_scratch_init",
            "flat_scratch_alias_init",
            "src_private_base",
            "scalar_pair_update_only",
        }:
            reasons.append("unrecognized_private_segment_materialization")

    return {
        "supported": not reasons,
        "reasons": reasons,
        "assumptions": {
            "workitem_preservation_policy": "spill_original_entry_vgprs",
            "expected_packed_workitem_encoding": "10_10_10",
            "scratch_spill_requires_private_segment_pattern": True,
        },
    }


def analyze_kernel_entry_abi(
    *,
    function: dict[str, Any],
    descriptor: dict[str, Any] | None,
    kernel_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    wavefront_size = None
    if isinstance(kernel_metadata, dict):
        raw_wavefront_size = kernel_metadata.get("wavefront_size")
        if isinstance(raw_wavefront_size, int):
            wavefront_size = raw_wavefront_size
    if wavefront_size is None and isinstance(descriptor, dict):
        properties = descriptor.get("kernel_code_properties", {})
        if isinstance(properties, dict):
            wavefront_size = 32 if int(properties.get("enable_wavefront_size32", 0) or 0) else 64

    entry_liveins = entry_livein_sgprs(descriptor)
    system_roles = entry_system_sgpr_roles(descriptor)
    workitem_vgpr_count = infer_entry_workitem_vgpr_count(descriptor)
    private_materialization = observe_private_segment_materialization(function)
    kernarg_base = infer_kernarg_base_pair(function)
    system_sgpr_uses = observe_entry_system_sgpr_uses(function, system_roles)
    workitem_materialization = observe_workitem_id_materialization(function, workitem_vgpr_count)
    dead_sgpr_pairs = observe_entry_dead_sgpr_pairs(function, descriptor)
    current_stub_support = summarize_current_entry_stub_support(
        descriptor=descriptor,
        kernarg_base=kernarg_base,
        workitem_materialization=workitem_materialization,
        private_materialization=private_materialization,
    )

    return {
        "function": function.get("name"),
        "descriptor_has_kernarg_segment_ptr": descriptor_enables_kernarg_segment_ptr(descriptor),
        "allocated_sgpr_count": descriptor_allocated_sgpr_count(descriptor),
        "allocated_vgpr_count": descriptor_allocated_vgpr_count(descriptor),
        "wavefront_size": wavefront_size,
        "private_segment_fixed_size": (
            int(descriptor.get("private_segment_fixed_size", 0) or 0)
            if isinstance(descriptor, dict)
            else None
        ),
        "entry_livein_sgprs": entry_liveins,
        "entry_system_sgpr_roles": system_roles,
        "observed_entry_system_sgpr_uses": system_sgpr_uses,
        "entry_workitem_vgpr_count": workitem_vgpr_count,
        "inferred_kernarg_base": kernarg_base,
        "observed_workitem_id_materialization": workitem_materialization,
        "observed_private_segment_materialization": private_materialization,
        "entry_dead_sgpr_pair_candidates": dead_sgpr_pairs,
        "current_entry_stub_support": current_stub_support,
        "supported_for_current_entry_stub": bool(current_stub_support["supported"]),
    }
