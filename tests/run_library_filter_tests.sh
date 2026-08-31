#!/bin/bash
################################################################################
# Library filter tests for omniprobe
# Tests --library-filter CLI argument with include/exclude JSON configs
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

# Helper function for library filter tests
# Args: test_name, kernel, filter_json, check_type, check_pattern
#   check_type: "present" (pattern should appear), "absent" (pattern should NOT appear)
#   check_pattern: grep pattern to search for in "Adding <library>" lines
run_library_filter_test() {
    local test_name="$1"
    local kernel="$2"
    local filter_json="$3"
    local check_type="$4"
    local check_pattern="$5"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Kernel: $kernel"
    echo "  Filter config: $filter_json"
    echo "  Check: $check_pattern should be $check_type"

    local output_file="$OUTPUT_DIR/${test_name}.out"
    local filter_file="$OUTPUT_DIR/${test_name}_filter.json"

    # Write filter config to temp file
    echo "$filter_json" > "$filter_file"

    # Run omniprobe with --library-filter
    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       "$OMNIPROBE" -i -a MemoryAnalysis --library-filter "$filter_file" -- "$kernel" > "$output_file" 2>&1; then

        # Extract "Adding <library>" lines for validation
        local adding_lines
        adding_lines=$(grep "^Adding " "$output_file" 2>/dev/null || true)

        case "$check_type" in
            present)
                if echo "$adding_lines" | grep -q "$check_pattern"; then
                    echo -e "  ${GREEN}✓ PASS${NC} - Found: '$check_pattern'"
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                    return 0
                else
                    echo -e "  ${RED}✗ FAIL${NC} - Expected to find: '$check_pattern'"
                    echo "  Libraries added:"
                    echo "$adding_lines" | head -10
                    echo "  Output saved to: $output_file"
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                    return 1
                fi
                ;;
            absent)
                if echo "$adding_lines" | grep -q "$check_pattern"; then
                    echo -e "  ${RED}✗ FAIL${NC} - Should NOT find: '$check_pattern'"
                    echo "  But found in:"
                    echo "$adding_lines" | grep "$check_pattern" | head -5
                    echo "  Output saved to: $output_file"
                    TESTS_FAILED=$((TESTS_FAILED + 1))
                    return 1
                else
                    echo -e "  ${GREEN}✓ PASS${NC} - Correctly excluded: '$check_pattern'"
                    TESTS_PASSED=$((TESTS_PASSED + 1))
                    return 0
                fi
                ;;
            *)
                echo -e "  ${RED}✗ FAIL${NC} - Unknown check_type: '$check_type'"
                TESTS_FAILED=$((TESTS_FAILED + 1))
                return 1
                ;;
        esac
    else
        echo -e "  ${RED}✗ FAIL${NC} - Kernel execution failed"
        echo "  Output saved to: $output_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

################################################################################
# Library Filter Tests
################################################################################

MEMORY_ANALYSIS_TEST="${BUILD_DIR}/tests/test_kernels/simple_memory_analysis_test"

if [ -x "$MEMORY_ANALYSIS_TEST" ]; then
    echo ""
    echo "================================================================================"
    echo "Library Filter Tests"
    echo "================================================================================"

    # Resolve native library paths from the test binary's own linkage.
    # Architecture-agnostic: ldd returns the paths the dynamic linker
    # would actually use for this binary, regardless of distro layout.
    LIBM_PATH=$(ldd "$MEMORY_ANALYSIS_TEST" 2>/dev/null \
        | awk '$1 ~ /^libm\.so/{print $3; exit}')
    if [ -z "$LIBM_PATH" ] || [ ! -e "$LIBM_PATH" ]; then
        echo -e "${RED}ERROR: Could not resolve libm.so path from ${MEMORY_ANALYSIS_TEST}${NC}" >&2
        echo "  ldd output:" >&2
        ldd "$MEMORY_ANALYSIS_TEST" 2>&1 | sed 's/^/    /' >&2
        exit 1
    fi
    NATIVE_LIB_DIR=$(dirname "$LIBM_PATH")
    LIBCRYPT_PATH=$(ls "${NATIVE_LIB_DIR}"/libcrypt.so.* 2>/dev/null \
        | head -1)

    # Test: Baseline - exclude non-existent library (should PASS, no behavior change)
    run_library_filter_test "libfilter_exclude_nonexistent" \
        "$MEMORY_ANALYSIS_TEST" \
        '{"exclude": ["/nonexistent/fake_library.so"]}' \
        "present" \
        "libm.so"

    # Test: Exclude libm (should NOT appear in "Adding" output)
    run_library_filter_test "libfilter_exclude_libm" \
        "$MEMORY_ANALYSIS_TEST" \
        "{\"exclude\": [\"${LIBM_PATH}\"]}" \
        "absent" \
        "libm.so"

    # Test: Include a file that wouldn't normally be scanned
    run_library_filter_test "libfilter_include_extra" \
        "$MEMORY_ANALYSIS_TEST" \
        "{\"include\": [\"${LIBCRYPT_PATH}\"]}" \
        "present" \
        "libcrypt.so"

else
    echo -e "\n${YELLOW}SKIP: Library filter tests (simple_memory_analysis_test not built)${NC}"
fi

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
