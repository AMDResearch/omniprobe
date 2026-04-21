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
assert payload["supported_class"] == "rdna-gfx1030-wave32-kernarg-sgpr8-9-workgroup-xyz-private17-vgpr3"
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
