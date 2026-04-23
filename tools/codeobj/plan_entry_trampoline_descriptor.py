#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from copy import deepcopy
from pathlib import Path

from regenerate_code_object import (
    ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS,
    ABI_SENSITIVE_RSRC2_BOOL_FIELDS,
    granulated_sgpr_count,
    granulated_vgpr_count,
)


SEMANTIC_RSRC1_FIELDS = (
    "float_round_mode_32",
    "float_round_mode_16_64",
    "float_denorm_mode_32",
    "float_denorm_mode_16_64",
    "enable_dx10_clamp",
    "enable_ieee_mode",
    "fp16_overflow",
    "workgroup_processor_mode",
    "memory_ordered",
    "forward_progress",
)

SEMANTIC_RSRC2_FIELDS = (
    "exception_fp_ieee_invalid_op",
    "exception_fp_denorm_src",
    "exception_fp_ieee_div_zero",
    "exception_fp_ieee_overflow",
    "exception_fp_ieee_underflow",
    "exception_fp_ieee_inexact",
    "exception_int_div_zero",
)

LAUNCH_ONLY_KERNEL_CODE_FIELDS = (
    "enable_sgpr_private_segment_buffer",
    "enable_sgpr_kernarg_segment_ptr",
    "enable_sgpr_flat_scratch_init",
    "enable_sgpr_private_segment_size",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plan the descriptor/resource merge policy for a compiler-generated "
            "entry trampoline plus an extracted original kernel body."
        )
    )
    parser.add_argument("--original-manifest", required=True, help="Manifest JSON for the original code object")
    parser.add_argument("--original-kernel", required=True, help="Original kernel name to hand off into")
    parser.add_argument(
        "--trampoline-manifest",
        required=True,
        help="Manifest JSON for the compiled trampoline code object",
    )
    parser.add_argument(
        "--trampoline-kernel",
        default=None,
        help="Optional trampoline kernel name; required only when the manifest contains multiple kernels",
    )
    parser.add_argument(
        "--expected-trampoline-manifest",
        default=None,
        help="Optional generated trampoline manifest; when provided the planner compares its declared body-handoff contract against the derived contract",
    )
    parser.add_argument(
        "--expected-trampoline-kernel",
        default=None,
        help="Optional trampoline kernel name to select from the generated trampoline manifest",
    )
    parser.add_argument("--output", default=None, help="Optional path for the JSON report")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def descriptor_field_value(descriptor: dict, section: str, field: str) -> int:
    section_obj = descriptor.get(section, {})
    if not isinstance(section_obj, dict):
        return 0
    return int(section_obj.get(field, 0) or 0)


def find_descriptor(manifest: dict, kernel_name: str) -> dict:
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            continue
        if descriptor.get("kernel_name") == kernel_name or descriptor.get("name") == f"{kernel_name}.kd":
            return deepcopy(descriptor)
    raise SystemExit(f"descriptor for kernel {kernel_name!r} not found")


def find_kernel_metadata(manifest: dict, kernel_name: str) -> dict | None:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == kernel_name or kernel.get("symbol") == f"{kernel_name}.kd":
            return deepcopy(kernel)
    return None


def choose_trampoline_kernel(manifest: dict, explicit_name: str | None) -> str:
    if explicit_name:
        return explicit_name
    candidates = []
    for kernel in manifest.get("kernels", {}).get("metadata", {}).get("kernels", []):
        if not isinstance(kernel, dict):
            continue
        name = str(kernel.get("name", "") or "")
        if name:
            candidates.append(name)
    if not candidates:
        for descriptor in manifest.get("kernels", {}).get("descriptors", []):
            if not isinstance(descriptor, dict):
                continue
            name = str(descriptor.get("kernel_name", "") or "")
            if name:
                candidates.append(name)
    unique = sorted(set(candidates))
    if len(unique) != 1:
        raise SystemExit(
            "--trampoline-kernel is required when the trampoline manifest does not identify exactly one kernel"
        )
    return unique[0]


def find_generated_trampoline_entry(manifest: dict, trampoline_kernel: str) -> dict | None:
    kernels = manifest.get("kernels", [])
    if not isinstance(kernels, list):
        return None
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("trampoline_kernel") == trampoline_kernel:
            return deepcopy(kernel)
    return None


def comparable_declared_body_handoff(contract: dict | None) -> dict | None:
    if not isinstance(contract, dict):
        return None
    return {
        "original_kernel": contract.get("original_kernel"),
        "body_model": contract.get("body_model"),
        "kernarg_size": int(contract.get("kernarg_size", 0) or 0),
        "user_sgpr_count": int(contract.get("user_sgpr_count", 0) or 0),
        "wavefront_size32": int(contract.get("wavefront_size32", 0) or 0),
        "entry_abi": {
            "compute_pgm_rsrc2": {
                **{
                    field: int(
                        contract.get("entry_abi", {}).get("compute_pgm_rsrc2", {}).get(field, 0) or 0
                    )
                    for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS
                },
                "enable_vgpr_workitem_id": int(
                    contract.get("entry_abi", {})
                    .get("compute_pgm_rsrc2", {})
                    .get("enable_vgpr_workitem_id", 0)
                    or 0
                ),
            },
            "kernel_code_properties": {
                **{
                    field: int(
                        contract.get("entry_abi", {}).get("kernel_code_properties", {}).get(field, 0)
                        or 0
                    )
                    for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS
                }
            },
        },
    }


def diff_contracts(expected: dict | None, derived: dict) -> list[str]:
    if expected is None:
        return ["generated trampoline manifest did not declare a body-handoff contract"]
    mismatches: list[str] = []
    if expected.get("original_kernel") != derived.get("original_kernel"):
        mismatches.append(
            f"original_kernel expected {expected.get('original_kernel')!r} derived {derived.get('original_kernel')!r}"
        )
    if expected.get("body_model") is not None and derived.get("body_model") is not None and expected.get("body_model") != derived.get("body_model"):
        mismatches.append(
            f"body_model expected {expected.get('body_model')!r} derived {derived.get('body_model')!r}"
        )
    for field in ("kernarg_size", "user_sgpr_count", "wavefront_size32"):
        if int(expected.get(field, 0) or 0) != int(derived.get(field, 0) or 0):
            mismatches.append(
                f"{field} expected {expected.get(field)!r} derived {derived.get(field)!r}"
            )
    for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS:
        expected_value = int(
            expected.get("entry_abi", {}).get("compute_pgm_rsrc2", {}).get(field, 0) or 0
        )
        derived_value = int(
            derived.get("entry_abi", {}).get("compute_pgm_rsrc2", {}).get(field, 0) or 0
        )
        if expected_value != derived_value:
            mismatches.append(
                f"entry_abi.compute_pgm_rsrc2.{field} expected {expected_value} derived {derived_value}"
            )
    expected_workitem = int(
        expected.get("entry_abi", {})
        .get("compute_pgm_rsrc2", {})
        .get("enable_vgpr_workitem_id", 0)
        or 0
    )
    derived_workitem = int(
        derived.get("entry_abi", {})
        .get("compute_pgm_rsrc2", {})
        .get("enable_vgpr_workitem_id", 0)
        or 0
    )
    if expected_workitem != derived_workitem:
        mismatches.append(
            "entry_abi.compute_pgm_rsrc2.enable_vgpr_workitem_id "
            f"expected {expected_workitem} derived {derived_workitem}"
        )
    for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS:
        expected_value = int(
            expected.get("entry_abi", {}).get("kernel_code_properties", {}).get(field, 0) or 0
        )
        derived_value = int(
            derived.get("entry_abi", {}).get("kernel_code_properties", {}).get(field, 0) or 0
        )
        if expected_value != derived_value:
            mismatches.append(
                f"entry_abi.kernel_code_properties.{field} expected {expected_value} derived {derived_value}"
            )
    return mismatches


def actual_count(metadata_kernel: dict | None, field: str, granulated_value: int) -> int:
    if isinstance(metadata_kernel, dict):
        value = int(metadata_kernel.get(field, 0) or 0)
        if value > 0:
            return value
    return (granulated_value + 1) * 8


def report_entry(
    *,
    field: str,
    policy: str,
    original: int,
    trampoline: int,
    merged: int,
    rationale: str,
) -> dict:
    return {
        "field": field,
        "policy": policy,
        "original": original,
        "trampoline": trampoline,
        "merged": merged,
        "rationale": rationale,
    }


def main() -> int:
    args = parse_args()
    original_manifest = load_json(Path(args.original_manifest).resolve())
    trampoline_manifest = load_json(Path(args.trampoline_manifest).resolve())

    original_descriptor = find_descriptor(original_manifest, args.original_kernel)
    original_metadata = find_kernel_metadata(original_manifest, args.original_kernel)
    trampoline_kernel = choose_trampoline_kernel(trampoline_manifest, args.trampoline_kernel)
    trampoline_descriptor = find_descriptor(trampoline_manifest, trampoline_kernel)
    trampoline_metadata = find_kernel_metadata(trampoline_manifest, trampoline_kernel)

    original_sgprs = actual_count(
        original_metadata,
        "sgpr_count",
        descriptor_field_value(original_descriptor, "compute_pgm_rsrc1", "granulated_wavefront_sgpr_count"),
    )
    original_vgprs = actual_count(
        original_metadata,
        "vgpr_count",
        descriptor_field_value(original_descriptor, "compute_pgm_rsrc1", "granulated_workitem_vgpr_count"),
    )
    trampoline_sgprs = actual_count(
        trampoline_metadata,
        "sgpr_count",
        descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc1", "granulated_wavefront_sgpr_count"),
    )
    trampoline_vgprs = actual_count(
        trampoline_metadata,
        "vgpr_count",
        descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc1", "granulated_workitem_vgpr_count"),
    )

    merged_sgprs = max(original_sgprs, trampoline_sgprs)
    merged_vgprs = max(original_vgprs, trampoline_vgprs)
    merged_group_segment = int(original_descriptor.get("group_segment_fixed_size", 0) or 0) + int(
        trampoline_descriptor.get("group_segment_fixed_size", 0) or 0
    )
    merged_private_segment = max(
        int(original_descriptor.get("private_segment_fixed_size", 0) or 0),
        int(trampoline_descriptor.get("private_segment_fixed_size", 0) or 0),
    )

    field_policies: list[dict] = []
    unresolved: list[str] = []

    field_policies.append(
        report_entry(
            field="group_segment_fixed_size",
            policy="additive-conservative",
            original=int(original_descriptor.get("group_segment_fixed_size", 0) or 0),
            trampoline=int(trampoline_descriptor.get("group_segment_fixed_size", 0) or 0),
            merged=merged_group_segment,
            rationale=(
                "Static LDS for the trampoline and for the imported original body may both "
                "need residency in the final linked kernel. Treating this as additive is "
                "conservative until final section/link layout is validated."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="private_segment_fixed_size",
            policy="max",
            original=int(original_descriptor.get("private_segment_fixed_size", 0) or 0),
            trampoline=int(trampoline_descriptor.get("private_segment_fixed_size", 0) or 0),
            merged=merged_private_segment,
            rationale=(
                "The merged kernel must accommodate the larger fixed private-segment "
                "requirement observed in either the trampoline path or the original body."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="kernarg_size",
            policy="launch-contract-only",
            original=int(original_descriptor.get("kernarg_size", 0) or 0),
            trampoline=int(trampoline_descriptor.get("kernarg_size", 0) or 0),
            merged=int(trampoline_descriptor.get("kernarg_size", 0) or 0),
            rationale=(
                "The dispatch targets the compiler-owned trampoline. The launch descriptor must "
                "describe the trampoline kernarg layout, while original-body argument recovery is "
                "a handoff concern."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="sgpr_count",
            policy="max",
            original=original_sgprs,
            trampoline=trampoline_sgprs,
            merged=merged_sgprs,
            rationale=(
                "The final combined kernel must reserve enough SGPRs for the larger of the "
                "trampoline path and the imported original body."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="vgpr_count",
            policy="max",
            original=original_vgprs,
            trampoline=trampoline_vgprs,
            merged=merged_vgprs,
            rationale=(
                "The final combined kernel must reserve enough VGPRs for the larger of the "
                "trampoline path and the imported original body."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="compute_pgm_rsrc3.shared_vgpr_count",
            policy="max",
            original=descriptor_field_value(original_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
            trampoline=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
            merged=max(
                descriptor_field_value(original_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
                descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
            ),
            rationale="Shared VGPR reservation is treated as a resource-footprint maximum.",
        )
    )

    for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS:
        field_policies.append(
            report_entry(
                field=f"compute_pgm_rsrc2.{field}",
                policy="launch-contract-only",
                original=descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", field),
                trampoline=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", field),
                merged=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", field),
                rationale=(
                    "Kernel-entry workgroup delivery is owned by the compiler-generated trampoline. "
                    "The original body's expectations must be reconstructed during handoff."
                ),
            )
        )

    field_policies.append(
        report_entry(
            field="compute_pgm_rsrc2.enable_vgpr_workitem_id",
            policy="launch-contract-only",
            original=descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"),
            trampoline=descriptor_field_value(
                trampoline_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"
            ),
            merged=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"),
            rationale=(
                "Kernel-entry workitem-id VGPR delivery is determined by the trampoline launch "
                "contract. Original-body consumption must be rebuilt from Omniprobe-owned state."
            ),
        )
    )
    field_policies.append(
        report_entry(
            field="compute_pgm_rsrc2.user_sgpr_count",
            policy="launch-contract-only",
            original=descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", "user_sgpr_count"),
            trampoline=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", "user_sgpr_count"),
            merged=descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", "user_sgpr_count"),
            rationale="User SGPR allocation is part of the trampoline's dispatch-facing ABI.",
        )
    )
    field_policies.append(
        report_entry(
            field="compute_pgm_rsrc2.enable_private_segment",
            policy="union",
            original=descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", "enable_private_segment"),
            trampoline=descriptor_field_value(
                trampoline_descriptor, "compute_pgm_rsrc2", "enable_private_segment"
            ),
            merged=1 if merged_private_segment > 0 else 0,
            rationale=(
                "Any merged fixed private-segment requirement implies private-segment enablement "
                "in the launch descriptor."
            ),
        )
    )

    for field in SEMANTIC_RSRC2_FIELDS:
        original_value = descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", field)
        trampoline_value = descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", field)
        if original_value != trampoline_value:
            unresolved.append(
                f"{field} differs between original ({original_value}) and trampoline ({trampoline_value})"
            )
        field_policies.append(
            report_entry(
                field=f"compute_pgm_rsrc2.{field}",
                policy="must-match",
                original=original_value,
                trampoline=trampoline_value,
                merged=trampoline_value,
                rationale="These exception-policy bits affect kernel execution semantics.",
            )
        )

    for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS:
        field_policies.append(
            report_entry(
                field=f"kernel_code_properties.{field}",
                policy="launch-contract-only",
                original=descriptor_field_value(original_descriptor, "kernel_code_properties", field),
                trampoline=descriptor_field_value(trampoline_descriptor, "kernel_code_properties", field),
                merged=descriptor_field_value(trampoline_descriptor, "kernel_code_properties", field),
                rationale=(
                    "Dispatch-facing SGPR enablement is part of the trampoline-owned launch ABI. "
                    "Original-body access must come from runtime snapshots."
                ),
            )
        )

    for field in LAUNCH_ONLY_KERNEL_CODE_FIELDS:
        field_policies.append(
            report_entry(
                field=f"kernel_code_properties.{field}",
                policy="launch-contract-only",
                original=descriptor_field_value(original_descriptor, "kernel_code_properties", field),
                trampoline=descriptor_field_value(trampoline_descriptor, "kernel_code_properties", field),
                merged=descriptor_field_value(trampoline_descriptor, "kernel_code_properties", field),
                rationale="These SGPR enablement bits describe hardware entry into the trampoline.",
            )
        )

    uses_dynamic_stack = max(
        descriptor_field_value(original_descriptor, "kernel_code_properties", "uses_dynamic_stack"),
        descriptor_field_value(trampoline_descriptor, "kernel_code_properties", "uses_dynamic_stack"),
    )
    field_policies.append(
        report_entry(
            field="kernel_code_properties.uses_dynamic_stack",
            policy="union",
            original=descriptor_field_value(original_descriptor, "kernel_code_properties", "uses_dynamic_stack"),
            trampoline=descriptor_field_value(
                trampoline_descriptor, "kernel_code_properties", "uses_dynamic_stack"
            ),
            merged=uses_dynamic_stack,
            rationale="If either side uses a dynamic stack path, the merged launch descriptor must preserve it.",
        )
    )

    wave32_original = descriptor_field_value(original_descriptor, "kernel_code_properties", "enable_wavefront_size32")
    wave32_trampoline = descriptor_field_value(
        trampoline_descriptor, "kernel_code_properties", "enable_wavefront_size32"
    )
    if wave32_original != wave32_trampoline:
        unresolved.append(
            f"enable_wavefront_size32 differs between original ({wave32_original}) and trampoline ({wave32_trampoline})"
        )
    field_policies.append(
        report_entry(
            field="kernel_code_properties.enable_wavefront_size32",
            policy="must-match",
            original=wave32_original,
            trampoline=wave32_trampoline,
            merged=wave32_trampoline,
            rationale=(
                "Wave32 versus wave64 changes calling convention and builtin behavior. "
                "A real handoff prototype must keep the original body in the mode it was compiled for."
            ),
        )
    )

    for field in SEMANTIC_RSRC1_FIELDS:
        original_value = descriptor_field_value(original_descriptor, "compute_pgm_rsrc1", field)
        trampoline_value = descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc1", field)
        if original_value != trampoline_value:
            unresolved.append(
                f"{field} differs between original ({original_value}) and trampoline ({trampoline_value})"
            )
        field_policies.append(
            report_entry(
                field=f"compute_pgm_rsrc1.{field}",
                policy="must-match",
                original=original_value,
                trampoline=trampoline_value,
                merged=trampoline_value,
                rationale="These descriptor bits affect instruction semantics or execution guarantees.",
            )
        )

    merged_descriptor = {
        "group_segment_fixed_size": merged_group_segment,
        "private_segment_fixed_size": merged_private_segment,
        "kernarg_size": int(trampoline_descriptor.get("kernarg_size", 0) or 0),
        "compute_pgm_rsrc3": {
            "shared_vgpr_count": max(
                descriptor_field_value(original_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
                descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "shared_vgpr_count"),
            ),
            "inst_pref_size": descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "inst_pref_size"),
            "trap_on_start": descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "trap_on_start"),
            "trap_on_end": descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "trap_on_end"),
            "image_op": descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc3", "image_op"),
        },
        "compute_pgm_rsrc1": {
            "granulated_wavefront_sgpr_count": granulated_sgpr_count(merged_sgprs),
            "granulated_workitem_vgpr_count": granulated_vgpr_count(merged_vgprs),
        },
        "compute_pgm_rsrc2": {
            "user_sgpr_count": descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", "user_sgpr_count"),
            "enable_private_segment": 1 if merged_private_segment > 0 else 0,
            "enable_vgpr_workitem_id": descriptor_field_value(
                trampoline_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"
            ),
            **{
                field: descriptor_field_value(trampoline_descriptor, "compute_pgm_rsrc2", field)
                for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS
            },
        },
        "kernel_code_properties": {
            "uses_dynamic_stack": uses_dynamic_stack,
            "enable_wavefront_size32": wave32_trampoline,
            **{
                field: descriptor_field_value(trampoline_descriptor, "kernel_code_properties", field)
                for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS + LAUNCH_ONLY_KERNEL_CODE_FIELDS
            },
        },
        "metadata": {
            "sgpr_count": merged_sgprs,
            "vgpr_count": merged_vgprs,
        },
    }

    body_handoff = {
        "original_kernel": args.original_kernel,
        "body_model": None,
        "kernarg_size": int(original_descriptor.get("kernarg_size", 0) or 0),
        "user_sgpr_count": descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", "user_sgpr_count"),
        "wavefront_size32": wave32_original,
        "entry_abi": {
            "compute_pgm_rsrc2": {
                **{
                    field: descriptor_field_value(original_descriptor, "compute_pgm_rsrc2", field)
                    for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS
                },
                "enable_vgpr_workitem_id": descriptor_field_value(
                    original_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"
                ),
            },
            "kernel_code_properties": {
                **{
                    field: descriptor_field_value(original_descriptor, "kernel_code_properties", field)
                    for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS
                }
            },
        },
    }

    declared_body_handoff_contract = None
    declared_body_handoff_matches_planner = None
    declared_body_handoff_mismatches: list[str] = []
    if args.expected_trampoline_manifest:
        expected_manifest = load_json(Path(args.expected_trampoline_manifest).resolve())
        expected_kernel = args.expected_trampoline_kernel or trampoline_kernel
        generated_entry = find_generated_trampoline_entry(expected_manifest, expected_kernel)
        declared_body_handoff_contract = (
            generated_entry.get("declared_body_handoff_contract")
            if isinstance(generated_entry, dict)
            else None
        )
        declared_body_handoff_mismatches = diff_contracts(
            comparable_declared_body_handoff(declared_body_handoff_contract),
            body_handoff,
        )
        declared_body_handoff_matches_planner = not declared_body_handoff_mismatches

    result = {
        "original_kernel": args.original_kernel,
        "trampoline_kernel": trampoline_kernel,
        "safe_for_phase3_handoff_prototype": not unresolved,
        "unresolved": unresolved,
        "original": {
            "descriptor": original_descriptor,
            "metadata": original_metadata,
            "actual_sgpr_count": original_sgprs,
            "actual_vgpr_count": original_vgprs,
        },
        "trampoline": {
            "descriptor": trampoline_descriptor,
            "metadata": trampoline_metadata,
            "actual_sgpr_count": trampoline_sgprs,
            "actual_vgpr_count": trampoline_vgprs,
        },
        "merged_launch_candidate": merged_descriptor,
        "body_handoff_requirements": body_handoff,
        "declared_body_handoff_contract": declared_body_handoff_contract,
        "declared_body_handoff_matches_planner": declared_body_handoff_matches_planner,
        "declared_body_handoff_mismatches": declared_body_handoff_mismatches,
        "field_policies": field_policies,
    }

    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
