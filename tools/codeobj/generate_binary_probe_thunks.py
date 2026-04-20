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


def render_site_event_locals(contract: str, when: str) -> list[str]:
    if contract != "kernel_lifecycle_v1":
        return []
    if when == "kernel_entry":
        return [
            "  if (!(blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 &&",
            "        threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0 &&",
            "        __omniprobe_lane_id == 0)) {",
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
        "  const uint32_t __omniprobe_event_workgroup_y = static_cast<uint32_t>(blockIdx.y);",
        "  const uint32_t __omniprobe_event_workgroup_z = static_cast<uint32_t>(blockIdx.z);",
        "  const uint32_t __omniprobe_event_thread_x = static_cast<uint32_t>(threadIdx.x);",
        "  const uint32_t __omniprobe_event_thread_y = static_cast<uint32_t>(threadIdx.y);",
        "  const uint32_t __omniprobe_event_thread_z = static_cast<uint32_t>(threadIdx.z);",
        "  const uint32_t __omniprobe_event_block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "  const uint32_t __omniprobe_event_block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "  const uint32_t __omniprobe_event_block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "  const uint32_t __omniprobe_event_lane_id = static_cast<uint32_t>(__lane_id());",
        "  const uint32_t __omniprobe_event_wavefront_size = static_cast<uint32_t>(warpSize);",
        "  const uint32_t __omniprobe_event_linear_tid = static_cast<uint32_t>(",
        "      threadIdx.x + blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z));",
        "  const uint32_t __omniprobe_event_wave_id =",
        "      __omniprobe_event_wavefront_size == 0",
        "          ? 0",
        "          : (__omniprobe_event_linear_tid / __omniprobe_event_wavefront_size);",
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


def render_dh_builtin_capture_lines(when: str) -> list[str]:
    return [
        "  dh_comms::builtin_snapshot_t __omniprobe_dh_builtins{};",
        "  const auto *__omniprobe_dispatch_uniform = runtime.dispatch_uniform;",
        "  const bool __omniprobe_has_grid_dim = __omniprobe_dispatch_uniform != nullptr &&",
        "      ((__omniprobe_dispatch_uniform->valid_mask & dispatch_uniform_valid_grid_dim) != 0);",
        "  const bool __omniprobe_has_block_dim = __omniprobe_dispatch_uniform != nullptr &&",
        "      ((__omniprobe_dispatch_uniform->valid_mask & dispatch_uniform_valid_block_dim) != 0);",
        "  __omniprobe_dh_builtins.grid_dim_x = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_x",
        "      : static_cast<uint32_t>(gridDim.x);",
        "  __omniprobe_dh_builtins.grid_dim_y = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_y",
        "      : static_cast<uint32_t>(gridDim.y);",
        "  __omniprobe_dh_builtins.grid_dim_z = __omniprobe_has_grid_dim",
        "      ? __omniprobe_dispatch_uniform->grid_dim_z",
        "      : static_cast<uint32_t>(gridDim.z);",
        "  const uint32_t __omniprobe_builtin_block_dim_x = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_x",
        "      : static_cast<uint32_t>(blockDim.x);",
        "  const uint32_t __omniprobe_builtin_block_dim_y = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_y",
        "      : static_cast<uint32_t>(blockDim.y);",
        "  const uint32_t __omniprobe_builtin_block_dim_z = __omniprobe_has_block_dim",
        "      ? __omniprobe_dispatch_uniform->block_dim_z",
        "      : static_cast<uint32_t>(blockDim.z);",
        "  __omniprobe_dh_builtins.block_dim_x = __omniprobe_builtin_block_dim_x;",
        "  __omniprobe_dh_builtins.block_dim_y = __omniprobe_builtin_block_dim_y;",
        "  __omniprobe_dh_builtins.block_dim_z = __omniprobe_builtin_block_dim_z;",
        "  __omniprobe_dh_builtins.block_idx_x = static_cast<uint32_t>(blockIdx.x);",
        "  __omniprobe_dh_builtins.block_idx_y = static_cast<uint32_t>(blockIdx.y);",
        "  __omniprobe_dh_builtins.block_idx_z = static_cast<uint32_t>(blockIdx.z);",
        "  const uint32_t __omniprobe_builtin_thread_idx_x = static_cast<uint32_t>(threadIdx.x);",
        "  const uint32_t __omniprobe_builtin_thread_idx_y = static_cast<uint32_t>(threadIdx.y);",
        "  const uint32_t __omniprobe_builtin_thread_idx_z = static_cast<uint32_t>(threadIdx.z);",
        "  __omniprobe_dh_builtins.thread_idx_x = __omniprobe_builtin_thread_idx_x;",
        "  __omniprobe_dh_builtins.thread_idx_y = __omniprobe_builtin_thread_idx_y;",
        "  __omniprobe_dh_builtins.thread_idx_z = __omniprobe_builtin_thread_idx_z;",
        "  __omniprobe_dh_builtins.lane_id = static_cast<uint32_t>(__lane_id());",
        "  __omniprobe_dh_builtins.wavefront_size = static_cast<uint32_t>(warpSize);",
        "  const uint32_t __omniprobe_builtin_linear_tid =",
        "      __omniprobe_builtin_thread_idx_x +",
        "      __omniprobe_builtin_block_dim_x *",
        "          (__omniprobe_builtin_thread_idx_y +",
        "           __omniprobe_builtin_block_dim_y * __omniprobe_builtin_thread_idx_z);",
        "  __omniprobe_dh_builtins.wave_num = __omniprobe_dh_builtins.wavefront_size == 0",
        "      ? 0",
        "      : (__omniprobe_builtin_linear_tid / __omniprobe_dh_builtins.wavefront_size);",
        "  __omniprobe_dh_builtins.exec = __builtin_amdgcn_read_exec();",
        "  __omniprobe_dh_builtins.xcc_id = 0;",
        "#if defined(__gfx940__) || defined(__gfx941__) || defined(__gfx942__)",
        "  uint32_t __omniprobe_builtin_xcc_reg = 0;",
        '  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_XCC_ID)" : "=s"(__omniprobe_builtin_xcc_reg));',
        "  __omniprobe_dh_builtins.xcc_id = static_cast<uint16_t>(__omniprobe_builtin_xcc_reg & 0xf);",
        "#endif",
        "  uint32_t __omniprobe_builtin_hw_id_reg = 0;",
        '  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_HW_ID)" : "=s"(__omniprobe_builtin_hw_id_reg));',
        "  __omniprobe_dh_builtins.hw_id = __omniprobe_builtin_hw_id_reg;",
        "  __omniprobe_dh_builtins.se_id = static_cast<uint16_t>((__omniprobe_builtin_hw_id_reg >> 13) & 0x7);",
        "  __omniprobe_dh_builtins.cu_id = static_cast<uint16_t>((__omniprobe_builtin_hw_id_reg >> 8) & 0xf);",
        "  __omniprobe_dh_builtins.arch = dh_comms::detect_gcn_arch();",
        "  runtime.dh_builtins = &__omniprobe_dh_builtins;",
    ]

def render_entry_snapshot_capture_lines(when: str) -> list[str]:
    if when != "kernel_entry":
        return []
    return [
        "  auto *entry_snapshot = const_cast<entry_snapshot_v1 *>(runtime.entry_snapshot);",
        "  if (entry_snapshot == nullptr) {",
        "    return;",
        "  }",
        "  const uint32_t __omniprobe_lane_id = static_cast<uint32_t>(__lane_id());",
        "  if (blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 &&",
        "      threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0 &&",
        "      __omniprobe_lane_id == 0) {",
        "    entry_snapshot->workgroup_x = static_cast<uint32_t>(blockIdx.x);",
        "    entry_snapshot->workgroup_y = static_cast<uint32_t>(blockIdx.y);",
        "    entry_snapshot->workgroup_z = static_cast<uint32_t>(blockIdx.z);",
        "    entry_snapshot->thread_x = static_cast<uint32_t>(threadIdx.x);",
        "    entry_snapshot->thread_y = static_cast<uint32_t>(threadIdx.y);",
        "    entry_snapshot->thread_z = static_cast<uint32_t>(threadIdx.z);",
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
        *render_dh_builtin_capture_lines(when),
        *render_entry_snapshot_capture_lines(when),
        *render_site_event_locals(contract, when),
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
