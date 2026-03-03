#!/bin/bash
################################################################################
# End-to-end test script for omniprobe handlers
# Tests handlers via omniprobe to verify behavior before/after wrapper removal
################################################################################

set -e  # Exit on error

# Configuration
# Derive paths from repo structure - tests/ is in REPO_ROOT, omniprobe is in REPO_ROOT/omniprobe/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/build"

# Use repo's omniprobe with build directory's runtime_config.txt
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"
# Copy runtime_config.txt to omniprobe directory so it can find build artifacts
if [ -f "${BUILD_DIR}/runtime_config.txt" ]; then
    cp "${BUILD_DIR}/runtime_config.txt" "${REPO_ROOT}/omniprobe/runtime_config.txt"
fi

TEST_KERNELS_DIR="${SCRIPT_DIR}/test_kernels"
OUTPUT_DIR="${SCRIPT_DIR}/test_output"
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

# Helper function to run a filter test that validates message block_idx values
# Args: test_name, kernel, expected_count, filter_x, filter_y, filter_z
# filter_{x,y,z} format: "" (no filter), "N" (single value), "N:M" (range [N,M))
run_filter_test() {
    local test_name="$1"
    local kernel="$2"
    local expected_count="$3"
    local filter_x="$4"
    local filter_y="$5"
    local filter_z="$6"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Kernel: $kernel"
    echo "  Expected message count: $expected_count"
    echo "  Filters: X=${filter_x:-any} Y=${filter_y:-any} Z=${filter_z:-any}"

    local output_file="$OUTPUT_DIR/${test_name}.out"

    # Build omniprobe command with filter flags
    local filter_args=()
    [ -n "$filter_x" ] && filter_args+=(--filter-x "$filter_x")
    [ -n "$filter_y" ] && filter_args+=(--filter-y "$filter_y")
    [ -n "$filter_z" ] && filter_args+=(--filter-z "$filter_z")

    # Run omniprobe with filter CLI flags
    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       "$OMNIPROBE" -i -a AddressLogger "${filter_args[@]}" -- "$kernel" > "$output_file" 2>&1; then

        # Count JSON messages (grep -c returns 0 on no match with exit code 1)
        local actual_count
        actual_count=$(grep -c '"block_idx_x":' "$output_file" 2>/dev/null || echo "0")
        # Ensure we have a single integer
        actual_count="${actual_count##*$'\n'}"

        # Validate message count
        if [ "$actual_count" -ne "$expected_count" ]; then
            echo -e "  ${RED}✗ FAIL${NC} - Message count: $actual_count (expected $expected_count)"
            echo "  Output saved to: $output_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi

        # If count is 0, no need to validate contents
        if [ "$expected_count" -eq 0 ]; then
            echo -e "  ${GREEN}✓ PASS${NC} - Message count: 0 (expected 0)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        fi

        # Validate block_idx values are within filter ranges
        # Extract unique block coordinates and check each one
        local invalid_messages=0
        local validation_errors=""

        while IFS= read -r line; do
            local bx by bz
            bx=$(echo "$line" | grep -o '"block_idx_x": [0-9]*' | grep -o '[0-9]*')
            by=$(echo "$line" | grep -o '"block_idx_y": [0-9]*' | grep -o '[0-9]*')
            bz=$(echo "$line" | grep -o '"block_idx_z": [0-9]*' | grep -o '[0-9]*')

            # Check X filter
            if [ -n "$filter_x" ]; then
                if ! check_in_range "$bx" "$filter_x"; then
                    invalid_messages=$((invalid_messages + 1))
                    validation_errors+="    block_idx_x=$bx not in range '$filter_x'\n"
                fi
            fi

            # Check Y filter
            if [ -n "$filter_y" ]; then
                if ! check_in_range "$by" "$filter_y"; then
                    invalid_messages=$((invalid_messages + 1))
                    validation_errors+="    block_idx_y=$by not in range '$filter_y'\n"
                fi
            fi

            # Check Z filter
            if [ -n "$filter_z" ]; then
                if ! check_in_range "$bz" "$filter_z"; then
                    invalid_messages=$((invalid_messages + 1))
                    validation_errors+="    block_idx_z=$bz not in range '$filter_z'\n"
                fi
            fi
        done < <(grep '"block_idx_x":' "$output_file")

        if [ "$invalid_messages" -gt 0 ]; then
            echo -e "  ${RED}✗ FAIL${NC} - $invalid_messages messages with invalid block_idx values"
            echo -e "$validation_errors" | head -10
            echo "  Output saved to: $output_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi

        echo -e "  ${GREEN}✓ PASS${NC} - Message count: $actual_count, all block_idx values valid"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗ FAIL${NC} - Kernel execution failed"
        echo "  Output saved to: $output_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Helper: check if value is in range (format: "N" for single, "N:M" for range [N,M))
check_in_range() {
    local value="$1"
    local range="$2"

    if [[ "$range" == *:* ]]; then
        # Range format N:M
        local min="${range%%:*}"
        local max="${range#*:}"
        [ "$value" -ge "$min" ] && [ "$value" -lt "$max" ]
    else
        # Single value
        [ "$value" -eq "$range" ]
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

################################################################################
# Block Index Filter Tests
# Test DH_COMMS_GROUP_FILTER_{X,Y,Z} environment variables
# Grid: 8x4x2 = 64 blocks, 3 messages per block = 192 total messages
################################################################################

BLOCK_FILTER_TEST="${BUILD_DIR}/tests/test_kernels/block_filter_test"

if [ -x "$BLOCK_FILTER_TEST" ]; then
    echo ""
    echo "================================================================================"
    echo "Block Index Filter Tests"
    echo "================================================================================"

    # Test 4: Baseline - no filter, all 192 messages should pass
    # Args: test_name, kernel, expected_count, filter_x, filter_y, filter_z
    run_filter_test "filter_baseline_no_filter" \
        "$BLOCK_FILTER_TEST" \
        192 \
        "" "" ""

    # Test 5: Single value filter on X dimension
    # --filter-x 5 -> only x=5 passes -> 4*2=8 blocks -> 24 messages
    run_filter_test "filter_single_x" \
        "$BLOCK_FILTER_TEST" \
        24 \
        "5" "" ""

    # Test 6: Range filter on X dimension
    # --filter-x 2:6 -> x in [2,6) passes -> 4*4*2=32 blocks -> 96 messages
    run_filter_test "filter_range_x" \
        "$BLOCK_FILTER_TEST" \
        96 \
        "2:6" "" ""

    # Test 7: Multi-dimension filter (X and Y)
    # --filter-x 2 --filter-y 1 -> x=2,y=1 -> 2 blocks -> 6 messages
    run_filter_test "filter_multi_xy" \
        "$BLOCK_FILTER_TEST" \
        6 \
        "2" "1" ""

    # Test 8: Empty range filter (should pass 0 messages)
    # --filter-x 3:3 -> empty range -> 0 blocks -> 0 messages
    run_filter_test "filter_empty_range" \
        "$BLOCK_FILTER_TEST" \
        0 \
        "3:3" "" ""

    # Test 9: Filter on Z dimension
    # --filter-z 1 -> z=1 only -> 8*4*1=32 blocks -> 96 messages
    run_filter_test "filter_single_z" \
        "$BLOCK_FILTER_TEST" \
        96 \
        "" "" "1"

else
    echo -e "\n${YELLOW}SKIP: Block filter tests (block_filter_test not built)${NC}"
fi

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
