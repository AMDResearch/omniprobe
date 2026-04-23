#!/bin/bash
################################################################################
# Entry resume matrix tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

MATRIX_TOOL="${REPO_ROOT}/tools/codeobj/emit_entry_resume_matrix.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

echo ""
echo "================================================================================"
echo "Entry Resume Matrix Tests"
echo "================================================================================"
echo "  Tool: $MATRIX_TOOL"
echo "================================================================================"

if [ ! -f "$MATRIX_TOOL" ]; then
    echo -e "${RED}ERROR: required resume matrix tooling is missing${NC}"
    exit 1
fi

WORK_DIR="$OUTPUT_DIR/entry_resume_matrix"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_resume_matrix_fixture_set"
CASES_JSON="$WORK_DIR/${TEST_NAME}.cases.json"
OUTPUT_JSON="$WORK_DIR/${TEST_NAME}.json"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the resume matrix normalizes supported resume requirements across gfx1030 and gfx942 fixture families"

python3 - "$SCRIPT_DIR" "$CASES_JSON" <<'PY'
import json
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve()
output_path = Path(sys.argv[2]).resolve()
payload = {
    "cases": [
        {
            "id": "gfx1030_fixture",
            "label": "Synthetic gfx1030 entry slice",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx1030.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx1030.manifest.json"),
            "function": "entry_abi_kernel",
        },
        {
            "id": "gfx942_packed_fixture",
            "label": "Synthetic gfx942 packed entry slice",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942.manifest.json"),
            "function": "entry_abi_kernel",
        },
        {
            "id": "gfx942_real_single_vgpr",
            "label": "Real gfx942 single-VGPR body entry",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json"),
            "function": "Cijk_S_GA",
        },
        {
            "id": "gfx942_real_mlk_xyz",
            "label": "Real gfx942 multi-VGPR body entry",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json"),
            "function": "mlk_xyz",
        },
    ]
}
output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if python3 "$MATRIX_TOOL" "$CASES_JSON" --output "$OUTPUT_JSON" > "$WORK_DIR/${TEST_NAME}.out"; then
    if python3 - "$OUTPUT_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["schema"] == "omniprobe.entry_resume_matrix.v1"
assert payload["generator"] == "emit_entry_resume_matrix.py"
assert "compiler-generated live-ins or builtins" in payload["helper_contract_note"]
cases = {entry["id"]: entry for entry in payload["cases"]}
assert set(cases) == {
    "gfx1030_fixture",
    "gfx942_packed_fixture",
    "gfx942_real_single_vgpr",
    "gfx942_real_mlk_xyz",
}

gfx1030 = cases["gfx1030_fixture"]
assert gfx1030["supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert gfx1030["entry_shape"]["wavefront_size"] == 32
assert gfx1030["entry_shape"]["private_pattern"] == "setreg_flat_scratch_init"
assert gfx1030["helper_policy"]["compiler_generated_builtins_allowed"] is False
assert gfx1030["helper_policy"]["requires_wrapper_captured_state"] is True
assert gfx1030["resume_requirements"]["dispatch_payload_fields"] == ["original_kernarg_pointer"]
assert "entry_workitem_id_x" in gfx1030["resume_requirements"]["entry_snapshot_fields"]
assert "private_segment_wave_offset" in gfx1030["resume_requirements"]["entry_snapshot_fields"]
assert "no-independent-entry-workitem-vgpr-source" in gfx1030["resume_requirements"]["current_wrapper_blockers"]

gfx942_packed = cases["gfx942_packed_fixture"]
assert gfx942_packed["supported_class"] == "wave64-packed-v0-10_10_10-src-private-base-v1"
assert gfx942_packed["entry_shape"]["wavefront_size"] == 64
assert gfx942_packed["entry_shape"]["workitem_pattern"] == "packed_v0_10_10_10_unpack"
assert gfx942_packed["entry_shape"]["private_pattern"] == "src_private_base"

gfx942_single = cases["gfx942_real_single_vgpr"]
assert gfx942_single["supported_class"] == "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1"
assert gfx942_single["entry_shape"]["workitem_vgpr_count"] == 1
assert gfx942_single["resume_requirements"]["entry_snapshot_fields"] == [
    "workgroup_id_x",
    "entry_workitem_id_x",
]
assert "requires-original-private-state-or-supplemental-handoff" not in gfx942_single["resume_requirements"]["current_wrapper_blockers"]

gfx942_real = cases["gfx942_real_mlk_xyz"]
assert gfx942_real["supported_class"] == "wave64-direct-vgpr-xyz-src-private-base-v1"
assert gfx942_real["entry_shape"]["private_pattern"] == "src_private_base"
assert "entry_private_base_lo" in gfx942_real["resume_requirements"]["entry_snapshot_fields"]

summary = {
    entry["supported_class"]: entry
    for entry in payload["class_summary"]
    if entry["supported_class"] is not None
}
assert summary["wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"]["arches"] == ["gfx1030"]
assert summary["wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"]["dispatch_payload_fields"] == ["original_kernarg_pointer"]
assert "entry_workitem_id_x" in summary["wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"]["entry_snapshot_fields"]
assert summary["wave64-single-vgpr-x-workgroup-x-kernarg-only-v1"]["case_ids"] == ["gfx942_real_single_vgpr"]
assert summary["wave64-direct-vgpr-xyz-src-private-base-v1"]["case_ids"] == ["gfx942_real_mlk_xyz"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Fixture resume matrix captures the expected per-class resume requirements"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Fixture resume matrix output was incorrect"
        echo "  Output saved to: $OUTPUT_JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Fixture resume matrix generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_resume_matrix_runtime_mlk"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the resume matrix accepts a built runtime mlk hsaco and emits a compatible real-body resume profile"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -f "$INSPECT_CODE_OBJECT" ] || [ ! -f "$DISASM_TO_IR" ]; then
    echo -e "  ${YELLOW}SKIP${NC} - Required runtime hsaco or inspection tooling is not available"
else
    RUNTIME_MANIFEST="$WORK_DIR/${TEST_NAME}.manifest.json"
    RUNTIME_IR="$WORK_DIR/${TEST_NAME}.ir.json"
    RUNTIME_CASES="$WORK_DIR/${TEST_NAME}.cases.json"
    RUNTIME_OUTPUT="$WORK_DIR/${TEST_NAME}.json"

    python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$RUNTIME_MANIFEST" >/dev/null
    python3 "$DISASM_TO_IR" "$MODULE_LOAD_PLAIN_HSACO" --manifest "$RUNTIME_MANIFEST" --output "$RUNTIME_IR" >/dev/null
    python3 - "$RUNTIME_IR" "$RUNTIME_MANIFEST" "$RUNTIME_CASES" <<'PY'
import json
import sys
from pathlib import Path

ir_path = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
cases_path = Path(sys.argv[3]).resolve()
payload = {
    "cases": [
        {
            "id": "runtime_mlk",
            "label": "Built runtime mlk kernel",
            "ir": str(ir_path),
            "manifest": str(manifest_path),
            "function": "mlk",
        }
    ]
}
cases_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

    if python3 "$MATRIX_TOOL" "$RUNTIME_CASES" --output "$RUNTIME_OUTPUT" > "$WORK_DIR/${TEST_NAME}.out"; then
        if python3 - "$RUNTIME_OUTPUT" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
case = payload["cases"][0]
assert case["id"] == "runtime_mlk"
assert case["function"] == "mlk"
assert case["supported"] is True
assert case["supported_class"] in {
    "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1",
    "wave64-direct-vgpr-xyz-src-private-base-v1",
    "wave64-direct-vgpr-xyz-flat-scratch-alias-v1",
}
assert case["resume_requirements"]["dispatch_payload_fields"] == ["original_kernarg_pointer"]
assert "entry_workitem_id_x" in case["resume_requirements"]["entry_snapshot_fields"]
assert case["helper_policy"]["compiler_generated_liveins_allowed"] is False
assert case["helper_policy"]["requires_runtime_dispatch_payload"] is True
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Runtime mlk hsaco emits a compatible real-body resume profile"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Runtime mlk resume matrix output was incorrect"
            echo "  Output saved to: $RUNTIME_OUTPUT"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Runtime mlk resume matrix generation failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
