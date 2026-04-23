#!/usr/bin/env python3
from __future__ import annotations

HELPER_ABI_SCHEMA = "omniprobe.helper_abi.v1"
HELPER_ABI_MODEL = "explicit_runtime_v1"


def _entry_name(entry: dict) -> str:
    for key in ("surrogate", "thunk", "probe_id", "source_kernel"):
        value = entry.get(key)
        if isinstance(value, str) and value:
            return value
    return "<unknown>"


def validate_helper_abi_entry(entry: dict, *, entry_kind: str) -> dict:
    name = _entry_name(entry)
    helper_abi = entry.get("helper_abi")
    if not isinstance(helper_abi, dict):
        raise SystemExit(
            f"{entry_kind} {name} is missing helper_abi; regenerate the probe manifest/plan with current tooling"
        )
    if helper_abi.get("schema") != HELPER_ABI_SCHEMA:
        raise SystemExit(
            f"{entry_kind} {name} has unsupported helper_abi.schema={helper_abi.get('schema')!r}"
        )
    if helper_abi.get("model") != HELPER_ABI_MODEL:
        raise SystemExit(
            f"{entry_kind} {name} has unsupported helper_abi.model={helper_abi.get('model')!r}"
        )
    if helper_abi.get("compiler_generated_liveins_allowed") is not False:
        raise SystemExit(
            f"{entry_kind} {name} must reject compiler-generated live-ins in helper_abi"
        )
    if helper_abi.get("compiler_generated_builtins_allowed") is not False:
        raise SystemExit(
            f"{entry_kind} {name} must reject compiler-generated builtins in helper_abi"
        )
    if helper_abi.get("requires_wrapper_captured_state") is not True:
        raise SystemExit(
            f"{entry_kind} {name} must require wrapper-captured state in helper_abi"
        )
    if helper_abi.get("requires_runtime_dispatch_payload") is not True:
        raise SystemExit(
            f"{entry_kind} {name} must require runtime dispatch payloads in helper_abi"
        )

    required_runtime_views = helper_abi.get("required_runtime_views", [])
    if not isinstance(required_runtime_views, list) or not all(
        isinstance(value, str) and value for value in required_runtime_views
    ):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.required_runtime_views"
        )

    helper_visible_sources = helper_abi.get("helper_visible_sources")
    if not isinstance(helper_visible_sources, dict):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.helper_visible_sources"
        )
    builtins_info = helper_visible_sources.get("builtins")
    if not isinstance(builtins_info, dict):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.helper_visible_sources.builtins"
        )
    if builtins_info.get("provider") != "runtime_ctx.dh_builtins":
        raise SystemExit(
            f"{entry_kind} {name} must source helper builtins from runtime_ctx.dh_builtins"
        )

    requested_builtins = builtins_info.get("requested", [])
    if not isinstance(requested_builtins, list) or not all(
        isinstance(value, str) and value for value in requested_builtins
    ):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.helper_visible_sources.builtins.requested"
        )
    helper_context = entry.get("helper_context", {})
    helper_context_builtins = helper_context.get("builtins", []) if isinstance(helper_context, dict) else []
    if requested_builtins != helper_context_builtins:
        raise SystemExit(
            f"{entry_kind} {name} has mismatched helper builtin requirements between helper_abi and helper_context"
        )

    event_payload = helper_visible_sources.get("event_payload")
    if not isinstance(event_payload, dict):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.helper_visible_sources.event_payload"
        )
    contract = entry.get("contract")
    if contract is not None and event_payload.get("contract") != contract:
        raise SystemExit(f"{entry_kind} {name} has mismatched helper_abi event contract")

    when_values = event_payload.get("when", [])
    if isinstance(when_values, str):
        when_values = [when_values]
    if not isinstance(when_values, list) or not all(isinstance(value, str) and value for value in when_values):
        raise SystemExit(
            f"{entry_kind} {name} has invalid helper_abi.helper_visible_sources.event_payload.when"
        )
    when = entry.get("when")
    if when is not None and str(when) not in when_values:
        raise SystemExit(f"{entry_kind} {name} helper_abi does not cover when={when!r}")
    return helper_abi
