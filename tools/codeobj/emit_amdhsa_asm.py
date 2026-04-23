#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from code_object_model import CodeObjectModel


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit a full AMDHSA assembly file from IR and code-object manifest."
    )
    parser.add_argument("ir", help="Instruction-level IR JSON")
    parser.add_argument("manifest", help="Code-object manifest JSON")
    parser.add_argument(
        "--output",
        required=True,
        help="Output assembly path",
    )
    parser.add_argument(
        "--function",
        default=None,
        help="Optional function name to emit when the IR/code object contains multiple kernels",
    )
    parser.add_argument(
        "--exact-encoding",
        action="store_true",
        help="Emit instructions as raw encoding words to preserve exact layout",
    )
    parser.add_argument(
        "--preserve-descriptor-bytes",
        action="store_true",
        help="Emit raw kernel-descriptor bytes from the manifest instead of regenerating descriptors",
    )
    return parser.parse_args()


def render_instruction(function: dict, instruction: dict, labels: dict[int, str]) -> str:
    mnemonic = instruction["mnemonic"]
    operand_text = instruction.get("operand_text", "")
    target = instruction.get("target")
    if target and target.get("symbol") == function["name"]:
        target_address = function["start_address"] + target.get("offset", 0)
        if target_address in labels:
            operand_text = labels[target_address]

    if operand_text:
        return f"  {mnemonic} {operand_text}"
    return f"  {mnemonic}"


def parse_scalar_reg(operand: str) -> int | None:
    match = re.fullmatch(r"s(\d+)", operand)
    return int(match.group(1)) if match else None


def parse_scalar_reg_pair(operand: str) -> tuple[int, int] | None:
    match = re.fullmatch(r"s\[(\d+):(\d+)\]", operand)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def parse_signed_32bit_immediate(operand: str) -> int | None:
    try:
        value = int(operand, 0)
    except ValueError:
        return None
    value &= 0xFFFFFFFF
    if value & 0x80000000:
        value -= 1 << 32
    return value


def render_encoded_instruction(instruction: dict) -> list[str]:
    encoding_words = instruction.get("encoding_words", [])
    if not encoding_words:
        return []
    return [f"  .long 0x{word.lower()}" for word in encoding_words]


def binding_name(symbol: dict | None) -> str:
    return str(symbol.get("binding", "")).lower() if symbol else ""


def is_global_binding(symbol: dict | None) -> bool:
    return binding_name(symbol) == "global"


def is_weak_binding(symbol: dict | None) -> bool:
    return binding_name(symbol) == "weak"


def binding_rank(symbol: dict | None) -> int:
    binding = binding_name(symbol)
    if binding == "global":
        return 3
    if binding == "weak":
        return 2
    if binding == "local":
        return 1
    return 0


def symbol_preference_key(symbol: dict | None) -> tuple[int, int, int]:
    visibility = set(symbol.get("visibility", [])) if symbol else set()
    return (
        binding_rank(symbol),
        1 if "STV_PROTECTED" in visibility else 0,
        1 if "STV_HIDDEN" in visibility else 0,
    )


def choose_preferred_symbol(existing: dict | None, candidate: dict | None) -> dict | None:
    if existing is None:
        return candidate
    if candidate is None:
        return existing
    if symbol_preference_key(candidate) > symbol_preference_key(existing):
        return candidate
    return existing


def emit_binding(name: str, symbol: dict | None) -> list[str]:
    if is_global_binding(symbol):
        return [f".globl {name}"]
    if is_weak_binding(symbol):
        return [f".weak {name}"]
    return []


def emit_visibility(name: str, symbol: dict | None) -> list[str]:
    if not symbol:
        return []
    visibility = set(symbol.get("visibility", []))
    if "STV_PROTECTED" in visibility:
        return [f".protected {name}"]
    if "STV_HIDDEN" in visibility:
        return [f".hidden {name}"]
    return []


def build_symbols_by_value(manifest: dict) -> dict[int, dict]:
    records: dict[int, dict] = {}
    for symbol in manifest.get("symbols", []):
        name = symbol.get("name")
        value = symbol.get("value")
        section = symbol.get("section")
        if not name or value is None or not section:
            continue
        if section not in {".text", ".data", ".bss", ".rodata"}:
            continue
        address = int(value)
        records[address] = choose_preferred_symbol(records.get(address), symbol)
    return records


def find_section(manifest: dict, name: str) -> dict | None:
    return next((section for section in manifest.get("sections", []) if section.get("name") == name), None)


def detect_pc_relative_symbolic_ref(
    function: dict,
    instructions: list[dict],
    index: int,
    symbols_by_value: dict[int, dict],
) -> dict | None:
    if index <= 0 or index + 1 >= len(instructions):
        return None

    getpc = instructions[index - 1]
    add_lo = instructions[index]
    add_hi = instructions[index + 1]
    if getpc.get("mnemonic") != "s_getpc_b64":
        return None
    if add_lo.get("mnemonic") != "s_add_u32" or add_hi.get("mnemonic") != "s_addc_u32":
        return None

    getpc_operands = getpc.get("operands", [])
    add_lo_operands = add_lo.get("operands", [])
    add_hi_operands = add_hi.get("operands", [])
    if len(getpc_operands) != 1 or len(add_lo_operands) != 3 or len(add_hi_operands) != 3:
        return None

    reg_pair = parse_scalar_reg_pair(getpc_operands[0])
    low_dst = parse_scalar_reg(add_lo_operands[0])
    low_src = parse_scalar_reg(add_lo_operands[1])
    high_dst = parse_scalar_reg(add_hi_operands[0])
    high_src = parse_scalar_reg(add_hi_operands[1])
    if reg_pair is None or None in {low_dst, low_src, high_dst, high_src}:
        return None
    if reg_pair != (low_dst, high_dst):
        return None
    if low_dst != low_src or high_dst != high_src:
        return None

    imm_lo = parse_signed_32bit_immediate(add_lo_operands[2])
    imm_hi = parse_signed_32bit_immediate(add_hi_operands[2])
    if imm_lo is None or imm_hi is None:
        return None

    delta = ((imm_hi & 0xFFFFFFFF) << 32) | (imm_lo & 0xFFFFFFFF)
    if delta & (1 << 63):
        delta -= 1 << 64
    target_base_address = int(add_lo.get("source_address", add_lo["address"]))
    target_address = (target_base_address + delta) & ((1 << 64) - 1)
    symbol = symbols_by_value.get(target_address)
    if symbol is None:
        return None

    low_expr = f"{symbol['name']}@rel32@lo+4"
    high_expr = f"{symbol['name']}@rel32@hi+4"
    return {
        "low_instruction_address": int(add_lo["address"]),
        "high_instruction_address": int(add_hi["address"]),
        "low_operand_text": f"{add_lo_operands[0]}, {add_lo_operands[1]}, {low_expr}",
        "high_operand_text": f"{add_hi_operands[0]}, {add_hi_operands[1]}, {high_expr}",
    }


def render_text(
    function: dict,
    symbol: dict | None,
    exact_encoding: bool,
    symbols_by_value: dict[int, dict],
    emit_section_header: bool,
    section_alignment_power: int,
    gap_before: int,
    function_alignment_power: int | None = None,
) -> list[str]:
    lines = [".text"]
    if emit_section_header:
        lines.append(f".p2align {section_alignment_power}")
    if gap_before > 0:
        lines.append(f"  .zero {gap_before}")
    if function_alignment_power is not None:
        lines.append(f".p2align {function_alignment_power}")
    lines.extend(emit_binding(function["name"], symbol))
    lines.extend(emit_visibility(function["name"], symbol))
    lines.extend([f".type {function['name']},@function", f"{function['name']}:"])

    leader_addresses = [block["start_address"] for block in function.get("basic_blocks", [])]
    labels = {
        address: f".L_{function['name']}_{address:016x}"
        for address in leader_addresses
        if address != function["start_address"]
    }
    function_end_address = None
    if symbol and symbol.get("size") is not None:
        function_end_address = function["start_address"] + int(symbol["size"])

    symbolic_refs = {}
    skipped_instruction_addresses = set()
    use_symbolic_pc_relocs = (
        not exact_encoding
        or CodeObjectModel.is_omniprobe_clone_name(str(function.get("name", "")))
    )
    if use_symbolic_pc_relocs:
        symbolic_refs = {
            instruction["address"]: ref
            for index, instruction in enumerate(function["instructions"])
            if (
                ref := detect_pc_relative_symbolic_ref(
                    function, function["instructions"], index, symbols_by_value
                )
            )
        }
        skipped_instruction_addresses = {
            ref["high_instruction_address"] for ref in symbolic_refs.values()
        }
    postamble: list[str] = []
    emitted_labels: set[int] = set()
    for instruction in function["instructions"]:
        address = instruction["address"]
        if address in skipped_instruction_addresses:
            continue
        destination = lines
        if function_end_address is not None and address >= function_end_address:
            destination = postamble
        if address in labels and address not in emitted_labels:
            destination.append(f"{labels[address]}:")
            emitted_labels.add(address)
        if exact_encoding:
            symbolic_ref = symbolic_refs.get(address)
            if symbolic_ref:
                destination.append(
                    f"  {instruction['mnemonic']} {symbolic_ref['low_operand_text']}"
                )
                destination.append(
                    f"  s_addc_u32 {symbolic_ref['high_operand_text']}"
                )
            else:
                encoded_lines = render_encoded_instruction(instruction)
                if encoded_lines:
                    destination.extend(encoded_lines)
                else:
                    destination.append(render_instruction(function, instruction, labels))
        else:
            symbolic_ref = symbolic_refs.get(address)
            if symbolic_ref:
                destination.append(f"  {instruction['mnemonic']} {symbolic_ref['low_operand_text']}")
                destination.append(
                    f"  s_addc_u32 {symbolic_ref['high_operand_text']}"
                )
            else:
                destination.append(render_instruction(function, instruction, labels))

    lines.extend(
        [
            f".L{function['name']}_end:",
            f".size {function['name']}, .L{function['name']}_end-{function['name']}",
        ]
    )
    lines.extend(postamble)
    return lines


def find_kernel_metadata(manifest: dict, function_name: str) -> dict:
    kernels = manifest.get("kernels", {}).get("metadata", {}).get("kernels", [])
    for kernel in kernels:
        if kernel.get("name") == function_name:
            return kernel
    raise SystemExit(f"kernel metadata for {function_name} not found")


def list_manifest_kernel_names(manifest: dict) -> set[str]:
    kernel_symbols = manifest.get("kernels", {}).get("function_symbols", [])
    return {symbol.get("name") for symbol in kernel_symbols if symbol.get("name")}


def list_manifest_helper_names(manifest: dict) -> set[str]:
    helper_symbols = manifest.get("functions", {}).get("helper_symbols", [])
    return {symbol.get("name") for symbol in helper_symbols if symbol.get("name")}


def function_symbol_map(manifest: dict) -> dict[str, dict]:
    records = {}
    for symbol in manifest.get("functions", {}).get("all_symbols", []):
        name = symbol.get("name")
        if name:
            records[name] = choose_preferred_symbol(records.get(name), symbol)
    return records


def find_kernel_descriptor(manifest: dict, function_name: str, kernel_metadata: dict) -> dict:
    wanted_names = {f"{function_name}.kd"}
    symbol = kernel_metadata.get("symbol")
    if symbol:
        wanted_names.add(symbol)

    descriptors = manifest.get("kernels", {}).get("descriptors", [])
    for descriptor in descriptors:
        if descriptor.get("name") in wanted_names or descriptor.get("kernel_name") == function_name:
            return descriptor
    raise SystemExit(f"kernel descriptor for {function_name} not found")


def descriptor_symbol_map(manifest: dict) -> dict[str, dict]:
    records = {}
    for symbol in manifest.get("kernels", {}).get("descriptor_symbols", []):
        name = symbol.get("name")
        if name:
            records[name] = choose_preferred_symbol(records.get(name), symbol)
    return records


def clone_descriptor_regen_names(manifest: dict) -> set[str]:
    regen: set[str] = set()
    for intent in manifest.get("clone_intents", []):
        if not isinstance(intent, dict):
            continue
        descriptor_name = intent.get("clone_descriptor")
        if isinstance(descriptor_name, str) and descriptor_name:
            regen.add(descriptor_name)
    return regen


def select_functions(ir: dict, manifest: dict, explicit_name: str | None) -> list[dict]:
    model = CodeObjectModel.from_manifest(manifest)
    kernel_names = list_manifest_kernel_names(manifest)
    helper_names = list_manifest_helper_names(manifest)
    manifest_names = kernel_names | helper_names
    candidates = [fn for fn in ir.get("functions", []) if fn.get("name") in manifest_names]
    symbol_values = {
        symbol.get("name"): int(symbol.get("value", 0))
        for symbol in manifest.get("functions", {}).get("all_symbols", [])
        if symbol.get("name")
    }
    candidates.sort(
        key=lambda fn: (
            1 if model.is_omniprobe_clone_name(str(fn.get("name", ""))) else 0,
            symbol_values.get(fn.get("name"), int(fn.get("start_address", 0))),
            fn.get("name", ""),
        )
    )

    if explicit_name:
        kernel = next((fn for fn in candidates if fn.get("name") == explicit_name), None)
        if kernel is None or explicit_name not in kernel_names:
            available = ", ".join(sorted(name for name in kernel_names if name))
            raise SystemExit(f"function {explicit_name!r} not found; available kernels: {available}")
        helpers = [fn for fn in candidates if fn.get("name") in helper_names]
        return helpers + [kernel]

    primary_kernel_names = set(model.primary_kernel_names())
    if len(primary_kernel_names) == 1:
        primary_kernel = next(
            (fn for fn in candidates if fn.get("name") in primary_kernel_names),
            None,
        )
        if primary_kernel is not None:
            helpers = [fn for fn in candidates if fn.get("name") in helper_names]
            clone_family = model.kernel_family_name(primary_kernel["name"])
            family_members = {
                fn.get("name")
                for fn in candidates
                if model.kernel_family_name(str(fn.get("name", ""))) == clone_family
            }
            ordered_family = [fn for fn in candidates if fn.get("name") in family_members]
            return helpers + ordered_family

    if not any(fn.get("name") in kernel_names for fn in candidates):
        raise SystemExit("no kernel functions found in IR/manifest intersection")
    return candidates


def iter_operand_tokens(function: dict) -> list[str]:
    tokens = []
    for instruction in function.get("instructions", []):
        operand_text = instruction.get("operand_text", "")
        if operand_text:
            tokens.append(operand_text)
    return tokens


def infer_explicit_next_free_sgpr(function: dict) -> int:
    highest = -1
    for operand_text in iter_operand_tokens(function):
        for start, end in re.findall(r"\bs\[(\d+):(\d+)\]", operand_text):
            highest = max(highest, int(start), int(end))
        for single in re.findall(r"\bs(\d+)\b", operand_text):
            highest = max(highest, int(single))
    return highest + 1 if highest >= 0 else 0


def infer_resource_reservations(function: dict, kernel_metadata: dict) -> dict:
    operand_texts = iter_operand_tokens(function)
    joined = "\n".join(operand_texts)
    total_sgprs = kernel_metadata.get("sgpr_count")

    reserve_vcc = 1 if re.search(r"\bvcc(?:_lo|_hi)?\b", joined) else 0
    remaining = (
        max(0, total_sgprs - infer_explicit_next_free_sgpr(function) - (2 if reserve_vcc else 0))
        if isinstance(total_sgprs, int)
        else 0
    )
    reserve_flat_scratch = 1 if re.search(r"\bflat_scratch(?:_lo|_hi)?\b", joined) else 0
    if not reserve_flat_scratch and remaining >= 4:
        reserve_flat_scratch = 1

    return {
        "reserve_vcc": reserve_vcc,
        "reserve_flat_scratch": reserve_flat_scratch,
    }


def explicit_next_free_vgpr(kernel_metadata: dict, descriptor: dict) -> int:
    granulated = descriptor.get("compute_pgm_rsrc1", {}).get("granulated_workitem_vgpr_count")
    if isinstance(granulated, int):
        return (granulated + 1) * 8
    metadata_count = kernel_metadata.get("vgpr_count")
    if isinstance(metadata_count, int):
        return metadata_count
    return 0


def explicit_next_free_sgpr(kernel_metadata: dict, descriptor: dict) -> int:
    granulated = descriptor.get("compute_pgm_rsrc1", {}).get("granulated_wavefront_sgpr_count")
    if isinstance(granulated, int):
        return (granulated + 1) * 8
    metadata_count = kernel_metadata.get("sgpr_count")
    if isinstance(metadata_count, int):
        return metadata_count
    return 0


def render_kernel_descriptor(
    function: dict,
    descriptor: dict,
    kernel_metadata: dict,
    descriptor_symbol: dict | None,
    preserve_descriptor_bytes: bool,
) -> list[str]:
    if preserve_descriptor_bytes and descriptor.get("bytes_hex"):
        descriptor_name = descriptor.get("name", f"{function['name']}.kd")
        lines = [
            ".rodata",
            ".p2align 6",
        ]
        lines.extend(emit_binding(descriptor_name, descriptor_symbol))
        if descriptor_symbol and descriptor_symbol.get("visibility"):
            lines.extend(emit_visibility(descriptor_name, descriptor_symbol))
        else:
            function_visibility = set((descriptor_symbol or {}).get("visibility", []))
            if not function_visibility and kernel_metadata.get("name") == function["name"]:
                function_visibility = set()
            if "STV_HIDDEN" in function_visibility:
                lines.append(f".hidden {descriptor_name}")
        lines.append(f".type {descriptor_name},@object")
        lines.append(f"{descriptor_name}:")
        lines.extend(emit_data_bytes(bytes.fromhex(descriptor.get("bytes_hex", ""))))
        lines.append(f".size {descriptor_name}, {descriptor.get('size', 64)}")
        return lines

    rsrc1 = descriptor.get("compute_pgm_rsrc1", {})
    rsrc2 = descriptor.get("compute_pgm_rsrc2", {})
    rsrc3 = descriptor.get("compute_pgm_rsrc3", {})
    properties = descriptor.get("kernel_code_properties", {})
    reservations = infer_resource_reservations(function, kernel_metadata)
    descriptor_name = descriptor.get("name", f"{function['name']}.kd")
    next_free_vgpr = explicit_next_free_vgpr(kernel_metadata, descriptor)
    next_free_sgpr = explicit_next_free_sgpr(kernel_metadata, descriptor)

    lines = [
        ".rodata",
        ".p2align 6",
    ]
    lines.extend(emit_binding(descriptor_name, descriptor_symbol))
    lines.extend(emit_visibility(descriptor_name, descriptor_symbol))
    lines.extend([
        f".amdhsa_kernel {function['name']}",
        f"  .amdhsa_group_segment_fixed_size {descriptor.get('group_segment_fixed_size', 0)}",
        f"  .amdhsa_private_segment_fixed_size {descriptor.get('private_segment_fixed_size', 0)}",
        f"  .amdhsa_kernarg_size {descriptor.get('kernarg_size', 0)}",
        f"  .amdhsa_float_round_mode_32 {rsrc1.get('float_round_mode_32', 0)}",
        f"  .amdhsa_float_round_mode_16_64 {rsrc1.get('float_round_mode_16_64', 0)}",
        f"  .amdhsa_float_denorm_mode_32 {rsrc1.get('float_denorm_mode_32', 0)}",
        f"  .amdhsa_float_denorm_mode_16_64 {rsrc1.get('float_denorm_mode_16_64', 0)}",
        f"  .amdhsa_dx10_clamp {rsrc1.get('enable_dx10_clamp', 0)}",
        f"  .amdhsa_ieee_mode {rsrc1.get('enable_ieee_mode', 0)}",
        f"  .amdhsa_fp16_overflow {rsrc1.get('fp16_overflow', 0)}",
        f"  .amdhsa_workgroup_processor_mode {rsrc1.get('workgroup_processor_mode', 0)}",
        f"  .amdhsa_memory_ordered {rsrc1.get('memory_ordered', 0)}",
        f"  .amdhsa_forward_progress {rsrc1.get('forward_progress', 0)}",
        f"  .amdhsa_user_sgpr_private_segment_buffer {properties.get('enable_sgpr_private_segment_buffer', 0)}",
        f"  .amdhsa_user_sgpr_dispatch_ptr {properties.get('enable_sgpr_dispatch_ptr', 0)}",
        f"  .amdhsa_user_sgpr_queue_ptr {properties.get('enable_sgpr_queue_ptr', 0)}",
        f"  .amdhsa_user_sgpr_kernarg_segment_ptr {properties.get('enable_sgpr_kernarg_segment_ptr', 0)}",
        f"  .amdhsa_user_sgpr_dispatch_id {properties.get('enable_sgpr_dispatch_id', 0)}",
        f"  .amdhsa_user_sgpr_flat_scratch_init {properties.get('enable_sgpr_flat_scratch_init', 0)}",
        f"  .amdhsa_user_sgpr_private_segment_size {properties.get('enable_sgpr_private_segment_size', 0)}",
        f"  .amdhsa_system_sgpr_workgroup_id_x {rsrc2.get('enable_sgpr_workgroup_id_x', 0)}",
        f"  .amdhsa_system_sgpr_workgroup_id_y {rsrc2.get('enable_sgpr_workgroup_id_y', 0)}",
        f"  .amdhsa_system_sgpr_workgroup_id_z {rsrc2.get('enable_sgpr_workgroup_id_z', 0)}",
        f"  .amdhsa_system_sgpr_workgroup_info {rsrc2.get('enable_sgpr_workgroup_info', 0)}",
        f"  .amdhsa_system_sgpr_private_segment_wavefront_offset {rsrc2.get('enable_private_segment', 0)}",
        f"  .amdhsa_system_vgpr_workitem_id {rsrc2.get('enable_vgpr_workitem_id', 0)}",
        f"  .amdhsa_user_sgpr_count {rsrc2.get('user_sgpr_count', 0)}",
        f"  .amdhsa_exception_fp_ieee_invalid_op {rsrc2.get('exception_fp_ieee_invalid_op', 0)}",
        f"  .amdhsa_exception_fp_denorm_src {rsrc2.get('exception_fp_denorm_src', 0)}",
        f"  .amdhsa_exception_fp_ieee_div_zero {rsrc2.get('exception_fp_ieee_div_zero', 0)}",
        f"  .amdhsa_exception_fp_ieee_overflow {rsrc2.get('exception_fp_ieee_overflow', 0)}",
        f"  .amdhsa_exception_fp_ieee_underflow {rsrc2.get('exception_fp_ieee_underflow', 0)}",
        f"  .amdhsa_exception_fp_ieee_inexact {rsrc2.get('exception_fp_ieee_inexact', 0)}",
        f"  .amdhsa_exception_int_div_zero {rsrc2.get('exception_int_div_zero', 0)}",
        f"  .amdhsa_next_free_vgpr {next_free_vgpr}",
        f"  .amdhsa_next_free_sgpr {next_free_sgpr}",
        f"  .amdhsa_reserve_vcc {reservations['reserve_vcc']}",
        f"  .amdhsa_reserve_flat_scratch {reservations['reserve_flat_scratch']}",
    ])
    if properties.get("enable_wavefront_size32", 0):
        lines.append("  .amdhsa_wavefront_size32 1")
    if properties.get("uses_dynamic_stack", 0):
        lines.append("  .amdhsa_uses_dynamic_stack 1")
    if properties.get("kernarg_preload_spec_length", 0):
        lines.append(
            "  .amdhsa_user_sgpr_kernarg_preload_length "
            f"{properties.get('kernarg_preload_spec_length', 0)}"
        )
    if properties.get("kernarg_preload_spec_offset", 0):
        lines.append(
            "  .amdhsa_user_sgpr_kernarg_preload_offset "
            f"{properties.get('kernarg_preload_spec_offset', 0)}"
        )
    if rsrc3.get("inst_pref_size", 0):
        lines.append(f"  .amdhsa_inst_pref_size {rsrc3.get('inst_pref_size', 0)}")
    lines.append(".end_amdhsa_kernel")
    return lines


def extract_kernel_metadata_block(raw_metadata: str, kernel_name: str, kernel_symbol: str | None) -> str:
    lines = raw_metadata.splitlines()
    result = ["---", "amdhsa.kernels:"]
    in_kernels = False
    current_kernel: list[str] = []
    capturing = False
    kernel_item_indent: int | None = None
    wanted_symbols = {kernel_name}
    if kernel_symbol:
        wanted_symbols.add(kernel_symbol)

    def flush_current() -> None:
        nonlocal current_kernel, capturing
        if capturing and current_kernel:
            result.extend(current_kernel)
        current_kernel = []
        capturing = False

    for line in lines:
        stripped = line.strip()
        if stripped == "amdhsa.kernels:":
            in_kernels = True
            continue
        if not in_kernels:
            continue
        if stripped.startswith("amdhsa.target:"):
            flush_current()
            result.append(line)
            break
        indent = len(line) - len(line.lstrip(" "))
        if stripped.startswith("- ") and (kernel_item_indent is None or indent == kernel_item_indent):
            if kernel_item_indent is None:
                kernel_item_indent = indent
            flush_current()
            current_kernel = [line]
            capturing = False
            continue
        if current_kernel:
            current_kernel.append(line)
            if stripped.startswith(".name:") or stripped.startswith(".symbol:"):
                value = stripped.split(":", 1)[1].strip().strip("'")
                if value in wanted_symbols:
                    capturing = True
    flush_current()
    return "\n".join(result) + "\n"


def render_metadata(manifest: dict, kernel_name: str | None = None, kernel_symbol: str | None = None) -> list[str]:
    metadata = manifest.get("kernels", {}).get("metadata", {})
    raw = metadata.get("raw") or metadata.get("rendered")
    if not raw and isinstance(metadata.get("object"), dict):
        raise SystemExit(
            "manifest contains exact MessagePack metadata, but no rendered YAML text was captured"
        )
    if not raw:
        return []
    if kernel_name:
        raw = extract_kernel_metadata_block(raw, kernel_name, kernel_symbol)
    lines = [".amdgpu_metadata"]
    lines.extend(raw.rstrip().splitlines())
    lines.append(".end_amdgpu_metadata")
    return lines


def flag_string(flags: list[str]) -> str:
    mapping = {
        "SHF_WRITE": "w",
        "SHF_ALLOC": "a",
        "SHF_EXECINSTR": "x",
        "SHF_MERGE": "M",
        "SHF_STRINGS": "S",
        "SHF_TLS": "T",
    }
    return "".join(mapping[flag] for flag in flags if flag in mapping)


def to_p2align(alignment: int) -> int:
    power = 0
    value = max(1, alignment)
    while (1 << power) < value:
        power += 1
    return power


def emit_data_bytes(payload: bytes) -> list[str]:
    lines: list[str] = []
    for index in range(0, len(payload), 16):
        chunk = payload[index : index + 16]
        bytes_text = ", ".join(f"0x{byte:02x}" for byte in chunk)
        lines.append(f"  .byte {bytes_text}")
    return lines


def render_support_sections(manifest: dict) -> list[str]:
    lines: list[str] = []
    descriptor_names = {
        descriptor.get("name")
        for descriptor in manifest.get("kernels", {}).get("descriptor_symbols", [])
        if descriptor.get("name")
    }
    for section in manifest.get("support_sections", []):
        section_name = section.get("name")
        if section_name not in {".data", ".bss", ".rodata"}:
            continue
        section_directive = f".section {section_name},\"{flag_string(section.get('flags', []))}\""
        if section_name == ".rodata":
            section_directive = '.section .rodata,"a",@progbits'
        lines.extend(
            [
                "",
                section_directive,
                f".p2align {to_p2align(int(section.get('alignment', 1) or 1))}",
            ]
        )
        symbols = sorted(section.get("symbols", []), key=lambda symbol: int(symbol.get("section_offset", 0)))
        offset = 0
        payload = bytes.fromhex(section.get("bytes_hex", ""))
        size = int(section.get("size", 0))
        for symbol in symbols:
            symbol_offset = int(symbol.get("section_offset", 0) or 0)
            if symbol_offset > offset and section_name != ".bss":
                lines.extend(emit_data_bytes(payload[offset:symbol_offset]))
            elif symbol_offset > offset:
                lines.append(f"  .zero {symbol_offset - offset}")
            symbol_name = symbol.get("name")
            symbol_size = int(symbol.get("size", 0) or 0)
            if section_name == ".rodata" and symbol_name in descriptor_names:
                offset = symbol_offset + symbol_size
                continue
            if symbol_name:
                lines.extend(emit_binding(symbol_name, symbol))
                lines.extend(emit_visibility(symbol_name, symbol))
                lines.append(f".type {symbol_name},@object")
                lines.append(f"{symbol_name}:")
            if section_name == ".bss":
                lines.append(f"  .zero {symbol_size}")
            else:
                lines.extend(emit_data_bytes(payload[symbol_offset : symbol_offset + symbol_size]))
            if symbol_name:
                lines.append(f".size {symbol_name}, {symbol_size}")
            offset = symbol_offset + symbol_size
        if offset < size:
            if section_name == ".bss":
                lines.append(f"  .zero {size - offset}")
            else:
                lines.extend(emit_data_bytes(payload[offset:size]))
    return lines


def render_undefined_symbols(manifest: dict) -> list[str]:
    lines: list[str] = []
    seen: set[str] = set()
    for symbol in manifest.get("symbols", []):
        name = symbol.get("name")
        if not name or name in seen:
            continue
        if symbol.get("section") not in {None, "Undefined", "UND"}:
            continue
        binding_lines = emit_binding(name, symbol)
        visibility_lines = emit_visibility(name, symbol)
        if not binding_lines and not visibility_lines:
            continue
        seen.add(name)
        lines.extend(binding_lines)
        lines.extend(visibility_lines)
    return lines


def main() -> int:
    args = parse_args()
    ir_path = Path(args.ir).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()

    ir = json.loads(ir_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    functions = select_functions(ir, manifest, args.function)
    function_symbols = function_symbol_map(manifest)
    descriptor_symbols = descriptor_symbol_map(manifest)
    descriptor_regen_names = clone_descriptor_regen_names(manifest)
    symbols_by_value = build_symbols_by_value(manifest)
    text_section = find_section(manifest, ".text")
    text_alignment = int(text_section.get("alignment", 4) or 4) if text_section else 4
    text_alignment_power = to_p2align(text_alignment)

    lines = [
        ".amdgcn_target \"amdgcn-amd-amdhsa--{}\"".format(ir["arch"])
        if ir.get("arch")
        else ""
    ]
    selected_kernel_name = None
    selected_kernel_symbol = None
    previous_end_address = None
    for index, function in enumerate(functions):
        if lines and lines[-1] != "":
            lines.append("")
        symbol = function_symbols.get(function["name"])
        gap_before = 0
        start_address = int(function["start_address"])
        if previous_end_address is None and text_section is not None:
            section_start = int(text_section.get("address", 0))
            if start_address > section_start:
                gap_before = start_address - section_start
        elif previous_end_address is not None and start_address > previous_end_address:
            gap_before = start_address - previous_end_address
        function_alignment_power = None
        if (
            function["name"] in list_manifest_kernel_names(manifest)
            and CodeObjectModel.is_omniprobe_clone_name(str(function.get("name", "")))
        ):
            # Fresh donor-free kernels are appended after the original text layout,
            # so their source addresses no longer imply a valid entry alignment.
            # Preserve the minimum kernel entry alignment ROCm emits for source kernels.
            function_alignment_power = max(text_alignment_power, 8)
        lines.extend(
            render_text(
                function,
                symbol,
                args.exact_encoding,
                symbols_by_value,
                emit_section_header=index == 0,
                section_alignment_power=text_alignment_power,
                gap_before=gap_before,
                function_alignment_power=function_alignment_power,
            )
        )
        if args.exact_encoding:
            emitted_end_address = int(function.get("end_address", start_address))
            previous_end_address = max(previous_end_address or 0, emitted_end_address)
        else:
            symbol_size = int(symbol.get("size", 0)) if symbol else 0
            if symbol_size > 0:
                previous_end_address = start_address + symbol_size
            else:
                previous_end_address = max(previous_end_address or 0, start_address)
        if function["name"] in list_manifest_kernel_names(manifest):
            kernel_metadata = find_kernel_metadata(manifest, function["name"])
            descriptor = find_kernel_descriptor(manifest, function["name"], kernel_metadata)
            descriptor_symbol = descriptor_symbols.get(descriptor.get("name", ""))
            lines.append("")
            lines.extend(
                render_kernel_descriptor(
                    function,
                    descriptor,
                    kernel_metadata,
                    descriptor_symbol,
                    args.preserve_descriptor_bytes
                    and descriptor.get("name") not in descriptor_regen_names,
                )
            )
            if args.function and function["name"] == args.function:
                selected_kernel_name = function["name"]
                selected_kernel_symbol = kernel_metadata.get("symbol")

    metadata_lines = render_metadata(manifest, selected_kernel_name, selected_kernel_symbol)
    if metadata_lines:
        lines.append("")
        lines.extend(metadata_lines)

    undefined_symbol_lines = render_undefined_symbols(manifest)
    if undefined_symbol_lines:
        lines.append("")
        lines.extend(undefined_symbol_lines)

    lines.extend(render_support_sections(manifest))

    output_path.write_text("\n".join(line for line in lines if line != "") + "\n", encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
