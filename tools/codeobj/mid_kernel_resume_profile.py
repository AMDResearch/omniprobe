#!/usr/bin/env python3
from __future__ import annotations

from typing import Any


HELPER_POLICY = {
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "notes": [
        "Heavyweight helpers must not rely on compiler-generated live-ins or builtins at arbitrary insertion points.",
        "Helpers are expected to consume Omniprobe-captured site/dispatch state plus runtime payload inputs instead.",
    ],
}

SUPPORTED_BINARY_HELPER_BUILTINS = [
    "block_dim",
    "block_idx",
    "dispatch_id",
    "exec",
    "grid_dim",
    "hw_id",
    "lane_id",
    "thread_idx",
    "wave_id",
    "wavefront_size",
]

HELPER_RUNTIME_VIEWS = [
    "runtime.raw_hidden_ctx",
    "runtime.entry_snapshot",
    "runtime.dispatch_uniform",
    "runtime.dispatch_id",
    "runtime.site_snapshot",
    "runtime.dh_builtins",
]

SUPPORTED_WORKITEM_PATTERNS = {
    None,
    "direct_vgpr_xyz",
    "packed_v0_10_10_10_unpack",
    "single_vgpr_workitem_id",
}

SUPPORTED_PRIVATE_PATTERNS = {
    None,
    "setreg_flat_scratch_init",
    "flat_scratch_alias_init",
    "src_private_base",
    "scalar_pair_update_only",
}

WORKITEM_PATTERN_LABELS = {
    None: "descriptor-declared",
    "direct_vgpr_xyz": "direct-vgpr-xyz",
    "packed_v0_10_10_10_unpack": "packed-v0-10_10_10-unpack",
    "single_vgpr_workitem_id": "single-vgpr-workitem-id",
}

PRIVATE_PATTERN_LABELS = {
    None: "s0-s1-plus-offset-sgpr",
    "setreg_flat_scratch_init": "setreg-flat-scratch",
    "flat_scratch_alias_init": "flat-scratch-alias",
    "src_private_base": "src-private-base",
    "scalar_pair_update_only": "scalar-pair-update-only",
}


def unique_ordered(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def _pattern_class(analysis: dict, field: str) -> str | None:
    payload = analysis.get(field)
    if not isinstance(payload, dict):
        return None
    value = payload.get("pattern_class")
    return str(value) if isinstance(value, str) else None


def _role_names(analysis: dict) -> list[str]:
    return [
        str(entry.get("role"))
        for entry in analysis.get("entry_system_sgpr_roles", [])
        if isinstance(entry, dict) and isinstance(entry.get("role"), str)
    ]


def _private_offset_source_sgpr(analysis: dict) -> int | None:
    private_materialization = analysis.get("observed_private_segment_materialization")
    if not isinstance(private_materialization, dict):
        private_materialization = None
    if isinstance(private_materialization, dict):
        details = private_materialization.get("details", {})
        if isinstance(details, dict):
            pair_updates = details.get("pair_updates", [])
            if isinstance(pair_updates, list):
                for entry in pair_updates:
                    if (
                        isinstance(entry, dict)
                        and entry.get("pair") == [0, 1]
                        and isinstance(entry.get("offset_sgpr"), int)
                    ):
                        return int(entry["offset_sgpr"])
    for entry in analysis.get("entry_system_sgpr_roles", []):
        if (
            isinstance(entry, dict)
            and entry.get("role") == "private_segment_wave_offset"
            and isinstance(entry.get("sgpr"), int)
        ):
            return int(entry["sgpr"])
    return None


def _label_for_pattern(pattern: str | None, labels: dict[str | None, str]) -> str:
    return labels.get(pattern, str(pattern or "unknown-pattern").replace("_", "-"))


def classify_mid_kernel_supported_class(
    *,
    analysis: dict,
    descriptor: dict | None,
) -> tuple[str | None, list[str]]:
    blockers: list[str] = []

    if not analysis.get("descriptor_has_kernarg_segment_ptr", False):
        blockers.append("missing-kernarg-segment-ptr")
    if not analysis.get("inferred_kernarg_base"):
        blockers.append("kernarg-base-not-observed")

    wavefront_size = int(analysis.get("wavefront_size", 0) or 0)
    if wavefront_size not in {32, 64}:
        blockers.append(f"unsupported-wavefront-size-{wavefront_size}")

    rsrc2 = (descriptor or {}).get("compute_pgm_rsrc2", {})
    if not int(rsrc2.get("enable_private_segment", 0) or 0):
        blockers.append("missing-private-segment-wave-offset-livein")

    workitem_pattern = _pattern_class(analysis, "observed_workitem_id_materialization")
    if workitem_pattern not in SUPPORTED_WORKITEM_PATTERNS:
        blockers.append(f"unsupported-workitem-pattern-{workitem_pattern}")

    private_pattern = _pattern_class(analysis, "observed_private_segment_materialization")
    if private_pattern not in SUPPORTED_PRIVATE_PATTERNS:
        blockers.append(f"unsupported-private-pattern-{private_pattern}")

    private_offset_source_sgpr = _private_offset_source_sgpr(analysis)
    if private_pattern in {
        None,
        "setreg_flat_scratch_init",
        "flat_scratch_alias_init",
        "scalar_pair_update_only",
    } and private_offset_source_sgpr is None:
        blockers.append("missing-private-segment-offset-sgpr")

    if blockers:
        return None, unique_ordered(blockers)

    supported_class = (
        f"wave{wavefront_size}-"
        f"{_label_for_pattern(workitem_pattern, WORKITEM_PATTERN_LABELS)}-"
        f"{_label_for_pattern(private_pattern, PRIVATE_PATTERN_LABELS)}-"
        "mid-kernel-private-spill-v1"
    )
    return supported_class, []


def build_mid_kernel_reconstruction_actions(analysis: dict) -> list[dict]:
    private_pattern = _pattern_class(analysis, "observed_private_segment_materialization")
    offset_sgpr = _private_offset_source_sgpr(analysis)

    actions: list[dict] = [
        {
            "action": "snapshot-kernarg-pair-at-entry",
            "source": "descriptor-declared-kernarg-segment-ptr",
        },
        {
            "action": "reserve-stub-sgpr-workspace",
            "min_sgpr": 64,
            "reason": "avoid overlap with helper callee SGPR reuse",
        },
        {
            "action": "spill-allocated-vgprs-to-private-segment-tail",
            "storage_class": "private_segment_tail",
        },
        {
            "action": "spill-live-sgprs-via-vgpr-shuttle",
            "storage_class": "private_segment_tail",
            "excluded_sgprs": [30, 31],
        },
        {
            "action": "save-control-registers",
            "registers": ["s30", "s31", "exec", "vcc", "m0"],
        },
    ]

    address_source = (
        "src_private_base"
        if private_pattern == "src_private_base"
        else "saved-s0-s1-plus-offset-sgpr"
    )
    actions.append(
        {
            "action": "reconstruct-private-segment-address",
            "pattern_class": private_pattern,
            "address_source": address_source,
            "offset_source_sgpr": offset_sgpr,
        }
    )
    return actions


def build_mid_kernel_resume_profile(
    *,
    function_name: str,
    arch: str | None,
    analysis: dict,
    descriptor: dict | None,
    kernel_metadata: dict | None,
) -> dict:
    supported_class, blockers = classify_mid_kernel_supported_class(
        analysis=analysis,
        descriptor=descriptor,
    )
    reconstruction_actions = build_mid_kernel_reconstruction_actions(analysis)
    private_pattern = _pattern_class(analysis, "observed_private_segment_materialization")
    workitem_pattern = _pattern_class(analysis, "observed_workitem_id_materialization")

    return {
        "function": function_name,
        "arch": arch,
        "supported_class": supported_class,
        "supported": supported_class is not None,
        "blockers": blockers,
        "instrumentation_mode": "binary-safe",
        "supported_modes": ["basic_block", "memory_op"] if supported_class is not None else [],
        "descriptor_summary": {
            "kernarg_size": int((descriptor or {}).get("kernarg_size", 0) or 0),
            "user_sgpr_count": int(
                ((descriptor or {}).get("compute_pgm_rsrc2", {}) or {}).get("user_sgpr_count", 0) or 0
            ),
            "private_segment_fixed_size": int(
                (descriptor or {}).get("private_segment_fixed_size", 0) or 0
            ),
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
            "enable_private_segment": int(
                ((descriptor or {}).get("compute_pgm_rsrc2", {}) or {}).get("enable_private_segment", 0) or 0
            ),
        },
        "kernel_metadata_summary": {
            "sgpr_count": int((kernel_metadata or {}).get("sgpr_count", 0) or 0),
            "vgpr_count": int((kernel_metadata or {}).get("vgpr_count", 0) or 0),
            "kernarg_segment_size": int((kernel_metadata or {}).get("kernarg_segment_size", 0) or 0),
        },
        "entry_shape": {
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
            "workitem_vgpr_count": int(analysis.get("entry_workitem_vgpr_count", 0) or 0),
            "workitem_pattern": workitem_pattern or "descriptor-declared",
            "private_pattern": private_pattern,
            "private_offset_source_sgpr": _private_offset_source_sgpr(analysis),
            "system_sgpr_roles": _role_names(analysis),
        },
        "resume_requirements": {
            "requires_kernarg_snapshot": True,
            "requires_private_segment_wave_offset_livein": True,
            "requires_private_segment_tail_growth": True,
            "spill_storage_class": "private_segment_tail",
            "stub_sgpr_floor": 64,
            "preserved_state_classes": [
                "allocated_vgprs",
                "live_sgprs_except_s30_s31",
                "return_pc",
                "exec",
                "vcc",
                "m0",
            ],
            "helper_runtime_views": list(HELPER_RUNTIME_VIEWS),
            "supported_helper_builtins": list(SUPPORTED_BINARY_HELPER_BUILTINS),
            "reconstruction_actions": reconstruction_actions,
            "current_injector_blockers": blockers,
        },
        "helper_policy": HELPER_POLICY,
    }
