#!/bin/bash
################################################################################
# Entry-wrapper kernarg-restore proof tests
#
# Validates the first donor-free reconstruction-after-clobber slice:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-kernarg-restore-proof
#   2. confirm the regeneration report declares that original_kernarg_pointer is
#      consumed to restore s[8:9]
#   3. confirm the rebuilt assembly zeros s8:s9 and reloads them from the
#      hidden handoff struct before branching to the original body
#   4. launch through the HSA runtime so the handoff struct contains the exact
#      packet->kernarg_address seen by the kernel
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
    echo -e "${YELLOW}SKIP: Entry-wrapper kernarg-restore proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_kernarg_restore_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_kernarg_restore_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_kernarg_restore_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_kernarg_restore_proof.manifest.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_kernarg_restore_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_kernarg_restore_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_kernarg_restore_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Kernarg-Restore Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-kernarg-restore-proof \
    --kernel mlk \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_kernarg_restore_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares kernarg-base restoration from the hidden handoff"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-kernarg-restore-proof"
assert entry.get("wrapper_size") == 40
hidden = entry.get("wrapper_hidden_handoff", {})
assert hidden.get("enabled") is True
assert hidden.get("restored_actions") == ["materialize-kernarg-base-pair"]
fields = hidden.get("consumed_fields", [])
assert len(fields) == 1
field = fields[0]
assert field["name"] == "original_kernarg_pointer"
assert field["offset"] == 0
assert field["kind"] == "u64"
assert field["load_opcode"] == "s_load_dwordx2"
assert field["target_pair"] == [8, 9]
assert field["clobber_target_before_load"] is True
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Kernarg-restore proof report captured the expected restoration contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Kernarg-restore proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_kernarg_restore_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt assembly clobbers and restores s8:s9 before the branch handoff"

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
    "s_waitcnt lgkmcnt(0)",
    f"s_getpc_b64 s[{lo}:{hi}]",
    f"s_setpc_b64 s[{lo}:{hi}]",
]
for needle in needles:
    assert needle in asm, needle
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt assembly contains the expected kernarg restore sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt assembly did not contain the expected kernarg restore sequence"
    echo "  Assembly saved to: $PROOF_ASM"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_kernarg_restore_manifest"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt manifest reflects the hidden handoff ABI"

if python3 - "$PROOF_MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
kernel = next(
    entry for entry in manifest["kernels"]["metadata"]["kernels"]
    if entry.get("name") == "mlk"
)
hidden = next(arg for arg in kernel.get("args", []) if arg.get("name") == "hidden_omniprobe_ctx")
assert int(hidden.get("offset", 0)) >= 16
assert int(hidden.get("size", 0)) == 8
descriptor = next(entry for entry in manifest["kernels"]["descriptors"] if entry.get("kernel_name") == "mlk")
assert int(descriptor.get("kernarg_size", 0)) == int(kernel.get("kernarg_segment_size", 0))
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt manifest preserved the hidden handoff ABI"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt manifest did not reflect the hidden handoff ABI"
    echo "  Manifest saved to: $PROOF_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_kernarg_restore_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate HSA launch restores the true packet kernarg pointer and preserves behavior"

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
   --populate-original-kernarg-pointer > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Kernarg-restore proof hsaco launches successfully through the HSA path"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Kernarg-restore proof hsaco failed under the HSA path"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
