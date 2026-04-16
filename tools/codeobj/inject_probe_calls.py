#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from copy import deepcopy
from pathlib import Path

from amdgpu_calling_convention import (
    analyze_kernel_calling_convention,
    descriptor_allocated_sgpr_count,
    descriptor_allocated_vgpr_count,
    layout_call_arguments,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Inject Omniprobe probe call sequences into instruction-level IR. "
            "The current implementation supports binary-only lifecycle exit "
            "thunk calls."
        )
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument("--plan", required=True, help="Planner JSON emitted by plan_probe_instrumentation.py")
    parser.add_argument(
        "--thunk-manifest",
        required=True,
        help="Thunk manifest JSON emitted by generate_binary_probe_thunks.py",
    )
    parser.add_argument(
        "--manifest",
        default=None,
        help="Optional code-object manifest JSON used for descriptor facts",
    )
    parser.add_argument("--function", required=True, help="Function name to mutate")
    parser.add_argument("--output", required=True, help="Output IR JSON")
    return parser.parse_args()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def find_function(ir: dict, function_name: str) -> dict:
    function = next(
        (entry for entry in ir.get("functions", []) if entry.get("name") == function_name),
        None,
    )
    if function is None:
        raise SystemExit(f"function {function_name!r} not found in IR")
    return function


def find_descriptor(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    for descriptor in manifest.get("kernels", {}).get("descriptors", []):
        if descriptor.get("kernel_name") == function_name or descriptor.get("name") == f"{function_name}.kd":
            return descriptor
    return None


def find_kernel_metadata(manifest: dict | None, function_name: str) -> dict | None:
    if not isinstance(manifest, dict):
        return None
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if not isinstance(kernel, dict):
            continue
        if kernel.get("name") == function_name or kernel.get("symbol") == f"{function_name}.kd":
            return kernel
    return None


def find_kernel_plan(plan: dict, function_name: str) -> dict:
    kernel = next(
        (
            entry
            for entry in plan.get("kernels", [])
            if entry.get("source_kernel") == function_name or entry.get("clone_kernel") == function_name
        ),
        None,
    )
    if kernel is None:
        raise SystemExit(f"no kernel plan found for function {function_name!r}")
    return kernel


def find_exit_thunk(thunk_manifest: dict, kernel_plan: dict) -> dict:
    source_kernel = kernel_plan.get("source_kernel")
    thunk = next(
        (
            entry
            for entry in thunk_manifest.get("thunks", [])
            if entry.get("source_kernel") == source_kernel and entry.get("when") == "kernel_exit"
        ),
        None,
    )
    if thunk is None:
        raise SystemExit(f"no kernel-exit thunk found for source kernel {source_kernel!r}")
    return thunk


def make_instruction(address: int, mnemonic: str, operand_text: str = "", operands: list[str] | None = None) -> dict:
    return {
        "address": address,
        "mnemonic": mnemonic,
        "operand_text": operand_text,
        "operands": operands or [],
        "control_flow": "linear",
        "synthetic": True,
    }


def emit_capture_load_and_marshal(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    temp_pair: list[int],
    call_argument: dict,
) -> list[dict]:
    dword_count = int(call_argument.get("dword_count", 0) or 0)
    offset = int(call_argument.get("kernel_arg_offset", 0) or 0)
    vgprs = [int(value) for value in call_argument.get("vgprs", [])]
    if dword_count == 1:
        scalar_operand = f"s{temp_pair[0]}"
        return [
            make_instruction(
                anchor_address,
                "s_load_dword",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            ),
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "lgkmcnt(0)",
                ["lgkmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{temp_pair[0]}",
                [f"v{vgprs[0]}", f"s{temp_pair[0]}"],
            ),
        ]
    if dword_count == 2:
        scalar_operand = f"s[{temp_pair[0]}:{temp_pair[1]}]"
        return [
            make_instruction(
                anchor_address,
                "s_load_dwordx2",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            ),
            make_instruction(
                anchor_address,
                "s_waitcnt",
                "lgkmcnt(0)",
                ["lgkmcnt(0)"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{temp_pair[0]}",
                [f"v{vgprs[0]}", f"s{temp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[1]}, s{temp_pair[1]}",
                [f"v{vgprs[1]}", f"s{temp_pair[1]}"],
            ),
        ]
    raise SystemExit(f"unsupported capture dword width {dword_count} for call argument {call_argument!r}")


def emit_entry_scalar_save(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    saved_argument: dict,
) -> list[dict]:
    dword_count = int(saved_argument.get("dword_count", 0) or 0)
    offset = int(saved_argument.get("kernel_arg_offset", 0) or 0)
    sgprs = [int(value) for value in saved_argument.get("saved_sgprs", [])]
    if dword_count == 1:
        scalar_operand = f"s{sgprs[0]}"
        return [
            make_instruction(
                anchor_address,
                "s_load_dword",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            )
        ]
    if dword_count == 2:
        scalar_operand = f"s[{sgprs[0]}:{sgprs[1]}]"
        return [
            make_instruction(
                anchor_address,
                "s_load_dwordx2",
                f"{scalar_operand}, s[{kernarg_pair[0]}:{kernarg_pair[1]}], 0x{offset:x}",
                [scalar_operand, f"s[{kernarg_pair[0]}:{kernarg_pair[1]}]", f"0x{offset:x}"],
            )
        ]
    raise SystemExit(f"unsupported entry-save dword width {dword_count} for saved argument {saved_argument!r}")


def emit_saved_scalar_marshal(
    *,
    anchor_address: int,
    saved_argument: dict,
) -> list[dict]:
    dword_count = int(saved_argument.get("dword_count", 0) or 0)
    sgprs = [int(value) for value in saved_argument.get("saved_sgprs", [])]
    vgprs = [int(value) for value in saved_argument.get("vgprs", [])]
    if dword_count == 1:
        return [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{sgprs[0]}",
                [f"v{vgprs[0]}", f"s{sgprs[0]}"],
            )
        ]
    if dword_count == 2:
        return [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[0]}, s{sgprs[0]}",
                [f"v{vgprs[0]}", f"s{sgprs[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{vgprs[1]}, s{sgprs[1]}",
                [f"v{vgprs[1]}", f"s{sgprs[1]}"],
            ),
        ]
    raise SystemExit(f"unsupported saved-scalar dword width {dword_count} for saved argument {saved_argument!r}")


def reserve_saved_scalar_arguments(
    *,
    kernel_metadata: dict | None,
    descriptor: dict | None,
    call_arguments: list[dict],
    hidden_offset: int,
) -> dict:
    current_sgprs = int((kernel_metadata or {}).get("sgpr_count", 0) or 0)
    if current_sgprs <= 0:
        current_sgprs = int(descriptor_allocated_sgpr_count(descriptor) or 0)
    if current_sgprs <= 0:
        raise SystemExit(
            "kernel metadata/descriptor is missing SGPR allocation facts required for binary lifecycle exit saves"
        )

    saved_arguments: list[dict] = []
    next_sgpr = current_sgprs
    for argument in call_arguments:
        kind = str(argument.get("kind", ""))
        if kind not in {"hidden_ctx", "capture"}:
            continue
        saved = dict(argument)
        if kind == "hidden_ctx":
            saved["kernel_arg_offset"] = hidden_offset
        saved_sgprs = list(range(next_sgpr, next_sgpr + int(saved.get("dword_count", 0) or 0)))
        saved["saved_sgprs"] = saved_sgprs
        next_sgpr += len(saved_sgprs)
        saved_arguments.append(saved)

    return {
        "saved_arguments": saved_arguments,
        "saved_sgpr_base": current_sgprs,
        "saved_sgpr_count": max(0, next_sgpr - current_sgprs),
        "total_sgprs": next_sgpr,
    }


def lifecycle_exit_stub_instructions(
    *,
    anchor_address: int,
    timestamp_pair: list[int],
    target_pair: list[int],
    thunk_name: str,
    call_arguments: list[dict],
    saved_arguments: list[dict],
) -> list[dict]:
    timestamp_operand = f"s[{timestamp_pair[0]}:{timestamp_pair[1]}]"
    target_operand = f"s[{target_pair[0]}:{target_pair[1]}]"
    instructions = [
        make_instruction(
            anchor_address,
            "s_memtime",
            timestamp_operand,
            [timestamp_operand],
        ),
        make_instruction(
            anchor_address,
            "s_waitcnt",
            "lgkmcnt(0)",
            ["lgkmcnt(0)"],
        ),
    ]
    for saved_argument in saved_arguments:
        instructions.extend(
            emit_saved_scalar_marshal(
                anchor_address=anchor_address,
                saved_argument=saved_argument,
            )
        )

    timestamp_arg = next((entry for entry in call_arguments if entry.get("kind") == "timestamp"), None)
    if timestamp_arg is None:
        raise SystemExit("thunk manifest did not describe a timestamp call argument")
    timestamp_vgprs = [int(value) for value in timestamp_arg.get("vgprs", [])]
    if len(timestamp_vgprs) != 2:
        raise SystemExit(f"timestamp call argument must occupy two VGPRs, got {timestamp_vgprs!r}")
    instructions.extend(
        [
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[0]}, s{timestamp_pair[0]}",
                [f"v{timestamp_vgprs[0]}", f"s{timestamp_pair[0]}"],
            ),
            make_instruction(
                anchor_address,
                "v_mov_b32_e32",
                f"v{timestamp_vgprs[1]}, s{timestamp_pair[1]}",
                [f"v{timestamp_vgprs[1]}", f"s{timestamp_pair[1]}"],
            ),
            make_instruction(anchor_address, "s_getpc_b64", target_operand, [target_operand]),
        ]
    )
    instructions.extend(
        [
        make_instruction(
            anchor_address,
            "s_add_u32",
            f"s{target_pair[0]}, s{target_pair[0]}, {thunk_name}@rel32@lo+4",
            [f"s{target_pair[0]}", f"s{target_pair[0]}", f"{thunk_name}@rel32@lo+4"],
        ),
        make_instruction(
            anchor_address,
            "s_addc_u32",
            f"s{target_pair[1]}, s{target_pair[1]}, {thunk_name}@rel32@hi+4",
            [f"s{target_pair[1]}", f"s{target_pair[1]}", f"{thunk_name}@rel32@hi+4"],
        ),
        make_instruction(
            anchor_address,
            "s_swappc_b64",
            f"s[30:31], {target_operand}",
            ["s[30:31]", target_operand],
        ),
        ]
    )
    return instructions


def lifecycle_entry_save_instructions(
    *,
    anchor_address: int,
    kernarg_pair: list[int],
    saved_arguments: list[dict],
) -> list[dict]:
    instructions: list[dict] = []
    for saved_argument in saved_arguments:
        instructions.extend(
            emit_entry_scalar_save(
                anchor_address=anchor_address,
                kernarg_pair=kernarg_pair,
                saved_argument=saved_argument,
            )
        )
    return instructions


def inject_lifecycle_exit_stub(
    *,
    ir: dict,
    function_name: str,
    kernel_plan: dict,
    thunk: dict,
    descriptor: dict | None,
    kernel_metadata: dict | None,
) -> dict:
    output = deepcopy(ir)
    function = find_function(output, function_name)
    analysis = analyze_kernel_calling_convention(function=function, descriptor=descriptor)
    if not analysis.get("supported_for_lifecycle_exit_stub", False):
        raise SystemExit(f"function {function_name!r} is not supported for lifecycle-exit stub injection")

    lifecycle_call = analysis["resolved_lifecycle_call"]
    kernarg_base = analysis["inferred_kernarg_base"]
    timestamp_pair = list(lifecycle_call["arg_pairs"][2]["source_sgpr_pair"])
    kernarg_pair = list(kernarg_base["base_pair"])
    target_pair = list(lifecycle_call["target_pair"])

    hidden_ctx = kernel_plan.get("hidden_omniprobe_ctx", {})
    hidden_offset = int(hidden_ctx.get("offset", 0) or 0)
    thunk_name = str(thunk.get("thunk", ""))
    if not thunk_name:
        raise SystemExit("thunk manifest entry did not contain a thunk name")
    thunk_call_arguments = thunk.get("call_arguments")
    if isinstance(thunk_call_arguments, list) and thunk_call_arguments:
        call_layout = layout_call_arguments([dict(entry) for entry in thunk_call_arguments])
        call_arguments = call_layout["arguments"]
    else:
        call_layout = layout_call_arguments(
            [
                {"kind": "hidden_ctx", "name": "hidden_ctx", "c_type": "const void *", "size_bytes": 8},
                {"kind": "kernarg_base", "name": "kernarg_base", "c_type": "const void *", "size_bytes": 8},
                {"kind": "timestamp", "name": "timestamp", "c_type": "uint64_t", "size_bytes": 8},
            ]
        )
        call_arguments = call_layout["arguments"]

    allocated_vgprs = descriptor_allocated_vgpr_count(descriptor)
    if allocated_vgprs is not None and call_layout["total_dwords"] > allocated_vgprs:
        raise SystemExit(
            f"function {function_name!r} cannot marshal {call_layout['total_dwords']} dwords of call arguments "
            f"with only {allocated_vgprs} allocated VGPRs"
        )
    saved_scalar_plan = reserve_saved_scalar_arguments(
        kernel_metadata=kernel_metadata,
        descriptor=descriptor,
        call_arguments=call_arguments,
        hidden_offset=hidden_offset,
    )
    saved_arguments = saved_scalar_plan["saved_arguments"]

    original_instructions = function.get("instructions", [])
    mutated_instructions: list[dict] = []
    injected_sites: list[int] = []
    if original_instructions:
        entry_anchor = int(original_instructions[0].get("address", function.get("start_address", 0)) or 0)
        mutated_instructions.extend(
            lifecycle_entry_save_instructions(
                anchor_address=entry_anchor,
                kernarg_pair=kernarg_pair,
                saved_arguments=saved_arguments,
            )
        )
    for instruction in original_instructions:
        if instruction.get("mnemonic") == "s_endpgm":
            anchor_address = int(instruction.get("address", 0) or 0)
            mutated_instructions.extend(
                lifecycle_exit_stub_instructions(
                    anchor_address=anchor_address,
                    timestamp_pair=timestamp_pair,
                    target_pair=target_pair,
                    thunk_name=thunk_name,
                    call_arguments=call_arguments,
                    saved_arguments=saved_arguments,
                )
            )
            injected_sites.append(anchor_address)
        mutated_instructions.append(instruction)

    if not injected_sites:
        raise SystemExit(f"function {function_name!r} did not contain any s_endpgm exits to instrument")

    function["instructions"] = mutated_instructions
    function.setdefault("instrumentation", {})
    function["instrumentation"]["lifecycle_exit_stub"] = {
        "call_source": analysis.get("lifecycle_call_source"),
        "hidden_omniprobe_ctx_offset": hidden_offset,
        "thunk": thunk_name,
        "injected_exit_addresses": injected_sites,
        "kernarg_pair": kernarg_pair,
        "timestamp_pair": timestamp_pair,
        "target_pair": target_pair,
        "call_arguments": call_arguments,
        "saved_call_arguments": saved_arguments,
        "saved_sgpr_base": saved_scalar_plan["saved_sgpr_base"],
        "saved_sgpr_count": saved_scalar_plan["saved_sgpr_count"],
        "total_sgprs": saved_scalar_plan["total_sgprs"],
    }
    return output


def main() -> int:
    args = parse_args()
    ir = load_json(Path(args.ir).resolve())
    plan = load_json(Path(args.plan).resolve())
    thunk_manifest = load_json(Path(args.thunk_manifest).resolve())
    manifest = load_json(Path(args.manifest).resolve()) if args.manifest else None
    kernel_plan = find_kernel_plan(plan, args.function)
    thunk = find_exit_thunk(thunk_manifest, kernel_plan)
    descriptor = find_descriptor(manifest, args.function)
    kernel_metadata = find_kernel_metadata(manifest, args.function)
    mutated = inject_lifecycle_exit_stub(
        ir=ir,
        function_name=args.function,
        kernel_plan=kernel_plan,
        thunk=thunk,
        descriptor=descriptor,
        kernel_metadata=kernel_metadata,
    )
    save_json(Path(args.output).resolve(), mutated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
