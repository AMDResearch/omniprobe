#!/bin/bash
################################################################################
# Entry-wrapper full entry-ABI capture-restore proof tests
#
# Validates a closed-loop proof slice for preserving the supported entry
# system-SGPR roles plus the entry workitem VGPR state through an Omniprobe-
# owned entry wrapper:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-full-entry-abi-capture-restore-proof targeting
#      mlk_xyz
#   2. confirm the regeneration report declares both the hidden-handoff
#      system-SGPR capture/restore contract and the private-tail workitem
#      spill/restore plan
#   3. confirm the rebuilt wrapper IR captures system state, spills v0/v1/v2,
#      clobbers both classes, restores both classes, and then branches to the
#      original body
#   4. launch through the HSA runtime with a single 3D workgroup and verify
#      the imported body still observes the original threadIdx.{x,y,z}
#      contract while hidden_ctx exposes the captured entry system state
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
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -x "$HSA_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Entry-wrapper full entry-ABI proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_full_entry_abi_capture_restore_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.manifest.json"
PROOF_IR="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.ir.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_full_entry_abi_capture_restore_proof.stderr"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Full Entry-ABI Capture-Restore Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-full-entry-abi-capture-restore-proof \
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
TEST_NAME="entry_wrapper_full_entry_abi_capture_restore_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares both the system-SGPR and workitem closed-loop contracts"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-full-entry-abi-capture-restore-proof"
assert entry.get("source_kernel") == "mlk_xyz"
assert entry.get("scratch_pair") == [32, 33]
assert entry.get("preconditions", {}).get("secondary_scratch_pair") == [32, 33]
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
workitem = entry.get("workitem_spill_restore", {})
assert workitem.get("enabled") is True
assert workitem.get("source_vgprs") == [0, 1, 2]
assert workitem.get("spill_offset") == 224
assert workitem.get("spill_bytes") == 12
assert workitem.get("private_segment_growth") == 16
assert workitem.get("save_pair") == [20, 21]
assert workitem.get("soffset_sgpr") == 32
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Full entry-ABI proof report captured the expected combined contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Full entry-ABI proof report did not match the expected combined contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_full_entry_abi_capture_restore_ir"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt wrapper IR contains both the system-SGPR and workitem restore sequences"

if [ -f "$PROOF_IR" ] && \
   python3 - "$PROOF_IR" <<'PY'
import json
import sys

ir = json.load(open(sys.argv[1], encoding="utf-8"))
wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "mlk_xyz")
instructions = wrapper.get("instructions", [])
texts = [str(insn.get("operand_text", "")) for insn in instructions]

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

assert "v6, s14" in texts
assert "v6, s15" in texts
assert "v6, s16" in texts
assert "v6, s17" in texts
save0 = find_index("buffer_store_dword", "v0, off, s[0:3], s32 offset:224")
save1 = find_index("buffer_store_dword", "v1, off, s[0:3], s32 offset:228")
save2 = find_index("buffer_store_dword", "v2, off, s[0:3], s32 offset:232")
clobber0 = find_index("v_mov_b32_e32", "v0, 0")
clobber1 = find_index("v_mov_b32_e32", "v1, 0")
clobber2 = find_index("v_mov_b32_e32", "v2, 0")
load0 = find_index("buffer_load_dword", "v0, off, s[0:3], s32 offset:224")
load1 = find_index("buffer_load_dword", "v1, off, s[0:3], s32 offset:228")
load2 = find_index("buffer_load_dword", "v2, off, s[0:3], s32 offset:232")
wait = find_index("s_waitcnt", "vmcnt(0)")
branch = find_index("s_setpc_b64", "s[32:33]")

assert find_index("v_mov_b32_e32", "v6, s14") < find_index("s_mov_b32", "s14, 0") < find_load_index(14, "0x8")
assert find_index("v_mov_b32_e32", "v6, s15") < find_index("s_mov_b32", "s15, 0") < find_load_index(15, "0xc")
assert find_index("v_mov_b32_e32", "v6, s16") < find_index("s_mov_b32", "s16, 0") < find_load_index(16, "0x10")
assert find_index("v_mov_b32_e32", "v6, s17") < find_index("s_mov_b32", "s17, 0") < find_load_index(17, "0x14")
assert save0 < save1 < save2 < clobber0 < clobber1 < clobber2 < load0 < load1 < load2 < wait < branch
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt wrapper IR contains the expected combined closed-loop sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt wrapper IR did not contain the expected combined closed-loop sequence"
    echo "  IR saved to: $PROOF_IR"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_full_entry_abi_capture_restore_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate a single 3D workgroup launch preserves threadIdx.{x,y,z} while capturing entry system state"

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
   "$PROOF_HSACO" mlk_xyz.kd index \
   --hidden-ctx-offset "$HIDDEN_CTX_OFFSET" \
   --populate-original-kernarg-pointer \
   --verify-hidden-u32 8 0 \
   --verify-hidden-u32 12 0 \
   --verify-hidden-u32 16 0 \
   --verify-hidden-u32-nonzero 20 \
   --single-workgroup \
   --workgroup-size-x 4 \
   --workgroup-size-y 2 \
   --workgroup-size-z 3 > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Full entry-ABI proof hsaco launches successfully and preserves the imported body ABI slice"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Full entry-ABI proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
