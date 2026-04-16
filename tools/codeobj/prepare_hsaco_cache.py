#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from common import (
    OMNIPROBE_PREFIX,
    find_amdgpu_metadata_note,
    get_hidden_abi_instrumented_name,
    get_instrumented_name,
    sanitize_bundle_id,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build an Omniprobe kernel cache for standalone code objects or host binaries "
            "containing bundled AMDGPU code objects."
        )
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help=(
            "Input AMDGPU code objects or host binaries/shared libraries containing "
            "bundled AMDGPU code objects"
        ),
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory where prepared cache code objects should be emitted",
    )
    parser.add_argument(
        "--kernel-filter",
        default="",
        help="Optional ECMAScript-style regex matched against kernel name or symbol",
    )
    parser.add_argument(
        "--pointer-size",
        type=int,
        default=8,
        help="Pointer size used for hidden_omniprobe_ctx planning",
    )
    parser.add_argument(
        "--alignment",
        type=int,
        default=8,
        help="Alignment used when appending hidden_omniprobe_ctx",
    )
    parser.add_argument(
        "--carrier-input",
        action="append",
        default=[],
        help=(
            "Optional instrumented carrier input. May be a standalone code object or a "
            "binary containing bundled GPU code objects. Matching kernels are satisfied "
            "by copying the carrier object into cache instead of donor-slot rewriting."
        ),
    )
    parser.add_argument(
        "--extract-tool",
        default=None,
        help=(
            "Path to extract_code_objects helper. Required only when an input is a host "
            "binary instead of a standalone AMDGPU code object."
        ),
    )
    parser.add_argument(
        "--source-rebuild-mode",
        default=None,
        choices=("exact", "abi-preserving", "abi-changing"),
        help=(
            "Optionally rebuild each resolved source code object before carrier/surrogate "
            "selection. Currently only 'exact' is implemented in cache preparation."
        ),
    )
    parser.add_argument(
        "--surrogate-mode",
        default="auto",
        choices=("auto", "donor-slot", "donor-free"),
        help=(
            "How to synthesize surrogate clone artifacts when no matching carrier is "
            "available. 'donor-slot' requires an existing Omniprobe-style donor clone "
            "slot inside the active code object. 'donor-free' uses whole-object "
            "regeneration. 'auto' prefers donor-slot when an eligible donor exists and "
            "otherwise falls back to donor-free."
        ),
    )
    parser.add_argument(
        "--probe-spec",
        default=None,
        help=(
            "Optional Omniprobe v1 probe YAML spec. The current binary-only "
            "integration can rewrite donor-free hidden-ABI clones for supported "
            "lifecycle-exit probe sites and otherwise fails closed with a plan/report."
        ),
    )
    parser.add_argument(
        "--probe-bundle",
        default=None,
        help=(
            "Optional generated probe bundle JSON from tools/probes/prepare_probe_bundle.py. "
            "Mutually exclusive with --probe-spec."
        ),
    )
    parser.add_argument(
        "--hipcc",
        default=None,
        help="Optional hipcc path forwarded to regenerate_code_object.py for probe support compilation",
    )
    parser.add_argument(
        "--llvm-readelf",
        default=None,
        help="Optional llvm-readelf path forwarded to manifest-generation helpers",
    )
    parser.add_argument(
        "--llvm-objdump",
        default=None,
        help="Optional llvm-objdump path forwarded to disasm/regeneration helpers",
    )
    parser.add_argument(
        "--llvm-mc",
        default=None,
        help="Optional llvm-mc path forwarded to rebuild helpers",
    )
    parser.add_argument(
        "--ld-lld",
        default=None,
        help="Optional ld.lld path forwarded to rebuild helpers",
    )
    parser.add_argument(
        "--clang-offload-bundler",
        default=None,
        help="Optional clang-offload-bundler path forwarded for compatibility with lower-level helpers",
    )
    return parser.parse_args()


def run_python(tool: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(tool), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def run_command(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        check=True,
        capture_output=True,
        text=True,
    )


def run_python_json(tool: Path, *args: str) -> dict:
    result = subprocess.run(
        [sys.executable, str(tool), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if not result.stdout.strip():
        if result.stderr.strip():
            raise SystemExit(result.stderr.strip())
        raise SystemExit(f"{tool} did not emit a JSON report")
    return json.loads(result.stdout)


@dataclass(frozen=True)
class ResolvedCodeObject:
    owner_input: Path
    code_object_path: Path
    cache_tag: str
    extracted: bool
    extract_index: int


def load_manifest(
    inspect_tool: Path, input_path: Path, *, llvm_readelf: str | None = None
) -> tuple[Path, dict]:
    manifest_path = (input_path.parent / f"{input_path.name}.manifest.json").resolve()
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{input_path.name}.manifest.",
        suffix=".json.tmp",
        dir=str(input_path.parent),
    )
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        args = [str(input_path), "--output", str(temp_path)]
        if llvm_readelf:
            args.extend(["--llvm-readelf", llvm_readelf])
        run_python(inspect_tool, *args)
        payload = json.loads(temp_path.read_text(encoding="utf-8"))
        temp_path.replace(manifest_path)
        return manifest_path, payload
    finally:
        if temp_path.exists():
            temp_path.unlink()


def kernel_records(manifest: dict) -> list[dict]:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    return [kernel for kernel in kernels if isinstance(kernel, dict)]


def instrumented_kernel_records(manifest: dict) -> list[dict]:
    return [kernel for kernel in kernel_records(manifest) if is_instrumented_kernel(kernel)]


def is_instrumented_kernel(kernel: dict) -> bool:
    for field in (kernel.get("name"), kernel.get("symbol")):
        if field and str(field).startswith(OMNIPROBE_PREFIX):
            return True
    return False


def select_sources(kernels: list[dict], kernel_filter: str) -> list[dict]:
    base_kernels = [kernel for kernel in kernels if not is_instrumented_kernel(kernel)]
    if not kernel_filter:
        return base_kernels

    regex = re.compile(kernel_filter)
    selected: list[dict] = []
    for kernel in base_kernels:
        name = str(kernel.get("name", ""))
        symbol = str(kernel.get("symbol", ""))
        if regex.search(name) or regex.search(symbol):
            selected.append(kernel)
    return selected


def detect_extract_tool(explicit: str | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))

    for env_name in ("BUILD_DIR", "OMNIPROBE_ROOT"):
        value = os.environ.get(env_name)
        if value:
            candidates.append(Path(value) / "tools" / "extract_code_objects")

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    candidates.extend(
        [
            repo_root / "build" / "tools" / "extract_code_objects",
            script_dir / "extract_code_objects",
        ]
    )

    which_path = shutil.which("extract_code_objects")
    if which_path:
        candidates.append(Path(which_path))

    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def parse_extract_outputs(stdout: str) -> list[Path]:
    results: list[Path] = []
    for line in stdout.splitlines():
        value = line.strip()
        if not value:
            continue
        candidate = Path(value)
        if candidate.is_absolute() and candidate.exists():
            results.append(candidate.resolve())
    return results


def resolve_input_code_objects(
    inputs: list[str],
    *,
    extract_tool: Path | None,
) -> list[ResolvedCodeObject]:
    resolved: list[ResolvedCodeObject] = []
    for input_name in inputs:
        input_path = Path(input_name).resolve()
        if not input_path.exists():
            raise SystemExit(f"input '{input_name}' not found")

        if find_amdgpu_metadata_note(input_path) is not None:
            resolved.append(
                ResolvedCodeObject(
                    owner_input=input_path,
                    code_object_path=input_path,
                    cache_tag=sanitize_bundle_id(input_path.stem),
                    extracted=False,
                    extract_index=0,
                )
            )
            continue

        if extract_tool is None:
            raise SystemExit(
                f"'{input_path}' is not a standalone AMDGPU code object and "
                "extract_code_objects was not found. Set BUILD_DIR/OMNIPROBE_ROOT, "
                "pass --extract-tool, or build the helper target."
            )

        result = run_command(str(extract_tool), str(input_path))
        outputs = parse_extract_outputs(result.stdout)
        if not outputs:
            raise SystemExit(f"no AMDGPU code objects found in '{input_path}'")

        for index, code_object_path in enumerate(outputs):
            resolved.append(
                ResolvedCodeObject(
                    owner_input=input_path,
                    code_object_path=code_object_path,
                    cache_tag=sanitize_bundle_id(f"{input_path.stem}.bundle{index}"),
                    extracted=True,
                    extract_index=index,
                )
            )
    return resolved


def clone_name_candidates(kernel: dict) -> set[str]:
    candidates: set[str] = set()
    for field in (kernel.get("name"), kernel.get("symbol")):
        if not field:
            continue
        value = str(field)
        candidates.add(get_instrumented_name(value))
        candidates.add(get_hidden_abi_instrumented_name(value))
    return {candidate for candidate in candidates if candidate}


def kernel_selector_value(kernel: dict) -> str:
    value = kernel.get("name") or kernel.get("symbol")
    if not value:
        raise SystemExit("kernel record is missing both name and symbol")
    return str(value)


def manifest_symbol_names(manifest: dict) -> set[str]:
    return {
        str(symbol.get("name"))
        for symbol in manifest.get("symbols", [])
        if symbol.get("name")
    }


def manifest_target(manifest: dict) -> str:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    return str(metadata.get("target") or "")


def manifest_contains_source_kernel(manifest: dict, kernel: dict) -> bool:
    symbols = manifest_symbol_names(manifest)
    for field in (kernel.get("name"), kernel.get("symbol")):
        if field and str(field) in symbols:
            return True
    return False


def manifest_has_existing_clone(manifest: dict, kernel: dict) -> bool:
    symbols = manifest_symbol_names(manifest)
    return any(candidate in symbols for candidate in clone_name_candidates(kernel))


def non_hidden_args(kernel: dict) -> list[dict]:
    args = kernel.get("args", [])
    non_hidden: list[dict] = []
    for arg in args:
        if arg.get("name") == "hidden_omniprobe_ctx":
            continue
        value_kind = str(arg.get("value_kind", ""))
        if value_kind.startswith("hidden_"):
            continue
        non_hidden.append(arg)
    return non_hidden


def arg_abi_signature(arg: dict) -> tuple[int, int, str, str, str]:
    return (
        int(arg.get("offset", 0) or 0),
        int(arg.get("size", 0) or 0),
        str(arg.get("value_kind", "") or ""),
        str(arg.get("address_space", "") or ""),
        str(arg.get("type_name", "") or ""),
    )


def donor_slot_is_abi_compatible(
    source_kernel: dict,
    donor_kernel: dict,
) -> bool:
    source_args = non_hidden_args(source_kernel)
    donor_args = non_hidden_args(donor_kernel)
    if len(donor_args) != len(source_args) + 1:
        return False

    return [arg_abi_signature(arg) for arg in donor_args[: len(source_args)]] == [
        arg_abi_signature(arg) for arg in source_args
    ]


def donor_slot_candidate(
    manifest: dict,
    source_kernel: dict,
) -> dict | None:
    source_candidates = clone_name_candidates(source_kernel)
    source_family_values = {
        str(field)
        for field in (source_kernel.get("name"), source_kernel.get("symbol"))
        if field
    }
    for kernel in instrumented_kernel_records(manifest):
        values = {
            str(field)
            for field in (kernel.get("name"), kernel.get("symbol"))
            if field
        }
        if values & source_candidates:
            continue
        if values & source_family_values:
            continue
        if not donor_slot_is_abi_compatible(source_kernel, kernel):
            continue
        return kernel
    return None


def find_matching_carrier(
    carriers: list[tuple[ResolvedCodeObject, dict]],
    source_manifest: dict,
    source_kernel: dict,
) -> tuple[ResolvedCodeObject, dict] | None:
    source_target = manifest_target(source_manifest)
    for carrier_record, carrier_manifest in carriers:
        if source_target and manifest_target(carrier_manifest) != source_target:
            continue
        if not manifest_contains_source_kernel(carrier_manifest, source_kernel):
            continue
        if manifest_has_existing_clone(carrier_manifest, source_kernel):
            return carrier_record, carrier_manifest
    return None


def carrier_output_path(
    output_dir: Path,
    source_record: ResolvedCodeObject,
    carrier_record: ResolvedCodeObject,
) -> Path:
    if (
        source_record.owner_input == carrier_record.owner_input
        and source_record.cache_tag == carrier_record.cache_tag
        and source_record.extract_index == carrier_record.extract_index
    ):
        name = f"{source_record.cache_tag}.carrier.hsaco"
    else:
        name = (
            f"{source_record.cache_tag}.from_{carrier_record.cache_tag}.carrier.hsaco"
        )
    return output_dir / name


def prepare_source_record(
    record: ResolvedCodeObject,
    *,
    manifest_path: Path,
    inspect_tool: Path,
    disasm_tool: Path,
    rebuild_tool: Path,
    readiness_tool: Path,
    output_dir: Path,
    source_rebuild_mode: str,
) -> tuple[ResolvedCodeObject, Path, dict, dict]:
    work_dir = output_dir / ".source_rebuild" / record.cache_tag
    work_dir.mkdir(parents=True, exist_ok=True)

    ir_path = work_dir / f"{record.cache_tag}.ir.json"
    rebuilt_path = work_dir / f"{record.cache_tag}.{source_rebuild_mode}.hsaco"
    report_path = work_dir / f"{record.cache_tag}.{source_rebuild_mode}.report.json"
    readiness_report_path = (
        work_dir / f"{record.cache_tag}.{source_rebuild_mode}.readiness.json"
    )

    readiness_report: dict | None = None
    if source_rebuild_mode == "abi-changing":
        readiness_report = run_python_json(
            readiness_tool,
            str(manifest_path),
            "--mode",
            source_rebuild_mode,
            "--json",
        )
        readiness_report_path.write_text(
            json.dumps(readiness_report, indent=2) + "\n",
            encoding="utf-8",
        )
        if not readiness_report.get("likely_supported", False):
            hazard_summary = "; ".join(readiness_report.get("hazards", []))
            raise SystemExit(
                "prepare_hsaco_cache.py rejected --source-rebuild-mode "
                f"{source_rebuild_mode} for {record.code_object_path}: "
                f"{hazard_summary or 'eligibility could not be proven'}"
            )
    elif source_rebuild_mode != "exact":
        raise SystemExit(
            "prepare_hsaco_cache.py currently supports only "
            "--source-rebuild-mode exact or abi-changing"
        )

    run_python(
        disasm_tool,
        str(record.code_object_path),
        "--manifest",
        str(manifest_path),
        "--output",
        str(ir_path),
        *(["--llvm-objdump", args.llvm_objdump] if args.llvm_objdump else []),
    )
    run_python(
        rebuild_tool,
        str(ir_path),
        str(manifest_path),
        "--mode",
        source_rebuild_mode,
        "--output",
        str(rebuilt_path),
        "--report-output",
        str(report_path),
        *(
            ["--preserve-descriptor-bytes"]
            if source_rebuild_mode == "abi-changing"
            else []
        ),
        *(["--llvm-mc", args.llvm_mc] if args.llvm_mc else []),
        *(["--ld-lld", args.ld_lld] if args.ld_lld else []),
    )
    rebuilt_manifest_path, rebuilt_manifest = load_manifest(
        inspect_tool,
        rebuilt_path,
        llvm_readelf=args.llvm_readelf,
    )
    rebuilt_record = ResolvedCodeObject(
        owner_input=record.owner_input,
        code_object_path=rebuilt_path,
        cache_tag=record.cache_tag,
        extracted=record.extracted,
        extract_index=record.extract_index,
    )
    prep_summary = {
        "operation": "source-rebuild",
        "mode": source_rebuild_mode,
        "input_code_object": str(record.code_object_path),
        "output_code_object": str(rebuilt_path),
        "report": str(report_path),
        "manifest": str(rebuilt_manifest_path),
        "ir": str(ir_path),
    }
    if readiness_report is not None:
        prep_summary["readiness_report"] = str(readiness_report_path)
    return rebuilt_record, rebuilt_manifest_path, rebuilt_manifest, prep_summary


def prepare_probe_bundle_for_planning(
    *,
    probe_spec: str | None,
    probe_bundle: str | None,
    prepare_probe_bundle_tool: Path,
    output_dir: Path,
) -> Path | None:
    if not probe_spec and not probe_bundle:
        return None
    if probe_spec and probe_bundle:
        raise SystemExit("at most one of --probe-spec or --probe-bundle may be provided")
    if probe_bundle:
        bundle_path = Path(probe_bundle).resolve()
        if not bundle_path.exists():
            raise SystemExit(f"probe bundle '{probe_bundle}' not found")
        return bundle_path

    spec_path = Path(str(probe_spec)).resolve()
    if not spec_path.exists():
        raise SystemExit(f"probe spec '{probe_spec}' not found")
    bundle_output_dir = output_dir / ".probe_bundle" / sanitize_bundle_id(spec_path.stem)
    bundle_output_dir.mkdir(parents=True, exist_ok=True)
    run_python(
        prepare_probe_bundle_tool,
        str(spec_path),
        "--output-dir",
        str(bundle_output_dir),
        "--skip-compile",
    )
    return bundle_output_dir / "generated_probe_bundle.json"


def matching_probe_kernel_plan(probe_plan: dict, kernel: dict) -> dict | None:
    kernel_values = {
        str(field)
        for field in (kernel.get("name"), kernel.get("symbol"))
        if isinstance(field, str) and field
    }
    for entry in probe_plan.get("kernels", []):
        if not isinstance(entry, dict):
            continue
        entry_values = {
            str(field)
            for field in (
                entry.get("source_kernel"),
                entry.get("source_symbol"),
                entry.get("clone_kernel"),
            )
            if isinstance(field, str) and field
        }
        if kernel_values & entry_values:
            return entry
    return None


def probe_kernel_rewrite_eligibility(kernel_plan: dict) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    unsupported_sites = kernel_plan.get("unsupported_sites", [])
    if isinstance(unsupported_sites, list) and unsupported_sites:
        reasons.append("probe plan contains unsupported sites")

    planned_sites = kernel_plan.get("planned_sites", [])
    if not isinstance(planned_sites, list) or not planned_sites:
        reasons.append("probe plan did not select any sites for this kernel")
        return False, reasons

    for site in planned_sites:
        if not isinstance(site, dict):
            reasons.append("probe plan contains an invalid site record")
            continue
        contract = str(site.get("contract", ""))
        when = str(site.get("when", ""))
        if contract != "kernel_lifecycle_v1":
            reasons.append(f"contract {contract!r} is not yet supported by binary rewrite")
        if when != "kernel_exit":
            reasons.append(
                f"binary rewrite currently supports only kernel_exit lifecycle sites, not {when!r}"
            )
    return len(reasons) == 0, reasons


def main() -> int:
    args = parse_args()
    tool_dir = Path(__file__).resolve().parent
    readiness_tool = tool_dir / "analyze_rebuild_readiness.py"
    inspect_tool = tool_dir / "inspect_code_object.py"
    disasm_tool = tool_dir / "disasm_to_ir.py"
    rebuild_tool = tool_dir / "rebuild_code_object.py"
    regenerate_tool = tool_dir / "regenerate_code_object.py"
    rebind_tool = tool_dir / "rebind_surrogate_kernel.py"
    plan_probe_tool = tool_dir / "plan_probe_instrumentation.py"
    generate_binary_thunks_tool = tool_dir / "generate_binary_probe_thunks.py"
    prepare_probe_bundle_tool = tool_dir.parent / "probes" / "prepare_probe_bundle.py"
    extract_tool = detect_extract_tool(args.extract_tool)
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    probe_bundle_path = prepare_probe_bundle_for_planning(
        probe_spec=args.probe_spec,
        probe_bundle=args.probe_bundle,
        prepare_probe_bundle_tool=prepare_probe_bundle_tool,
        output_dir=output_dir,
    )

    summary: list[dict] = []
    had_error = False
    carrier_cache_copies: dict[tuple[str, str], Path] = {}

    source_records = resolve_input_code_objects(args.inputs, extract_tool=extract_tool)
    carrier_records = resolve_input_code_objects(args.carrier_input, extract_tool=extract_tool)
    source_manifests = {
        record: load_manifest(
            inspect_tool,
            record.code_object_path,
            llvm_readelf=args.llvm_readelf,
        )
        for record in source_records
    }
    carrier_manifests = {
        record: load_manifest(
            inspect_tool,
            record.code_object_path,
            llvm_readelf=args.llvm_readelf,
        )
        for record in carrier_records
    }

    for record in source_records:
        manifest_path, manifest = source_manifests[record]
        active_record = record
        active_manifest_path = manifest_path
        active_manifest = manifest

        item_summary = {
            "input": str(record.owner_input),
            "code_object": str(record.code_object_path),
            "manifest": str(manifest_path),
            "extracted": record.extracted,
            "source_rebuild_mode": args.source_rebuild_mode,
            "outputs": [],
            "skipped": [],
        }

        if args.source_rebuild_mode:
            (
                active_record,
                active_manifest_path,
                active_manifest,
                source_preparation,
            ) = prepare_source_record(
                record,
                manifest_path=manifest_path,
                inspect_tool=inspect_tool,
                disasm_tool=disasm_tool,
                rebuild_tool=rebuild_tool,
                readiness_tool=readiness_tool,
                output_dir=output_dir,
                source_rebuild_mode=args.source_rebuild_mode,
            )
            item_summary["source_preparation"] = source_preparation

        probe_plan = None
        probe_plan_path = None
        thunk_source_path = None
        thunk_manifest_path = None
        if probe_bundle_path is not None:
            probe_plan_path = output_dir / f"{record.cache_tag}.probe-plan.json"
            plan_args = [
                str(active_manifest_path),
                "--probe-bundle",
                str(probe_bundle_path),
                "--output",
                str(probe_plan_path),
            ]
            plan_result = subprocess.run(
                [sys.executable, str(plan_probe_tool), *plan_args],
                check=False,
                capture_output=True,
                text=True,
            )
            try:
                probe_plan = json.loads(plan_result.stdout)
            except json.JSONDecodeError as exc:
                stderr = plan_result.stderr.strip()
                raise SystemExit(
                    f"probe planner did not emit valid JSON for {active_manifest_path}: "
                    f"{exc}; stderr={stderr}"
                )
            item_summary["probe_instrumentation"] = {
                "status": "planned",
                "bundle": str(probe_bundle_path),
                "plan": str(probe_plan_path),
                "supported": bool(probe_plan.get("supported", False)),
                "planned_site_count": int(probe_plan.get("planned_site_count", 0) or 0),
                "unsupported_site_count": int(probe_plan.get("unsupported_site_count", 0) or 0),
                "rewrite_pending": True,
            }
            if probe_plan.get("supported", False) and int(probe_plan.get("planned_site_count", 0) or 0) > 0:
                thunk_source_path = output_dir / f"{record.cache_tag}.binary-probe-thunks.hip"
                thunk_manifest_path = output_dir / f"{record.cache_tag}.binary-probe-thunks.manifest.json"
                run_python(
                    generate_binary_thunks_tool,
                    str(probe_plan_path),
                    "--probe-bundle",
                    str(probe_bundle_path),
                    "--output",
                    str(thunk_source_path),
                    "--manifest-output",
                    str(thunk_manifest_path),
                )
                item_summary["probe_instrumentation"]["binary_thunks"] = {
                    "source": str(thunk_source_path),
                    "manifest": str(thunk_manifest_path),
                }

        kernels = kernel_records(active_manifest)
        sources = select_sources(kernels, args.kernel_filter)
        available_carriers = [
            (active_record, active_manifest),
            *[
                (carrier_record, carrier_manifest)
                for carrier_record, (_carrier_manifest_path, carrier_manifest) in carrier_manifests.items()
            ],
        ]

        if not sources:
            item_summary["skipped"].append("no kernels matched --kernel-filter")
            summary.append(item_summary)
            had_error = True
            continue

        for source in sources:
            source_kernel_plan = (
                matching_probe_kernel_plan(probe_plan, source) if probe_plan is not None else None
            )
            if source_kernel_plan is not None:
                planned_sites = source_kernel_plan.get("planned_sites", [])
                unsupported_sites = source_kernel_plan.get("unsupported_sites", [])
                if (
                    isinstance(planned_sites, list)
                    and not planned_sites
                    and isinstance(unsupported_sites, list)
                    and not unsupported_sites
                ):
                    item_summary["probe_instrumentation"].setdefault("kernel_rewrite", {})[
                        kernel_selector_value(source)
                    ] = {
                        "supported": False,
                        "reasons": ["no probe sites selected for this kernel"],
                        "instrumented": False,
                    }
                    source_kernel_plan = None

            if source_kernel_plan is not None:
                if probe_plan is not None and not bool(probe_plan.get("supported", False)):
                    item_summary["probe_instrumentation"].setdefault("kernel_rewrite", {})[
                        kernel_selector_value(source)
                    ] = {
                        "supported": False,
                        "reasons": [
                            "binary probe rewrite fails closed when the overall probe plan contains unsupported sites"
                        ],
                        "instrumented": False,
                    }
                    item_summary["skipped"].append(
                        "binary probe rewrite is not available for "
                        f"{kernel_selector_value(source)} because the overall probe plan is unsupported"
                    )
                    had_error = True
                    continue
                rewrite_supported, rewrite_reasons = probe_kernel_rewrite_eligibility(
                    source_kernel_plan
                )
                item_summary["probe_instrumentation"].setdefault("kernel_rewrite", {})[
                    kernel_selector_value(source)
                ] = {
                    "supported": rewrite_supported,
                    "reasons": rewrite_reasons,
                    "instrumented": rewrite_supported,
                }
                if not rewrite_supported:
                    item_summary["skipped"].append(
                        "binary probe rewrite is not available for "
                        f"{kernel_selector_value(source)}: {'; '.join(rewrite_reasons)}"
                    )
                    had_error = True
                    continue
                if args.surrogate_mode == "donor-slot":
                    item_summary["skipped"].append(
                        "binary probe rewrite requires donor-free regeneration; "
                        f"kernel {kernel_selector_value(source)} cannot use --surrogate-mode donor-slot"
                    )
                    had_error = True
                    continue
                if probe_plan_path is None or thunk_manifest_path is None or thunk_source_path is None:
                    item_summary["skipped"].append(
                        "binary probe rewrite prerequisites were not generated for "
                        f"{kernel_selector_value(source)}"
                    )
                    had_error = True
                    continue

                source_tag = sanitize_bundle_id(
                    str(source.get("symbol") or source.get("name") or "kernel")
                )
                output_path = output_dir / f"{record.cache_tag}.{source_tag}.probe-surrogate.hsaco"
                report_path = output_dir / f"{record.cache_tag}.{source_tag}.probe-surrogate.report.json"
                regenerate_args = [
                    str(active_record.code_object_path),
                    "--manifest",
                    str(active_manifest_path),
                    "--kernel",
                    kernel_selector_value(source),
                    "--output",
                    str(output_path),
                    "--report-output",
                    str(report_path),
                    "--add-hidden-abi-clone",
                    "--probe-plan",
                    str(probe_plan_path),
                    "--thunk-manifest",
                    str(thunk_manifest_path),
                ]
                if args.hipcc:
                    regenerate_args.extend(["--hipcc", args.hipcc])
                if args.llvm_readelf:
                    regenerate_args.extend(["--llvm-readelf", args.llvm_readelf])
                if args.llvm_objdump:
                    regenerate_args.extend(["--llvm-objdump", args.llvm_objdump])
                if args.llvm_mc:
                    regenerate_args.extend(["--llvm-mc", args.llvm_mc])
                if args.ld_lld:
                    regenerate_args.extend(["--ld-lld", args.ld_lld])
                if args.clang_offload_bundler:
                    regenerate_args.extend(
                        ["--clang-offload-bundler", args.clang_offload_bundler]
                    )
                run_python(regenerate_tool, *regenerate_args)
                item_summary["probe_instrumentation"]["status"] = "rewritten"
                item_summary["probe_instrumentation"]["rewrite_pending"] = False
                item_summary["outputs"].append(
                    {
                        "mode": "probe-surrogate",
                        "surrogate_mode": "donor-free",
                        "rebuild_mode": "abi-changing",
                        "descriptor_policy": "whole-object-regeneration+linked-probe-support",
                        "source_kernel": source.get("name"),
                        "source_symbol": source.get("symbol"),
                        "probe_plan": str(probe_plan_path),
                        "thunk_manifest": str(thunk_manifest_path),
                        "thunk_source": str(thunk_source_path),
                        "output": str(output_path),
                        "report": str(report_path),
                    }
                )
                continue

            carrier_match = find_matching_carrier(available_carriers, active_manifest, source)
            if carrier_match is not None:
                carrier_record, _carrier_manifest = carrier_match
                cache_key = (record.cache_tag, carrier_record.cache_tag)
                output_path = carrier_cache_copies.get(cache_key)
                if output_path is None:
                    output_path = carrier_output_path(output_dir, record, carrier_record)
                    shutil.copy2(carrier_record.code_object_path, output_path)
                    carrier_cache_copies[cache_key] = output_path
                item_summary["outputs"].append(
                    {
                        "mode": "carrier",
                        "rebuild_mode": "exact",
                        "descriptor_policy": "pass-through",
                        "source_kernel": source.get("name"),
                        "source_symbol": source.get("symbol"),
                        "carrier_input": str(carrier_record.owner_input),
                        "carrier_code_object": str(carrier_record.code_object_path),
                        "output": str(output_path),
                    }
                )
                continue

            source_tag = sanitize_bundle_id(str(source.get("symbol") or source.get("name") or "kernel"))
            output_path = output_dir / f"{record.cache_tag}.{source_tag}.surrogate.hsaco"
            report_path = output_dir / f"{record.cache_tag}.{source_tag}.surrogate.report.json"
            selected_surrogate_mode = args.surrogate_mode
            donor_kernel = None
            if selected_surrogate_mode in ("auto", "donor-slot"):
                donor_kernel = donor_slot_candidate(active_manifest, source)
                if selected_surrogate_mode == "auto" and donor_kernel is None:
                    selected_surrogate_mode = "donor-free"

            if selected_surrogate_mode == "donor-slot":
                if donor_kernel is None:
                    item_summary["skipped"].append(
                        "no eligible donor-slot kernel available for "
                        f"{source.get('symbol') or source.get('name')}"
                    )
                    had_error = True
                    continue
                run_python(
                    rebind_tool,
                    str(active_record.code_object_path),
                    str(active_manifest_path),
                    "--source-kernel",
                    kernel_selector_value(source),
                    "--donor-kernel",
                    kernel_selector_value(donor_kernel),
                    "--output",
                    str(output_path),
                    "--report-output",
                    str(report_path),
                )
                item_summary["outputs"].append(
                    {
                        "mode": "surrogate",
                        "surrogate_mode": "donor-slot",
                        "rebuild_mode": "abi-changing",
                        "descriptor_policy": "donor-slot-rebind",
                        "source_kernel": source.get("name"),
                        "source_symbol": source.get("symbol"),
                        "donor_kernel": donor_kernel.get("name"),
                        "donor_symbol": donor_kernel.get("symbol"),
                        "output": str(output_path),
                        "report": str(report_path),
                    }
                )
                continue

            run_python(
                regenerate_tool,
                str(active_record.code_object_path),
                "--manifest",
                str(active_manifest_path),
                "--kernel",
                kernel_selector_value(source),
                "--output",
                str(output_path),
                "--report-output",
                str(report_path),
                "--add-hidden-abi-clone",
            )
            item_summary["outputs"].append(
                {
                    "mode": "surrogate",
                    "surrogate_mode": "donor-free",
                    "rebuild_mode": "abi-changing",
                    "descriptor_policy": "whole-object-regeneration+metadata-note-rewrite",
                    "source_kernel": source.get("name"),
                    "source_symbol": source.get("symbol"),
                    "output": str(output_path),
                    "report": str(report_path),
                }
            )

        summary.append(item_summary)

    print(json.dumps(summary, indent=2))
    return 1 if had_error else 0


if __name__ == "__main__":
    raise SystemExit(main())
