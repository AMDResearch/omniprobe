#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from plan_hidden_abi import build_kernel_plan


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plan Omniprobe binary-only probe instrumentation against an "
            "inspected code-object manifest. The current implementation "
            "resolves lifecycle probes and fails closed on unsupported "
            "site-selection contracts."
        )
    )
    parser.add_argument(
        "manifest",
        help="Manifest JSON emitted by inspect_code_object.py",
    )
    parser.add_argument(
        "--probe-manifest",
        default=None,
        help="Generated probe manifest JSON emitted by prepare_probe_bundle.py or generate_probe_surrogates.py",
    )
    parser.add_argument(
        "--probe-bundle",
        default=None,
        help="Generated probe bundle JSON emitted by prepare_probe_bundle.py",
    )
    parser.add_argument(
        "--kernel",
        action="append",
        default=[],
        help="Restrict planning to one or more kernel names or symbols",
    )
    parser.add_argument(
        "--pointer-size",
        type=int,
        default=8,
        help="Size in bytes of the hidden Omniprobe context pointer",
    )
    parser.add_argument(
        "--alignment",
        type=int,
        default=8,
        help="Alignment used when appending hidden_omniprobe_ctx",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Optional path where the planner JSON should also be written",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_probe_manifest_path(args: argparse.Namespace) -> tuple[Path, dict]:
    if bool(args.probe_manifest) == bool(args.probe_bundle):
        raise SystemExit("exactly one of --probe-manifest or --probe-bundle is required")

    if args.probe_manifest:
        manifest_path = Path(args.probe_manifest).resolve()
        return manifest_path, load_json(manifest_path)

    bundle_path = Path(args.probe_bundle).resolve()
    bundle = load_json(bundle_path)
    manifest_value = bundle.get("manifest")
    if not isinstance(manifest_value, str) or not manifest_value:
        raise SystemExit(f"probe bundle {bundle_path} does not contain a manifest path")
    manifest_path = Path(manifest_value).resolve()
    probe_manifest = load_json(manifest_path)
    probe_manifest["_bundle"] = {
        "path": str(bundle_path),
        "compile_skipped": bool(bundle.get("compile_skipped", False)),
        "helper_bitcode": bundle.get("helper_bitcode"),
        "helper_source": bundle.get("helper_source"),
    }
    return manifest_path, probe_manifest


def kernel_records(manifest: dict) -> list[dict]:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    return [kernel for kernel in kernels if isinstance(kernel, dict)]


def visible_kernel_args(kernel: dict) -> list[dict]:
    visible: list[dict] = []
    for arg in kernel.get("args", []):
        if not isinstance(arg, dict):
            continue
        value_kind = str(arg.get("value_kind", "") or "")
        if arg.get("name") == "hidden_omniprobe_ctx":
            continue
        if value_kind.startswith("hidden_"):
            continue
        visible.append(arg)
    return visible


def match_selected_kernels(kernels: list[dict], selectors: list[str]) -> list[dict]:
    if not selectors:
        return kernels
    selected: list[dict] = []
    selector_set = set(selectors)
    for kernel in kernels:
        values = {
            str(field)
            for field in (kernel.get("name"), kernel.get("symbol"))
            if isinstance(field, str) and field
        }
        if values & selector_set:
            selected.append(kernel)
    missing = [
        selector
        for selector in selectors
        if not any(
            selector in {
                str(field)
                for field in (kernel.get("name"), kernel.get("symbol"))
                if isinstance(field, str) and field
            }
            for kernel in kernels
        )
    ]
    if missing:
        raise SystemExit(f"selected kernel(s) not found in manifest: {', '.join(missing)}")
    return selected


def kernel_target_matches(entry: dict, kernel: dict) -> bool:
    target = entry.get("target", {})
    kernel_targets = target.get("kernels", []) if isinstance(target, dict) else []
    values = {
        str(field)
        for field in (kernel.get("name"), kernel.get("symbol"))
        if isinstance(field, str) and field
    }
    return any(candidate in values for candidate in kernel_targets if isinstance(candidate, str))


def bind_capture_fields(kernel: dict, struct_fields: list[dict]) -> tuple[list[dict], list[dict]]:
    visible_args = visible_kernel_args(kernel)
    args_by_name = {
        str(arg.get("name")): arg
        for arg in visible_args
        if isinstance(arg.get("name"), str) and arg.get("name")
    }

    bindings: list[dict] = []
    unresolved: list[dict] = []
    for index, field in enumerate(struct_fields):
        requested_name = str(field.get("name", "")) if isinstance(field, dict) else ""
        requested_type = field.get("type") if isinstance(field, dict) else None
        matched = args_by_name.get(requested_name)
        resolution = "by-name"
        ordinal = None
        if matched is None and index < len(visible_args):
            matched = visible_args[index]
            resolution = "by-ordinal-fallback"
            ordinal = index

        if matched is None:
            unresolved.append(
                {
                    "requested_name": requested_name,
                    "requested_type": requested_type,
                    "requested_index": index,
                    "reason": "kernel argument not found by name or ordinal fallback",
                }
            )
            continue

        binding = {
            "requested_name": requested_name,
            "requested_type": requested_type,
            "resolution": resolution,
            "kernel_arg_name": matched.get("name"),
            "kernel_arg_offset": int(matched.get("offset", 0) or 0),
            "kernel_arg_size": int(matched.get("size", 0) or 0),
            "kernel_arg_value_kind": matched.get("value_kind"),
        }
        if matched.get("address_space") is not None:
            binding["kernel_arg_address_space"] = matched.get("address_space")
        if matched.get("type_name") is not None:
            binding["kernel_arg_type_name"] = matched.get("type_name")
        if ordinal is not None:
            binding["ordinal"] = ordinal
        bindings.append(binding)
    return bindings, unresolved


def unsupported_site(entry: dict, kernel: dict, reason: str) -> dict:
    kernel_name = kernel.get("name") or kernel.get("symbol")
    return {
        "probe_id": entry.get("probe_id"),
        "surrogate": entry.get("surrogate"),
        "contract": entry.get("contract"),
        "when": entry.get("when"),
        "kernel": kernel_name,
        "status": "unsupported",
        "reason": reason,
    }


def plan_entry_for_kernel(entry: dict, kernel: dict) -> tuple[dict | None, dict | None]:
    contract = str(entry.get("contract", ""))
    when = str(entry.get("when", ""))
    target = entry.get("target", {})

    if isinstance(target, dict) and target.get("match"):
        return None, unsupported_site(
            entry,
            kernel,
            "target.match selectors are not yet supported by the binary-only planner",
        )

    if contract != "kernel_lifecycle_v1":
        return None, unsupported_site(
            entry,
            kernel,
            f"contract {contract!r} is not yet supported by the binary-only planner",
        )

    if when not in {"kernel_entry", "kernel_exit"}:
        return None, unsupported_site(
            entry,
            kernel,
            f"lifecycle planning does not support when={when!r}",
        )

    capture_layout = entry.get("capture_layout", {})
    struct_fields = capture_layout.get("struct_fields", []) if isinstance(capture_layout, dict) else []
    event_fields = capture_layout.get("event_fields", []) if isinstance(capture_layout, dict) else []
    bindings, unresolved = bind_capture_fields(
        kernel,
        [field for field in struct_fields if isinstance(field, dict)],
    )
    return (
        {
            "probe_id": entry.get("probe_id"),
            "surrogate": entry.get("surrogate"),
            "helper": entry.get("helper"),
            "contract": contract,
            "when": when,
            "captures_type": entry.get("captures_type"),
            "event_type": entry.get("event_type"),
            "status": "planned",
            "injection_point": {
                "kind": when,
            },
            "call_signature": entry.get("signature", {}),
            "payload": entry.get("payload", {}),
            "capture_layout": {
                "struct_fields": struct_fields,
                "event_fields": event_fields,
            },
            "helper_context": entry.get("helper_context", {}),
            "capture_bindings": bindings,
            "unresolved_captures": unresolved,
        },
        None,
    )


def plan_kernel(kernel: dict, surrogates: list[dict], pointer_size: int, alignment: int) -> dict:
    hidden_plan = build_kernel_plan(kernel, pointer_size=pointer_size, alignment=alignment)
    planned_sites: list[dict] = []
    unsupported_sites: list[dict] = []

    for entry in surrogates:
        if not kernel_target_matches(entry, kernel):
            continue
        planned, unsupported = plan_entry_for_kernel(entry, kernel)
        if planned is not None:
            planned_sites.append(planned)
        if unsupported is not None:
            unsupported_sites.append(unsupported)

    return {
        "source_kernel": kernel.get("name") or kernel.get("symbol"),
        "source_symbol": kernel.get("symbol"),
        "clone_kernel": hidden_plan["hidden_abi_clone_name"],
        "hidden_omniprobe_ctx": hidden_plan["hidden_omniprobe_ctx"],
        "instrumented_kernarg_length": hidden_plan["instrumented_kernarg_length"],
        "planned_sites": planned_sites,
        "unsupported_sites": unsupported_sites,
        "notes": hidden_plan["notes"],
    }


def render_plan(
    *,
    manifest_path: Path,
    manifest: dict,
    probe_manifest_path: Path,
    probe_manifest: dict,
    selected_kernels: list[dict],
    pointer_size: int,
    alignment: int,
) -> dict:
    surrogates = probe_manifest.get("surrogates", [])
    if not isinstance(surrogates, list):
        raise SystemExit("probe manifest does not contain a valid 'surrogates' list")

    kernel_plans = [
        plan_kernel(kernel, [entry for entry in surrogates if isinstance(entry, dict)], pointer_size, alignment)
        for kernel in selected_kernels
    ]

    unmatched_surrogates: list[dict] = []
    for entry in surrogates:
        if not isinstance(entry, dict):
            continue
        if not any(kernel_target_matches(entry, kernel) for kernel in selected_kernels):
            unmatched_surrogates.append(
                {
                    "probe_id": entry.get("probe_id"),
                    "surrogate": entry.get("surrogate"),
                    "reason": "no selected kernel matched target.kernels",
                }
            )

    unsupported_total = sum(len(plan["unsupported_sites"]) for plan in kernel_plans)
    planned_total = sum(len(plan["planned_sites"]) for plan in kernel_plans)
    target = manifest.get("kernels", {}).get("metadata", {}).get("target")
    bundle = probe_manifest.get("_bundle")
    output = {
        "planning_only": True,
        "supported": unsupported_total == 0,
        "code_object_manifest": str(manifest_path),
        "probe_manifest": str(probe_manifest_path),
        "target": target,
        "pointer_size": pointer_size,
        "alignment": alignment,
        "planned_site_count": planned_total,
        "unsupported_site_count": unsupported_total,
        "selected_kernel_count": len(selected_kernels),
        "kernels": kernel_plans,
        "unmatched_surrogates": unmatched_surrogates,
    }
    if isinstance(bundle, dict):
        output["probe_bundle"] = bundle
    return output


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest).resolve()
    manifest = load_json(manifest_path)
    probe_manifest_path, probe_manifest = resolve_probe_manifest_path(args)
    selected_kernels = match_selected_kernels(kernel_records(manifest), list(args.kernel))
    plan = render_plan(
        manifest_path=manifest_path,
        manifest=manifest,
        probe_manifest_path=probe_manifest_path,
        probe_manifest=probe_manifest,
        selected_kernels=selected_kernels,
        pointer_size=args.pointer_size,
        alignment=args.alignment,
    )

    payload = json.dumps(plan, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0 if plan["supported"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
