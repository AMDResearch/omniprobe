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
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


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
    if args.llvm_mc:
        command.extend(["--llvm-mc", args.llvm_mc])
    if args.ld_lld:
        command.extend(["--ld-lld", args.ld_lld])
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
            args=args,
            tool_dir=tool_dir,
        )
        if args.add_hidden_abi_clone:
            patch_output_metadata_note(output_path, load_json(working_manifest_path))

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
        if report_path is not None:
            report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(output_path)
        return 0
    finally:
        if cleanup_dir is not None:
            cleanup_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
