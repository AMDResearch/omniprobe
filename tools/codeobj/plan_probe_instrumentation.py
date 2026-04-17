#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from disasm_to_ir import build_basic_blocks
from plan_hidden_abi import build_kernel_plan

MEMORY_ACCESS_PREFIXES = (
    ("global_load", "load", "global"),
    ("global_store", "store", "global"),
    ("flat_load", "load", "flat"),
    ("flat_store", "store", "flat"),
    ("buffer_load", "load", "global"),
    ("buffer_store", "store", "global"),
    ("ds_read", "load", "local"),
    ("ds_write", "store", "local"),
    ("scratch_load", "load", "scratch"),
    ("scratch_store", "store", "scratch"),
    ("image_load", "load", "image"),
    ("image_store", "store", "image"),
)


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
        "--ir",
        default=None,
        help="Optional instruction-level IR JSON emitted by disasm_to_ir.py for non-lifecycle site selection",
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


def function_records(ir: dict | None) -> list[dict]:
    if not isinstance(ir, dict):
        return []
    functions = ir.get("functions", [])
    return [function for function in functions if isinstance(function, dict)]


def find_kernel_function(ir: dict | None, kernel: dict) -> dict | None:
    values = {
        str(field)
        for field in (kernel.get("name"), kernel.get("symbol"))
        if isinstance(field, str) and field
    }
    for function in function_records(ir):
        name = function.get("name")
        if isinstance(name, str) and name in values:
            if not isinstance(function.get("basic_blocks"), list):
                build_basic_blocks(function)
            return function
    return None


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


def selector_for_entry(entry: dict) -> dict | None:
    target = entry.get("target", {})
    if not isinstance(target, dict):
        return None
    selector = target.get("match")
    return selector if isinstance(selector, dict) else None


def normalize_selector_values(selector: dict | None) -> set[str]:
    if not isinstance(selector, dict):
        return set()
    values = selector.get("values", [])
    if not isinstance(values, list):
        return set()
    return {str(value) for value in values if isinstance(value, str) and value}


def memory_width_bytes(mnemonic: str) -> int | None:
    lowered = mnemonic.lower()
    if "byte" in lowered:
        return 1
    if "short" in lowered:
        return 2
    if "word" in lowered and "dword" not in lowered and "qword" not in lowered:
        return 2
    if "dwordx" in lowered:
        suffix = lowered.split("dwordx", 1)[1]
        digits = ""
        for ch in suffix:
            if ch.isdigit():
                digits += ch
            else:
                break
        if digits:
            return 4 * int(digits)
    if "dword" in lowered:
        return 4
    if "qwordx" in lowered:
        suffix = lowered.split("qwordx", 1)[1]
        digits = ""
        for ch in suffix:
            if ch.isdigit():
                digits += ch
            else:
                break
        if digits:
            return 8 * int(digits)
    if "qword" in lowered:
        return 8
    return None


def classify_memory_instruction(instruction: dict) -> dict | None:
    mnemonic = str(instruction.get("mnemonic", "") or "")
    for prefix, access_kind, address_space in MEMORY_ACCESS_PREFIXES:
        if mnemonic.startswith(prefix):
            return {
                "mnemonic_family": prefix,
                "access_kind": access_kind,
                "address_space": address_space,
                "bytes": memory_width_bytes(mnemonic),
            }
    return None


def callee_names(instruction: dict) -> set[str]:
    names: set[str] = set()
    target = instruction.get("target")
    if isinstance(target, dict):
        for key in ("symbol", "raw"):
            value = target.get(key)
            if isinstance(value, str) and value:
                names.add(value)
    operands = instruction.get("operands", [])
    if isinstance(operands, list) and len(operands) >= 2:
        value = operands[-1]
        if isinstance(value, str) and value and not value.startswith("s["):
            names.add(value)
    return names


def instruction_matches_selector(
    *,
    selector: dict | None,
    instruction: dict,
    memory_info: dict | None = None,
) -> bool:
    if not isinstance(selector, dict):
        return True
    kind = str(selector.get("kind", "") or "")
    values = normalize_selector_values(selector)
    if not values:
        return True
    if kind == "isa_mnemonic":
        candidates = {str(instruction.get("mnemonic", ""))}
        if isinstance(memory_info, dict):
            candidates.add(str(memory_info.get("mnemonic_family", "")))
            access_kind = str(memory_info.get("access_kind", "") or "")
            address_space = str(memory_info.get("address_space", "") or "")
            if access_kind and address_space:
                candidates.add(f"{address_space}_{access_kind}")
                if address_space == "global":
                    candidates.add(f"global_{access_kind}")
        return bool(candidates & values)
    if kind == "memory_access_class":
        if not isinstance(memory_info, dict):
            return False
        candidates = {
            str(memory_info.get("access_kind", "")),
            str(memory_info.get("address_space", "")),
            f"{memory_info.get('address_space', '')}_{memory_info.get('access_kind', '')}",
        }
        return bool(candidates & values)
    if kind == "function_name":
        return bool(callee_names(instruction) & values)
    return False


def planned_site_base(entry: dict, kernel: dict) -> tuple[dict, list[dict], list[dict]]:
    capture_layout = entry.get("capture_layout", {})
    struct_fields = capture_layout.get("struct_fields", []) if isinstance(capture_layout, dict) else []
    event_fields = capture_layout.get("event_fields", []) if isinstance(capture_layout, dict) else []
    bindings, unresolved = bind_capture_fields(
        kernel,
        [field for field in struct_fields if isinstance(field, dict)],
    )
    planned = {
        "probe_id": entry.get("probe_id"),
        "surrogate": entry.get("surrogate"),
        "helper": entry.get("helper"),
        "contract": str(entry.get("contract", "")),
        "when": str(entry.get("when", "")),
        "captures_type": entry.get("captures_type"),
        "event_type": entry.get("event_type"),
        "status": "planned",
        "call_signature": entry.get("signature", {}),
        "payload": entry.get("payload", {}),
        "capture_layout": {
            "struct_fields": struct_fields,
            "event_fields": event_fields,
        },
        "helper_context": entry.get("helper_context", {}),
        "capture_bindings": bindings,
        "unresolved_captures": unresolved,
    }
    return planned, bindings, unresolved


def plan_lifecycle_site(entry: dict, kernel: dict) -> tuple[list[dict], list[dict]]:
    planned, _bindings, _unresolved = planned_site_base(entry, kernel)
    when = planned["when"]
    if when not in {"kernel_entry", "kernel_exit"}:
        return [], [
            unsupported_site(
                entry,
                kernel,
                f"lifecycle planning does not support when={when!r}",
            )
        ]
    planned["injection_point"] = {"kind": when}
    return [planned], []


def plan_memory_sites(entry: dict, kernel: dict, function: dict | None) -> tuple[list[dict], list[dict]]:
    if function is None:
        return [], [
            unsupported_site(
                entry,
                kernel,
                "memory_op planning requires instruction IR; rerun with --ir",
            )
        ]
    selector = selector_for_entry(entry)
    if isinstance(selector, dict) and str(selector.get("kind", "") or "") == "source_location":
        return [], [
            unsupported_site(
                entry,
                kernel,
                "memory_op planning does not yet support target.match.kind='source_location'",
            )
        ]
    planned_sites: list[dict] = []
    for instruction in function.get("instructions", []):
        if not isinstance(instruction, dict):
            continue
        memory_info = classify_memory_instruction(instruction)
        if memory_info is None:
            continue
        if not instruction_matches_selector(selector=selector, instruction=instruction, memory_info=memory_info):
            continue
        planned, _bindings, unresolved = planned_site_base(entry, kernel)
        if unresolved:
            names = ", ".join(str(item.get("requested_name", "?")) for item in unresolved)
            return [], [
                unsupported_site(
                    entry,
                    kernel,
                    f"memory_op planning has unresolved captures: {names}",
                )
            ]
        binary_site_id = len(planned_sites)
        planned["binary_site_id"] = binary_site_id
        planned["injection_point"] = {
            "kind": "memory_op",
            "instruction_address": int(instruction.get("address", 0) or 0),
            "instruction_mnemonic": instruction.get("mnemonic"),
            "binary_site_id": binary_site_id,
        }
        planned["event_materialization"] = {
            "address": {"kind": "dynamic_memory_address"},
            "bytes": {"kind": "static_instruction_width", "value": memory_info.get("bytes")},
            "access_kind": {"kind": "static_access_kind", "value": memory_info.get("access_kind")},
            "address_space": {"kind": "static_address_space", "value": memory_info.get("address_space")},
        }
        planned_sites.append(planned)
    return planned_sites, []


def plan_basic_block_sites(entry: dict, kernel: dict, function: dict | None) -> tuple[list[dict], list[dict]]:
    if function is None:
        return [], [
            unsupported_site(
                entry,
                kernel,
                "basic_block planning requires instruction IR; rerun with --ir",
            )
        ]
    if selector_for_entry(entry) is not None:
        return [], [
            unsupported_site(
                entry,
                kernel,
                "basic_block planning does not yet support target.match selectors",
            )
        ]
    blocks = function.get("basic_blocks", [])
    planned_sites: list[dict] = []
    for block_id, block in enumerate(blocks):
        if not isinstance(block, dict):
            continue
        if block_id == 0:
            # Reserve the entry block for the dedicated kernel_entry path.
            # Mid-kernel basic-block stubs may need scratch/private-segment state
            # that is not fully established until after entry materialization.
            continue
        planned, _bindings, unresolved = planned_site_base(entry, kernel)
        if unresolved:
            names = ", ".join(str(item.get("requested_name", "?")) for item in unresolved)
            return [], [
                unsupported_site(
                    entry,
                    kernel,
                    f"basic_block planning has unresolved captures: {names}",
                )
            ]
        planned["binary_site_id"] = block_id
        planned["injection_point"] = {
            "kind": "basic_block",
            "block_id": block_id,
            "block_label": block.get("label"),
            "start_address": int(block.get("start_address", 0) or 0),
            "end_address": int(block.get("end_address", 0) or 0),
        }
        planned["event_materialization"] = {
            "timestamp": {"kind": "dynamic_timestamp"},
            "block_id": {"kind": "static_block_id", "value": block_id},
        }
        planned_sites.append(planned)
    return planned_sites, []


def plan_call_sites(entry: dict, kernel: dict, function: dict | None) -> tuple[list[dict], list[dict]]:
    if function is None:
        return [], [
            unsupported_site(
                entry,
                kernel,
                "call planning requires instruction IR; rerun with --ir",
            )
        ]
    selector = selector_for_entry(entry)
    selector_kind = str(selector.get("kind", "") or "") if isinstance(selector, dict) else ""
    if selector is not None and selector_kind not in {"function_name", ""}:
        return [], [
            unsupported_site(
                entry,
                kernel,
                f"call planning does not yet support target.match.kind={selector_kind!r}",
            )
        ]
    planned_sites: list[dict] = []
    for instruction in function.get("instructions", []):
        if not isinstance(instruction, dict):
            continue
        mnemonic = str(instruction.get("mnemonic", "") or "")
        if mnemonic != "s_swappc_b64":
            continue
        if not instruction_matches_selector(selector=selector, instruction=instruction):
            continue
        callee = next(iter(sorted(callee_names(instruction))), None)
        planned, _bindings, unresolved = planned_site_base(entry, kernel)
        if unresolved:
            names = ", ".join(str(item.get("requested_name", "?")) for item in unresolved)
            return [], [
                unsupported_site(
                    entry,
                    kernel,
                    f"call planning has unresolved captures: {names}",
                )
            ]
        binary_site_id = len(planned_sites)
        planned["binary_site_id"] = binary_site_id
        planned["injection_point"] = {
            "kind": str(entry.get("when", "")),
            "instruction_address": int(instruction.get("address", 0) or 0),
            "instruction_mnemonic": instruction.get("mnemonic"),
            "binary_site_id": binary_site_id,
            "callee": callee,
        }
        planned["event_materialization"] = {
            "timestamp": {"kind": "dynamic_timestamp"},
            "callee_id": {"kind": "static_callee_id", "value": binary_site_id, "callee": callee},
        }
        planned_sites.append(planned)
    return planned_sites, []


def plan_entry_for_kernel(entry: dict, kernel: dict, function: dict | None) -> tuple[list[dict], list[dict]]:
    contract = str(entry.get("contract", ""))
    target = entry.get("target", {})

    if isinstance(target, dict) and target.get("match") and contract == "kernel_lifecycle_v1":
        return [], [
            unsupported_site(
                entry,
                kernel,
                "target.match selectors are not yet supported for kernel_lifecycle_v1 planning",
            )
        ]
    if contract == "kernel_lifecycle_v1":
        return plan_lifecycle_site(entry, kernel)
    if contract == "memory_op_v1":
        return plan_memory_sites(entry, kernel, function)
    if contract == "basic_block_v1":
        return plan_basic_block_sites(entry, kernel, function)
    if contract == "call_v1":
        return plan_call_sites(entry, kernel, function)
    return [], [
        unsupported_site(
            entry,
            kernel,
            f"contract {contract!r} is not supported by the binary-only planner",
        )
    ]


def plan_kernel(kernel: dict, surrogates: list[dict], pointer_size: int, alignment: int, ir: dict | None) -> dict:
    hidden_plan = build_kernel_plan(kernel, pointer_size=pointer_size, alignment=alignment)
    planned_sites: list[dict] = []
    unsupported_sites: list[dict] = []
    function = find_kernel_function(ir, kernel)

    for entry in surrogates:
        if not kernel_target_matches(entry, kernel):
            continue
        planned, unsupported = plan_entry_for_kernel(entry, kernel, function)
        planned_sites.extend(planned)
        unsupported_sites.extend(unsupported)

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
    ir_path: Path | None,
    ir: dict | None,
) -> dict:
    surrogates = probe_manifest.get("surrogates", [])
    if not isinstance(surrogates, list):
        raise SystemExit("probe manifest does not contain a valid 'surrogates' list")

    kernel_plans = [
        plan_kernel(
            kernel,
            [entry for entry in surrogates if isinstance(entry, dict)],
            pointer_size,
            alignment,
            ir,
        )
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
    if ir_path is not None:
        output["instruction_ir"] = str(ir_path)
    return output


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest).resolve()
    manifest = load_json(manifest_path)
    ir_path = Path(args.ir).resolve() if args.ir else None
    ir = load_json(ir_path) if ir_path else None
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
        ir_path=ir_path,
        ir=ir,
    )

    payload = json.dumps(plan, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0 if plan["supported"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
