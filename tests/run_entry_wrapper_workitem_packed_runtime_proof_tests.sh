#!/bin/bash
################################################################################
# Entry-wrapper packed-workitem runtime proof tests
#
# Validates a hardware-backed launch slice for the packed wave64 gfx942 class:
#   1. materialize a runtime-safe variant of the packed entry_abi fixture by
#      appending s_endpgm to the synthetic source body
#   2. rebuild it with --add-entry-wrapper-workitem-vgpr-capture-restore-proof
#   3. launch it through the HSA runtime and confirm the wrapper + handoff path
#      executes to completion on real gfx942 hardware
#
# This intentionally proves hardware legality of the wrapper-owned packed
# spill/restore and branch handoff sequence. The original packed fixture body is
# only an ABI slice, so it is not expected to be launchable without a terminal
# instruction.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

mkdir -p "$OUTPUT_DIR"

HSA_LAUNCH_TEST="${BUILD_DIR}/tools/test_hsa_module_launch"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"

if [ ! -x "$HSA_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Packed runtime proof launcher not built${NC}"
    echo "  Expected: $HSA_LAUNCH_TEST"
    echo "  Build with: cmake --build build --target test_hsa_module_launch"
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

WORK_DIR="$OUTPUT_DIR/entry_wrapper_workitem_packed_runtime_proof"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

RUNTIME_FIXTURE_IR="$WORK_DIR/amdgpu_entry_abi_gfx942_runtime_fixture.ir.json"
PROOF_HSACO="$WORK_DIR/entry_wrapper_workitem_regen_gfx942_packed_runtime.hsaco"
PROOF_REPORT="$WORK_DIR/entry_wrapper_workitem_regen_gfx942_packed_runtime.report.json"
PROOF_STDOUT="$WORK_DIR/entry_wrapper_workitem_regen_gfx942_packed_runtime.stdout"
PROOF_STDERR="$WORK_DIR/entry_wrapper_workitem_regen_gfx942_packed_runtime.stderr"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Packed Workitem Runtime Proof Tests"
echo "================================================================================"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "================================================================================"

python3 - "$SCRIPT_DIR" "$RUNTIME_FIXTURE_IR" <<'PY'
import json
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve()
output_path = Path(sys.argv[2]).resolve()
source_path = script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942.ir.json"

ir = json.loads(source_path.read_text(encoding="utf-8"))
function = next(fn for fn in ir["functions"] if fn.get("name") == "entry_abi_kernel")
instructions = function["instructions"]
last = instructions[-1]
encoding_words = last.get("encoding_words", [])
size_bytes = 4 * len(encoding_words) if encoding_words else 4
next_address = int(last["address"]) + size_bytes

if not any(insn.get("mnemonic") == "s_endpgm" for insn in instructions[-2:]):
    instructions.append(
        {
            "address": next_address,
            "mnemonic": "s_endpgm",
            "operand_text": "",
            "operands": [],
        }
    )
    next_address += 4

function["end_address"] = next_address
function["size_bytes"] = next_address - int(instructions[0]["address"])

output_path.write_text(json.dumps(ir, indent=2) + "\n", encoding="utf-8")
PY

python3 "$REGENERATE_CODE_OBJECT" \
    --input-ir "$RUNTIME_FIXTURE_IR" \
    --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
    --kernel entry_abi_kernel \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_gfx942_packed_runtime_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the packed gfx942 wrapper path executes to completion when the synthetic body is made terminal"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$PROOF_HSACO" entry_abi_kernel untouched > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx942 wrapper proof launches successfully on hardware"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 wrapper proof failed on hardware"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
