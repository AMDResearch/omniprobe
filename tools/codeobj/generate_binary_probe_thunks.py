#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from amdgpu_calling_convention import layout_call_arguments
from helper_abi_contract import validate_helper_abi_entry


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

CONTRACT_EVENT_ARGUMENTS = {
    "kernel_lifecycle_v1": [
        {"kind": "timestamp", "name": "timestamp", "c_type": "uint64_t", "size_bytes": 8},
    ],
    "memory_op_v1": [
        {"kind": "event", "name": "address", "c_type": "uint64_t", "size_bytes": 8},
        {"kind": "event", "name": "bytes", "c_type": "uint32_t", "size_bytes": 4},
        {"kind": "event", "name": "access_kind", "c_type": "uint8_t", "size_bytes": 1},
        {"kind": "event", "name": "address_space", "c_type": "uint8_t", "size_bytes": 1},
    ],
    "basic_block_v1": [
        {"kind": "timestamp", "name": "timestamp", "c_type": "uint64_t", "size_bytes": 8},
        {"kind": "event", "name": "block_id", "c_type": "uint32_t", "size_bytes": 4},
    ],
    "call_v1": [
        {"kind": "timestamp", "name": "timestamp", "c_type": "uint64_t", "size_bytes": 8},
        {"kind": "event", "name": "callee_id", "c_type": "uint32_t", "size_bytes": 4},
    ],
}

BINARY_CONTRACT_EVENT_ARGUMENTS = {
    "memory_op_v1": [
        {"kind": "event", "name": "address", "c_type": "uint64_t", "size_bytes": 8},
        {
            "kind": "event",
            "name": "memory_info",
            "c_type": "uint32_t",
            "size_bytes": 4,
            "packing": "memory_op_compact_v1",
        },
    ],
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate kernel-specific binary probe thunks from an Omniprobe "
            "binary probe plan."
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


def requested_helper_builtins(site: dict) -> set[str]:
    helper_context = site.get("helper_context", {})
    if not isinstance(helper_context, dict):
        return set()
    builtins = helper_context.get("builtins", [])
    if not isinstance(builtins, list):
        return set()
    return {
        str(name)
        for name in builtins
        if isinstance(name, str) and name
    }


def source_entry_abi(kernel: dict) -> dict:
    payload = kernel.get("source_entry_abi", {})
    return payload if isinstance(payload, dict) else {}


def source_rsrc2(kernel: dict) -> dict:
    payload = source_entry_abi(kernel).get("compute_pgm_rsrc2", {})
    return payload if isinstance(payload, dict) else {}


def source_workgroup_id_available(kernel: dict, component: str) -> bool:
    value = source_rsrc2(kernel).get(f"enable_sgpr_workgroup_id_{component}")
    if isinstance(value, int):
        return value != 0
    return True


def source_workitem_vgpr_count(kernel: dict) -> int:
    payload = source_entry_abi(kernel)
    count = payload.get("entry_workitem_vgpr_count")
    if isinstance(count, int):
        return max(0, min(3, count))
    encoded = source_rsrc2(kernel).get("enable_vgpr_workitem_id")
    if isinstance(encoded, int) and encoded >= 0:
        return min(encoded + 1, 3)
    return 3


def source_thread_component_available(kernel: dict, component: str) -> bool:
    required = {"x": 1, "y": 2, "z": 3}.get(component, 1)
    return source_workitem_vgpr_count(kernel) >= required


def dispatch_origin_guard_lines(kernel: dict) -> list[str]:
    conditions = ["blockIdx.x == 0"]
    if source_workgroup_id_available(kernel, "y"):
        conditions.append("blockIdx.y == 0")
    if source_workgroup_id_available(kernel, "z"):
        conditions.append("blockIdx.z == 0")
    if source_thread_component_available(kernel, "x"):
        conditions.append("threadIdx.x == 0")
    if source_thread_component_available(kernel, "y"):
        conditions.append("threadIdx.y == 0")
    if source_thread_component_available(kernel, "z"):
        conditions.append("threadIdx.z == 0")
    conditions.append("__omniprobe_lane_id == 0")
    if len(conditions) <= 3:
        return [f"  if (!({' && '.join(conditions)})) {{"]
    first = " && ".join(conditions[:3])
    second = " && ".join(conditions[3:])
    return [
        f"  if (!({first} &&",
        f"        {second})) {{",
    ]


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


def build_site_call_arguments(contract: str, capture_fields: list[dict], capture_bindings: list[dict]) -> list[dict]:
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
    contract_arguments = BINARY_CONTRACT_EVENT_ARGUMENTS.get(contract)
    if contract_arguments is None:
        contract_arguments = CONTRACT_EVENT_ARGUMENTS.get(contract)
    if contract_arguments is None:
        raise SystemExit(f"generate_binary_probe_thunks.py does not yet support contract {contract!r}")
    arguments.extend(dict(argument) for argument in contract_arguments)
    return arguments


def surrogate_forward_arguments(contract: str) -> list[str]:
    if contract == "memory_op_v1":
        return [
            "address",
            "__omniprobe_event_bytes",
            "__omniprobe_event_access_kind",
            "__omniprobe_event_address_space",
        ]
    if contract == "kernel_lifecycle_v1":
        return [
            "timestamp",
            "__omniprobe_event_workgroup_x",
            "__omniprobe_event_workgroup_y",
            "__omniprobe_event_workgroup_z",
            "__omniprobe_event_thread_x",
            "__omniprobe_event_thread_y",
            "__omniprobe_event_thread_z",
            "__omniprobe_event_block_dim_x",
            "__omniprobe_event_block_dim_y",
            "__omniprobe_event_block_dim_z",
            "__omniprobe_event_lane_id",
            "__omniprobe_event_wave_id",
            "__omniprobe_event_wavefront_size",
            "__omniprobe_event_hw_id",
            "__omniprobe_event_exec_mask",
        ]
    arguments = CONTRACT_EVENT_ARGUMENTS.get(contract)
    if arguments is None:
        raise SystemExit(f"generate_binary_probe_thunks.py does not yet support contract {contract!r}")
    return [str(entry["name"]) for entry in arguments]


def render_site_event_unpack_lines(contract: str) -> list[str]:
    if contract != "memory_op_v1":
        return []
    return [
        "  const uint32_t __omniprobe_event_bytes = static_cast<uint32_t>(memory_info & 0xffffu);",
        "  const uint8_t __omniprobe_event_access_kind =",
        "      static_cast<uint8_t>((memory_info >> 16) & 0xffu);",
        "  const uint8_t __omniprobe_event_address_space =",
        "      static_cast<uint8_t>((memory_info >> 24) & 0xffu);",
    ]


def render_site_event_locals(kernel: dict, contract: str, when: str) -> list[str]:
    if contract != "kernel_lifecycle_v1":
        return []
    if when == "kernel_entry":
        return [
            *dispatch_origin_guard_lines(kernel),
            "    return;",
            "  }",
            "  const auto *__omniprobe_event_snapshot = runtime.entry_snapshot;",
            "  if (__omniprobe_event_snapshot == nullptr) {",
            "    return;",
            "  }",
            "  const uint32_t __omniprobe_event_workgroup_x = __omniprobe_event_snapshot->workgroup_x;",
            "  const uint32_t __omniprobe_event_workgroup_y = __omniprobe_event_snapshot->workgroup_y;",
            "  const uint32_t __omniprobe_event_workgroup_z = __omniprobe_event_snapshot->workgroup_z;",
            "  const uint32_t __omniprobe_event_thread_x = __omniprobe_event_snapshot->thread_x;",
            "  const uint32_t __omniprobe_event_thread_y = __omniprobe_event_snapshot->thread_y;",
            "  const uint32_t __omniprobe_event_thread_z = __omniprobe_event_snapshot->thread_z;",
            "  const uint32_t __omniprobe_event_block_dim_x = __omniprobe_event_snapshot->block_dim_x;",
            "  const uint32_t __omniprobe_event_block_dim_y = __omniprobe_event_snapshot->block_dim_y;",
            "  const uint32_t __omniprobe_event_block_dim_z = __omniprobe_event_snapshot->block_dim_z;",
            "  const uint32_t __omniprobe_event_lane_id = __omniprobe_event_snapshot->lane_id;",
            "  const uint32_t __omniprobe_event_wave_id = __omniprobe_event_snapshot->wave_id;",
            "  const uint32_t __omniprobe_event_wavefront_size = __omniprobe_event_snapshot->wavefront_size;",
            "  const uint32_t __omniprobe_event_hw_id = __omniprobe_event_snapshot->hw_id;",
            "  const uint64_t __omniprobe_event_exec_mask = __omniprobe_event_snapshot->exec_mask;",
        ]
    return [
        "  const uint32_t __omniprobe_event_workgroup_x = static_cast<uint32_t>(blockIdx.x);",
        (
            "  const uint32_t __omniprobe_event_workgroup_y = static_cast<uint32_t>(blockIdx.y);"
            if source_workgroup_id_available(kernel, "y")
            else "  const uint32_t __omniprobe_event_workgroup_y = 0u;"
        ),
        (
            "  const uint32_t __omniprobe_event_workgroup_z = static_cast<uint32_t>(blockIdx.z);"
            if source_workgroup_id_available(kernel, "z")
            else "  const uint32_t __omniprobe_event_workgroup_z = 0u;"
        ),
        "  const uint32_t __omniprobe_event_thread_x = static_cast<uint32_t>(threadIdx.x);",
        (
            "  const uint32_t __omniprobe_event_thread_y = static_cast<uint32_t>(threadIdx.y);"
            if source_thread_component_available(kernel, "y")
            else "  const uint32_t __omniprobe_event_thread_y = 0u;"
        ),
        (
            "  const uint32_t __omniprobe_event_thread_z = static_cast<uint32_t>(threadIdx.z);"
            if source_thread_component_available(kernel, "z")
            else "  const uint32_t __omniprobe_event_thread_z = 0u;"
        ),
        "  const uint32_t __omniprobe_event_block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "  const uint32_t __omniprobe_event_block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "  const uint32_t __omniprobe_event_block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "  const uint32_t __omniprobe_event_lane_id = static_cast<uint32_t>(__lane_id());",
        "  const uint32_t __omniprobe_event_wavefront_size = static_cast<uint32_t>(warpSize);",
        (
            "  const uint32_t __omniprobe_event_linear_tid = static_cast<uint32_t>(threadIdx.x + "
            "blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z));"
            if source_thread_component_available(kernel, "z")
            else (
                "  const uint32_t __omniprobe_event_linear_tid = static_cast<uint32_t>(threadIdx.x + "
                "blockDim.x * threadIdx.y);"
                if source_thread_component_available(kernel, "y")
                else "  const uint32_t __omniprobe_event_linear_tid = static_cast<uint32_t>(threadIdx.x);"
            )
        ),
        (
            "  const uint32_t __omniprobe_event_wave_id ="
            if source_thread_component_available(kernel, "y")
            else "  const uint32_t __omniprobe_event_wave_id = 0u;"
        ),
        *(
            [
                "      __omniprobe_event_wavefront_size == 0",
                "          ? 0",
                "          : (__omniprobe_event_linear_tid / __omniprobe_event_wavefront_size);",
            ]
            if source_thread_component_available(kernel, "y")
            else []
        ),
        "  const uint32_t __omniprobe_event_hw_id = static_cast<uint32_t>(__smid());",
        "  const uint64_t __omniprobe_event_exec_mask = __builtin_amdgcn_read_exec();",
    ]


def render_runtime_init_lines() -> list[str]:
    return [
        "  auto *runtime_storage = reinterpret_cast<runtime_storage_v2 *>(",
        "      const_cast<void *>(hidden_ctx));",
        "  runtime_ctx runtime{};",
        "  runtime.raw_hidden_ctx = hidden_ctx;",
        "  if (runtime_storage != nullptr) {",
        "    runtime.dh = runtime_storage->dh;",
        "    runtime.config_blob = runtime_storage->config_blob;",
        "    runtime.state_blob = runtime_storage->state_blob;",
        "    runtime.dispatch_id = runtime_storage->dispatch_id;",
        "    runtime.entry_snapshot = &runtime_storage->entry_snapshot;",
        "    runtime.dispatch_uniform = &runtime_storage->dispatch_uniform;",
        "    runtime.dispatch_private = runtime_storage->dispatch_private;",
        "    runtime.abi_version = runtime_storage->abi_version;",
        "    runtime.flags = runtime_storage->flags;",
        "  }",
    ]


def render_site_snapshot_capture_lines(kernel: dict, site: dict) -> list[str]:
    builtins = requested_helper_builtins(site)
    needs_block_idx = "block_idx" in builtins
    needs_thread_idx = "thread_idx" in builtins
    needs_block_dim = "block_dim" in builtins
    needs_lane = "lane_id" in builtins
    needs_wavefront = "wavefront_size" in builtins or "wave_num" in builtins
    needs_wave_num = "wave_num" in builtins
    needs_hw = "hw_id" in builtins
    needs_exec = "exec" in builtins

    lines = [
        "  site_snapshot_v1 __omniprobe_site_snapshot_storage{};",
    ]
    if needs_block_idx or not builtins:
        lines.append("  __omniprobe_site_snapshot_storage.workgroup_x = static_cast<uint32_t>(blockIdx.x);")
        lines.append(
            (
                "  __omniprobe_site_snapshot_storage.workgroup_y = static_cast<uint32_t>(blockIdx.y);"
                if source_workgroup_id_available(kernel, 'y')
                else "  __omniprobe_site_snapshot_storage.workgroup_y = 0u;"
            )
        )
        lines.append(
            (
                "  __omniprobe_site_snapshot_storage.workgroup_z = static_cast<uint32_t>(blockIdx.z);"
                if source_workgroup_id_available(kernel, 'z')
                else "  __omniprobe_site_snapshot_storage.workgroup_z = 0u;"
            )
        )
    if needs_thread_idx or not builtins:
        lines.append("  __omniprobe_site_snapshot_storage.thread_x = static_cast<uint32_t>(threadIdx.x);")
        lines.append(
            (
                "  __omniprobe_site_snapshot_storage.thread_y = static_cast<uint32_t>(threadIdx.y);"
                if source_thread_component_available(kernel, 'y')
                else "  __omniprobe_site_snapshot_storage.thread_y = 0u;"
            )
        )
        lines.append(
            (
                "  __omniprobe_site_snapshot_storage.thread_z = static_cast<uint32_t>(threadIdx.z);"
                if source_thread_component_available(kernel, 'z')
                else "  __omniprobe_site_snapshot_storage.thread_z = 0u;"
            )
        )
    if needs_block_dim or not builtins:
        lines.extend(
            [
                "  __omniprobe_site_snapshot_storage.block_dim_x = static_cast<uint32_t>(blockDim.x);",
                "  __omniprobe_site_snapshot_storage.block_dim_y = static_cast<uint32_t>(blockDim.y);",
                "  __omniprobe_site_snapshot_storage.block_dim_z = static_cast<uint32_t>(blockDim.z);",
            ]
        )
    if needs_lane or not builtins:
        lines.append("  __omniprobe_site_snapshot_storage.lane_id = static_cast<uint32_t>(__lane_id());")
    if needs_wavefront or not builtins:
        lines.append(
            "  __omniprobe_site_snapshot_storage.wavefront_size = static_cast<uint32_t>(warpSize);"
        )
    else:
        lines.append("  __omniprobe_site_snapshot_storage.wavefront_size = 1u;")
    if needs_wave_num or not builtins:
        if source_thread_component_available(kernel, "z"):
            lines.extend(
                [
                    "  const uint32_t __omniprobe_site_linear_tid = static_cast<uint32_t>(",
                    "      threadIdx.x + blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z));",
                ]
            )
        elif source_thread_component_available(kernel, "y"):
            lines.append(
                "  const uint32_t __omniprobe_site_linear_tid = static_cast<uint32_t>(threadIdx.x + blockDim.x * threadIdx.y);"
            )
        else:
            lines.append(
                "  const uint32_t __omniprobe_site_linear_tid = static_cast<uint32_t>(threadIdx.x);"
            )
        lines.extend(
            [
                "  __omniprobe_site_snapshot_storage.wave_id =",
                "      __omniprobe_site_snapshot_storage.wavefront_size == 0",
                "          ? 0u",
                "          : (__omniprobe_site_linear_tid / __omniprobe_site_snapshot_storage.wavefront_size);",
            ]
        )
    if needs_hw or not builtins:
        lines.append("  __omniprobe_site_snapshot_storage.hw_id = static_cast<uint32_t>(__smid());")
    if needs_exec or not builtins:
        lines.append("  __omniprobe_site_snapshot_storage.exec_mask = __builtin_amdgcn_read_exec();")
    lines.append("  runtime.site_snapshot = &__omniprobe_site_snapshot_storage;")
    return lines


def render_dh_builtin_capture_lines(when: str) -> list[str]:
    return [
        "  dh_comms::builtin_snapshot_t __omniprobe_dh_builtins{};",
        "  const auto *__omniprobe_site_snapshot = runtime.site_snapshot;",
        "  const auto *__omniprobe_dispatch_uniform = runtime.dispatch_uniform;",
        "  const bool __omniprobe_has_site_snapshot = __omniprobe_site_snapshot != nullptr &&",
        "      (__omniprobe_site_snapshot->wavefront_size != 0);",
        "  const bool __omniprobe_has_grid_dim = __omniprobe_dispatch_uniform != nullptr &&",
        "      ((__omniprobe_dispatch_uniform->valid_mask & dispatch_uniform_valid_grid_dim) != 0);",
        "  const bool __omniprobe_has_block_dim = __omniprobe_dispatch_uniform != nullptr &&",
        "      ((__omniprobe_dispatch_uniform->valid_mask & dispatch_uniform_valid_block_dim) != 0);",
        "  __omniprobe_dh_builtins.grid_dim_x = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_x",
        "      : 0u;",
        "  __omniprobe_dh_builtins.grid_dim_y = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_y",
        "      : 0u;",
        "  __omniprobe_dh_builtins.grid_dim_z = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_z",
        "      : 0u;",
        "  const uint32_t __omniprobe_builtin_block_dim_x = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_x",
        "      : (__omniprobe_has_site_snapshot ? __omniprobe_site_snapshot->block_dim_x : 0u);",
        "  const uint32_t __omniprobe_builtin_block_dim_y = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_y",
        "      : (__omniprobe_has_site_snapshot ? __omniprobe_site_snapshot->block_dim_y : 0u);",
        "  const uint32_t __omniprobe_builtin_block_dim_z = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_z",
        "      : (__omniprobe_has_site_snapshot ? __omniprobe_site_snapshot->block_dim_z : 0u);",
        "  __omniprobe_dh_builtins.block_dim_x = __omniprobe_builtin_block_dim_x;",
        "  __omniprobe_dh_builtins.block_dim_y = __omniprobe_builtin_block_dim_y;",
        "  __omniprobe_dh_builtins.block_dim_z = __omniprobe_builtin_block_dim_z;",
        "  __omniprobe_dh_builtins.block_idx_x = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->workgroup_x",
        "      : 0u;",
        "  __omniprobe_dh_builtins.block_idx_y = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->workgroup_y",
        "      : 0u;",
        "  __omniprobe_dh_builtins.block_idx_z = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->workgroup_z",
        "      : 0u;",
        "  const uint32_t __omniprobe_builtin_thread_idx_x = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->thread_x",
        "      : 0u;",
        "  const uint32_t __omniprobe_builtin_thread_idx_y = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->thread_y",
        "      : 0u;",
        "  const uint32_t __omniprobe_builtin_thread_idx_z = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->thread_z",
        "      : 0u;",
        "  __omniprobe_dh_builtins.thread_idx_x = __omniprobe_builtin_thread_idx_x;",
        "  __omniprobe_dh_builtins.thread_idx_y = __omniprobe_builtin_thread_idx_y;",
        "  __omniprobe_dh_builtins.thread_idx_z = __omniprobe_builtin_thread_idx_z;",
        "  __omniprobe_dh_builtins.lane_id = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->lane_id",
        "      : 0u;",
        "  __omniprobe_dh_builtins.wavefront_size = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->wavefront_size",
        "      : 0u;",
        "  __omniprobe_dh_builtins.wave_num = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->wave_id",
        "      : 0u;",
        "  __omniprobe_dh_builtins.exec = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->exec_mask",
        "      : 0u;",
        "  __omniprobe_dh_builtins.xcc_id = 0;",
        "  const uint32_t __omniprobe_builtin_hw_id = __omniprobe_has_site_snapshot",
        "      ? __omniprobe_site_snapshot->hw_id",
        "      : 0u;",
        "  __omniprobe_dh_builtins.hw_id = __omniprobe_builtin_hw_id;",
        "  __omniprobe_dh_builtins.se_id = static_cast<uint16_t>((__omniprobe_builtin_hw_id >> 13) & 0x7);",
        "  __omniprobe_dh_builtins.cu_id = static_cast<uint16_t>((__omniprobe_builtin_hw_id >> 8) & 0xf);",
        "  __omniprobe_dh_builtins.arch = dh_comms::detect_gcn_arch();",
        "  runtime.dh_builtins = &__omniprobe_dh_builtins;",
    ]

def render_entry_snapshot_capture_lines(kernel: dict, when: str) -> list[str]:
    if when != "kernel_entry":
        return []
    return [
        "  auto *entry_snapshot = const_cast<entry_snapshot_v1 *>(runtime.entry_snapshot);",
        "  if (entry_snapshot == nullptr) {",
        "    return;",
        "  }",
        "  const uint32_t __omniprobe_lane_id = static_cast<uint32_t>(__lane_id());",
        *dispatch_origin_guard_lines(kernel),
        "    entry_snapshot->workgroup_x = static_cast<uint32_t>(blockIdx.x);",
        (
            "    entry_snapshot->workgroup_y = static_cast<uint32_t>(blockIdx.y);"
            if source_workgroup_id_available(kernel, "y")
            else "    entry_snapshot->workgroup_y = 0u;"
        ),
        (
            "    entry_snapshot->workgroup_z = static_cast<uint32_t>(blockIdx.z);"
            if source_workgroup_id_available(kernel, "z")
            else "    entry_snapshot->workgroup_z = 0u;"
        ),
        "    entry_snapshot->thread_x = static_cast<uint32_t>(threadIdx.x);",
        (
            "    entry_snapshot->thread_y = static_cast<uint32_t>(threadIdx.y);"
            if source_thread_component_available(kernel, "y")
            else "    entry_snapshot->thread_y = 0u;"
        ),
        (
            "    entry_snapshot->thread_z = static_cast<uint32_t>(threadIdx.z);"
            if source_thread_component_available(kernel, "z")
            else "    entry_snapshot->thread_z = 0u;"
        ),
        "    entry_snapshot->block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "    entry_snapshot->block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "    entry_snapshot->block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "    entry_snapshot->lane_id = __omniprobe_lane_id;",
        "    entry_snapshot->wave_id = 0;",
        "    entry_snapshot->wavefront_size = static_cast<uint32_t>(warpSize);",
        "    entry_snapshot->hw_id = static_cast<uint32_t>(__smid());",
        "    entry_snapshot->exec_mask = __builtin_amdgcn_read_exec();",
        "    entry_snapshot->timestamp = timestamp;",
        "  }",
    ]


def render_thunk_function(kernel: dict, site: dict) -> tuple[str, dict]:
    helper_abi = validate_helper_abi_entry(site, entry_kind="planned site")
    contract = str(site.get("contract", ""))
    when = str(site.get("when", ""))
    if contract not in CONTRACT_EVENT_ARGUMENTS:
        raise SystemExit(
            f"generate_binary_probe_thunks.py does not yet support contract {contract!r}"
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

    call_arguments = build_site_call_arguments(contract, capture_fields, capture_bindings)
    call_layout = layout_call_arguments(call_arguments)
    parameter_lines = []
    for index, argument in enumerate(call_arguments):
        suffix = "," if index != len(call_arguments) - 1 else ""
        parameter_lines.append(f"    {argument['c_type']} {argument['name']}{suffix}")

    lines = [
        f"extern \"C\" __device__ __attribute__((used)) void {thunk_name}(",
        *parameter_lines,
        ") {",
        *render_runtime_init_lines(),
        *render_site_snapshot_capture_lines(kernel, site),
        *render_entry_snapshot_capture_lines(kernel, when),
        *render_dh_builtin_capture_lines(when),
        *render_site_event_locals(kernel, contract, when),
        *render_site_event_unpack_lines(contract),
        f"  {captures_type} captures{{}};",
    ]
    for field in capture_fields:
        field_name = sanitize_identifier(str(field.get("name", "value")))
        argument_name = field_argument_name(field)
        field_type = cpp_type_for_field(field)
        lines.append(f"  captures.{field_name} = static_cast<{field_type}>({argument_name});")
    forward_arguments = ", ".join(["&runtime", "&captures", *surrogate_forward_arguments(contract)])
    lines.append(f"  {surrogate}({forward_arguments});")
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
        "binary_event_abi": (
            "memory_op_compact_v1"
            if contract == "memory_op_v1"
            else "direct"
        ),
        "helper_context": site.get("helper_context", {}),
        "helper_abi": helper_abi,
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
    seen_thunks: set[str] = set()
    for kernel in plan.get("kernels", []):
        if not isinstance(kernel, dict):
            continue
        for site in kernel.get("planned_sites", []):
            if not isinstance(site, dict):
                continue
            block, entry = render_thunk_function(kernel, site)
            thunk_name = str(entry.get("thunk", ""))
            if thunk_name in seen_thunks:
                continue
            seen_thunks.add(thunk_name)
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
        "#include <hip/hip_runtime.h>",
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
