#!/bin/bash
################################################################################
# Entry-wrapper proof tests
#
# Validates the first donor-free "branch into original machine code" slice:
#   1. rebuild module_load_kernel_plain.hsaco with --add-entry-wrapper-proof
#   2. confirm the regeneration report declares the wrapper/body mapping
#   3. confirm the rebuilt assembly contains the PC-relative handoff stub
#   4. launch the rebuilt exported kernel and verify original behavior
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
    echo -e "${YELLOW}SKIP: Entry-wrapper proof artifacts not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PROOF_HSACO="$WORK_DIR/module_load_entry_wrapper_proof.hsaco"
PROOF_REPORT="$WORK_DIR/module_load_entry_wrapper_proof.report.json"
PROOF_MANIFEST="$WORK_DIR/module_load_entry_wrapper_proof.manifest.json"
PROOF_STDOUT="$WORK_DIR/module_load_entry_wrapper_proof.stdout"
PROOF_STDERR="$WORK_DIR/module_load_entry_wrapper_proof.stderr"
PROOF_REGEN_DIR="$WORK_DIR/.module_load_entry_wrapper_proof.hsaco.regen"
PROOF_ASM="$PROOF_REGEN_DIR/output.s"
BASELINE_OUT="$WORK_DIR/baseline.out"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Proof Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Launch test: $HIP_LAUNCH_TEST"
echo "================================================================================"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$HIP_LAUNCH_TEST" \
    "$MODULE_LOAD_PLAIN_HSACO" mlk index > "$BASELINE_OUT" 2>&1

python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-proof \
    --kernel mlk \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

python3 "$INSPECT_CODE_OBJECT" \
    "$PROOF_HSACO" \
    --output "$PROOF_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_proof_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate regeneration report declares the wrapper/body handoff"

if python3 - "$PROOF_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
entry = report.get("entry_wrapper_result", {})
assert entry.get("source_kernel") == "mlk"
assert entry.get("wrapper_symbol") == "mlk"
assert entry.get("body_symbol") == "__omniprobe_original_body_mlk"
assert entry.get("wrapper_size") == 16
scratch_pair = entry.get("scratch_pair")
assert isinstance(scratch_pair, list) and len(scratch_pair) == 2
assert scratch_pair[0] % 2 == 0
assert scratch_pair[1] == scratch_pair[0] + 1
recipe = entry.get("entry_handoff_recipe", {})
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert recipe.get("wrapper_strategy", {}).get("branch_target_symbol") == "mlk"
assert recipe.get("wrapper_strategy", {}).get("scratch_pair") == scratch_pair
actions = recipe.get("reconstruction_actions", [])
assert actions[0]["action"] == "materialize-kernarg-base-pair"
assert actions[0]["target_sgprs"] == [8, 9]
wrapper = recipe.get("wrapper_source_analysis", {})
assert wrapper.get("model") == "direct-entry-wrapper-v1"
assert wrapper.get("direct_branch_supported") is True
assert wrapper.get("reconstruction_after_clobber_supported") is False
assert "no-independent-entry-workitem-vgpr-source" in wrapper.get("reconstruction_after_clobber_blockers", [])
handoff = recipe.get("supplemental_handoff_contract", {})
assert handoff.get("schema") == "omniprobe.entry_handoff.hidden_v1"
assert handoff.get("required") is True
field_names = [entry["name"] for entry in handoff.get("fields", [])]
assert "original_kernarg_pointer" in field_names
assert "entry_workitem_id_x" in field_names
assert "entry_private_base_lo" in field_names
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-wrapper proof report captured the expected wrapper/body contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-wrapper proof report did not match the expected contract"
    echo "  Report saved to: $PROOF_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_proof_asm"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt assembly contains the PC-relative handoff stub"

if [ -f "$PROOF_ASM" ] && \
   python3 - "$PROOF_REPORT" "$PROOF_ASM" <<'PY'
import json
import sys
from pathlib import Path

report = json.load(open(sys.argv[1], encoding="utf-8"))
asm = Path(sys.argv[2]).read_text(encoding="utf-8")
lo, hi = report["entry_wrapper_result"]["scratch_pair"]
needles = [
    f"s_getpc_b64 s[{lo}:{hi}]",
    f"s_add_u32 s{lo}, s{lo}, __omniprobe_original_body_mlk@rel32@lo+4",
    f"s_addc_u32 s{hi}, s{hi}, __omniprobe_original_body_mlk@rel32@hi+4",
    f"s_setpc_b64 s[{lo}:{hi}]",
]
for needle in needles:
    assert needle in asm, needle
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt assembly contains the expected wrapper handoff sequence"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt assembly did not contain the expected wrapper handoff sequence"
    echo "  Assembly saved to: $PROOF_ASM"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_proof_manifest"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt code object exports mlk and retains the renamed original body as a helper"

if python3 - "$PROOF_MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
kernel_symbols = {entry.get("name") for entry in manifest["kernels"]["function_symbols"]}
helper_symbols = {entry.get("name") for entry in manifest["functions"]["helper_symbols"]}
assert "mlk" in kernel_symbols
assert "__omniprobe_original_body_mlk" in helper_symbols
descriptor = next(entry for entry in manifest["kernels"]["descriptors"] if entry.get("kernel_name") == "mlk")
assert descriptor.get("name") == "mlk.kd"
assert int(descriptor.get("kernarg_size", 0)) == 272
assert int(descriptor.get("private_segment_fixed_size", 0)) == 208
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Rebuilt manifest preserved the exported kernel contract and helper body symbol"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Rebuilt manifest did not preserve the expected wrapper/body layout"
    echo "  Manifest saved to: $PROOF_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_proof_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the rebuilt exported kernel launches and matches baseline behavior"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HIP_LAUNCH_TEST" \
   "$PROOF_HSACO" mlk index > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-wrapper proof hsaco launches successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-wrapper proof hsaco failed to launch"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
