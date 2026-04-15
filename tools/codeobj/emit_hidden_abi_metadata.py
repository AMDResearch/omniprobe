#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from copy import deepcopy
from pathlib import Path
import sys

from common import OMNIPROBE_HIDDEN_ARG, get_hidden_abi_instrumented_name
from inspect_code_object import extract_indented_block, parse_scalar_field, split_list_items
from msgpack_codec import packb
from plan_hidden_abi import build_kernel_plan, select_kernels


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit hidden-ABI Omniprobe clone metadata from a code-object manifest."
    )
    parser.add_argument("manifest", help="Manifest JSON emitted by inspect_code_object.py")
    parser.add_argument(
        "--kernel",
        default=None,
        help="Restrict emission to one kernel name or symbol",
    )
    parser.add_argument(
        "--pointer-size",
        type=int,
        default=8,
        help="Size in bytes of the hidden Omniprobe context pointer",
    )
    parser.add_argument(
        "--alignment",
        type=int,
        default=8,
        help="Alignment used when appending hidden_omniprobe_ctx",
    )
    parser.add_argument(
        "--clones-only",
        action="store_true",
        help="Emit only cloned kernel metadata entries",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Write metadata output to this path instead of stdout",
    )
    parser.add_argument(
        "--format",
        choices=["yaml", "msgpack"],
        default="yaml",
        help="Emit metadata as rendered YAML or exact MessagePack payload bytes",
    )
    return parser.parse_args()


def clone_descriptor_symbol(kernel_name: str) -> str:
    return f"{kernel_name}.kd"


def clone_kernel_record(kernel: dict, plan: dict) -> dict:
    clone = deepcopy(kernel)
    clone_name = plan["hidden_abi_clone_name"]
    clone["name"] = clone_name
    clone["symbol"] = clone_descriptor_symbol(clone_name)
    clone["kernarg_segment_size"] = plan["instrumented_kernarg_length"]

    args = [deepcopy(arg) for arg in clone.get("args", []) if arg]
    hidden_arg = {
        "name": OMNIPROBE_HIDDEN_ARG,
        "offset": plan["hidden_omniprobe_ctx"]["offset"],
        "size": plan["hidden_omniprobe_ctx"]["size"],
        "value_kind": plan["hidden_omniprobe_ctx"]["value_kind"],
    }
    if "address_space" in plan["hidden_omniprobe_ctx"]:
        hidden_arg["address_space"] = plan["hidden_omniprobe_ctx"]["address_space"]
    args.append(hidden_arg)
    args.sort(key=lambda arg: (int(arg.get("offset", 0)), str(arg.get("value_kind", ""))))
    clone["args"] = args
    return clone


def mutate_kernel_record_in_place(kernel: dict, plan: dict) -> dict:
    mutated = deepcopy(kernel)
    mutated["kernarg_segment_size"] = plan["instrumented_kernarg_length"]

    args = [deepcopy(arg) for arg in mutated.get("args", []) if arg]
    if not any(
        arg.get("name") == OMNIPROBE_HIDDEN_ARG
        or arg.get("value_kind") == OMNIPROBE_HIDDEN_ARG
        for arg in args
    ):
        hidden_arg = {
            "name": OMNIPROBE_HIDDEN_ARG,
            "offset": plan["hidden_omniprobe_ctx"]["offset"],
            "size": plan["hidden_omniprobe_ctx"]["size"],
            "value_kind": plan["hidden_omniprobe_ctx"]["value_kind"],
        }
        if "address_space" in plan["hidden_omniprobe_ctx"]:
            hidden_arg["address_space"] = plan["hidden_omniprobe_ctx"]["address_space"]
        args.append(hidden_arg)
    args.sort(key=lambda arg: (int(arg.get("offset", 0)), str(arg.get("value_kind", ""))))
    mutated["args"] = args
    return mutated


def yaml_scalar(value: object) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or any(ch in text for ch in [":", "'", '"', "#", "{", "}", "[", "]"]):
        return "'" + text.replace("'", "''") + "'"
    return text


def emit_arg_lines(arg: dict, indent: int) -> list[str]:
    prefix = " " * indent
    lines = [f"{prefix}- .offset:         {arg['offset']}"]
    if "address_space" in arg:
        lines.append(f"{prefix}  .address_space:  {yaml_scalar(arg['address_space'])}")
    lines.append(f"{prefix}  .size:           {arg['size']}")
    if "name" in arg:
        lines.append(f"{prefix}  .name:           {yaml_scalar(arg['name'])}")
    if "type_name" in arg:
        lines.append(f"{prefix}  .type_name:      {yaml_scalar(arg['type_name'])}")
    lines.append(f"{prefix}  .value_kind:     {yaml_scalar(arg['value_kind'])}")
    return lines


def emit_kernel_lines(kernel: dict, indent: int = 2) -> list[str]:
    prefix = " " * indent
    lines = [f"{prefix}- .args:"]
    for arg in kernel.get("args", []):
        lines.extend(emit_arg_lines(arg, indent + 4))

    ordered_keys = [
        "group_segment_fixed_size",
        "kernarg_segment_size",
        "max_flat_workgroup_size",
        "name",
        "private_segment_fixed_size",
        "sgpr_count",
        "symbol",
        "vgpr_count",
        "wavefront_size",
    ]
    emitted = set()
    for key in ordered_keys:
        if key in kernel:
            lines.append(f"{prefix}  .{key}: {yaml_scalar(kernel[key])}")
            emitted.add(key)

    for key in sorted(kernel.keys()):
        if key in emitted or key == "args":
            continue
        lines.append(f"{prefix}  .{key}: {yaml_scalar(kernel[key])}")
    return lines


def build_metadata_document(manifest: dict, selected_kernels: list[dict], clones_only: bool, pointer_size: int, alignment: int) -> str:
    original_kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    selected_identity = {
        (kernel.get("name"), kernel.get("symbol")) for kernel in selected_kernels
    }
    kernel_lines: list[str] = ["---", "amdhsa.kernels:"]

    if not clones_only:
        for kernel in original_kernels:
            kernel_lines.extend(emit_kernel_lines(kernel))

    for kernel in selected_kernels:
        plan = build_kernel_plan(kernel, pointer_size=pointer_size, alignment=alignment)
        kernel_lines.extend(emit_kernel_lines(clone_kernel_record(kernel, plan)))

    target = manifest.get("kernels", {}).get("metadata", {}).get("target")
    if target:
        kernel_lines.append(f"amdhsa.target: {yaml_scalar(target)}")
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    version = metadata_obj.get("amdhsa.version") if isinstance(metadata_obj, dict) else None
    if isinstance(version, list) and version:
        kernel_lines.append("amdhsa.version:")
        for item in version:
            kernel_lines.append(f"  - {yaml_scalar(item)}")
    return "\n".join(kernel_lines) + "\n"


def dedupe_kernel_records(kernels: list[dict]) -> list[dict]:
    seen: set[tuple[object, object]] = set()
    result: list[dict] = []
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        identity = (kernel.get("name"), kernel.get("symbol"))
        if identity in seen:
            continue
        seen.add(identity)
        result.append(kernel)
    return result


def clone_arg_object(plan: dict) -> dict:
    arg = {
        ".name": OMNIPROBE_HIDDEN_ARG,
        ".offset": plan["hidden_omniprobe_ctx"]["offset"],
        ".size": plan["hidden_omniprobe_ctx"]["size"],
        ".value_kind": plan["hidden_omniprobe_ctx"]["value_kind"],
    }
    if "address_space" in plan["hidden_omniprobe_ctx"]:
        arg[".address_space"] = plan["hidden_omniprobe_ctx"]["address_space"]
    return arg


def clone_kernel_object(kernel_obj: dict, plan: dict) -> dict:
    clone = deepcopy(kernel_obj)
    clone_name = plan["hidden_abi_clone_name"]
    clone[".name"] = clone_name
    clone[".symbol"] = clone_descriptor_symbol(clone_name)
    clone[".kernarg_segment_size"] = plan["instrumented_kernarg_length"]

    args = [deepcopy(arg) for arg in clone.get(".args", []) if isinstance(arg, dict)]
    args.append(clone_arg_object(plan))
    args.sort(key=lambda arg: (int(arg.get(".offset", 0)), str(arg.get(".value_kind", ""))))
    clone[".args"] = args
    return clone


def mutate_kernel_object_in_place(kernel_obj: dict, plan: dict) -> dict:
    mutated = deepcopy(kernel_obj)
    mutated[".kernarg_segment_size"] = plan["instrumented_kernarg_length"]

    args = [deepcopy(arg) for arg in mutated.get(".args", []) if isinstance(arg, dict)]
    if not any(
        arg.get(".name") == OMNIPROBE_HIDDEN_ARG
        or arg.get(".value_kind") == OMNIPROBE_HIDDEN_ARG
        for arg in args
    ):
        args.append(clone_arg_object(plan))
    args.sort(key=lambda arg: (int(arg.get(".offset", 0)), str(arg.get(".value_kind", ""))))
    mutated[".args"] = args
    return mutated


def build_metadata_object(
    manifest: dict,
    selected_kernels: list[dict],
    clones_only: bool,
    pointer_size: int,
    alignment: int,
) -> dict:
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    if not isinstance(metadata_obj, dict):
        raise SystemExit("manifest does not contain an exact metadata object")

    result = deepcopy(metadata_obj)
    original_kernels = result.get("amdhsa.kernels")
    if not isinstance(original_kernels, list):
        raise SystemExit("metadata object is missing amdhsa.kernels")

    kernel_obj_by_identity = {}
    for kernel_obj in original_kernels:
        if not isinstance(kernel_obj, dict):
            continue
        identity = (kernel_obj.get(".name"), kernel_obj.get(".symbol"))
        kernel_obj_by_identity[identity] = kernel_obj

    output_kernels = [] if clones_only else [deepcopy(kernel) for kernel in original_kernels]
    for kernel in selected_kernels:
        identity = (kernel.get("name"), kernel.get("symbol"))
        source_obj = kernel_obj_by_identity.get(identity)
        if source_obj is None:
            raise SystemExit(f"failed to locate exact metadata object for kernel {identity}")
        plan = build_kernel_plan(kernel, pointer_size=pointer_size, alignment=alignment)
        output_kernels.append(clone_kernel_object(source_obj, plan))

    result["amdhsa.kernels"] = output_kernels
    return result


def build_metadata_object_with_replacement(
    manifest: dict,
    source_kernel: dict,
    replace_kernel: dict,
    pointer_size: int,
    alignment: int,
) -> dict:
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    if not isinstance(metadata_obj, dict):
        raise SystemExit("manifest does not contain an exact metadata object")

    result = deepcopy(metadata_obj)
    original_kernels = result.get("amdhsa.kernels")
    if not isinstance(original_kernels, list):
        raise SystemExit("metadata object is missing amdhsa.kernels")

    kernel_obj_by_identity = {}
    for kernel_obj in original_kernels:
        if not isinstance(kernel_obj, dict):
            continue
        identity = (kernel_obj.get(".name"), kernel_obj.get(".symbol"))
        kernel_obj_by_identity[identity] = kernel_obj

    source_identity = (source_kernel.get("name"), source_kernel.get("symbol"))
    replace_identity = (replace_kernel.get("name"), replace_kernel.get("symbol"))
    source_obj = kernel_obj_by_identity.get(source_identity)
    if source_obj is None:
        raise SystemExit(f"failed to locate exact metadata object for kernel {source_identity}")

    plan = build_kernel_plan(source_kernel, pointer_size=pointer_size, alignment=alignment)
    output_kernels = []
    for kernel_obj in original_kernels:
        if not isinstance(kernel_obj, dict):
            output_kernels.append(deepcopy(kernel_obj))
            continue
        identity = (kernel_obj.get(".name"), kernel_obj.get(".symbol"))
        if identity == replace_identity:
            output_kernels.append(clone_kernel_object(source_obj, plan))
        else:
            output_kernels.append(deepcopy(kernel_obj))
    result["amdhsa.kernels"] = output_kernels
    return result


def build_metadata_object_with_inplace_update(
    manifest: dict,
    source_kernel: dict,
    pointer_size: int,
    alignment: int,
) -> dict:
    metadata_obj = manifest.get("kernels", {}).get("metadata", {}).get("object")
    if not isinstance(metadata_obj, dict):
        raise SystemExit("manifest does not contain an exact metadata object")

    result = deepcopy(metadata_obj)
    original_kernels = result.get("amdhsa.kernels")
    if not isinstance(original_kernels, list):
        raise SystemExit("metadata object is missing amdhsa.kernels")

    source_identity = (source_kernel.get("name"), source_kernel.get("symbol"))
    plan = build_kernel_plan(source_kernel, pointer_size=pointer_size, alignment=alignment)
    output_kernels = []
    for kernel_obj in original_kernels:
        if not isinstance(kernel_obj, dict):
            output_kernels.append(deepcopy(kernel_obj))
            continue
        identity = (kernel_obj.get(".name"), kernel_obj.get(".symbol"))
        if identity == source_identity:
            output_kernels.append(mutate_kernel_object_in_place(kernel_obj, plan))
        else:
            output_kernels.append(deepcopy(kernel_obj))
    result["amdhsa.kernels"] = output_kernels
    return result


def build_metadata_payload(
    manifest: dict,
    selected_kernels: list[dict],
    clones_only: bool,
    pointer_size: int,
    alignment: int,
    output_format: str,
) -> bytes | str:
    if output_format == "msgpack":
        metadata_obj = build_metadata_object(
            manifest,
            selected_kernels=selected_kernels,
            clones_only=clones_only,
            pointer_size=pointer_size,
            alignment=alignment,
        )
        return packb(metadata_obj)

    return build_metadata_document_from_raw(
        manifest,
        selected_kernels=selected_kernels,
        clones_only=clones_only,
        pointer_size=pointer_size,
        alignment=alignment,
    )


def build_metadata_payload_with_replacement(
    manifest: dict,
    source_kernel: dict,
    replace_kernel: dict,
    pointer_size: int,
    alignment: int,
    output_format: str,
) -> bytes | str:
    if output_format == "msgpack":
        metadata_obj = build_metadata_object_with_replacement(
            manifest,
            source_kernel=source_kernel,
            replace_kernel=replace_kernel,
            pointer_size=pointer_size,
            alignment=alignment,
        )
        return packb(metadata_obj)

    return build_metadata_document_with_replacement(
        manifest,
        source_kernel=source_kernel,
        replace_kernel=replace_kernel,
        pointer_size=pointer_size,
        alignment=alignment,
    )


def build_metadata_payload_with_inplace_update(
    manifest: dict,
    source_kernel: dict,
    pointer_size: int,
    alignment: int,
    output_format: str,
) -> bytes | str:
    if output_format == "msgpack":
        metadata_obj = build_metadata_object_with_inplace_update(
            manifest,
            source_kernel=source_kernel,
            pointer_size=pointer_size,
            alignment=alignment,
        )
        return packb(metadata_obj)

    return build_metadata_document_with_inplace_update(
        manifest,
        source_kernel=source_kernel,
        pointer_size=pointer_size,
        alignment=alignment,
    )


def raw_kernel_blocks(raw_metadata: str) -> tuple[list[str], list[list[str]], list[str]]:
    lines = raw_metadata.splitlines()
    kernels_header_index = None
    kernels_header_indent = 0
    for index, line in enumerate(lines):
        if line.strip() == "amdhsa.kernels:":
            kernels_header_index = index
            kernels_header_indent = len(line) - len(line.lstrip(" "))
            break
    if kernels_header_index is None:
        raise SystemExit("raw metadata does not contain amdhsa.kernels")

    kernel_lines = extract_indented_block(lines, kernels_header_index + 1, kernels_header_indent)
    kernel_items = split_list_items(kernel_lines, kernels_header_indent)
    prefix = lines[: kernels_header_index + 1]
    suffix = lines[kernels_header_index + 1 + len(kernel_lines) :]
    return prefix, kernel_items, suffix


def kernel_identity(block_lines: list[str]) -> tuple[str | None, str | None]:
    block = "\n".join(block_lines)
    return parse_scalar_field(block, "name"), parse_scalar_field(block, "symbol")


def mutate_kernel_block(block_lines: list[str], plan: dict) -> list[str]:
    clone_name = plan["hidden_abi_clone_name"]
    clone_symbol = clone_descriptor_symbol(clone_name)
    new_kernarg = plan["instrumented_kernarg_length"]
    hidden_arg = plan["hidden_omniprobe_ctx"]

    lines = list(block_lines)
    for index, line in enumerate(lines):
        if ".name:" in line:
            prefix = line.split(".name:", 1)[0]
            lines[index] = f"{prefix}.name:           {clone_name}"
        elif ".symbol:" in line:
            prefix = line.split(".symbol:", 1)[0]
            lines[index] = f"{prefix}.symbol:         {clone_symbol}"
        elif ".kernarg_segment_size:" in line:
            prefix = line.split(".kernarg_segment_size:", 1)[0]
            lines[index] = f"{prefix}.kernarg_segment_size: {new_kernarg}"

    args_line_index = next(
        (i for i, line in enumerate(lines) if line.strip() in {".args:", "- .args:"}),
        None,
    )
    if args_line_index is None:
        raise SystemExit(f"kernel block for {clone_name} does not contain .args")

    args_line = lines[args_line_index]
    args_indent = len(args_line) - len(args_line.lstrip(" "))
    args_parent_indent = args_indent + 2 if args_line.strip().startswith("- ") else args_indent
    insert_index = args_line_index + 1
    while insert_index < len(lines):
        line = lines[insert_index]
        if line.strip():
            indent = len(line) - len(line.lstrip(" "))
            if indent <= args_parent_indent:
                break
        insert_index += 1

    arg_prefix = " " * (args_indent + 4)
    clone_arg_lines = [
        f"{arg_prefix}- .name:           {OMNIPROBE_HIDDEN_ARG}",
        f"{arg_prefix}  .address_space:  {hidden_arg['address_space']}",
        f"{arg_prefix}  .offset:         {hidden_arg['offset']}",
        f"{arg_prefix}  .size:           {hidden_arg['size']}",
        f"{arg_prefix}  .value_kind:     {hidden_arg['value_kind']}",
    ]
    lines[insert_index:insert_index] = clone_arg_lines
    return lines


def build_metadata_document_from_raw(
    manifest: dict,
    selected_kernels: list[dict],
    clones_only: bool,
    pointer_size: int,
    alignment: int,
) -> str:
    raw_metadata = manifest.get("kernels", {}).get("metadata", {}).get("raw")
    if not raw_metadata:
        return build_metadata_document(
            manifest,
            selected_kernels=selected_kernels,
            clones_only=clones_only,
            pointer_size=pointer_size,
            alignment=alignment,
        )

    prefix, kernel_blocks, suffix = raw_kernel_blocks(raw_metadata)
    selected_identities = {
        (kernel.get("name"), kernel.get("symbol")) for kernel in selected_kernels
    }

    output_lines = list(prefix)
    if not clones_only:
        for block in kernel_blocks:
            output_lines.extend(block)

    for block in kernel_blocks:
        identity = kernel_identity(block)
        if identity not in selected_identities:
            continue
        matching_kernel = next(
            kernel
            for kernel in selected_kernels
            if (kernel.get("name"), kernel.get("symbol")) == identity
        )
        plan = build_kernel_plan(matching_kernel, pointer_size=pointer_size, alignment=alignment)
        output_lines.extend(mutate_kernel_block(block, plan))

    output_lines.extend(suffix)
    return "\n".join(output_lines).rstrip() + "\n"


def build_metadata_document_with_replacement(
    manifest: dict,
    source_kernel: dict,
    replace_kernel: dict,
    pointer_size: int,
    alignment: int,
) -> str:
    raw_metadata = manifest.get("kernels", {}).get("metadata", {}).get("raw")
    if not raw_metadata:
        raise SystemExit("raw metadata is required for donor replacement mode")

    prefix, kernel_blocks, suffix = raw_kernel_blocks(raw_metadata)
    replace_identity = (replace_kernel.get("name"), replace_kernel.get("symbol"))
    plan = build_kernel_plan(source_kernel, pointer_size=pointer_size, alignment=alignment)

    output_lines = list(prefix)
    for block in kernel_blocks:
        if kernel_identity(block) == replace_identity:
            output_lines.extend(mutate_kernel_block(block, plan))
        else:
            output_lines.extend(block)
    output_lines.extend(suffix)
    return "\n".join(output_lines).rstrip() + "\n"


def build_metadata_document_with_inplace_update(
    manifest: dict,
    source_kernel: dict,
    pointer_size: int,
    alignment: int,
) -> str:
    raw_metadata = manifest.get("kernels", {}).get("metadata", {}).get("raw")
    if not raw_metadata:
        mutated_kernels = []
        for kernel in manifest.get("kernels", {}).get("metadata", {}).get("kernels", []):
            identity = (kernel.get("name"), kernel.get("symbol"))
            source_identity = (source_kernel.get("name"), source_kernel.get("symbol"))
            if identity == source_identity:
                plan = build_kernel_plan(source_kernel, pointer_size=pointer_size, alignment=alignment)
                mutated_kernels.append(mutate_kernel_record_in_place(kernel, plan))
            else:
                mutated_kernels.append(deepcopy(kernel))
        updated_manifest = deepcopy(manifest)
        updated_manifest["kernels"]["metadata"]["kernels"] = mutated_kernels
        return build_metadata_document(
            updated_manifest,
            selected_kernels=[],
            clones_only=False,
            pointer_size=pointer_size,
            alignment=alignment,
        )

    prefix, kernel_blocks, suffix = raw_kernel_blocks(raw_metadata)
    source_identity = (source_kernel.get("name"), source_kernel.get("symbol"))
    plan = build_kernel_plan(source_kernel, pointer_size=pointer_size, alignment=alignment)

    output_lines = list(prefix)
    for block in kernel_blocks:
        identity = kernel_identity(block)
        if identity == source_identity:
            output_lines.extend(mutate_kernel_block_in_place(block, plan))
        else:
            output_lines.extend(block)
    output_lines.extend(suffix)
    return "\n".join(output_lines).rstrip() + "\n"


def mutate_kernel_block_in_place(block_lines: list[str], plan: dict) -> list[str]:
    new_kernarg = plan["instrumented_kernarg_length"]
    hidden_arg = plan["hidden_omniprobe_ctx"]

    lines = list(block_lines)
    for index, line in enumerate(lines):
        if ".kernarg_segment_size:" in line:
            prefix = line.split(".kernarg_segment_size:", 1)[0]
            lines[index] = f"{prefix}.kernarg_segment_size: {new_kernarg}"

    args_line_index = next(
        (i for i, line in enumerate(lines) if line.strip() in {".args:", "- .args:"}),
        None,
    )
    if args_line_index is None:
        raise SystemExit("kernel block does not contain .args")

    if any(OMNIPROBE_HIDDEN_ARG in line for line in lines):
        return lines

    args_line = lines[args_line_index]
    args_indent = len(args_line) - len(args_line.lstrip(" "))
    args_parent_indent = args_indent + 2 if args_line.strip().startswith("- ") else args_indent
    insert_index = args_line_index + 1
    while insert_index < len(lines):
        line = lines[insert_index]
        if line.strip():
            indent = len(line) - len(line.lstrip(" "))
            if indent <= args_parent_indent:
                break
        insert_index += 1

    arg_prefix = " " * (args_indent + 4)
    clone_arg_lines = [
        f"{arg_prefix}- .name:           {OMNIPROBE_HIDDEN_ARG}",
        f"{arg_prefix}  .address_space:  {hidden_arg['address_space']}",
        f"{arg_prefix}  .offset:         {hidden_arg['offset']}",
        f"{arg_prefix}  .size:           {hidden_arg['size']}",
        f"{arg_prefix}  .value_kind:     {hidden_arg['value_kind']}",
    ]
    lines[insert_index:insert_index] = clone_arg_lines
    return lines


def main() -> int:
    args = parse_args()
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    selected_kernels = select_kernels(manifest, args.kernel)
    payload = build_metadata_payload(
        manifest,
        selected_kernels=selected_kernels,
        clones_only=args.clones_only,
        pointer_size=args.pointer_size,
        alignment=args.alignment,
        output_format=args.format,
    )

    if args.output:
        output_path = Path(args.output).resolve()
        if isinstance(payload, bytes):
            output_path.write_bytes(payload)
        else:
            output_path.write_text(payload, encoding="utf-8")
        print(output_path)
    else:
        if isinstance(payload, bytes):
            sys.stdout.buffer.write(payload)
        else:
            print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
