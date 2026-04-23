#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from amdgpu_entry_abi import analyze_kernel_entry_abi
from emit_entry_handoff_recipe import (
    find_descriptor,
    find_function,
    find_kernel_metadata,
    load_json,
)
from mid_kernel_resume_profile import build_mid_kernel_resume_profile, unique_ordered


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a normalized mid-kernel resume matrix across multiple AMDGPU "
            "kernels using Omniprobe's current binary-safe spill/reconstruction model."
        )
    )
    parser.add_argument("cases", help="JSON file describing the matrix cases")
    parser.add_argument("--output", default=None, help="Optional output JSON path")
    return parser.parse_args()


def resolve_case_path(base_dir: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = (base_dir / path).resolve()
    return path


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
    analysis = analyze_kernel_entry_abi(
        function=function,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    profile = build_mid_kernel_resume_profile(
        function_name=function_name,
        arch=ir.get("arch"),
        analysis=analysis,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )

    return {
        "id": case_id,
        "label": case.get("label") or case_id,
        "function": function_name,
        "arch": profile.get("arch"),
        "input": {
            "ir": str(ir_path),
            "manifest": str(manifest_path),
        },
        "supported": bool(profile.get("supported")),
        "supported_class": profile.get("supported_class"),
        "blockers": profile.get("blockers", []),
        "entry_shape": profile.get("entry_shape", {}),
        "resume_requirements": profile.get("resume_requirements", {}),
        "helper_policy": profile.get("helper_policy", {}),
        "raw_profile": profile,
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
                "arches": unique_ordered(
                    [str(entry.get("arch")) for entry in entries if entry.get("arch")]
                ),
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
                "supported_modes": unique_ordered(
                    [
                        str(mode)
                        for entry in entries
                        for mode in entry.get("raw_profile", {}).get("supported_modes", [])
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
                "helper_runtime_views": unique_ordered(
                    [
                        str(view)
                        for entry in entries
                        for view in entry.get("resume_requirements", {}).get("helper_runtime_views", [])
                    ]
                ),
                "supported_helper_builtins": unique_ordered(
                    [
                        str(name)
                        for entry in entries
                        for name in entry.get("resume_requirements", {}).get("supported_helper_builtins", [])
                    ]
                ),
                "current_injector_blockers": unique_ordered(
                    [
                        str(blocker)
                        for entry in entries
                        for blocker in entry.get("resume_requirements", {}).get("current_injector_blockers", [])
                    ]
                ),
                "helper_policy": entries[0].get("helper_policy", {}),
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
        "schema": "omniprobe.mid_kernel_resume_matrix.v1",
        "generator": "emit_mid_kernel_resume_matrix.py",
        "source": str(cases_path),
        "helper_contract_note": (
            "Heavyweight mid-kernel helpers are expected to consume Omniprobe-captured "
            "site/dispatch/runtime state rather than compiler-generated live-ins or builtins."
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
