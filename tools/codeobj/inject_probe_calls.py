#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from copy import deepcopy
from pathlib import Path
from typing import Any

from amdgpu_calling_convention import (
    analyze_kernel_calling_convention,
    descriptor_allocated_sgpr_count,
    descriptor_allocated_vgpr_count,
    layout_call_arguments,
)
from amdgpu_entry_abi import (
    analyze_kernel_entry_abi,
    entry_livein_sgprs as tracked_entry_livein_sgprs,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Inject Omniprobe probe call sequences into instruction-level IR. "
            "The current implementation supports binary-only lifecycle entry "
            "and lifecycle exit thunk calls, plus conservative basic-block "
            "thunk insertion."
        )
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument("--plan", required=True, help="Planner JSON emitted by plan_probe_instrumentation.py")
    parser.add_argument(
        "--thunk-manifest",
        required=True,
        help="Thunk manifest JSON emitted by generate_binary_probe_thunks.py",
    )
    parser.add_argument(
        "--manifest",
        default=None,
        help="Optional code-object manifest JSON used for descriptor facts",
    )
    parser.add_argument("--function", required=True, help="Function name to mutate")
    parser.add_argument("--output", required=True, help="Output IR JSON")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def find_function(ir: dict, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"function {function_name!r} not found in IR")
    return function


def find_descriptor(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    for descriptor in manifest.get("kernels", {}).get("descriptors", []):
        if descriptor.get("kernel_name") == function_name or descriptor.get("name") == f"{function_name}.kd":
            return descriptor
    return None


def find_kernel_metadata(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == function_name or kernel.get("symbol") == f"{function_name}.kd":
            return kernel
    return None


def find_kernel_plan(plan: dict, function_name: str) -> dict:
    kernel = next(
        (
            entry
            for entry in plan.get("kernels", [])
            if entry.get("source_kernel") == function_name or entry.get("clone_kernel") == function_name
        ),
        None,
    )
    if kernel is None:
        raise SystemExit(f"no kernel plan found for function {function_name!r}")
    return kernel


def find_thunk(thunk_manifest: dict, kernel_plan: dict, when: str) -> dict:
    source_kernel = kernel_plan.get("source_kernel")
    thunk = next(
        (
            entry
            for entry in thunk_manifest.get("thunks", [])
            if entry.get("source_kernel") == source_kernel and entry.get("when") == when
        ),
        None,
    )
    if thunk is None:
        raise SystemExit(f"no {when} thunk found for source kernel {source_kernel!r}")
    return thunk


def find_planned_sites(
    kernel_plan: dict,
    *,
    when: str | None = None,
    contract: str | None = None,
) -> list[dict]:
    sites: list[dict] = []
    for entry in kernel_plan.get("planned_sites", []):
        if not isinstance(entry, dict):
            continue
        if entry.get("status") != "planned":
            continue
        if when is not None and entry.get("when") != when:
            continue
        if contract is not None and entry.get("contract") != contract:
            continue
        sites.append(entry)
    return sites


def find_planned_site(kernel_plan: dict, when: str) -> dict | None:
    entries = find_planned_sites(kernel_plan, when=when, contract="kernel_lifecycle_v1")
    return entries[0] if entries else None


def choose_entry_insertion_anchor(function: dict, kernarg_base: dict | None) -> tuple[int, int]:
    instructions = function.get("instructions", [])
    if not instructions:
        return 0, int(function.get("start_address", 0) or 0)
    cursor = 0
    address = int(
        instructions[cursor].get("address", function.get("start_address", 0))
        or function.get("start_address", 0)
        or 0
    )
    return cursor, address


def make_instruction(address: int, mnemonic: str, operand_text: str = "", operands: list[str] | None = None) -> dict:
    return {
        "address": address,
        "mnemonic": mnemonic,
        "operand_text": operand_text,
        "operands": operands or [],
        "control_flow": "linear",
        "synthetic": True,
    }


def round_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        return value
    return ((value + alignment - 1) // alignment) * alignment


def emit_capture_load_and_marshal(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    temp_pair: list[int],
    call_argument: dict,
) -> list[dict]:
    dword_count = int(call_argument.get("dword_count", 0) or 0)
    offset = int(call_argument.get("kernel_arg_offset", 0) or 0)
    vgprs = [int(value) for value in call_argument.get("vgprs", [])]
    if dword_count == 1:
        scalar_operand = f"s{temp_pair[0]}"
        return [
            make_instruction(
                anchor_address,
                "s_load_dword",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            ),
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "lgkmcnt(0)",
                ["lgkmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{temp_pair[0]}",
                [f"v{vgprs[0]}", f"s{temp_pair[0]}"],
            ),
        ]
    if dword_count == 2:
        scalar_operand = f"s[{temp_pair[0]}:{temp_pair[1]}]"
        return [
            make_instruction(
                anchor_address,
                "s_load_dwordx2",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            ),
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "lgkmcnt(0)",
                ["lgkmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{temp_pair[0]}",
                [f"v{vgprs[0]}", f"s{temp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[1]}, s{temp_pair[1]}",
                [f"v{vgprs[1]}", f"s{temp_pair[1]}"],
            ),
        ]
    raise SystemExit(f"unsupported capture dword width {dword_count} for call argument {call_argument!r}")


def emit_entry_scalar_save(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    saved_argument: dict,
) -> list[dict]:
    dword_count = int(saved_argument.get("dword_count", 0) or 0)
    offset = int(saved_argument.get("kernel_arg_offset", 0) or 0)
    sgprs = [int(value) for value in saved_argument.get("saved_sgprs", [])]
    if dword_count == 1:
        scalar_operand = f"s{sgprs[0]}"
        return [
            make_instruction(
                anchor_address,
                "s_load_dword",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            )
        ]
    if dword_count == 2:
        scalar_operand = f"s[{sgprs[0]}:{sgprs[1]}]"
        return [
            make_instruction(
                anchor_address,
                "s_load_dwordx2",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            )
        ]
    raise SystemExit(f"unsupported entry-save dword width {dword_count} for saved argument {saved_argument!r}")


def emit_saved_scalar_marshal(
    *,
    anchor_address: int,
    saved_argument: dict,
) -> list[dict]:
    dword_count = int(saved_argument.get("dword_count", 0) or 0)
    sgprs = [int(value) for value in saved_argument.get("saved_sgprs", [])]
    vgprs = [int(value) for value in saved_argument.get("vgprs", [])]
    if dword_count == 1:
        return [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{sgprs[0]}",
                [f"v{vgprs[0]}", f"s{sgprs[0]}"],
            )
        ]
    if dword_count == 2:
        return [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{sgprs[0]}",
                [f"v{vgprs[0]}", f"s{sgprs[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[1]}, s{sgprs[1]}",
                [f"v{vgprs[1]}", f"s{sgprs[1]}"],
            ),
        ]
    raise SystemExit(f"unsupported saved-scalar dword width {dword_count} for saved argument {saved_argument!r}")


def allocated_sgpr_count(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
) -> int:
    current_sgprs = int((kernel_metadata or {}).get("sgpr_count", 0) or 0)
    if current_sgprs <= 0:
        current_sgprs = int(descriptor_allocated_sgpr_count(descriptor) or 0)
    if current_sgprs <= 0:
        raise SystemExit(
            "kernel metadata/descriptor is missing SGPR allocation facts required for binary lifecycle stub injection"
        )
    return current_sgprs


def infer_first_hidden_arg_offset(kernel_metadata: dict | None) -> int | None:
    if not isinstance(kernel_metadata, dict):
        return None
    args = kernel_metadata.get("args", [])
    hidden_offsets: list[int] = []
    for arg in args:
        if not isinstance(arg, dict):
            continue
        value_kind = str(arg.get("value_kind", ""))
        if not value_kind.startswith("hidden_"):
            continue
        if value_kind == "hidden_omniprobe_ctx":
            continue
        offset = arg.get("offset")
        if isinstance(offset, int):
            hidden_offsets.append(offset)
    if not hidden_offsets:
        return None
    return min(hidden_offsets)


def infer_builtin_livein_plan(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
) -> dict[str, int] | None:
    if not isinstance(descriptor, dict):
        return None
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {})
    if not isinstance(rsrc2, dict):
        return None
    if not int(rsrc2.get("enable_sgpr_workgroup_id_x", 0) or 0):
        return None
    first_hidden_offset = infer_first_hidden_arg_offset(kernel_metadata)
    if first_hidden_offset is None:
        return None
    workgroup_source_base = rsrc2.get("user_sgpr_count")
    if not isinstance(workgroup_source_base, int) or workgroup_source_base < 0:
        return None
    plan: dict[str, int] = {
        "implicitarg_ptr_offset": first_hidden_offset,
        "implicitarg_ptr_dest_low_sgpr": 8,
        "workgroup_id_x_source_sgpr": workgroup_source_base,
        "workgroup_id_x_dest_sgpr": 12,
    }
    if int(rsrc2.get("enable_sgpr_workgroup_id_y", 0) or 0):
        plan["workgroup_id_y_source_sgpr"] = workgroup_source_base + 1
        plan["workgroup_id_y_dest_sgpr"] = 13
    if int(rsrc2.get("enable_sgpr_workgroup_id_z", 0) or 0):
        plan["workgroup_id_z_source_sgpr"] = workgroup_source_base + 2
        plan["workgroup_id_z_dest_sgpr"] = 14
    return plan


def reserve_saved_scalar_arguments(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
    call_arguments: list[dict],
    hidden_offset: int,
) -> dict:
    current_sgprs = allocated_sgpr_count(kernel_metadata=kernel_metadata, descriptor=descriptor)
    saved_arguments: list[dict] = []
    next_sgpr = current_sgprs
    for argument in call_arguments:
        kind = str(argument.get("kind", ""))
        if kind not in {"hidden_ctx", "capture"}:
            continue
        saved = dict(argument)
        if kind == "hidden_ctx":
            saved["kernel_arg_offset"] = hidden_offset
        saved_sgprs = list(range(next_sgpr, next_sgpr + int(saved.get("dword_count", 0) or 0)))
        saved["saved_sgprs"] = saved_sgprs
        next_sgpr += len(saved_sgprs)
        saved_arguments.append(saved)

    return {
        "saved_arguments": saved_arguments,
        "saved_sgpr_base": current_sgprs,
        "saved_sgpr_count": max(0, next_sgpr - current_sgprs),
        "total_sgprs": next_sgpr,
    }


def reserve_entry_scalar_arguments(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
    call_arguments: list[dict],
    hidden_offset: int,
) -> dict:
    current_sgprs = allocated_sgpr_count(kernel_metadata=kernel_metadata, descriptor=descriptor)
    staged_arguments: list[dict] = []
    next_sgpr = current_sgprs
    for argument in call_arguments:
        kind = str(argument.get("kind", ""))
        if kind not in {"hidden_ctx", "capture"}:
            continue
        staged = dict(argument)
        if kind == "hidden_ctx":
            staged["kernel_arg_offset"] = hidden_offset
        staging_sgprs = list(range(next_sgpr, next_sgpr + int(staged.get("dword_count", 0) or 0)))
        staged["staging_sgprs"] = staging_sgprs
        next_sgpr += len(staging_sgprs)
        staged_arguments.append(staged)

    timestamp_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    target_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    return {
        "staged_arguments": staged_arguments,
        "staging_sgpr_base": current_sgprs,
        "staging_sgpr_count": max(0, next_sgpr - current_sgprs),
        "timestamp_pair": timestamp_pair,
        "target_pair": target_pair,
        "total_sgprs": next_sgpr,
    }


def reserve_entry_builtin_restore(
    *,
    next_sgpr: int,
    builtin_liveins: dict[str, int] | None,
) -> dict[str, Any]:
    if not isinstance(builtin_liveins, dict):
        return {
            "restore_pair": None,
            "restore_sgpr_count": 0,
            "total_sgprs": next_sgpr,
        }
    restore_pair = [next_sgpr, next_sgpr + 1]
    return {
        "restore_pair": restore_pair,
        "restore_sgpr_count": 2,
        "total_sgprs": next_sgpr + 2,
    }


def reserve_entry_kernarg_restore(
    *,
    next_sgpr: int,
    kernarg_pair: list[int],
) -> dict[str, Any]:
    if len(kernarg_pair) != 2:
        return {
            "restore_pair": None,
            "restore_sgpr_count": 0,
            "total_sgprs": next_sgpr,
        }
    restore_pair = [next_sgpr, next_sgpr + 1]
    return {
        "restore_pair": restore_pair,
        "restore_sgpr_count": 2,
        "total_sgprs": next_sgpr + 2,
    }


def reserve_entry_exec_restore(
    *,
    next_sgpr: int,
) -> dict[str, Any]:
    aligned = next_sgpr if next_sgpr % 2 == 0 else next_sgpr + 1
    restore_pair = [aligned, aligned + 1]
    return {
        "restore_pair": restore_pair,
        "restore_sgpr_count": 2,
        "total_sgprs": aligned + 2,
    }


def reserve_entry_builtin_snapshot(
    *,
    next_sgpr: int,
    builtin_liveins: dict[str, int] | None,
) -> dict[str, Any]:
    if not isinstance(builtin_liveins, dict):
        return {
            "saved_sources": {},
            "snapshot_sgpr_base": next_sgpr,
            "snapshot_sgpr_count": 0,
            "total_sgprs": next_sgpr,
        }

    saved_sources: dict[str, int] = {}
    cursor = next_sgpr
    for key in (
        "workgroup_id_x_source_sgpr",
        "workgroup_id_y_source_sgpr",
        "workgroup_id_z_source_sgpr",
    ):
        source = builtin_liveins.get(key)
        if not isinstance(source, int):
            continue
        saved_sources[key] = cursor
        cursor += 1

    return {
        "saved_sources": saved_sources,
        "snapshot_sgpr_base": next_sgpr,
        "snapshot_sgpr_count": max(0, cursor - next_sgpr),
        "total_sgprs": cursor,
    }


def entry_livein_sgprs(descriptor: dict | None) -> list[int]:
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
    if int(rsrc2.get("enable_sgpr_workgroup_id_x", 0) or 0):
        liveins.append(cursor)
        cursor += 1
    if int(rsrc2.get("enable_sgpr_workgroup_id_y", 0) or 0):
        liveins.append(cursor)
        cursor += 1
    if int(rsrc2.get("enable_sgpr_workgroup_id_z", 0) or 0):
        liveins.append(cursor)
        cursor += 1
    if int(rsrc2.get("enable_sgpr_workgroup_info", 0) or 0):
        liveins.append(cursor)
        cursor += 1
    if int(rsrc2.get("enable_private_segment", 0) or 0):
        liveins.append(cursor)
        cursor += 1
    return liveins


def reserve_entry_livein_restore(
    *,
    next_sgpr: int,
    descriptor: dict | None,
    entry_analysis: dict[str, Any] | None = None,
) -> dict[str, Any]:
    source_sgprs = []
    if isinstance(entry_analysis, dict):
        source_sgprs = [int(value) for value in entry_analysis.get("entry_livein_sgprs", [])]
    if not source_sgprs:
        source_sgprs = tracked_entry_livein_sgprs(descriptor)
    if not source_sgprs:
        return {
            "source_sgprs": [],
            "save_sgprs": [],
            "save_sgpr_base": next_sgpr,
            "save_sgpr_count": 0,
            "total_sgprs": next_sgpr,
        }
    save_sgprs = list(range(next_sgpr, next_sgpr + len(source_sgprs)))
    return {
        "source_sgprs": source_sgprs,
        "save_sgprs": save_sgprs,
        "save_sgpr_base": next_sgpr,
        "save_sgpr_count": len(save_sgprs),
        "total_sgprs": next_sgpr + len(save_sgprs),
    }


def reserve_entry_workitem_restore(
    *,
    allocated_vgprs: int | None,
    reserved_low_vgprs: int,
    descriptor: dict | None,
    entry_analysis: dict[str, Any] | None = None,
) -> dict[str, Any]:
    count = 0
    if isinstance(entry_analysis, dict):
        count = int(entry_analysis.get("entry_workitem_vgpr_count", 0) or 0)
    if count <= 0:
        return {
            "count": 0,
            "spill_offset": None,
            "packed_workitem_dest_vgpr": None,
            "pattern_class": None,
            "private_segment_pattern_class": None,
            "private_segment_offset_source_sgpr": None,
            "source_vgprs": [],
            "restore_mode": None,
        }
    workitem_pattern = entry_analysis.get("observed_workitem_id_materialization") if isinstance(entry_analysis, dict) else None
    pattern_class = (
        str(workitem_pattern.get("pattern_class"))
        if isinstance(workitem_pattern, dict)
        else None
    )
    if pattern_class not in {None, "direct_vgpr_xyz", "packed_v0_10_10_10_unpack", "single_vgpr_workitem_id"}:
        raise SystemExit(
            "entry helper injection does not yet support workitem-id materialization "
            f"pattern {pattern_class!r}"
        )
    if pattern_class == "packed_v0_10_10_10_unpack":
        source_vgprs = [0]
        restore_mode = "direct"
    else:
        effective_count = max(1, count) if pattern_class == "single_vgpr_workitem_id" else count
        source_vgprs = list(range(effective_count))
        restore_mode = "direct"
    private_segment_size = int((descriptor or {}).get("private_segment_fixed_size", 0) or 0)
    if private_segment_size < 0:
        raise SystemExit("kernel private-segment size cannot be negative")
    private_materialization = (
        entry_analysis.get("observed_private_segment_materialization")
        if isinstance(entry_analysis, dict)
        else None
    )
    private_pattern_class = (
        str(private_materialization.get("pattern_class"))
        if isinstance(private_materialization, dict)
        else None
    )
    private_segment_offset_source_sgpr = None
    if isinstance(private_materialization, dict):
        details = private_materialization.get("details", {})
        if isinstance(details, dict):
            pair_updates = details.get("pair_updates", [])
            if isinstance(pair_updates, list):
                first_pair_update = next(
                    (
                        entry
                        for entry in pair_updates
                        if isinstance(entry, dict)
                        and entry.get("pair") == [0, 1]
                        and isinstance(entry.get("offset_sgpr"), int)
                    ),
                    None,
                )
                if first_pair_update is not None:
                    private_segment_offset_source_sgpr = int(first_pair_update["offset_sgpr"])
    if private_pattern_class not in {
        None,
        "setreg_flat_scratch_init",
        "flat_scratch_alias_init",
        "src_private_base",
        "scalar_pair_update_only",
    }:
        raise SystemExit(
            "entry helper injection does not yet support private-segment materialization "
            f"pattern {private_pattern_class!r}"
        )
    return {
        "count": count,
        # Binary probe regeneration grows the clone private segment by 16 bytes.
        # Spill the packed workitem state into that appended tail, not into the
        # source kernel's original private frame.
        "spill_offset": private_segment_size,
        "packed_workitem_dest_vgpr": None,
        "pattern_class": pattern_class,
        "private_segment_pattern_class": private_pattern_class,
        "private_segment_offset_source_sgpr": private_segment_offset_source_sgpr,
        "source_vgprs": source_vgprs,
        "restore_mode": restore_mode,
    }


def emit_entry_workitem_save_restore(
    *,
    anchor_address: int,
    restore_plan: dict[str, Any] | None,
    livein_restore_plan: dict[str, Any] | None,
    scratch_soffset_sgpr: int,
) -> tuple[list[dict], list[dict]]:
    if not isinstance(restore_plan, dict):
        return [], []
    count = int(restore_plan.get("count", 0) or 0)
    spill_offset = restore_plan.get("spill_offset")
    if count <= 0 or not isinstance(spill_offset, int):
        return [], []
    if not isinstance(livein_restore_plan, dict):
        return [], []
    source_sgprs = [int(value) for value in livein_restore_plan.get("source_sgprs", [])]
    save_sgprs = [int(value) for value in livein_restore_plan.get("save_sgprs", [])]
    if len(source_sgprs) != len(save_sgprs):
        return [], []
    saved_sgpr_by_source = dict(zip(source_sgprs, save_sgprs))
    saved_s0 = saved_sgpr_by_source.get(0)
    saved_s1 = saved_sgpr_by_source.get(1)
    if not isinstance(saved_s0, int) or not isinstance(saved_s1, int):
        raise SystemExit("entry workitem preservation requires saved copies of s0:s1")
    workitem_pattern_class = restore_plan.get("pattern_class")
    private_pattern_class = restore_plan.get("private_segment_pattern_class")
    private_offset_source_sgpr = restore_plan.get("private_segment_offset_source_sgpr")
    source_vgprs = [int(value) for value in restore_plan.get("source_vgprs", [])]
    if not source_vgprs:
        return [], []

    before: list[dict] = []
    after: list[dict] = []
    address_setup: list[dict] = []
    if private_pattern_class == "src_private_base":
        address_setup.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b64",
                    "s[0:1], src_private_base",
                    ["s[0:1]", "src_private_base"],
                ),
            ]
        )
        if isinstance(private_offset_source_sgpr, int):
            address_setup.extend(
                [
                    make_instruction(
                        anchor_address,
                        "s_add_u32",
                        f"s0, s0, s{private_offset_source_sgpr}",
                        ["s0", "s0", f"s{private_offset_source_sgpr}"],
                    ),
                    make_instruction(
                        anchor_address,
                        "s_addc_u32",
                        "s1, s1, 0",
                        ["s1", "s1", "0"],
                    ),
                ]
            )
    elif private_pattern_class in {None, "setreg_flat_scratch_init", "flat_scratch_alias_init", "scalar_pair_update_only"}:
        if not isinstance(private_offset_source_sgpr, int):
            raise SystemExit(
                "entry workitem preservation requires an observed private-segment offset SGPR "
                f"for pattern {private_pattern_class!r}"
            )
        address_setup.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_add_u32",
                    f"s0, s0, s{private_offset_source_sgpr}",
                    ["s0", "s0", f"s{private_offset_source_sgpr}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_addc_u32",
                    "s1, s1, 0",
                    ["s1", "s1", "0"],
                ),
            ]
        )
    else:
        raise SystemExit(
            "entry workitem preservation does not support private-segment pattern "
            f"{private_pattern_class!r}"
        )

    if workitem_pattern_class not in {None, "packed_v0_10_10_10_unpack", "single_vgpr_workitem_id", "direct_vgpr_xyz"}:
        raise SystemExit(
            "entry workitem preservation does not support workitem pattern "
            f"{workitem_pattern_class!r}"
        )
    before.extend(
        address_setup
        + [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{scratch_soffset_sgpr}, 0",
                [f"s{scratch_soffset_sgpr}", "0"],
            ),
        ]
    )
    for index, source_vgpr in enumerate(source_vgprs):
        store_offset = spill_offset + (index * 4)
        before.append(
            make_instruction(
                anchor_address,
                "buffer_store_dword",
                f"v{source_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{store_offset}",
                [
                    f"v{source_vgpr}",
                    "off",
                    "s[0:3]",
                    f"s{scratch_soffset_sgpr}",
                    f"offset:{store_offset}",
                ],
            )
        )
    before.extend(
        [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s0, s{saved_s0}",
                ["s0", f"s{saved_s0}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s1, s{saved_s1}",
                ["s1", f"s{saved_s1}"],
            ),
        ]
    )
    after.extend(
        address_setup
        + [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{scratch_soffset_sgpr}, 0",
                [f"s{scratch_soffset_sgpr}", "0"],
            ),
        ]
    )
    for index, source_vgpr in enumerate(source_vgprs):
        load_offset = spill_offset + (index * 4)
        after.append(
            make_instruction(
                anchor_address,
                "buffer_load_dword",
                f"v{source_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{load_offset}",
                [
                    f"v{source_vgpr}",
                    "off",
                    "s[0:3]",
                    f"s{scratch_soffset_sgpr}",
                    f"offset:{load_offset}",
                ],
            )
        )
    after.extend(
        [
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "vmcnt(0)",
                ["vmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s0, s{saved_s0}",
                ["s0", f"s{saved_s0}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s1, s{saved_s1}",
                ["s1", f"s{saved_s1}"],
            ),
        ]
    )
    return before, after


def emit_entry_livein_save_restore(
    *,
    anchor_address: int,
    restore_plan: dict[str, Any] | None,
) -> tuple[list[dict], list[dict]]:
    if not isinstance(restore_plan, dict):
        return [], []
    source_sgprs = [int(value) for value in restore_plan.get("source_sgprs", [])]
    save_sgprs = [int(value) for value in restore_plan.get("save_sgprs", [])]
    if len(source_sgprs) != len(save_sgprs):
        return [], []
    before: list[dict] = []
    after: list[dict] = []
    for source_sgpr, save_sgpr in zip(source_sgprs, save_sgprs):
        before.append(
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{save_sgpr}, s{source_sgpr}",
                [f"s{save_sgpr}", f"s{source_sgpr}"],
            )
        )
        after.append(
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{source_sgpr}, s{save_sgpr}",
                [f"s{source_sgpr}", f"s{save_sgpr}"],
            )
        )
    return before, after


def emit_helper_builtin_liveins(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    builtin_liveins: dict[str, int] | None,
    restore_pair: list[int] | None = None,
) -> tuple[list[dict], list[dict]]:
    if not isinstance(builtin_liveins, dict):
        return [], []

    instructions_before: list[dict] = []
    instructions_after: list[dict] = []
    implicitarg_dest_low = int(builtin_liveins["implicitarg_ptr_dest_low_sgpr"])
    implicitarg_offset = int(builtin_liveins["implicitarg_ptr_offset"])

    if restore_pair is not None:
        instructions_before.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{restore_pair[0]}, s{implicitarg_dest_low}",
                    [f"s{restore_pair[0]}", f"s{implicitarg_dest_low}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{restore_pair[1]}, s{implicitarg_dest_low + 1}",
                    [f"s{restore_pair[1]}", f"s{implicitarg_dest_low + 1}"],
                ),
            ]
        )
        instructions_after.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{implicitarg_dest_low}, s{restore_pair[0]}",
                    [f"s{implicitarg_dest_low}", f"s{restore_pair[0]}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{implicitarg_dest_low + 1}, s{restore_pair[1]}",
                    [f"s{implicitarg_dest_low + 1}", f"s{restore_pair[1]}"],
                ),
            ]
        )

    workgroup_pairs = [
        (
            builtin_liveins.get("workgroup_id_x_source_sgpr"),
            builtin_liveins.get("workgroup_id_x_dest_sgpr"),
        ),
        (
            builtin_liveins.get("workgroup_id_y_source_sgpr"),
            builtin_liveins.get("workgroup_id_y_dest_sgpr"),
        ),
        (
            builtin_liveins.get("workgroup_id_z_source_sgpr"),
            builtin_liveins.get("workgroup_id_z_dest_sgpr"),
        ),
    ]
    for source, dest in workgroup_pairs:
        if not isinstance(source, int) or not isinstance(dest, int) or source == dest:
            continue
        instructions_before.append(
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{dest}, s{source}",
                [f"s{dest}", f"s{source}"],
            )
        )

    instructions_before.extend(
        [
            make_instruction(
                anchor_address,
                "s_add_u32",
                f"s{implicitarg_dest_low}, s{kernarg_pair[0]}, 0x{implicitarg_offset:x}",
                [f"s{implicitarg_dest_low}", f"s{kernarg_pair[0]}", f"0x{implicitarg_offset:x}"],
            ),
            make_instruction(
                anchor_address,
                "s_addc_u32",
                f"s{implicitarg_dest_low + 1}, s{kernarg_pair[1]}, 0",
                [f"s{implicitarg_dest_low + 1}", f"s{kernarg_pair[1]}", "0"],
            ),
        ]
    )
    return instructions_before, instructions_after


def emit_entry_builtin_snapshot(
    *,
    anchor_address: int,
    builtin_liveins: dict[str, int] | None,
    snapshot_plan: dict[str, Any] | None,
) -> list[dict]:
    if not isinstance(builtin_liveins, dict) or not isinstance(snapshot_plan, dict):
        return []

    saved_sources = snapshot_plan.get("saved_sources", {})
    if not isinstance(saved_sources, dict):
        return []

    instructions: list[dict] = []
    for key in (
        "workgroup_id_x_source_sgpr",
        "workgroup_id_y_source_sgpr",
        "workgroup_id_z_source_sgpr",
    ):
        source = builtin_liveins.get(key)
        dest = saved_sources.get(key)
        if not isinstance(source, int) or not isinstance(dest, int) or source == dest:
            continue
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{dest}, s{source}",
                [f"s{dest}", f"s{source}"],
            )
        )
    return instructions


def lifecycle_entry_stub_instructions(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    thunk_name: str,
    call_arguments: list[dict],
    staged_arguments: list[dict],
    timestamp_pair: list[int],
    target_pair: list[int],
    builtin_liveins: dict[str, int] | None,
    builtin_restore_pair: list[int] | None,
    kernarg_restore_pair: list[int] | None,
    exec_restore_pair: list[int] | None,
    livein_restore_plan: dict[str, Any] | None,
    workitem_restore_plan: dict[str, Any] | None,
) -> list[dict]:
    instructions: list[dict] = []
    workitem_save, workitem_restore = emit_entry_workitem_save_restore(
        anchor_address=anchor_address,
        restore_plan=workitem_restore_plan,
        livein_restore_plan=livein_restore_plan,
        scratch_soffset_sgpr=timestamp_pair[0],
    )
    livein_save, livein_restore = emit_entry_livein_save_restore(
        anchor_address=anchor_address,
        restore_plan=livein_restore_plan,
    )
    instructions.extend(livein_save)
    instructions.extend(workitem_save)
    for staged_argument in staged_arguments:
        instructions.extend(
            emit_capture_load_and_marshal(
                anchor_address=anchor_address,
                kernarg_pair=kernarg_pair,
                temp_pair=[int(value) for value in staged_argument.get("staging_sgprs", [])],
                call_argument=staged_argument,
            )
        )

    timestamp_operand = f"s[{timestamp_pair[0]}:{timestamp_pair[1]}]"
    target_operand = f"s[{target_pair[0]}:{target_pair[1]}]"
    timestamp_arg = next((entry for entry in call_arguments if entry.get("kind") == "timestamp"), None)
    if timestamp_arg is None:
        raise SystemExit("thunk manifest did not describe a timestamp call argument")
    timestamp_vgprs = [int(value) for value in timestamp_arg.get("vgprs", [])]
    if len(timestamp_vgprs) != 2:
        raise SystemExit(f"timestamp call argument must occupy two VGPRs, got {timestamp_vgprs!r}")

    builtin_setup, builtin_restore = emit_helper_builtin_liveins(
        anchor_address=anchor_address,
        kernarg_pair=kernarg_pair,
        builtin_liveins=builtin_liveins,
        restore_pair=builtin_restore_pair,
    )

    instructions.extend(
        [
            make_instruction(anchor_address, "s_memtime", timestamp_operand, [timestamp_operand]),
            make_instruction(anchor_address, "s_waitcnt", "lgkmcnt(0)", ["lgkmcnt(0)"]),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[0]}, s{timestamp_pair[0]}",
                [f"v{timestamp_vgprs[0]}", f"s{timestamp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[1]}, s{timestamp_pair[1]}",
                [f"v{timestamp_vgprs[1]}", f"s{timestamp_pair[1]}"],
            ),
            make_instruction(anchor_address, "s_getpc_b64", target_operand, [target_operand]),
            make_instruction(
                anchor_address,
                "s_add_u32",
                f"s{target_pair[0]}, s{target_pair[0]}, {thunk_name}@rel32@lo+4",
                [f"s{target_pair[0]}", f"s{target_pair[0]}", f"{thunk_name}@rel32@lo+4"],
            ),
            make_instruction(
                anchor_address,
                "s_addc_u32",
                f"s{target_pair[1]}, s{target_pair[1]}, {thunk_name}@rel32@hi+4",
                [f"s{target_pair[1]}", f"s{target_pair[1]}", f"{thunk_name}@rel32@hi+4"],
            ),
        ]
    )
    if exec_restore_pair is not None:
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}], exec",
                [f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]", "exec"],
            )
        )
    if kernarg_restore_pair is not None:
        instructions.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{kernarg_restore_pair[0]}, s{kernarg_pair[0]}",
                    [f"s{kernarg_restore_pair[0]}", f"s{kernarg_pair[0]}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{kernarg_restore_pair[1]}, s{kernarg_pair[1]}",
                    [f"s{kernarg_restore_pair[1]}", f"s{kernarg_pair[1]}"],
                ),
            ]
        )
    instructions.extend(builtin_setup)
    instructions.append(
        make_instruction(
            anchor_address,
            "s_swappc_b64",
            f"s[30:31], {target_operand}",
            ["s[30:31]", target_operand],
        )
    )
    instructions.extend(builtin_restore)
    if kernarg_restore_pair is not None:
        instructions.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{kernarg_pair[0]}, s{kernarg_restore_pair[0]}",
                    [f"s{kernarg_pair[0]}", f"s{kernarg_restore_pair[0]}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{kernarg_pair[1]}, s{kernarg_restore_pair[1]}",
                    [f"s{kernarg_pair[1]}", f"s{kernarg_restore_pair[1]}"],
                ),
            ]
        )
    if exec_restore_pair is not None:
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"exec, s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]",
                ["exec", f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]"],
            )
        )
    instructions.extend(livein_restore)
    instructions.extend(workitem_restore)
    return instructions


def lifecycle_exit_stub_instructions(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    timestamp_pair: list[int],
    target_pair: list[int],
    thunk_name: str,
    call_arguments: list[dict],
    saved_arguments: list[dict],
    builtin_liveins: dict[str, int] | None,
) -> list[dict]:
    timestamp_operand = f"s[{timestamp_pair[0]}:{timestamp_pair[1]}]"
    target_operand = f"s[{target_pair[0]}:{target_pair[1]}]"
    instructions = [
        make_instruction(
            anchor_address,
            "s_memtime",
            timestamp_operand,
            [timestamp_operand],
        ),
        make_instruction(
            anchor_address,
            "s_waitcnt",
            "lgkmcnt(0)",
            ["lgkmcnt(0)"],
        ),
    ]
    for saved_argument in saved_arguments:
        instructions.extend(
            emit_saved_scalar_marshal(
                anchor_address=anchor_address,
                saved_argument=saved_argument,
            )
        )

    timestamp_arg = next((entry for entry in call_arguments if entry.get("kind") == "timestamp"), None)
    if timestamp_arg is None:
        raise SystemExit("thunk manifest did not describe a timestamp call argument")
    timestamp_vgprs = [int(value) for value in timestamp_arg.get("vgprs", [])]
    if len(timestamp_vgprs) != 2:
        raise SystemExit(f"timestamp call argument must occupy two VGPRs, got {timestamp_vgprs!r}")
    builtin_setup, _ = emit_helper_builtin_liveins(
        anchor_address=anchor_address,
        kernarg_pair=kernarg_pair,
        builtin_liveins=builtin_liveins,
        restore_pair=None,
    )
    instructions.extend(
        [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[0]}, s{timestamp_pair[0]}",
                [f"v{timestamp_vgprs[0]}", f"s{timestamp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[1]}, s{timestamp_pair[1]}",
                [f"v{timestamp_vgprs[1]}", f"s{timestamp_pair[1]}"],
            ),
        ]
    )
    instructions.extend(builtin_setup)
    # Keep s_getpc_b64 adjacent to the rel32 add pair. The assembler resolves
    # the thunk target assuming this canonical sequence.
    instructions.extend(
        [
            make_instruction(anchor_address, "s_getpc_b64", target_operand, [target_operand]),
            make_instruction(
                anchor_address,
                "s_add_u32",
                f"s{target_pair[0]}, s{target_pair[0]}, {thunk_name}@rel32@lo+4",
                [f"s{target_pair[0]}", f"s{target_pair[0]}", f"{thunk_name}@rel32@lo+4"],
            ),
            make_instruction(
                anchor_address,
                "s_addc_u32",
                f"s{target_pair[1]}, s{target_pair[1]}, {thunk_name}@rel32@hi+4",
                [f"s{target_pair[1]}", f"s{target_pair[1]}", f"{thunk_name}@rel32@hi+4"],
            ),
            make_instruction(
                anchor_address,
                "s_swappc_b64",
                f"s[30:31], {target_operand}",
                ["s[30:31]", target_operand],
            ),
        ]
    )
    return instructions


def lifecycle_entry_save_instructions(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    saved_arguments: list[dict],
) -> list[dict]:
    instructions: list[dict] = []
    for saved_argument in saved_arguments:
        instructions.extend(
            emit_entry_scalar_save(
                anchor_address=anchor_address,
                kernarg_pair=kernarg_pair,
                saved_argument=saved_argument,
            )
        )
    return instructions


def call_arguments_from_thunk(thunk: dict) -> tuple[dict, list[dict]]:
    thunk_call_arguments = thunk.get("call_arguments")
    if isinstance(thunk_call_arguments, list) and thunk_call_arguments:
        call_layout = layout_call_arguments([dict(entry) for entry in thunk_call_arguments])
        return call_layout, call_layout["arguments"]
    call_layout = layout_call_arguments(
        [
            {"kind": "hidden_ctx", "name": "hidden_ctx", "c_type": "const void *", "size_bytes": 8},
            {"kind": "timestamp", "name": "timestamp", "c_type": "uint64_t", "size_bytes": 8},
        ]
    )
    return call_layout, call_layout["arguments"]


def planned_helper_builtins(site: dict) -> list[str]:
    helper_context = site.get("helper_context", {})
    if not isinstance(helper_context, dict):
        return []
    builtins = helper_context.get("builtins", [])
    if not isinstance(builtins, list):
        return []
    return [str(value) for value in builtins if isinstance(value, str) and value]


def require_no_helper_builtins(sites: list[dict], *, mode: str) -> None:
    requested: set[str] = set()
    for site in sites:
        requested.update(planned_helper_builtins(site))
    if requested:
        names = ", ".join(sorted(requested))
        raise SystemExit(
            f"binary {mode} rewrite does not yet support helper builtins; "
            f"requested builtins: {names}"
        )


def reserve_mid_kernel_scalar_arguments(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
    call_arguments: list[dict],
    hidden_offset: int,
) -> dict[str, Any]:
    current_sgprs = allocated_sgpr_count(kernel_metadata=kernel_metadata, descriptor=descriptor)
    staged_arguments: list[dict] = []
    next_sgpr = current_sgprs
    saved_kernarg_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    for argument in call_arguments:
        kind = str(argument.get("kind", ""))
        if kind not in {"hidden_ctx", "capture"}:
            continue
        staged = dict(argument)
        if kind == "hidden_ctx":
            staged["kernel_arg_offset"] = hidden_offset
        staging_sgprs = list(range(next_sgpr, next_sgpr + int(staged.get("dword_count", 0) or 0)))
        staged["staging_sgprs"] = staging_sgprs
        next_sgpr += len(staging_sgprs)
        staged_arguments.append(staged)

    timestamp_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    target_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    scratch_restore_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    return_restore_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    exec_restore_pair = reserve_entry_exec_restore(next_sgpr=next_sgpr)
    next_sgpr = int(exec_restore_pair["total_sgprs"])
    vcc_restore_pair = [next_sgpr, next_sgpr + 1]
    next_sgpr += 2
    m0_restore_sgpr = next_sgpr
    next_sgpr += 1
    return {
        "staged_arguments": staged_arguments,
        "staging_sgpr_base": current_sgprs,
        "staging_sgpr_count": max(0, next_sgpr - current_sgprs),
        "saved_kernarg_pair": saved_kernarg_pair,
        "timestamp_pair": timestamp_pair,
        "target_pair": target_pair,
        "scratch_restore_pair": scratch_restore_pair,
        "return_restore_pair": return_restore_pair,
        "exec_restore_pair": exec_restore_pair["restore_pair"],
        "vcc_restore_pair": vcc_restore_pair,
        "m0_restore_sgpr": m0_restore_sgpr,
        "total_sgprs": next_sgpr,
    }


def reserve_mid_kernel_vgpr_spill(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
    entry_analysis: dict[str, Any] | None,
    call_dword_count: int,
) -> dict[str, Any]:
    original_vgpr_count = descriptor_allocated_vgpr_count(descriptor)
    if original_vgpr_count is None:
        source_vgprs = list(range(max(0, call_dword_count)))
    else:
        source_vgprs = list(range(max(0, original_vgpr_count)))
    original_sgpr_count = allocated_sgpr_count(
        kernel_metadata=kernel_metadata,
        descriptor=descriptor,
    )
    source_sgprs = [
        reg
        for reg in range(2, original_sgpr_count)
        if reg not in {30, 31}
    ]
    private_segment_size = int((descriptor or {}).get("private_segment_fixed_size", 0) or 0)
    if private_segment_size < 0:
        raise SystemExit("kernel private-segment size cannot be negative")

    private_materialization = (
        entry_analysis.get("observed_private_segment_materialization")
        if isinstance(entry_analysis, dict)
        else None
    )
    private_pattern_class = (
        str(private_materialization.get("pattern_class"))
        if isinstance(private_materialization, dict)
        else None
    )
    private_segment_offset_source_sgpr = None
    if isinstance(private_materialization, dict):
        details = private_materialization.get("details", {})
        if isinstance(details, dict):
            pair_updates = details.get("pair_updates", [])
            if isinstance(pair_updates, list):
                first_pair_update = next(
                    (
                        entry
                        for entry in pair_updates
                        if isinstance(entry, dict)
                        and entry.get("pair") == [0, 1]
                        and isinstance(entry.get("offset_sgpr"), int)
                    ),
                    None,
                )
                if first_pair_update is not None:
                    private_segment_offset_source_sgpr = int(first_pair_update["offset_sgpr"])
    if private_pattern_class not in {
        None,
        "setreg_flat_scratch_init",
        "flat_scratch_alias_init",
        "src_private_base",
        "scalar_pair_update_only",
    }:
        raise SystemExit(
            "mid-kernel helper injection does not yet support private-segment materialization "
            f"pattern {private_pattern_class!r}"
        )

    spill_bytes = max(0, len(source_vgprs) * 4)
    sgpr_spill_offset = private_segment_size + spill_bytes
    sgpr_spill_bytes = max(0, len(source_sgprs) * 4)
    private_segment_growth = round_up(spill_bytes + sgpr_spill_bytes, 16)
    return {
        "source_vgprs": source_vgprs,
        "spill_offset": private_segment_size,
        "spill_bytes": spill_bytes,
        "source_sgprs": source_sgprs,
        "sgpr_spill_offset": sgpr_spill_offset,
        "sgpr_spill_bytes": sgpr_spill_bytes,
        "private_segment_growth": private_segment_growth,
        "private_segment_pattern_class": private_pattern_class,
        "private_segment_offset_source_sgpr": private_segment_offset_source_sgpr,
    }


def emit_mid_kernel_private_segment_address_setup(
    *,
    anchor_address: int,
    spill_plan: dict[str, Any] | None,
    scratch_restore_pair: list[int] | None,
    save_original: bool,
) -> list[dict]:
    if not isinstance(spill_plan, dict):
        return []
    if not isinstance(scratch_restore_pair, list) or len(scratch_restore_pair) != 2:
        return []

    private_pattern_class = spill_plan.get("private_segment_pattern_class")
    private_offset_source_sgpr = spill_plan.get("private_segment_offset_source_sgpr")
    instructions: list[dict] = []
    if save_original:
        instructions.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{scratch_restore_pair[0]}, s0",
                    [f"s{scratch_restore_pair[0]}", "s0"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s{scratch_restore_pair[1]}, s1",
                    [f"s{scratch_restore_pair[1]}", "s1"],
                ),
            ]
        )
    elif private_pattern_class in {None, "setreg_flat_scratch_init", "flat_scratch_alias_init", "scalar_pair_update_only"}:
        instructions.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s0, s{scratch_restore_pair[0]}",
                    ["s0", f"s{scratch_restore_pair[0]}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_mov_b32",
                    f"s1, s{scratch_restore_pair[1]}",
                    ["s1", f"s{scratch_restore_pair[1]}"],
                ),
            ]
        )

    if private_pattern_class == "src_private_base":
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b64",
                "s[0:1], src_private_base",
                ["s[0:1]", "src_private_base"],
            )
        )
        if isinstance(private_offset_source_sgpr, int):
            instructions.extend(
                [
                    make_instruction(
                        anchor_address,
                        "s_add_u32",
                        f"s0, s0, s{private_offset_source_sgpr}",
                        ["s0", "s0", f"s{private_offset_source_sgpr}"],
                    ),
                    make_instruction(
                        anchor_address,
                        "s_addc_u32",
                        "s1, s1, 0",
                        ["s1", "s1", "0"],
                    ),
                ]
            )
    elif private_pattern_class in {None, "setreg_flat_scratch_init", "flat_scratch_alias_init", "scalar_pair_update_only"}:
        if not isinstance(private_offset_source_sgpr, int):
            raise SystemExit(
                "mid-kernel helper injection requires an observed private-segment offset SGPR "
                f"for pattern {private_pattern_class!r}"
            )
        instructions.extend(
            [
                make_instruction(
                    anchor_address,
                    "s_add_u32",
                    f"s0, s0, s{private_offset_source_sgpr}",
                    ["s0", "s0", f"s{private_offset_source_sgpr}"],
                ),
                make_instruction(
                    anchor_address,
                    "s_addc_u32",
                    "s1, s1, 0",
                    ["s1", "s1", "0"],
                ),
            ]
        )
    else:
        raise SystemExit(
            "mid-kernel helper injection does not support private-segment pattern "
            f"{private_pattern_class!r}"
        )
    return instructions


def emit_mid_kernel_vgpr_save_restore(
    *,
    anchor_address: int,
    spill_plan: dict[str, Any] | None,
    scratch_restore_pair: list[int] | None,
    scratch_soffset_sgpr: int,
) -> tuple[list[dict], list[dict]]:
    if not isinstance(spill_plan, dict):
        return [], []
    if not isinstance(scratch_restore_pair, list) or len(scratch_restore_pair) != 2:
        return [], []
    source_vgprs = [int(value) for value in spill_plan.get("source_vgprs", [])]
    spill_offset = spill_plan.get("spill_offset")
    if not source_vgprs or not isinstance(spill_offset, int):
        return [], []

    address_setup = emit_mid_kernel_private_segment_address_setup(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        save_original=True,
    )

    before = list(address_setup)
    before.append(
        make_instruction(
            anchor_address,
            "s_mov_b32",
            f"s{scratch_soffset_sgpr}, 0",
            [f"s{scratch_soffset_sgpr}", "0"],
        )
    )
    for index, source_vgpr in enumerate(source_vgprs):
        store_offset = spill_offset + (index * 4)
        before.append(
            make_instruction(
                anchor_address,
                "buffer_store_dword",
                f"v{source_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{store_offset}",
                [
                    f"v{source_vgpr}",
                    "off",
                    "s[0:3]",
                    f"s{scratch_soffset_sgpr}",
                    f"offset:{store_offset}",
                ],
            )
        )
    before.extend(
        [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                "s0, s{}".format(scratch_restore_pair[0]),
                ["s0", f"s{scratch_restore_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                "s1, s{}".format(scratch_restore_pair[1]),
                ["s1", f"s{scratch_restore_pair[1]}"],
            ),
        ]
    )

    after = emit_mid_kernel_private_segment_address_setup(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        save_original=False,
    )
    after.append(
        make_instruction(
            anchor_address,
            "s_mov_b32",
            f"s{scratch_soffset_sgpr}, 0",
            [f"s{scratch_soffset_sgpr}", "0"],
        )
    )
    for index, source_vgpr in enumerate(source_vgprs):
        load_offset = spill_offset + (index * 4)
        after.append(
            make_instruction(
                anchor_address,
                "buffer_load_dword",
                f"v{source_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{load_offset}",
                [
                    f"v{source_vgpr}",
                    "off",
                    "s[0:3]",
                    f"s{scratch_soffset_sgpr}",
                    f"offset:{load_offset}",
                ],
            )
        )
    after.extend(
        [
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "vmcnt(0)",
                ["vmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                "s0, s{}".format(scratch_restore_pair[0]),
                ["s0", f"s{scratch_restore_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                "s1, s{}".format(scratch_restore_pair[1]),
                ["s1", f"s{scratch_restore_pair[1]}"],
            ),
        ]
    )
    return before, after


def emit_mid_kernel_sgpr_save_restore(
    *,
    anchor_address: int,
    spill_plan: dict[str, Any] | None,
    scratch_restore_pair: list[int] | None,
    scratch_soffset_sgpr: int,
    shuttle_vgpr: int = 0,
) -> tuple[list[dict], list[dict]]:
    if not isinstance(spill_plan, dict):
        return [], []
    if not isinstance(scratch_restore_pair, list) or len(scratch_restore_pair) != 2:
        return [], []
    source_sgprs = [int(value) for value in spill_plan.get("source_sgprs", [])]
    spill_offset = spill_plan.get("sgpr_spill_offset")
    if not source_sgprs or not isinstance(spill_offset, int):
        return [], []

    before = emit_mid_kernel_private_segment_address_setup(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        save_original=True,
    )
    before.append(
        make_instruction(
            anchor_address,
            "s_mov_b32",
            f"s{scratch_soffset_sgpr}, 0",
            [f"s{scratch_soffset_sgpr}", "0"],
        )
    )
    for index, source_sgpr in enumerate(source_sgprs):
        store_offset = spill_offset + (index * 4)
        before.extend(
            [
                make_instruction(
                    anchor_address,
                    "v_mov_b32_e32",
                    f"v{shuttle_vgpr}, s{source_sgpr}",
                    [f"v{shuttle_vgpr}", f"s{source_sgpr}"],
                ),
                make_instruction(
                    anchor_address,
                    "buffer_store_dword",
                    f"v{shuttle_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{store_offset}",
                    [
                        f"v{shuttle_vgpr}",
                        "off",
                        "s[0:3]",
                        f"s{scratch_soffset_sgpr}",
                        f"offset:{store_offset}",
                    ],
                ),
            ]
        )
    before.extend(
        [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s0, s{scratch_restore_pair[0]}",
                ["s0", f"s{scratch_restore_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s1, s{scratch_restore_pair[1]}",
                ["s1", f"s{scratch_restore_pair[1]}"],
            ),
        ]
    )

    after = emit_mid_kernel_private_segment_address_setup(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        save_original=False,
    )
    after.append(
        make_instruction(
            anchor_address,
            "s_mov_b32",
            f"s{scratch_soffset_sgpr}, 0",
            [f"s{scratch_soffset_sgpr}", "0"],
        )
    )
    for index, source_sgpr in enumerate(source_sgprs):
        load_offset = spill_offset + (index * 4)
        after.extend(
            [
                make_instruction(
                    anchor_address,
                    "buffer_load_dword",
                    f"v{shuttle_vgpr}, off, s[0:3], s{scratch_soffset_sgpr} offset:{load_offset}",
                    [
                        f"v{shuttle_vgpr}",
                        "off",
                        "s[0:3]",
                        f"s{scratch_soffset_sgpr}",
                        f"offset:{load_offset}",
                    ],
                ),
                make_instruction(
                    anchor_address,
                    "s_waitcnt",
                    "vmcnt(0)",
                    ["vmcnt(0)"],
                ),
                make_instruction(
                    anchor_address,
                    "v_readlane_b32",
                    f"s{source_sgpr}, v{shuttle_vgpr}, 0",
                    [f"s{source_sgpr}", f"v{shuttle_vgpr}", "0"],
                ),
            ]
        )
    after.extend(
        [
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s0, s{scratch_restore_pair[0]}",
                ["s0", f"s{scratch_restore_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s1, s{scratch_restore_pair[1]}",
                ["s1", f"s{scratch_restore_pair[1]}"],
            ),
        ]
    )
    return before, after


def emit_basic_block_event_arguments(
    *,
    anchor_address: int,
    site: dict,
    call_arguments: list[dict],
    timestamp_pair: list[int],
) -> list[dict]:
    instructions: list[dict] = []
    event_materialization = site.get("event_materialization", {})
    if not isinstance(event_materialization, dict):
        raise SystemExit("planned basic_block site is missing event materialization metadata")

    timestamp_arg = next((entry for entry in call_arguments if entry.get("kind") == "timestamp"), None)
    if timestamp_arg is None:
        raise SystemExit("thunk manifest did not describe a timestamp call argument")
    timestamp_vgprs = [int(value) for value in timestamp_arg.get("vgprs", [])]
    if len(timestamp_vgprs) != 2:
        raise SystemExit(f"timestamp call argument must occupy two VGPRs, got {timestamp_vgprs!r}")

    timestamp_operand = f"s[{timestamp_pair[0]}:{timestamp_pair[1]}]"
    instructions.extend(
        [
            make_instruction(anchor_address, "s_memtime", timestamp_operand, [timestamp_operand]),
            make_instruction(anchor_address, "s_waitcnt", "lgkmcnt(0)", ["lgkmcnt(0)"]),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[0]}, s{timestamp_pair[0]}",
                [f"v{timestamp_vgprs[0]}", f"s{timestamp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[1]}, s{timestamp_pair[1]}",
                [f"v{timestamp_vgprs[1]}", f"s{timestamp_pair[1]}"],
            ),
        ]
    )

    block_id_arg = next(
        (entry for entry in call_arguments if entry.get("kind") == "event" and entry.get("name") == "block_id"),
        None,
    )
    if block_id_arg is None:
        raise SystemExit("thunk manifest did not describe a basic_block block_id event argument")
    block_id_vgprs = [int(value) for value in block_id_arg.get("vgprs", [])]
    if len(block_id_vgprs) != 1:
        raise SystemExit(f"basic_block block_id must occupy one VGPR, got {block_id_vgprs!r}")
    block_id_materialization = event_materialization.get("block_id", {})
    if (
        not isinstance(block_id_materialization, dict)
        or str(block_id_materialization.get("kind", "")) != "static_block_id"
    ):
        raise SystemExit("planned basic_block site is missing a supported static block_id materialization")
    block_id_value = int(block_id_materialization.get("value", 0) or 0)
    instructions.append(
        make_instruction(
            anchor_address,
            "v_mov_b32_e32",
            f"v{block_id_vgprs[0]}, {block_id_value}",
            [f"v{block_id_vgprs[0]}", str(block_id_value)],
        )
    )
    return instructions


def basic_block_stub_instructions(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    thunk_name: str,
    site: dict,
    call_arguments: list[dict],
    staged_arguments: list[dict],
    timestamp_pair: list[int],
    target_pair: list[int],
    scratch_restore_pair: list[int],
    return_restore_pair: list[int],
    exec_restore_pair: list[int] | None,
    vcc_restore_pair: list[int],
    m0_restore_sgpr: int,
    builtin_liveins: dict[str, int] | None,
    spill_plan: dict[str, Any],
) -> list[dict]:
    instructions: list[dict] = []
    vgpr_save, vgpr_restore = emit_mid_kernel_vgpr_save_restore(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        scratch_soffset_sgpr=target_pair[0],
    )
    sgpr_save, sgpr_restore = emit_mid_kernel_sgpr_save_restore(
        anchor_address=anchor_address,
        spill_plan=spill_plan,
        scratch_restore_pair=scratch_restore_pair,
        scratch_soffset_sgpr=target_pair[0],
        shuttle_vgpr=0,
    )
    instructions.extend(vgpr_save)
    instructions.extend(sgpr_save)
    for staged_argument in staged_arguments:
        instructions.extend(
            emit_capture_load_and_marshal(
                anchor_address=anchor_address,
                kernarg_pair=kernarg_pair,
                temp_pair=[int(value) for value in staged_argument.get("staging_sgprs", [])],
                call_argument=staged_argument,
            )
        )
    instructions.extend(
        emit_basic_block_event_arguments(
            anchor_address=anchor_address,
            site=site,
            call_arguments=call_arguments,
            timestamp_pair=timestamp_pair,
        )
    )
    target_operand = f"s[{target_pair[0]}:{target_pair[1]}]"
    builtin_setup, _ = emit_helper_builtin_liveins(
        anchor_address=anchor_address,
        kernarg_pair=kernarg_pair,
        builtin_liveins=builtin_liveins,
        restore_pair=None,
    )
    instructions.extend(
        [
            make_instruction(anchor_address, "s_getpc_b64", target_operand, [target_operand]),
            make_instruction(
                anchor_address,
                "s_add_u32",
                f"s{target_pair[0]}, s{target_pair[0]}, {thunk_name}@rel32@lo+4",
                [f"s{target_pair[0]}", f"s{target_pair[0]}", f"{thunk_name}@rel32@lo+4"],
            ),
            make_instruction(
                anchor_address,
                "s_addc_u32",
                f"s{target_pair[1]}, s{target_pair[1]}, {thunk_name}@rel32@hi+4",
                [f"s{target_pair[1]}", f"s{target_pair[1]}", f"{thunk_name}@rel32@hi+4"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"s[{return_restore_pair[0]}:{return_restore_pair[1]}], s[30:31]",
                [f"s[{return_restore_pair[0]}:{return_restore_pair[1]}]", "s[30:31]"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"s[{vcc_restore_pair[0]}:{vcc_restore_pair[1]}], vcc",
                [f"s[{vcc_restore_pair[0]}:{vcc_restore_pair[1]}]", "vcc"],
            ),
            make_instruction(
                anchor_address,
                "s_mov_b32",
                f"s{m0_restore_sgpr}, m0",
                [f"s{m0_restore_sgpr}", "m0"],
            ),
        ]
    )
    instructions.extend(builtin_setup)
    if exec_restore_pair is not None:
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}], exec",
                [f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]", "exec"],
            )
        )
    instructions.append(
        make_instruction(
            anchor_address,
            "s_swappc_b64",
            f"s[30:31], {target_operand}",
            ["s[30:31]", target_operand],
        )
    )
    if exec_restore_pair is not None:
        instructions.append(
            make_instruction(
                anchor_address,
                "s_mov_b64",
                f"exec, s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]",
                ["exec", f"s[{exec_restore_pair[0]}:{exec_restore_pair[1]}]"],
            )
        )
    instructions.append(
        make_instruction(
            anchor_address,
            "s_mov_b32",
            f"m0, s{m0_restore_sgpr}",
            ["m0", f"s{m0_restore_sgpr}"],
        )
    )
    instructions.append(
        make_instruction(
            anchor_address,
            "s_mov_b64",
            f"vcc, s[{vcc_restore_pair[0]}:{vcc_restore_pair[1]}]",
            ["vcc", f"s[{vcc_restore_pair[0]}:{vcc_restore_pair[1]}]"],
        )
    )
    instructions.extend(sgpr_restore)
    instructions.append(
        make_instruction(
            anchor_address,
            "s_mov_b64",
            f"s[30:31], s[{return_restore_pair[0]}:{return_restore_pair[1]}]",
            ["s[30:31]", f"s[{return_restore_pair[0]}:{return_restore_pair[1]}]"],
        )
    )
    instructions.extend(vgpr_restore)
    return instructions


def emit_mid_kernel_kernarg_snapshot(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    saved_kernarg_pair: list[int],
) -> list[dict]:
    return [
        make_instruction(
            anchor_address,
            "s_mov_b64",
            f"s[{saved_kernarg_pair[0]}:{saved_kernarg_pair[1]}], s[{kernarg_pair[0]}:{kernarg_pair[1]}]",
            [
                f"s[{saved_kernarg_pair[0]}:{saved_kernarg_pair[1]}]",
                f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]",
            ],
        )
    ]


def inject_basic_block_stubs(
    *,
    ir: dict,
    function_name: str,
    kernel_plan: dict,
    thunk: dict,
    descriptor: dict | None,
    kernel_metadata: dict | None,
) -> dict:
    output = deepcopy(ir)
    function = find_function(output, function_name)
    analysis = analyze_kernel_calling_convention(function=function, descriptor=descriptor)
    entry_analysis = analyze_kernel_entry_abi(
        function=function,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    kernarg_base = analysis["inferred_kernarg_base"]
    if kernarg_base is None or not analysis.get("descriptor_has_kernarg_segment_ptr", False):
        raise SystemExit(
            f"function {function_name!r} is missing kernarg-base facts required for basic-block stub injection"
        )
    kernarg_pair = list(kernarg_base["base_pair"])
    sites = find_planned_sites(kernel_plan, when="basic_block", contract="basic_block_v1")
    if not sites:
        raise SystemExit(f"kernel plan for {function_name!r} did not contain any planned basic-block sites")
    require_no_helper_builtins(sites, mode="basic-block")

    hidden_ctx = kernel_plan.get("hidden_omniprobe_ctx", {})
    hidden_offset = int(hidden_ctx.get("offset", 0) or 0)
    thunk_name = str(thunk.get("thunk", ""))
    if not thunk_name:
        raise SystemExit("thunk manifest entry did not contain a thunk name")
    call_layout, call_arguments = call_arguments_from_thunk(thunk)
    allocated_vgprs = descriptor_allocated_vgpr_count(descriptor)
    if allocated_vgprs is not None and call_layout["total_dwords"] > allocated_vgprs:
        raise SystemExit(
            f"function {function_name!r} cannot marshal {call_layout['total_dwords']} dwords of call arguments "
            f"with only {allocated_vgprs} allocated VGPRs"
        )

    scalar_plan = reserve_mid_kernel_scalar_arguments(
        kernel_metadata=kernel_metadata,
        descriptor=descriptor,
        call_arguments=call_arguments,
        hidden_offset=hidden_offset,
    )
    builtin_liveins_raw = infer_builtin_livein_plan(
        kernel_metadata=kernel_metadata,
        descriptor=descriptor,
    )
    builtin_snapshot_plan = reserve_entry_builtin_snapshot(
        next_sgpr=scalar_plan["total_sgprs"],
        builtin_liveins=builtin_liveins_raw,
    )
    if isinstance(builtin_liveins_raw, dict):
        builtin_liveins = dict(builtin_liveins_raw)
        for key, saved_source in builtin_snapshot_plan["saved_sources"].items():
            builtin_liveins[key] = saved_source
        scalar_plan["total_sgprs"] = int(builtin_snapshot_plan["total_sgprs"])
    else:
        builtin_liveins = None
    spill_plan = reserve_mid_kernel_vgpr_spill(
        kernel_metadata=kernel_metadata,
        descriptor=descriptor,
        entry_analysis=entry_analysis,
        call_dword_count=call_layout["total_dwords"],
    )

    original_instructions = function.get("instructions", [])
    site_by_address: dict[int, dict] = {}
    for site in sites:
        injection_point = site.get("injection_point", {})
        if not isinstance(injection_point, dict):
            raise SystemExit("planned basic_block site is missing an injection_point")
        start_address = injection_point.get("start_address")
        if not isinstance(start_address, int):
            raise SystemExit("planned basic_block site is missing a basic-block start_address")
        site_by_address[start_address] = site

    mutated_instructions: list[dict] = []
    injected_sites: list[dict] = []
    if original_instructions:
        entry_anchor = int(original_instructions[0].get("address", function.get("start_address", 0)) or 0)
        mutated_instructions.extend(
            emit_mid_kernel_kernarg_snapshot(
                anchor_address=entry_anchor,
                kernarg_pair=kernarg_pair,
                saved_kernarg_pair=scalar_plan["saved_kernarg_pair"],
            )
        )
        mutated_instructions.extend(
            emit_entry_builtin_snapshot(
                anchor_address=entry_anchor,
                builtin_liveins=builtin_liveins_raw,
                snapshot_plan=builtin_snapshot_plan,
            )
        )
    for index, instruction in enumerate(original_instructions):
        address = int(instruction.get("address", 0) or 0)
        site = site_by_address.get(address)
        if site is not None:
            mutated_instructions.extend(
                basic_block_stub_instructions(
                    anchor_address=address,
                    kernarg_pair=scalar_plan["saved_kernarg_pair"],
                    thunk_name=thunk_name,
                    site=site,
                    call_arguments=call_arguments,
                    staged_arguments=scalar_plan["staged_arguments"],
                    timestamp_pair=scalar_plan["timestamp_pair"],
                    target_pair=scalar_plan["target_pair"],
                    scratch_restore_pair=scalar_plan["scratch_restore_pair"],
                    return_restore_pair=scalar_plan["return_restore_pair"],
                    exec_restore_pair=scalar_plan["exec_restore_pair"],
                    vcc_restore_pair=scalar_plan["vcc_restore_pair"],
                    m0_restore_sgpr=scalar_plan["m0_restore_sgpr"],
                    builtin_liveins=builtin_liveins,
                    spill_plan=spill_plan,
                )
            )
            injection_point = site.get("injection_point", {})
            injected_sites.append(
                {
                    "binary_site_id": site.get("binary_site_id"),
                    "block_id": injection_point.get("block_id"),
                    "block_label": injection_point.get("block_label"),
                    "start_address": address,
                    "original_instruction_index": index,
                }
            )
        mutated_instructions.append(instruction)
    if len(injected_sites) != len(sites):
        raise SystemExit(
            f"function {function_name!r} did not contain all planned basic-block insertion anchors"
        )

    function["instructions"] = mutated_instructions
    function["instrumentation"] = {
        "basic_block_stubs": {
            "mode": "basic_block",
            "when": "basic_block",
            "contract": "basic_block_v1",
            "call_source": "reserved_mid_kernel_stub_sgprs",
            "hidden_omniprobe_ctx_offset": hidden_offset,
            "thunk": thunk_name,
            "kernarg_pair": kernarg_pair,
            "call_arguments": call_arguments,
            "staged_call_arguments": scalar_plan["staged_arguments"],
            "staging_sgpr_base": scalar_plan["staging_sgpr_base"],
            "staging_sgpr_count": scalar_plan["staging_sgpr_count"],
            "saved_kernarg_pair": scalar_plan["saved_kernarg_pair"],
            "timestamp_pair": scalar_plan["timestamp_pair"],
            "target_pair": scalar_plan["target_pair"],
            "scratch_restore_pair": scalar_plan["scratch_restore_pair"],
            "return_restore_pair": scalar_plan["return_restore_pair"],
            "exec_restore_pair": scalar_plan["exec_restore_pair"],
            "vcc_restore_pair": scalar_plan["vcc_restore_pair"],
            "m0_restore_sgpr": scalar_plan["m0_restore_sgpr"],
            "helper_builtin_liveins": builtin_liveins,
            "entry_raw_builtin_liveins": builtin_liveins_raw,
            "builtin_snapshot_sgprs": builtin_snapshot_plan["saved_sources"],
            "builtin_snapshot_sgpr_base": builtin_snapshot_plan["snapshot_sgpr_base"],
            "builtin_snapshot_sgpr_count": builtin_snapshot_plan["snapshot_sgpr_count"],
            "preserved_low_vgprs": spill_plan,
            "private_segment_growth": spill_plan["private_segment_growth"],
            "injected_sites": injected_sites,
            "total_sgprs": scalar_plan["total_sgprs"],
        }
    }
    return output


def inject_lifecycle_stubs(
    *,
    ir: dict,
    function_name: str,
    kernel_plan: dict,
    thunk: dict,
    descriptor: dict | None,
    kernel_metadata: dict | None,
) -> dict:
    output = deepcopy(ir)
    function = find_function(output, function_name)
    analysis = analyze_kernel_calling_convention(function=function, descriptor=descriptor)
    entry_analysis = analyze_kernel_entry_abi(
        function=function,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    kernarg_base = analysis["inferred_kernarg_base"]
    if kernarg_base is None or not analysis.get("descriptor_has_kernarg_segment_ptr", False):
        raise SystemExit(f"function {function_name!r} is missing kernarg-base facts required for lifecycle stub injection")
    kernarg_pair = list(kernarg_base["base_pair"])

    hidden_ctx = kernel_plan.get("hidden_omniprobe_ctx", {})
    hidden_offset = int(hidden_ctx.get("offset", 0) or 0)
    entry_site = find_planned_site(kernel_plan, "kernel_entry")
    exit_site = find_planned_site(kernel_plan, "kernel_exit")
    if entry_site is not None and exit_site is not None:
        raise SystemExit(
            "binary lifecycle rewrite currently supports a single insertion point per kernel; split kernel_entry and kernel_exit into separate probes"
        )
    if entry_site is None and exit_site is None:
        raise SystemExit(f"kernel plan for {function_name!r} did not contain any planned lifecycle sites")

    original_instructions = function.get("instructions", [])
    mutated_instructions: list[dict] = []
    instrumentation: dict[str, dict] = {}
    allocated_vgprs = descriptor_allocated_vgpr_count(descriptor)

    if entry_site is not None:
        thunk_name = str(thunk.get("thunk", ""))
        if not thunk_name:
            raise SystemExit("thunk manifest entry did not contain a thunk name")
        call_layout, call_arguments = call_arguments_from_thunk(thunk)
        if allocated_vgprs is not None and call_layout["total_dwords"] > allocated_vgprs:
            raise SystemExit(
                f"function {function_name!r} cannot marshal {call_layout['total_dwords']} dwords of call arguments "
                f"with only {allocated_vgprs} allocated VGPRs"
            )
        entry_scalar_plan = reserve_entry_scalar_arguments(
            kernel_metadata=kernel_metadata,
            descriptor=descriptor,
            call_arguments=call_arguments,
            hidden_offset=hidden_offset,
        )
        builtin_liveins = infer_builtin_livein_plan(kernel_metadata=kernel_metadata, descriptor=descriptor)
        builtin_liveins_raw = dict(builtin_liveins) if isinstance(builtin_liveins, dict) else None
        builtin_snapshot_plan = reserve_entry_builtin_snapshot(
            next_sgpr=entry_scalar_plan["total_sgprs"],
            builtin_liveins=builtin_liveins_raw,
        )
        if isinstance(builtin_liveins, dict):
            builtin_liveins = dict(builtin_liveins)
            for key, saved_source in builtin_snapshot_plan["saved_sources"].items():
                builtin_liveins[key] = saved_source
        builtin_restore_plan = reserve_entry_builtin_restore(
            next_sgpr=builtin_snapshot_plan["total_sgprs"],
            builtin_liveins=builtin_liveins,
        )
        kernarg_restore_plan = reserve_entry_kernarg_restore(
            next_sgpr=builtin_restore_plan["total_sgprs"],
            kernarg_pair=kernarg_pair,
        )
        exec_restore_plan = reserve_entry_exec_restore(
            next_sgpr=kernarg_restore_plan["total_sgprs"],
        )
        livein_restore_plan = reserve_entry_livein_restore(
            next_sgpr=exec_restore_plan["total_sgprs"],
            descriptor=descriptor,
            entry_analysis=entry_analysis,
        )
        workitem_restore_plan = reserve_entry_workitem_restore(
            allocated_vgprs=allocated_vgprs,
            reserved_low_vgprs=call_layout["total_dwords"],
            descriptor=descriptor,
            entry_analysis=entry_analysis,
        )
        entry_anchor_index, entry_anchor_address = choose_entry_insertion_anchor(function, kernarg_base)
        entry_stub_instructions = lifecycle_entry_stub_instructions(
            anchor_address=entry_anchor_address,
            kernarg_pair=kernarg_pair,
            thunk_name=thunk_name,
            call_arguments=call_arguments,
            staged_arguments=entry_scalar_plan["staged_arguments"],
            timestamp_pair=entry_scalar_plan["timestamp_pair"],
            target_pair=entry_scalar_plan["target_pair"],
            builtin_liveins=builtin_liveins,
            builtin_restore_pair=builtin_restore_plan["restore_pair"],
            kernarg_restore_pair=kernarg_restore_plan["restore_pair"],
            exec_restore_pair=exec_restore_plan["restore_pair"],
            livein_restore_plan=livein_restore_plan,
            workitem_restore_plan=workitem_restore_plan,
        )
        instrumentation["lifecycle_entry_stub"] = {
            "mode": "lifecycle_entry",
            "when": "kernel_entry",
            "call_source": "reserved_entry_stub_sgprs",
            "hidden_omniprobe_ctx_offset": hidden_offset,
            "thunk": thunk_name,
            "kernarg_pair": kernarg_pair,
            "injected_before_instruction_index": entry_anchor_index,
            "injected_before_instruction_address": entry_anchor_address,
            "call_arguments": call_arguments,
            "staged_call_arguments": entry_scalar_plan["staged_arguments"],
            "staging_sgpr_base": entry_scalar_plan["staging_sgpr_base"],
            "staging_sgpr_count": entry_scalar_plan["staging_sgpr_count"],
            "timestamp_pair": entry_scalar_plan["timestamp_pair"],
            "target_pair": entry_scalar_plan["target_pair"],
            "helper_builtin_liveins": builtin_liveins,
            "entry_raw_builtin_liveins": builtin_liveins_raw,
            "builtin_snapshot_sgprs": builtin_snapshot_plan["saved_sources"],
            "builtin_snapshot_sgpr_base": builtin_snapshot_plan["snapshot_sgpr_base"],
            "builtin_snapshot_sgpr_count": builtin_snapshot_plan["snapshot_sgpr_count"],
            "builtin_restore_pair": builtin_restore_plan["restore_pair"],
            "kernarg_restore_pair": kernarg_restore_plan["restore_pair"],
            "exec_restore_pair": exec_restore_plan["restore_pair"],
            "entry_livein_source_sgprs": livein_restore_plan["source_sgprs"],
            "entry_livein_save_sgprs": livein_restore_plan["save_sgprs"],
            "entry_livein_save_sgpr_base": livein_restore_plan["save_sgpr_base"],
            "entry_livein_save_sgpr_count": livein_restore_plan["save_sgpr_count"],
            "entry_abi_analysis": entry_analysis,
            "preserved_workitem_vgprs": workitem_restore_plan,
            "private_segment_growth": 16,
            "total_sgprs": livein_restore_plan["total_sgprs"],
        }

    injected_sites: list[int] = []
    exit_stub_meta: dict | None = None
    if exit_site is not None:
        if not analysis.get("supported_for_lifecycle_exit_stub", False):
            raise SystemExit(f"function {function_name!r} is not supported for lifecycle-exit stub injection")
        lifecycle_call = analysis["resolved_lifecycle_call"]
        timestamp_pair = list(lifecycle_call["arg_pairs"][2]["source_sgpr_pair"])
        target_pair = list(lifecycle_call["target_pair"])
        thunk_name = str(thunk.get("thunk", ""))
        if not thunk_name:
            raise SystemExit("thunk manifest entry did not contain a thunk name")
        call_layout, call_arguments = call_arguments_from_thunk(thunk)
        if allocated_vgprs is not None and call_layout["total_dwords"] > allocated_vgprs:
            raise SystemExit(
                f"function {function_name!r} cannot marshal {call_layout['total_dwords']} dwords of call arguments "
                f"with only {allocated_vgprs} allocated VGPRs"
            )
        saved_scalar_plan = reserve_saved_scalar_arguments(
            kernel_metadata=kernel_metadata,
            descriptor=descriptor,
            call_arguments=call_arguments,
            hidden_offset=hidden_offset,
        )
        saved_arguments = saved_scalar_plan["saved_arguments"]
        builtin_liveins = infer_builtin_livein_plan(kernel_metadata=kernel_metadata, descriptor=descriptor)

        if original_instructions:
            entry_anchor = int(original_instructions[0].get("address", function.get("start_address", 0)) or 0)
            mutated_instructions.extend(
                lifecycle_entry_save_instructions(
                    anchor_address=entry_anchor,
                    kernarg_pair=kernarg_pair,
                    saved_arguments=saved_arguments,
                )
            )
        exit_stub_meta = {
            "mode": "lifecycle_exit",
            "when": "kernel_exit",
            "call_source": analysis.get("lifecycle_call_source"),
            "hidden_omniprobe_ctx_offset": hidden_offset,
            "thunk": thunk_name,
            "kernarg_pair": kernarg_pair,
            "timestamp_pair": timestamp_pair,
            "target_pair": target_pair,
            "call_arguments": call_arguments,
            "saved_call_arguments": saved_arguments,
            "saved_sgpr_base": saved_scalar_plan["saved_sgpr_base"],
            "saved_sgpr_count": saved_scalar_plan["saved_sgpr_count"],
            "helper_builtin_liveins": builtin_liveins,
            "private_segment_growth": 16,
            "total_sgprs": saved_scalar_plan["total_sgprs"],
        }

    if original_instructions:
        if entry_site is not None:
            entry_anchor = int(original_instructions[0].get("address", function.get("start_address", 0)) or 0)
            mutated_instructions.extend(
                emit_entry_builtin_snapshot(
                    anchor_address=entry_anchor,
                    builtin_liveins=instrumentation["lifecycle_entry_stub"]["entry_raw_builtin_liveins"],
                    snapshot_plan={
                        "saved_sources": instrumentation["lifecycle_entry_stub"]["builtin_snapshot_sgprs"],
                    },
                )
            )
        for index, instruction in enumerate(original_instructions):
            if entry_site is not None and index == instrumentation["lifecycle_entry_stub"]["injected_before_instruction_index"]:
                mutated_instructions.extend(entry_stub_instructions)
            if exit_stub_meta is not None and instruction.get("mnemonic") == "s_endpgm":
                anchor_address = int(instruction.get("address", 0) or 0)
                mutated_instructions.extend(
                    lifecycle_exit_stub_instructions(
                        anchor_address=anchor_address,
                        kernarg_pair=kernarg_pair,
                        timestamp_pair=exit_stub_meta["timestamp_pair"],
                        target_pair=exit_stub_meta["target_pair"],
                        thunk_name=exit_stub_meta["thunk"],
                        call_arguments=exit_stub_meta["call_arguments"],
                        saved_arguments=exit_stub_meta["saved_call_arguments"],
                        builtin_liveins=exit_stub_meta["helper_builtin_liveins"],
                    )
                )
                injected_sites.append(anchor_address)
            mutated_instructions.append(instruction)

    if exit_stub_meta is not None and not injected_sites:
        raise SystemExit(f"function {function_name!r} did not contain any s_endpgm exits to instrument")

    function["instructions"] = mutated_instructions
    if exit_stub_meta is not None:
        exit_stub_meta["injected_exit_addresses"] = injected_sites
        instrumentation["lifecycle_exit_stub"] = exit_stub_meta
    function["instrumentation"] = instrumentation
    return output


def main() -> int:
    args = parse_args()
    ir = load_json(Path(args.ir).resolve())
    plan = load_json(Path(args.plan).resolve())
    thunk_manifest = load_json(Path(args.thunk_manifest).resolve())
    manifest = load_json(Path(args.manifest).resolve()) if args.manifest else None
    kernel_plan = find_kernel_plan(plan, args.function)
    entry_site = find_planned_site(kernel_plan, "kernel_entry")
    exit_site = find_planned_site(kernel_plan, "kernel_exit")
    basic_block_sites = find_planned_sites(kernel_plan, when="basic_block", contract="basic_block_v1")
    active_modes = int(entry_site is not None) + int(exit_site is not None) + int(bool(basic_block_sites))
    if entry_site is not None and exit_site is not None:
        raise SystemExit(
            "binary lifecycle rewrite currently supports a single insertion point per kernel; split kernel_entry and kernel_exit into separate probes"
        )
    if active_modes > 1:
        raise SystemExit(
            "binary rewrite currently supports one instrumentation mode per kernel; split lifecycle and basic_block probes into separate rewrites"
        )
    if entry_site is not None:
        thunk = find_thunk(thunk_manifest, kernel_plan, "kernel_entry")
        rewrite_mode = "lifecycle"
    elif exit_site is not None:
        thunk = find_thunk(thunk_manifest, kernel_plan, "kernel_exit")
        rewrite_mode = "lifecycle"
    elif basic_block_sites:
        thunk = find_thunk(thunk_manifest, kernel_plan, "basic_block")
        rewrite_mode = "basic_block"
    else:
        raise SystemExit(
            f"kernel plan for {args.function!r} did not contain any supported planned rewrite sites"
        )
    descriptor = find_descriptor(manifest, args.function)
    kernel_metadata = find_kernel_metadata(manifest, args.function)
    if rewrite_mode == "lifecycle":
        mutated = inject_lifecycle_stubs(
            ir=ir,
            function_name=args.function,
            kernel_plan=kernel_plan,
            thunk=thunk,
            descriptor=descriptor,
            kernel_metadata=kernel_metadata,
        )
    elif rewrite_mode == "basic_block":
        mutated = inject_basic_block_stubs(
            ir=ir,
            function_name=args.function,
            kernel_plan=kernel_plan,
            thunk=thunk,
            descriptor=descriptor,
            kernel_metadata=kernel_metadata,
        )
    else:
        raise SystemExit(f"unsupported rewrite mode {rewrite_mode!r}")
    save_json(Path(args.output).resolve(), mutated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
