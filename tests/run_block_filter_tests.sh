#!/bin/bash
################################################################################
# Block index filter tests for omniprobe
# Tests DH_COMMS_GROUP_FILTER_{X,Y,Z} via --filter-x/y/z CLI flags
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

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

################################################################################
# Block Index Filter Tests
# Grid: 8x4x2 = 64 blocks, 3 messages per block = 192 total messages
################################################################################

BLOCK_FILTER_TEST="${BUILD_DIR}/tests/test_kernels/block_filter_test"

if [ -x "$BLOCK_FILTER_TEST" ]; then
    echo ""
    echo "================================================================================"
    echo "Block Index Filter Tests"
    echo "================================================================================"

    # Test: Baseline - no filter, all 192 messages should pass
    run_filter_test "filter_baseline_no_filter" \
        "$BLOCK_FILTER_TEST" \
        192 \
        "" "" ""

    # Test: Single value filter on X dimension
    # --filter-x 5 -> only x=5 passes -> 4*2=8 blocks -> 24 messages
    run_filter_test "filter_single_x" \
        "$BLOCK_FILTER_TEST" \
        24 \
        "5" "" ""

    # Test: Range filter on X dimension
    # --filter-x 2:6 -> x in [2,6) passes -> 4*4*2=32 blocks -> 96 messages
    run_filter_test "filter_range_x" \
        "$BLOCK_FILTER_TEST" \
        96 \
        "2:6" "" ""

    # Test: Multi-dimension filter (X and Y)
    # --filter-x 2 --filter-y 1 -> x=2,y=1 -> 2 blocks -> 6 messages
    run_filter_test "filter_multi_xy" \
        "$BLOCK_FILTER_TEST" \
        6 \
        "2" "1" ""

    # Test: Empty range filter (should pass 0 messages)
    # --filter-x 3:3 -> empty range -> 0 blocks -> 0 messages
    run_filter_test "filter_empty_range" \
        "$BLOCK_FILTER_TEST" \
        0 \
        "3:3" "" ""

    # Test: Filter on Z dimension
    # --filter-z 1 -> z=1 only -> 8*4*1=32 blocks -> 96 messages
    run_filter_test "filter_single_z" \
        "$BLOCK_FILTER_TEST" \
        96 \
        "" "" "1"

else
    echo -e "\n${YELLOW}SKIP: Block filter tests (block_filter_test not built)${NC}"
fi

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
