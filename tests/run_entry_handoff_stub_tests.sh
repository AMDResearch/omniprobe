#!/bin/bash
################################################################################
# Entry handoff stub plan tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

RECIPE_TOOL="${REPO_ROOT}/tools/codeobj/emit_entry_handoff_recipe.py"
STUB_TOOL="${REPO_ROOT}/tools/codeobj/emit_entry_handoff_stub.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

echo ""
echo "================================================================================"
echo "Entry Handoff Stub Tests"
echo "================================================================================"
echo "  Tool: $STUB_TOOL"
echo "================================================================================"

if [ ! -f "$RECIPE_TOOL" ] || [ ! -f "$STUB_TOOL" ]; then
    echo -e "${RED}ERROR: required handoff stub tooling is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

run_supported_fixture_stub_test() {
    local arch="$1"
    local fixture="$2"
    local manifest="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="entry_handoff_stub_fixture_${arch}"
    local recipe_json="$OUTPUT_DIR/${test_name}.recipe.json"
    local stub_json="$OUTPUT_DIR/${test_name}.stub.json"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"

    if python3 "$RECIPE_TOOL" \
        "$fixture" \
        --manifest "$manifest" \
        --function entry_abi_kernel \
        --output "$recipe_json" > "$OUTPUT_DIR/${test_name}.recipe.out" && \
       python3 "$STUB_TOOL" "$recipe_json" --output "$stub_json" > "$OUTPUT_DIR/${test_name}.stub.out"; then
        if python3 - "$stub_json" "$arch" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_arch = sys.argv[2]

assert payload["function"] == "entry_abi_kernel"
assert payload["arch"] == expected_arch
assert payload["supported"] is True
assert payload["supported_class"] == {
    "gfx90a": "wave64-packed-v0-10_10_10-flat-scratch-alias-v1",
    "gfx942": "wave64-packed-v0-10_10_10-src-private-base-v1",
}[expected_arch]
assert payload["blockers"] == []
assert payload["handoff_strategy"] == "branch-to-original-entry"
assert payload["branch_transfer_kind"] == "s_setpc_b64"
assert payload["branch_target_symbol"] == "entry_abi_kernel"

required_inputs = {entry["name"]: entry for entry in payload["required_inputs"]}
assert required_inputs["original_launch_kernarg_image"]["source_class"] == "dispatch_carried"
assert required_inputs["workgroup_ids"]["source_class"] == "entry_captured"
assert required_inputs["preserved_entry_workitem_vgprs"]["source_class"] == "entry_captured"
assert required_inputs["wavefront_mode"]["source_class"] == "descriptor_derived"

register_plan = payload["register_plan"]
expected_pair = {
    "gfx90a": [4, 5],
    "gfx942": [0, 1],
}[expected_arch]
expected_private_sgpr = {
    "gfx90a": 11,
    "gfx942": 5,
}[expected_arch]
assert any(entry["kind"] == "sgpr-pair" and entry["target"] == expected_pair for entry in register_plan)
assert any(entry["kind"] == "sgpr" and entry["target"] == expected_private_sgpr for entry in register_plan)
assert any(entry["kind"] == "vgpr" and entry["target"] == 0 for entry in register_plan)
asm = payload["symbolic_asm"]
assert any(f"s_mov_b64 s[{expected_pair[0]}:{expected_pair[1]}], <original_launch_kernarg_image>" in line for line in asm)
assert any(f"s_mov_b32 s{expected_private_sgpr}, <trampoline.entry.private_segment_wave_offset>" in line for line in asm)
assert asm[-1] == "s_setpc_b64 <original_body_entry_symbol_addr_pair>"
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} stub plan emits a supported symbolic reconstruction plan"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} supported fixture stub output was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} supported fixture stub generation failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_supported_fixture_stub_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json"

run_supported_fixture_stub_test \
    "gfx942" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_handoff_stub_fixture_gfx90a_mi210_direct"
MI210_RECIPE="$OUTPUT_DIR/${TEST_NAME}.recipe.json"
MI210_STUB="$OUTPUT_DIR/${TEST_NAME}.stub.json"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 "$RECIPE_TOOL" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.ir.json" \
    --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json" \
    --function mlk_xyz \
    --output "$MI210_RECIPE" > "$OUTPUT_DIR/${TEST_NAME}.recipe.out" && \
   python3 "$STUB_TOOL" "$MI210_RECIPE" --output "$MI210_STUB" > "$OUTPUT_DIR/${TEST_NAME}.stub.out"; then
    if python3 - "$MI210_STUB" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["function"] == "mlk_xyz"
assert payload["arch"] == "gfx90a"
assert payload["supported"] is True
assert payload["supported_class"] == "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"
assert payload["blockers"] == []
assert payload["handoff_strategy"] == "branch-to-original-entry"
assert payload["branch_transfer_kind"] == "s_setpc_b64"
assert payload["branch_target_symbol"] == "mlk_xyz"
required_inputs = {entry["name"]: entry for entry in payload["required_inputs"]}
assert required_inputs["original_launch_kernarg_image"]["source_class"] == "dispatch_carried"
assert required_inputs["workgroup_ids"]["source_class"] == "entry_captured"
assert required_inputs["preserved_entry_workitem_vgprs"]["source_class"] == "entry_captured"
assert required_inputs["wavefront_mode"]["source_class"] == "descriptor_derived"
register_plan = payload["register_plan"]
assert any(entry["kind"] == "sgpr-pair" and entry["target"] == [8, 9] for entry in register_plan)
assert any(
    entry["kind"] == "sgpr" and entry["target"] == 17
    and entry["source"] == "trampoline.entry.private_segment_wave_offset"
    for entry in register_plan
)
assert any(entry["kind"] == "vgpr" and entry["target"] == 2 for entry in register_plan)
asm = payload["symbolic_asm"]
assert any("s_mov_b64 s[8:9], <original_launch_kernarg_image>" in line for line in asm)
assert any("s_mov_b32 s17, <trampoline.entry.private_segment_wave_offset>" in line for line in asm)
assert asm[-1] == "s_setpc_b64 <original_body_entry_symbol_addr_pair>"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Real MI210 fixture stub plan emits the expected wave64 direct-VGPR reconstruction"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real MI210 fixture stub output was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real MI210 fixture stub generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_handoff_stub_fixture_gfx942_real_single_vgpr"
REAL_GFX942_RECIPE="$OUTPUT_DIR/${TEST_NAME}.recipe.json"
REAL_GFX942_STUB="$OUTPUT_DIR/${TEST_NAME}.stub.json"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 "$RECIPE_TOOL" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    --function Cijk_S_GA \
    --output "$REAL_GFX942_RECIPE" > "$OUTPUT_DIR/${TEST_NAME}.recipe.out" && \
   python3 "$STUB_TOOL" "$REAL_GFX942_RECIPE" --output "$REAL_GFX942_STUB" > "$OUTPUT_DIR/${TEST_NAME}.stub.out"; then
    if python3 - "$REAL_GFX942_STUB" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["function"] == "Cijk_S_GA"
assert payload["arch"] == "gfx942"
assert payload["supported"] is True
assert payload["supported_class"] == "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1"
assert payload["blockers"] == []
assert payload["handoff_strategy"] == "branch-to-original-entry"
assert payload["branch_transfer_kind"] == "s_setpc_b64"
assert payload["branch_target_symbol"] == "Cijk_S_GA"
required_inputs = {entry["name"]: entry for entry in payload["required_inputs"]}
assert set(required_inputs) == {
    "original_launch_kernarg_image",
    "workgroup_ids",
    "preserved_entry_workitem_vgprs",
    "wavefront_mode",
}
assert required_inputs["original_launch_kernarg_image"]["source_class"] == "dispatch_carried"
assert required_inputs["workgroup_ids"]["source_class"] == "entry_captured"
assert required_inputs["preserved_entry_workitem_vgprs"]["source_class"] == "entry_captured"
assert required_inputs["wavefront_mode"]["source_class"] == "descriptor_derived"
register_plan = payload["register_plan"]
assert any(entry["kind"] == "sgpr-pair" and entry["target"] == [0, 1] for entry in register_plan)
assert any(
    entry["kind"] == "sgpr" and entry["target"] == 2
    and entry["source"] == "dispatch.workgroup_id_x"
    for entry in register_plan
)
assert any(entry["kind"] == "vgpr" and entry["target"] == 0 for entry in register_plan)
assert not any(entry["kind"] == "sgpr" and entry["source"] == "trampoline.entry.private_segment_wave_offset" for entry in register_plan)
asm = payload["symbolic_asm"]
assert any("s_mov_b64 s[0:1], <original_launch_kernarg_image>" in line for line in asm)
assert any("s_mov_b32 s2, <dispatch.workgroup_id_x>" in line for line in asm)
assert any("v_mov_b32_e32 v0, <preserved_entry_vgpr[0]>" in line for line in asm)
assert asm[-1] == "s_setpc_b64 <original_body_entry_symbol_addr_pair>"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Real gfx942 single-VGPR fixture stub plan emits the expected symbolic reconstruction"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR fixture stub output was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR fixture stub generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_handoff_stub_mlk_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "  ${YELLOW}SKIP${NC} - Required hsaco is not built: $MODULE_LOAD_PLAIN_HSACO"
else
    MLK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"
    MLK_IR="$OUTPUT_DIR/${TEST_NAME}.ir.json"
    MLK_RECIPE="$OUTPUT_DIR/${TEST_NAME}.recipe.json"
    MLK_STUB="$OUTPUT_DIR/${TEST_NAME}.stub.json"
    python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MLK_MANIFEST" >/dev/null
    python3 "$DISASM_TO_IR" "$MODULE_LOAD_PLAIN_HSACO" --manifest "$MLK_MANIFEST" --output "$MLK_IR" >/dev/null
    python3 "$RECIPE_TOOL" "$MLK_IR" --manifest "$MLK_MANIFEST" --function mlk --output "$MLK_RECIPE" >/dev/null
    if python3 "$STUB_TOOL" "$MLK_RECIPE" --output "$MLK_STUB" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
        if python3 - "$MLK_STUB" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["function"] == "mlk"
assert payload["supported"] is True
assert payload["supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert payload["handoff_strategy"] == "branch-to-original-entry"
assert payload["branch_transfer_kind"] == "s_setpc_b64"
assert payload["branch_target_symbol"] == "mlk"
required_inputs = {entry["name"]: entry for entry in payload["required_inputs"]}
assert required_inputs["original_launch_kernarg_image"]["source_class"] == "dispatch_carried"
assert required_inputs["original_launch_kernarg_image"]["acquisition"] == "hidden_handoff.original_kernarg_pointer"
assert required_inputs["workgroup_ids"]["source_class"] == "entry_captured"
assert required_inputs["trampoline_private_segment_wave_offset"]["source_class"] == "entry_captured"
assert required_inputs["preserved_entry_workitem_vgprs"]["source_class"] == "entry_captured"
assert required_inputs["wavefront_mode"]["source_class"] == "descriptor_derived"
register_plan = payload["register_plan"]
assert any(entry["kind"] == "sgpr-pair" and entry["target"] == [8, 9] and entry["source"] == "original_launch_kernarg_image" for entry in register_plan)
assert any(entry["kind"] == "sgpr" and entry["target"] == 17 and entry["source"] == "trampoline.entry.private_segment_wave_offset" for entry in register_plan)
assert any(entry["kind"] == "vgpr" and entry["target"] == 2 and entry["source"] == "preserved_entry_vgpr[2]" for entry in register_plan)
asm = payload["symbolic_asm"]
assert any("s_mov_b64 s[8:9], <original_launch_kernarg_image>" in line for line in asm)
assert any("s_mov_b32 s17, <trampoline.entry.private_segment_wave_offset>" in line for line in asm)
assert asm[-1] == "s_setpc_b64 <original_body_entry_symbol_addr_pair>"
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Real mlk handoff stub plan emits the expected register reconstruction and branch transfer"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Real mlk handoff stub output was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real mlk handoff stub generation failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
