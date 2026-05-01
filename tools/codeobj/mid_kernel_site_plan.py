#!/usr/bin/env python3
from __future__ import annotations

import re
from copy import deepcopy
from typing import Any

from amdgpu_calling_convention import (
    parse_scalar_reg,
    parse_scalar_reg_pair,
    parse_vector_reg,
)
from disasm_to_ir import build_basic_blocks, classify_control_flow

VECTOR_REG_RANGE_RE = re.compile(r"^v\[(\d+):(\d+)\]$")
ACC_REG_RE = re.compile(r"^a(\d+)$")
ACC_REG_RANGE_RE = re.compile(r"^a\[(\d+):(\d+)\]$")

SITE_STATE_SCHEMA = "omniprobe.site_state_requirements.v1"
SITE_RESUME_PLAN_SCHEMA = "omniprobe.site_resume_plan.v1"

SPECIAL_REG_ALIASES = {
    "exec": "exec",
    "exec_lo": "exec",
    "exec_hi": "exec",
    "vcc": "vcc",
    "vcc_lo": "vcc",
    "vcc_hi": "vcc",
    "m0": "m0",
    "scc": "scc",
    "flat_scratch_lo": "flat_scratch",
    "flat_scratch_hi": "flat_scratch",
}

SPECIAL_ORDER = [
    "s30:s31",
    "exec",
    "vcc",
    "m0",
    "scc",
    "flat_scratch",
]

LOAD_PREFIXES = (
    "flat_load",
    "global_load",
    "buffer_load",
    "image_load",
    "ds_load",
    "ds_read",
    "scratch_load",
    "s_load_dword",
)

STORE_PREFIXES = (
    "flat_store",
    "global_store",
    "buffer_store",
    "image_store",
    "ds_store",
    "ds_write",
    "scratch_store",
)

SCALAR_SCC_PREFIXES = (
    "s_add",
    "s_sub",
    "s_mul",
    "s_and",
    "s_or",
    "s_xor",
    "s_lshl",
    "s_lshr",
    "s_ashr",
    "s_bfe",
    "s_bfm",
)


def empty_reg_state() -> dict[str, set[Any]]:
    return {
        "sgprs": set(),
        "vgprs": set(),
        "accvgprs": set(),
        "special": set(),
    }


def clone_reg_state(values: dict[str, set[Any]]) -> dict[str, set[Any]]:
    return {
        "sgprs": set(values["sgprs"]),
        "vgprs": set(values["vgprs"]),
        "accvgprs": set(values["accvgprs"]),
        "special": set(values["special"]),
    }


def merge_reg_state(dst: dict[str, set[Any]], src: dict[str, set[Any]]) -> None:
    for key in ("sgprs", "vgprs", "accvgprs", "special"):
        dst[key].update(src[key])


def reg_state_difference(
    lhs: dict[str, set[Any]],
    rhs: dict[str, set[Any]],
) -> dict[str, set[Any]]:
    result = empty_reg_state()
    for key in ("sgprs", "vgprs", "accvgprs", "special"):
        result[key] = set(lhs[key] - rhs[key])
    return result


def reg_state_equal(lhs: dict[str, set[Any]], rhs: dict[str, set[Any]]) -> bool:
    return all(lhs[key] == rhs[key] for key in ("sgprs", "vgprs", "accvgprs", "special"))


def parse_vector_reg_range(operand: str) -> list[int]:
    match = VECTOR_REG_RANGE_RE.fullmatch(str(operand or "").strip())
    if not match:
        return []
    start = int(match.group(1))
    end = int(match.group(2))
    if end < start:
        return []
    return list(range(start, end + 1))


def parse_acc_reg(operand: str) -> int | None:
    match = ACC_REG_RE.fullmatch(str(operand or "").strip())
    return int(match.group(1)) if match else None


def parse_acc_reg_range(operand: str) -> list[int]:
    match = ACC_REG_RANGE_RE.fullmatch(str(operand or "").strip())
    if not match:
        return []
    start = int(match.group(1))
    end = int(match.group(2))
    if end < start:
        return []
    return list(range(start, end + 1))


def operand_reg_state(operand: str) -> dict[str, set[Any]]:
    result = empty_reg_state()
    operand_text = str(operand or "").strip()
    pair = parse_scalar_reg_pair(operand_text)
    if pair is not None:
        result["sgprs"].update(range(pair[0], pair[1] + 1))
        return result

    scalar = parse_scalar_reg(operand_text)
    if scalar is not None:
        result["sgprs"].add(scalar)
        return result

    vector_range = parse_vector_reg_range(operand_text)
    if vector_range:
        result["vgprs"].update(vector_range)
        return result

    vector = parse_vector_reg(operand_text)
    if vector is not None:
        result["vgprs"].add(vector)
        return result

    acc_range = parse_acc_reg_range(operand_text)
    if acc_range:
        result["accvgprs"].update(acc_range)
        return result

    acc = parse_acc_reg(operand_text)
    if acc is not None:
        result["accvgprs"].add(acc)
        return result

    special = SPECIAL_REG_ALIASES.get(operand_text)
    if special is not None:
        result["special"].add(special)
    return result


def add_operand_defs(target: dict[str, set[Any]], operand: str) -> None:
    merge_reg_state(target, operand_reg_state(operand))


def add_operand_uses(target: dict[str, set[Any]], operand: str) -> None:
    merge_reg_state(target, operand_reg_state(operand))


def scalar_instruction_sets_scc(mnemonic: str) -> bool:
    if "saveexec" in mnemonic:
        return True
    return mnemonic.startswith(SCALAR_SCC_PREFIXES)


def instruction_semantics(instruction: dict[str, Any]) -> tuple[dict[str, set[Any]], dict[str, set[Any]]]:
    defs = empty_reg_state()
    uses = empty_reg_state()
    mnemonic = str(instruction.get("mnemonic", "") or "")
    operands = [str(value) for value in instruction.get("operands", [])]

    if not operands and mnemonic not in {"s_cbranch_execz", "s_cbranch_execnz"}:
        return defs, uses

    if mnemonic in {"s_nop", "s_waitcnt", "s_barrier", "s_endpgm", "s_branch"}:
        return defs, uses

    if mnemonic.startswith("s_cbranch_"):
        if "exec" in mnemonic:
            uses["special"].add("exec")
        elif "vcc" in mnemonic:
            uses["special"].add("vcc")
        elif "scc" in mnemonic:
            uses["special"].add("scc")
        return defs, uses

    if mnemonic == "s_setpc_b64":
        if operands:
            add_operand_uses(uses, operands[0])
        return defs, uses

    if mnemonic == "s_setreg_b32" and len(operands) == 2:
        dst = operands[0]
        if dst == "hwreg(HW_REG_FLAT_SCR_LO)" or dst == "hwreg(HW_REG_FLAT_SCR_HI)":
            defs["special"].add("flat_scratch")
            add_operand_uses(uses, operands[1])
            return defs, uses

    if mnemonic.startswith(("s_cmp", "s_bitcmp")):
        for operand in operands:
            add_operand_uses(uses, operand)
        defs["special"].add("scc")
        return defs, uses

    if mnemonic.startswith("s_cselect"):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        uses["special"].add("scc")
        return defs, uses

    if mnemonic in {"s_addc_u32", "s_subb_u32"}:
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        defs["special"].add("scc")
        uses["special"].add("scc")
        return defs, uses

    if "saveexec" in mnemonic:
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        defs["special"].add("exec")
        defs["special"].add("scc")
        uses["special"].add("exec")
        return defs, uses

    if mnemonic.startswith("v_cmpx"):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        defs["special"].add("exec")
        uses["special"].add("exec")
        return defs, uses

    if mnemonic.startswith("v_cmp"):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        uses["special"].add("exec")
        return defs, uses

    if mnemonic.startswith(STORE_PREFIXES):
        for operand in operands:
            add_operand_uses(uses, operand)
        if not mnemonic.startswith("s_"):
            uses["special"].add("exec")
        return defs, uses

    if mnemonic.startswith(LOAD_PREFIXES):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        if not mnemonic.startswith("s_"):
            uses["special"].add("exec")
        return defs, uses

    if mnemonic.startswith("s_swappc_b64"):
        if operands:
            add_operand_defs(defs, operands[0])
        if len(operands) > 1:
            add_operand_uses(uses, operands[1])
        return defs, uses

    if mnemonic.startswith("s_"):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        if scalar_instruction_sets_scc(mnemonic):
            defs["special"].add("scc")
        return defs, uses

    if mnemonic.startswith("v_"):
        if operands:
            add_operand_defs(defs, operands[0])
        for operand in operands[1:]:
            add_operand_uses(uses, operand)
        uses["special"].add("exec")
        return defs, uses

    return defs, uses


def normalize_function_cfg(function: dict[str, Any]) -> dict[str, Any]:
    normalized = deepcopy(function)
    instructions = normalized.get("instructions", [])
    if isinstance(instructions, list):
        for instruction in instructions:
            if not isinstance(instruction, dict):
                continue
            if "control_flow" not in instruction:
                instruction["control_flow"] = classify_control_flow(
                    str(instruction.get("mnemonic", "") or "")
                )
    blocks = normalized.get("basic_blocks")
    if not isinstance(blocks, list) or any(
        not isinstance(block, dict)
        or not isinstance(block.get("instruction_addresses"), list)
        or not isinstance(block.get("successors"), list)
        for block in blocks
    ):
        build_basic_blocks(normalized)
    return normalized


def build_instruction_liveness(function: dict[str, Any]) -> tuple[dict[int, dict[str, set[Any]]], list[dict[str, Any]]]:
    normalized = normalize_function_cfg(function)
    instructions = normalized.get("instructions", [])
    if not isinstance(instructions, list):
        return {}, []

    address_to_index = {
        int(instruction.get("address", 0) or 0): index
        for index, instruction in enumerate(instructions)
        if isinstance(instruction, dict)
    }
    block_labels: list[str] = []
    block_instruction_indices: list[list[int]] = []
    block_use: list[dict[str, set[Any]]] = []
    block_def: list[dict[str, set[Any]]] = []
    label_to_index: dict[str, int] = {}

    for block_index, block in enumerate(normalized.get("basic_blocks", [])):
        if not isinstance(block, dict):
            continue
        label = str(block.get("label") or f"bb_{block_index}")
        label_to_index[label] = len(block_labels)
        block_labels.append(label)
        instruction_addresses = block.get("instruction_addresses", [])
        indices = [
            address_to_index[address]
            for address in instruction_addresses
            if isinstance(address, int) and address in address_to_index
        ]
        block_instruction_indices.append(indices)
        use_state = empty_reg_state()
        def_state = empty_reg_state()
        for instruction_index in indices:
            defs, uses = instruction_semantics(instructions[instruction_index])
            merge_reg_state(use_state, reg_state_difference(uses, def_state))
            merge_reg_state(def_state, defs)
        block_use.append(use_state)
        block_def.append(def_state)

    successors: list[list[int]] = [[] for _ in block_labels]
    ordered_blocks = [
        block for block in normalized.get("basic_blocks", [])
        if isinstance(block, dict)
    ]
    for block_index, block in enumerate(ordered_blocks):
        resolved: list[int] = []
        for successor_label in block.get("successors", []):
            successor_index = label_to_index.get(str(successor_label))
            if successor_index is not None:
                resolved.append(successor_index)
        if block_instruction_indices[block_index]:
            tail_index = block_instruction_indices[block_index][-1]
            tail_mnemonic = str(instructions[tail_index].get("mnemonic", "") or "")
            if tail_mnemonic == "s_swappc_b64" and block_index + 1 < len(block_labels):
                fallthrough_index = block_index + 1
                if fallthrough_index not in resolved:
                    resolved.append(fallthrough_index)
        successors[block_index] = resolved

    live_in = [empty_reg_state() for _ in block_labels]
    live_out = [empty_reg_state() for _ in block_labels]
    changed = True
    while changed:
        changed = False
        for block_index in range(len(block_labels) - 1, -1, -1):
            next_live_out = empty_reg_state()
            for successor_index in successors[block_index]:
                merge_reg_state(next_live_out, live_in[successor_index])
            next_live_in = clone_reg_state(block_use[block_index])
            merge_reg_state(next_live_in, reg_state_difference(next_live_out, block_def[block_index]))
            if not reg_state_equal(next_live_out, live_out[block_index]):
                live_out[block_index] = next_live_out
                changed = True
            if not reg_state_equal(next_live_in, live_in[block_index]):
                live_in[block_index] = next_live_in
                changed = True

    live_before_by_address: dict[int, dict[str, set[Any]]] = {}
    site_hazards: list[dict[str, Any]] = []
    for block_index, indices in enumerate(block_instruction_indices):
        live = clone_reg_state(live_out[block_index])
        for instruction_index in reversed(indices):
            instruction = instructions[instruction_index]
            defs, uses = instruction_semantics(instruction)
            live_before = clone_reg_state(uses)
            merge_reg_state(live_before, reg_state_difference(live, defs))
            address = int(instruction.get("address", 0) or 0)
            live_before_by_address[address] = live_before
            live = live_before

    return live_before_by_address, site_hazards


def ordered_special_names(values: set[str]) -> list[str]:
    ordered = [name for name in SPECIAL_ORDER if name in values]
    extras = sorted(name for name in values if name not in SPECIAL_ORDER)
    ordered.extend(extras)
    return ordered


def workitem_source_vgprs(entry_shape: dict[str, Any]) -> list[int]:
    count = int(entry_shape.get("workitem_vgpr_count", 0) or 0)
    pattern = str(entry_shape.get("workitem_pattern", "") or "")
    if pattern == "packed_v0_10_10_10_unpack":
        return [0]
    if pattern == "single_vgpr_workitem_id":
        return [0]
    if count <= 0:
        return []
    return list(range(count))


def build_entry_dependencies(
    *,
    entry_analysis: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, Any]:
    entry_shape = profile.get("entry_shape", {}) if isinstance(profile, dict) else {}
    kernarg_base = entry_analysis.get("inferred_kernarg_base", {})
    observed_private = entry_analysis.get("observed_private_segment_materialization", {})

    kernarg_entry_pair = None
    current_pair = None
    if isinstance(kernarg_base, dict):
        raw_entry_pair = kernarg_base.get("entry_base_pair")
        raw_current_pair = kernarg_base.get("base_pair")
        if isinstance(raw_entry_pair, list) and len(raw_entry_pair) == 2:
            kernarg_entry_pair = [int(raw_entry_pair[0]), int(raw_entry_pair[1])]
        if isinstance(raw_current_pair, list) and len(raw_current_pair) == 2:
            current_pair = [int(raw_current_pair[0]), int(raw_current_pair[1])]

    private_details = observed_private.get("details", {}) if isinstance(observed_private, dict) else {}
    src_private_base = private_details.get("src_private_base", {}) if isinstance(private_details, dict) else {}
    src_private_pair = None
    if isinstance(src_private_base, dict):
        raw_pair = src_private_base.get("pair")
        if isinstance(raw_pair, list) and len(raw_pair) == 2:
            src_private_pair = [int(raw_pair[0]), int(raw_pair[1])]

    private_dependency = {
        "pattern": entry_shape.get("private_pattern"),
        "address_source": (
            "src_private_base"
            if entry_shape.get("private_pattern") == "src_private_base"
            else "current_s0_s1"
        ),
    }
    if isinstance(entry_shape.get("private_offset_source_sgpr"), int):
        private_dependency["offset_sgpr"] = int(entry_shape["private_offset_source_sgpr"])
    if isinstance(src_private_pair, list):
        private_dependency["materialized_pair"] = src_private_pair

    workitem_dependency = {
        "pattern": entry_shape.get("workitem_pattern"),
        "source_vgprs": workitem_source_vgprs(entry_shape),
    }

    kernarg_dependency = {"kind": "entry_sgpr_pair"}
    if isinstance(kernarg_entry_pair, list):
        kernarg_dependency["source_sgprs"] = kernarg_entry_pair
    if isinstance(current_pair, list):
        kernarg_dependency["current_sgprs"] = current_pair

    return {
        "kernarg_segment_ptr": kernarg_dependency,
        "private_segment": private_dependency,
        "workitem_id": workitem_dependency,
    }


def split_live_state(values: dict[str, set[Any]]) -> tuple[list[int], list[int], list[int], list[str]]:
    sgprs = sorted(int(value) for value in values["sgprs"])
    vgprs = sorted(int(value) for value in values["vgprs"])
    accvgprs = sorted(int(value) for value in values["accvgprs"])
    special = set(str(value) for value in values["special"])
    if 30 in sgprs and 31 in sgprs:
        sgprs = [value for value in sgprs if value not in {30, 31}]
        special.add("s30:s31")
    return sgprs, vgprs, accvgprs, ordered_special_names(special)


def site_anchor_address(site: dict[str, Any]) -> int | None:
    injection_point = site.get("injection_point", {})
    if not isinstance(injection_point, dict):
        return None
    kind = str(injection_point.get("kind", "") or "")
    if kind == "basic_block":
        value = injection_point.get("start_address")
        return int(value) if isinstance(value, int) else None
    if kind == "memory_op":
        value = injection_point.get("instruction_address")
        return int(value) if isinstance(value, int) else None
    return None


def build_mid_kernel_site_state_requirements(
    *,
    function: dict[str, Any],
    site: dict[str, Any],
    entry_analysis: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, Any]:
    hazards: list[dict[str, Any]] = []
    anchor_address = site_anchor_address(site)
    if anchor_address is None:
        return {
            "schema": SITE_STATE_SCHEMA,
            "supported": False,
            "analysis": {
                "kind": "intraprocedural_backward_liveness_v1",
            },
            "hazards": [
                {
                    "kind": "missing-site-anchor-address",
                }
            ],
        }

    live_before_by_address, dataflow_hazards = build_instruction_liveness(function)
    hazards.extend(dataflow_hazards)
    live_before = live_before_by_address.get(anchor_address)
    if live_before is None:
        return {
            "schema": SITE_STATE_SCHEMA,
            "supported": False,
            "analysis": {
                "kind": "intraprocedural_backward_liveness_v1",
                "anchor_address": anchor_address,
            },
            "hazards": [
                {
                    "kind": "anchor-address-not-found-in-function",
                    "address": anchor_address,
                }
            ],
        }

    sgprs, vgprs, accvgprs, special = split_live_state(live_before)
    if accvgprs:
        hazards.append(
            {
                "kind": "live-accvgprs-observed",
                "registers": list(accvgprs),
            }
        )

    result = {
        "schema": SITE_STATE_SCHEMA,
        "supported": True,
        "analysis": {
            "kind": "intraprocedural_backward_liveness_v1",
            "anchor_address": anchor_address,
        },
        "live_state": {
            "sgprs": sgprs,
            "vgprs": vgprs,
            "special": special,
        },
        "entry_dependencies": build_entry_dependencies(
            entry_analysis=entry_analysis,
            profile=profile,
        ),
        "hazards": hazards,
    }
    if accvgprs:
        result["live_state"]["accvgprs"] = accvgprs
    return result


def current_backend_name(private_pattern: str | None) -> str:
    if private_pattern == "src_private_base":
        return "private_segment_tail.src_private_base.flat.v1"
    return "private_segment_tail.current_scratch_descriptor.buffer.v1"


def build_mid_kernel_site_resume_plan(
    *,
    site_state_requirements: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, Any]:
    entry_shape = profile.get("entry_shape", {}) if isinstance(profile, dict) else {}
    private_pattern = entry_shape.get("private_pattern")
    address_ops = "flat" if private_pattern == "src_private_base" else "buffer"
    storage = {
        "kind": "private_segment_tail",
        "private_pattern": private_pattern,
        "address_source": "src_private_base" if private_pattern == "src_private_base" else "current_s0_s1",
        "address_ops": address_ops,
    }
    if isinstance(entry_shape.get("private_offset_source_sgpr"), int):
        storage["offset_sgpr"] = int(entry_shape["private_offset_source_sgpr"])

    resume_requirements = profile.get("resume_requirements", {}) if isinstance(profile, dict) else {}
    helper_contract = {
        "runtime_views": list(resume_requirements.get("helper_runtime_views", [])),
        "supported_helper_builtins": list(resume_requirements.get("supported_helper_builtins", [])),
        "helper_call_special_clobbers": ["s30:s31", "exec", "vcc", "m0"],
    }

    plan = {
        "schema": SITE_RESUME_PLAN_SCHEMA,
        "supported": bool(profile.get("supported")),
        "blockers": list(profile.get("blockers", [])),
        "backend": current_backend_name(private_pattern),
        "storage": storage,
        "semantic_preserve_set": deepcopy(site_state_requirements.get("live_state", {})),
        "entry_snapshot_requirements": {
            "kernarg_snapshot": bool(resume_requirements.get("requires_kernarg_snapshot", False)),
            "private_segment_tail_growth": bool(
                resume_requirements.get("requires_private_segment_tail_growth", False)
            ),
        },
        "lowering_constraints": {
            "stub_sgpr_floor": int(resume_requirements.get("stub_sgpr_floor", 0) or 0),
            "address_vgpr_pair_required": address_ops == "flat",
            "current_lowering_policy": {
                "vgpr_selection": "semantic_preserve_set_union",
                "sgpr_selection": "semantic_preserve_set_union_plus_persistent_stub_state",
            },
        },
        "helper_contract": helper_contract,
    }
    if not bool(profile.get("supported")):
        plan["backend"] = None
    return plan


def build_mid_kernel_site_plan(
    *,
    function: dict[str, Any],
    site: dict[str, Any],
    entry_analysis: dict[str, Any],
    profile: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    state_requirements = build_mid_kernel_site_state_requirements(
        function=function,
        site=site,
        entry_analysis=entry_analysis,
        profile=profile,
    )
    resume_plan = build_mid_kernel_site_resume_plan(
        site_state_requirements=state_requirements,
        profile=profile,
    )
    return state_requirements, resume_plan
