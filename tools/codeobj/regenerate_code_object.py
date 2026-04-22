#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import struct
import shutil
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

from code_object_model import CodeObjectModel
from common import get_hidden_abi_instrumented_name
from amdgpu_entry_abi import analyze_kernel_entry_abi
from emit_hidden_abi_metadata import (
    build_metadata_document,
    build_metadata_document_from_raw,
    build_metadata_object,
    build_metadata_object_with_inplace_update,
    build_metadata_document_with_inplace_update,
    clone_kernel_record,
    dedupe_kernel_records,
    kernel_identity,
    mutate_kernel_record_in_place,
    raw_kernel_blocks,
)
from msgpack_codec import packb
from plan_hidden_abi import build_kernel_plan
import rewrite_metadata_note as note_rewriter


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Regenerate an AMDGPU code object through Omniprobe's normalized "
            "code-object model. The current scope is a donor-free, single-kernel, "
            "no-op rebuild scaffold that reuses the existing inspect/disasm/rebuild "
            "primitives behind one orchestration entrypoint."
        )
    )
    parser.add_argument("input", help="Input AMDGPU code object")
    parser.add_argument("--output", required=True, help="Output code-object path")
    parser.add_argument(
        "--manifest",
        default=None,
        help="Optional existing manifest; generated from the input when omitted",
    )
    parser.add_argument(
        "--mode",
        default="exact",
        choices=("exact",),
        help="Current regeneration contract. Only exact no-op regeneration is supported today.",
    )
    parser.add_argument(
        "--kernel",
        default=None,
        help=(
            "Optional kernel name or symbol to target when the code object contains "
            "multiple primary kernel families."
        ),
    )
    parser.add_argument(
        "--report-output",
        default=None,
        help="Optional JSON report path",
    )
    parser.add_argument(
        "--keep-temp-dir",
        action="store_true",
        help="Keep intermediate manifest/IR/asm/object files for debugging",
    )
    parser.add_argument(
        "--add-hidden-abi-clone",
        action="store_true",
        help=(
            "Duplicate the primary kernel into a donor-free hidden-ABI clone "
            "entry during regeneration. The current implementation keeps the "
            "clone body identical to the source kernel and updates only clone-side "
            "name/descriptor/metadata ABI."
        ),
    )
    parser.add_argument(
        "--add-noop-clone",
        action="store_true",
        help=(
            "Duplicate the primary kernel into a donor-free same-ABI clone entry. "
            "This is the first true non-donor clone-insertion slice and keeps "
            "the clone body and kernarg ABI identical to the source kernel."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-proof",
        action="store_true",
        help=(
            "Fail-closed proof mode for retargeting a kernel entry to a tiny "
            "wrapper that immediately branches into the original machine-code "
            "body. Current support is intentionally narrow."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-hidden-handoff-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper proof by growing the exported kernel ABI "
            "with a wrapper-only hidden_omniprobe_ctx pointer and emitting a "
            "real wrapper-side scalar load from that slot before branching to "
            "the original body."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-kernarg-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper hidden-handoff proof by clobbering the "
            "original kernarg base pair and restoring it from "
            "hidden_omniprobe_ctx->original_kernarg_pointer before branching "
            "to the original body."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-workgroup-x-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper kernarg-restore proof by also clobbering "
            "workgroup_id_x and restoring it from hidden_omniprobe_ctx under a "
            "single-workgroup proof launch."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-workgroup-x-capture-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper kernarg-restore proof by capturing "
            "workgroup_id_x into hidden_omniprobe_ctx entry_snapshot storage "
            "before branching to the original body. Current validation is "
            "constrained to a single-workgroup launch."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-workgroup-xyz-capture-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper kernarg-restore proof by capturing "
            "workgroup_id_x/y/z into hidden_omniprobe_ctx entry_snapshot "
            "storage before branching to the original body. Current validation "
            "is constrained to a single-workgroup launch."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-workgroup-xyz-capture-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper kernarg-restore proof by capturing "
            "workgroup_id_x/y/z into hidden_omniprobe_ctx entry_snapshot "
            "storage, clobbering those SGPRs, restoring them from the captured "
            "snapshot fields, and then branching to the original body. Current "
            "validation is constrained to a single-workgroup launch."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-system-sgpr-capture-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper kernarg-restore proof by capturing all "
            "supported entry system SGPR roles (workgroup_id_x/y/z and "
            "private_segment_wave_offset) into hidden_omniprobe_ctx snapshot "
            "storage, clobbering them, restoring them from the captured "
            "snapshot fields, and then branching to the original body. "
            "Current validation is constrained to a single-wave, "
            "single-workgroup launch."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-workitem-vgpr-capture-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper proof by spilling the original entry "
            "workitem VGPR state into a grown private-segment tail, clobbering "
            "that state in the wrapper, restoring it from the private tail, "
            "and then branching to the original body. This is a fail-closed "
            "proof path for kernels whose bodies actually consume the entry "
            "workitem VGPR contract."
        ),
    )
    parser.add_argument(
        "--add-entry-wrapper-full-entry-abi-capture-restore-proof",
        action="store_true",
        help=(
            "Extend the entry-wrapper proof by preserving both the supported "
            "entry system SGPR roles and the entry workitem VGPR state before "
            "branching to the original body. This combines hidden-handoff "
            "entry snapshot restore for workgroup/private state with "
            "private-tail spill/restore for lane-variant workitem VGPRs."
        ),
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python interpreter to use for helper tools",
    )
    parser.add_argument(
        "--llvm-readelf",
        default=None,
        help="Path to llvm-readelf for manifest generation",
    )
    parser.add_argument(
        "--llvm-objdump",
        default=None,
        help="Path to llvm-objdump for IR generation",
    )
    parser.add_argument(
        "--llvm-mc",
        default=None,
        help="Path to llvm-mc for rebuild",
    )
    parser.add_argument(
        "--ld-lld",
        default=None,
        help="Path to ld.lld for rebuild",
    )
    parser.add_argument(
        "--probe-plan",
        default=None,
        help="Optional binary probe plan JSON for clone-body mutation",
    )
    parser.add_argument(
        "--thunk-manifest",
        default=None,
        help="Optional thunk manifest JSON emitted by generate_binary_probe_thunks.py",
    )
    parser.add_argument(
        "--probe-support-object",
        default=None,
        help="Optional precompiled binary probe support object to link into the rebuilt code object",
    )
    parser.add_argument(
        "--hipcc",
        default=None,
        help="Path to hipcc used when compiling binary probe support objects",
    )
    parser.add_argument(
        "--clang-offload-bundler",
        default=None,
        help="Path to clang-offload-bundler used when compiling binary probe support objects",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def reject_unsupported_binary_probe_sites(probe_plan: dict, *, kernel_name: str) -> None:
    kernels = probe_plan.get("kernels", [])
    if not isinstance(kernels, list):
        return
    kernel_plan = next(
        (
            entry
            for entry in kernels
            if isinstance(entry, dict)
            and kernel_name in {
                str(entry.get("source_kernel", "")),
                str(entry.get("clone_kernel", "")),
                str(entry.get("source_symbol", "")),
            }
        ),
        None,
    )
    if not isinstance(kernel_plan, dict):
        return
    for site in kernel_plan.get("planned_sites", []):
        if not isinstance(site, dict):
            continue
        if str(site.get("contract", "")) != "kernel_lifecycle_v1":
            continue
        when = str(site.get("when", ""))
        event_usage = str(site.get("event_usage", "dispatch_origin") or "dispatch_origin")
        if when == "kernel_entry":
            raise SystemExit(
                "donor-free binary rewrite does not support kernel_entry lifecycle helper execution; "
                "use the pass-plugin path or choose a supported binary insertion point such as kernel_exit"
            )
        if when == "kernel_exit" and event_usage != "none":
            raise SystemExit(
                "donor-free binary rewrite does not support kernel_exit lifecycle helpers that consume args.event; "
                "set inject.event_usage: none, use the pass-plugin path, or choose a captures-only binary helper"
            )


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def choose_kernel(model: CodeObjectModel, requested_kernel: str | None = None) -> tuple[str, int]:
    kernel_names = model.kernel_names()
    primary_kernel_names = model.primary_kernel_names()
    if requested_kernel:
        requested = str(requested_kernel)
        if requested in primary_kernel_names:
            return requested, len(primary_kernel_names)
        metadata_match = next(
            (
                name
                for name in primary_kernel_names
                if (model.metadata_by_kernel_name(name) or {}).get("symbol") == requested
            ),
            None,
        )
        if metadata_match is not None:
            return metadata_match, len(primary_kernel_names)
        raise SystemExit(
            "requested kernel {!r} was not found among primary kernel families: {}".format(
                requested, primary_kernel_names
            )
        )
    if len(primary_kernel_names) != 1:
        raise SystemExit(
            "regenerate_code_object.py currently supports only one primary "
            "non-Omniprobe kernel family; found "
            f"{len(primary_kernel_names)} primary kernels: {primary_kernel_names} "
            f"(all kernels: {kernel_names})"
        )
    return primary_kernel_names[0], len(primary_kernel_names)


def metadata_output_format(manifest: dict) -> str:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    return "msgpack" if isinstance(metadata.get("object"), dict) else "yaml"


def rename_function_ir(ir: dict, source_name: str, new_name: str) -> dict:
    source_function = next(
        (fn for fn in ir.get("functions", []) if fn.get("name") == source_name),
        None,
    )
    if source_function is None:
        raise SystemExit(f"IR function {source_name!r} not found")
    source_function["name"] = new_name
    for instruction in source_function.get("instructions", []):
        instruction.setdefault("source_address", instruction.get("address"))
        target = instruction.get("target")
        if isinstance(target, dict) and target.get("symbol") == source_name:
            target["symbol"] = new_name
    return source_function


def duplicate_function_ir(ir: dict, source_name: str, clone_name: str) -> None:
    source_function = next(
        (fn for fn in ir.get("functions", []) if fn.get("name") == source_name),
        None,
    )
    if source_function is None:
        raise SystemExit(f"IR function {source_name!r} not found")
    clone_function = deepcopy(source_function)
    clone_function["name"] = clone_name
    for instruction in clone_function.get("instructions", []):
        instruction.setdefault("source_address", instruction.get("address"))
        target = instruction.get("target")
        if isinstance(target, dict) and target.get("symbol") == source_name:
            target["symbol"] = clone_name
    ir.setdefault("functions", []).append(clone_function)


def duplicate_symbol(records: list[dict], source_name: str, clone_name: str) -> dict:
    source_symbol = next(
        (entry for entry in records if entry.get("name") == source_name),
        None,
    )
    if source_symbol is None:
        raise SystemExit(f"source symbol {source_name!r} not found")
    clone_symbol = deepcopy(source_symbol)
    clone_symbol["name"] = clone_name
    records.append(clone_symbol)
    return clone_symbol


def rename_symbol(records: list[dict], source_name: str, new_name: str) -> list[dict]:
    matches = [entry for entry in records if entry.get("name") == source_name]
    if not matches:
        raise SystemExit(f"source symbol {source_name!r} not found")
    for entry in matches:
        entry["name"] = new_name
    return matches


def remove_symbol(records: list[dict], name: str) -> list[dict]:
    removed = [entry for entry in records if entry.get("name") == name]
    records[:] = [entry for entry in records if entry.get("name") != name]
    return removed


def patch_descriptor_bytes_hex(bytes_hex: str, kernarg_size: int) -> str:
    payload = bytearray.fromhex(bytes_hex)
    struct.pack_into("<I", payload, 8, kernarg_size)
    return payload.hex()


def round_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        return value
    return ((value + alignment - 1) // alignment) * alignment


def granulated_sgpr_count(total_sgprs: int) -> int:
    return max(0, (round_up(max(1, total_sgprs), 8) // 8) - 1)


def granulated_vgpr_count(total_vgprs: int) -> int:
    return max(0, (round_up(max(1, total_vgprs), 8) // 8) - 1)


def update_descriptor_sgpr_footprint(descriptor: dict, total_sgprs: int) -> None:
    rsrc1 = descriptor.setdefault("compute_pgm_rsrc1", {})
    granulated = granulated_sgpr_count(total_sgprs)
    raw_value = int(rsrc1.get("raw_value", 0) or 0)
    raw_value &= ~(0xF << 6)
    raw_value |= (granulated & 0xF) << 6
    rsrc1["raw_value"] = raw_value
    rsrc1["granulated_wavefront_sgpr_count"] = granulated


def update_descriptor_vgpr_footprint(descriptor: dict, total_vgprs: int) -> None:
    rsrc1 = descriptor.setdefault("compute_pgm_rsrc1", {})
    granulated = granulated_vgpr_count(total_vgprs)
    raw_value = int(rsrc1.get("raw_value", 0) or 0)
    raw_value &= ~0x3F
    raw_value |= granulated & 0x3F
    rsrc1["raw_value"] = raw_value
    rsrc1["granulated_workitem_vgpr_count"] = granulated


def apply_binary_probe_saved_sgpr_policy(
    manifest: dict,
    *,
    clone_kernel: str,
    total_sgprs: int,
    refresh_rendered_metadata: bool = True,
) -> None:
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    clone_descriptor = next(
        (entry for entry in descriptors if entry.get("kernel_name") == clone_kernel),
        None,
    )
    if clone_descriptor is None:
        raise SystemExit(f"clone descriptor for {clone_kernel!r} not found")

    update_descriptor_sgpr_footprint(clone_descriptor, total_sgprs)

    metadata = manifest.get("kernels", {}).get("metadata", {})
    for kernel_record in metadata.get("kernels", []):
        if not isinstance(kernel_record, dict):
            continue
        if kernel_record.get("name") != clone_kernel:
            continue
        kernel_record["sgpr_count"] = total_sgprs
        break

    metadata_obj = metadata.get("object")
    if isinstance(metadata_obj, dict):
        for kernel_obj in metadata_obj.get("amdhsa.kernels", []):
            if not isinstance(kernel_obj, dict):
                continue
            if kernel_obj.get(".name") != clone_kernel:
                continue
            kernel_obj[".sgpr_count"] = total_sgprs
            break

    rendered = metadata.get("rendered") or metadata.get("raw")
    if refresh_rendered_metadata and rendered:
        metadata["rendered"] = build_metadata_document(
            manifest,
            selected_kernels=[],
            clones_only=False,
            pointer_size=8,
            alignment=8,
        )
        metadata["raw"] = metadata["rendered"]


def apply_binary_probe_vgpr_policy(
    manifest: dict,
    *,
    clone_kernel: str,
    total_vgprs: int,
    refresh_rendered_metadata: bool = True,
) -> None:
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    clone_descriptor = next(
        (entry for entry in descriptors if entry.get("kernel_name") == clone_kernel),
        None,
    )
    if clone_descriptor is None:
        raise SystemExit(f"clone descriptor for {clone_kernel!r} not found")

    update_descriptor_vgpr_footprint(clone_descriptor, total_vgprs)

    metadata = manifest.get("kernels", {}).get("metadata", {})
    for kernel_record in metadata.get("kernels", []):
        if not isinstance(kernel_record, dict):
            continue
        if kernel_record.get("name") != clone_kernel:
            continue
        kernel_record["vgpr_count"] = total_vgprs
        break

    metadata_obj = metadata.get("object")
    if isinstance(metadata_obj, dict):
        for kernel_obj in metadata_obj.get("amdhsa.kernels", []):
            if not isinstance(kernel_obj, dict):
                continue
            if kernel_obj.get(".name") != clone_kernel:
                continue
            kernel_obj[".vgpr_count"] = total_vgprs
            break

    rendered = metadata.get("rendered") or metadata.get("raw")
    if refresh_rendered_metadata and rendered:
        metadata["rendered"] = build_metadata_document(
            manifest,
            selected_kernels=[],
            clones_only=False,
            pointer_size=8,
            alignment=8,
        )
        metadata["raw"] = metadata["rendered"]


def apply_binary_probe_nonleaf_policy(
    manifest: dict,
    *,
    clone_kernel: str,
    private_segment_growth: int = 16,
    refresh_rendered_metadata: bool = True,
) -> None:
    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    clone_descriptor = next(
        (entry for entry in descriptors if entry.get("kernel_name") == clone_kernel),
        None,
    )
    if clone_descriptor is None:
        raise SystemExit(f"clone descriptor for {clone_kernel!r} not found")

    current_private = int(clone_descriptor.get("private_segment_fixed_size", 0) or 0)
    clone_descriptor["private_segment_fixed_size"] = current_private + private_segment_growth
    rsrc2 = clone_descriptor.setdefault("compute_pgm_rsrc2", {})
    rsrc2["enable_private_segment"] = 1
    rsrc2_raw_value = rsrc2.get("raw_value")
    if isinstance(rsrc2_raw_value, int):
        rsrc2["raw_value"] = rsrc2_raw_value | 0x1
    properties = clone_descriptor.setdefault("kernel_code_properties", {})
    properties["uses_dynamic_stack"] = 1
    raw_value = properties.get("raw_value")
    if isinstance(raw_value, int):
        properties["raw_value"] = raw_value | 0x800

    metadata = manifest.get("kernels", {}).get("metadata", {})
    for kernel_record in metadata.get("kernels", []):
        if not isinstance(kernel_record, dict):
            continue
        if kernel_record.get("name") != clone_kernel:
            continue
        kernel_record["private_segment_fixed_size"] = current_private + private_segment_growth
        break

    metadata_obj = metadata.get("object")
    if isinstance(metadata_obj, dict):
        for kernel_obj in metadata_obj.get("amdhsa.kernels", []):
            if not isinstance(kernel_obj, dict):
                continue
            if kernel_obj.get(".name") != clone_kernel:
                continue
            kernel_obj[".private_segment_fixed_size"] = current_private + private_segment_growth
            break

    rendered = metadata.get("rendered") or metadata.get("raw")
    if refresh_rendered_metadata and rendered:
        metadata["rendered"] = build_metadata_document(
            manifest,
            selected_kernels=[],
            clones_only=False,
            pointer_size=8,
            alignment=8,
        )
        metadata["raw"] = metadata["rendered"]


def add_hidden_abi_clone_intent(manifest: dict, ir: dict, model: CodeObjectModel, kernel_name: str) -> dict:
    kernel = model.metadata_by_kernel_name(kernel_name)
    if kernel is None:
        raise SystemExit(f"kernel metadata for {kernel_name!r} not found")

    plan = build_kernel_plan(kernel, pointer_size=8, alignment=8)
    clone_name = plan["hidden_abi_clone_name"]
    clone_descriptor_name = f"{clone_name}.kd"
    if model.metadata_by_kernel_name(clone_name) is not None:
        raise SystemExit(
            f"hidden-ABI clone target {clone_name!r} already exists in the source code object"
        )

    duplicate_function_ir(ir, kernel_name, clone_name)
    duplicate_symbol(manifest["functions"]["all_symbols"], kernel_name, clone_name)
    duplicate_symbol(manifest["kernels"]["function_symbols"], kernel_name, clone_name)
    duplicate_symbol(manifest["symbols"], kernel_name, clone_name)

    source_descriptor = model.descriptor_by_kernel_name(kernel_name)
    if source_descriptor is None:
        raise SystemExit(f"descriptor for kernel {kernel_name!r} not found")

    clone_descriptor = deepcopy(source_descriptor)
    clone_descriptor["name"] = clone_descriptor_name
    clone_descriptor["kernel_name"] = clone_name
    clone_descriptor["kernarg_size"] = plan["instrumented_kernarg_length"]
    clone_descriptor["bytes_hex"] = patch_descriptor_bytes_hex(
        str(source_descriptor.get("bytes_hex", "")),
        int(plan["instrumented_kernarg_length"]),
    )
    manifest["kernels"]["descriptors"].append(clone_descriptor)

    duplicate_symbol(
        manifest["kernels"]["descriptor_symbols"],
        str(source_descriptor.get("name")),
        clone_descriptor_name,
    )
    duplicate_symbol(
        manifest["symbols"],
        str(source_descriptor.get("name")),
        clone_descriptor_name,
    )

    metadata = manifest["kernels"]["metadata"]
    metadata["kernels"] = dedupe_kernel_records(
        [
            *metadata.get("kernels", []),
            clone_kernel_record(kernel, plan),
        ]
    )
    # The hidden-ABI path already changes the metadata contract, so regenerate
    # the YAML note from the normalized kernel list rather than trying to splice
    # raw text blocks and risking duplicate clone entries.
    metadata["rendered"] = build_metadata_document(
        manifest,
        selected_kernels=[],
        clones_only=False,
        pointer_size=8,
        alignment=8,
    )
    metadata["raw"] = metadata["rendered"]
    if metadata_output_format(manifest) == "msgpack":
        metadata["object"] = build_metadata_object(
            manifest,
            selected_kernels=[kernel],
            clones_only=False,
            pointer_size=8,
            alignment=8,
        )
    manifest["kernels"].pop("metadata_note", None)
    manifest.setdefault("clone_intents", []).append(
        {
            "mode": "hidden-abi-noop-clone",
            "source_kernel": kernel_name,
            "clone_kernel": clone_name,
            "clone_descriptor": clone_descriptor_name,
            "source_kernarg_length": plan["source_kernarg_length"],
            "instrumented_kernarg_length": plan["instrumented_kernarg_length"],
            "hidden_omniprobe_ctx": deepcopy(plan["hidden_omniprobe_ctx"]),
            "descriptor_patch_policy": "preserve-source-bytes",
        }
    )
    return {
        "source_kernel": kernel_name,
        "clone_kernel": clone_name,
        "clone_descriptor": clone_descriptor_name,
        "instrumented_kernarg_length": plan["instrumented_kernarg_length"],
        "hidden_omniprobe_ctx": deepcopy(plan["hidden_omniprobe_ctx"]),
    }


def build_noop_clone_kernel_record(kernel: dict, clone_name: str) -> dict:
    clone = deepcopy(kernel)
    clone["name"] = clone_name
    clone["symbol"] = f"{clone_name}.kd"
    return clone


def build_noop_clone_metadata_rendered(manifest: dict, kernel: dict, clone_name: str) -> str:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    raw_metadata = metadata.get("raw") or metadata.get("rendered")
    if not raw_metadata:
        raise SystemExit("rendered/raw metadata is required for noop clone insertion")
    prefix, kernel_blocks, suffix = raw_kernel_blocks(raw_metadata)
    identity = (kernel.get("name"), kernel.get("symbol"))
    output_lines = list(prefix)
    for block in kernel_blocks:
        output_lines.extend(block)
    for block in kernel_blocks:
        if kernel_identity(block) != identity:
            continue
        cloned = []
        for line in block:
            if ".name:" in line:
                prefix_text = line.split(".name:", 1)[0]
                cloned.append(f"{prefix_text}.name:           {clone_name}")
            elif ".symbol:" in line:
                prefix_text = line.split(".symbol:", 1)[0]
                cloned.append(f"{prefix_text}.symbol:         {clone_name}.kd")
            else:
                cloned.append(line)
        output_lines.extend(cloned)
        break
    output_lines.extend(suffix)
    return "\n".join(output_lines).rstrip() + "\n"


def build_noop_clone_metadata_object(manifest: dict, kernel: dict, clone_name: str) -> dict | None:
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    if not isinstance(metadata_obj, dict):
        return None
    result = deepcopy(metadata_obj)
    original_kernels = result.get("amdhsa.kernels")
    if not isinstance(original_kernels, list):
        return None
    source_identity = (kernel.get("name"), kernel.get("symbol"))
    for kernel_obj in original_kernels:
        if not isinstance(kernel_obj, dict):
            continue
        if (kernel_obj.get(".name"), kernel_obj.get(".symbol")) != source_identity:
            continue
        clone_obj = deepcopy(kernel_obj)
        clone_obj[".name"] = clone_name
        clone_obj[".symbol"] = f"{clone_name}.kd"
        original_kernels.append(clone_obj)
        break
    return result


def add_noop_clone_intent(manifest: dict, ir: dict, model: CodeObjectModel, kernel_name: str) -> dict:
    kernel = model.metadata_by_kernel_name(kernel_name)
    if kernel is None:
        raise SystemExit(f"kernel metadata for {kernel_name!r} not found")
    clone_name = get_hidden_abi_instrumented_name(kernel_name)
    clone_descriptor_name = f"{clone_name}.kd"

    duplicate_function_ir(ir, kernel_name, clone_name)
    duplicate_symbol(manifest["functions"]["all_symbols"], kernel_name, clone_name)
    duplicate_symbol(manifest["kernels"]["function_symbols"], kernel_name, clone_name)
    duplicate_symbol(manifest["symbols"], kernel_name, clone_name)

    source_descriptor = model.descriptor_by_kernel_name(kernel_name)
    if source_descriptor is None:
        raise SystemExit(f"descriptor for kernel {kernel_name!r} not found")
    clone_descriptor = deepcopy(source_descriptor)
    clone_descriptor["name"] = clone_descriptor_name
    clone_descriptor["kernel_name"] = clone_name
    manifest["kernels"]["descriptors"].append(clone_descriptor)
    duplicate_symbol(
        manifest["kernels"]["descriptor_symbols"],
        str(source_descriptor.get("name")),
        clone_descriptor_name,
    )
    duplicate_symbol(
        manifest["symbols"],
        str(source_descriptor.get("name")),
        clone_descriptor_name,
    )

    metadata = manifest["kernels"]["metadata"]
    metadata.setdefault("kernels", [])
    metadata["kernels"].append(build_noop_clone_kernel_record(kernel, clone_name))
    metadata["rendered"] = build_noop_clone_metadata_rendered(manifest, kernel, clone_name)
    metadata["raw"] = metadata["rendered"]
    metadata_object = build_noop_clone_metadata_object(manifest, kernel, clone_name)
    if metadata_object is not None:
        metadata["object"] = metadata_object
    manifest["kernels"].pop("metadata_note", None)
    manifest.setdefault("clone_intents", []).append(
        {
            "mode": "noop-clone",
            "source_kernel": kernel_name,
            "clone_kernel": clone_name,
            "clone_descriptor": clone_descriptor_name,
            "abi": "unchanged",
        }
    )
    return {
        "source_kernel": kernel_name,
        "clone_kernel": clone_name,
        "clone_descriptor": clone_descriptor_name,
        "abi": "unchanged",
    }


ENTRY_WRAPPER_PROOF_ARCH = "gfx1030"
ENTRY_WRAPPER_PROOF_BODY_PREFIX = "__omniprobe_original_body_"
ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES = {
    "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1",
    "wave64-direct-vgpr-xyz-flat-scratch-alias-v1",
    "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1",
}
ENTRY_WRAPPER_HIDDEN_HANDOFF_POINTER_SIZE = 8
ENTRY_WRAPPER_HIDDEN_HANDOFF_ALIGNMENT = 8


def find_ir_function(ir: dict, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"IR function {function_name!r} not found")
    return function


def align_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        return value
    return ((value + alignment - 1) // alignment) * alignment


def build_text_function_symbol(
    source_symbol: dict,
    *,
    name: str,
    value: int,
    size: int,
    text_section: dict | None,
) -> dict:
    symbol = deepcopy(source_symbol)
    symbol["name"] = name
    symbol["value"] = int(value)
    symbol["size"] = int(size)
    symbol["section"] = ".text"
    if isinstance(text_section, dict):
        symbol["section_offset"] = int(value) - int(text_section.get("address", 0) or 0)
    return symbol


def wrapper_start_address(ir: dict, manifest: dict) -> int:
    text_section = next(
        (section for section in manifest.get("sections", []) if section.get("name") == ".text"),
        None,
    )
    text_end = 0
    if isinstance(text_section, dict):
        text_end = int(text_section.get("address", 0) or 0) + int(text_section.get("size", 0) or 0)
    function_end = max(
        (
            int(function.get("end_address", function.get("start_address", 0)) or 0)
            for function in ir.get("functions", [])
        ),
        default=0,
    )
    return align_up(max(text_end, function_end), 0x100)


def build_entry_wrapper_ir(
    *,
    wrapper_name: str,
    body_name: str,
    start_address: int,
    scratch_pair: tuple[int, int],
    workitem_spill_restore_plan: dict | None = None,
    hidden_ctx_offset: int | None = None,
    hidden_ctx_source_pair: tuple[int, int] | None = None,
    hidden_handoff_field_loads: list[dict] | None = None,
    hidden_handoff_field_stores: list[dict] | None = None,
    hidden_handoff_store_before_loads: bool = False,
) -> dict:
    scratch_lo, scratch_hi = scratch_pair
    next_address = start_address
    instructions = []

    if isinstance(workitem_spill_restore_plan, dict):
        source_vgprs = [int(value) for value in workitem_spill_restore_plan.get("source_vgprs", [])]
        spill_offset = int(workitem_spill_restore_plan.get("spill_offset", 0) or 0)
        save_pair = workitem_spill_restore_plan.get("save_pair")
        if not (
            isinstance(save_pair, list)
            and len(save_pair) == 2
            and all(isinstance(value, int) for value in save_pair)
        ):
            raise SystemExit("entry wrapper workitem spill/restore requires a save_pair")
        save_lo, save_hi = int(save_pair[0]), int(save_pair[1])
        soffset_sgpr = workitem_spill_restore_plan.get("soffset_sgpr")
        if not isinstance(soffset_sgpr, int):
            raise SystemExit("entry wrapper workitem spill/restore requires soffset_sgpr")
        private_pattern_class = str(
            workitem_spill_restore_plan.get("private_segment_pattern_class", "") or ""
        )
        address_vgprs = workitem_spill_restore_plan.get("address_vgprs")
        private_offset_source_sgpr = workitem_spill_restore_plan.get("private_segment_offset_source_sgpr")
        if private_pattern_class in {
            "",
            "setreg_flat_scratch_init",
            "flat_scratch_alias_init",
            "scalar_pair_update_only",
            "None",
        }:
            if not isinstance(private_offset_source_sgpr, int):
                raise SystemExit(
                    "entry wrapper workitem spill/restore requires a private segment offset SGPR"
                )
            def emit_private_address_setup() -> None:
                nonlocal next_address
                instructions.extend(
                    [
                        {
                            "address": next_address,
                            "mnemonic": "s_add_u32",
                            "operand_text": f"s0, s0, s{private_offset_source_sgpr}",
                            "operands": ["s0", "s0", f"s{private_offset_source_sgpr}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 4,
                            "mnemonic": "s_addc_u32",
                            "operand_text": "s1, s1, 0",
                            "operands": ["s1", "s1", "0"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                    ]
                )
                next_address += 8
        elif private_pattern_class in {
            "src_private_base",
            "wrapper_owned_src_private_base",
        }:
            def emit_private_address_setup() -> None:
                nonlocal next_address
                instructions.append(
                    {
                        "address": next_address,
                        "mnemonic": "s_mov_b64",
                        "operand_text": "s[0:1], src_private_base",
                        "operands": ["s[0:1]", "src_private_base"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    }
                )
                next_address += 4
                if isinstance(private_offset_source_sgpr, int):
                    instructions.extend(
                        [
                            {
                                "address": next_address,
                                "mnemonic": "s_add_u32",
                                "operand_text": f"s0, s0, s{private_offset_source_sgpr}",
                                "operands": ["s0", "s0", f"s{private_offset_source_sgpr}"],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                            {
                                "address": next_address + 4,
                                "mnemonic": "s_addc_u32",
                                "operand_text": "s1, s1, 0",
                                "operands": ["s1", "s1", "0"],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                        ]
                    )
                    next_address += 8
        else:
            raise SystemExit(
                f"entry wrapper workitem spill/restore does not support private pattern {private_pattern_class!r}"
            )

        if source_vgprs:
            instructions.extend(
                [
                    {
                        "address": next_address,
                        "mnemonic": "s_mov_b32",
                        "operand_text": f"s{save_lo}, s0",
                        "operands": [f"s{save_lo}", "s0"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                    {
                        "address": next_address + 4,
                        "mnemonic": "s_mov_b32",
                        "operand_text": f"s{save_hi}, s1",
                        "operands": [f"s{save_hi}", "s1"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                ]
            )
            next_address += 8
            if private_pattern_class == "wrapper_owned_src_private_base":
                if spill_offset != 0:
                    raise SystemExit(
                        "entry wrapper workitem spill/restore requires zero spill offset for wrapper-owned src_private_base"
                    )
                if not (
                    isinstance(address_vgprs, list)
                    and len(address_vgprs) == 2
                    and all(isinstance(value, int) for value in address_vgprs)
                ):
                    raise SystemExit(
                        "entry wrapper workitem spill/restore requires address_vgprs for wrapper-owned src_private_base"
                    )
                addr_lo_vgpr, addr_hi_vgpr = int(address_vgprs[0]), int(address_vgprs[1])
                emit_private_address_setup()
                instructions.extend(
                    [
                        {
                            "address": next_address,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_lo_vgpr}, s0",
                            "operands": [f"v{addr_lo_vgpr}", "s0"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 4,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_hi_vgpr}, s1",
                            "operands": [f"v{addr_hi_vgpr}", "s1"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 8,
                            "mnemonic": "flat_store_dword",
                            "operand_text": f"v[{addr_lo_vgpr}:{addr_hi_vgpr}], v{source_vgprs[0]}",
                            "operands": [f"v[{addr_lo_vgpr}:{addr_hi_vgpr}]", f"v{source_vgprs[0]}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                    ]
                )
                next_address += 12
            else:
                emit_private_address_setup()
                instructions.append(
                    {
                        "address": next_address,
                        "mnemonic": "s_mov_b32",
                        "operand_text": f"s{soffset_sgpr}, 0",
                        "operands": [f"s{soffset_sgpr}", "0"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    }
                )
                next_address += 4
                for index, source_vgpr in enumerate(source_vgprs):
                    current_offset = spill_offset + (index * 4)
                    instructions.append(
                        {
                            "address": next_address,
                            "mnemonic": "buffer_store_dword",
                            "operand_text": (
                                f"v{source_vgpr}, off, s[0:3], s{soffset_sgpr} offset:{current_offset}"
                            ),
                            "operands": [
                                f"v{source_vgpr}",
                                "off",
                                "s[0:3]",
                                f"s{soffset_sgpr}",
                                f"offset:{current_offset}",
                            ],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        }
                    )
                    next_address += 8
            instructions.extend(
                [
                    {
                        "address": next_address,
                        "mnemonic": "s_mov_b32",
                        "operand_text": "s0, s{}".format(save_lo),
                        "operands": ["s0", f"s{save_lo}"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                    {
                        "address": next_address + 4,
                        "mnemonic": "s_mov_b32",
                        "operand_text": "s1, s{}".format(save_hi),
                        "operands": ["s1", f"s{save_hi}"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                ]
            )
            next_address += 8
            for source_vgpr in source_vgprs:
                instructions.append(
                    {
                        "address": next_address,
                        "mnemonic": "v_mov_b32_e32",
                        "operand_text": f"v{source_vgpr}, 0",
                        "operands": [f"v{source_vgpr}", "0"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    }
                )
                next_address += 4
            if private_pattern_class == "wrapper_owned_src_private_base":
                addr_lo_vgpr, addr_hi_vgpr = int(address_vgprs[0]), int(address_vgprs[1])
                emit_private_address_setup()
                instructions.extend(
                    [
                        {
                            "address": next_address,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_lo_vgpr}, s0",
                            "operands": [f"v{addr_lo_vgpr}", "s0"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 4,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_hi_vgpr}, s1",
                            "operands": [f"v{addr_hi_vgpr}", "s1"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 8,
                            "mnemonic": "flat_load_dword",
                            "operand_text": f"v{source_vgprs[0]}, v[{addr_lo_vgpr}:{addr_hi_vgpr}]",
                            "operands": [f"v{source_vgprs[0]}", f"v[{addr_lo_vgpr}:{addr_hi_vgpr}]"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 12,
                            "mnemonic": "s_waitcnt",
                            "operand_text": "vmcnt(0)",
                            "operands": ["vmcnt(0)"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 16,
                            "mnemonic": "s_mov_b32",
                            "operand_text": "s0, s{}".format(save_lo),
                            "operands": ["s0", f"s{save_lo}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 20,
                            "mnemonic": "s_mov_b32",
                            "operand_text": "s1, s{}".format(save_hi),
                            "operands": ["s1", f"s{save_hi}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                    ]
                )
                next_address += 24
            else:
                emit_private_address_setup()
                instructions.append(
                    {
                        "address": next_address,
                        "mnemonic": "s_mov_b32",
                        "operand_text": f"s{soffset_sgpr}, 0",
                        "operands": [f"s{soffset_sgpr}", "0"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    }
                )
                next_address += 4
                for index, source_vgpr in enumerate(source_vgprs):
                    current_offset = spill_offset + (index * 4)
                    instructions.append(
                        {
                            "address": next_address,
                            "mnemonic": "buffer_load_dword",
                            "operand_text": (
                                f"v{source_vgpr}, off, s[0:3], s{soffset_sgpr} offset:{current_offset}"
                            ),
                            "operands": [
                                f"v{source_vgpr}",
                                "off",
                                "s[0:3]",
                                f"s{soffset_sgpr}",
                                f"offset:{current_offset}",
                            ],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        }
                    )
                    next_address += 8
                instructions.extend(
                    [
                        {
                            "address": next_address,
                            "mnemonic": "s_waitcnt",
                            "operand_text": "vmcnt(0)",
                            "operands": ["vmcnt(0)"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 4,
                            "mnemonic": "s_mov_b32",
                            "operand_text": "s0, s{}".format(save_lo),
                            "operands": ["s0", f"s{save_lo}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 8,
                            "mnemonic": "s_mov_b32",
                            "operand_text": "s1, s{}".format(save_hi),
                            "operands": ["s1", f"s{save_hi}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                    ]
                )
                next_address += 12

    if hidden_ctx_offset is not None:
        if hidden_ctx_source_pair is None:
            raise SystemExit("entry wrapper hidden handoff load requires a source kernarg SGPR pair")
        source_lo, source_hi = hidden_ctx_source_pair
        def emit_hidden_ctx_pointer_load() -> None:
            nonlocal next_address
            instructions.extend(
                [
                    {
                        "address": next_address,
                        "mnemonic": "s_load_dwordx2",
                        "operand_text": (
                            f"s[{scratch_lo}:{scratch_hi}], "
                            f"s[{source_lo}:{source_hi}], 0x{int(hidden_ctx_offset):x}"
                        ),
                        "operands": [
                            f"s[{scratch_lo}:{scratch_hi}]",
                            f"s[{source_lo}:{source_hi}]",
                            f"0x{int(hidden_ctx_offset):x}",
                        ],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                    {
                        "address": next_address + 4,
                        "mnemonic": "s_waitcnt",
                        "operand_text": "lgkmcnt(0)",
                        "operands": ["lgkmcnt(0)"],
                        "control_flow": "linear",
                        "target": None,
                        "is_padding": False,
                    },
                ]
            )
            next_address += 8

        def emit_hidden_handoff_field_loads() -> None:
            nonlocal next_address
            emit_hidden_ctx_pointer_load()
            for field_load in hidden_handoff_field_loads or []:
                kind = str(field_load.get("kind", "") or "")
                field_offset = int(field_load.get("offset", 0) or 0)
                if kind == "u64":
                    target_pair_value = field_load.get("target_pair")
                    if (
                        isinstance(target_pair_value, list)
                        and len(target_pair_value) == 2
                        and all(isinstance(entry, int) for entry in target_pair_value)
                    ):
                        target_lo, target_hi = int(target_pair_value[0]), int(target_pair_value[1])
                    else:
                        target_lo, target_hi = scratch_lo, scratch_hi
                    if bool(field_load.get("clobber_target_before_load", False)):
                        instructions.extend(
                            [
                                {
                                    "address": next_address,
                                    "mnemonic": "s_mov_b32",
                                    "operand_text": f"s{target_lo}, 0",
                                    "operands": [f"s{target_lo}", "0"],
                                    "control_flow": "linear",
                                    "target": None,
                                    "is_padding": False,
                                },
                                {
                                    "address": next_address + 4,
                                    "mnemonic": "s_mov_b32",
                                    "operand_text": f"s{target_hi}, 0",
                                    "operands": [f"s{target_hi}", "0"],
                                    "control_flow": "linear",
                                    "target": None,
                                    "is_padding": False,
                                },
                            ]
                        )
                        next_address += 8
                    instructions.extend(
                        [
                            {
                                "address": next_address,
                                "mnemonic": "s_load_dwordx2",
                                "operand_text": (
                                    f"s[{target_lo}:{target_hi}], "
                                    f"s[{scratch_lo}:{scratch_hi}], 0x{field_offset:x}"
                                ),
                                "operands": [
                                    f"s[{target_lo}:{target_hi}]",
                                    f"s[{scratch_lo}:{scratch_hi}]",
                                    f"0x{field_offset:x}",
                                ],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                            {
                                "address": next_address + 4,
                                "mnemonic": "s_waitcnt",
                                "operand_text": "lgkmcnt(0)",
                                "operands": ["lgkmcnt(0)"],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                        ]
                    )
                    next_address += 8
                elif kind == "u32":
                    target_sgpr = field_load.get("target_sgpr")
                    target_sgpr_value = int(target_sgpr) if target_sgpr is not None else scratch_lo
                    if bool(field_load.get("clobber_target_before_load", False)):
                        instructions.append(
                            {
                                "address": next_address,
                                "mnemonic": "s_mov_b32",
                                "operand_text": f"s{target_sgpr_value}, 0",
                                "operands": [f"s{target_sgpr_value}", "0"],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            }
                        )
                        next_address += 4
                    instructions.extend(
                        [
                            {
                                "address": next_address,
                                "mnemonic": "s_load_dword",
                                "operand_text": (
                                    f"s{target_sgpr_value}, "
                                    f"s[{scratch_lo}:{scratch_hi}], 0x{field_offset:x}"
                                ),
                                "operands": [
                                    f"s{target_sgpr_value}",
                                    f"s[{scratch_lo}:{scratch_hi}]",
                                    f"0x{field_offset:x}",
                                ],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                            {
                                "address": next_address + 4,
                                "mnemonic": "s_waitcnt",
                                "operand_text": "lgkmcnt(0)",
                                "operands": ["lgkmcnt(0)"],
                                "control_flow": "linear",
                                "target": None,
                                "is_padding": False,
                            },
                        ]
                    )
                    next_address += 8
                else:
                    raise SystemExit(f"unsupported hidden handoff field load kind {kind!r}")

        def emit_hidden_handoff_field_stores() -> None:
            nonlocal next_address
            for field_store in hidden_handoff_field_stores or []:
                kind = str(field_store.get("kind", "") or "")
                field_offset = int(field_store.get("offset", 0) or 0)
                if kind != "u32_from_sgpr":
                    raise SystemExit(f"unsupported hidden handoff field store kind {kind!r}")
                source_sgpr = field_store.get("source_sgpr")
                if source_sgpr is None:
                    raise SystemExit("hidden handoff u32 capture store requires source_sgpr")
                address_vgprs = field_store.get("address_vgprs")
                if not (
                    isinstance(address_vgprs, list)
                    and len(address_vgprs) == 2
                    and all(isinstance(entry, int) for entry in address_vgprs)
                ):
                    raise SystemExit("hidden handoff u32 capture store requires address_vgprs pair")
                data_vgpr = field_store.get("data_vgpr")
                if not isinstance(data_vgpr, int):
                    raise SystemExit("hidden handoff u32 capture store requires data_vgpr")
                addr_lo_vgpr, addr_hi_vgpr = int(address_vgprs[0]), int(address_vgprs[1])
                emit_hidden_ctx_pointer_load()
                instructions.extend(
                    [
                        {
                            "address": next_address,
                            "mnemonic": "s_add_u32",
                            "operand_text": f"s{scratch_lo}, s{scratch_lo}, 0x{field_offset:x}",
                            "operands": [f"s{scratch_lo}", f"s{scratch_lo}", f"0x{field_offset:x}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 4,
                            "mnemonic": "s_addc_u32",
                            "operand_text": f"s{scratch_hi}, s{scratch_hi}, 0",
                            "operands": [f"s{scratch_hi}", f"s{scratch_hi}", "0"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 8,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_lo_vgpr}, s{scratch_lo}",
                            "operands": [f"v{addr_lo_vgpr}", f"s{scratch_lo}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 12,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{addr_hi_vgpr}, s{scratch_hi}",
                            "operands": [f"v{addr_hi_vgpr}", f"s{scratch_hi}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 16,
                            "mnemonic": "v_mov_b32_e32",
                            "operand_text": f"v{data_vgpr}, s{int(source_sgpr)}",
                            "operands": [f"v{data_vgpr}", f"s{int(source_sgpr)}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                        {
                            "address": next_address + 20,
                            "mnemonic": "flat_store_dword",
                            "operand_text": f"v[{addr_lo_vgpr}:{addr_hi_vgpr}], v{data_vgpr}",
                            "operands": [f"v[{addr_lo_vgpr}:{addr_hi_vgpr}]", f"v{data_vgpr}"],
                            "control_flow": "linear",
                            "target": None,
                            "is_padding": False,
                        },
                    ]
                )
                next_address += 24

        if hidden_handoff_store_before_loads:
            emit_hidden_handoff_field_stores()
            emit_hidden_handoff_field_loads()
        else:
            emit_hidden_handoff_field_loads()
            emit_hidden_handoff_field_stores()

    instructions.extend(
        [
            {
                "address": next_address,
                "mnemonic": "s_getpc_b64",
                "operand_text": f"s[{scratch_lo}:{scratch_hi}]",
                "operands": [f"s[{scratch_lo}:{scratch_hi}]"],
                "control_flow": "linear",
                "target": None,
                "is_padding": False,
            },
            {
                "address": next_address + 4,
                "mnemonic": "s_add_u32",
                "operand_text": f"s{scratch_lo}, s{scratch_lo}, {body_name}@rel32@lo+4",
                "operands": [f"s{scratch_lo}", f"s{scratch_lo}", f"{body_name}@rel32@lo+4"],
                "control_flow": "linear",
                "target": None,
                "is_padding": False,
            },
            {
                "address": next_address + 8,
                "mnemonic": "s_addc_u32",
                "operand_text": f"s{scratch_hi}, s{scratch_hi}, {body_name}@rel32@hi+4",
                "operands": [f"s{scratch_hi}", f"s{scratch_hi}", f"{body_name}@rel32@hi+4"],
                "control_flow": "linear",
                "target": None,
                "is_padding": False,
            },
            {
                "address": next_address + 12,
                "mnemonic": "s_setpc_b64",
                "operand_text": f"s[{scratch_lo}:{scratch_hi}]",
                "operands": [f"s[{scratch_lo}:{scratch_hi}]"],
                "control_flow": "branch",
                "target": {"symbol": body_name, "offset": 0},
                "is_padding": False,
            },
        ]
    )
    end_address = next_address + 16
    return {
        "name": wrapper_name,
        "start_address": start_address,
        "end_address": end_address,
        "basic_blocks": [
            {
                "label": "bb_0",
                "start_address": start_address,
                "end_address": end_address,
                "instruction_addresses": [instruction["address"] for instruction in instructions],
                "successors": [],
            }
        ],
        "instructions": instructions,
    }


def classify_entry_handoff_supported_class(analysis: dict) -> tuple[str | None, list[str]]:
    blockers: list[str] = []

    if not analysis.get("descriptor_has_kernarg_segment_ptr", False):
        blockers.append("missing-kernarg-segment-ptr")
    if not analysis.get("inferred_kernarg_base"):
        blockers.append("kernarg-base-not-observed")

    wavefront_size = int(analysis.get("wavefront_size", 0) or 0)
    if wavefront_size not in {32, 64}:
        blockers.append(f"unsupported-wavefront-size-{wavefront_size}")

    workitem_vgpr_count = int(analysis.get("entry_workitem_vgpr_count", 0) or 0)
    system_roles = analysis.get("entry_system_sgpr_roles", [])
    role_names = [entry.get("role") for entry in system_roles if isinstance(entry, dict)]
    private_pattern = (
        analysis.get("observed_private_segment_materialization", {}) or {}
    ).get("pattern_class")
    workitem_pattern = (
        analysis.get("observed_workitem_id_materialization", {}) or {}
    ).get("pattern_class")

    if blockers:
        return None, blockers

    full_system_role_layout = [
        "workgroup_id_x",
        "workgroup_id_y",
        "workgroup_id_z",
        "private_segment_wave_offset",
    ]

    if (
        wavefront_size == 32
        and workitem_vgpr_count == 3
        and role_names == full_system_role_layout
        and workitem_pattern in {None, "direct_vgpr_xyz"}
    ):
        if private_pattern == "setreg_flat_scratch_init":
            return "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1", blockers
        return None, [f"unsupported-wave32-private-pattern-{private_pattern}"]

    if (
        wavefront_size == 64
        and workitem_vgpr_count == 3
        and role_names == full_system_role_layout
        and workitem_pattern == "packed_v0_10_10_10_unpack"
    ):
        if private_pattern == "flat_scratch_alias_init":
            return "wave64-packed-v0-10_10_10-flat-scratch-alias-v1", blockers
        if private_pattern == "src_private_base":
            return "wave64-packed-v0-10_10_10-src-private-base-v1", blockers
        return None, [f"unsupported-wave64-private-pattern-{private_pattern}"]

    if (
        wavefront_size == 64
        and workitem_vgpr_count == 3
        and role_names == full_system_role_layout
        and workitem_pattern == "direct_vgpr_xyz"
    ):
        if private_pattern == "flat_scratch_alias_init":
            return "wave64-direct-vgpr-xyz-flat-scratch-alias-v1", blockers
        if private_pattern == "src_private_base":
            return "wave64-direct-vgpr-xyz-src-private-base-v1", blockers
        return None, [f"unsupported-wave64-private-pattern-{private_pattern}"]

    if (
        wavefront_size == 64
        and workitem_vgpr_count == 1
        and role_names == ["workgroup_id_x"]
        and workitem_pattern == "single_vgpr_workitem_id"
        and private_pattern is None
    ):
        return "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1", blockers

    if workitem_vgpr_count not in {1, 3}:
        blockers.append(f"unsupported-workitem-vgpr-count-{workitem_vgpr_count}")
    if role_names not in (["workgroup_id_x"], full_system_role_layout):
        blockers.append(f"unsupported-system-sgpr-role-layout-{role_names}")
    if private_pattern not in {
        None,
        "setreg_flat_scratch_init",
        "flat_scratch_alias_init",
        "src_private_base",
    }:
        blockers.append(f"unsupported-private-pattern-{private_pattern}")
    if workitem_pattern not in {
        None,
        "direct_vgpr_xyz",
        "packed_v0_10_10_10_unpack",
        "single_vgpr_workitem_id",
    }:
        blockers.append(f"unsupported-workitem-pattern-{workitem_pattern}")
    if blockers:
        return None, blockers

    return None, [
        "unsupported-entry-shape-"
        f"wave{wavefront_size}-{workitem_pattern}-{private_pattern}"
    ]


def build_entry_handoff_reconstruction_actions(analysis: dict) -> list[dict]:
    actions: list[dict] = []
    kernarg_base = analysis.get("inferred_kernarg_base") or {}
    base_pair = kernarg_base.get("base_pair") or []
    if len(base_pair) == 2:
        actions.append(
            {
                "action": "materialize-kernarg-base-pair",
                "target_sgprs": [int(base_pair[0]), int(base_pair[1])],
                "source": "original-launch-kernarg",
            }
        )

    for entry in analysis.get("entry_system_sgpr_roles", []):
        if not isinstance(entry, dict):
            continue
        role = entry.get("role")
        sgpr = entry.get("sgpr")
        if not isinstance(role, str) or not isinstance(sgpr, int):
            continue
        actions.append(
            {
                "action": "materialize-system-sgpr",
                "role": role,
                "target_sgpr": sgpr,
                "source": f"reconstructed-{role}",
            }
        )

    workitem_vgpr_count = int(analysis.get("entry_workitem_vgpr_count", 0) or 0)
    if workitem_vgpr_count:
        actions.append(
            {
                "action": "materialize-entry-workitem-vgprs",
                "count": workitem_vgpr_count,
                "source_pattern": (
                    (analysis.get("observed_workitem_id_materialization", {}) or {}).get("pattern_class")
                    or "descriptor-declared"
                ),
            }
        )

    private_materialization = analysis.get("observed_private_segment_materialization") or {}
    if private_materialization:
        actions.append(
            {
                "action": "materialize-private-segment-state",
                "pattern_class": private_materialization.get("pattern_class"),
            }
        )

    actions.append(
        {
            "action": "require-wavefront-mode",
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
        }
    )
    return actions


def build_entry_wrapper_source_analysis(analysis: dict, actions: list[dict]) -> dict:
    action_analysis: list[dict] = []
    blockers: list[str] = []

    for action in actions:
        action_name = action.get("action")
        record = {
            "action": action_name,
            "preserve_without_clobber": True,
            "reconstruct_after_clobber_with_current_wrapper_only": False,
            "blocker": None,
        }
        if action_name == "materialize-kernarg-base-pair":
            record["blocker"] = "no-independent-kernarg-source-in-current-wrapper"
        elif action_name == "materialize-system-sgpr":
            role = action.get("role")
            if role in {"workgroup_id_x", "workgroup_id_y", "workgroup_id_z"}:
                record["blocker"] = "no-independent-current-workgroup-id-source"
            elif role == "private_segment_wave_offset":
                record["blocker"] = "no-independent-private-segment-wave-offset-source"
            else:
                record["blocker"] = f"no-independent-source-for-{role}"
        elif action_name == "materialize-entry-workitem-vgprs":
            record["blocker"] = "no-independent-entry-workitem-vgpr-source"
        elif action_name == "materialize-private-segment-state":
            record["blocker"] = "requires-original-private-state-or-supplemental-handoff"
        elif action_name == "require-wavefront-mode":
            record["reconstruct_after_clobber_with_current_wrapper_only"] = True
            record["blocker"] = None
        else:
            record["blocker"] = "unclassified-wrapper-source-gap"

        blocker = record.get("blocker")
        if blocker:
            blockers.append(str(blocker))
        action_analysis.append(record)

    unique_blockers: list[str] = []
    for blocker in blockers:
        if blocker not in unique_blockers:
            unique_blockers.append(blocker)

    return {
        "model": "direct-entry-wrapper-v1",
        "direct_branch_supported": True,
        "reconstruction_after_clobber_supported": False,
        "reconstruction_after_clobber_blockers": unique_blockers,
        "action_analysis": action_analysis,
    }


def build_entry_supplemental_handoff_contract(
    *,
    function_name: str,
    supported_class: str | None,
    analysis: dict,
    actions: list[dict],
) -> dict:
    validation_requirements: list[dict] = [
        {
            "name": "wavefront_size",
            "kind": "u32",
            "required": True,
            "source_class": "descriptor_derived",
            "variability": "dispatch_constant",
            "producer": "descriptor-and-launch-validation",
            "purpose": "validate wrapper launch mode before branch-to-body handoff",
            "satisfies_actions": ["require-wavefront-mode"],
        }
    ]
    fields: list[dict] = [
        {
            "name": "original_kernarg_pointer",
            "kind": "u64",
            "required": True,
            "source_class": "dispatch_carried",
            "variability": "dispatch_constant",
            "producer": "runtime-dispatch-rewrite",
            "purpose": "re-materialize the original kernarg base pair after wrapper-side clobber",
            "satisfies_actions": ["materialize-kernarg-base-pair"],
        },
    ]

    role_field_specs = {
        "workgroup_id_x": ("u32", "workgroup_variant", "restore entry system SGPR role workgroup_id_x"),
        "workgroup_id_y": ("u32", "workgroup_variant", "restore entry system SGPR role workgroup_id_y"),
        "workgroup_id_z": ("u32", "workgroup_variant", "restore entry system SGPR role workgroup_id_z"),
        "private_segment_wave_offset": (
            "u32",
            "wave_variant",
            "restore the entry private-segment wave offset live-in",
        ),
    }
    for role_entry in analysis.get("entry_system_sgpr_roles", []):
        if not isinstance(role_entry, dict):
            continue
        role = role_entry.get("role")
        if role not in role_field_specs:
            continue
        kind, variability, purpose = role_field_specs[str(role)]
        satisfies_actions = ["materialize-system-sgpr"]
        if role == "private_segment_wave_offset":
            satisfies_actions.append("materialize-private-segment-state")
        fields.append(
            {
                "name": str(role),
                "kind": kind,
                "required": True,
                "source_class": "entry_captured",
                "variability": variability,
                "producer": "wrapper-entry-snapshot",
                "purpose": purpose,
                "satisfies_actions": satisfies_actions,
                "role": str(role),
            }
        )

    workitem_components = ["x", "y", "z"][: max(0, min(3, int(analysis.get("entry_workitem_vgpr_count", 0) or 0)))]
    for component in workitem_components:
        fields.append(
            {
                "name": f"entry_workitem_id_{component}",
                "kind": "u32",
                "required": True,
                "source_class": "entry_captured",
                "variability": "lane_variant",
                "producer": "wrapper-entry-snapshot",
                "purpose": (
                    "restore the canonical "
                    f"{component} workitem-id component into the expected entry VGPR contract"
                ),
                "satisfies_actions": ["materialize-entry-workitem-vgprs"],
            }
        )

    private_pattern = (
        analysis.get("observed_private_segment_materialization", {}) or {}
    ).get("pattern_class")
    if private_pattern in {"setreg_flat_scratch_init", "flat_scratch_alias_init", "src_private_base"}:
        fields.extend(
            [
                {
                    "name": "entry_private_base_lo",
                    "kind": "u32",
                    "required": True,
                    "source_class": "entry_captured",
                    "variability": "wave_variant",
                    "producer": "wrapper-entry-snapshot-or-private-state-reconstruction",
                    "purpose": "supply the low dword of the original private base materialization source",
                    "satisfies_actions": ["materialize-private-segment-state"],
                },
                {
                    "name": "entry_private_base_hi",
                    "kind": "u32",
                    "required": True,
                    "source_class": "entry_captured",
                    "variability": "wave_variant",
                    "producer": "wrapper-entry-snapshot-or-private-state-reconstruction",
                    "purpose": "supply the high dword of the original private base materialization source",
                    "satisfies_actions": ["materialize-private-segment-state"],
                },
            ]
        )

    if supported_class is None:
        fields = []
        validation_requirements = []

    dispatch_payload_fields = [
        entry for entry in fields if str(entry.get("source_class", "")) == "dispatch_carried"
    ]
    entry_snapshot_fields = [
        entry for entry in fields if str(entry.get("source_class", "")) == "entry_captured"
    ]

    return {
        "schema": "omniprobe.entry_handoff.hidden_v1",
        "original_kernel": function_name,
        "supported_class": supported_class,
        "required": supported_class is not None,
        "fields": fields,
        "validation_requirements": validation_requirements,
        "runtime_objects": {
            "dispatch_payload": {
                "name": "hidden_handoff_dispatch_payload_v1",
                "producer": "runtime-dispatch-rewrite",
                "transport": "wrapper-only hidden pointer or suffix carrier",
                "fields": dispatch_payload_fields,
            },
            "entry_snapshot": {
                "name": "entry_snapshot_v1",
                "producer": "wrapper-entry-snapshot",
                "transport": "wrapper-captured before helper execution",
                "fields": entry_snapshot_fields,
            },
            "validation": {
                "name": "launch_validation_v1",
                "producer": "descriptor-and-launch-validation",
                "fields": validation_requirements,
            },
        },
        "transport_classes": {
            "dispatch_carried": "Populated by the runtime/interceptor once per dispatch and valid for the whole grid.",
            "entry_captured": "Captured by the wrapper from original entry live-ins before helper execution perturbs the ABI state.",
            "descriptor_derived": "Validated or derived from descriptor/launch state rather than carried in the hidden payload.",
        },
        "notes": [
            "This contract is for the Omniprobe-owned wrapper dispatch ABI, not the original imported body ABI.",
            "The wrapper may run helpers against this canonical handoff state before reconstructing the original entry ABI and branching to the imported body.",
            "Only dispatch-carried fields are general host-populatable hidden-payload inputs. Workgroup-, wave-, and lane-variant fields must be preserved or snapshotted inside the wrapper itself.",
        ],
        "future_runtime_integration": {
            "producer": "interceptor/runtime dispatch rewrite",
            "consumer": "entry wrapper reconstructor",
            "transport": "hidden wrapper-only handoff pointer or suffix-ABI carrier",
        },
    }


def build_entry_wrapper_handoff_recipe(
    *,
    function_name: str,
    analysis: dict,
    descriptor: dict,
    kernel_metadata: dict | None,
    scratch_pair: tuple[int, int],
) -> dict:
    supported_class, blockers = classify_entry_handoff_supported_class(analysis)
    reconstruction_actions = build_entry_handoff_reconstruction_actions(analysis)
    return {
        "function": function_name,
        "arch": analysis.get("arch"),
        "supported_class": supported_class,
        "supported": supported_class is not None,
        "blockers": blockers,
        "descriptor_summary": {
            "kernarg_size": int(descriptor.get("kernarg_size", 0) or 0),
            "user_sgpr_count": int(
                (descriptor.get("compute_pgm_rsrc2", {}) or {}).get("user_sgpr_count", 0) or 0
            ),
            "private_segment_fixed_size": int(descriptor.get("private_segment_fixed_size", 0) or 0),
            "wavefront_size": int(analysis.get("wavefront_size", 0) or 0),
        },
        "kernel_metadata_summary": {
            "sgpr_count": int((kernel_metadata or {}).get("sgpr_count", 0) or 0),
            "vgpr_count": int((kernel_metadata or {}).get("vgpr_count", 0) or 0),
            "kernarg_segment_size": int((kernel_metadata or {}).get("kernarg_segment_size", 0) or 0),
        },
        "entry_requirements": {
            "entry_livein_sgprs": analysis.get("entry_livein_sgprs", []),
            "entry_system_sgpr_roles": analysis.get("entry_system_sgpr_roles", []),
            "entry_workitem_vgpr_count": int(analysis.get("entry_workitem_vgpr_count", 0) or 0),
            "inferred_kernarg_base": analysis.get("inferred_kernarg_base"),
            "observed_workitem_id_materialization": analysis.get("observed_workitem_id_materialization"),
            "observed_private_segment_materialization": analysis.get("observed_private_segment_materialization"),
        },
        "reconstruction_actions": reconstruction_actions,
        "wrapper_source_analysis": build_entry_wrapper_source_analysis(analysis, reconstruction_actions),
        "supplemental_handoff_contract": build_entry_supplemental_handoff_contract(
            function_name=function_name,
            supported_class=supported_class,
            analysis=analysis,
            actions=reconstruction_actions,
        ),
        "wrapper_strategy": {
            "kind": "pc-relative-entry-wrapper",
            "scratch_pair": [int(scratch_pair[0]), int(scratch_pair[1])],
            "branch_transfer_kind": "s_setpc_b64",
            "branch_target_symbol": function_name,
        },
        "handoff_constraints": {
            "must_match_wavefront_mode": True,
            "must_preserve_kernarg_layout": True,
            "must_preserve_private_segment_state": True,
            "must_preserve_entry_workitem_vgprs": True,
        },
    }


def infer_private_segment_offset_source_sgpr(analysis: dict) -> int | None:
    private_materialization = analysis.get("observed_private_segment_materialization")
    if not isinstance(private_materialization, dict):
        return None
    details = private_materialization.get("details", {})
    if not isinstance(details, dict):
        return None
    pair_updates = details.get("pair_updates", [])
    if not isinstance(pair_updates, list):
        return None
    first_pair_update = next(
        (
            entry
            for entry in pair_updates
            if isinstance(entry, dict)
            and entry.get("pair") == [0, 1]
            and isinstance(entry.get("offset_sgpr"), int)
        ),
        None,
    )
    if first_pair_update is None:
        return None
    return int(first_pair_update["offset_sgpr"])


def infer_wrapper_owned_private_segment_offset_sgpr(descriptor: dict) -> int | None:
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {}) if isinstance(descriptor, dict) else {}
    if not isinstance(rsrc2, dict):
        return None
    user_sgpr_count = rsrc2.get("user_sgpr_count")
    if not isinstance(user_sgpr_count, int) or user_sgpr_count < 0:
        return None
    cursor = int(user_sgpr_count)
    for key in (
        "enable_sgpr_workgroup_id_x",
        "enable_sgpr_workgroup_id_y",
        "enable_sgpr_workgroup_id_z",
        "enable_sgpr_workgroup_info",
    ):
        if int(rsrc2.get(key, 0) or 0):
            cursor += 1
    return cursor


def build_entry_wrapper_workitem_spill_restore_plan(
    *,
    analysis: dict,
    descriptor: dict,
    save_pair: tuple[int, int],
    branch_pair: tuple[int, int],
) -> dict:
    workitem_vgpr_count = int(analysis.get("entry_workitem_vgpr_count", 0) or 0)
    if workitem_vgpr_count <= 0:
        raise SystemExit("entry wrapper workitem proof requires entry workitem VGPRs")
    workitem_pattern = analysis.get("observed_workitem_id_materialization")
    pattern_class = (
        str(workitem_pattern.get("pattern_class"))
        if isinstance(workitem_pattern, dict)
        else None
    )
    if pattern_class == "packed_v0_10_10_10_unpack":
        source_vgprs = [0]
    elif pattern_class == "single_vgpr_workitem_id":
        source_vgprs = [0]
    elif pattern_class in {None, "direct_vgpr_xyz"}:
        source_vgprs = list(range(workitem_vgpr_count))
    else:
        raise SystemExit(
            "entry wrapper workitem proof does not support workitem materialization "
            f"pattern {pattern_class!r}"
        )

    private_pattern_class = (
        (analysis.get("observed_private_segment_materialization", {}) or {}).get("pattern_class")
    )
    if private_pattern_class not in {
        "setreg_flat_scratch_init",
        "flat_scratch_alias_init",
        "src_private_base",
        "scalar_pair_update_only",
        None,
    }:
        raise SystemExit(
            "entry wrapper workitem proof does not support private materialization "
            f"pattern {private_pattern_class!r}"
        )
    private_offset_source_sgpr = infer_private_segment_offset_source_sgpr(analysis)
    if private_pattern_class is None:
        # When the source entry ABI has no private-segment carrier, the wrapper
        # can still own a private tail after descriptor mutation enables the
        # wrapper-side private segment live-in.
        private_pattern_class = "wrapper_owned_src_private_base"
        private_offset_source_sgpr = infer_wrapper_owned_private_segment_offset_sgpr(descriptor)
        if private_offset_source_sgpr is None:
            raise SystemExit(
                "entry wrapper workitem proof could not infer a wrapper-owned private segment offset SGPR"
            )

    private_segment_size = int(descriptor.get("private_segment_fixed_size", 0) or 0)
    if private_segment_size < 0:
        raise SystemExit("kernel private-segment size cannot be negative")
    spill_bytes = max(0, len(source_vgprs) * 4)
    private_segment_growth = align_up(spill_bytes, 16)
    plan = {
        "source_vgprs": source_vgprs,
        "pattern_class": pattern_class,
        "spill_offset": private_segment_size,
        "spill_bytes": spill_bytes,
        "private_segment_growth": private_segment_growth,
        "private_segment_pattern_class": private_pattern_class,
        "private_segment_offset_source_sgpr": private_offset_source_sgpr,
        "save_pair": [int(save_pair[0]), int(save_pair[1])],
        "branch_pair": [int(branch_pair[0]), int(branch_pair[1])],
        "soffset_sgpr": int(branch_pair[0]),
    }
    if private_pattern_class == "wrapper_owned_src_private_base":
        if source_vgprs != [0]:
            raise SystemExit(
                "entry wrapper workitem proof currently supports wrapper-owned src_private_base "
                "only for single-VGPR entry classes"
            )
        plan["address_vgprs"] = [2, 3]
    return plan


def validate_entry_wrapper_proof_preconditions(
    manifest: dict,
    ir: dict,
    *,
    kernel_name: str,
) -> tuple[dict, dict, dict, dict | None, tuple[int, int]]:
    ir_arch = str(ir.get("arch", "") or "")
    metadata_target = str(
        (
            manifest.get("kernels", {})
            .get("metadata", {})
            .get("target", "")
        )
        or ""
    )
    function = find_ir_function(ir, kernel_name)
    descriptor = next(
        (
            entry
            for entry in manifest.get("kernels", {}).get("descriptors", [])
            if entry.get("kernel_name") == kernel_name or entry.get("name") == f"{kernel_name}.kd"
        ),
        None,
    )
    kernel_metadata = next(
        (
            entry
            for entry in manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
            if isinstance(entry, dict)
            and (entry.get("name") == kernel_name or entry.get("symbol") == f"{kernel_name}.kd")
        ),
        None,
    )
    analysis = analyze_kernel_entry_abi(
        function=function,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    liveins = set(int(value) for value in analysis.get("entry_livein_sgprs", []) if isinstance(value, int))
    supported_class, blockers = classify_entry_handoff_supported_class(analysis)
    if descriptor is None:
        raise SystemExit("entry-wrapper proof requires a descriptor for the source kernel")
    if supported_class is None:
        raise SystemExit(
            "entry-wrapper proof could not classify the source entry ABI; blockers: "
            f"{', '.join(blockers) or 'unknown'}"
        )
    if supported_class not in ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES:
        raise SystemExit(
            "entry-wrapper proof recognized entry-handoff class "
            f"{supported_class} but that class is not implemented in the runtime wrapper yet"
        )

    pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
    if not isinstance(pair_candidates, list) or not pair_candidates:
        raise SystemExit(
            "entry-wrapper proof requires at least one analyzed dead SGPR pair candidate for the branch scratch"
        )
    selected_pair = pair_candidates[0]
    pair = selected_pair.get("pair", [])
    if not isinstance(pair, list) or len(pair) != 2:
        raise SystemExit("entry-wrapper proof candidate pair was malformed")
    low, high = int(pair[0]), int(pair[1])
    if low in liveins or high in liveins:
        raise SystemExit(
            "entry-wrapper proof candidate scratch pair intersects declared live-ins: "
            f"s{low}:s{high}"
        )
    overwrite_details = [
        {
            "register": low,
            "operand_text": selected_pair.get("first_def_operand_texts", [None, None])[0],
            "address": selected_pair.get("first_def_instruction_addresses", [None, None])[0],
            "instruction_index": selected_pair.get("first_def_instruction_indices", [None, None])[0],
        },
        {
            "register": high,
            "operand_text": selected_pair.get("first_def_operand_texts", [None, None])[1],
            "address": selected_pair.get("first_def_instruction_addresses", [None, None])[1],
            "instruction_index": selected_pair.get("first_def_instruction_indices", [None, None])[1],
        },
    ]
    analysis["entry_wrapper_supported_class"] = supported_class
    analysis["entry_wrapper_scratch_pair"] = [low, high]
    analysis["entry_wrapper_entry_overwrites"] = overwrite_details
    recipe = build_entry_wrapper_handoff_recipe(
        function_name=kernel_name,
        analysis=analysis,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
        scratch_pair=(low, high),
    )
    return function, analysis, recipe, kernel_metadata, (low, high)


def add_entry_wrapper_proof_intent(
    manifest: dict,
    ir: dict,
    model: CodeObjectModel,
    kernel_name: str,
    *,
    include_hidden_handoff: bool = False,
    restore_kernarg_base_from_handoff: bool = False,
    restore_workgroup_x_from_handoff: bool = False,
    restore_workgroup_xyz_from_handoff: bool = False,
    restore_all_system_sgprs_from_handoff: bool = False,
    capture_restore_entry_workitem_vgprs: bool = False,
    capture_restore_full_entry_abi: bool = False,
    capture_workgroup_x_to_handoff: bool = False,
    capture_workgroup_xyz_to_handoff: bool = False,
    capture_all_system_sgprs_to_handoff: bool = False,
) -> dict:
    source_kernel = model.metadata_by_kernel_name(kernel_name)
    if source_kernel is None:
        raise SystemExit(f"kernel metadata for {kernel_name!r} not found")
    source_descriptor = model.descriptor_by_kernel_name(kernel_name)
    if source_descriptor is None:
        raise SystemExit(f"descriptor for kernel {kernel_name!r} not found")

    original_function, entry_analysis, handoff_recipe, kernel_metadata, scratch_pair = validate_entry_wrapper_proof_preconditions(
        manifest,
        ir,
        kernel_name=kernel_name,
    )
    branch_scratch_pair = scratch_pair
    workitem_spill_restore_plan = None
    if capture_restore_entry_workitem_vgprs or capture_restore_full_entry_abi:
        pair_candidates = entry_analysis.get("entry_dead_sgpr_pair_candidates", [])
        if not isinstance(pair_candidates, list) or len(pair_candidates) < 2:
            raise SystemExit(
                "entry-wrapper workitem proof requires at least two analyzed dead SGPR pair candidates"
            )
        secondary_pair = pair_candidates[1].get("pair", [])
        if not (
            isinstance(secondary_pair, list)
            and len(secondary_pair) == 2
            and all(isinstance(value, int) for value in secondary_pair)
        ):
            raise SystemExit("entry-wrapper workitem proof secondary scratch pair was malformed")
        branch_scratch_pair = (int(secondary_pair[0]), int(secondary_pair[1]))
        entry_analysis["entry_wrapper_secondary_scratch_pair"] = list(branch_scratch_pair)
        workitem_spill_restore_plan = build_entry_wrapper_workitem_spill_restore_plan(
            analysis=entry_analysis,
            descriptor=source_descriptor,
            save_pair=scratch_pair,
            branch_pair=branch_scratch_pair,
        )
        apply_binary_probe_nonleaf_policy(
            manifest,
            clone_kernel=kernel_name,
            private_segment_growth=int(
                workitem_spill_restore_plan.get("private_segment_growth", 0) or 0
            ),
        )
    body_name = f"{ENTRY_WRAPPER_PROOF_BODY_PREFIX}{kernel_name}"
    if any(function.get("name") == body_name for function in ir.get("functions", [])):
        raise SystemExit(f"entry-wrapper proof body name {body_name!r} already exists")
    hidden_handoff_plan = None
    hidden_ctx_offset = None
    hidden_handoff_field_loads: list[dict] = []
    hidden_handoff_field_stores: list[dict] = []
    kernarg_base = entry_analysis.get("inferred_kernarg_base") or {}
    kernarg_base_pair = kernarg_base.get("base_pair") or []
    if include_hidden_handoff:
        if len(kernarg_base_pair) != 2:
            raise SystemExit("entry-wrapper hidden-handoff proof requires an inferred kernarg base SGPR pair")
        hidden_handoff_plan = build_kernel_plan(
            source_kernel,
            pointer_size=ENTRY_WRAPPER_HIDDEN_HANDOFF_POINTER_SIZE,
            alignment=ENTRY_WRAPPER_HIDDEN_HANDOFF_ALIGNMENT,
        )
        hidden_ctx_offset = int(hidden_handoff_plan["hidden_omniprobe_ctx"]["offset"])
        hidden_handoff_field_loads = []
        if restore_workgroup_x_from_handoff:
            workgroup_x_sgpr = next(
                (
                    int(entry.get("sgpr"))
                    for entry in entry_analysis.get("entry_system_sgpr_roles", [])
                    if isinstance(entry, dict) and entry.get("role") == "workgroup_id_x"
                ),
                None,
            )
            if workgroup_x_sgpr is None:
                raise SystemExit("entry-wrapper workgroup-x restore proof requires a workgroup_id_x SGPR role")
            hidden_handoff_field_loads.append(
                {
                    "name": "workgroup_id_x",
                    "offset": 8,
                    "kind": "u32",
                    "target_sgpr": int(workgroup_x_sgpr),
                    "clobber_target_before_load": True,
                    "purpose": "restore workgroup_id_x under the single-workgroup proof launch",
                }
            )
        if restore_workgroup_xyz_from_handoff:
            for role_name, role_offset in (
                ("workgroup_id_x", 8),
                ("workgroup_id_y", 12),
                ("workgroup_id_z", 16),
            ):
                role_sgpr = next(
                    (
                        int(entry.get("sgpr"))
                        for entry in entry_analysis.get("entry_system_sgpr_roles", [])
                        if isinstance(entry, dict) and entry.get("role") == role_name
                    ),
                    None,
                )
                if role_sgpr is None:
                    raise SystemExit(f"entry-wrapper restore proof requires a {role_name} SGPR role")
                hidden_handoff_field_loads.append(
                    {
                        "name": role_name,
                        "offset": int(role_offset),
                        "kind": "u32",
                        "target_sgpr": int(role_sgpr),
                        "clobber_target_before_load": True,
                        "purpose": f"restore {role_name} from the wrapper-owned entry_snapshot storage",
                    }
                )
        if restore_all_system_sgprs_from_handoff:
            for role_name, role_offset in (
                ("workgroup_id_x", 8),
                ("workgroup_id_y", 12),
                ("workgroup_id_z", 16),
                ("private_segment_wave_offset", 20),
            ):
                role_sgpr = next(
                    (
                        int(entry.get("sgpr"))
                        for entry in entry_analysis.get("entry_system_sgpr_roles", [])
                        if isinstance(entry, dict) and entry.get("role") == role_name
                    ),
                    None,
                )
                if role_sgpr is None:
                    raise SystemExit(f"entry-wrapper restore proof requires a {role_name} SGPR role")
                hidden_handoff_field_loads.append(
                    {
                        "name": role_name,
                        "offset": int(role_offset),
                        "kind": "u32",
                        "target_sgpr": int(role_sgpr),
                        "clobber_target_before_load": True,
                        "purpose": f"restore {role_name} from the wrapper-owned entry_snapshot storage",
                    }
                )
        capture_roles: list[tuple[str, int]] = []
        if capture_workgroup_x_to_handoff:
            capture_roles.append(("workgroup_id_x", 8))
        if capture_workgroup_xyz_to_handoff:
            capture_roles.extend(
                [
                    ("workgroup_id_x", 8),
                    ("workgroup_id_y", 12),
                    ("workgroup_id_z", 16),
                ]
            )
        if capture_all_system_sgprs_to_handoff:
            capture_roles.extend(
                [
                    ("workgroup_id_x", 8),
                    ("workgroup_id_y", 12),
                    ("workgroup_id_z", 16),
                    ("private_segment_wave_offset", 20),
                ]
            )
        emitted_capture_roles: set[str] = set()
        for role_name, role_offset in capture_roles:
            if role_name in emitted_capture_roles:
                continue
            role_sgpr = next(
                (
                    int(entry.get("sgpr"))
                    for entry in entry_analysis.get("entry_system_sgpr_roles", [])
                    if isinstance(entry, dict) and entry.get("role") == role_name
                ),
                None,
            )
            if role_sgpr is None:
                raise SystemExit(f"entry-wrapper capture proof requires a {role_name} SGPR role")
            hidden_handoff_field_stores.append(
                {
                    "name": role_name,
                    "offset": int(role_offset),
                    "kind": "u32_from_sgpr",
                    "source_sgpr": int(role_sgpr),
                    "address_vgprs": [4, 5],
                    "data_vgpr": 6,
                    "purpose": f"capture {role_name} into the wrapper-owned entry_snapshot storage",
                }
            )
            emitted_capture_roles.add(role_name)
        hidden_handoff_field = {
            "name": "original_kernarg_pointer",
            "offset": 0,
            "kind": "u64",
            "purpose": (
                "restore the original kernarg base pair after wrapper-side clobber"
                if restore_kernarg_base_from_handoff
                else "prove wrapper-side dereference of the handoff struct payload"
            ),
        }
        if restore_kernarg_base_from_handoff:
            hidden_handoff_field["target_pair"] = [int(kernarg_base_pair[0]), int(kernarg_base_pair[1])]
            hidden_handoff_field["clobber_target_before_load"] = True
        hidden_handoff_field_loads.append(hidden_handoff_field)

        manifest_metadata = manifest.setdefault("kernels", {}).setdefault("metadata", {})
        source_identity = (source_kernel.get("name"), source_kernel.get("symbol"))
        mutated_kernels = []
        for kernel in manifest_metadata.get("kernels", []):
            if not isinstance(kernel, dict):
                mutated_kernels.append(kernel)
                continue
            identity = (kernel.get("name"), kernel.get("symbol"))
            if identity == source_identity:
                mutated_kernels.append(
                    mutate_kernel_record_in_place(kernel, hidden_handoff_plan)
                )
            else:
                mutated_kernels.append(deepcopy(kernel))
        manifest_metadata["kernels"] = mutated_kernels
        manifest_metadata["rendered"] = build_metadata_document_with_inplace_update(
            manifest,
            source_kernel=source_kernel,
            pointer_size=ENTRY_WRAPPER_HIDDEN_HANDOFF_POINTER_SIZE,
            alignment=ENTRY_WRAPPER_HIDDEN_HANDOFF_ALIGNMENT,
        )
        manifest_metadata["raw"] = manifest_metadata["rendered"]
        if metadata_output_format(manifest) == "msgpack":
            manifest_metadata["object"] = build_metadata_object_with_inplace_update(
                manifest,
                source_kernel=source_kernel,
                pointer_size=ENTRY_WRAPPER_HIDDEN_HANDOFF_POINTER_SIZE,
                alignment=ENTRY_WRAPPER_HIDDEN_HANDOFF_ALIGNMENT,
            )
        manifest["kernels"].pop("metadata_note", None)

        source_descriptor["kernarg_size"] = int(hidden_handoff_plan["instrumented_kernarg_length"])
        source_descriptor["bytes_hex"] = patch_descriptor_bytes_hex(
            str(source_descriptor.get("bytes_hex", "")),
            int(hidden_handoff_plan["instrumented_kernarg_length"]),
        )

    text_section = next(
        (section for section in manifest.get("sections", []) if section.get("name") == ".text"),
        None,
    )
    original_kernel_symbol = next(
        (entry for entry in manifest.get("kernels", {}).get("function_symbols", []) if entry.get("name") == kernel_name),
        None,
    )
    if original_kernel_symbol is None:
        raise SystemExit(f"kernel function symbol for {kernel_name!r} not found")

    rename_function_ir(ir, kernel_name, body_name)
    wrapper_address = wrapper_start_address(ir, manifest)
    wrapper_function = build_entry_wrapper_ir(
        wrapper_name=kernel_name,
        body_name=body_name,
        start_address=wrapper_address,
        scratch_pair=branch_scratch_pair,
        workitem_spill_restore_plan=workitem_spill_restore_plan,
        hidden_ctx_offset=hidden_ctx_offset,
        hidden_ctx_source_pair=(
            (int(kernarg_base_pair[0]), int(kernarg_base_pair[1]))
            if len(kernarg_base_pair) == 2
            else None
        ),
        hidden_handoff_field_loads=hidden_handoff_field_loads,
        hidden_handoff_field_stores=hidden_handoff_field_stores,
        hidden_handoff_store_before_loads=bool(
            restore_workgroup_xyz_from_handoff or restore_all_system_sgprs_from_handoff
        ),
    )
    ir.setdefault("functions", []).append(wrapper_function)

    renamed_all_symbols = rename_symbol(manifest["functions"]["all_symbols"], kernel_name, body_name)
    renamed_symbols = rename_symbol(manifest["symbols"], kernel_name, body_name)
    for entry in [*renamed_all_symbols, *renamed_symbols]:
        entry["binding"] = "Local"
        entry["visibility"] = []

    remove_symbol(manifest["kernels"]["function_symbols"], kernel_name)
    remove_symbol(manifest["functions"]["helper_symbols"], body_name)

    body_helper_symbol = next(
        (entry for entry in manifest["functions"]["all_symbols"] if entry.get("name") == body_name),
        None,
    )
    if body_helper_symbol is None:
        raise SystemExit(f"renamed body helper symbol {body_name!r} was not materialized")
    manifest["functions"]["helper_symbols"].append(deepcopy(body_helper_symbol))

    wrapper_symbol = build_text_function_symbol(
        original_kernel_symbol,
        name=kernel_name,
        value=wrapper_address,
        size=int(wrapper_function.get("end_address", wrapper_address) - wrapper_address),
        text_section=text_section,
    )
    manifest["functions"]["all_symbols"].append(deepcopy(wrapper_symbol))
    manifest["kernels"]["function_symbols"].append(deepcopy(wrapper_symbol))
    manifest["symbols"].append(deepcopy(wrapper_symbol))

    manifest.setdefault("descriptor_patch_intents", []).append(
        {
            "mode": "entry-wrapper-proof",
            "source_kernel": kernel_name,
            "clone_kernel": kernel_name,
            "clone_descriptor": str(source_descriptor.get("name") or f"{kernel_name}.kd"),
            "body_symbol": body_name,
            "wrapper_symbol": kernel_name,
            "descriptor_patch_policy": "patch-linked-entry-only",
        }
    )

    return {
        "mode": (
            "entry-wrapper-full-entry-abi-capture-restore-proof"
            if capture_restore_full_entry_abi
            else (
            "entry-wrapper-workitem-vgpr-capture-restore-proof"
            if capture_restore_entry_workitem_vgprs
            else (
            "entry-wrapper-system-sgpr-capture-restore-proof"
            if restore_all_system_sgprs_from_handoff
            else (
            "entry-wrapper-workgroup-xyz-capture-restore-proof"
            if restore_workgroup_xyz_from_handoff
            else (
            "entry-wrapper-workgroup-xyz-capture-proof"
            if capture_workgroup_xyz_to_handoff
            else (
            "entry-wrapper-workgroup-x-capture-proof"
            if capture_workgroup_x_to_handoff
            else (
            "entry-wrapper-workgroup-x-restore-proof"
            if restore_workgroup_x_from_handoff
            else (
            "entry-wrapper-kernarg-restore-proof"
            if restore_kernarg_base_from_handoff
            else ("entry-wrapper-hidden-handoff-proof" if include_hidden_handoff else "entry-wrapper-proof")
            )
            )
            )
            )
            )
            )
            )
        ),
        "source_kernel": kernel_name,
        "body_symbol": body_name,
        "wrapper_symbol": kernel_name,
        "wrapper_start_address": wrapper_address,
        "wrapper_size": int(wrapper_function.get("end_address", wrapper_address) - wrapper_address),
        "descriptor": str(source_descriptor.get("name") or f"{kernel_name}.kd"),
        "scratch_pair": list(branch_scratch_pair),
        "supported_class": entry_analysis.get("entry_wrapper_supported_class"),
        "entry_handoff_recipe": handoff_recipe,
        "preconditions": {
            "arch": str(ir.get("arch") or manifest.get("arch") or ""),
            "entry_overwrites": entry_analysis.get("entry_wrapper_entry_overwrites", []),
            "entry_livein_sgprs": entry_analysis.get("entry_livein_sgprs", []),
            "original_entry_start_address": int(original_function.get("start_address", 0) or 0),
            "secondary_scratch_pair": entry_analysis.get("entry_wrapper_secondary_scratch_pair"),
        },
        "workitem_spill_restore": (
            {
                "enabled": True,
                "source_vgprs": list(workitem_spill_restore_plan.get("source_vgprs", [])),
                "spill_offset": int(workitem_spill_restore_plan.get("spill_offset", 0) or 0),
                "spill_bytes": int(workitem_spill_restore_plan.get("spill_bytes", 0) or 0),
                "private_segment_growth": int(
                    workitem_spill_restore_plan.get("private_segment_growth", 0) or 0
                ),
                "save_pair": list(workitem_spill_restore_plan.get("save_pair", [])),
                "soffset_sgpr": int(workitem_spill_restore_plan.get("soffset_sgpr", 0) or 0),
                "private_segment_pattern_class": workitem_spill_restore_plan.get(
                    "private_segment_pattern_class"
                ),
                "private_segment_offset_source_sgpr": workitem_spill_restore_plan.get(
                    "private_segment_offset_source_sgpr"
                ),
            }
            if workitem_spill_restore_plan is not None
            else {"enabled": False}
        ),
        "wrapper_hidden_handoff": (
            {
                "enabled": True,
                "arg_name": str(hidden_handoff_plan["hidden_omniprobe_ctx"]["name"]),
                "arg_value_kind": str(hidden_handoff_plan["hidden_omniprobe_ctx"]["value_kind"]),
                "offset": int(hidden_handoff_plan["hidden_omniprobe_ctx"]["offset"]),
                "size": int(hidden_handoff_plan["hidden_omniprobe_ctx"]["size"]),
                "instrumented_kernarg_length": int(hidden_handoff_plan["instrumented_kernarg_length"]),
                "load_source_pair": [int(kernarg_base_pair[0]), int(kernarg_base_pair[1])],
                "pointer_load_opcode": "s_load_dwordx2",
                "consumed_fields": [
                    {
                        "name": str(field["name"]),
                        "offset": int(field["offset"]),
                        "kind": str(field["kind"]),
                        "load_opcode": "s_load_dwordx2" if field["kind"] == "u64" else "s_load_dword",
                        "target_pair": [int(field["target_pair"][0]), int(field["target_pair"][1])]
                        if isinstance(field.get("target_pair"), list) and len(field["target_pair"]) == 2
                        else None,
                        "target_sgpr": int(field["target_sgpr"]) if field.get("target_sgpr") is not None else None,
                        "clobber_target_before_load": bool(field.get("clobber_target_before_load", False)),
                    }
                    for field in hidden_handoff_field_loads
                ],
                "restored_actions": (
                    (
                        ([
                            "materialize-system-sgpr:workgroup_id_x",
                            "materialize-system-sgpr:workgroup_id_y",
                            "materialize-system-sgpr:workgroup_id_z",
                            "materialize-system-sgpr:private_segment_wave_offset",
                        ] if restore_all_system_sgprs_from_handoff else [])
                        +
                        ([
                            "materialize-system-sgpr:workgroup_id_x",
                            "materialize-system-sgpr:workgroup_id_y",
                            "materialize-system-sgpr:workgroup_id_z",
                        ] if restore_workgroup_xyz_from_handoff else [])
                        +
                        (["materialize-system-sgpr:workgroup_id_x"] if restore_workgroup_x_from_handoff else [])
                        + (["materialize-kernarg-base-pair"] if restore_kernarg_base_from_handoff else [])
                    )
                ),
                "captured_entry_snapshot_fields": [
                    {
                        "name": str(field["name"]),
                        "offset": int(field["offset"]),
                        "kind": str(field["kind"]),
                        "store_opcode": "flat_store_dword",
                        "source_sgpr": int(field["source_sgpr"]),
                        "address_vgprs": [int(field["address_vgprs"][0]), int(field["address_vgprs"][1])],
                        "data_vgpr": int(field["data_vgpr"]),
                    }
                    for field in hidden_handoff_field_stores
                ],
            }
            if hidden_handoff_plan is not None
            else {"enabled": False}
        ),
    }


def build_manifest(
    *,
    input_path: Path,
    manifest_path: Path,
    args: argparse.Namespace,
    tool_dir: Path,
) -> None:
    inspect_tool = tool_dir / "inspect_code_object.py"
    command = [
        args.python,
        str(inspect_tool),
        str(input_path),
        "--output",
        str(manifest_path),
    ]
    if args.llvm_readelf:
        command.extend(["--llvm-readelf", args.llvm_readelf])
    run(command)


def build_ir(
    *,
    input_path: Path,
    manifest_path: Path,
    ir_path: Path,
    args: argparse.Namespace,
    tool_dir: Path,
) -> None:
    disasm_tool = tool_dir / "disasm_to_ir.py"
    command = [
        args.python,
        str(disasm_tool),
        str(input_path),
        "--manifest",
        str(manifest_path),
        "--output",
        str(ir_path),
    ]
    if args.llvm_objdump:
        command.extend(["--llvm-objdump", args.llvm_objdump])
    run(command)


def rebuild(
    *,
    ir_path: Path,
    manifest_path: Path,
    output_path: Path,
    asm_path: Path,
    obj_path: Path,
    rebuild_report_path: Path,
    kernel_name: str | None,
    extra_objects: list[Path],
    args: argparse.Namespace,
    tool_dir: Path,
) -> None:
    rebuild_tool = tool_dir / "rebuild_code_object.py"
    command = [
        args.python,
        str(rebuild_tool),
        str(ir_path),
        str(manifest_path),
        "--mode",
        args.mode,
        "--output",
        str(output_path),
        "--asm-output",
        str(asm_path),
        "--object-output",
        str(obj_path),
        "--report-output",
        str(rebuild_report_path),
    ]
    if kernel_name:
        command.extend(["--function", kernel_name])
    for extra_object in extra_objects:
        command.extend(["--extra-object", str(extra_object)])
    if args.llvm_mc:
        command.extend(["--llvm-mc", args.llvm_mc])
    if args.ld_lld:
        command.extend(["--ld-lld", args.ld_lld])
    run(command)


def compile_probe_support_object(
    *,
    thunk_manifest_path: Path,
    arch: str,
    output_path: Path,
    args: argparse.Namespace,
    tool_dir: Path,
) -> None:
    compile_tool = tool_dir / "compile_binary_probe_support.py"
    command = [
        args.python,
        str(compile_tool),
        "--thunk-manifest",
        str(thunk_manifest_path),
        "--output",
        str(output_path),
        "--arch",
        arch,
    ]
    if args.hipcc:
        command.extend(["--hipcc", args.hipcc])
    if args.clang_offload_bundler:
        command.extend(["--clang-offload-bundler", args.clang_offload_bundler])
    run(command)


def inspect_probe_support_wrapper_footprint(
    *,
    thunk_manifest_path: Path,
    arch: str,
    temp_dir: Path,
    args: argparse.Namespace,
    tool_dir: Path,
) -> dict[str, int]:
    thunk_manifest = load_json(thunk_manifest_path)
    thunk_source_value = thunk_manifest.get("thunk_source")
    if not isinstance(thunk_source_value, str) or not thunk_source_value:
        raise SystemExit(f"thunk manifest {thunk_manifest_path} does not contain thunk_source")
    thunk_source = Path(thunk_source_value).resolve()
    thunks = thunk_manifest.get("thunks", [])
    if not isinstance(thunks, list) or not thunks:
        return {}

    wrapper_source = temp_dir / "binary_probe_support_wrapper.hip"
    wrapper_hsaco = temp_dir / "binary_probe_support_wrapper.hsaco"
    wrapper_manifest = temp_dir / "binary_probe_support_wrapper.manifest.json"

    lines = [
        "#include <stdint.h>",
        "#include <hip/hip_runtime.h>",
        f'#include "{thunk_source}"',
        "",
    ]
    for index, thunk in enumerate(thunks):
        thunk_name = str(thunk.get("thunk", "") or "")
        call_arguments = thunk.get("call_arguments", [])
        if not thunk_name or not isinstance(call_arguments, list):
            continue
        arg_decls: list[str] = []
        arg_names: list[str] = []
        for arg_index, entry in enumerate(call_arguments):
            if not isinstance(entry, dict):
                continue
            c_type = str(entry.get("c_type", "") or "").strip()
            name = str(entry.get("name", "") or "").strip() or f"arg_{arg_index}"
            if not c_type:
                raise SystemExit(
                    f"thunk manifest {thunk_manifest_path} is missing c_type for {thunk_name!r} argument {name!r}"
                )
            arg_decls.append(f"{c_type} {name}")
            arg_names.append(name)
        wrapper_name = f"__omniprobe_support_wrapper_{index}"
        lines.extend(
            [
                f'extern "C" __global__ void {wrapper_name}({", ".join(arg_decls)}) {{',
                f"  {thunk_name}({', '.join(arg_names)});",
                "}",
                "",
            ]
        )

    wrapper_source.write_text("\n".join(lines), encoding="utf-8")

    repo_root = tool_dir.parent.parent
    hipcc = args.hipcc or str(Path("/opt/rocm/bin/hipcc"))
    run(
        [
            hipcc,
            "-x",
            "hip",
            "--offload-device-only",
            "--no-gpu-bundle-output",
            f"--offload-arch={arch}",
            "-I",
            str(repo_root / "external/dh_comms/include"),
            "-I",
            str(repo_root / "inc"),
            "-I",
            str(thunk_source.parent),
            "-o",
            str(wrapper_hsaco),
            str(wrapper_source),
        ]
    )
    run(
        [
            args.python,
            str(tool_dir / "inspect_code_object.py"),
            str(wrapper_hsaco),
            "--output",
            str(wrapper_manifest),
        ]
    )

    manifest_payload = load_json(wrapper_manifest)
    footprint: dict[str, int] = {}
    footprint["abi_requirements"] = collect_wrapper_abi_requirements(manifest_payload)
    for kernel in manifest_payload.get("kernels", {}).get("metadata", {}).get("kernels", []):
        if not isinstance(kernel, dict):
            continue
        name = str(kernel.get("name", "") or "")
        if not name.startswith("__omniprobe_support_wrapper_") and name != "__omniprobe_support_wrapper":
            continue
        footprint["total_sgprs"] = max(
            int(footprint.get("total_sgprs", 0) or 0),
            int(kernel.get("sgpr_count", 0) or 0),
        )
        footprint["total_vgprs"] = max(
            int(footprint.get("total_vgprs", 0) or 0),
            int(kernel.get("vgpr_count", 0) or 0),
        )
        footprint["private_segment_fixed_size"] = max(
            int(footprint.get("private_segment_fixed_size", 0) or 0),
            int(kernel.get("private_segment_fixed_size", 0) or 0),
        )
    return footprint


REGISTER_PAIR_RE = re.compile(r"([vs])\[(\d+):(\d+)\]")
REGISTER_SINGLE_RE = re.compile(r"([vs])(\d+)")

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


def descriptor_field_value(descriptor: dict, section: str, field: str) -> int:
    section_obj = descriptor.get(section, {})
    if not isinstance(section_obj, dict):
        return 0
    return int(section_obj.get(field, 0) or 0)


def collect_wrapper_abi_requirements(manifest_payload: dict) -> dict[str, dict[str, int]]:
    descriptors = manifest_payload.get("kernels", {}).get("descriptors", [])
    requirements = {
        "compute_pgm_rsrc2": {field: 0 for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS},
        "kernel_code_properties": {field: 0 for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS},
    }
    requirements["compute_pgm_rsrc2"]["enable_vgpr_workitem_id"] = 0
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            continue
        kernel_name = str(descriptor.get("kernel_name", "") or "")
        if not kernel_name.startswith("__omniprobe_support_wrapper_") and kernel_name != "__omniprobe_support_wrapper":
            continue
        for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS:
            requirements["compute_pgm_rsrc2"][field] = max(
                requirements["compute_pgm_rsrc2"][field],
                descriptor_field_value(descriptor, "compute_pgm_rsrc2", field),
            )
        requirements["compute_pgm_rsrc2"]["enable_vgpr_workitem_id"] = max(
            requirements["compute_pgm_rsrc2"]["enable_vgpr_workitem_id"],
            descriptor_field_value(descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"),
        )
        for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS:
            requirements["kernel_code_properties"][field] = max(
                requirements["kernel_code_properties"][field],
                descriptor_field_value(descriptor, "kernel_code_properties", field),
            )
    return requirements


def collect_support_wrapper_abi_delta(
    *,
    source_descriptor: dict,
    support_wrapper_footprint: dict[str, int],
) -> dict:
    requirements = support_wrapper_footprint.get("abi_requirements")
    delta = {
        "source_descriptor_features": {
            "compute_pgm_rsrc2": {},
            "kernel_code_properties": {},
        },
        "required_wrapper_features": requirements if isinstance(requirements, dict) else {},
        "missing_features": [],
    }
    if not isinstance(requirements, dict):
        return delta

    rsrc2_requirements = requirements.get("compute_pgm_rsrc2", {})
    if isinstance(rsrc2_requirements, dict):
        for field in ABI_SENSITIVE_RSRC2_BOOL_FIELDS:
            available = descriptor_field_value(source_descriptor, "compute_pgm_rsrc2", field)
            required = int(rsrc2_requirements.get(field, 0) or 0)
            delta["source_descriptor_features"]["compute_pgm_rsrc2"][field] = available
            if required and not available:
                delta["missing_features"].append(
                    {
                        "field": f"compute_pgm_rsrc2.{field}",
                        "required": 1,
                        "available": available,
                    }
                )
        available_workitem_id = descriptor_field_value(
            source_descriptor, "compute_pgm_rsrc2", "enable_vgpr_workitem_id"
        )
        required_workitem_id = int(rsrc2_requirements.get("enable_vgpr_workitem_id", 0) or 0)
        delta["source_descriptor_features"]["compute_pgm_rsrc2"][
            "enable_vgpr_workitem_id"
        ] = available_workitem_id
        if required_workitem_id > available_workitem_id:
            delta["missing_features"].append(
                {
                    "field": "compute_pgm_rsrc2.enable_vgpr_workitem_id",
                    "required": required_workitem_id,
                    "available": available_workitem_id,
                }
            )

    kernel_code_requirements = requirements.get("kernel_code_properties", {})
    if isinstance(kernel_code_requirements, dict):
        for field in ABI_SENSITIVE_KERNEL_CODE_BOOL_FIELDS:
            available = descriptor_field_value(source_descriptor, "kernel_code_properties", field)
            required = int(kernel_code_requirements.get(field, 0) or 0)
            delta["source_descriptor_features"]["kernel_code_properties"][field] = available
            if required and not available:
                delta["missing_features"].append(
                    {
                        "field": f"kernel_code_properties.{field}",
                        "required": 1,
                        "available": available,
                    }
                )
    return delta


def format_support_wrapper_abi_incompatibility(*, clone_kernel: str, abi_delta: dict) -> str:
    failures = abi_delta.get("missing_features", []) if isinstance(abi_delta, dict) else []
    failure_text = "; ".join(
        f"{entry.get('field')} requires {entry.get('required')} but source descriptor provides {entry.get('available')}"
        for entry in failures
        if isinstance(entry, dict)
    )
    return (
        "binary probe support wrapper requires initial-kernel ABI state that "
        f"clone {clone_kernel!r} does not provide: {failure_text}. "
        "This helper must be simplified or compiled against a contract that "
        "does not request additional kernel-entry system registers."
    )


def resolve_llvm_objdump() -> str:
    discovered = shutil.which("llvm-objdump")
    if discovered:
        return discovered
    rocm_candidate = Path("/opt/rocm/llvm/bin/llvm-objdump")
    if rocm_candidate.exists():
        return str(rocm_candidate)
    raise SystemExit("llvm-objdump is required to inspect binary probe support register usage")


def inspect_amdgpu_object_register_footprint(object_path: Path) -> dict[str, int]:
    command = [resolve_llvm_objdump(), "-d", str(object_path)]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    max_vgpr = -1
    max_sgpr = -1
    for line in completed.stdout.splitlines():
        for match in REGISTER_PAIR_RE.finditer(line):
            kind = match.group(1)
            end = int(match.group(3))
            if kind == "v":
                max_vgpr = max(max_vgpr, end)
            else:
                max_sgpr = max(max_sgpr, end)
        for match in REGISTER_SINGLE_RE.finditer(line):
            kind = match.group(1)
            value = int(match.group(2))
            if kind == "v":
                max_vgpr = max(max_vgpr, value)
            else:
                max_sgpr = max(max_sgpr, value)
    footprint: dict[str, int] = {}
    if max_vgpr >= 0:
        footprint["total_vgprs"] = max_vgpr + 1
    if max_sgpr >= 0:
        footprint["total_sgprs"] = max_sgpr + 1
    return footprint


def patch_output_metadata_note(output_path: Path, manifest: dict) -> None:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    metadata_obj = metadata.get("object")
    if isinstance(metadata_obj, dict):
        metadata_bytes = packb(metadata_obj)
    else:
        rendered = metadata.get("raw") or metadata.get("rendered")
        if not rendered:
            return
        metadata_bytes = str(rendered).encode("utf-8")

    data, sections, section_map = note_rewriter.load_sections(output_path)
    data, _sections, _section_map = note_rewriter.replace_metadata_note(
        data,
        sections,
        section_map,
        metadata_bytes,
        allow_grow=True,
    )
    output_path.write_bytes(data)


def find_descriptor(manifest: dict, descriptor_name: str) -> dict:
    for descriptor in manifest.get("kernels", {}).get("descriptors", []):
        if descriptor.get("name") == descriptor_name:
            return descriptor
    raise SystemExit(f"descriptor {descriptor_name!r} not found in manifest")


def find_symbol(records: list[dict], name: str) -> dict:
    for record in records:
        if record.get("name") == name:
            return record
    raise SystemExit(f"symbol {name!r} not found in manifest")


def materialize_descriptor_bytes(descriptor: dict, entry_offset: int) -> bytes:
    raw_hex = str(descriptor.get("bytes_hex", ""))
    payload = bytearray.fromhex(raw_hex) if raw_hex else bytearray(64)
    expected_size = int(descriptor.get("size", 64) or 64)
    if len(payload) < expected_size:
        payload.extend(b"\x00" * (expected_size - len(payload)))
    elif len(payload) > expected_size:
        payload = payload[:expected_size]

    struct.pack_into("<I", payload, 0, int(descriptor.get("group_segment_fixed_size", 0) or 0))
    struct.pack_into("<I", payload, 4, int(descriptor.get("private_segment_fixed_size", 0) or 0))
    struct.pack_into("<I", payload, 8, int(descriptor.get("kernarg_size", 0) or 0))
    struct.pack_into("<q", payload, 16, int(entry_offset))
    struct.pack_into(
        "<I",
        payload,
        44,
        int(descriptor.get("compute_pgm_rsrc3", {}).get("raw_value", 0) or 0),
    )
    struct.pack_into(
        "<I",
        payload,
        48,
        int(descriptor.get("compute_pgm_rsrc1", {}).get("raw_value", 0) or 0),
    )
    struct.pack_into(
        "<I",
        payload,
        52,
        int(descriptor.get("compute_pgm_rsrc2", {}).get("raw_value", 0) or 0),
    )
    struct.pack_into(
        "<I",
        payload,
        56,
        int(descriptor.get("kernel_code_properties", {}).get("raw_value", 0) or 0),
    )
    return bytes(payload)


def patch_output_clone_descriptors(
    *,
    output_path: Path,
    manifest: dict,
    args: argparse.Namespace,
    tool_dir: Path,
    temp_dir_path: Path,
) -> None:
    clone_intents = manifest.get("clone_intents", [])
    descriptor_patch_intents = manifest.get("descriptor_patch_intents", [])
    intents = []
    if isinstance(clone_intents, list):
        intents.extend(clone_intents)
    if isinstance(descriptor_patch_intents, list):
        intents.extend(descriptor_patch_intents)
    if not intents:
        return

    inspect_tool = tool_dir / "inspect_code_object.py"
    output_manifest_path = temp_dir_path / "output.manifest.json"
    command = [
        args.python,
        str(inspect_tool),
        str(output_path),
        "--output",
        str(output_manifest_path),
    ]
    if args.llvm_readelf:
        command.extend(["--llvm-readelf", args.llvm_readelf])
    run(command)

    output_manifest = load_json(output_manifest_path)
    output_descriptor_symbols = output_manifest.get("kernels", {}).get("descriptor_symbols", [])
    output_function_symbols = output_manifest.get("kernels", {}).get("function_symbols", [])
    data = bytearray(output_path.read_bytes())

    for intent in intents:
        if not isinstance(intent, dict):
            continue
        clone_kernel = intent.get("clone_kernel")
        clone_descriptor_name = intent.get("clone_descriptor")
        if not isinstance(clone_kernel, str) or not isinstance(clone_descriptor_name, str):
            continue

        source_descriptor = find_descriptor(manifest, clone_descriptor_name)
        output_descriptor = find_descriptor(output_manifest, clone_descriptor_name)
        output_descriptor_symbol = find_symbol(output_descriptor_symbols, clone_descriptor_name)
        output_function_symbol = find_symbol(output_function_symbols, clone_kernel)

        descriptor_bytes = bytearray(
            materialize_descriptor_bytes(source_descriptor, entry_offset=0)
        )
        entry_offset = int(output_function_symbol.get("value", 0)) - int(
            output_descriptor_symbol.get("value", 0)
        )
        struct.pack_into("<Q", descriptor_bytes, 16, entry_offset)

        file_offset = int(output_descriptor.get("file_offset", -1))
        if file_offset < 0:
            raise SystemExit(f"output descriptor {clone_descriptor_name!r} is missing file_offset")
        expected_size = int(output_descriptor.get("size", 0))
        if expected_size and len(descriptor_bytes) != expected_size:
            raise SystemExit(
                f"descriptor size mismatch for {clone_descriptor_name!r}: "
                f"{len(descriptor_bytes)} != {expected_size}"
            )
        data[file_offset : file_offset + len(descriptor_bytes)] = descriptor_bytes

    output_path.write_bytes(data)


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()
    report_path = Path(args.report_output).resolve() if args.report_output else None
    tool_dir = Path(__file__).resolve().parent

    temp_dir_path: Path | None = None
    cleanup_dir: tempfile.TemporaryDirectory[str] | None = None
    if args.keep_temp_dir:
        temp_dir_path = output_path.parent / f".{output_path.name}.regen"
        temp_dir_path.mkdir(parents=True, exist_ok=True)
    else:
        cleanup_dir = tempfile.TemporaryDirectory(prefix="omniprobe_regen_")
        temp_dir_path = Path(cleanup_dir.name)

    try:
        if args.manifest:
            manifest_path = Path(args.manifest).resolve()
            working_manifest_path = temp_dir_path / "input.manifest.json"
            if manifest_path != working_manifest_path:
                shutil.copyfile(manifest_path, working_manifest_path)
            else:
                working_manifest_path = manifest_path
        else:
            working_manifest_path = temp_dir_path / "input.manifest.json"
            build_manifest(
                input_path=input_path,
                manifest_path=working_manifest_path,
                args=args,
                tool_dir=tool_dir,
            )

        model = CodeObjectModel.from_manifest(load_json(working_manifest_path))
        kernel_name, primary_kernel_count = choose_kernel(model, args.kernel)
        clone_result = None
        entry_wrapper_result = None
        extra_link_objects: list[Path] = []
        binary_probe_mode: str | None = None
        binary_probe_abi_delta: dict | None = None
        support_wrapper_footprint_report: dict | None = None
        support_object_footprint_report: dict | None = None
        mutation_modes = [
            bool(args.add_hidden_abi_clone),
            bool(args.add_noop_clone),
            bool(args.add_entry_wrapper_proof),
            bool(args.add_entry_wrapper_hidden_handoff_proof),
            bool(args.add_entry_wrapper_kernarg_restore_proof),
            bool(args.add_entry_wrapper_workgroup_x_restore_proof),
            bool(args.add_entry_wrapper_workgroup_x_capture_proof),
            bool(args.add_entry_wrapper_workgroup_xyz_capture_proof),
            bool(args.add_entry_wrapper_workgroup_xyz_capture_restore_proof),
            bool(args.add_entry_wrapper_system_sgpr_capture_restore_proof),
            bool(args.add_entry_wrapper_workitem_vgpr_capture_restore_proof),
            bool(args.add_entry_wrapper_full_entry_abi_capture_restore_proof),
        ]
        if sum(1 for enabled in mutation_modes if enabled) > 1:
            raise SystemExit(
                "choose at most one mutation mode: "
                "--add-hidden-abi-clone, --add-noop-clone, --add-entry-wrapper-proof, "
                "--add-entry-wrapper-hidden-handoff-proof, or "
                "--add-entry-wrapper-kernarg-restore-proof, or "
                "--add-entry-wrapper-workgroup-x-restore-proof, or "
                "--add-entry-wrapper-workgroup-x-capture-proof, or "
                "--add-entry-wrapper-workgroup-xyz-capture-proof, or "
                "--add-entry-wrapper-workgroup-xyz-capture-restore-proof, or "
                "--add-entry-wrapper-system-sgpr-capture-restore-proof, or "
                "--add-entry-wrapper-workitem-vgpr-capture-restore-proof, or "
                "--add-entry-wrapper-full-entry-abi-capture-restore-proof"
            )

        ir_path = temp_dir_path / "input.ir.json"
        asm_path = temp_dir_path / "output.s"
        obj_path = temp_dir_path / "output.o"
        rebuild_report_path = temp_dir_path / "rebuild.report.json"
        asm_manifest_path = working_manifest_path
        build_ir(
            input_path=input_path,
            manifest_path=working_manifest_path,
            ir_path=ir_path,
            args=args,
            tool_dir=tool_dir,
        )
        if args.add_entry_wrapper_proof:
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_hidden_handoff_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_kernarg_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_workgroup_x_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                restore_workgroup_x_from_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_workgroup_x_capture_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                capture_workgroup_x_to_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_workgroup_xyz_capture_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                capture_workgroup_xyz_to_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_workgroup_xyz_capture_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                restore_workgroup_xyz_from_handoff=True,
                capture_workgroup_xyz_to_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_system_sgpr_capture_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                restore_all_system_sgprs_from_handoff=True,
                capture_all_system_sgprs_to_handoff=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_workitem_vgpr_capture_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                capture_restore_entry_workitem_vgprs=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_entry_wrapper_full_entry_abi_capture_restore_proof:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            entry_wrapper_result = add_entry_wrapper_proof_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
                include_hidden_handoff=True,
                restore_kernarg_base_from_handoff=True,
                restore_all_system_sgprs_from_handoff=True,
                capture_all_system_sgprs_to_handoff=True,
                capture_restore_entry_workitem_vgprs=True,
                capture_restore_full_entry_abi=True,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        elif args.add_hidden_abi_clone:
            original_manifest_payload = load_json(working_manifest_path)
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            clone_result = add_hidden_abi_clone_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            asm_manifest_payload = deepcopy(manifest_payload)
            asm_manifest_metadata = asm_manifest_payload.setdefault("kernels", {}).setdefault(
                "metadata", {}
            )
            original_metadata = original_manifest_payload.get("kernels", {}).get("metadata", {})
            for key in ("raw", "rendered", "object", "target"):
                if key in original_metadata:
                    asm_manifest_metadata[key] = deepcopy(original_metadata[key])
                else:
                    asm_manifest_metadata.pop(key, None)
            asm_manifest_path = temp_dir_path / "input.asm.manifest.json"
            asm_manifest_path.write_text(
                json.dumps(asm_manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            if bool(args.probe_plan) != bool(args.thunk_manifest):
                raise SystemExit("--probe-plan and --thunk-manifest must be provided together")
            if args.probe_plan and args.thunk_manifest:
                reject_unsupported_binary_probe_sites(
                    load_json(Path(args.probe_plan).resolve()),
                    kernel_name=kernel_name,
                )
                inject_tool = tool_dir / "inject_probe_calls.py"
                inject_command = [
                    args.python,
                    str(inject_tool),
                    str(ir_path),
                    "--plan",
                    str(Path(args.probe_plan).resolve()),
                    "--thunk-manifest",
                    str(Path(args.thunk_manifest).resolve()),
                    "--manifest",
                    str(working_manifest_path),
                    "--function",
                    str(clone_result["clone_kernel"]),
                    "--output",
                    str(ir_path),
                ]
                run(inject_command)
                injected_ir_payload = load_json(ir_path)
                injected_function = next(
                    (
                        entry
                        for entry in injected_ir_payload.get("functions", [])
                        if entry.get("name") == clone_result["clone_kernel"]
                    ),
                    None,
                )
                instrumentation_map = (injected_function or {}).get("instrumentation", {})
                instrumentation = (
                    instrumentation_map.get("basic_block_stubs")
                    or instrumentation_map.get("memory_op_stubs")
                    or instrumentation_map.get("lifecycle_entry_stub")
                    or instrumentation_map.get("lifecycle_exit_stub", {})
                )
                total_probe_sgprs = int(instrumentation.get("total_sgprs", 0) or 0)
                total_probe_vgprs = int(instrumentation.get("total_vgprs", 0) or 0)
                private_segment_growth = int(instrumentation.get("private_segment_growth", 0) or 0)
                lifecycle_when = str(instrumentation.get("when", "") or "")
                instrumentation_mode = str(instrumentation.get("mode", "") or "")
                for intent in manifest_payload.get("clone_intents", []):
                    if not isinstance(intent, dict):
                        continue
                    if intent.get("clone_kernel") == clone_result["clone_kernel"]:
                        if instrumentation_mode == "basic_block":
                            intent["mode"] = "hidden-abi-basic-block-clone"
                        elif instrumentation_mode == "memory_op":
                            intent["mode"] = "hidden-abi-memory-op-clone"
                        elif lifecycle_when:
                            intent["mode"] = f"hidden-abi-lifecycle-{lifecycle_when}-clone"
                        else:
                            intent["mode"] = "hidden-abi-probe-clone"
                        if private_segment_growth:
                            intent["nonleaf_private_segment_growth"] = private_segment_growth
                        if total_probe_sgprs:
                            intent["probe_total_sgprs"] = total_probe_sgprs
                        if total_probe_vgprs:
                            intent["probe_total_vgprs"] = total_probe_vgprs
                        break
                if private_segment_growth:
                    apply_binary_probe_nonleaf_policy(
                        manifest_payload,
                        clone_kernel=str(clone_result["clone_kernel"]),
                        private_segment_growth=private_segment_growth,
                    )
                if total_probe_sgprs:
                    apply_binary_probe_saved_sgpr_policy(
                        manifest_payload,
                        clone_kernel=str(clone_result["clone_kernel"]),
                        total_sgprs=total_probe_sgprs,
                    )
                if total_probe_vgprs:
                    apply_binary_probe_vgpr_policy(
                        manifest_payload,
                        clone_kernel=str(clone_result["clone_kernel"]),
                        total_vgprs=total_probe_vgprs,
                    )
                if asm_manifest_path != working_manifest_path and asm_manifest_path.exists():
                    asm_manifest_payload_updated = load_json(asm_manifest_path)
                    if private_segment_growth:
                        apply_binary_probe_nonleaf_policy(
                            asm_manifest_payload_updated,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            private_segment_growth=private_segment_growth,
                            refresh_rendered_metadata=False,
                        )
                    if total_probe_sgprs:
                        apply_binary_probe_saved_sgpr_policy(
                            asm_manifest_payload_updated,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            total_sgprs=total_probe_sgprs,
                            refresh_rendered_metadata=False,
                        )
                    if total_probe_vgprs:
                        apply_binary_probe_vgpr_policy(
                            asm_manifest_payload_updated,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            total_vgprs=total_probe_vgprs,
                            refresh_rendered_metadata=False,
                        )
                    asm_manifest_path.write_text(
                        json.dumps(asm_manifest_payload_updated, indent=2) + "\n",
                        encoding="utf-8",
                    )
                working_manifest_path.write_text(
                    json.dumps(manifest_payload, indent=2) + "\n",
                    encoding="utf-8",
                )
                if args.probe_support_object:
                    extra_link_objects.append(Path(args.probe_support_object).resolve())
                else:
                    ir_payload_for_arch = load_json(ir_path)
                    arch = ir_payload_for_arch.get("arch")
                    if not isinstance(arch, str) or not arch:
                        raise SystemExit("IR arch is required to compile binary probe support")
                    support_object_path = temp_dir_path / "binary_probe_support.o"
                    compile_probe_support_object(
                        thunk_manifest_path=Path(args.thunk_manifest).resolve(),
                        arch=arch,
                        output_path=support_object_path,
                        args=args,
                        tool_dir=tool_dir,
                    )
                    support_footprint = inspect_amdgpu_object_register_footprint(support_object_path)
                    support_wrapper_footprint = inspect_probe_support_wrapper_footprint(
                        thunk_manifest_path=Path(args.thunk_manifest).resolve(),
                        arch=arch,
                        temp_dir=temp_dir_path,
                        args=args,
                        tool_dir=tool_dir,
                    )
                    support_object_footprint_report = deepcopy(support_footprint)
                    support_wrapper_footprint_report = deepcopy(support_wrapper_footprint)
                    binary_probe_abi_delta = collect_support_wrapper_abi_delta(
                        source_descriptor=find_descriptor(
                            manifest_payload,
                            str(clone_result["clone_descriptor"]),
                        ),
                        support_wrapper_footprint=support_wrapper_footprint,
                    )
                    binary_probe_mode = (
                        "binary-safe"
                        if not binary_probe_abi_delta.get("missing_features")
                        else "abi-changing-required"
                    )
                    if binary_probe_mode != "binary-safe":
                        if report_path is not None:
                            partial_report = {
                                "operation": "whole-object-regeneration-scaffold",
                                "scope": "single-kernel-noop",
                                "input_code_object": str(input_path),
                                "output_code_object": str(output_path),
                                "mode": args.mode,
                                "kernel_name": kernel_name,
                                "kernel_count": len(model.kernel_names()),
                                "primary_kernel_count": primary_kernel_count,
                                "manifest": str(working_manifest_path),
                                "asm_manifest": str(asm_manifest_path),
                                "ir": str(ir_path),
                                "asm": str(asm_path),
                                "object": str(obj_path),
                                "rebuild_report": str(rebuild_report_path),
                                "temp_dir": str(temp_dir_path),
                                "clone_result": clone_result,
                                "binary_probe": {
                                    "instrumentation_mode": binary_probe_mode,
                                    "support_object_footprint": support_object_footprint_report,
                                    "support_wrapper_footprint": support_wrapper_footprint_report,
                                    "abi_delta": binary_probe_abi_delta,
                                },
                            }
                            report_path.write_text(
                                json.dumps(partial_report, indent=2) + "\n", encoding="utf-8"
                            )
                        raise SystemExit(
                            format_support_wrapper_abi_incompatibility(
                                clone_kernel=str(clone_result["clone_kernel"]),
                                abi_delta=binary_probe_abi_delta,
                            )
                        )
                    total_probe_sgprs = max(
                        total_probe_sgprs,
                        int(support_footprint.get("total_sgprs", 0) or 0),
                        int(support_wrapper_footprint.get("total_sgprs", 0) or 0),
                    )
                    total_probe_vgprs = max(
                        total_probe_vgprs,
                        int(support_footprint.get("total_vgprs", 0) or 0),
                        int(support_wrapper_footprint.get("total_vgprs", 0) or 0),
                    )
                    support_private_segment = int(
                        support_wrapper_footprint.get("private_segment_fixed_size", 0) or 0
                    )
                    if support_private_segment:
                        apply_binary_probe_nonleaf_policy(
                            manifest_payload,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            private_segment_growth=support_private_segment,
                        )
                    if total_probe_sgprs:
                        apply_binary_probe_saved_sgpr_policy(
                            manifest_payload,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            total_sgprs=total_probe_sgprs,
                        )
                    if total_probe_vgprs:
                        apply_binary_probe_vgpr_policy(
                            manifest_payload,
                            clone_kernel=str(clone_result["clone_kernel"]),
                            total_vgprs=total_probe_vgprs,
                        )
                    if asm_manifest_path != working_manifest_path and asm_manifest_path.exists():
                        asm_manifest_payload_updated = load_json(asm_manifest_path)
                        if support_private_segment:
                            apply_binary_probe_nonleaf_policy(
                                asm_manifest_payload_updated,
                                clone_kernel=str(clone_result["clone_kernel"]),
                                private_segment_growth=support_private_segment,
                                refresh_rendered_metadata=False,
                            )
                        if total_probe_sgprs:
                            apply_binary_probe_saved_sgpr_policy(
                                asm_manifest_payload_updated,
                                clone_kernel=str(clone_result["clone_kernel"]),
                                total_sgprs=total_probe_sgprs,
                                refresh_rendered_metadata=False,
                            )
                        if total_probe_vgprs:
                            apply_binary_probe_vgpr_policy(
                                asm_manifest_payload_updated,
                                clone_kernel=str(clone_result["clone_kernel"]),
                                total_vgprs=total_probe_vgprs,
                                refresh_rendered_metadata=False,
                            )
                        asm_manifest_path.write_text(
                            json.dumps(asm_manifest_payload_updated, indent=2) + "\n",
                            encoding="utf-8",
                        )
                    for intent in manifest_payload.get("clone_intents", []):
                        if not isinstance(intent, dict):
                            continue
                        if intent.get("clone_kernel") != clone_result["clone_kernel"]:
                            continue
                        if total_probe_sgprs:
                            intent["probe_total_sgprs"] = total_probe_sgprs
                        if total_probe_vgprs:
                            intent["probe_total_vgprs"] = total_probe_vgprs
                        if support_private_segment:
                            intent["nonleaf_private_segment_growth"] = int(
                                intent.get("nonleaf_private_segment_growth", 0) or 0
                            ) + support_private_segment
                        break
                    working_manifest_path.write_text(
                        json.dumps(manifest_payload, indent=2) + "\n",
                        encoding="utf-8",
                    )
                    extra_link_objects.append(support_object_path)
        elif args.add_noop_clone:
            manifest_payload = load_json(working_manifest_path)
            ir_payload = load_json(ir_path)
            clone_result = add_noop_clone_intent(
                manifest_payload,
                ir_payload,
                model,
                kernel_name,
            )
            working_manifest_path.write_text(
                json.dumps(manifest_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            ir_path.write_text(
                json.dumps(ir_payload, indent=2) + "\n",
                encoding="utf-8",
            )
        rebuild_function_name = kernel_name if primary_kernel_count == 1 else None
        rebuild(
            ir_path=ir_path,
            manifest_path=asm_manifest_path,
            output_path=output_path,
            asm_path=asm_path,
            obj_path=obj_path,
            rebuild_report_path=rebuild_report_path,
            kernel_name=rebuild_function_name,
            extra_objects=extra_link_objects,
            args=args,
            tool_dir=tool_dir,
        )
        if (
            args.add_hidden_abi_clone
            or args.add_entry_wrapper_hidden_handoff_proof
            or args.add_entry_wrapper_kernarg_restore_proof
            or args.add_entry_wrapper_workgroup_x_restore_proof
            or args.add_entry_wrapper_workgroup_x_capture_proof
            or args.add_entry_wrapper_workgroup_xyz_capture_proof
            or args.add_entry_wrapper_workgroup_xyz_capture_restore_proof
            or args.add_entry_wrapper_system_sgpr_capture_restore_proof
            or args.add_entry_wrapper_workitem_vgpr_capture_restore_proof
            or args.add_entry_wrapper_full_entry_abi_capture_restore_proof
        ):
            patch_output_metadata_note(output_path, load_json(working_manifest_path))
        if clone_result is not None or entry_wrapper_result is not None:
            patch_output_clone_descriptors(
                output_path=output_path,
                manifest=load_json(working_manifest_path),
                args=args,
                tool_dir=tool_dir,
                temp_dir_path=temp_dir_path,
            )

        report = {
            "operation": "whole-object-regeneration-scaffold",
            "scope": "single-kernel-noop",
            "input_code_object": str(input_path),
            "output_code_object": str(output_path),
            "mode": args.mode,
            "kernel_name": kernel_name,
            "kernel_count": len(model.kernel_names()),
            "primary_kernel_count": primary_kernel_count,
            "manifest": str(working_manifest_path),
            "asm_manifest": str(asm_manifest_path),
            "ir": str(ir_path),
            "asm": str(asm_path),
            "object": str(obj_path),
            "rebuild_report": str(rebuild_report_path),
            "temp_dir": str(temp_dir_path),
        }
        if clone_result is not None:
            report["clone_result"] = clone_result
        if entry_wrapper_result is not None:
            report["entry_wrapper_result"] = entry_wrapper_result
        if binary_probe_mode is not None:
            report["binary_probe"] = {
                "instrumentation_mode": binary_probe_mode,
                "support_object_footprint": support_object_footprint_report,
                "support_wrapper_footprint": support_wrapper_footprint_report,
                "abi_delta": binary_probe_abi_delta,
            }
        if extra_link_objects:
            report["extra_link_objects"] = [str(path) for path in extra_link_objects]
        if report_path is not None:
            report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(output_path)
        return 0
    finally:
        if cleanup_dir is not None:
            cleanup_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
