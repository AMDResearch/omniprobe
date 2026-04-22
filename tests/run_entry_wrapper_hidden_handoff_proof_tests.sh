#!/bin/bash
################################################################################
# Entry-wrapper hidden-handoff proof tests
#
# Validates the first donor-free "grown wrapper ABI + original-body branch"
# slice:
#   1. rebuild module_load_kernel_plain.hsaco with
#      --add-entry-wrapper-hidden-handoff-proof
#   2. confirm the regeneration report declares the hidden handoff contract
#   3. confirm the rebuilt assembly contains a wrapper-side scalar load from the
#      appended hidden_omniprobe_ctx slot
#   4. raw-launch the rebuilt exported kernel with an explicit kernarg buffer
#      and verify original behavior
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
HIP_LAUNCH_TEST="${BUILD_DIR}/tools/test_hip_module_launch"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -x "$HIP_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Entry-wrapper hidden-handoff proof artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Expected: $HIP_LAUNCH_TEST"
    echo "  Build with: cmake --build build --target module_load_kernel_plain_hsaco test_hip_module_launch"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_hidden_handoff_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_hidden_handoff_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_hidden_handoff_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_hidden_handoff_proof.manifest.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_hidden_handoff_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_hidden_handoff_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_hidden_handoff_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Hidden-Handoff Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HIP_LAUNCH_TEST"
echo "================================================================================"

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-hidden-handoff-proof \
    --kernel mlk \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_hidden_handoff_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares the wrapper hidden-handoff contract"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("mode") == "entry-wrapper-hidden-handoff-proof"
assert entry.get("source_kernel") == "mlk"
assert entry.get("body_symbol") == "__omniprobe_original_body_mlk"
assert entry.get("wrapper_symbol") == "mlk"
assert entry.get("wrapper_size") == 32
scratch_pair = entry.get("scratch_pair")
assert isinstance(scratch_pair, list) and len(scratch_pair) == 2
hidden = entry.get("wrapper_hidden_handoff", {})
assert hidden.get("enabled") is True
assert hidden.get("arg_name") == "hidden_omniprobe_ctx"
assert isinstance(hidden.get("offset"), int)
assert hidden.get("offset") >= 16
assert hidden.get("size") == 8
assert isinstance(hidden.get("instrumented_kernarg_length"), int)
assert hidden.get("instrumented_kernarg_length") >= hidden.get("offset") + hidden.get("size")
assert hidden.get("load_source_pair") == [8, 9]
assert hidden.get("pointer_load_opcode") == "s_load_dwordx2"
fields = hidden.get("consumed_fields", [])
assert len(fields) == 1
assert fields[0]["name"] == "original_kernarg_pointer"
assert fields[0]["offset"] == 0
assert fields[0]["kind"] == "u64"
assert fields[0]["load_opcode"] == "s_load_dwordx2"
recipe = entry.get("entry_handoff_recipe", {})
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-wrapper hidden-handoff report captured the expected ABI growth"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-wrapper hidden-handoff report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_hidden_handoff_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt assembly consumes hidden_omniprobe_ctx before the branch handoff"

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
needles = [
    f"s_load_dwordx2 s[{lo}:{hi}], s[8:9], 0x{offset:x}",
    f"s_load_dwordx2 s[{lo}:{hi}], s[{lo}:{hi}], 0x0",
    "s_waitcnt lgkmcnt(0)",
    f"s_getpc_b64 s[{lo}:{hi}]",
    f"s_add_u32 s{lo}, s{lo}, __omniprobe_original_body_mlk@rel32@lo+4",
    f"s_addc_u32 s{hi}, s{hi}, __omniprobe_original_body_mlk@rel32@hi+4",
    f"s_setpc_b64 s[{lo}:{hi}]",
]
for needle in needles:
    assert needle in asm, needle
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt assembly contains the hidden-handoff load and branch sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt assembly did not contain the expected hidden-handoff sequence"
    echo "  Assembly saved to: $PROOF_ASM"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_hidden_handoff_manifest"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt manifest reflects the grown wrapper ABI"

if python3 - "$PROOF_MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
kernel_symbols = {entry.get("name") for entry in manifest["kernels"]["function_symbols"]}
helper_symbols = {entry.get("name") for entry in manifest["functions"]["helper_symbols"]}
assert "mlk" in kernel_symbols
assert "__omniprobe_original_body_mlk" in helper_symbols
kernel = next(
    entry for entry in manifest["kernels"]["metadata"]["kernels"]
    if entry.get("name") == "mlk"
)
hidden_report = next(
    arg for arg in kernel.get("args", [])
    if arg.get("name") == "hidden_omniprobe_ctx"
)
assert isinstance(int(kernel.get("kernarg_segment_size", 0)), int)
args = kernel.get("args", [])
hidden = next(arg for arg in args if arg.get("name") == "hidden_omniprobe_ctx")
assert int(hidden.get("offset", 0)) >= 16
assert int(hidden.get("size", 0)) == 8
descriptor = next(entry for entry in manifest["kernels"]["descriptors"] if entry.get("kernel_name") == "mlk")
assert descriptor.get("name") == "mlk.kd"
assert int(descriptor.get("kernarg_size", 0)) == int(kernel.get("kernarg_segment_size", 0))
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt manifest preserved the wrapper/body layout and grown kernarg ABI"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt manifest did not reflect the hidden-handoff ABI growth"
    echo "  Manifest saved to: $PROOF_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_hidden_handoff_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt exported kernel raw-launches and matches original behavior"

RAW_KERNARG_SIZE="$(python3 - <<'PY' "$PROOF_REPORT"
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
hidden = report["entry_wrapper_result"]["wrapper_hidden_handoff"]
print(hidden["instrumented_kernarg_length"])
PY
)"
HIDDEN_CTX_OFFSET="$(python3 - <<'PY' "$PROOF_REPORT"
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
hidden = report["entry_wrapper_result"]["wrapper_hidden_handoff"]
print(hidden["offset"])
PY
)"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HIP_LAUNCH_TEST" \
   "$PROOF_HSACO" mlk index \
   --raw-kernarg-size "$RAW_KERNARG_SIZE" \
   --hidden-ctx-offset "$HIDDEN_CTX_OFFSET" > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-wrapper hidden-handoff proof hsaco raw-launches successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-wrapper hidden-handoff proof hsaco failed to raw-launch"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
