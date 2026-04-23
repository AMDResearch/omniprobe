#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi
from emit_entry_handoff_recipe import (
    build_recipe,
    find_descriptor,
    find_function,
    find_kernel_metadata,
    load_json,
)


HELPER_POLICY = {
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "notes": [
        "Heavyweight helpers must not rely on compiler-generated live-ins or builtins at arbitrary insertion points.",
        "Helpers are expected to consume Omniprobe-captured entry snapshot fields plus runtime dispatch payload inputs instead.",
    ],
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a normalized entry resume/re-entry matrix across multiple "
            "AMDGPU kernels using Omniprobe's existing handoff recipe analysis."
        )
    )
    parser.add_argument("cases", help="JSON file describing the matrix cases")
    parser.add_argument("--output", default=None, help="Optional output JSON path")
    return parser.parse_args()


def unique_ordered(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def resolve_case_path(base_dir: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = (base_dir / path).resolve()
    return path


def extract_field_names(container: dict, object_name: str) -> list[str]:
    runtime_objects = container.get("runtime_objects", {})
    fields = runtime_objects.get(object_name, {}).get("fields", [])
    return [
        str(entry.get("name"))
        for entry in fields
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    ]


def summarize_case(case: dict, base_dir: Path) -> dict:
    case_id = case.get("id")
    if not isinstance(case_id, str) or not case_id:
        raise SystemExit("each matrix case requires a non-empty string id")
    function_name = case.get("function")
    if not isinstance(function_name, str) or not function_name:
        raise SystemExit(f"matrix case {case_id!r} is missing a function name")

    ir_path = resolve_case_path(base_dir, str(case.get("ir", "")))
    manifest_path = resolve_case_path(base_dir, str(case.get("manifest", "")))
    if not ir_path.is_file():
        raise SystemExit(f"matrix case {case_id!r} IR file was not found: {ir_path}")
    if not manifest_path.is_file():
        raise SystemExit(f"matrix case {case_id!r} manifest file was not found: {manifest_path}")

    ir = load_json(ir_path)
    manifest = load_json(manifest_path)
    function = find_function(ir, function_name)
    descriptor = find_descriptor(manifest, function_name)
    kernel_metadata = find_kernel_metadata(manifest, function_name)
    analysis = {
        "arch": ir.get("arch"),
        **analyze_kernel_entry_abi(
            function=function,
            descriptor=descriptor,
            kernel_metadata=kernel_metadata,
        ),
    }
    recipe = build_recipe(
        function_name=function_name,
        analysis=analysis,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    handoff = recipe.get("supplemental_handoff_contract", {})
    wrapper_source_analysis = recipe.get("wrapper_source_analysis", {})

    workitem_pattern = recipe.get("entry_requirements", {}).get("observed_workitem_id_materialization") or {}
    private_pattern = recipe.get("entry_requirements", {}).get("observed_private_segment_materialization") or {}
    reconstruction_actions = recipe.get("reconstruction_actions", [])

    return {
        "id": case_id,
        "label": case.get("label") or case_id,
        "function": function_name,
        "arch": recipe.get("arch"),
        "input": {
            "ir": str(ir_path),
            "manifest": str(manifest_path),
        },
        "supported": bool(recipe.get("supported")),
        "supported_class": recipe.get("supported_class"),
        "blockers": recipe.get("blockers", []),
        "entry_shape": {
            "wavefront_size": recipe.get("descriptor_summary", {}).get("wavefront_size"),
            "workitem_vgpr_count": recipe.get("entry_requirements", {}).get("entry_workitem_vgpr_count"),
            "workitem_pattern": workitem_pattern.get("pattern_class") or "descriptor-declared",
            "private_pattern": private_pattern.get("pattern_class"),
            "system_sgpr_roles": [
                entry.get("role")
                for entry in recipe.get("entry_requirements", {}).get("entry_system_sgpr_roles", [])
                if isinstance(entry, dict) and isinstance(entry.get("role"), str)
            ],
        },
        "resume_requirements": {
            "direct_branch_supported": bool(wrapper_source_analysis.get("direct_branch_supported")),
            "reconstruction_after_clobber_supported": bool(
                wrapper_source_analysis.get("reconstruction_after_clobber_supported")
            ),
            "current_wrapper_blockers": wrapper_source_analysis.get(
                "reconstruction_after_clobber_blockers", []
            ),
            "reconstruction_actions": reconstruction_actions,
            "dispatch_payload_fields": extract_field_names(handoff, "dispatch_payload"),
            "entry_snapshot_fields": extract_field_names(handoff, "entry_snapshot"),
            "validation_fields": extract_field_names(handoff, "validation"),
        },
        "helper_policy": HELPER_POLICY,
        "raw_recipe": recipe,
    }


def build_class_summary(cases: list[dict]) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    for case in cases:
        key = str(case.get("supported_class") or "unsupported")
        grouped.setdefault(key, []).append(case)

    summaries: list[dict] = []
    for supported_class in sorted(grouped):
        entries = grouped[supported_class]
        summaries.append(
            {
                "supported_class": None if supported_class == "unsupported" else supported_class,
                "case_ids": [str(entry["id"]) for entry in entries],
                "arches": unique_ordered([str(entry.get("arch")) for entry in entries if entry.get("arch")]),
                "wavefront_sizes": unique_ordered(
                    [
                        str(entry.get("entry_shape", {}).get("wavefront_size"))
                        for entry in entries
                        if entry.get("entry_shape", {}).get("wavefront_size") is not None
                    ]
                ),
                "workitem_patterns": unique_ordered(
                    [
                        str(entry.get("entry_shape", {}).get("workitem_pattern"))
                        for entry in entries
                        if entry.get("entry_shape", {}).get("workitem_pattern") is not None
                    ]
                ),
                "private_patterns": unique_ordered(
                    [
                        str(entry.get("entry_shape", {}).get("private_pattern"))
                        for entry in entries
                        if entry.get("entry_shape", {}).get("private_pattern") is not None
                    ]
                ),
                "dispatch_payload_fields": unique_ordered(
                    [
                        field
                        for entry in entries
                        for field in entry.get("resume_requirements", {}).get("dispatch_payload_fields", [])
                    ]
                ),
                "entry_snapshot_fields": unique_ordered(
                    [
                        field
                        for entry in entries
                        for field in entry.get("resume_requirements", {}).get("entry_snapshot_fields", [])
                    ]
                ),
                "validation_fields": unique_ordered(
                    [
                        field
                        for entry in entries
                        for field in entry.get("resume_requirements", {}).get("validation_fields", [])
                    ]
                ),
                "reconstruction_actions": unique_ordered(
                    [
                        str(action.get("action"))
                        for entry in entries
                        for action in entry.get("resume_requirements", {}).get("reconstruction_actions", [])
                        if isinstance(action, dict) and isinstance(action.get("action"), str)
                    ]
                ),
                "current_wrapper_blockers": unique_ordered(
                    [
                        str(blocker)
                        for entry in entries
                        for blocker in entry.get("resume_requirements", {}).get("current_wrapper_blockers", [])
                    ]
                ),
                "direct_branch_supported": all(
                    bool(entry.get("resume_requirements", {}).get("direct_branch_supported"))
                    for entry in entries
                ),
                "reconstruction_after_clobber_supported": all(
                    bool(entry.get("resume_requirements", {}).get("reconstruction_after_clobber_supported"))
                    for entry in entries
                ),
                "helper_policy": HELPER_POLICY,
            }
        )
    return summaries


def main() -> int:
    args = parse_args()
    cases_path = Path(args.cases).resolve()
    payload = load_json(cases_path)
    case_specs = payload.get("cases", [])
    if not isinstance(case_specs, list) or not case_specs:
        raise SystemExit("matrix cases file must contain a non-empty cases list")

    base_dir = cases_path.parent
    cases = [summarize_case(case, base_dir) for case in case_specs]
    matrix = {
        "schema": "omniprobe.entry_resume_matrix.v1",
        "generator": "emit_entry_resume_matrix.py",
        "source": str(cases_path),
        "helper_contract_note": (
            "Heavyweight helpers are expected to consume wrapper-captured state "
            "and runtime payloads rather than compiler-generated live-ins or builtins."
        ),
        "cases": cases,
        "class_summary": build_class_summary(cases),
    }
    rendered = json.dumps(matrix, indent=2) + "\n"
    if args.output:
        Path(args.output).resolve().write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
