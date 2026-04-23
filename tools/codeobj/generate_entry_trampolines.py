#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path

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

ABI_SENSITIVE_RSRC2_BOOL_FIELDS = (
    "enable_sgpr_workgroup_id_x",
    "enable_sgpr_workgroup_id_y",
    "enable_sgpr_workgroup_id_z",
    "enable_sgpr_workgroup_info",
)
ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS = (
    "enable_sgpr_dispatch_ptr",
    "enable_sgpr_queue_ptr",
    "enable_sgpr_dispatch_id",
)

SUPPORTED_SOURCE_KERNEL_MODELS = {
    "mlk": {
        "model": "mlk-linear-index-store-v1",
        "body_data_param": "data",
        "body_size_param": "size",
        "body_pointee_type": "int",
        "body_value_expr": "static_cast<int>(idx)",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate compiler-owned entry-trampoline HIP source from an "
            "Omniprobe binary probe plan and probe bundle manifest."
        )
    )
    parser.add_argument("plan", help="Planner JSON emitted by plan_probe_instrumentation.py")
    parser.add_argument(
        "--probe-bundle",
        required=True,
        help="Generated probe bundle JSON emitted by prepare_probe_bundle.py",
    )
    parser.add_argument("--output", required=True, help="Path for generated trampoline HIP source")
    parser.add_argument(
        "--source-manifest",
        default=None,
        help="Optional original code-object manifest used to declare the intended original-body handoff contract",
    )
    parser.add_argument(
        "--manifest-output",
        default=None,
        help="Optional JSON manifest describing generated trampoline kernels",
    )
    parser.add_argument(
        "--body-template",
        choices=("none", "linear-index-store", "noinline-linear-index-store", "source-kernel-model-v1"),
        default="linear-index-store",
        help="Prototype compiler-owned kernel body template to append after entry instrumentation",
    )
    parser.add_argument(
        "--body-data-param",
        default="data",
        help="Parameter name used as the output pointer for the linear-index-store prototype body",
    )
    parser.add_argument(
        "--body-size-param",
        default="size",
        help="Parameter name used as the element count for the linear-index-store prototype body",
    )
    parser.add_argument(
        "--body-pointee-type",
        default="int",
        help="Pointee type used by the linear-index-store prototype body",
    )
    parser.add_argument(
        "--body-value-expr",
        default="static_cast<int>(idx)",
        help="Value expression assigned by the linear-index-store prototype body",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def descriptor_field_value(descriptor: dict, section: str, field: str) -> int:
    section_obj = descriptor.get(section, {})
    if not isinstance(section_obj, dict):
        return 0
    return int(section_obj.get(field, 0) or 0)


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


def include_path(output_path: Path, target_path: Path) -> str:
    return os.path.relpath(target_path, output_path.parent).replace(os.sep, "/")


def selected_entry_sites(kernel: dict) -> list[dict]:
    selected = []
    for site in kernel.get("planned_sites", []):
        if str(site.get("status", "")) != "planned":
            continue
        if str(site.get("when", "")) != "kernel_entry":
            continue
        if str(site.get("contract", "")) != "kernel_lifecycle_v1":
            continue
        selected.append(site)
    return selected


def find_surrogate_entry(probe_manifest: dict, *, probe_id: str, surrogate: str) -> dict:
    matches = []
    for entry in probe_manifest.get("surrogates", []):
        if str(entry.get("probe_id", "")) == probe_id and str(entry.get("surrogate", "")) == surrogate:
            matches.append(entry)
    if not matches:
        raise SystemExit(
            f"probe manifest does not contain surrogate {surrogate!r} for probe_id {probe_id!r}"
        )
    if len(matches) != 1:
        raise SystemExit(
            f"probe manifest contains multiple entries for surrogate {surrogate!r} and probe_id {probe_id!r}"
        )
    return matches[0]


def find_source_descriptor(source_manifest: dict | None, kernel_name: str) -> dict | None:
    if not isinstance(source_manifest, dict):
        return None
    for descriptor in source_manifest.get("kernels", {}).get("descriptors", []):
        if not isinstance(descriptor, dict):
            continue
        if descriptor.get("kernel_name") == kernel_name or descriptor.get("name") == f"{kernel_name}.kd":
            return descriptor
    return None


def find_source_metadata(source_manifest: dict | None, kernel_name: str) -> dict | None:
    if not isinstance(source_manifest, dict):
        return None
    for kernel in source_manifest.get("kernels", {}).get("metadata", {}).get("kernels", []):
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == kernel_name or kernel.get("symbol") == f"{kernel_name}.kd":
            return kernel
    return None


def kernel_parameters(site: dict) -> list[dict]:
    capture_fields = site.get("capture_layout", {}).get("struct_fields", [])
    capture_bindings = site.get("capture_bindings", [])
    if len(capture_fields) != len(capture_bindings):
        raise SystemExit(
            f"capture binding mismatch: {len(capture_fields)} fields vs {len(capture_bindings)} bindings"
        )

    parameters: list[dict] = []
    seen_names: set[str] = set()
    for index, (field, binding) in enumerate(zip(capture_fields, capture_bindings)):
        requested_name = str(binding.get("kernel_arg_name") or field.get("name") or f"arg{index}")
        parameter_name = sanitize_identifier(requested_name)
        if parameter_name in seen_names:
            parameter_name = f"{parameter_name}_{index}"
        seen_names.add(parameter_name)
        parameters.append(
            {
                "name": parameter_name,
                "c_type": cpp_type_for_field(field),
                "field_name": sanitize_identifier(str(field.get("name") or parameter_name)),
                "kernel_arg_offset": int(binding.get("kernel_arg_offset", 0) or 0),
            }
        )
    return parameters


def build_declared_body_handoff_contract(
    *,
    kernel: dict,
    parameters: list[dict],
    source_manifest: dict | None,
    source_kernel_model: dict | None = None,
) -> dict | None:
    source_kernel = str(kernel.get("source_kernel", "") or "")
    if not source_kernel:
        return None

    source_descriptor = find_source_descriptor(source_manifest, source_kernel)
    source_metadata = find_source_metadata(source_manifest, source_kernel)
    if source_descriptor is None and source_metadata is None:
        return None

    kernarg_size = 0
    if isinstance(source_descriptor, dict):
        kernarg_size = int(source_descriptor.get("kernarg_size", 0) or 0)
    if not kernarg_size and isinstance(source_metadata, dict):
        kernarg_size = int(source_metadata.get("kernarg_segment_size", 0) or 0)

    contract = {
        "original_kernel": source_kernel,
        "original_symbol": kernel.get("source_symbol")
        or (source_metadata.get("symbol") if isinstance(source_metadata, dict) else None)
        or (f"{source_kernel}.kd"),
        "kernarg_size": kernarg_size,
        "user_sgpr_count": descriptor_field_value(
            source_descriptor or {}, "compute_pgm_rsrc2", "user_sgpr_count"
        ),
        "wavefront_size32": descriptor_field_value(
            source_descriptor or {}, "kernel_code_properties", "enable_wavefront_size32"
        ),
        "body_model": source_kernel_model.get("model") if isinstance(source_kernel_model, dict) else None,
        "entry_abi": {
            "compute_pgm_rsrc2": {
                **{
                    field: descriptor_field_value(source_descriptor or {}, "compute_pgm_rsrc2", field)
                    for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS
                },
                "enable_vgpr_workitem_id": descriptor_field_value(
                    source_descriptor or {}, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"
                ),
            },
            "kernel_code_properties": {
                **{
                    field: descriptor_field_value(
                        source_descriptor or {}, "kernel_code_properties", field
                    )
                    for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS
                }
            },
        },
        "captured_parameters": [
            {
                "name": entry["name"],
                "field_name": entry["field_name"],
                "kernel_arg_offset": entry["kernel_arg_offset"],
                "c_type": entry["c_type"],
            }
            for entry in parameters
        ],
    }
    return contract


def render_body_lines(
    *,
    body_template: str,
    parameters: list[dict],
    body_data_param: str,
    body_size_param: str,
    body_pointee_type: str,
    body_value_expr: str,
) -> list[str]:
    if body_template == "none":
        return []
    if body_template not in {
        "linear-index-store",
        "noinline-linear-index-store",
        "source-kernel-model-v1",
    }:
        raise SystemExit(f"unsupported body template {body_template!r}")

    param_names = {entry["name"] for entry in parameters}
    if body_data_param not in param_names:
        raise SystemExit(
            f"body-data-param {body_data_param!r} is not present in generated parameters {sorted(param_names)}"
        )
    if body_size_param not in param_names:
        raise SystemExit(
            f"body-size-param {body_size_param!r} is not present in generated parameters {sorted(param_names)}"
        )

    return [
        f"  auto *body_data = reinterpret_cast<{body_pointee_type} *>(static_cast<uintptr_t>({body_data_param}));",
        f"  const size_t body_size = static_cast<size_t>({body_size_param});",
        "  const size_t idx = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;",
        "  if (body_data != nullptr && idx < body_size) {",
        f"    body_data[idx] = {body_value_expr};",
        "  }",
    ]


def render_body_function(
    *,
    body_template: str,
    trampoline_name: str,
    source_kernel: str,
    parameters: list[dict],
    body_data_param: str,
    body_size_param: str,
    body_pointee_type: str,
    body_value_expr: str,
) -> tuple[list[str], str | None, dict | None, str | None]:
    if body_template not in {"noinline-linear-index-store", "source-kernel-model-v1"}:
        return [], None, None, None

    model_record = None
    handoff_struct_name = None
    if body_template == "source-kernel-model-v1":
        model_record = SUPPORTED_SOURCE_KERNEL_MODELS.get(source_kernel)
        if model_record is None:
            supported = ", ".join(sorted(SUPPORTED_SOURCE_KERNEL_MODELS))
            raise SystemExit(
                f"body-template 'source-kernel-model-v1' does not support source kernel {source_kernel!r}; "
                f"supported kernels: {supported}"
            )
        body_data_param = sanitize_identifier(str(model_record["body_data_param"]))
        body_size_param = sanitize_identifier(str(model_record["body_size_param"]))
        body_pointee_type = str(model_record["body_pointee_type"])
        body_value_expr = str(model_record["body_value_expr"])
        body_function_name = (
            f"__omniprobe_source_model_body_{sanitize_identifier(source_kernel)}_v1"
        )
        handoff_struct_name = f"__omniprobe_body_handoff_{sanitize_identifier(source_kernel)}_v1"
    else:
        body_function_name = f"__omniprobe_body_{sanitize_identifier(trampoline_name)}"
    parameter_lines = [f"    {entry['c_type']} {entry['name']}," for entry in parameters]
    if parameter_lines:
        parameter_lines[-1] = parameter_lines[-1].rstrip(",")
    body_lines = render_body_lines(
        body_template=body_template,
        parameters=parameters,
        body_data_param=body_data_param,
        body_size_param=body_size_param,
        body_pointee_type=body_pointee_type,
        body_value_expr=body_value_expr,
    )
    if handoff_struct_name:
        lines = [
            f"struct {handoff_struct_name} {{",
            "  runtime_ctx *runtime;",
            "  const entry_snapshot_v1 *entry_snapshot;",
            "  const dispatch_uniform_snapshot_v1 *dispatch_uniform;",
        ]
        for entry in parameters:
            lines.append(f"  {entry['c_type']} {entry['name']};")
        lines.extend(
            [
                "};",
                "",
                f"__device__ __noinline__ void {body_function_name}(const {handoff_struct_name} *handoff) {{",
                "  if (handoff == nullptr) {",
                "    return;",
                "  }",
                f"  const auto {body_data_param} = handoff->{body_data_param};",
                f"  const auto {body_size_param} = handoff->{body_size_param};",
                *body_lines,
                "}",
                "",
            ]
        )
    else:
        lines = [
            f"__device__ __noinline__ void {body_function_name}(",
            *parameter_lines,
            ") {",
            *body_lines,
            "}",
            "",
        ]
    return lines, body_function_name, model_record, handoff_struct_name


def render_trampoline_kernel(
    *,
    kernel: dict,
    site: dict,
    surrogate_entry: dict,
    namespace: str,
    body_template: str,
    body_data_param: str,
    body_size_param: str,
    body_pointee_type: str,
    body_value_expr: str,
    source_manifest: dict | None,
) -> tuple[list[str], dict]:
    parameters = kernel_parameters(site)
    source_kernel = str(kernel.get("source_kernel", "kernel") or "kernel")
    trampoline_name = f"__omniprobe_trampoline_{sanitize_identifier(source_kernel)}"
    captures_type = str(site.get("captures_type", ""))
    surrogate_name = str(site.get("surrogate", ""))
    if not captures_type or not surrogate_name:
        raise SystemExit("entry trampoline generation requires captures_type and surrogate")

    parameter_lines = [f"    {entry['c_type']} {entry['name']}," for entry in parameters]
    parameter_lines.append("    runtime_storage_v2 *hidden_ctx) {")

    capture_lines = [f"  {namespace}::{captures_type} captures{{}};"]
    for entry in parameters:
        capture_lines.append(f"  captures.{entry['field_name']} = {entry['name']};")

    snapshot_arg_lines = [
        "      snapshot->timestamp,",
        "      snapshot->workgroup_x,",
        "      snapshot->workgroup_y,",
        "      snapshot->workgroup_z,",
        "      snapshot->thread_x,",
        "      snapshot->thread_y,",
        "      snapshot->thread_z,",
        "      snapshot->block_dim_x,",
        "      snapshot->block_dim_y,",
        "      snapshot->block_dim_z,",
        "      snapshot->lane_id,",
        "      snapshot->wave_id,",
        "      snapshot->wavefront_size,",
        "      snapshot->hw_id,",
        "      snapshot->exec_mask);",
    ]
    body_function_lines, body_function_name, source_kernel_model, handoff_struct_name = render_body_function(
        body_template=body_template,
        trampoline_name=trampoline_name,
        source_kernel=source_kernel,
        parameters=parameters,
        body_data_param=body_data_param,
        body_size_param=body_size_param,
        body_pointee_type=body_pointee_type,
        body_value_expr=body_value_expr,
    )
    declared_body_handoff_contract = build_declared_body_handoff_contract(
        kernel=kernel,
        parameters=parameters,
        source_manifest=source_manifest,
        source_kernel_model=source_kernel_model,
    )

    lines = [
        *body_function_lines,
        f"extern \"C\" __global__ void {trampoline_name}(",
        *parameter_lines,
        "  runtime_ctx runtime{};",
        "  site_snapshot_v1 site_snapshot{};",
        "  runtime.raw_hidden_ctx = hidden_ctx;",
        "  if (hidden_ctx != nullptr) {",
        "    runtime.dh = hidden_ctx->dh;",
        "    runtime.config_blob = hidden_ctx->config_blob;",
        "    runtime.state_blob = hidden_ctx->state_blob;",
        "    runtime.dispatch_id = hidden_ctx->dispatch_id;",
        "    runtime.entry_snapshot = &hidden_ctx->entry_snapshot;",
        "    runtime.dispatch_uniform = &hidden_ctx->dispatch_uniform;",
        "    runtime.dispatch_private = hidden_ctx->dispatch_private;",
        "    runtime.abi_version = hidden_ctx->abi_version;",
        "    runtime.flags = hidden_ctx->flags;",
        "  }",
        "  __omniprobe_capture_site_snapshot(site_snapshot);",
        "  runtime.site_snapshot = &site_snapshot;",
        "",
        *capture_lines,
        "",
        "  if (__omniprobe_is_dispatch_origin()) {",
        "    __omniprobe_capture_dispatch_uniform(runtime);",
        "    __omniprobe_capture_entry_snapshot(runtime);",
        "    dh_comms::builtin_snapshot_t dh_builtins = __omniprobe_make_dh_builtins(runtime);",
        "    runtime.dh_builtins = &dh_builtins;",
        "    const auto *snapshot = runtime.entry_snapshot;",
        "    if (snapshot != nullptr) {",
        f"      {namespace}::{surrogate_name}(",
        "          &runtime,",
        "          &captures,",
        *snapshot_arg_lines,
        "    }",
        "  }",
    ]
    body_lines = render_body_lines(
        body_template=body_template,
        parameters=parameters,
        body_data_param=body_data_param,
        body_size_param=body_size_param,
        body_pointee_type=body_pointee_type,
        body_value_expr=body_value_expr,
    )
    if body_lines:
        lines.append("")
        if body_function_name:
            if handoff_struct_name:
                lines.append(f"  {handoff_struct_name} body_handoff{{}};")
                lines.append("  body_handoff.runtime = &runtime;")
                lines.append("  body_handoff.entry_snapshot = runtime.entry_snapshot;")
                lines.append("  body_handoff.dispatch_uniform = runtime.dispatch_uniform;")
                for entry in parameters:
                    lines.append(f"  body_handoff.{entry['name']} = {entry['name']};")
                lines.append(f"  {body_function_name}(&body_handoff);")
            else:
                call_args = ", ".join(entry["name"] for entry in parameters)
                lines.append(f"  {body_function_name}({call_args});")
        else:
            lines.extend(body_lines)
    lines.append("}")

    manifest_entry = {
        "source_kernel": kernel.get("source_kernel"),
        "source_symbol": kernel.get("source_symbol"),
        "trampoline_kernel": trampoline_name,
        "probe_id": site.get("probe_id"),
        "surrogate": surrogate_name,
        "captures_type": captures_type,
        "prototype_body": body_template,
        "prototype_body_strategy": (
            (
                "source-kernel-model-device-call"
                if body_template == "source-kernel-model-v1"
                else ("noinline-device-call" if body_function_name else ("inline" if body_lines else "none"))
            )
        ),
        "prototype_body_function": body_function_name,
        "prototype_body_origin": (
            "source-kernel-model" if body_template == "source-kernel-model-v1" else "prototype-template"
        ),
        "prototype_body_model": (
            source_kernel_model.get("model") if isinstance(source_kernel_model, dict) else None
        ),
        "prototype_body_handoff_struct": handoff_struct_name,
        "prototype_body_handoff_transport": "stack-struct-pointer" if handoff_struct_name else None,
        "declared_body_handoff_contract": declared_body_handoff_contract,
        "parameters": parameters,
        "helper": surrogate_entry.get("helper"),
    }
    return lines, manifest_entry


def main() -> int:
    args = parse_args()
    plan_path = Path(args.plan).resolve()
    bundle_path = Path(args.probe_bundle).resolve()
    output_path = Path(args.output).resolve()
    manifest_path = manifest_output_path(args.manifest_output, output_path)

    plan = load_json(plan_path)
    bundle = load_json(bundle_path)
    source_manifest = load_json(Path(args.source_manifest).resolve()) if args.source_manifest else None

    manifest_value = bundle.get("manifest")
    surrogate_value = bundle.get("surrogate_source")
    helper_value = bundle.get("helper_source")
    if not isinstance(manifest_value, str) or not manifest_value:
        raise SystemExit(f"probe bundle {bundle_path} does not contain a manifest path")
    if not isinstance(surrogate_value, str) or not surrogate_value:
        raise SystemExit(f"probe bundle {bundle_path} does not contain a surrogate source path")
    if not isinstance(helper_value, str) or not helper_value:
        raise SystemExit(f"probe bundle {bundle_path} does not contain a helper source path")

    probe_manifest_path = Path(manifest_value).resolve()
    surrogate_source_path = Path(surrogate_value).resolve()
    helper_source_path = Path(helper_value).resolve()
    probe_manifest = load_json(probe_manifest_path)

    helpers = probe_manifest.get("helpers", {}) if isinstance(probe_manifest.get("helpers"), dict) else {}
    namespace = str(helpers.get("namespace") or "omniprobe_user")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    helper_include = include_path(output_path, helper_source_path)
    surrogate_include = include_path(output_path, surrogate_source_path)

    generated_kernels: list[dict] = []
    rendered_kernels: list[str] = []
    for kernel in plan.get("kernels", []):
        sites = selected_entry_sites(kernel)
        if not sites:
            continue
        if len(sites) != 1:
            raise SystemExit(
                f"entry trampoline prototype expects exactly one kernel_entry kernel_lifecycle_v1 site per kernel; "
                f"kernel {kernel.get('source_kernel')!r} has {len(sites)}"
            )
        site = sites[0]
        surrogate_entry = find_surrogate_entry(
            probe_manifest,
            probe_id=str(site.get("probe_id", "")),
            surrogate=str(site.get("surrogate", "")),
        )
        lines, manifest_entry = render_trampoline_kernel(
            kernel=kernel,
            site=site,
            surrogate_entry=surrogate_entry,
            namespace=namespace,
            body_template=args.body_template,
            body_data_param=sanitize_identifier(args.body_data_param),
            body_size_param=sanitize_identifier(args.body_size_param),
            body_pointee_type=args.body_pointee_type,
            body_value_expr=args.body_value_expr,
            source_manifest=source_manifest,
        )
        rendered_kernels.append("\n".join(lines))
        generated_kernels.append(manifest_entry)

    if not generated_kernels:
        raise SystemExit(
            f"plan {plan_path} does not contain any planned kernel_entry kernel_lifecycle_v1 sites to trampoline"
        )

    source_lines = [
        "// Generated by tools/codeobj/generate_entry_trampolines.py",
        "#include <hip/hip_runtime.h>",
        "#include <stdint.h>",
        "",
        '#include "dh_comms_dev.h"',
        '#include "omniprobe_probe_abi_v1.h"',
        f'#include "{surrogate_include}"',
        f'#include "{helper_include}"',
        "",
        "using namespace omniprobe::probe_abi_v1;",
        "",
        "namespace {",
        "",
        "__device__ __forceinline__ bool __omniprobe_is_dispatch_origin() {",
        "  return blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 &&",
        "         threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0 &&",
        "         static_cast<uint32_t>(__lane_id()) == 0;",
        "}",
        "",
        "__device__ __forceinline__ uint32_t __omniprobe_wave_id() {",
        "  const uint32_t wavefront_size = static_cast<uint32_t>(warpSize);",
        "  if (wavefront_size == 0) {",
        "    return 0;",
        "  }",
        "  const uint32_t linear_tid = static_cast<uint32_t>(",
        "      threadIdx.x + blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z));",
        "  return linear_tid / wavefront_size;",
        "}",
        "",
        "__device__ __forceinline__ void __omniprobe_capture_dispatch_uniform(runtime_ctx &runtime) {",
        "  if (!__omniprobe_is_dispatch_origin()) {",
        "    return;",
        "  }",
        "  auto *uniform = const_cast<dispatch_uniform_snapshot_v1 *>(runtime.dispatch_uniform);",
        "  if (uniform == nullptr) {",
        "    return;",
        "  }",
        "  uniform->valid_mask = dispatch_uniform_valid_grid_dim | dispatch_uniform_valid_block_dim;",
        "  uniform->grid_dim_x = static_cast<uint32_t>(gridDim.x);",
        "  uniform->grid_dim_y = static_cast<uint32_t>(gridDim.y);",
        "  uniform->grid_dim_z = static_cast<uint32_t>(gridDim.z);",
        "  uniform->block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "  uniform->block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "  uniform->block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "}",
        "",
        "__device__ __forceinline__ void __omniprobe_capture_site_snapshot(site_snapshot_v1 &snapshot) {",
        "  snapshot.workgroup_x = static_cast<uint32_t>(blockIdx.x);",
        "  snapshot.workgroup_y = static_cast<uint32_t>(blockIdx.y);",
        "  snapshot.workgroup_z = static_cast<uint32_t>(blockIdx.z);",
        "  snapshot.thread_x = static_cast<uint32_t>(threadIdx.x);",
        "  snapshot.thread_y = static_cast<uint32_t>(threadIdx.y);",
        "  snapshot.thread_z = static_cast<uint32_t>(threadIdx.z);",
        "  snapshot.block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "  snapshot.block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "  snapshot.block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "  snapshot.lane_id = static_cast<uint32_t>(__lane_id());",
        "  snapshot.wave_id = __omniprobe_wave_id();",
        "  snapshot.wavefront_size = static_cast<uint32_t>(warpSize);",
        "  snapshot.hw_id = static_cast<uint32_t>(__smid());",
        "  snapshot.exec_mask = __builtin_amdgcn_read_exec();",
        "}",
        "",
        "__device__ __forceinline__ void __omniprobe_capture_entry_snapshot(runtime_ctx &runtime) {",
        "  if (!__omniprobe_is_dispatch_origin()) {",
        "    return;",
        "  }",
        "  auto *snapshot = const_cast<entry_snapshot_v1 *>(runtime.entry_snapshot);",
        "  if (snapshot == nullptr) {",
        "    return;",
        "  }",
        "  snapshot->workgroup_x = static_cast<uint32_t>(blockIdx.x);",
        "  snapshot->workgroup_y = static_cast<uint32_t>(blockIdx.y);",
        "  snapshot->workgroup_z = static_cast<uint32_t>(blockIdx.z);",
        "  snapshot->thread_x = static_cast<uint32_t>(threadIdx.x);",
        "  snapshot->thread_y = static_cast<uint32_t>(threadIdx.y);",
        "  snapshot->thread_z = static_cast<uint32_t>(threadIdx.z);",
        "  snapshot->block_dim_x = static_cast<uint32_t>(blockDim.x);",
        "  snapshot->block_dim_y = static_cast<uint32_t>(blockDim.y);",
        "  snapshot->block_dim_z = static_cast<uint32_t>(blockDim.z);",
        "  snapshot->lane_id = static_cast<uint32_t>(__lane_id());",
        "  snapshot->wave_id = __omniprobe_wave_id();",
        "  snapshot->wavefront_size = static_cast<uint32_t>(warpSize);",
        "  snapshot->hw_id = static_cast<uint32_t>(__smid());",
        "  snapshot->exec_mask = __builtin_amdgcn_read_exec();",
        "  snapshot->timestamp = clock64();",
        "}",
        "",
        "__device__ __forceinline__ dh_comms::builtin_snapshot_t __omniprobe_make_dh_builtins(const runtime_ctx &runtime) {",
        "  dh_comms::builtin_snapshot_t builtins{};",
        "  const auto *snapshot = runtime.site_snapshot;",
        "  const auto *uniform = runtime.dispatch_uniform;",
        "  const bool has_snapshot = snapshot != nullptr && snapshot->wavefront_size != 0;",
        "  const bool has_grid_dim = uniform != nullptr && ((uniform->valid_mask & dispatch_uniform_valid_grid_dim) != 0);",
        "  const bool has_block_dim = uniform != nullptr && ((uniform->valid_mask & dispatch_uniform_valid_block_dim) != 0);",
        "  builtins.grid_dim_x = has_grid_dim ? uniform->grid_dim_x : 0u;",
        "  builtins.grid_dim_y = has_grid_dim ? uniform->grid_dim_y : 0u;",
        "  builtins.grid_dim_z = has_grid_dim ? uniform->grid_dim_z : 0u;",
        "  builtins.block_dim_x = has_block_dim ? uniform->block_dim_x : (has_snapshot ? snapshot->block_dim_x : 0u);",
        "  builtins.block_dim_y = has_block_dim ? uniform->block_dim_y : (has_snapshot ? snapshot->block_dim_y : 0u);",
        "  builtins.block_dim_z = has_block_dim ? uniform->block_dim_z : (has_snapshot ? snapshot->block_dim_z : 0u);",
        "  builtins.block_idx_x = has_snapshot ? snapshot->workgroup_x : 0u;",
        "  builtins.block_idx_y = has_snapshot ? snapshot->workgroup_y : 0u;",
        "  builtins.block_idx_z = has_snapshot ? snapshot->workgroup_z : 0u;",
        "  builtins.thread_idx_x = has_snapshot ? snapshot->thread_x : 0u;",
        "  builtins.thread_idx_y = has_snapshot ? snapshot->thread_y : 0u;",
        "  builtins.thread_idx_z = has_snapshot ? snapshot->thread_z : 0u;",
        "  builtins.lane_id = has_snapshot ? snapshot->lane_id : 0u;",
        "  builtins.wavefront_size = has_snapshot ? snapshot->wavefront_size : 0u;",
        "  builtins.wave_num = has_snapshot ? snapshot->wave_id : 0u;",
        "  builtins.exec = has_snapshot ? snapshot->exec_mask : 0u;",
        "  builtins.xcc_id = 0;",
        "  const uint32_t hw_id = has_snapshot ? snapshot->hw_id : 0u;",
        "  builtins.hw_id = hw_id;",
        "  builtins.se_id = static_cast<uint16_t>((hw_id >> 13) & 0x7);",
        "  builtins.cu_id = static_cast<uint16_t>((hw_id >> 8) & 0xf);",
        "  builtins.arch = dh_comms::detect_gcn_arch();",
        "  return builtins;",
        "}",
        "",
        "} // namespace",
        "",
        *[f"{kernel_source}\n" for kernel_source in rendered_kernels],
    ]
    output_path.write_text("\n".join(source_lines), encoding="utf-8")

    manifest_payload = {
        "version": 1,
        "plan": str(plan_path),
        "probe_bundle": str(bundle_path),
        "probe_manifest": str(probe_manifest_path),
        "source_manifest": str(Path(args.source_manifest).resolve()) if args.source_manifest else None,
        "output": str(output_path),
        "body_template": args.body_template,
        "kernels": generated_kernels,
    }
    manifest_path.write_text(json.dumps(manifest_payload, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
