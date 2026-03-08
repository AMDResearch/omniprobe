#!/bin/bash
################################################################################
# Triton integration test for omniprobe
#
# Verifies that omniprobe can instrument Triton-compiled kernels by running
# a minimal vector-add kernel through omniprobe with MemoryAnalysis.
#
# Prerequisites:
#   - TRITON_DIR environment variable pointing to the Triton repository
#     (must contain a .venv with Triton installed)
#   - omniprobe built with TRITON_LLVM support
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"
TRITON_CACHE="${HOME}/.triton/cache"
VECTOR_ADD="${SCRIPT_DIR}/vector_add.py"
OUTPUT_DIR="${SCRIPT_DIR}/test_output"
ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

mkdir -p "$OUTPUT_DIR"

################################################################################
# Preflight checks
################################################################################

if [ -z "$TRITON_DIR" ]; then
    echo -e "${YELLOW}SKIP: TRITON_DIR not set. Set it to the Triton repository path to run Triton tests.${NC}"
    exit 0
fi

TRITON_VENV="${TRITON_DIR}/.venv"

if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

if [ ! -d "$TRITON_VENV" ]; then
    echo -e "${RED}ERROR: Triton venv not found at $TRITON_VENV${NC}"
    echo "TRITON_DIR is set to $TRITON_DIR but no .venv directory was found there."
    exit 1
fi

if [ ! -f "$VECTOR_ADD" ]; then
    echo -e "${RED}ERROR: vector_add.py not found at $VECTOR_ADD${NC}"
    exit 1
fi

echo "================================================================================"
echo "Triton Integration Tests"
echo "================================================================================"
echo "Omniprobe:    $OMNIPROBE"
echo "Triton venv:  $TRITON_VENV"
echo "Triton cache: $TRITON_CACHE"
echo "Test script:  $VECTOR_ADD"
echo "GPU:          ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

# Activate Triton venv
source "$TRITON_VENV/bin/activate"

################################################################################
# Test 1: Instrumentation plugin is invoked during Triton JIT compilation
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="triton_instrumentation_plugin"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumentation plugin runs during Triton JIT compilation"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$OMNIPROBE" -a MemoryAnalysis -i -c "$TRITON_CACHE" \
   -- python "$VECTOR_ADD" > "$OUTPUT_FILE" 2>&1; then

    if grep -q "Running AMDGCNSubmitAddressMessage on module" "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Instrumentation plugin invoked on Triton module"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Instrumentation plugin not invoked"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 2: Instrumented kernel alternative is found and dispatched
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="triton_instrumented_dispatch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumented kernel alternative is found for add_kernel"

# Re-use output from test 1 (same run)
if grep -q "Found instrumented alternative for add_kernel" "$OUTPUT_DIR/triton_instrumentation_plugin.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Found instrumented alternative for add_kernel"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No instrumented alternative found for add_kernel"
    echo "  Output saved to: $OUTPUT_DIR/triton_instrumentation_plugin.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 3: L2 cache line use report is produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="triton_cache_line_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify L2 cache line use report is generated"

if grep -q "L2 cache line use report" "$OUTPUT_DIR/triton_instrumentation_plugin.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - L2 cache line use report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - L2 cache line use report not found"
    echo "  Output saved to: $OUTPUT_DIR/triton_instrumentation_plugin.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 4: Bank conflicts report is produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="triton_bank_conflicts_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify bank conflicts report is generated"

if grep -q "Bank conflicts report" "$OUTPUT_DIR/triton_instrumentation_plugin.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Bank conflicts report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Bank conflicts report not found"
    echo "  Output saved to: $OUTPUT_DIR/triton_instrumentation_plugin.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Summary
################################################################################

echo ""
echo "================================================================================"
echo "Triton Integration Test Summary"
echo "================================================================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "================================================================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All Triton integration tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some Triton integration tests failed.${NC}"
    exit 1
fi
