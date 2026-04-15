#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from common import detect_llvm_tool, sanitize_bundle_id


BUNDLE_MAGIC = b"__CLANG_OFFLOAD_BUNDLE__"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract AMDGPU code objects from a clang offload bundle."
    )
    parser.add_argument("input", help="Input bundle or AMDGPU ELF object")
    parser.add_argument(
        "--output-dir",
        default="build/extracted",
        help="Directory for extracted objects and manifest",
    )
    parser.add_argument(
        "--target-substring",
        default="hip",
        help="Only extract bundle IDs containing this substring",
    )
    parser.add_argument(
        "--include-host",
        action="store_true",
        help="Also extract host objects from the bundle",
    )
    parser.add_argument(
        "--bundler",
        default=None,
        help="Path to clang-offload-bundler; auto-detected when omitted",
    )
    return parser.parse_args()


def detect_input_kind(path: Path) -> str:
    with path.open("rb") as handle:
        prefix = handle.read(max(len(BUNDLE_MAGIC), 4))

    if prefix.startswith(BUNDLE_MAGIC):
        return "bundle"
    if prefix.startswith(b"\x7fELF"):
        return "elf"
    return "unknown"


def list_bundle_ids(bundler: str, input_path: Path) -> list[str]:
    result = subprocess.run(
        [bundler, "--list", "--type=o", "--input", str(input_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def extract_from_bundle(
    bundler: str,
    input_path: Path,
    output_dir: Path,
    target_substring: str,
    include_host: bool,
) -> dict:
    bundle_ids = list_bundle_ids(bundler, input_path)
    selected_ids: list[str] = []
    for bundle_id in bundle_ids:
        if bundle_id.startswith("host-"):
            if include_host:
                selected_ids.append(bundle_id)
            continue
        if target_substring in bundle_id:
            selected_ids.append(bundle_id)

    if not selected_ids:
        raise SystemExit(f"no bundle IDs matched target substring {target_substring!r}")

    outputs: list[Path] = []
    for bundle_id in selected_ids:
        suffix = ".o" if bundle_id.startswith("host-") else ".co"
        output_name = f"{input_path.stem}.{sanitize_bundle_id(bundle_id)}{suffix}"
        outputs.append(output_dir / output_name)

    command = [
        bundler,
        "--unbundle",
        "--type=o",
        f"--targets={','.join(selected_ids)}",
        f"--input={input_path}",
    ]
    for output_path in outputs:
        command.append(f"--output={output_path}")

    subprocess.run(command, check=True)

    return {
        "input": str(input_path),
        "input_kind": "bundle",
        "bundle_ids": bundle_ids,
        "selected_bundle_ids": selected_ids,
        "outputs": [str(path) for path in outputs],
    }


def handle_elf_input(input_path: Path, output_dir: Path) -> dict:
    output_path = output_dir / input_path.name
    shutil.copy2(input_path, output_path)
    return {
        "input": str(input_path),
        "input_kind": "elf",
        "outputs": [str(output_path)],
    }


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    kind = detect_input_kind(input_path)
    if kind == "bundle":
        bundler = detect_llvm_tool("clang-offload-bundler", args.bundler)
        manifest = extract_from_bundle(
            bundler=bundler,
            input_path=input_path,
            output_dir=output_dir,
            target_substring=args.target_substring,
            include_host=args.include_host,
        )
    elif kind == "elf":
        manifest = handle_elf_input(input_path, output_dir)
    else:
        raise SystemExit(f"unsupported input format for {input_path}")

    manifest_path = output_dir / f"{input_path.stem}.extract_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    print(f"wrote {manifest_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
