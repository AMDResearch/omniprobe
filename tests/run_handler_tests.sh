#!/bin/bash
################################################################################
# End-to-end test script for omniprobe handlers
# Tests handlers via omniprobe to verify behavior before/after wrapper removal
################################################################################

set -e  # Exit on error

# Configuration
OMNIPROBE="${HOME}/work/.local/bin/logDuration/omniprobe"
TEST_KERNELS_DIR="$(dirname "$0")/test_kernels"
OUTPUT_DIR="$(dirname "$0")/test_output"
ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run a test
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

# Helper to check if kernel exists
check_kernel() {
    local kernel="$1"
    if [ ! -x "$kernel" ]; then
        echo -e "${RED}ERROR: Test kernel not found or not executable: $kernel${NC}"
        echo "Did you build the tests? Run: cmake .. -DINTERCEPTOR_BUILD_TESTING=ON && ninja"
        exit 1
    fi
}

echo "================================================================================"
echo "Omniprobe Handler End-to-End Tests"
echo "================================================================================"
echo "Omniprobe: $OMNIPROBE"
echo "Test kernels: $TEST_KERNELS_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "GPU: ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

# Use project's instrumented test kernels
# Find the build directory - support running from repo root or build directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/build"

HEATMAP_TEST="${BUILD_DIR}/tests/test_kernels/simple_heatmap_test"
MEMORY_ANALYSIS_TEST="${BUILD_DIR}/tests/test_kernels/simple_memory_analysis_test"

if [ ! -x "$HEATMAP_TEST" ]; then
    echo -e "${RED}ERROR: Test kernel not found at $HEATMAP_TEST${NC}"
    echo "Make sure you have built the project with: ninja"
    exit 1
fi

if [ ! -x "$MEMORY_ANALYSIS_TEST" ]; then
    echo -e "${RED}ERROR: Test kernel not found at $MEMORY_ANALYSIS_TEST${NC}"
    echo "Make sure you have built the project with: ninja"
    exit 1
fi

check_kernel "$HEATMAP_TEST"
check_kernel "$MEMORY_ANALYSIS_TEST"

# Test 1: Memory heatmap handler
run_test "heatmap_basic" \
    "$HEATMAP_TEST" \
    "Heatmap" \
    "memory heatmap report"

# Test 2: Memory analysis handler - should report cache line usage
run_test "memory_analysis_cache_lines" \
    "$MEMORY_ANALYSIS_TEST" \
    "MemoryAnalysis" \
    "L2 cache line use report"

# Test 3: Verify heatmap handler produces page access counts
run_test "heatmap_page_accesses" \
    "$HEATMAP_TEST" \
    "Heatmap" \
    "accesses"

# Summary
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
    exit 0
else
    echo -e "${RED}Some tests failed. Check output files in $OUTPUT_DIR${NC}"
    exit 1
fi
