#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a fail-closed original-body entry handoff recipe from Omniprobe's "
            "AMDGPU entry-ABI analysis."
        )
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument("--manifest", required=True, help="Code-object manifest JSON")
    parser.add_argument("--function", required=True, help="Original kernel function name")
    parser.add_argument("--output", default=None, help="Optional output JSON path")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def find_function(ir: dict, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"function {function_name!r} not found in IR")
    return function


def find_descriptor(manifest: dict, function_name: str) -> dict:
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            continue
        if descriptor.get("kernel_name") == function_name or descriptor.get("name") == f"{function_name}.kd":
            return descriptor
    raise SystemExit(f"descriptor for function {function_name!r} not found")


def find_kernel_metadata(manifest: dict, function_name: str) -> dict | None:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == function_name or kernel.get("symbol") == f"{function_name}.kd":
            return kernel
    return None


def classify_supported_class(analysis: dict) -> tuple[str | None, list[str]]:
    blockers: list[str] = []

    if not analysis.get("descriptor_has_kernarg_segment_ptr", False):
        blockers.append("missing-kernarg-segment-ptr")
    if not analysis.get("inferred_kernarg_base"):
        blockers.append("kernarg-base-not-observed")

    wavefront_size = int(analysis.get("wavefront_size", 0) or 0)
    if wavefront_size not in {32, 64}:
        blockers.append(f"unsupported-wavefront-size-{wavefront_size}")

    workitem_vgpr_count = int(analysis.get("entry_workitem_vgpr_count", 0) or 0)
    if workitem_vgpr_count != 3:
        blockers.append(f"unsupported-workitem-vgpr-count-{workitem_vgpr_count}")

    system_roles = analysis.get("entry_system_sgpr_roles", [])
    role_names = [entry.get("role") for entry in system_roles if isinstance(entry, dict)]
    expected_roles = [
        "workgroup_id_x",
        "workgroup_id_y",
        "workgroup_id_z",
        "private_segment_wave_offset",
    ]
    if role_names != expected_roles:
        blockers.append(f"unsupported-system-sgpr-role-layout-{role_names}")

    private_pattern = (
        analysis.get("observed_private_segment_materialization", {}) or {}
    ).get("pattern_class")
    if private_pattern not in {"setreg_flat_scratch_init", "flat_scratch_alias_init", "src_private_base"}:
        blockers.append(f"unsupported-private-pattern-{private_pattern}")

    workitem_pattern = (
        analysis.get("observed_workitem_id_materialization", {}) or {}
    ).get("pattern_class")
    if workitem_pattern not in {None, "direct_vgpr_xyz", "packed_v0_10_10_10_unpack"}:
        blockers.append(f"unsupported-workitem-pattern-{workitem_pattern}")

    if blockers:
        return None, blockers

    if wavefront_size == 32 and workitem_pattern in {None, "direct_vgpr_xyz"}:
        if private_pattern == "setreg_flat_scratch_init":
            return "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1", blockers
        blockers.append(f"unsupported-wave32-private-pattern-{private_pattern}")
        return None, blockers

    if wavefront_size == 64 and workitem_pattern == "packed_v0_10_10_10_unpack":
        if private_pattern == "flat_scratch_alias_init":
            return "wave64-packed-v0-10_10_10-flat-scratch-alias-v1", blockers
        if private_pattern == "src_private_base":
            return "wave64-packed-v0-10_10_10-src-private-base-v1", blockers
        blockers.append(f"unsupported-wave64-private-pattern-{private_pattern}")
        return None, blockers

    blockers.append(
        "unsupported-entry-shape-"
        f"wave{wavefront_size}-{workitem_pattern}-{private_pattern}"
    )
    return None, blockers


def build_reconstruction_actions(analysis: dict) -> list[dict]:
    actions: list[dict] = []
    kernarg_base = analysis.get("inferred_kernarg_base") or {}
    base_pair = kernarg_base.get("base_pair") or []
    if len(base_pair) == 2:
        actions.append(
            {
                "action": "materialize-kernarg-base-pair",
                "target_sgprs": [int(base_pair[0]), int(base_pair[1])],
                "source": "original-launch-kernarg",
            }
        )

    for entry in analysis.get("entry_system_sgpr_roles", []):
        if not isinstance(entry, dict):
            continue
        role = entry.get("role")
        sgpr = entry.get("sgpr")
        if not isinstance(role, str) or not isinstance(sgpr, int):
            continue
        actions.append(
            {
                "action": "materialize-system-sgpr",
                "role": role,
                "target_sgpr": sgpr,
                "source": f"reconstructed-{role}",
            }
        )

    workitem_vgpr_count = int(analysis.get("entry_workitem_vgpr_count", 0) or 0)
    if workitem_vgpr_count:
        actions.append(
            {
                "action": "materialize-entry-workitem-vgprs",
                "count": workitem_vgpr_count,
                "source_pattern": (
                    (analysis.get("observed_workitem_id_materialization", {}) or {}).get("pattern_class")
                    or "descriptor-declared"
                ),
            }
        )

    private_materialization = analysis.get("observed_private_segment_materialization") or {}
    if private_materialization:
        actions.append(
            {
                "action": "materialize-private-segment-state",
                "pattern_class": private_materialization.get("pattern_class"),
            }
        )

    actions.append(
        {
            "action": "require-wavefront-mode",
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
        }
    )
    return actions


def build_wrapper_source_analysis(analysis: dict, actions: list[dict]) -> dict:
    action_analysis: list[dict] = []
    blockers: list[str] = []

    for action in actions:
        action_name = action.get("action")
        record = {
            "action": action_name,
            "preserve_without_clobber": True,
            "reconstruct_after_clobber_with_current_wrapper_only": False,
            "blocker": None,
        }
        if action_name == "materialize-kernarg-base-pair":
            record["blocker"] = "no-independent-kernarg-source-in-current-wrapper"
        elif action_name == "materialize-system-sgpr":
            role = action.get("role")
            if role in {"workgroup_id_x", "workgroup_id_y", "workgroup_id_z"}:
                record["blocker"] = "no-independent-current-workgroup-id-source"
            elif role == "private_segment_wave_offset":
                record["blocker"] = "no-independent-private-segment-wave-offset-source"
            else:
                record["blocker"] = f"no-independent-source-for-{role}"
        elif action_name == "materialize-entry-workitem-vgprs":
            record["blocker"] = "no-independent-entry-workitem-vgpr-source"
        elif action_name == "materialize-private-segment-state":
            record["blocker"] = "requires-original-private-state-or-supplemental-handoff"
        elif action_name == "require-wavefront-mode":
            record["reconstruct_after_clobber_with_current_wrapper_only"] = True
            record["blocker"] = None
        else:
            record["blocker"] = "unclassified-wrapper-source-gap"

        blocker = record.get("blocker")
        if blocker:
            blockers.append(str(blocker))
        action_analysis.append(record)

    unique_blockers = []
    for blocker in blockers:
        if blocker not in unique_blockers:
            unique_blockers.append(blocker)

    return {
        "model": "direct-entry-wrapper-v1",
        "direct_branch_supported": True,
        "reconstruction_after_clobber_supported": False,
        "reconstruction_after_clobber_blockers": unique_blockers,
        "action_analysis": action_analysis,
    }


def build_supplemental_handoff_contract(
    *,
    function_name: str,
    supported_class: str | None,
    analysis: dict,
    actions: list[dict],
) -> dict:
    validation_requirements: list[dict] = [
        {
            "name": "wavefront_size",
            "kind": "u32",
            "required": True,
            "source_class": "descriptor_derived",
            "variability": "dispatch_constant",
            "producer": "descriptor-and-launch-validation",
            "purpose": "validate wrapper launch mode before branch-to-body handoff",
            "satisfies_actions": ["require-wavefront-mode"],
        }
    ]
    fields: list[dict] = [
        {
            "name": "original_kernarg_pointer",
            "kind": "u64",
            "required": True,
            "source_class": "dispatch_carried",
            "variability": "dispatch_constant",
            "producer": "runtime-dispatch-rewrite",
            "purpose": "re-materialize the original kernarg base pair after wrapper-side clobber",
            "satisfies_actions": ["materialize-kernarg-base-pair"],
        },
        {
            "name": "workgroup_id_x",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "workgroup_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore entry system SGPR role workgroup_id_x",
            "satisfies_actions": ["materialize-system-sgpr"],
            "role": "workgroup_id_x",
        },
        {
            "name": "workgroup_id_y",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "workgroup_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore entry system SGPR role workgroup_id_y",
            "satisfies_actions": ["materialize-system-sgpr"],
            "role": "workgroup_id_y",
        },
        {
            "name": "workgroup_id_z",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "workgroup_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore entry system SGPR role workgroup_id_z",
            "satisfies_actions": ["materialize-system-sgpr"],
            "role": "workgroup_id_z",
        },
        {
            "name": "private_segment_wave_offset",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "wave_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore the entry private-segment wave offset live-in",
            "satisfies_actions": ["materialize-system-sgpr", "materialize-private-segment-state"],
            "role": "private_segment_wave_offset",
        },
        {
            "name": "entry_workitem_id_x",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "lane_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore the canonical x workitem-id component into the expected entry VGPR contract",
            "satisfies_actions": ["materialize-entry-workitem-vgprs"],
        },
        {
            "name": "entry_workitem_id_y",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "lane_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore the canonical y workitem-id component into the expected entry VGPR contract",
            "satisfies_actions": ["materialize-entry-workitem-vgprs"],
        },
        {
            "name": "entry_workitem_id_z",
            "kind": "u32",
            "required": True,
            "source_class": "entry_captured",
            "variability": "lane_variant",
            "producer": "wrapper-entry-snapshot",
            "purpose": "restore the canonical z workitem-id component into the expected entry VGPR contract",
            "satisfies_actions": ["materialize-entry-workitem-vgprs"],
        },
    ]

    private_pattern = (
        analysis.get("observed_private_segment_materialization", {}) or {}
    ).get("pattern_class")
    if private_pattern in {"setreg_flat_scratch_init", "flat_scratch_alias_init", "src_private_base"}:
        fields.extend(
            [
                {
                    "name": "entry_private_base_lo",
                    "kind": "u32",
                    "required": True,
                    "source_class": "entry_captured",
                    "variability": "wave_variant",
                    "producer": "wrapper-entry-snapshot-or-private-state-reconstruction",
                    "purpose": "supply the low dword of the original private base materialization source",
                    "satisfies_actions": ["materialize-private-segment-state"],
                },
                {
                    "name": "entry_private_base_hi",
                    "kind": "u32",
                    "required": True,
                    "source_class": "entry_captured",
                    "variability": "wave_variant",
                    "producer": "wrapper-entry-snapshot-or-private-state-reconstruction",
                    "purpose": "supply the high dword of the original private base materialization source",
                    "satisfies_actions": ["materialize-private-segment-state"],
                },
            ]
        )

    if supported_class is None:
        fields = []
        validation_requirements = []

    dispatch_payload_fields = [
        entry for entry in fields if str(entry.get("source_class", "")) == "dispatch_carried"
    ]
    entry_snapshot_fields = [
        entry for entry in fields if str(entry.get("source_class", "")) == "entry_captured"
    ]

    return {
        "schema": "omniprobe.entry_handoff.hidden_v1",
        "original_kernel": function_name,
        "supported_class": supported_class,
        "required": supported_class is not None,
        "fields": fields,
        "validation_requirements": validation_requirements,
        "runtime_objects": {
            "dispatch_payload": {
                "name": "hidden_handoff_dispatch_payload_v1",
                "producer": "runtime-dispatch-rewrite",
                "transport": "wrapper-only hidden pointer or suffix carrier",
                "fields": dispatch_payload_fields,
            },
            "entry_snapshot": {
                "name": "entry_snapshot_v1",
                "producer": "wrapper-entry-snapshot",
                "transport": "wrapper-captured before helper execution",
                "fields": entry_snapshot_fields,
            },
            "validation": {
                "name": "launch_validation_v1",
                "producer": "descriptor-and-launch-validation",
                "fields": validation_requirements,
            },
        },
        "transport_classes": {
            "dispatch_carried": "Populated by the runtime/interceptor once per dispatch and valid for the whole grid.",
            "entry_captured": "Captured by the wrapper from original entry live-ins before helper execution perturbs the ABI state.",
            "descriptor_derived": "Validated or derived from descriptor/launch state rather than carried in the hidden payload.",
        },
        "notes": [
            "This contract is for the Omniprobe-owned wrapper dispatch ABI, not the original imported body ABI.",
            "The wrapper may run helpers against this canonical handoff state before reconstructing the original entry ABI and branching to the imported body.",
            "Only dispatch-carried fields are general host-populatable hidden-payload inputs. Workgroup-, wave-, and lane-variant fields must be preserved or snapshotted inside the wrapper itself.",
        ],
        "future_runtime_integration": {
            "producer": "interceptor/runtime dispatch rewrite",
            "consumer": "entry wrapper reconstructor",
            "transport": "hidden wrapper-only handoff pointer or suffix-ABI carrier",
        },
    }


def build_recipe(*, function_name: str, analysis: dict, descriptor: dict, kernel_metadata: dict | None) -> dict:
    supported_class, blockers = classify_supported_class(analysis)
    reconstruction_actions = build_reconstruction_actions(analysis)
    recipe = {
        "function": function_name,
        "arch": analysis.get("arch"),
        "supported_class": supported_class,
        "supported": supported_class is not None,
        "blockers": blockers,
        "descriptor_summary": {
            "kernarg_size": int(descriptor.get("kernarg_size", 0) or 0),
            "user_sgpr_count": int(
                (descriptor.get("compute_pgm_rsrc2", {}) or {}).get("user_sgpr_count", 0) or 0
            ),
            "private_segment_fixed_size": int(descriptor.get("private_segment_fixed_size", 0) or 0),
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
        },
        "kernel_metadata_summary": {
            "sgpr_count": int((kernel_metadata or {}).get("sgpr_count", 0) or 0),
            "vgpr_count": int((kernel_metadata or {}).get("vgpr_count", 0) or 0),
            "kernarg_segment_size": int((kernel_metadata or {}).get("kernarg_segment_size", 0) or 0),
        },
        "entry_requirements": {
            "entry_livein_sgprs": analysis.get("entry_livein_sgprs", []),
            "entry_system_sgpr_roles": analysis.get("entry_system_sgpr_roles", []),
            "entry_workitem_vgpr_count": int(analysis.get("entry_workitem_vgpr_count", 0) or 0),
            "inferred_kernarg_base": analysis.get("inferred_kernarg_base"),
            "observed_workitem_id_materialization": analysis.get("observed_workitem_id_materialization"),
            "observed_private_segment_materialization": analysis.get("observed_private_segment_materialization"),
        },
        "reconstruction_actions": reconstruction_actions,
        "wrapper_source_analysis": build_wrapper_source_analysis(analysis, reconstruction_actions),
        "supplemental_handoff_contract": build_supplemental_handoff_contract(
            function_name=function_name,
            supported_class=supported_class,
            analysis=analysis,
            actions=reconstruction_actions,
        ),
        "handoff_constraints": {
            "must_match_wavefront_mode": True,
            "must_preserve_kernarg_layout": True,
            "must_preserve_private_segment_state": True,
            "must_preserve_entry_workitem_vgprs": True,
        },
    }
    return recipe


def main() -> int:
    args = parse_args()
    ir = load_json(Path(args.ir).resolve())
    manifest = load_json(Path(args.manifest).resolve())
    function = find_function(ir, args.function)
    descriptor = find_descriptor(manifest, args.function)
    kernel_metadata = find_kernel_metadata(manifest, args.function)

    analysis = {
        "arch": ir.get("arch"),
        **analyze_kernel_entry_abi(
            function=function,
            descriptor=descriptor,
            kernel_metadata=kernel_metadata,
        ),
    }
    recipe = build_recipe(
        function_name=args.function,
        analysis=analysis,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    payload = json.dumps(recipe, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
