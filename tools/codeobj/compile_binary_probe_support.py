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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compile generated binary probe thunk source into a linkable AMDGPU "
            "device object using ROCm's supported HIP compilation flow."
        )
    )
    parser.add_argument(
        "--thunk-manifest",
        required=True,
        help="Thunk manifest JSON emitted by generate_binary_probe_thunks.py",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output AMDGPU device object path",
    )
    parser.add_argument(
        "--arch",
        required=True,
        help="Target architecture, for example gfx1030 or gfx90a",
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
        help="Path to llc; auto-detected when omitted",
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


def resolve_llc(explicit: str | None, *, dry_run: bool) -> str:
    if explicit:
        return explicit
    if dry_run:
        discovered = shutil.which("llc")
        if discovered:
            return discovered
        return "llc"
    return detect_llvm_tool("llc", explicit)


def build_commands(
    *,
    thunk_source: Path,
    output_path: Path,
    arch: str,
    hipcc: str,
    llc: str,
) -> dict:
    root = repo_root()
    temp_bitcode = output_path.with_suffix(output_path.suffix + ".bc")
    compile_command = [
        hipcc,
        "-x",
        "hip",
        "--offload-device-only",
        "-c",
        "-fgpu-rdc",
        f"--offload-arch={arch}",
        str(thunk_source),
        "-o",
        str(temp_bitcode),
        "-I",
        str(root / "external/dh_comms/include"),
        "-I",
        str(root / "inc"),
        "-I",
        str(thunk_source.parent),
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
        "bitcode_path": str(temp_bitcode),
        "compile_command": compile_command,
        "llc_command": llc_command,
    }


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def main() -> int:
    args = parse_args()
    thunk_manifest_path = Path(args.thunk_manifest).resolve()
    output_path = Path(args.output).resolve()
    thunk_manifest = load_json(thunk_manifest_path)
    thunk_source_value = thunk_manifest.get("thunk_source")
    if not isinstance(thunk_source_value, str) or not thunk_source_value:
        raise SystemExit(f"thunk manifest {thunk_manifest_path} does not contain thunk_source")
    thunk_source = Path(thunk_source_value).resolve()
    if not thunk_source.exists():
        raise SystemExit(f"thunk source not found: {thunk_source}")

    hipcc = resolve_hipcc(args.hipcc)
    llc = resolve_llc(args.llc, dry_run=args.dry_run)
    commands = build_commands(
        thunk_source=thunk_source,
        output_path=output_path,
        arch=args.arch,
        hipcc=hipcc,
        llc=llc,
    )

    if args.dry_run:
        json.dump(
            {
                "thunk_manifest": str(thunk_manifest_path),
                "thunk_source": str(thunk_source),
                "arch": args.arch,
                **commands,
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
        return 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    run(commands["compile_command"])
    run(commands["llc_command"])
    Path(commands["bitcode_path"]).unlink(missing_ok=True)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
