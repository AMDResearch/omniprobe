#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ALLOWED_TOP_LEVEL_KEYS = {"version", "helpers", "defaults", "probes"}
ALLOWED_HELPER_KEYS = {"source", "namespace"}
ALLOWED_DEFAULT_KEYS = {"emission", "lane_headers", "state"}
ALLOWED_PROBE_KEYS = {"id", "target", "inject", "payload", "capture"}
ALLOWED_TARGET_KEYS = {"kernels", "match"}
ALLOWED_MATCH_KEYS = {"kind", "values"}
ALLOWED_INJECT_KEYS = {"when", "helper", "contract", "event_usage"}
ALLOWED_PAYLOAD_KEYS = {"mode", "message"}
ALLOWED_CAPTURE_KEYS = {"kernel_args", "builtins", "instruction"}

ALLOWED_EMISSION_MODES = {"auto", "scalar", "vector"}
ALLOWED_MESSAGE_KINDS = {"address", "time_interval", "wave_header", "custom"}
ALLOWED_WHEN = {
    "kernel_entry",
    "kernel_exit",
    "memory_op",
    "basic_block",
    "call_before",
    "call_after",
}
ALLOWED_CONTRACTS = {
    "kernel_lifecycle_v1": {"kernel_entry", "kernel_exit"},
    "memory_op_v1": {"memory_op"},
    "basic_block_v1": {"basic_block"},
    "call_v1": {"call_before", "call_after"},
}
ALLOWED_EVENT_USAGE = {"none", "dispatch_origin"}
ALLOWED_MATCH_KINDS = {
    "isa_mnemonic",
    "function_name",
    "source_location",
    "memory_access_class",
}
ALLOWED_BUILTINS = {
    "grid_dim",
    "block_dim",
    "block_idx",
    "thread_idx",
    "dispatch_id",
    "lane_id",
    "wave_id",
    "wavefront_size",
    "exec",
    "hw_id",
}
FORBIDDEN_HELPER_CONTEXT_REQUESTS = {
    "gridDim": "use capture.builtins: [grid_dim]",
    "blockDim": "use capture.builtins: [block_dim]",
    "blockIdx": "use capture.builtins: [block_idx]",
    "threadIdx": "use capture.builtins: [thread_idx]",
    "dispatchPtr": "compiler-generated dispatch/live-in values are not part of the helper ABI",
    "dispatch_ptr": "compiler-generated dispatch/live-in values are not part of the helper ABI",
    "implicitarg_ptr": "compiler-generated implicitarg live-ins are not part of the helper ABI",
    "kernarg_segment_ptr": "compiler-generated kernarg live-ins are not part of the helper ABI",
    "private_segment_buffer": "compiler-generated private-segment live-ins are not part of the helper ABI",
    "private_segment_wave_byte_offset": "compiler-generated private-segment live-ins are not part of the helper ABI",
}
ALLOWED_INSTRUCTION_FIELDS = {
    "address",
    "bytes",
    "addr_space",
    "access_kind",
    "opcode",
    "callee",
}
HELPER_ABI_SCHEMA = "omniprobe.helper_abi.v1"
HELPER_ABI_MODEL = "explicit_runtime_v1"
HELPER_ABI_NOTES = [
    "Heavyweight helpers must not rely on compiler-generated live-ins or builtins at arbitrary insertion points.",
    "Helpers are expected to consume Omniprobe-captured state plus runtime dispatch payload inputs instead.",
]


class SpecError(ValueError):
    pass


@dataclass(frozen=True)
class SourceLine:
    lineno: int
    indent: int
    content: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate and normalize an Omniprobe v1 instrumentation probe spec "
            "written in the constrained YAML subset used by Omniprobe."
        )
    )
    parser.add_argument("spec", help="Probe spec YAML file")
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit normalized JSON to stdout",
    )
    return parser.parse_args()


def unique_ordered(values: list[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        if value not in result:
            result.append(value)
    return result


def strip_comments(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    result: list[str] = []
    for index, ch in enumerate(line):
        if escaped:
            result.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_double:
            result.append(ch)
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            result.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            result.append(ch)
            continue
        if ch == "#" and not in_single and not in_double:
            if index == 0 or line[index - 1].isspace():
                break
        result.append(ch)
    return "".join(result).rstrip()


def lex_document(text: str) -> list[SourceLine]:
    lines: list[SourceLine] = []
    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        line = strip_comments(raw_line)
        if not line.strip():
            continue
        if "\t" in raw_line:
            raise SpecError(f"line {lineno}: tabs are not supported in probe specs")
        indent = len(line) - len(line.lstrip(" "))
        lines.append(SourceLine(lineno=lineno, indent=indent, content=line.strip()))
    return lines


def split_top_level(text: str, delimiter: str) -> list[str]:
    items: list[str] = []
    current: list[str] = []
    depth = 0
    in_single = False
    in_double = False
    escaped = False
    for ch in text:
        if escaped:
            current.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_double:
            current.append(ch)
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            current.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            current.append(ch)
            continue
        if not in_single and not in_double:
            if ch in "[{(":
                depth += 1
            elif ch in "]})":
                depth -= 1
            elif ch == delimiter and depth == 0:
                items.append("".join(current).strip())
                current = []
                continue
        current.append(ch)
    if current:
        items.append("".join(current).strip())
    return [item for item in items if item]


def split_key_value(text: str) -> tuple[str, str | None]:
    depth = 0
    in_single = False
    in_double = False
    escaped = False
    for index, ch in enumerate(text):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_double:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            continue
        if in_single or in_double:
            continue
        if ch in "[{(":
            depth += 1
            continue
        if ch in "]})":
            depth -= 1
            continue
        if ch == ":" and depth == 0:
            key = text[:index].strip()
            remainder = text[index + 1 :].strip()
            if not key:
                raise SpecError("empty mapping key")
            return key, remainder if remainder else None
    raise SpecError(f"expected mapping entry, got {text!r}")


def parse_scalar(text: str) -> Any:
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(item) for item in split_top_level(inner, ",")]
    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        result: dict[str, Any] = {}
        for item in split_top_level(inner, ","):
            key, value = split_key_value(item)
            result[key] = None if value is None else parse_scalar(value)
        return result
    if (text.startswith('"') and text.endswith('"')) or (
        text.startswith("'") and text.endswith("'")
    ):
        return ast.literal_eval(text)
    if re.fullmatch(r"-?[0-9]+", text):
        return int(text)
    lowered = text.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "~"}:
        return None
    return text


def parse_block(lines: list[SourceLine], index: int, indent: int) -> tuple[Any, int]:
    if index >= len(lines):
        raise SpecError("unexpected end of document")
    if lines[index].indent != indent:
        raise SpecError(
            f"line {lines[index].lineno}: expected indent {indent}, got {lines[index].indent}"
        )
    if lines[index].content.startswith("- "):
        return parse_sequence(lines, index, indent)
    return parse_mapping(lines, index, indent)


def parse_mapping(lines: list[SourceLine], index: int, indent: int) -> tuple[dict[str, Any], int]:
    result: dict[str, Any] = {}
    while index < len(lines):
        line = lines[index]
        if line.indent < indent:
            break
        if line.indent > indent:
            raise SpecError(
                f"line {line.lineno}: unexpected indentation inside mapping"
            )
        if line.content.startswith("- "):
            break
        key, remainder = split_key_value(line.content)
        index += 1
        if remainder is None:
            if index < len(lines) and lines[index].indent > indent:
                value, index = parse_block(lines, index, lines[index].indent)
            else:
                value = None
        else:
            value = parse_scalar(remainder)
        result[key] = value
    return result, index


def parse_sequence(lines: list[SourceLine], index: int, indent: int) -> tuple[list[Any], int]:
    result: list[Any] = []
    while index < len(lines):
        line = lines[index]
        if line.indent < indent:
            break
        if line.indent > indent:
            raise SpecError(
                f"line {line.lineno}: unexpected indentation inside sequence"
            )
        if not line.content.startswith("- "):
            break
        item_text = line.content[2:].strip()
        index += 1
        if not item_text:
            if index >= len(lines) or lines[index].indent <= indent:
                raise SpecError(f"line {line.lineno}: sequence item missing value")
            item, index = parse_block(lines, index, lines[index].indent)
            result.append(item)
            continue

        try:
            key, remainder = split_key_value(item_text)
        except SpecError:
            if index < len(lines) and lines[index].indent > indent:
                raise SpecError(
                    f"line {line.lineno}: scalar sequence items cannot own nested blocks"
                )
            result.append(parse_scalar(item_text))
            continue

        item: dict[str, Any] = {}
        if remainder is None:
            if index < len(lines) and lines[index].indent > indent:
                value, index = parse_block(lines, index, lines[index].indent)
            else:
                value = None
        else:
            value = parse_scalar(remainder)
        item[key] = value

        if index < len(lines) and lines[index].indent > indent:
            extra, index = parse_mapping(lines, index, lines[index].indent)
            item.update(extra)
        result.append(item)
    return result, index


def parse_yaml_subset(text: str) -> Any:
    lines = lex_document(text)
    if not lines:
        raise SpecError("probe spec is empty")
    document, index = parse_block(lines, 0, lines[0].indent)
    if index != len(lines):
        line = lines[index]
        raise SpecError(f"line {line.lineno}: trailing unparsed content")
    return document


def ensure_keys(mapping: dict[str, Any], allowed: set[str], context: str) -> None:
    unknown = sorted(set(mapping.keys()) - allowed)
    if unknown:
        raise SpecError(f"{context}: unknown keys: {', '.join(unknown)}")


def ensure_string_list(value: Any, context: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SpecError(f"{context}: expected a list of strings")
    return list(value)


def normalize_kernel_args(value: Any, context: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise SpecError(f"{context}: expected a list")
    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        entry_context = f"{context}[{index}]"
        if isinstance(item, str):
            normalized.append({"name": item})
            continue
        if not isinstance(item, dict):
            raise SpecError(f"{entry_context}: expected a string or mapping")
        if "name" not in item or not isinstance(item["name"], str):
            raise SpecError(f"{entry_context}: missing string field 'name'")
        normalized_item = {"name": item["name"]}
        if "type" in item:
            if not isinstance(item["type"], str):
                raise SpecError(f"{entry_context}.type: expected a string")
            normalized_item["type"] = item["type"]
        unknown = sorted(set(item.keys()) - {"name", "type"})
        if unknown:
            raise SpecError(f"{entry_context}: unknown keys: {', '.join(unknown)}")
        normalized.append(normalized_item)
    return normalized


def normalize_probe(probe: Any, defaults: dict[str, Any], probe_index: int) -> dict[str, Any]:
    context = f"probes[{probe_index}]"
    if not isinstance(probe, dict):
        raise SpecError(f"{context}: expected a mapping")
    ensure_keys(probe, ALLOWED_PROBE_KEYS, context)

    probe_id = probe.get("id")
    if not isinstance(probe_id, str) or not probe_id:
        raise SpecError(f"{context}.id: expected a non-empty string")

    target = probe.get("target")
    if not isinstance(target, dict):
        raise SpecError(f"{context}.target: expected a mapping")
    ensure_keys(target, ALLOWED_TARGET_KEYS, f"{context}.target")
    kernels = ensure_string_list(target.get("kernels", []), f"{context}.target.kernels")
    if not kernels:
        raise SpecError(f"{context}.target.kernels: must not be empty")
    normalized_target: dict[str, Any] = {"kernels": kernels}
    if "match" in target:
        match = target["match"]
        if not isinstance(match, dict):
            raise SpecError(f"{context}.target.match: expected a mapping")
        ensure_keys(match, ALLOWED_MATCH_KEYS, f"{context}.target.match")
        kind = match.get("kind")
        values = match.get("values")
        if not isinstance(kind, str) or kind not in ALLOWED_MATCH_KINDS:
            raise SpecError(
                f"{context}.target.match.kind: expected one of {sorted(ALLOWED_MATCH_KINDS)}"
            )
        normalized_target["match"] = {
            "kind": kind,
            "values": ensure_string_list(values, f"{context}.target.match.values"),
        }

    inject = probe.get("inject")
    if not isinstance(inject, dict):
        raise SpecError(f"{context}.inject: expected a mapping")
    ensure_keys(inject, ALLOWED_INJECT_KEYS, f"{context}.inject")
    when_value = inject.get("when")
    when_list = [when_value] if isinstance(when_value, str) else when_value
    when = ensure_string_list(when_list, f"{context}.inject.when")
    unknown_when = sorted(set(when) - ALLOWED_WHEN)
    if unknown_when:
        raise SpecError(f"{context}.inject.when: unsupported values: {', '.join(unknown_when)}")
    helper = inject.get("helper")
    if not isinstance(helper, str) or not helper:
        raise SpecError(f"{context}.inject.helper: expected a non-empty string")
    contract = inject.get("contract")
    if not isinstance(contract, str) or contract not in ALLOWED_CONTRACTS:
        raise SpecError(
            f"{context}.inject.contract: expected one of {sorted(ALLOWED_CONTRACTS)}"
        )
    unsupported_for_contract = sorted(set(when) - ALLOWED_CONTRACTS[contract])
    if unsupported_for_contract:
        raise SpecError(
            f"{context}.inject.contract: {contract} does not support when={unsupported_for_contract}"
        )
    event_usage = inject.get("event_usage")
    if contract == "kernel_lifecycle_v1":
        if event_usage is None:
            event_usage = "dispatch_origin"
        if not isinstance(event_usage, str) or event_usage not in ALLOWED_EVENT_USAGE:
            raise SpecError(
                f"{context}.inject.event_usage: expected one of {sorted(ALLOWED_EVENT_USAGE)}"
            )
    elif "event_usage" in inject:
        raise SpecError(
            f"{context}.inject.event_usage: only supported for contract 'kernel_lifecycle_v1'"
        )

    normalized_inject = {
        "when": when,
        "helper": helper,
        "contract": contract,
    }
    if contract == "kernel_lifecycle_v1":
        normalized_inject["event_usage"] = event_usage

    payload = probe.get("payload", {})
    if not isinstance(payload, dict):
        raise SpecError(f"{context}.payload: expected a mapping")
    ensure_keys(payload, ALLOWED_PAYLOAD_KEYS, f"{context}.payload")
    mode = payload.get("mode", defaults["emission"])
    if not isinstance(mode, str) or mode not in ALLOWED_EMISSION_MODES:
        raise SpecError(
            f"{context}.payload.mode: expected one of {sorted(ALLOWED_EMISSION_MODES)}"
        )
    message = payload.get("message", "custom")
    if not isinstance(message, str) or message not in ALLOWED_MESSAGE_KINDS:
        raise SpecError(
            f"{context}.payload.message: expected one of {sorted(ALLOWED_MESSAGE_KINDS)}"
        )

    capture = probe.get("capture", {})
    if not isinstance(capture, dict):
        raise SpecError(f"{context}.capture: expected a mapping")
    ensure_keys(capture, ALLOWED_CAPTURE_KEYS, f"{context}.capture")
    kernel_args = normalize_kernel_args(capture.get("kernel_args", []), f"{context}.capture.kernel_args")
    builtins = ensure_string_list(capture.get("builtins", []), f"{context}.capture.builtins")
    forbidden_helper_requests = sorted(
        value for value in set(builtins) if value in FORBIDDEN_HELPER_CONTEXT_REQUESTS
    )
    if forbidden_helper_requests:
        details = "; ".join(
            f"{value}: {FORBIDDEN_HELPER_CONTEXT_REQUESTS[value]}"
            for value in forbidden_helper_requests
        )
        raise SpecError(
            f"{context}.capture.builtins: helper requests must use Omniprobe runtime-context names; {details}"
        )
    unknown_builtins = sorted(set(builtins) - ALLOWED_BUILTINS)
    if unknown_builtins:
        raise SpecError(f"{context}.capture.builtins: unsupported values: {', '.join(unknown_builtins)}")
    instruction = ensure_string_list(
        capture.get("instruction", []), f"{context}.capture.instruction"
    )
    unknown_instruction = sorted(set(instruction) - ALLOWED_INSTRUCTION_FIELDS)
    if unknown_instruction:
        raise SpecError(
            f"{context}.capture.instruction: unsupported values: {', '.join(unknown_instruction)}"
        )

    required_runtime_views: list[str] = []
    if builtins:
        required_runtime_views.append("runtime_ctx.dh_builtins")
    if "dispatch_id" in builtins:
        required_runtime_views.append("runtime_ctx.dispatch_id")
    if any(name in {"grid_dim", "block_dim"} for name in builtins):
        required_runtime_views.append("runtime_ctx.dispatch_uniform")
    if any(
        name in {"block_dim", "block_idx", "thread_idx", "lane_id", "wave_id", "wavefront_size", "exec", "hw_id"}
        for name in builtins
    ):
        required_runtime_views.append("runtime_ctx.site_snapshot")

    helper_abi = {
        "schema": HELPER_ABI_SCHEMA,
        "model": HELPER_ABI_MODEL,
        "compiler_generated_liveins_allowed": False,
        "compiler_generated_builtins_allowed": False,
        "requires_wrapper_captured_state": True,
        "requires_runtime_dispatch_payload": True,
        "required_runtime_views": unique_ordered(required_runtime_views),
        "helper_visible_sources": {
            "kernel_args": [str(arg["name"]) for arg in kernel_args],
            "instruction_fields": instruction,
            "builtins": {
                "requested": builtins,
                "provider": "runtime_ctx.dh_builtins",
            },
            "event_payload": {
                "contract": contract,
                "when": when,
            },
        },
        "notes": list(HELPER_ABI_NOTES),
    }

    return {
        "id": probe_id,
        "target": normalized_target,
        "inject": normalized_inject,
        "payload": {
            "mode": mode,
            "message": message,
            "lane_headers": defaults["lane_headers"],
        },
        "capture": {
            "kernel_args": kernel_args,
            "builtins": builtins,
            "instruction": instruction,
        },
        "helper_abi": helper_abi,
    }


def normalize_spec(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise SpecError("probe spec root must be a mapping")
    ensure_keys(document, ALLOWED_TOP_LEVEL_KEYS, "root")

    version = document.get("version")
    if version != 1:
        raise SpecError("root.version: only version 1 is supported")

    helpers = document.get("helpers")
    if not isinstance(helpers, dict):
        raise SpecError("root.helpers: expected a mapping")
    ensure_keys(helpers, ALLOWED_HELPER_KEYS, "root.helpers")
    helper_source = helpers.get("source")
    if not isinstance(helper_source, str) or not helper_source:
        raise SpecError("root.helpers.source: expected a non-empty string")
    helper_namespace = helpers.get("namespace", "omniprobe_user")
    if not isinstance(helper_namespace, str) or not helper_namespace:
        raise SpecError("root.helpers.namespace: expected a non-empty string")

    defaults_raw = document.get("defaults", {})
    if not isinstance(defaults_raw, dict):
        raise SpecError("root.defaults: expected a mapping")
    ensure_keys(defaults_raw, ALLOWED_DEFAULT_KEYS, "root.defaults")
    defaults = {
        "emission": defaults_raw.get("emission", "auto"),
        "lane_headers": defaults_raw.get("lane_headers", False),
        "state": defaults_raw.get("state", "none"),
    }
    if defaults["emission"] not in ALLOWED_EMISSION_MODES:
        raise SpecError(
            f"root.defaults.emission: expected one of {sorted(ALLOWED_EMISSION_MODES)}"
        )
    if not isinstance(defaults["lane_headers"], bool):
        raise SpecError("root.defaults.lane_headers: expected a boolean")
    if not isinstance(defaults["state"], str):
        raise SpecError("root.defaults.state: expected a string")

    probes = document.get("probes")
    if not isinstance(probes, list) or not probes:
        raise SpecError("root.probes: expected a non-empty list")

    return {
        "version": 1,
        "helpers": {
            "source": helper_source,
            "namespace": helper_namespace,
        },
        "defaults": defaults,
        "probes": [
            normalize_probe(probe, defaults=defaults, probe_index=index)
            for index, probe in enumerate(probes)
        ],
    }


def render_summary(spec: dict[str, Any]) -> str:
    lines = [
        "probe spec: valid",
        f"version: {spec['version']}",
        f"helpers.source: {spec['helpers']['source']}",
        f"helpers.namespace: {spec['helpers']['namespace']}",
        f"probes: {len(spec['probes'])}",
    ]
    for probe in spec["probes"]:
        lines.append(
            "  - {}: contract={} when={} mode={} message={}".format(
                probe["id"],
                probe["inject"]["contract"],
                ",".join(probe["inject"]["when"]),
                probe["payload"]["mode"],
                probe["payload"]["message"],
            )
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        raw = Path(args.spec).read_text(encoding="utf-8")
        parsed = parse_yaml_subset(raw)
        normalized = normalize_spec(parsed)
    except (OSError, SpecError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        json.dump(normalized, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_summary(normalized))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
