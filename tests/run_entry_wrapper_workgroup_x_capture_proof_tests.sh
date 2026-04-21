#!/bin/bash
################################################################################
# Entry-wrapper workgroup-x capture proof tests
#
# Validates the first real wrapper-side entry_snapshot capture slice:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-workgroup-x-capture-proof
#   2. confirm the regeneration report declares workgroup_id_x capture into the
#      wrapper-owned hidden handoff storage
#   3. confirm the rebuilt assembly restores s8:s9, then stores s14 through a
#      VGPR-backed flat_store_dword path before the branch handoff
#   4. launch through the HSA runtime with a single-workgroup dispatch and
#      verify the host can observe hidden_ctx.workgroup_id_x == 0 after launch
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
    echo -e "${YELLOW}SKIP: Entry-wrapper workgroup-x capture proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_workgroup_x_capture_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_workgroup_x_capture_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_workgroup_x_capture_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_workgroup_x_capture_proof.manifest.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_workgroup_x_capture_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_workgroup_x_capture_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_workgroup_x_capture_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Workgroup-X Capture Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-workgroup-x-capture-proof \
    --kernel mlk \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_x_capture_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares workgroup_id_x capture into hidden handoff storage"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-workgroup-x-capture-proof"
assert entry.get("wrapper_size") == 72
hidden = entry.get("wrapper_hidden_handoff", {})
assert hidden.get("restored_actions") == ["materialize-kernarg-base-pair"]
captured = hidden.get("captured_entry_snapshot_fields", [])
assert len(captured) == 1
field = captured[0]
assert field["name"] == "workgroup_id_x"
assert field["offset"] == 8
assert field["kind"] == "u32_from_sgpr"
assert field["store_opcode"] == "flat_store_dword"
assert field["source_sgpr"] == 14
assert field["address_vgprs"] == [4, 5]
assert field["data_vgpr"] == 6
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Workgroup-x capture proof report captured the expected wrapper-side snapshot contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workgroup-x capture proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_x_capture_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt assembly restores s8:s9 and emits the expected capture store"

if [ -f "$PROOF_ASM" ] && \
   python3 - "$PROOF_REPORT" "$PROOF_ASM" <<'PY'
import json
import sys
from pathlib import Path

report = json.load(open(sys.argv[1], encoding="utf-8"))
asm = Path(sys.argv[2]).read_text(encoding="utf-8")
lo, hi = report["entry_wrapper_result"]["scratch_pair"]
offset = report["entry_wrapper_result"]["wrapper_hidden_handoff"]["offset"]
needles = [
    f"s_load_dwordx2 s[{lo}:{hi}], s[8:9], 0x{offset:x}",
    "s_mov_b32 s8, 0",
    "s_mov_b32 s9, 0",
    f"s_load_dwordx2 s[8:9], s[{lo}:{hi}], 0x0",
    f"s_load_dwordx2 s[{lo}:{hi}], s[8:9], 0x{offset:x}",
    f"s_add_u32 s{lo}, s{lo}, 0x8",
    f"s_addc_u32 s{hi}, s{hi}, 0",
    f"v_mov_b32_e32 v4, s{lo}",
    f"v_mov_b32_e32 v5, s{hi}",
    "v_mov_b32_e32 v6, s14",
    "flat_store_dword v[4:5], v6",
]
for needle in needles:
    assert needle in asm, needle
assert asm.count(f"s_load_dwordx2 s[{lo}:{hi}], s[8:9], 0x{offset:x}") == 2
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt assembly contains the expected wrapper-side capture sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt assembly did not contain the expected wrapper-side capture sequence"
    echo "  Assembly saved to: $PROOF_ASM"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workgroup_x_capture_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate single-workgroup HSA launch captures workgroup_id_x=0 into hidden_ctx"

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
   --single-workgroup > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Workgroup-x capture proof hsaco launches successfully and exposes the captured value through hidden_ctx"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workgroup-x capture proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
