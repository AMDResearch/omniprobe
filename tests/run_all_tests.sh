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

    local output exit_code
    output=$("$script" "$@" 2>&1) && exit_code=0 || exit_code=$?

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

# Suite 2: Probe spec validation
run_suite "Probe spec validation" "${SCRIPT_DIR}/run_probe_spec_tests.sh"

# Suite 3: Binary-only probe planning
run_suite "Binary probe planning" "${SCRIPT_DIR}/run_binary_probe_planning_tests.sh"

# Suite 4: AMDGPU calling convention inference
run_suite "AMDGPU calling convention" "${SCRIPT_DIR}/run_amdgpu_calling_convention_tests.sh"

# Suite 5: Binary probe injector
run_suite "Binary probe injector" "${SCRIPT_DIR}/run_binary_probe_injector_tests.sh"

# Suite 6: Binary probe support compile
run_suite "Binary probe support compile" "${SCRIPT_DIR}/run_binary_probe_support_compile_tests.sh"

# Suite 7: Binary probe cache preparation
run_suite "Binary probe cache preparation" "${SCRIPT_DIR}/run_binary_probe_cache_prepare_tests.sh"

# Suite 8: Probe helper examples
run_suite "Probe helper examples" "${SCRIPT_DIR}/run_probe_helper_example_tests.sh"

# Suite 9: Probe surrogate smoke test
run_suite "Probe surrogate smoke" "${SCRIPT_DIR}/run_probe_surrogate_smoke_tests.sh"

# Suite 10: Probe lifecycle smoke test
run_suite "Probe lifecycle smoke" "${SCRIPT_DIR}/run_probe_lifecycle_smoke_tests.sh"

# Suite 11: Binary-only probe runtime smoke
run_suite "Binary probe runtime smoke" "${SCRIPT_DIR}/run_binary_probe_runtime_smoke_tests.sh"

# Suite 12: Binary-only probe entry runtime smoke
run_suite "Binary probe entry runtime smoke" "${SCRIPT_DIR}/run_binary_probe_entry_runtime_smoke_tests.sh"

# Suite 13: Library filter chain (has its own build step)
run_suite "Library filter chain" "${SCRIPT_DIR}/library_filter_chain/run_test.sh"

# Suite 14: External code-object donor-free regeneration
run_suite "External code-object regeneration" "${SCRIPT_DIR}/run_codeobj_external_regen_tests.sh"

# Suite 15: Code-object round-trip and donor-free regeneration scaffold
run_suite "Code-object round-trip" "${SCRIPT_DIR}/run_codeobj_roundtrip_tests.sh"

# Suite 16: rocPRIM donor-free breadth
run_suite "rocPRIM donor-free breadth" "${SCRIPT_DIR}/run_codeobj_rocprim_breadth_tests.sh"

# Suite 17: hipBLASLt instrumentation (requires INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "hipBLASLt instrumentation" "${SCRIPT_DIR}/hipblaslt/run_test.sh"

# Suite 18: rocBLAS integration (requires INSTRUMENTED_ROCBLAS_LIB_DIR)
run_suite "rocBLAS integration" "${SCRIPT_DIR}/rocblas_filter/run_test.sh"

# Suite 19: rocBLAS + hipBLASLt combined (requires INSTRUMENTED_ROCBLAS_LIB_DIR + INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "rocBLAS + hipBLASLt combined" "${SCRIPT_DIR}/rocblas_hipblaslt/run_test.sh"

# Suite 20: Triton integration (requires TRITON_DIR)
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
