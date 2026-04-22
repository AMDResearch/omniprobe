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

mkdir -p "$OUTPUT_DIR"

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
assert entry.get("scratch_pair") == [14, 15]
assert entry.get("preconditions", {}).get("secondary_scratch_pair") == [14, 15]
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
assert [field["offset"] for field in consumed] == [8, 12, 16, 20, 0]
assert [field["target_sgpr"] for field in consumed[:4]] == [8, 9, 10, 11]
assert consumed[4]["target_pair"] == [0, 1]
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

def find_index(mnemonic, operand_text, start=0):
    for idx in range(start, len(instructions)):
        insn = instructions[idx]
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

save_lo = find_index("s_mov_b32", "s12, s0")
save_hi = find_index("s_mov_b32", "s13, s1")
private_base_0 = find_index("s_mov_b64", "s[0:1], src_private_base")
private_wave_off_0 = find_index("s_add_u32", "s0, s0, s11", private_base_0 + 1)
private_wave_off_hi_0 = find_index("s_addc_u32", "s1, s1, 0", private_wave_off_0 + 1)
spill_add_0 = find_index("s_add_u32", "s0, s0, 0xc0", private_wave_off_hi_0 + 1)
spill_add_hi_0 = find_index("s_addc_u32", "s1, s1, 0", spill_add_0 + 1)
addr_lo_0 = find_index("v_mov_b32_e32", "v40, s0", spill_add_hi_0 + 1)
addr_hi_0 = find_index("v_mov_b32_e32", "v41, s1", addr_lo_0 + 1)
pair_lo_0 = find_index("v_mov_b32_e32", "v42, v0", addr_hi_0 + 1)
pair_hi_0 = find_index("v_mov_b32_e32", "v43, v1", pair_lo_0 + 1)
save_pair = find_index("flat_store_dwordx2", "v[40:41], v[42:43]", pair_hi_0 + 1)
tail_copy = find_index("v_mov_b32_e32", "v44, v2", save_pair + 1)
tail_add_0 = find_index("s_add_u32", "s0, s0, 8", tail_copy + 1)
tail_add_hi_0 = find_index("s_addc_u32", "s1, s1, 0", tail_add_0 + 1)
tail_addr_lo_0 = find_index("v_mov_b32_e32", "v40, s0", tail_add_hi_0 + 1)
tail_addr_hi_0 = find_index("v_mov_b32_e32", "v41, s1", tail_addr_lo_0 + 1)
save_tail = find_index("flat_store_dword", "v[40:41], v44", tail_addr_hi_0 + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s12")
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s13")
clobber0 = find_index("v_mov_b32_e32", "v0, 0")
clobber1 = find_index("v_mov_b32_e32", "v1, 0")
clobber2 = find_index("v_mov_b32_e32", "v2, 0")
private_base_1 = find_index("s_mov_b64", "s[0:1], src_private_base", clobber2 + 1)
private_wave_off_1 = find_index("s_add_u32", "s0, s0, s11", private_base_1 + 1)
private_wave_off_hi_1 = find_index("s_addc_u32", "s1, s1, 0", private_wave_off_1 + 1)
spill_add_1 = find_index("s_add_u32", "s0, s0, 0xc0", private_wave_off_hi_1 + 1)
spill_add_hi_1 = find_index("s_addc_u32", "s1, s1, 0", spill_add_1 + 1)
addr_lo_1 = find_index("v_mov_b32_e32", "v40, s0", spill_add_hi_1 + 1)
addr_hi_1 = find_index("v_mov_b32_e32", "v41, s1", addr_lo_1 + 1)
load_pair = find_index("flat_load_dwordx2", "v[42:43], v[40:41]")
load0 = find_index("v_mov_b32_e32", "v0, v42")
load1 = find_index("v_mov_b32_e32", "v1, v43")
tail_add_1 = find_index("s_add_u32", "s0, s0, 8", load1 + 1)
tail_add_hi_1 = find_index("s_addc_u32", "s1, s1, 0", tail_add_1 + 1)
tail_addr_lo_1 = find_index("v_mov_b32_e32", "v40, s0", tail_add_hi_1 + 1)
tail_addr_hi_1 = find_index("v_mov_b32_e32", "v41, s1", tail_addr_lo_1 + 1)
load_tail = find_index("flat_load_dword", "v44, v[40:41]")
load2 = find_index("v_mov_b32_e32", "v2, v44")
vm_wait = find_index("s_waitcnt", "vmcnt(0)")
restore_lo_after_load = find_index("s_mov_b32", "s0, s12", vm_wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s13", restore_lo_after_load + 1)

capture_ptr_0 = find_index("s_load_dwordx2", "s[14:15], s[4:5], 0xe0")
capture_wait_0 = find_index("s_waitcnt", "lgkmcnt(0)", capture_ptr_0 + 1)
capture_add_0 = find_index("s_add_u32", "s14, s14, 8", capture_wait_0 + 1)
capture_addc_0 = find_index("s_addc_u32", "s15, s15, 0", capture_add_0 + 1)
capture_addr_lo_0 = find_index("v_mov_b32_e32", "v4, s14", capture_addc_0 + 1)
capture_addr_hi_0 = find_index("v_mov_b32_e32", "v5, s15", capture_addr_lo_0 + 1)
capture_data_0 = find_index("v_mov_b32_e32", "v6, s8", capture_addr_hi_0 + 1)
capture_store_0 = find_index("flat_store_dword", "v[4:5], v6", capture_data_0 + 1)

capture_ptr_1 = find_index("s_load_dwordx2", "s[14:15], s[4:5], 0xe0", capture_store_0 + 1)
capture_wait_1 = find_index("s_waitcnt", "lgkmcnt(0)", capture_ptr_1 + 1)
capture_add_1 = find_index("s_add_u32", "s14, s14, 12", capture_wait_1 + 1)
capture_addc_1 = find_index("s_addc_u32", "s15, s15, 0", capture_add_1 + 1)
capture_addr_lo_1 = find_index("v_mov_b32_e32", "v4, s14", capture_addc_1 + 1)
capture_addr_hi_1 = find_index("v_mov_b32_e32", "v5, s15", capture_addr_lo_1 + 1)
capture_data_1 = find_index("v_mov_b32_e32", "v6, s9", capture_addr_hi_1 + 1)
capture_store_1 = find_index("flat_store_dword", "v[4:5], v6", capture_store_0 + 1)

capture_ptr_2 = find_index("s_load_dwordx2", "s[14:15], s[4:5], 0xe0", capture_store_1 + 1)
capture_wait_2 = find_index("s_waitcnt", "lgkmcnt(0)", capture_ptr_2 + 1)
capture_add_2 = find_index("s_add_u32", "s14, s14, 16", capture_wait_2 + 1)
capture_addc_2 = find_index("s_addc_u32", "s15, s15, 0", capture_add_2 + 1)
capture_addr_lo_2 = find_index("v_mov_b32_e32", "v4, s14", capture_addc_2 + 1)
capture_addr_hi_2 = find_index("v_mov_b32_e32", "v5, s15", capture_addr_lo_2 + 1)
capture_data_2 = find_index("v_mov_b32_e32", "v6, s10", capture_addr_hi_2 + 1)
capture_store_2 = find_index("flat_store_dword", "v[4:5], v6", capture_store_1 + 1)

capture_ptr_3 = find_index("s_load_dwordx2", "s[14:15], s[4:5], 0xe0", capture_store_2 + 1)
capture_wait_3 = find_index("s_waitcnt", "lgkmcnt(0)", capture_ptr_3 + 1)
capture_add_3 = find_index("s_add_u32", "s14, s14, 20", capture_wait_3 + 1)
capture_addc_3 = find_index("s_addc_u32", "s15, s15, 0", capture_add_3 + 1)
capture_addr_lo_3 = find_index("v_mov_b32_e32", "v4, s14", capture_addc_3 + 1)
capture_addr_hi_3 = find_index("v_mov_b32_e32", "v5, s15", capture_addr_lo_3 + 1)
capture_data_3 = find_index("v_mov_b32_e32", "v6, s11", capture_addr_hi_3 + 1)
capture_store_3 = find_index("flat_store_dword", "v[4:5], v6", capture_store_2 + 1)

restore_ptr = find_index("s_load_dwordx2", "s[14:15], s[4:5], 0xe0", capture_store_3 + 1)
restore_ptr_wait = find_index("s_waitcnt", "lgkmcnt(0)", restore_ptr + 1)
assert find_index("s_mov_b32", "s8, 0") < find_load_index(8, "0x8")
assert find_index("s_mov_b32", "s9, 0") < find_load_index(9, "0xc")
assert find_index("s_mov_b32", "s10, 0") < find_load_index(10, "0x10")
assert find_index("s_mov_b32", "s11, 0") < find_load_index(11, "0x14")
restore_kernarg_lo = find_index("s_mov_b32", "s0, 0")
restore_kernarg_hi = find_index("s_mov_b32", "s1, 0")
restore_kernarg = find_index("s_load_dwordx2", "s[0:1], s[14:15], 0x0")
restore_kernarg_wait = find_index("s_waitcnt", "lgkmcnt(0)", restore_kernarg + 1)
branch_pc = find_index("s_getpc_b64", "s[14:15]", restore_kernarg_wait + 1)
branch_add_lo = find_index("s_add_u32", "s14, s14, 0xfffff53c", branch_pc + 1)
branch_add_hi = find_index("s_addc_u32", "s15, s15, -1", branch_add_lo + 1)
branch = find_index("s_setpc_b64", "s[14:15]")

assert save_lo < save_hi < private_base_0 < private_wave_off_0 < private_wave_off_hi_0 < spill_add_0 < spill_add_hi_0 < addr_lo_0 < addr_hi_0 < pair_lo_0 < pair_hi_0 < save_pair < tail_copy < tail_add_0 < tail_add_hi_0 < tail_addr_lo_0 < tail_addr_hi_0 < save_tail
assert save_tail < restore_lo_before_clobber < restore_hi_before_clobber < clobber0 < clobber1 < clobber2
assert clobber2 < private_base_1 < private_wave_off_1 < private_wave_off_hi_1 < spill_add_1 < spill_add_hi_1 < addr_lo_1 < addr_hi_1 < load_pair < load0 < load1 < tail_add_1 < tail_add_hi_1 < tail_addr_lo_1 < tail_addr_hi_1 < load_tail < load2 < vm_wait
assert vm_wait < restore_lo_after_load < restore_hi_after_load < capture_ptr_0 < capture_wait_0 < capture_add_0 < capture_addc_0 < capture_addr_lo_0 < capture_addr_hi_0 < capture_data_0 < capture_store_0
assert capture_store_0 < capture_ptr_1 < capture_wait_1 < capture_add_1 < capture_addc_1 < capture_addr_lo_1 < capture_addr_hi_1 < capture_data_1 < capture_store_1
assert capture_store_1 < capture_ptr_2 < capture_wait_2 < capture_add_2 < capture_addc_2 < capture_addr_lo_2 < capture_addr_hi_2 < capture_data_2 < capture_store_2
assert capture_store_2 < capture_ptr_3 < capture_wait_3 < capture_add_3 < capture_addc_3 < capture_addr_lo_3 < capture_addr_hi_3 < capture_data_3 < capture_store_3
assert capture_store_3 < restore_ptr < restore_ptr_wait < restore_kernarg_lo < restore_kernarg_hi < restore_kernarg < restore_kernarg_wait < branch_pc < branch_add_lo < branch_add_hi < branch
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
echo "  Validate a single 3D workgroup launch preserves threadIdx.{x,y,z} while capturing first-wave entry system state"

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
   --verify-hidden-u32 20 0 \
   --single-workgroup \
   --workgroup-size-x 4 \
   --workgroup-size-y 2 \
   --workgroup-size-z 3 > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Full entry-ABI proof hsaco launches successfully, preserves the imported body ABI slice, and captures first-wave entry system state"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Full entry-ABI proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
