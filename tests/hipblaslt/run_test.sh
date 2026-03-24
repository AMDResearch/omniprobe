#!/bin/bash
################################################################################
# hipBLASLt instrumentation test for omniprobe
#
# Verifies that omniprobe can instrument hipBLASLt matrix transform kernels.
# These kernels are compiled from HIP source (matrix_transform.cpp) and
# instrumented with the AMDGCNSubmitAddressMessages LLVM IR pass plugin.
#
# Prerequisites:
#   - INSTRUMENTED_HIPBLASLT_LIB_DIR environment variable pointing to the
#     directory containing libhipblaslt.so (custom installation with
#     instrumented device code objects). The unbundled .hsaco is
#     auto-discovered from hipblaslt/library/ under this directory.
#   - The test binary test_hipblaslt_transform must be pre-built in this
#     directory.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
OMNIPROBE_ROOT="${OMNIPROBE_ROOT:-${BUILD_DIR}}"
OMNIPROBE="${OMNIPROBE_ROOT}/bin/omniprobe"
TEST_BINARY="${SCRIPT_DIR}/test_hipblaslt_transform"
OUTPUT_DIR="${REPO_ROOT}/tests/test_output"
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

if [ -z "$INSTRUMENTED_HIPBLASLT_LIB_DIR" ]; then
    echo -e "${YELLOW}SKIP: INSTRUMENTED_HIPBLASLT_LIB_DIR not set.${NC}"
    echo "Set it to the directory containing libhipblaslt.so (custom installation with instrumented device code)."
    exit 0
fi

if [ ! -f "$INSTRUMENTED_HIPBLASLT_LIB_DIR/libhipblaslt.so" ]; then
    echo -e "${RED}ERROR: libhipblaslt.so not found in $INSTRUMENTED_HIPBLASLT_LIB_DIR${NC}"
    exit 1
fi

# Auto-discover the unbundled instrumented hipblasltTransform .hsaco
HIPBLASLT_INSTRUMENTED_HSACO=""
for hsaco in $(find "$INSTRUMENTED_HIPBLASLT_LIB_DIR/hipblaslt/library" -name "hipblasltTransform-*.hsaco" 2>/dev/null); do
    if nm "$hsaco" 2>/dev/null | grep -q "__amd_crk_Transform_"; then
        HIPBLASLT_INSTRUMENTED_HSACO="$hsaco"
        break
    fi
done

if [ -z "$HIPBLASLT_INSTRUMENTED_HSACO" ]; then
    echo -e "${RED}ERROR: No instrumented hipblasltTransform .hsaco found in $INSTRUMENTED_HIPBLASLT_LIB_DIR/hipblaslt/library/${NC}"
    exit 1
fi

if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

if [ ! -x "$TEST_BINARY" ]; then
    echo -e "${RED}ERROR: test_hipblaslt_transform not found at $TEST_BINARY${NC}"
    echo "Build it first (see test_hipblaslt_transform.cpp)."
    exit 1
fi

# Create temporary library filter config
FILTER_FILE=$(mktemp /tmp/hipblaslt_filter_XXXXXX.json)
cat > "$FILTER_FILE" <<EOF
{
  "include": [
    "$HIPBLASLT_INSTRUMENTED_HSACO"
  ]
}
EOF
trap "rm -f $FILTER_FILE" EXIT

echo "================================================================================"
echo "hipBLASLt Instrumentation Tests"
echo "================================================================================"
echo "Omniprobe:           $OMNIPROBE"
echo "hipBLASLt lib:       $INSTRUMENTED_HIPBLASLT_LIB_DIR"
echo "Instrumented .hsaco: $HIPBLASLT_INSTRUMENTED_HSACO"
echo "Test binary:         $TEST_BINARY"
echo "Output dir:          $OUTPUT_DIR"
echo "GPU:                 ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

################################################################################
# Test 1: hipBLASLt matrix transform runs with instrumentation
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hipblaslt_transform_instrumented"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run hipblasLtMatrixTransform with MemoryAnalysis instrumentation"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

SECONDS=0
if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   LD_LIBRARY_PATH="$INSTRUMENTED_HIPBLASLT_LIB_DIR:$LD_LIBRARY_PATH" \
   "$OMNIPROBE" -i -a MemoryAnalysis \
   --library-filter "$FILTER_FILE" \
   -- "$TEST_BINARY" > "$OUTPUT_FILE" 2>&1; then
    ELAPSED_SECONDS=$SECONDS

    # Check that the matrix transform result is correct
    if grep -q "hipblaslt_matrix_transform: PASS" "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}✓ PASS${NC} - hipblasLtMatrixTransform computation correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - hipblasLtMatrixTransform computation failed or not found"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 2: Instrumented alternative found for Transform kernel
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hipblaslt_transform_alternative"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumented alternative found for matrix transform kernel"

if grep -q "Found instrumented alternative for Transform_" "$OUTPUT_DIR/hipblaslt_transform_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Found instrumented alternative for Transform kernel"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No instrumented alternative found for Transform kernel"
    echo "  Output saved to: $OUTPUT_DIR/hipblaslt_transform_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 3: L2 cache line use report produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hipblaslt_transform_cache_report"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify L2 cache line use report is generated"

if grep -q "L2 cache line use report" "$OUTPUT_DIR/hipblaslt_transform_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - L2 cache line use report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - L2 cache line use report not found"
    echo "  Output saved to: $OUTPUT_DIR/hipblaslt_transform_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 4: Bank conflicts report produced
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hipblaslt_transform_bank_conflicts"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify bank conflicts report is generated"

if grep -q "Bank conflicts report" "$OUTPUT_DIR/hipblaslt_transform_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Bank conflicts report present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Bank conflicts report not found"
    echo "  Output saved to: $OUTPUT_DIR/hipblaslt_transform_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 5: Total run completes in reasonable time (< 60 seconds)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hipblaslt_transform_elapsed_time"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify total elapsed time < 60 seconds"

if [ "$ELAPSED_SECONDS" -lt 60 ] 2>/dev/null; then
    echo -e "  ${GREEN}✓ PASS${NC} - Total elapsed time: ${ELAPSED_SECONDS}s"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Total elapsed time: ${ELAPSED_SECONDS:-unknown}s (limit: 60s)"
    echo "  Output saved to: $OUTPUT_DIR/hipblaslt_transform_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Summary
################################################################################

echo ""
echo "================================================================================"
echo "hipBLASLt Instrumentation Test Summary"
echo "================================================================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "================================================================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All hipBLASLt instrumentation tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some hipBLASLt instrumentation tests failed.${NC}"
    exit 1
fi
