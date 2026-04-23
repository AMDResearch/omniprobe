#!/bin/bash
################################################################################
# Entry-wrapper workgroup-xyz capture-restore proof tests
#
# Validates the first closed-loop entry_snapshot reconstruction slice:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-workgroup-xyz-capture-restore-proof
#   2. confirm the regeneration report declares x/y/z capture plus x/y/z
#      restoration from the captured snapshot fields
#   3. confirm the rebuilt assembly emits capture stores before clobber+reload
#   4. launch through the HSA runtime with a single-workgroup dispatch and
#      verify the imported body still executes correctly while hidden_ctx
#      exposes the captured values
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
HSA_LAUNCH_TEST="${BUILD_DIR}/tools/test_hsa_module_launch"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -x "$HSA_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Entry-wrapper workgroup-xyz capture-restore proof artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Expected: $HSA_LAUNCH_TEST"
    echo "  Build with: cmake --build build --target module_load_kernel_plain_hsaco test_hsa_module_launch"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm LLVM tools not found${NC}"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/entry_wrapper_workgroup_xyz_capture_restore_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.manifest.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_workgroup_xyz_capture_restore_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Workgroup-XYZ Capture-Restore Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-workgroup-xyz-capture-restore-proof \
    --kernel mlk \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_xyz_capture_restore_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares workgroup_id_x/y/z capture plus restoration"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-workgroup-xyz-capture-restore-proof"
assert entry.get("wrapper_size") == 172
hidden = entry.get("wrapper_hidden_handoff", {})
assert hidden.get("restored_actions") == [
    "materialize-system-sgpr:workgroup_id_x",
    "materialize-system-sgpr:workgroup_id_y",
    "materialize-system-sgpr:workgroup_id_z",
    "materialize-kernarg-base-pair",
]
captured = hidden.get("captured_entry_snapshot_fields", [])
assert [field["name"] for field in captured] == [
    "workgroup_id_x",
    "workgroup_id_y",
    "workgroup_id_z",
]
consumed = hidden.get("consumed_fields", [])
assert [field["name"] for field in consumed] == [
    "workgroup_id_x",
    "workgroup_id_y",
    "workgroup_id_z",
    "original_kernarg_pointer",
]
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Workgroup-xyz capture-restore proof report captured the expected closed-loop contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workgroup-xyz capture-restore proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_xyz_capture_restore_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt assembly captures x/y/z before clobber+reload"

if [ -f "$PROOF_ASM" ] && \
   python3 - "$PROOF_REPORT" "$PROOF_ASM" <<'PY'
import json
import sys
from pathlib import Path

report = json.load(open(sys.argv[1], encoding="utf-8"))
asm = Path(sys.argv[2]).read_text(encoding="utf-8")
lo, hi = report["entry_wrapper_result"]["scratch_pair"]
hidden = report["entry_wrapper_result"]["wrapper_hidden_handoff"]
offset = hidden["offset"]
load_lo, load_hi = hidden["load_source_pair"]
captured = hidden["captured_entry_snapshot_fields"]
consumed = hidden["consumed_fields"]
kernarg_field = consumed[-1]
target_lo, target_hi = kernarg_field["target_pair"]
needles = [
    f"s_load_dwordx2 s[{lo}:{hi}], s[{load_lo}:{load_hi}], 0x{offset:x}",
    "flat_store_dword v[4:5], v6",
    f"s_load_dwordx2 s[{target_lo}:{target_hi}], s[{lo}:{hi}], 0x{kernarg_field['offset']:x}",
]
for needle in needles:
    assert needle in asm, needle
assert asm.count("flat_store_dword v[4:5], v6") == 3
for field in captured:
    name = field["name"]
    source = int(field["source_sgpr"])
    consumed_field = next(item for item in consumed if item["name"] == name)
    target = int(consumed_field["target_sgpr"])
    field_offset = int(field["offset"])
    assert f"v_mov_b32_e32 v6, s{source}" in asm
    assert f"s_mov_b32 s{target}, 0" in asm
    assert f"s_load_dword s{target}, s[{lo}:{hi}], 0x{field_offset:x}" in asm
    assert asm.index(f"v_mov_b32_e32 v6, s{source}") < asm.index(f"s_mov_b32 s{target}, 0")
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt assembly contains the expected closed-loop capture/restore sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt assembly did not contain the expected closed-loop capture/restore sequence"
    echo "  Assembly saved to: $PROOF_ASM"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_xyz_capture_restore_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate single-workgroup HSA launch preserves original behavior and exposes captured x/y/z"

HIDDEN_CTX_OFFSET="$(python3 - <<'PY' "$PROOF_REPORT"
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
hidden = report["entry_wrapper_result"]["wrapper_hidden_handoff"]
print(hidden["offset"])
PY
)"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$PROOF_HSACO" mlk.kd index \
   --hidden-ctx-offset "$HIDDEN_CTX_OFFSET" \
   --populate-original-kernarg-pointer \
   --verify-hidden-u32 8 0 \
   --verify-hidden-u32 12 0 \
   --verify-hidden-u32 16 0 \
   --single-workgroup > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Workgroup-xyz capture-restore proof hsaco launches successfully and preserves the imported body ABI slice"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workgroup-xyz capture-restore proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
