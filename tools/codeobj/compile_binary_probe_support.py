#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from common import detect_llvm_tool
from helper_abi_contract import validate_helper_abi_entry


MANIFEST_SOURCE_FIELDS = {
    "thunk": "thunk_source",
    "entry-trampoline": "output",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compile generated Omniprobe binary-probe support source into either "
            "a linkable AMDGPU device object or a standalone HSACO."
        )
    )
    manifest_group = parser.add_mutually_exclusive_group(required=True)
    manifest_group.add_argument(
        "--thunk-manifest",
        help="Thunk manifest JSON emitted by generate_binary_probe_thunks.py",
    )
    manifest_group.add_argument(
        "--entry-trampoline-manifest",
        help="Entry-trampoline manifest JSON emitted by generate_entry_trampolines.py",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output AMDGPU device object or HSACO path",
    )
    parser.add_argument(
        "--arch",
        required=True,
        help="Target architecture, for example gfx1030 or gfx90a",
    )
    parser.add_argument(
        "--output-format",
        choices=("obj", "hsaco"),
        default="obj",
        help="Emit a linkable device object (obj) or a standalone HSACO (hsaco)",
    )
    parser.add_argument(
        "--hipcc",
        default=None,
        help="Path to hipcc; defaults to /opt/rocm/bin/hipcc or HIPCC environment",
    )
    parser.add_argument(
        "--clang-offload-bundler",
        default=None,
        help="Deprecated compatibility option; no longer required for support-object compilation",
    )
    parser.add_argument(
        "--llc",
        default=None,
        help="Path to llc; auto-detected when omitted for obj output",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the planned commands as JSON without executing them",
    )
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_hipcc(explicit: str | None) -> str:
    if explicit:
        return explicit
    env_value = os.environ.get("HIPCC")
    if env_value:
        return env_value
    discovered = shutil.which("hipcc")
    if discovered:
        return discovered
    return str(Path("/opt/rocm/bin/hipcc"))


def resolve_llc_near_hipcc(hipcc: str) -> str | None:
    hipcc_path = Path(hipcc).expanduser()
    candidate_roots = [*hipcc_path.parents]
    for root in candidate_roots:
        tool_path = root / "lib/llvm/bin/llc"
        if tool_path.exists():
            return str(tool_path)
    return None


def resolve_llc(explicit: str | None, *, hipcc: str, dry_run: bool) -> str:
    if explicit:
        return explicit
    env_value = os.environ.get("LLC")
    if env_value:
        return env_value
    adjacent = resolve_llc_near_hipcc(hipcc)
    if adjacent:
        return adjacent
    if dry_run:
        discovered = shutil.which("llc")
        if discovered:
            return discovered
        return "llc"
    return detect_llvm_tool("llc", explicit)


def manifest_kind_and_path(args: argparse.Namespace) -> tuple[str, Path]:
    if args.thunk_manifest:
        return "thunk", Path(args.thunk_manifest).resolve()
    return "entry-trampoline", Path(args.entry_trampoline_manifest).resolve()


def support_source_from_manifest(*, manifest_kind: str, manifest_path: Path, manifest: dict) -> Path:
    field = MANIFEST_SOURCE_FIELDS[manifest_kind]
    source_value = manifest.get(field)
    if not isinstance(source_value, str) or not source_value:
        raise SystemExit(f"{manifest_kind} manifest {manifest_path} does not contain {field}")
    source_path = Path(source_value).resolve()
    if not source_path.exists():
        raise SystemExit(f"support source not found: {source_path}")
    return source_path


def validate_manifest_contracts(*, manifest_kind: str, manifest_path: Path, manifest: dict) -> None:
    if manifest_kind != "thunk":
        return
    thunks = manifest.get("thunks", [])
    if not isinstance(thunks, list) or not thunks:
        raise SystemExit(f"thunk manifest {manifest_path} does not contain a valid non-empty thunks list")
    for thunk in thunks:
        if not isinstance(thunk, dict):
            raise SystemExit(f"thunk manifest {manifest_path} contains an invalid thunk entry")
        validate_helper_abi_entry(thunk, entry_kind="generated thunk")


def build_commands(
    *,
    support_source: Path,
    output_path: Path,
    arch: str,
    hipcc: str,
    llc: str | None,
    output_format: str,
) -> dict:
    root = repo_root()
    include_args = [
        "-I",
        str(root / "external/dh_comms/include"),
        "-I",
        str(root / "inc"),
        "-I",
        str(support_source.parent),
    ]
    if output_format == "hsaco":
        compile_command = [
            hipcc,
            "-x",
            "hip",
            "--offload-device-only",
            "--no-gpu-bundle-output",
            f"--offload-arch={arch}",
            str(support_source),
            "-o",
            str(output_path),
            *include_args,
        ]
        return {
            "support_source": str(support_source),
            "compile_command": compile_command,
            "llc_command": None,
            "bitcode_path": None,
        }

    temp_bitcode = output_path.with_suffix(output_path.suffix + ".bc")
    compile_command = [
        hipcc,
        "-x",
        "hip",
        "--offload-device-only",
        "-c",
        "-fgpu-rdc",
        f"--offload-arch={arch}",
        str(support_source),
        "-o",
        str(temp_bitcode),
        *include_args,
    ]
    llc_command = [
        llc,
        "-march=amdgcn",
        f"-mcpu={arch}",
        "-filetype=obj",
        str(temp_bitcode),
        "-o",
        str(output_path),
    ]
    return {
        "support_source": str(support_source),
        "compile_command": compile_command,
        "llc_command": llc_command,
        "bitcode_path": str(temp_bitcode),
    }


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()
    manifest_kind, manifest_path = manifest_kind_and_path(args)
    output_path = Path(args.output).resolve()
    manifest = load_json(manifest_path)
    validate_manifest_contracts(
        manifest_kind=manifest_kind,
        manifest_path=manifest_path,
        manifest=manifest,
    )
    support_source = support_source_from_manifest(
        manifest_kind=manifest_kind,
        manifest_path=manifest_path,
        manifest=manifest,
    )

    hipcc = resolve_hipcc(args.hipcc)
    llc = None if args.output_format == "hsaco" else resolve_llc(
        args.llc,
        hipcc=hipcc,
        dry_run=args.dry_run,
    )
    commands = build_commands(
        support_source=support_source,
        output_path=output_path,
        arch=args.arch,
        hipcc=hipcc,
        llc=llc,
        output_format=args.output_format,
    )

    if args.dry_run:
        json.dump(
            {
                "manifest_kind": manifest_kind,
                "manifest_path": str(manifest_path),
                "arch": args.arch,
                "output_format": args.output_format,
                **commands,
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
        return 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    run(commands["compile_command"])
    if commands["llc_command"] is not None:
        run(commands["llc_command"])
    bitcode_path = commands.get("bitcode_path")
    if isinstance(bitcode_path, str):
        Path(bitcode_path).unlink(missing_ok=True)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
