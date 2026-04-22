#!/bin/bash
################################################################################
# Entry-wrapper workitem-VGPR capture-restore proof tests
#
# Validates a fail-closed proof slice for preserving entry workitem VGPR state
# through an Omniprobe-owned entry wrapper:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-workitem-vgpr-capture-restore-proof targeting mlk_xyz
#   2. confirm the regeneration report declares the private-tail spill/restore
#      plan for the entry workitem VGPRs
#   3. confirm the rebuilt wrapper IR spills v0/v1/v2, clobbers them, reloads
#      them from the grown private tail, and then branches to the original body
#   4. launch through the HSA runtime with a single 3D workgroup and verify the
#      imported body still observes the original threadIdx.{x,y,z} contract
#   5. launch both the plain and wrapped kernels under the default multi-
#      workgroup grid and verify they preserve the source kernel's real
#      first-block-only behavior, since mlk_xyz indexes by threadIdx only
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

mkdir -p "$OUTPUT_DIR"

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
HSA_LAUNCH_TEST="${BUILD_DIR}/tools/test_hsa_module_launch"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -x "$HSA_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Entry-wrapper workitem-VGPR proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_workitem_vgpr_capture_restore_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.manifest.json"
PROOF_IR="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.ir.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_workitem_vgpr_capture_restore_proof.stderr"
LAUNCH_OUT="$WORK_DIR/launch.out"
BASELINE_MULTIWORKGROUP_OUT="$WORK_DIR/baseline_multiworkgroup_launch.out"
PROOF_MULTIWORKGROUP_OUT="$WORK_DIR/proof_multiworkgroup_launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Workitem-VGPR Capture-Restore Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
    --kernel mlk_xyz \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null
python3 "$DISASM_TO_IR" \
    "$PROOF_HSACO" \
    --manifest "$PROOF_MANIFEST" \
    --output "$PROOF_IR" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_vgpr_capture_restore_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares the private-tail workitem spill/restore contract"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-workitem-vgpr-capture-restore-proof"
assert entry.get("source_kernel") == "mlk_xyz"
assert entry.get("scratch_pair") == [14, 15]
assert entry.get("preconditions", {}).get("secondary_scratch_pair") == [14, 15]
workitem = entry.get("workitem_spill_restore", {})
assert workitem.get("enabled") is True
assert workitem.get("source_vgprs") == [0, 1, 2]
assert workitem.get("spill_offset") == 192
assert workitem.get("spill_bytes") == 12
assert workitem.get("private_segment_growth") == 16
assert workitem.get("save_pair") == [12, 13]
assert workitem.get("soffset_sgpr") == 14
assert workitem.get("private_segment_pattern_class") == "src_private_base"
assert workitem.get("private_segment_offset_source_sgpr") == 11
assert workitem.get("address_vgprs") == [40, 41]
assert workitem.get("data_pair_vgprs") == [42, 43]
assert workitem.get("tail_data_vgpr") == 44
assert workitem.get("required_total_vgprs") == 45
assert entry.get("entry_handoff_recipe", {}).get("entry_requirements", {}).get(
    "entry_workitem_vgpr_count"
) == 3
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Workitem-VGPR proof report captured the expected spill/restore contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workitem-VGPR proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_vgpr_capture_restore_ir"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt wrapper IR spills, clobbers, and restores v0/v1/v2 before branch handoff"

if [ -f "$PROOF_IR" ] && \
   python3 - "$PROOF_IR" <<'PY'
import json
import sys

ir = json.load(open(sys.argv[1], encoding="utf-8"))
wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "mlk_xyz")
instructions = wrapper.get("instructions", [])

def find_index(mnemonic, operand_text, start=0):
    for idx in range(start, len(instructions)):
        insn = instructions[idx]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return idx
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")

save_lo = find_index("s_mov_b32", "s12, s0")
save_hi = find_index("s_mov_b32", "s13, s1")
private_base_0 = find_index("s_mov_b64", "s[0:1], src_private_base")
spill_add_0 = find_index("s_add_u32", "s0, s0, 0xc0")
addr_lo_0 = find_index("v_mov_b32_e32", "v40, s0")
addr_hi_0 = find_index("v_mov_b32_e32", "v41, s1")
pair_lo_0 = find_index("v_mov_b32_e32", "v42, v0")
pair_hi_0 = find_index("v_mov_b32_e32", "v43, v1")
save_pair = find_index("flat_store_dwordx2", "v[40:41], v[42:43]")
tail_copy = find_index("v_mov_b32_e32", "v44, v2")
tail_add_0 = find_index("s_add_u32", "s0, s0, 8", tail_copy + 1)
save_tail = find_index("flat_store_dword", "v[40:41], v44")
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s12")
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s13")
clobber0 = find_index("v_mov_b32_e32", "v0, 0")
clobber1 = find_index("v_mov_b32_e32", "v1, 0")
clobber2 = find_index("v_mov_b32_e32", "v2, 0")
private_base_1 = find_index("s_mov_b64", "s[0:1], src_private_base", clobber2 + 1)
spill_add_1 = find_index("s_add_u32", "s0, s0, 0xc0", private_base_1 + 1)
addr_lo_1 = find_index("v_mov_b32_e32", "v40, s0", private_base_1 + 1)
addr_hi_1 = find_index("v_mov_b32_e32", "v41, s1", addr_lo_1 + 1)
load_pair = find_index("flat_load_dwordx2", "v[42:43], v[40:41]")
load0 = find_index("v_mov_b32_e32", "v0, v42")
load1 = find_index("v_mov_b32_e32", "v1, v43")
tail_add_1 = find_index("s_add_u32", "s0, s0, 8", load1 + 1)
load_tail = find_index("flat_load_dword", "v44, v[40:41]")
load2 = find_index("v_mov_b32_e32", "v2, v44")
wait = find_index("s_waitcnt", "vmcnt(0)")
restore_lo_after_load = find_index("s_mov_b32", "s0, s12", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s13", restore_lo_after_load + 1)
branch = find_index("s_setpc_b64", "s[14:15]")

assert save_lo < save_hi < private_base_0 < spill_add_0 < addr_lo_0 < addr_hi_0 < pair_lo_0 < pair_hi_0 < save_pair < tail_copy < tail_add_0 < save_tail
assert save_tail < restore_lo_before_clobber < restore_hi_before_clobber < clobber0 < clobber1 < clobber2
assert clobber2 < private_base_1 < spill_add_1 < addr_lo_1 < addr_hi_1 < load_pair < load0 < load1 < tail_add_1 < load_tail < load2 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < branch
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt wrapper IR contains the expected workitem spill/clobber/restore sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt wrapper IR did not contain the expected workitem spill/clobber/restore sequence"
    echo "  IR saved to: $PROOF_IR"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_vgpr_capture_restore_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate a single 3D workgroup launch preserves the original threadIdx.{x,y,z} body contract"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$PROOF_HSACO" mlk_xyz.kd index \
   --single-workgroup \
   --workgroup-size-x 4 \
   --workgroup-size-y 2 \
   --workgroup-size-z 3 > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Workitem-VGPR proof hsaco launches successfully and preserves the imported body threadIdx ABI slice"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Workitem-VGPR proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_vgpr_capture_restore_baseline_multiworkgroup"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the plain mlk_xyz kernel preserves its source-level first-block-only behavior under the default multi-workgroup grid"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$MODULE_LOAD_PLAIN_HSACO" mlk_xyz first-block-only > "$BASELINE_MULTIWORKGROUP_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Plain mlk_xyz preserves the expected first-block-only contract under the default grid"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Plain mlk_xyz did not preserve the expected first-block-only contract under the default grid"
    echo "  Output saved to: $BASELINE_MULTIWORKGROUP_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_vgpr_capture_restore_multiworkgroup"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the wrapped mlk_xyz kernel preserves the same first-block-only contract under the default multi-workgroup grid"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$PROOF_HSACO" mlk_xyz.kd first-block-only > "$PROOF_MULTIWORKGROUP_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Wrapped mlk_xyz preserves the expected first-block-only contract under the default grid"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Wrapped mlk_xyz did not preserve the expected first-block-only contract under the default grid"
    echo "  Output saved to: $PROOF_MULTIWORKGROUP_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
