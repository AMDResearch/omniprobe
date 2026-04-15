#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from validate_probe_spec import normalize_spec, parse_yaml_subset


CONTRACT_EVENT_TYPE = {
    "kernel_lifecycle_v1": "kernel_lifecycle_event",
    "memory_op_v1": "memory_op_event",
    "basic_block_v1": "basic_block_event",
    "call_v1": "call_event",
}

CONTRACT_EVENT_KIND = {
    "kernel_lifecycle_v1": {
        "kernel_entry": "event_kind::kernel_entry",
        "kernel_exit": "event_kind::kernel_exit",
    },
    "memory_op_v1": {
        "memory_op": "event_kind::memory_load",
    },
    "basic_block_v1": {
        "basic_block": "event_kind::basic_block",
    },
    "call_v1": {
        "call_before": "event_kind::call_before",
        "call_after": "event_kind::call_after",
    },
}

MESSAGE_KIND_EXPR = {
    "custom": "message_kind::custom",
    "address": "message_kind::address",
    "time_interval": "message_kind::time_interval",
    "wave_header": "message_kind::wave_header",
}

EMISSION_MODE_EXPR = {
    "auto": "emission_mode::auto_mode",
    "scalar": "emission_mode::scalar",
    "vector": "emission_mode::vector",
}

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate Omniprobe v1 surrogate HIP/C++ scaffolding and a probe "
            "manifest from a validated probe-spec YAML file."
        )
    )
    parser.add_argument("spec", help="Probe spec YAML file")
    parser.add_argument(
        "--hip-output",
        required=True,
        help="Path for generated surrogate HIP/C++ source",
    )
    parser.add_argument(
        "--manifest-output",
        required=True,
        help="Path for generated surrogate manifest JSON",
    )
    return parser.parse_args()


def sanitize_identifier(value: str) -> str:
    sanitized = re.sub(r"[^0-9A-Za-z_]+", "_", value).strip("_")
    if not sanitized:
        sanitized = "probe"
    if sanitized[0].isdigit():
        sanitized = f"probe_{sanitized}"
    return sanitized


def contract_helper_enum(contract: str) -> str:
    if not contract.endswith("_v1"):
        raise ValueError(f"unsupported contract name {contract!r}")
    return contract.removesuffix("_v1")


def cpp_type_for_kernel_arg(arg: dict[str, object]) -> str:
    explicit = arg.get("type")
    if isinstance(explicit, str) and explicit:
        if explicit == "u64":
            return "uint64_t"
        if explicit == "u32":
            return "uint32_t"
        if explicit == "i64":
            return "int64_t"
        if explicit == "i32":
            return "int32_t"
        if explicit == "bool":
            return "bool"
        return explicit
    return "uint64_t"


def helper_arg_signature(contract: str, captures_type: str) -> tuple[list[str], list[str], list[str]]:
    if contract == "kernel_lifecycle_v1":
        return (
            [
                "const runtime_ctx *runtime",
                f"const {captures_type} *captures",
                "uint64_t timestamp",
            ],
            ["runtime", "captures", "timestamp"],
            [
                "kernel_lifecycle_event event{};",
                "event.timestamp = timestamp;",
            ],
        )
    if contract == "memory_op_v1":
        return (
            [
                "const runtime_ctx *runtime",
                f"const {captures_type} *captures",
                "uint64_t address",
                "uint32_t bytes",
                "uint8_t access_kind",
                "uint8_t address_space",
            ],
            ["runtime", "captures", "address", "bytes", "access_kind", "address_space"],
            [
                "memory_op_event event{};",
                "event.address = address;",
                "event.bytes = bytes;",
                "event.access = static_cast<memory_access_kind>(access_kind);",
                "event.address_space = static_cast<address_space_kind>(address_space);",
            ],
        )
    if contract == "basic_block_v1":
        return (
            [
                "const runtime_ctx *runtime",
                f"const {captures_type} *captures",
                "uint64_t timestamp",
                "uint32_t block_id",
            ],
            ["runtime", "captures", "timestamp", "block_id"],
            [
                "basic_block_event event{};",
                "event.timestamp = timestamp;",
                "event.block_id = block_id;",
            ],
        )
    if contract == "call_v1":
        return (
            [
                "const runtime_ctx *runtime",
                f"const {captures_type} *captures",
                "uint64_t timestamp",
                "uint32_t callee_id",
            ],
            ["runtime", "captures", "timestamp", "callee_id"],
            [
                "call_event event{};",
                "event.timestamp = timestamp;",
                "event.callee_id = callee_id;",
            ],
        )
    raise ValueError(f"unsupported contract {contract!r}")


def expand_probe_sites(spec: dict[str, object]) -> list[dict[str, object]]:
    sites: list[dict[str, object]] = []
    next_site_id = 0
    for probe in spec["probes"]:
        probe_id = str(probe["id"])
        probe_ident = sanitize_identifier(probe_id)
        contract = str(probe["inject"]["contract"])
        event_type = CONTRACT_EVENT_TYPE[contract]
        captures_type = f"{probe_ident}_captures"
        helper_name = str(probe["inject"]["helper"])
        when_values = list(probe["inject"]["when"])
        multi_site = len(when_values) > 1
        for when_item in when_values:
            site_ident = (
                f"{probe_ident}_{sanitize_identifier(when_item)}"
                if multi_site
                else probe_ident
            )
            sites.append(
                {
                    "site_id": next_site_id,
                    "logical_probe_id": probe_id,
                    "probe_ident": probe_ident,
                    "site_when": when_item,
                    "site_ident": site_ident,
                    "surrogate": f"__omniprobe_probe_{site_ident}_surrogate",
                    "captures_type": captures_type,
                    "helper": helper_name,
                    "contract": contract,
                    "event_type": event_type,
                    "target": probe["target"],
                    "payload": probe["payload"],
                    "capture": probe["capture"],
                }
            )
            next_site_id += 1
    return sites


def render_capture_struct(site: dict[str, object]) -> str:
    captures_type = str(site["captures_type"])
    lines = [f"struct {captures_type} {{"]  # generated in helper namespace
    capture = site["capture"]

    kernel_args = capture["kernel_args"]
    if not kernel_args:
        lines.append("  uint8_t reserved = 0;")
        lines.append("};")
        return "\n".join(lines)

    for arg in kernel_args:
        arg_name = sanitize_identifier(str(arg["name"]))
        lines.append(f"  {cpp_type_for_kernel_arg(arg)} {arg_name}{{}};")
    lines.append("};")
    return "\n".join(lines)


def render_helper_decl(site: dict[str, object]) -> str:
    helper_name = str(site["helper"])
    captures_type = str(site["captures_type"])
    event_type = str(site["event_type"])
    return (
        f"extern \"C\" __device__ void {helper_name}(\n"
        f"    const helper_args<{captures_type}, {event_type}> &args);"
    )


def render_probe_block(site: dict[str, object]) -> tuple[str, dict[str, object]]:
    captures_type = str(site["captures_type"])
    contract = str(site["contract"])
    event_type = CONTRACT_EVENT_TYPE[contract]
    when_item = str(site["site_when"])
    surrogate_name = str(site["surrogate"])
    helper_name = str(site["helper"])
    arg_decls, arg_names, event_lines = helper_arg_signature(contract, captures_type)
    event_kind_expr = CONTRACT_EVENT_KIND[contract][when_item]
    emission_expr = EMISSION_MODE_EXPR[str(site["payload"]["mode"])]
    message_expr = MESSAGE_KIND_EXPR[str(site["payload"]["message"])]
    lane_headers = "1" if site["payload"]["lane_headers"] else "0"

    lines = [
        f"extern \"C\" __device__ __attribute__((used)) void {surrogate_name}(",
        "    " + ",\n    ".join(arg_decls) + ") {",
        "  site_info site{};",
        f"  site.probe_id = {site['site_id']};",
        f"  site.event = {event_kind_expr};",
        f"  site.contract = helper_contract::{contract_helper_enum(contract)};",
        f"  site.emission = {emission_expr};",
        f"  site.message = {message_expr};",
        f"  site.has_lane_headers = {lane_headers};",
    ]
    lines.extend([f"  {line}" for line in event_lines])
    lines.extend(
        [
            f"  helper_args<{captures_type}, {event_type}> args{{}};",
            "  args.runtime = runtime;",
            "  args.site = &site;",
            "  args.captures = captures;",
            "  args.event = &event;",
            f"  {helper_name}(args);",
            "}",
        ]
    )
    manifest = {
        "site_id": site["site_id"],
        "probe_id": site["logical_probe_id"],
        "site_when": when_item,
        "surrogate": surrogate_name,
        "helper": helper_name,
        "captures_type": captures_type,
        "event_type": event_type,
        "when": when_item,
        "contract": contract,
        "payload": site["payload"],
        "target": site["target"],
        "capture": site["capture"],
        "signature": {
            "arguments": arg_decls,
            "argument_names": arg_names,
        },
    }
    return "\n".join(lines), manifest


def render_source(spec: dict[str, object], sites: list[dict[str, object]], manifest_entries: list[dict[str, object]]) -> str:
    namespace = str(spec["helpers"]["namespace"])
    struct_blocks: list[str] = []
    seen_capture_types: set[str] = set()
    seen_helper_decls: set[str] = set()
    surrogate_blocks: list[str] = []
    for site in sites:
        captures_type = str(site["captures_type"])
        if captures_type not in seen_capture_types:
            struct_blocks.append(render_capture_struct(site))
            seen_capture_types.add(captures_type)
        helper_decl = render_helper_decl(site)
        if helper_decl not in seen_helper_decls:
            struct_blocks.append(helper_decl)
            seen_helper_decls.add(helper_decl)
        surrogate_blocks.append(render_probe_block(site)[0])

    lines = [
        "// Generated by tools/probes/generate_probe_surrogates.py",
        "// This file provides the probe-surrogate layer that Omniprobe",
        "// frontends should target instead of calling dh_comms entry points",
        "// directly from injected IR or rewritten ISA.",
        "",
        "#include <stdint.h>",
        '#include "dh_comms_dev.h"',
        '#include "omniprobe_probe_abi_v1.h"',
        "",
        f"namespace {namespace} {{",
        "",
        "using namespace omniprobe::probe_abi_v1;",
        "",
    ]
    for index, entry in enumerate(manifest_entries):
        if index:
            lines.append("")
            lines.append("")
        lines.append(f"// Probe: {entry['probe_id']}")
        lines.append(f"// Surrogate: {entry['surrogate']}")
        lines.append(f"// Contract: {entry['contract']}")
        helper_context = entry["helper_context"]["builtins"]
        if helper_context:
            lines.append(
                "// Helper-visible execution context: "
                + ", ".join(helper_context)
            )
    lines.append("")
    lines.append("\n\n".join(struct_blocks))
    lines.append("")
    lines.append("")
    lines.append("\n\n".join(surrogate_blocks))
    lines.append("")
    lines.append(f"}} // namespace {namespace}")
    lines.append("")
    return "\n".join(lines)


def flatten_manifest_entries(sites: list[dict[str, object]]) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for site in sites:
        _block, manifest = render_probe_block(site)
        capture = site["capture"]
        manifest["capture_layout"] = {
            "struct_fields": capture["kernel_args"],
            "event_fields": capture["instruction"],
        }
        manifest["helper_context"] = {
            "builtins": capture["builtins"],
        }
        entries.append(manifest)
    return entries


def main() -> int:
    args = parse_args()
    spec_path = Path(args.spec).resolve()
    document = parse_yaml_subset(spec_path.read_text(encoding="utf-8"))
    spec = normalize_spec(document)
    sites = expand_probe_sites(spec)
    manifest_entries = flatten_manifest_entries(sites)
    source = render_source(spec, sites, manifest_entries)

    Path(args.hip_output).write_text(source, encoding="utf-8")
    Path(args.manifest_output).write_text(
        json.dumps(
            {
                "version": spec["version"],
                "helpers": spec["helpers"],
                "defaults": spec["defaults"],
                "surrogates": manifest_entries,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
