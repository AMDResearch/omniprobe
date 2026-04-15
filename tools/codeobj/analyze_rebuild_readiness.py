#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Assess whether a code-object manifest is currently eligible for a "
            "particular Omniprobe rebuild mode."
        )
    )
    parser.add_argument("manifest", help="Code-object manifest JSON")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("exact", "abi-preserving", "abi-changing"),
        help="Rebuild mode to assess",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the report as JSON",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def kernel_names(manifest: dict) -> list[str]:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    return [str(kernel.get("name")) for kernel in kernels if kernel.get("name")]


def support_section_names(manifest: dict) -> list[str]:
    return [
        str(section.get("name"))
        for section in manifest.get("support_sections", [])
        if section.get("name") and int(section.get("size", 0) or 0) > 0
    ]


def descriptor_count_evidence(manifest: dict) -> list[dict]:
    descriptors = []
    for descriptor in manifest.get("kernels", {}).get("descriptors", []):
        if not descriptor.get("name"):
            continue
        rsrc1 = descriptor.get("compute_pgm_rsrc1", {})
        descriptors.append(
            {
                "name": str(descriptor.get("name")),
                "has_granulated_workitem_vgpr_count": isinstance(
                    rsrc1.get("granulated_workitem_vgpr_count"), int
                ),
                "has_granulated_wavefront_sgpr_count": isinstance(
                    rsrc1.get("granulated_wavefront_sgpr_count"), int
                ),
            }
        )
    return descriptors


def assess_mode(manifest: dict, mode: str) -> dict:
    hazards: list[str] = []
    kernels = kernel_names(manifest)
    descriptor_evidence = descriptor_count_evidence(manifest)

    if mode == "exact":
        likely_supported = True
    elif mode == "abi-preserving":
        likely_supported = True
    elif mode == "abi-changing":
        likely_supported = True
        missing_counts = [
            descriptor["name"]
            for descriptor in descriptor_evidence
            if not descriptor["has_granulated_workitem_vgpr_count"]
            or not descriptor["has_granulated_wavefront_sgpr_count"]
        ]
        if missing_counts:
            hazards.append(
                "descriptor granulation fields missing for: "
                + ", ".join(missing_counts)
            )
            likely_supported = False
    else:
        raise SystemExit(f"unsupported mode {mode!r}")

    return {
        "mode": mode,
        "likely_supported": likely_supported,
        "hazards": hazards,
        "evidence": {
            "kernel_names": kernels,
            "descriptor_count_evidence": descriptor_evidence,
            "support_sections": support_section_names(manifest),
        },
    }


def main() -> int:
    args = parse_args()
    manifest = load_json(Path(args.manifest).resolve())
    report = assess_mode(manifest, args.mode)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        verdict = "supported" if report["likely_supported"] else "rejected"
        print(f"{args.mode}: {verdict}")
        for hazard in report["hazards"]:
            print(f"hazard: {hazard}")
    return 0 if report["likely_supported"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
