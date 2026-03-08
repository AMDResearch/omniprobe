#!/bin/bash
################################################################################
# Run all omniprobe tests
#
# Usage: ./run_all_tests.sh
#
# Test suites:
#   1. Handler tests (basic, block filter, library filter)
#   2. Library filter chain tests (builds its own test libraries)
#   3. hipBLASLt instrumentation (requires INSTRUMENTED_HIPBLASLT_LIB_DIR)
#   4. rocBLAS integration (requires INSTRUMENTED_ROCBLAS_LIB_DIR)
#   5. rocBLAS + hipBLASLt combined (requires INSTRUMENTED_ROCBLAS_LIB_DIR + INSTRUMENTED_HIPBLASLT_LIB_DIR)
#   6. Triton integration (requires TRITON_DIR)
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
NC='\033[0m'

SUITES_RUN=0
SUITES_PASSED=0
SUITES_SKIPPED=0
SUITES_FAILED=0
FAILED_SUITES=""

run_suite() {
    local name="$1"
    local script="$2"
    shift 2

    SUITES_RUN=$((SUITES_RUN + 1))
    echo ""
    echo "################################################################################"
    echo -e "${YELLOW}Suite ${SUITES_RUN}: ${name}${NC}"
    echo "################################################################################"

    if [ ! -x "$script" ]; then
        echo -e "${RED}SKIP${NC}: $script not found or not executable"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES="${FAILED_SUITES}  - ${name} (script not found)\n"
        return 1
    fi

    local output
    output=$("$script" "$@" 2>&1)
    local exit_code=$?

    echo "$output"

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Suite FAILED: ${name}${NC}"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES="${FAILED_SUITES}  - ${name}\n"
    elif echo "$output" | grep -q "SKIP"; then
        echo -e "${YELLOW}Suite SKIPPED: ${name}${NC}"
        SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
    else
        echo -e "${GREEN}Suite PASSED: ${name}${NC}"
        SUITES_PASSED=$((SUITES_PASSED + 1))
    fi
}

echo "================================================================================"
echo "Omniprobe — All Tests"
echo "================================================================================"

# Suite 1: Handler tests (basic + block filter + library filter)
run_suite "Handler tests" "${SCRIPT_DIR}/run_handler_tests.sh"

# Suite 2: Library filter chain (has its own build step)
run_suite "Library filter chain" "${SCRIPT_DIR}/library_filter_chain/run_test.sh"

# Suite 3: hipBLASLt instrumentation (requires INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "hipBLASLt instrumentation" "${SCRIPT_DIR}/hipblaslt/run_test.sh"

# Suite 4: rocBLAS integration (requires INSTRUMENTED_ROCBLAS_LIB_DIR)
run_suite "rocBLAS integration" "${SCRIPT_DIR}/rocblas_filter/run_test.sh"

# Suite 5: rocBLAS + hipBLASLt combined (requires INSTRUMENTED_ROCBLAS_LIB_DIR + INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "rocBLAS + hipBLASLt combined" "${SCRIPT_DIR}/rocblas_hipblaslt/run_test.sh"

# Suite 6: Triton integration (requires TRITON_DIR)
run_suite "Triton integration" "${SCRIPT_DIR}/triton/run_test.sh"

# Summary
echo ""
echo "================================================================================"
echo "Overall Summary"
echo "================================================================================"
echo "Suites run:     $SUITES_RUN"
echo -e "${GREEN}Suites passed:  $SUITES_PASSED${NC}"
echo -e "${YELLOW}Suites skipped: $SUITES_SKIPPED${NC}"
echo -e "${RED}Suites failed:  $SUITES_FAILED${NC}"

if [ $SUITES_FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed suites:${NC}"
    echo -e "$FAILED_SUITES"
    echo "================================================================================"
    exit 1
else
    echo "================================================================================"
    echo -e "${GREEN}All suites passed!${NC}"
    exit 0
fi
