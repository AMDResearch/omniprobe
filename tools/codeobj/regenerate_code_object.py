#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import struct
import shutil
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

from code_object_model import CodeObjectModel
from common import get_hidden_abi_instrumented_name
from emit_hidden_abi_metadata import (
    build_metadata_document,
    build_metadata_document_from_raw,
    build_metadata_object,
    clone_kernel_record,
    dedupe_kernel_records,
    kernel_identity,
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


def update_descriptor_sgpr_footprint(descriptor: dict, total_sgprs: int) -> None:
    rsrc1 = descriptor.setdefault("compute_pgm_rsrc1", {})
    granulated = granulated_sgpr_count(total_sgprs)
    raw_value = int(rsrc1.get("raw_value", 0) or 0)
    raw_value &= ~(0xF << 6)
    raw_value |= (granulated & 0xF) << 6
    rsrc1["raw_value"] = raw_value
    rsrc1["granulated_wavefront_sgpr_count"] = granulated


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
    if not isinstance(clone_intents, list) or not clone_intents:
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

    for intent in clone_intents:
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
        extra_link_objects: list[Path] = []

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
        if args.add_hidden_abi_clone:
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
        if args.add_hidden_abi_clone:
            patch_output_metadata_note(output_path, load_json(working_manifest_path))
        if clone_result is not None:
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
