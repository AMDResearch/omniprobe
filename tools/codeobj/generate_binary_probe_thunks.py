#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from amdgpu_calling_convention import layout_call_arguments


TYPE_MAP = {
    "u64": "uint64_t",
    "u32": "uint32_t",
    "u16": "uint16_t",
    "u8": "uint8_t",
    "i64": "int64_t",
    "i32": "int32_t",
    "i16": "int16_t",
    "i8": "int8_t",
    "bool": "bool",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate kernel-specific binary probe thunks from an Omniprobe "
            "binary probe plan. The current implementation supports "
            "kernel_lifecycle_v1 sites."
        )
    )
    parser.add_argument(
        "plan",
        help="Planner JSON emitted by plan_probe_instrumentation.py",
    )
    parser.add_argument(
        "--probe-bundle",
        required=True,
        help="Generated probe bundle JSON emitted by prepare_probe_bundle.py",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path for generated thunk HIP/C++ source",
    )
    parser.add_argument(
        "--manifest-output",
        default=None,
        help="Optional JSON manifest describing generated thunk symbols",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sanitize_identifier(value: str) -> str:
    sanitized = re.sub(r"[^0-9A-Za-z_]+", "_", value).strip("_")
    if not sanitized:
        sanitized = "probe"
    if sanitized[0].isdigit():
        sanitized = f"probe_{sanitized}"
    return sanitized


def cpp_type_for_field(field: dict) -> str:
    explicit = field.get("type")
    if isinstance(explicit, str) and explicit:
        return TYPE_MAP.get(explicit, explicit)
    return "uint64_t"


def manifest_output_path(explicit: str | None, output_path: Path) -> Path:
    if explicit:
        return Path(explicit).resolve()
    return output_path.with_suffix(output_path.suffix + ".manifest.json")


def probe_helper_namespace(bundle: dict) -> str | None:
    manifest_path_value = bundle.get("manifest")
    if not isinstance(manifest_path_value, str) or not manifest_path_value:
        return None
    manifest_path = Path(manifest_path_value).resolve()
    if not manifest_path.exists():
        return None
    manifest = load_json(manifest_path)
    helpers = manifest.get("helpers", {})
    namespace = helpers.get("namespace") if isinstance(helpers, dict) else None
    return str(namespace) if isinstance(namespace, str) and namespace else None


def render_binding_line(binding: dict, captures_type: str, field: dict) -> str:
    requested_name = sanitize_identifier(str(field.get("name", "value")))
    field_type = cpp_type_for_field(field)
    offset = int(binding.get("kernel_arg_offset", 0) or 0)
    return f"  captures.{requested_name} = load_kernarg<{field_type}>(kernarg_base, {offset});"


def field_argument_name(field: dict) -> str:
    requested_name = sanitize_identifier(str(field.get("name", "value")))
    return f"capture_{requested_name}"


def build_call_arguments(capture_fields: list[dict], capture_bindings: list[dict]) -> list[dict]:
    arguments: list[dict] = [
        {
            "kind": "hidden_ctx",
            "name": "hidden_ctx",
            "c_type": "const void *",
            "size_bytes": 8,
        }
    ]
    for field, binding in zip(capture_fields, capture_bindings):
        field_name = field_argument_name(field)
        arguments.append(
            {
                "kind": "capture",
                "name": field_name,
                "field_name": sanitize_identifier(str(field.get("name", "value"))),
                "c_type": cpp_type_for_field(field),
                "size_bytes": int(binding.get("kernel_arg_size", 0) or 0),
                "kernel_arg_offset": int(binding.get("kernel_arg_offset", 0) or 0),
                "kernel_arg_name": binding.get("kernel_arg_name"),
            }
        )
    arguments.append(
        {
            "kind": "timestamp",
            "name": "timestamp",
            "c_type": "uint64_t",
            "size_bytes": 8,
        }
    )
    return arguments


def render_thunk_function(kernel: dict, site: dict) -> tuple[str, dict]:
    contract = str(site.get("contract", ""))
    if contract != "kernel_lifecycle_v1":
        raise SystemExit(
            f"generate_binary_probe_thunks.py does not yet support contract {contract!r}"
        )

    when = str(site.get("when", ""))
    if when not in {"kernel_entry", "kernel_exit"}:
        raise SystemExit(
            f"generate_binary_probe_thunks.py does not support lifecycle when={when!r}"
        )

    probe_id = str(site.get("probe_id", "probe"))
    captures_type = str(site.get("captures_type", ""))
    surrogate = str(site.get("surrogate", ""))
    if not captures_type or not surrogate:
        raise SystemExit("planned lifecycle site is missing captures_type or surrogate")

    source_kernel = str(kernel.get("source_kernel", "kernel"))
    thunk_name = (
        "__omniprobe_binary_"
        f"{sanitize_identifier(probe_id)}_"
        f"{sanitize_identifier(source_kernel)}_"
        f"{sanitize_identifier(when)}_thunk"
    )

    capture_fields = site.get("capture_layout", {}).get("struct_fields", [])
    capture_bindings = site.get("capture_bindings", [])
    unresolved = site.get("unresolved_captures", [])
    if unresolved:
        names = ", ".join(str(entry.get("requested_name", "?")) for entry in unresolved)
        raise SystemExit(
            f"planned lifecycle site {surrogate} still has unresolved captures: {names}"
        )
    if len(capture_fields) != len(capture_bindings):
        raise SystemExit(
            f"capture binding mismatch for {surrogate}: "
            f"{len(capture_fields)} fields vs {len(capture_bindings)} bindings"
        )

    call_arguments = build_call_arguments(capture_fields, capture_bindings)
    call_layout = layout_call_arguments(call_arguments)
    parameter_lines = []
    for index, argument in enumerate(call_arguments):
        suffix = "," if index != len(call_arguments) - 1 else ""
        parameter_lines.append(f"    {argument['c_type']} {argument['name']}{suffix}")

    lines = [
        f"extern \"C\" __device__ __attribute__((used)) void {thunk_name}(",
        *parameter_lines,
        ") {",
        "  runtime_ctx runtime{};",
        "  runtime.dh = reinterpret_cast<dh_comms::dh_comms_descriptor *>(",
        "      const_cast<void *>(hidden_ctx));",
        f"  {captures_type} captures{{}};",
    ]
    for field in capture_fields:
        field_name = sanitize_identifier(str(field.get("name", "value")))
        argument_name = field_argument_name(field)
        field_type = cpp_type_for_field(field)
        lines.append(f"  captures.{field_name} = static_cast<{field_type}>({argument_name});")
    lines.append(f"  {surrogate}(&runtime, &captures, timestamp);")
    lines.append("}")
    manifest_entry = {
        "source_kernel": source_kernel,
        "clone_kernel": kernel.get("clone_kernel"),
        "probe_id": probe_id,
        "when": when,
        "contract": contract,
        "surrogate": surrogate,
        "thunk": thunk_name,
        "captures_type": captures_type,
        "signature": {
            "arguments": [f"{entry['c_type']} {entry['name']}" for entry in call_arguments]
        },
        "call_arguments": call_layout["arguments"],
        "call_argument_dwords": call_layout["total_dwords"],
        "capture_bindings": capture_bindings,
    }
    return "\n".join(lines), manifest_entry


def render_source(bundle: dict, plan: dict) -> tuple[str, list[dict]]:
    surrogate_source = bundle.get("surrogate_source")
    helper_source = bundle.get("helper_source")
    helper_namespace = probe_helper_namespace(bundle)
    if not isinstance(surrogate_source, str) or not surrogate_source:
        raise SystemExit("probe bundle does not contain surrogate_source")
    if not isinstance(helper_source, str) or not helper_source:
        raise SystemExit("probe bundle does not contain helper_source")

    generated_blocks: list[str] = []
    manifest_entries: list[dict] = []
    for kernel in plan.get("kernels", []):
        if not isinstance(kernel, dict):
            continue
        for site in kernel.get("planned_sites", []):
            if not isinstance(site, dict):
                continue
            block, entry = render_thunk_function(kernel, site)
            generated_blocks.append(block)
            manifest_entries.append(entry)

    lines = [
        "// Generated by tools/codeobj/generate_binary_probe_thunks.py",
        "// These thunks are kernel-specific adapters for Omniprobe's binary-only",
        "// rewrite path. They reconstruct Omniprobe's runtime_ctx wrapper from",
        "// the hidden carrier argument, accept already-marshalled capture values",
        "// from the rewritten caller, and then call the shared surrogate layer.",
        "",
        "#include <stdint.h>",
        f'#include "{surrogate_source}"',
        f'#include "{helper_source}"',
        "",
        "using namespace omniprobe::probe_abi_v1;",
        "",
    ]
    if helper_namespace:
        lines.extend([f"using namespace {helper_namespace};", ""])
    if generated_blocks:
        lines.append("\n\n".join(generated_blocks))
        lines.append("")
    return "\n".join(lines), manifest_entries


def main() -> int:
    args = parse_args()
    plan_path = Path(args.plan).resolve()
    bundle_path = Path(args.probe_bundle).resolve()
    output_path = Path(args.output).resolve()
    output_manifest_path = manifest_output_path(args.manifest_output, output_path)

    plan = load_json(plan_path)
    bundle = load_json(bundle_path)
    source, manifest_entries = render_source(bundle, plan)
    output_path.write_text(source, encoding="utf-8")
    output_manifest_path.write_text(
        json.dumps(
            {
                "planning_only": bool(plan.get("planning_only", True)),
                "probe_bundle": str(bundle_path),
                "plan": str(plan_path),
                "thunk_source": str(output_path),
                "thunks": manifest_entries,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
