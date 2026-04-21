#!/bin/bash
################################################################################
# Entry handoff recipe tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

RECIPE_TOOL="${REPO_ROOT}/tools/codeobj/emit_entry_handoff_recipe.py"
ANALYZE_ABI="${REPO_ROOT}/tools/codeobj/analyze_amdgpu_entry_abi.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

echo ""
echo "================================================================================"
echo "Entry Handoff Recipe Tests"
echo "================================================================================"
echo "  Tool: $RECIPE_TOOL"
echo "================================================================================"

if [ ! -f "$RECIPE_TOOL" ] || [ ! -f "$ANALYZE_ABI" ]; then
    echo -e "${RED}ERROR: required handoff recipe tooling is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_handoff_recipe_fixture_gfx1030"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
FIXTURE_OUTPUT="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$RECIPE_TOOL" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
    --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
    --function entry_abi_kernel \
    --output "$FIXTURE_OUTPUT" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$FIXTURE_OUTPUT" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["function"] == "entry_abi_kernel"
assert payload["supported"] is True
assert payload["supported_class"] == "rdna-gfx1030-wave32-kernarg-sgpr8-9-workgroup-xyz-private17-vgpr3"
actions = payload["reconstruction_actions"]
assert actions[0]["action"] == "materialize-kernarg-base-pair"
assert actions[0]["target_sgprs"] == [4, 5]
assert any(
    entry["action"] == "materialize-system-sgpr" and entry["role"] == "workgroup_id_x" and entry["target_sgpr"] == 8
    for entry in actions
)
assert any(
    entry["action"] == "materialize-entry-workitem-vgprs" and entry["count"] == 3
    for entry in actions
)
wrapper = payload["wrapper_source_analysis"]
assert wrapper["model"] == "direct-entry-wrapper-v1"
assert wrapper["direct_branch_supported"] is True
assert wrapper["reconstruction_after_clobber_supported"] is False
assert "no-independent-kernarg-source-in-current-wrapper" in wrapper["reconstruction_after_clobber_blockers"]
handoff = payload["supplemental_handoff_contract"]
assert handoff["schema"] == "omniprobe.entry_handoff.hidden_v1"
assert handoff["required"] is True
fields = {entry["name"]: entry for entry in handoff["fields"]}
assert fields["original_kernarg_pointer"]["source_class"] == "dispatch_carried"
assert fields["workgroup_id_x"]["source_class"] == "entry_captured"
assert fields["workgroup_id_x"]["variability"] == "workgroup_variant"
assert fields["private_segment_wave_offset"]["source_class"] == "entry_captured"
validation = {entry["name"]: entry for entry in handoff["validation_requirements"]}
assert validation["wavefront_size"]["source_class"] == "descriptor_derived"
runtime_objects = handoff["runtime_objects"]
dispatch_payload = {entry["name"]: entry for entry in runtime_objects["dispatch_payload"]["fields"]}
entry_snapshot = {entry["name"]: entry for entry in runtime_objects["entry_snapshot"]["fields"]}
assert "original_kernarg_pointer" in dispatch_payload
assert "workgroup_id_x" in entry_snapshot
assert "private_segment_wave_offset" in entry_snapshot
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Fixture handoff recipe emits the expected supported-class reconstruction plan"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Fixture handoff recipe output was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Fixture handoff recipe generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_handoff_recipe_mlk_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "  ${YELLOW}SKIP${NC} - Required hsaco is not built: $MODULE_LOAD_PLAIN_HSACO"
else
    MLK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"
    MLK_IR="$OUTPUT_DIR/${TEST_NAME}.ir.json"
    MLK_OUTPUT="$OUTPUT_DIR/${TEST_NAME}.json"
    python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MLK_MANIFEST" >/dev/null
    python3 "$DISASM_TO_IR" "$MODULE_LOAD_PLAIN_HSACO" --manifest "$MLK_MANIFEST" --output "$MLK_IR" >/dev/null
    if python3 "$RECIPE_TOOL" \
        "$MLK_IR" \
        --manifest "$MLK_MANIFEST" \
        --function mlk \
        --output "$MLK_OUTPUT" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
        if python3 - "$MLK_OUTPUT" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["function"] == "mlk"
assert payload["supported"] is True
assert payload["supported_class"] == "rdna-gfx1030-wave32-kernarg-sgpr8-9-workgroup-xyz-private17-vgpr3"
assert payload["descriptor_summary"]["kernarg_size"] == 272
assert payload["descriptor_summary"]["user_sgpr_count"] == 14
assert payload["kernel_metadata_summary"]["sgpr_count"] == 36
assert payload["kernel_metadata_summary"]["vgpr_count"] == 32
actions = payload["reconstruction_actions"]
assert actions[0]["action"] == "materialize-kernarg-base-pair"
assert actions[0]["target_sgprs"] == [8, 9]
assert any(
    entry["action"] == "materialize-system-sgpr" and entry["role"] == "private_segment_wave_offset" and entry["target_sgpr"] == 17
    for entry in actions
)
assert any(
    entry["action"] == "materialize-private-segment-state" and entry["pattern_class"] == "setreg_flat_scratch_init"
    for entry in actions
)
wrapper = payload["wrapper_source_analysis"]
assert wrapper["model"] == "direct-entry-wrapper-v1"
assert wrapper["direct_branch_supported"] is True
assert wrapper["reconstruction_after_clobber_supported"] is False
assert "no-independent-current-workgroup-id-source" in wrapper["reconstruction_after_clobber_blockers"]
handoff = payload["supplemental_handoff_contract"]
assert handoff["schema"] == "omniprobe.entry_handoff.hidden_v1"
assert handoff["required"] is True
fields = {entry["name"]: entry for entry in handoff["fields"]}
assert fields["original_kernarg_pointer"]["source_class"] == "dispatch_carried"
assert fields["entry_workitem_id_x"]["source_class"] == "entry_captured"
assert fields["entry_workitem_id_x"]["variability"] == "lane_variant"
assert fields["entry_private_base_lo"]["source_class"] == "entry_captured"
validation = {entry["name"]: entry for entry in handoff["validation_requirements"]}
assert validation["wavefront_size"]["source_class"] == "descriptor_derived"
runtime_objects = handoff["runtime_objects"]
dispatch_payload = {entry["name"]: entry for entry in runtime_objects["dispatch_payload"]["fields"]}
entry_snapshot = {entry["name"]: entry for entry in runtime_objects["entry_snapshot"]["fields"]}
assert "original_kernarg_pointer" in dispatch_payload
assert "entry_workitem_id_x" in entry_snapshot
assert "entry_private_base_lo" in entry_snapshot
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Real mlk hsaco yields a concrete original-body reconstruction recipe"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Real mlk handoff recipe output was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real mlk handoff recipe generation failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
