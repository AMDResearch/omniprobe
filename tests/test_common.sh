#!/bin/bash
################################################################################
# Common utilities for omniprobe test scripts
# Source this file from feature-specific test scripts
################################################################################

# Derive paths from repo structure
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

# Use repo's omniprobe - always use relative paths, never hardcoded installation paths
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"

TEST_KERNELS_DIR="${SCRIPT_DIR}/test_kernels"
OUTPUT_DIR="${SCRIPT_DIR}/test_output"
ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
NC='\033[0m' # No Color

# Test counters (use export so they persist across sourced scripts)
export TESTS_RUN=${TESTS_RUN:-0}
export TESTS_PASSED=${TESTS_PASSED:-0}
export TESTS_FAILED=${TESTS_FAILED:-0}

# Check prerequisites
check_omniprobe() {
    if [ ! -x "$OMNIPROBE" ]; then
        echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
        exit 1
    fi
    mkdir -p "$OUTPUT_DIR"
}

# Helper to check if kernel exists
check_kernel() {
    local kernel="$1"
    if [ ! -x "$kernel" ]; then
        echo -e "${RED}ERROR: Test kernel not found or not executable: $kernel${NC}"
        echo "Did you build the tests? Run: cmake .. -DINTERCEPTOR_BUILD_TESTING=ON && ninja"
        exit 1
    fi
}

# Helper function to run a basic test
run_test() {
    local test_name="$1"
    local kernel="$2"
    local analyzer="$3"
    local expected_pattern="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Kernel: $kernel"
    echo "  Analyzer: $analyzer"

    local output_file="$OUTPUT_DIR/${test_name}.out"

    # Run omniprobe and capture output
    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       "$OMNIPROBE" -i -a "$analyzer" -- "$kernel" > "$output_file" 2>&1; then

        # Check for expected pattern in output
        if grep -q "$expected_pattern" "$output_file"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Found expected pattern: '$expected_pattern'"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            echo -e "  ${RED}✗ FAIL${NC} - Expected pattern not found: '$expected_pattern'"
            echo "  Output saved to: $output_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Kernel execution failed"
        echo "  Output saved to: $output_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Print test summary
print_summary() {
    echo ""
    echo "================================================================================"
    echo "Test Summary"
    echo "================================================================================"
    echo -e "Total tests run: $TESTS_RUN"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    echo "================================================================================"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed. Check output files in $OUTPUT_DIR${NC}"
        return 1
    fi
}
