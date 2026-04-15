#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


SGPR_RANGE_RE = re.compile(r"\bs\[(\d+):(\d+)\]")
SGPR_SINGLE_RE = re.compile(r"\bs(\d+)\b")
VGPR_RANGE_RE = re.compile(r"\bv\[(\d+):(\d+)\]")
VGPR_SINGLE_RE = re.compile(r"\bv(\d+)\b")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Assess whether an edited kernel IR still looks safe to pair with the "
            "original raw kernel descriptor bytes."
        )
    )
    parser.add_argument("original_ir", help="Original instruction-level IR JSON")
    parser.add_argument("candidate_ir", help="Candidate instruction-level IR JSON")
    parser.add_argument("manifest", help="Code-object manifest JSON")
    parser.add_argument(
        "--function",
        default=None,
        help="Kernel function name to analyze; required when multiple kernels exist",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of a text report",
    )
    return parser.parse_args()


def load_json(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def list_kernel_names(manifest: dict) -> list[str]:
    names = []
    for kernel in manifest.get("kernels", {}).get("metadata", {}).get("kernels", []):
        name = kernel.get("name")
        if name and name not in names:
            names.append(name)
    return names


def choose_function_name(manifest: dict, explicit: str | None) -> str:
    kernel_names = list_kernel_names(manifest)
    if explicit:
        if explicit not in kernel_names:
            available = ", ".join(kernel_names)
            raise SystemExit(f"function {explicit!r} not found; available kernels: {available}")
        return explicit
    if len(kernel_names) != 1:
        available = ", ".join(kernel_names)
        raise SystemExit(
            f"--function is required when multiple kernels exist; available kernels: {available}"
        )
    return kernel_names[0]


def find_function(ir: dict, function_name: str) -> dict:
    for function in ir.get("functions", []):
        if function.get("name") == function_name:
            return function
    raise SystemExit(f"function {function_name!r} not found in IR")


def find_kernel_metadata(manifest: dict, function_name: str) -> dict:
    for kernel in manifest.get("kernels", {}).get("metadata", {}).get("kernels", []):
        if kernel.get("name") == function_name:
            return kernel
    raise SystemExit(f"kernel metadata for {function_name!r} not found in manifest")


def iter_operand_texts(function: dict) -> list[str]:
    return [
        instruction.get("operand_text", "")
        for instruction in function.get("instructions", [])
        if instruction.get("operand_text")
    ]


def explicit_register_footprint(function: dict) -> dict:
    max_sgpr = -1
    max_vgpr = -1
    joined = "\n".join(iter_operand_texts(function))

    for start, end in SGPR_RANGE_RE.findall(joined):
        max_sgpr = max(max_sgpr, int(start), int(end))
    for single in SGPR_SINGLE_RE.findall(joined):
        max_sgpr = max(max_sgpr, int(single))

    for start, end in VGPR_RANGE_RE.findall(joined):
        max_vgpr = max(max_vgpr, int(start), int(end))
    for single in VGPR_SINGLE_RE.findall(joined):
        max_vgpr = max(max_vgpr, int(single))

    return {
        "max_explicit_sgpr": max_sgpr,
        "max_explicit_vgpr": max_vgpr,
        "uses_vcc": bool(re.search(r"\bvcc(?:_lo|_hi)?\b", joined)),
        "uses_flat_scratch": bool(re.search(r"\bflat_scratch(?:_lo|_hi)?\b", joined)),
        "uses_exec": bool(re.search(r"\bexec(?:_lo|_hi)?\b", joined)),
        "uses_m0": bool(re.search(r"\bm0\b", joined)),
    }


def instruction_map(function: dict) -> dict[int, dict]:
    return {
        int(instruction["address"]): instruction
        for instruction in function.get("instructions", [])
        if "address" in instruction
    }


def instruction_repr(instruction: dict | None) -> str | None:
    if instruction is None:
        return None
    mnemonic = instruction.get("mnemonic", "")
    operand_text = instruction.get("operand_text", "")
    return mnemonic if not operand_text else f"{mnemonic} {operand_text}"


def diff_instructions(original: dict, candidate: dict) -> list[dict]:
    original_by_addr = instruction_map(original)
    candidate_by_addr = instruction_map(candidate)
    diffs: list[dict] = []
    for address in sorted(set(original_by_addr) | set(candidate_by_addr)):
        lhs = original_by_addr.get(address)
        rhs = candidate_by_addr.get(address)
        if lhs is None or rhs is None:
            diffs.append(
                {
                    "address": address,
                    "kind": "layout",
                    "original": instruction_repr(lhs),
                    "candidate": instruction_repr(rhs),
                }
            )
            continue
        if lhs.get("mnemonic") == rhs.get("mnemonic") and lhs.get("operand_text", "") == rhs.get(
            "operand_text", ""
        ):
            continue
        diffs.append(
            {
                "address": address,
                "kind": "instruction",
                "original": instruction_repr(lhs),
                "candidate": instruction_repr(rhs),
                "original_mnemonic": lhs.get("mnemonic"),
                "candidate_mnemonic": rhs.get("mnemonic"),
                "original_operands": lhs.get("operand_text", ""),
                "candidate_operands": rhs.get("operand_text", ""),
            }
        )
    return diffs


def classify_hazards(diffs: list[dict], original_fp: dict, candidate_fp: dict) -> list[str]:
    hazards: list[str] = []

    if any(diff["kind"] == "layout" for diff in diffs):
        hazards.append("instruction layout changed (addresses added/removed)")

    if candidate_fp["max_explicit_sgpr"] > original_fp["max_explicit_sgpr"]:
        hazards.append("candidate uses a higher explicit SGPR index than the original")
    if candidate_fp["max_explicit_vgpr"] > original_fp["max_explicit_vgpr"]:
        hazards.append("candidate uses a higher explicit VGPR index than the original")
    if candidate_fp["uses_vcc"] and not original_fp["uses_vcc"]:
        hazards.append("candidate introduces VCC usage")
    if candidate_fp["uses_flat_scratch"] and not original_fp["uses_flat_scratch"]:
        hazards.append("candidate introduces flat_scratch usage")
    if candidate_fp["uses_m0"] and not original_fp["uses_m0"]:
        hazards.append("candidate introduces m0 usage")

    for diff in diffs:
        if diff["kind"] != "instruction":
            continue
        old_mnemonic = str(diff.get("original_mnemonic") or "")
        new_mnemonic = str(diff.get("candidate_mnemonic") or "")
        old_text = str(diff.get("original_operands") or "")
        new_text = str(diff.get("candidate_operands") or "")

        if old_mnemonic.startswith("s_load") or new_mnemonic.startswith("s_load"):
            hazards.append(f"{diff['address']:#x}: scalar load changed; kernarg/layout assumptions may differ")
        if old_mnemonic != new_mnemonic and old_mnemonic.startswith("s_load") != new_mnemonic.startswith(
            "s_load"
        ):
            hazards.append(
                f"{diff['address']:#x}: load-class mnemonic changed from {old_mnemonic} to {new_mnemonic}"
            )
        if "HW_REG_FLAT_SCR_" in old_text or "HW_REG_FLAT_SCR_" in new_text:
            hazards.append(f"{diff['address']:#x}: flat scratch register programming changed")
        if ".kd" in old_text or ".kd" in new_text:
            hazards.append(f"{diff['address']:#x}: descriptor-symbol reference changed")

    return sorted(set(hazards))


def build_report(original: dict, candidate: dict, manifest: dict, function_name: str) -> dict:
    original_function = find_function(original, function_name)
    candidate_function = find_function(candidate, function_name)
    kernel = find_kernel_metadata(manifest, function_name)

    original_fp = explicit_register_footprint(original_function)
    candidate_fp = explicit_register_footprint(candidate_function)
    diffs = diff_instructions(original_function, candidate_function)
    hazards = classify_hazards(diffs, original_fp, candidate_fp)

    return {
        "function": function_name,
        "descriptor": {
            "kernarg_segment_size": kernel.get("kernarg_segment_size"),
            "sgpr_count": kernel.get("sgpr_count"),
            "vgpr_count": kernel.get("vgpr_count"),
            "wavefront_size": kernel.get("wavefront_size"),
        },
        "original_footprint": original_fp,
        "candidate_footprint": candidate_fp,
        "changed_instruction_count": len(diffs),
        "changed_instructions": diffs,
        "hazards": hazards,
        "likely_safe_to_preserve_descriptor_bytes": not hazards,
        "summary": (
            "no descriptor-sensitive hazards detected"
            if not hazards
            else "descriptor-sensitive hazards detected"
        ),
    }


def render_text(report: dict) -> str:
    lines = [
        f"function: {report['function']}",
        f"changed instructions: {report['changed_instruction_count']}",
        "descriptor counts: "
        f"sgpr={report['descriptor'].get('sgpr_count')} "
        f"vgpr={report['descriptor'].get('vgpr_count')} "
        f"kernarg={report['descriptor'].get('kernarg_segment_size')}",
        "original explicit footprint: "
        f"sgpr={report['original_footprint']['max_explicit_sgpr']} "
        f"vgpr={report['original_footprint']['max_explicit_vgpr']} "
        f"vcc={int(report['original_footprint']['uses_vcc'])} "
        f"flat_scratch={int(report['original_footprint']['uses_flat_scratch'])}",
        "candidate explicit footprint: "
        f"sgpr={report['candidate_footprint']['max_explicit_sgpr']} "
        f"vgpr={report['candidate_footprint']['max_explicit_vgpr']} "
        f"vcc={int(report['candidate_footprint']['uses_vcc'])} "
        f"flat_scratch={int(report['candidate_footprint']['uses_flat_scratch'])}",
        "verdict: "
        + (
            "LIKELY_SAFE_TO_PRESERVE_DESCRIPTOR_BYTES"
            if report["likely_safe_to_preserve_descriptor_bytes"]
            else "REVIEW_OR_RECOMPUTE_DESCRIPTOR_METADATA"
        ),
    ]

    if report["hazards"]:
        lines.append("hazards:")
        lines.extend(f"  - {hazard}" for hazard in report["hazards"])
    if report["changed_instructions"]:
        lines.append("changed instructions:")
        for diff in report["changed_instructions"]:
            lines.append(
                f"  - {diff['address']:#x}: {diff.get('original')} -> {diff.get('candidate')}"
            )
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    manifest = load_json(args.manifest)
    function_name = choose_function_name(manifest, args.function)
    original = load_json(args.original_ir)
    candidate = load_json(args.candidate_ir)
    report = build_report(original, candidate, manifest, function_name)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
