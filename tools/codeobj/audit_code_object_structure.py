#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Audit structural fidelity between two inspected AMDGPU code-object "
            "manifests."
        )
    )
    parser.add_argument("original_manifest", help="Reference manifest JSON")
    parser.add_argument("rebuilt_manifest", help="Candidate manifest JSON")
    parser.add_argument(
        "--require-descriptor-bytes-match",
        action="store_true",
        help="Fail unless every kernel descriptor byte payload matches exactly",
    )
    parser.add_argument(
        "--require-metadata-note-match",
        action="store_true",
        help="Fail unless the exact AMDGPU metadata note payload matches exactly",
    )
    parser.add_argument(
        "--symbol",
        action="append",
        default=[],
        help="Named symbol whose binding/visibility/section must match exactly",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the audit report as JSON",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def descriptor_map(manifest: dict) -> dict[str, dict]:
    return {
        str(descriptor.get("name")): descriptor
        for descriptor in manifest.get("kernels", {}).get("descriptors", [])
        if descriptor.get("name")
    }


def symbol_map(manifest: dict) -> dict[str, dict]:
    return {
        str(symbol.get("name")): symbol
        for symbol in manifest.get("symbols", [])
        if symbol.get("name")
    }


def metadata_note_payload(manifest: dict) -> str | None:
    note = manifest.get("kernels", {}).get("metadata_note", {})
    payload = note.get("payload_base64")
    return str(payload) if payload is not None else None


def audit_descriptors(original: dict, rebuilt: dict) -> list[dict]:
    diffs: list[dict] = []
    original_descriptors = descriptor_map(original)
    rebuilt_descriptors = descriptor_map(rebuilt)
    for name, original_descriptor in sorted(original_descriptors.items()):
        rebuilt_descriptor = rebuilt_descriptors.get(name)
        if rebuilt_descriptor is None:
            diffs.append(
                {
                    "name": name,
                    "status": "missing-in-rebuilt",
                }
            )
            continue
        if original_descriptor.get("bytes_hex") != rebuilt_descriptor.get("bytes_hex"):
            diffs.append(
                {
                    "name": name,
                    "status": "bytes-mismatch",
                    "original_prefix": str(original_descriptor.get("bytes_hex", ""))[:64],
                    "rebuilt_prefix": str(rebuilt_descriptor.get("bytes_hex", ""))[:64],
                }
            )
    for name in sorted(rebuilt_descriptors):
        if name not in original_descriptors:
            diffs.append(
                {
                    "name": name,
                    "status": "extra-in-rebuilt",
                }
            )
    return diffs


def audit_metadata_note(original: dict, rebuilt: dict) -> dict:
    original_payload = metadata_note_payload(original)
    rebuilt_payload = metadata_note_payload(rebuilt)
    return {
        "matches": original_payload == rebuilt_payload,
        "original_present": original_payload is not None,
        "rebuilt_present": rebuilt_payload is not None,
    }


def audit_symbols(original: dict, rebuilt: dict, names: list[str]) -> list[dict]:
    diffs: list[dict] = []
    original_symbols = symbol_map(original)
    rebuilt_symbols = symbol_map(rebuilt)
    for name in names:
        original_symbol = original_symbols.get(name)
        rebuilt_symbol = rebuilt_symbols.get(name)
        if original_symbol is None or rebuilt_symbol is None:
            diffs.append(
                {
                    "name": name,
                    "status": "missing",
                    "original_present": original_symbol is not None,
                    "rebuilt_present": rebuilt_symbol is not None,
                }
            )
            continue
        mismatches: dict[str, object] = {}
        for field in ("binding", "visibility", "section", "type"):
            if original_symbol.get(field) != rebuilt_symbol.get(field):
                mismatches[field] = {
                    "original": original_symbol.get(field),
                    "rebuilt": rebuilt_symbol.get(field),
                }
        if mismatches:
            diffs.append(
                {
                    "name": name,
                    "status": "attribute-mismatch",
                    "mismatches": mismatches,
                }
            )
    return diffs


def main() -> int:
    args = parse_args()
    original = load_json(Path(args.original_manifest).resolve())
    rebuilt = load_json(Path(args.rebuilt_manifest).resolve())

    descriptor_diffs = (
        audit_descriptors(original, rebuilt)
        if args.require_descriptor_bytes_match
        else []
    )
    metadata_note = audit_metadata_note(original, rebuilt)
    symbol_diffs = audit_symbols(original, rebuilt, args.symbol)

    failures: list[str] = []
    if args.require_descriptor_bytes_match and descriptor_diffs:
        failures.append("descriptor-bytes")
    if args.require_metadata_note_match and not metadata_note["matches"]:
        failures.append("metadata-note")
    if symbol_diffs:
        failures.append("symbols")

    report = {
        "original_manifest": str(Path(args.original_manifest).resolve()),
        "rebuilt_manifest": str(Path(args.rebuilt_manifest).resolve()),
        "passed": not failures,
        "failures": failures,
        "descriptor_diffs": descriptor_diffs,
        "metadata_note": metadata_note,
        "symbol_diffs": symbol_diffs,
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("PASS" if report["passed"] else "FAIL")
        if descriptor_diffs:
            print(f"descriptor_diffs={len(descriptor_diffs)}")
        if args.require_metadata_note_match:
            print(f"metadata_note_match={metadata_note['matches']}")
        if symbol_diffs:
            print(f"symbol_diffs={len(symbol_diffs)}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
