#!/bin/bash
################################################################################
# rocBLAS integration test for omniprobe
#
# Verifies that omniprobe can instrument rocBLAS kernels that live inside
# librocblas.so itself (non-Tensile, BLAS Level 1 kernels like sscal).
#
# Prerequisites:
#   - ROCBLAS_LIB_DIR environment variable pointing to the directory containing
#     an instrumented librocblas.so (built with omniprobe instrumentation).
#   - The test binary test_rocblas_scal must be pre-built in this directory.
#
# Note: Tensile kernels (loaded via CCOB at runtime) are not yet supported
# and are not tested here.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"
TEST_BINARY="${SCRIPT_DIR}/test_rocblas_scal"
OUTPUT_DIR="${REPO_ROOT}/tests/test_output"
ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

mkdir -p "$OUTPUT_DIR"

################################################################################
# Preflight checks
################################################################################

if [ -z "$ROCBLAS_LIB_DIR" ]; then
    echo -e "${YELLOW}SKIP: ROCBLAS_LIB_DIR not set. Set it to the directory containing an instrumented librocblas.so to run rocBLAS tests.${NC}"
    exit 0
fi

if [ ! -f "$ROCBLAS_LIB_DIR/librocblas.so" ]; then
    echo -e "${RED}ERROR: librocblas.so not found in $ROCBLAS_LIB_DIR${NC}"
    echo "ROCBLAS_LIB_DIR is set but does not contain librocblas.so."
    exit 1
fi

if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

if [ ! -x "$TEST_BINARY" ]; then
    echo -e "${RED}ERROR: test_rocblas_scal not found at $TEST_BINARY${NC}"
    echo "Build it first (see test_rocblas_scal.cpp)."
    exit 1
fi

echo "================================================================================"
echo "rocBLAS Integration Tests"
echo "================================================================================"
echo "Omniprobe:      $OMNIPROBE"
echo "rocBLAS lib:    $ROCBLAS_LIB_DIR"
echo "Test binary:    $TEST_BINARY"
echo "Output dir:     $OUTPUT_DIR"
echo "GPU:            ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

################################################################################
# Test 1: rocBLAS scal kernel runs with instrumentation
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocblas_scal_instrumented"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run rocblas_sscal with MemoryAnalysis instrumentation"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   LD_LIBRARY_PATH="$ROCBLAS_LIB_DIR:$LD_LIBRARY_PATH" \
   "$OMNIPROBE" -i -a MemoryAnalysis \
   -- "$TEST_BINARY" > "$OUTPUT_FILE" 2>&1; then

    # Check that the scal kernel result is correct
    if grep -q "rocblas_sscal: PASS" "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}✓ PASS${NC} - rocblas_sscal computation correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - rocblas_sscal computation failed or not found"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 2: Instrumented alternative found for scal kernel
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocblas_scal_alternative"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumented alternative found for rocblas_sscal kernel"

if grep -q "Found instrumented alternative for.*rocblas_sscal" "$OUTPUT_DIR/rocblas_scal_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Found instrumented alternative for sscal kernel"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No instrumented alternative found for sscal kernel"
    echo "  Output saved to: $OUTPUT_DIR/rocblas_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 3: L2 cache line use report produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocblas_scal_cache_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify L2 cache line use report is generated"

if grep -q "L2 cache line use report" "$OUTPUT_DIR/rocblas_scal_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - L2 cache line use report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - L2 cache line use report not found"
    echo "  Output saved to: $OUTPUT_DIR/rocblas_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 4: Bank conflicts report produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocblas_scal_bank_conflicts"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify bank conflicts report is generated"

if grep -q "Bank conflicts report" "$OUTPUT_DIR/rocblas_scal_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Bank conflicts report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Bank conflicts report not found"
    echo "  Output saved to: $OUTPUT_DIR/rocblas_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 5: Startup completes in reasonable time (< 30 seconds)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocblas_scal_startup_time"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify startup scanning completes in < 30 seconds"

STARTUP_MS=$(grep '\[TIMING\] Total startup scanning loop' "$OUTPUT_DIR/rocblas_scal_instrumented.out" | grep -oP '\d+(?= ms)' || echo "0")

if [ "$STARTUP_MS" -gt 0 ] && [ "$STARTUP_MS" -lt 30000 ]; then
    echo -e "  ${GREEN}✓ PASS${NC} - Startup scanning took ${STARTUP_MS} ms"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Startup scanning took ${STARTUP_MS} ms (limit: 30000 ms)"
    echo "  Output saved to: $OUTPUT_DIR/rocblas_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Summary
################################################################################

echo ""
echo "================================================================================"
echo "rocBLAS Integration Test Summary"
echo "================================================================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "================================================================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All rocBLAS integration tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some rocBLAS integration tests failed.${NC}"
    exit 1
fi
