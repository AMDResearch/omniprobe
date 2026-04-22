#!/bin/bash
################################################################################
# Entry-wrapper system-SGPR capture-restore proof tests
#
# Validates the first closed-loop proof for all entry system SGPR roles in the
# current supported class:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-system-sgpr-capture-restore-proof
#   2. confirm the regeneration report declares capture plus restoration for
#      x/y/z and private_segment_wave_offset
#   3. confirm the rebuilt assembly emits capture stores before clobber+reload
#   4. launch through the HSA runtime with a single-wave, single-workgroup
#      dispatch and verify the imported body still executes correctly while
#      hidden_ctx exposes the captured values
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
    echo -e "${YELLOW}SKIP: Entry-wrapper system-SGPR capture-restore proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_system_sgpr_capture_restore_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.manifest.json"
PROOF_IR="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.ir.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_system_sgpr_capture_restore_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_system_sgpr_capture_restore_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper System-SGPR Capture-Restore Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-system-sgpr-capture-restore-proof \
    --kernel mlk \
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
TEST_NAME="entry_wrapper_system_sgpr_capture_restore_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares capture plus restoration for all entry system SGPR roles"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-system-sgpr-capture-restore-proof"
assert entry.get("wrapper_size") == 216
hidden = entry.get("wrapper_hidden_handoff", {})
assert hidden.get("restored_actions") == [
    "materialize-system-sgpr:workgroup_id_x",
    "materialize-system-sgpr:workgroup_id_y",
    "materialize-system-sgpr:workgroup_id_z",
    "materialize-system-sgpr:private_segment_wave_offset",
    "materialize-kernarg-base-pair",
]
captured = hidden.get("captured_entry_snapshot_fields", [])
assert [field["name"] for field in captured] == [
    "workgroup_id_x",
    "workgroup_id_y",
    "workgroup_id_z",
    "private_segment_wave_offset",
]
assert [field["offset"] for field in captured] == [8, 12, 16, 20]
consumed = hidden.get("consumed_fields", [])
assert [field["name"] for field in consumed] == [
    "workgroup_id_x",
    "workgroup_id_y",
    "workgroup_id_z",
    "private_segment_wave_offset",
    "original_kernarg_pointer",
]
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - System-SGPR capture-restore proof report captured the expected closed-loop contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - System-SGPR capture-restore proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_system_sgpr_capture_restore_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt wrapper IR captures and restores x/y/z/private before branch handoff"

if [ -f "$PROOF_IR" ] && \
   python3 - "$PROOF_IR" <<'PY'
import json
import sys

ir = json.load(open(sys.argv[1], encoding="utf-8"))
wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "mlk")
instructions = wrapper.get("instructions", [])
texts = [str(insn.get("operand_text", "")) for insn in instructions]
mnemonics = [str(insn.get("mnemonic", "")) for insn in instructions]

def find_index(mnemonic, operand_text):
    for idx, insn in enumerate(instructions):
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return idx
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")

def find_load_index(target_sgpr, offset_text):
    prefix = f"s{target_sgpr}, s["
    suffix = f", {offset_text}"
    for idx, insn in enumerate(instructions):
        if insn.get("mnemonic") != "s_load_dword":
            continue
        operand_text = str(insn.get("operand_text", ""))
        if operand_text.startswith(prefix) and operand_text.endswith(suffix):
            return idx
    raise AssertionError(f"missing instruction: s_load_dword -> s{target_sgpr} @ {offset_text}")

assert mnemonics.count("flat_store_dword") == 4
for needle in (
    "v[4:5], v6",
    "v6, s8",
    "v6, s9",
    "v6, s10",
    "v6, s11",
    "s8, 0",
    "s9, 0",
    "s10, 0",
    "s11, 0",
):
    assert needle in texts, needle
assert find_index("v_mov_b32_e32", "v6, s8") < find_index("s_mov_b32", "s8, 0") < find_load_index(8, "0x8")
assert find_index("v_mov_b32_e32", "v6, s9") < find_index("s_mov_b32", "s9, 0") < find_load_index(9, "0xc")
assert find_index("v_mov_b32_e32", "v6, s10") < find_index("s_mov_b32", "s10, 0") < find_load_index(10, "0x10")
assert find_index("v_mov_b32_e32", "v6, s11") < find_index("s_mov_b32", "s11, 0") < find_load_index(11, "0x14")
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt wrapper IR contains the expected full system-SGPR closed-loop sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt wrapper IR did not contain the expected full system-SGPR closed-loop sequence"
    echo "  IR saved to: $PROOF_IR"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_system_sgpr_capture_restore_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate single-wave HSA launch preserves original behavior while capturing x/y/z and the first-wave private offset"

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
   --verify-hidden-u32 20 0 \
   --single-wave > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - System-SGPR capture-restore proof hsaco launches successfully, preserves the imported body ABI slice, and captures the first-wave private offset"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - System-SGPR capture-restore proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
