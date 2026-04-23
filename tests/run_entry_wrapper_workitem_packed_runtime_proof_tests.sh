#!/bin/bash
################################################################################
# Entry-wrapper synthetic runtime proof tests
#
# Validates a hardware-backed launch slice for entry-wrapper proof fixtures:
#   1. materialize a runtime-safe variant of the synthetic entry_abi fixture by
#      appending s_endpgm to the source body
#   2. rebuild it with --add-entry-wrapper-workitem-vgpr-capture-restore-proof
#   3. launch it through the HSA runtime and confirm the wrapper + handoff path
#      executes to completion on matching hardware
#
# This intentionally proves hardware legality of the wrapper-owned spill/restore
# and branch handoff sequence. The synthetic entry_abi fixtures are ABI slices,
# so they are not expected to be launchable without a terminal instruction.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

mkdir -p "$OUTPUT_DIR"

HSA_LAUNCH_TEST="${BUILD_DIR}/tools/test_hsa_module_launch"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
AMDGPU_ARCH_TOOL="${AMDGPU_ARCH_TOOL:-}"
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

ENTRY_WRAPPER_RUNTIME_PROOF_ARCH="${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH:-gfx942}"
ENTRY_WRAPPER_RUNTIME_PROOF_FUNCTION="${ENTRY_WRAPPER_RUNTIME_PROOF_FUNCTION:-entry_abi_kernel}"
ENTRY_WRAPPER_RUNTIME_PROOF_EXPECTATION="${ENTRY_WRAPPER_RUNTIME_PROOF_EXPECTATION:-untouched}"
ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_BASENAME="${ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_BASENAME:-amdgpu_entry_abi_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}}"
ENTRY_WRAPPER_RUNTIME_PROOF_LABEL="${ENTRY_WRAPPER_RUNTIME_PROOF_LABEL:-${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}}"
ENTRY_WRAPPER_RUNTIME_PROOF_KIND="${ENTRY_WRAPPER_RUNTIME_PROOF_KIND:-synthetic}"
ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_IR="${SCRIPT_DIR}/probe_specs/fixtures/${ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_BASENAME}.ir.json"
ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/${ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_BASENAME}.manifest.json"

if [ -z "$AMDGPU_ARCH_TOOL" ]; then
    for candidate in \
        /opt/rocm/llvm/bin/amdgpu-arch \
        /opt/rocm/lib/llvm/bin/amdgpu-arch \
        /opt/rocm-7.2.0/lib/llvm/bin/amdgpu-arch \
        /opt/rocm-7.2.2/lib/llvm/bin/amdgpu-arch; do
        if [ -x "$candidate" ]; then
            AMDGPU_ARCH_TOOL="$candidate"
            break
        fi
    done
fi

if [ -n "$AMDGPU_ARCH_TOOL" ] && [ -x "$AMDGPU_ARCH_TOOL" ]; then
    DETECTED_ARCHS="$("$AMDGPU_ARCH_TOOL" 2>/dev/null || true)"
    if ! printf '%s\n' "$DETECTED_ARCHS" | grep -qx "$ENTRY_WRAPPER_RUNTIME_PROOF_ARCH"; then
        echo -e "${YELLOW}SKIP: Available GPU architecture does not match runtime-proof target${NC}"
        echo "  Target arch:    $ENTRY_WRAPPER_RUNTIME_PROOF_ARCH"
        echo "  Detected archs: ${DETECTED_ARCHS:-<none>}"
        export TESTS_RUN TESTS_PASSED TESTS_FAILED
        return 0 2>/dev/null || exit 0
    fi
fi

RUNTIME_FIXTURE_IR="$WORK_DIR/${ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_BASENAME}_runtime_fixture.ir.json"
PROOF_HSACO="$WORK_DIR/entry_wrapper_workitem_regen_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}_${ENTRY_WRAPPER_RUNTIME_PROOF_KIND}_runtime.hsaco"
PROOF_REPORT="$WORK_DIR/entry_wrapper_workitem_regen_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}_${ENTRY_WRAPPER_RUNTIME_PROOF_KIND}_runtime.report.json"
PROOF_STDOUT="$WORK_DIR/entry_wrapper_workitem_regen_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}_${ENTRY_WRAPPER_RUNTIME_PROOF_KIND}_runtime.stdout"
PROOF_STDERR="$WORK_DIR/entry_wrapper_workitem_regen_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}_${ENTRY_WRAPPER_RUNTIME_PROOF_KIND}_runtime.stderr"
LAUNCH_OUT="$WORK_DIR/launch.out"

echo ""
echo "================================================================================"
echo "Entry-Wrapper Synthetic Runtime Proof Tests"
echo "================================================================================"
echo "  Launch test: $HSA_LAUNCH_TEST"
echo "  Fixture IR:  $ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_IR"
echo "  Target arch: $ENTRY_WRAPPER_RUNTIME_PROOF_ARCH"
echo "================================================================================"

python3 - "$REPO_ROOT" "$ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_IR" "$RUNTIME_FIXTURE_IR" "$ENTRY_WRAPPER_RUNTIME_PROOF_FUNCTION" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
source_path = Path(sys.argv[2]).resolve()
output_path = Path(sys.argv[3]).resolve()
function_name = sys.argv[4]

sys.path.insert(0, str(repo_root / "tools" / "codeobj"))

from common import write_runtime_safe_fixture_ir  # type: ignore


write_runtime_safe_fixture_ir(
    source_path,
    output_path,
    function_name=function_name,
)
PY

python3 "$REGENERATE_CODE_OBJECT" \
    --input-ir "$RUNTIME_FIXTURE_IR" \
    --manifest "$ENTRY_WRAPPER_RUNTIME_PROOF_FIXTURE_MANIFEST" \
    --output "$PROOF_HSACO" \
    --report-output "$PROOF_REPORT" \
    --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
    --kernel "$ENTRY_WRAPPER_RUNTIME_PROOF_FUNCTION" \
    --keep-temp-dir \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$PROOF_STDOUT" 2> "$PROOF_STDERR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_${ENTRY_WRAPPER_RUNTIME_PROOF_ARCH}_${ENTRY_WRAPPER_RUNTIME_PROOF_KIND}_runtime_launch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the ${ENTRY_WRAPPER_RUNTIME_PROOF_LABEL} wrapper path executes to completion when the synthetic body is made terminal"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$HSA_LAUNCH_TEST" \
   "$PROOF_HSACO" "$ENTRY_WRAPPER_RUNTIME_PROOF_FUNCTION" "$ENTRY_WRAPPER_RUNTIME_PROOF_EXPECTATION" > "$LAUNCH_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - ${ENTRY_WRAPPER_RUNTIME_PROOF_LABEL} wrapper proof launches successfully on hardware"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - ${ENTRY_WRAPPER_RUNTIME_PROOF_LABEL} wrapper proof failed on hardware"
    echo "  Output saved to: $LAUNCH_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
