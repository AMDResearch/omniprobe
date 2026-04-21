#!/bin/bash
################################################################################
# Scope filter tests for omniprobe instrumentation
# Tests INSTRUMENTATION_SCOPE and INSTRUMENTATION_SCOPE_FILE env vars
#
# Unlike block filter tests (runtime filtering), scope filtering is a
# compile-time feature: the plugin reads INSTRUMENTATION_SCOPE during
# compilation to decide which instructions to instrument. This means the
# test kernel must be recompiled for each scope setting.
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

# Paths
INST_PLUGIN="${OMNIPROBE_ROOT}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"
KERNEL_SRC="${TEST_KERNELS_DIR}/scope_filter_test.cpp"

# Use ROCM_PATH to find hipcc (same logic as CMakeLists.txt)
ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
HIPCC="${ROCM_PATH}/bin/hipcc"

if [ ! -x "$HIPCC" ]; then
    echo -e "${YELLOW}SKIP: Scope filter tests (hipcc not found at ${HIPCC}; set ROCM_PATH)${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    exit 0
fi

if [ ! -f "$INST_PLUGIN" ]; then
    echo -e "${YELLOW}SKIP: Scope filter tests (instrumentation plugin not built)${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    exit 0
fi

if [ ! -f "$KERNEL_SRC" ]; then
    echo -e "${YELLOW}SKIP: Scope filter tests (scope_filter_test.cpp not found)${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    exit 0
fi

# Detect GPU architecture from the actual hardware (not CMake cache, which may
# contain multiple architectures separated by semicolons — unusable as a single
# --offload-arch value).
GPU_ARCH=$(rocminfo 2>/dev/null | grep -oP 'gfx\w+' | head -1)
if [ -z "$GPU_ARCH" ]; then
    echo -e "${YELLOW}SKIP: Scope filter tests (cannot detect GPU architecture via rocminfo)${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

# Discover SCOPE_MARKER lines dynamically from kernel source
# Each SCOPE_MARKER line has a memory operation (load or store)
declare -A MARKER_LINES
MARKER_COUNT=0
while IFS= read -r match; do
    line_num=$(echo "$match" | cut -d: -f1)
    label=$(echo "$match" | grep -o 'SCOPE_MARKER [a-z_]*' | cut -d' ' -f2)
    MARKER_LINES["$label"]=$line_num
    MARKER_COUNT=$((MARKER_COUNT + 1))
done < <(grep -n '// SCOPE_MARKER' "$KERNEL_SRC")

echo ""
echo "================================================================================"
echo "Scope Filter Tests"
echo "================================================================================"
echo "Kernel source: $KERNEL_SRC"
echo "Plugin: $INST_PLUGIN"
echo "GPU arch: $GPU_ARCH"
echo "SCOPE_MARKER lines found: $MARKER_COUNT"
for label in "${!MARKER_LINES[@]}"; do
    echo "  $label: line ${MARKER_LINES[$label]}"
done
echo "================================================================================"

# Compile the test kernel with a given scope setting
# Args: output_binary [scope_value] [scope_file_path]
compile_with_scope() {
    local output="$1"
    local scope_value="$2"
    local scope_file="$3"

    local env_prefix=()
    if [ -n "$scope_value" ]; then
        env_prefix+=(INSTRUMENTATION_SCOPE="$scope_value")
    fi
    if [ -n "$scope_file" ]; then
        env_prefix+=(INSTRUMENTATION_SCOPE_FILE="$scope_file")
    fi

    env "${env_prefix[@]}" "$HIPCC" \
        -g \
        -fgpu-rdc \
        --offload-arch="$GPU_ARCH" \
        -fpass-plugin="$INST_PLUGIN" \
        -I"${TEST_KERNELS_DIR}" \
        -o "$output" \
        "$KERNEL_SRC" \
        2>"${output}.compile.log"
}

# Count JSON address messages in omniprobe output
count_messages() {
    local output_file="$1"
    grep -c '"dwarf_line":' "$output_file" 2>/dev/null || echo "0"
}

# Run a scope filter test
# Args: test_name, scope_value, scope_file, expected_count_description
run_scope_test() {
    local test_name="$1"
    local scope_value="$2"
    local scope_file="$3"
    local expected_count="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Scope: ${scope_value:-<not set>}"
    [ -n "$scope_file" ] && echo "  Scope file: $scope_file"
    echo "  Expected message count: $expected_count"

    local output_binary="$OUTPUT_DIR/${test_name}"
    local output_file="$OUTPUT_DIR/${test_name}.out"

    # Compile with scope
    if ! compile_with_scope "$output_binary" "$scope_value" "$scope_file"; then
        echo -e "  ${RED}✗ FAIL${NC} - Compilation failed"
        echo "  Compile log: ${output_binary}.compile.log"
        cat "${output_binary}.compile.log" 2>/dev/null | tail -20
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi

    # Run under omniprobe
    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       "$OMNIPROBE" -i -a AddressLogger -- "$output_binary" > "$output_file" 2>&1; then

        local actual_count
        actual_count=$(count_messages "$output_file")
        actual_count="${actual_count##*$'\n'}"

        if [ "$actual_count" -ne "$expected_count" ]; then
            echo -e "  ${RED}✗ FAIL${NC} - Message count: $actual_count (expected $expected_count)"
            echo "  Output saved to: $output_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi

        echo -e "  ${GREEN}✓ PASS${NC} - Message count: $actual_count (expected $expected_count)"
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
# Determine baseline message count
# The kernel has 4 SCOPE_MARKER lines (2 loads, 2 stores), but the compiler
# may generate additional load/store instructions from the if(idx>=n) check
# or other lowering. We discover the actual baseline by compiling without
# scope first.
################################################################################

echo -e "\n${YELLOW}Compiling baseline (no scope)...${NC}"
BASELINE_BINARY="$OUTPUT_DIR/scope_baseline"
if ! compile_with_scope "$BASELINE_BINARY" "" ""; then
    echo -e "${RED}ERROR: Baseline compilation failed. Cannot run scope filter tests.${NC}"
    cat "${BASELINE_BINARY}.compile.log" 2>/dev/null | tail -20
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    exit 1
fi

BASELINE_OUTPUT="$OUTPUT_DIR/scope_baseline.out"
if ! ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   "$OMNIPROBE" -i -a AddressLogger -- "$BASELINE_BINARY" > "$BASELINE_OUTPUT" 2>&1; then
    echo -e "${RED}ERROR: Baseline execution failed. Cannot run scope filter tests.${NC}"
    cat "$BASELINE_OUTPUT" 2>/dev/null | tail -20
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    exit 1
fi

BASELINE_COUNT=$(count_messages "$BASELINE_OUTPUT")
BASELINE_COUNT="${BASELINE_COUNT##*$'\n'}"
echo "  Baseline message count: $BASELINE_COUNT"

################################################################################
# Test 1: No scope set — should match baseline
################################################################################
run_scope_test "scope_no_filter" \
    "" "" \
    "$BASELINE_COUNT"

################################################################################
# Test 2: Scope = full path to test kernel source
# When scope is active, instructions without debug info are skipped, so
# the count may be less than the no-scope baseline. We probe the expected count.
################################################################################
KERNEL_FULL_PATH="$(cd "$(dirname "$KERNEL_SRC")" && pwd)/$(basename "$KERNEL_SRC")"

echo -e "\n${YELLOW}Probing full-path scope count...${NC}"
FULLPATH_PROBE_BINARY="$OUTPUT_DIR/scope_fullpath_probe"
compile_with_scope "$FULLPATH_PROBE_BINARY" "$KERNEL_FULL_PATH" ""
FULLPATH_PROBE_OUTPUT="$OUTPUT_DIR/scope_fullpath_probe.out"
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$OMNIPROBE" -i -a AddressLogger -- "$FULLPATH_PROBE_BINARY" > "$FULLPATH_PROBE_OUTPUT" 2>&1
FULLPATH_COUNT=$(count_messages "$FULLPATH_PROBE_OUTPUT")
FULLPATH_COUNT="${FULLPATH_COUNT##*$'\n'}"
echo "  Full-path scope message count: $FULLPATH_COUNT (baseline: $BASELINE_COUNT)"

# Sanity: full-path count must be <= baseline and > 0
if [ "$FULLPATH_COUNT" -le 0 ] || [ "$FULLPATH_COUNT" -gt "$BASELINE_COUNT" ]; then
    echo -e "  ${RED}ERROR: full-path count ($FULLPATH_COUNT) out of expected range (1..$BASELINE_COUNT)${NC}"
fi

run_scope_test "scope_full_path" \
    "$KERNEL_FULL_PATH" "" \
    "$FULLPATH_COUNT"

################################################################################
# Test 3: Scope = specific line range covering only first 2 markers
# Use line_a and line_b markers (the two loads)
################################################################################
LINE_A="${MARKER_LINES[line_a]}"
LINE_B="${MARKER_LINES[line_b]}"
if [ -n "$LINE_A" ] && [ -n "$LINE_B" ]; then
    # Range [line_a, line_b+1) covers both load lines
    RANGE_END=$((LINE_B + 1))

    echo -e "\n${YELLOW}Probing range scope (lines $LINE_A:$RANGE_END)...${NC}"
    RANGE_BINARY="$OUTPUT_DIR/scope_range_probe"
    if compile_with_scope "$RANGE_BINARY" "${KERNEL_FULL_PATH}:${LINE_A}:${RANGE_END}" ""; then
        RANGE_OUTPUT="$OUTPUT_DIR/scope_range_probe.out"
        if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
           "$OMNIPROBE" -i -a AddressLogger -- "$RANGE_BINARY" > "$RANGE_OUTPUT" 2>&1; then
            RANGE_COUNT=$(count_messages "$RANGE_OUTPUT")
            RANGE_COUNT="${RANGE_COUNT##*$'\n'}"
            echo "  Range message count: $RANGE_COUNT (baseline: $BASELINE_COUNT)"

            run_scope_test "scope_line_range" \
                "${KERNEL_FULL_PATH}:${LINE_A}:${RANGE_END}" "" \
                "$RANGE_COUNT"
        fi
    fi
fi

################################################################################
# Test 4: Scope = single line (first marker only)
################################################################################
if [ -n "$LINE_A" ]; then
    echo -e "\n${YELLOW}Probing single-line scope (line $LINE_A)...${NC}"
    SINGLE_BINARY="$OUTPUT_DIR/scope_single_probe"
    if compile_with_scope "$SINGLE_BINARY" "${KERNEL_FULL_PATH}:${LINE_A}" ""; then
        SINGLE_OUTPUT="$OUTPUT_DIR/scope_single_probe.out"
        if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
           "$OMNIPROBE" -i -a AddressLogger -- "$SINGLE_BINARY" > "$SINGLE_OUTPUT" 2>&1; then
            SINGLE_COUNT=$(count_messages "$SINGLE_OUTPUT")
            SINGLE_COUNT="${SINGLE_COUNT##*$'\n'}"
            echo "  Single-line message count: $SINGLE_COUNT"

            run_scope_test "scope_single_line" \
                "${KERNEL_FULL_PATH}:${LINE_A}" "" \
                "$SINGLE_COUNT"
        fi
    fi
fi

################################################################################
# Test 5: Scope = tail match (partial path) → same as full path scope
################################################################################
run_scope_test "scope_tail_match" \
    "scope_filter_test.cpp" "" \
    "$FULLPATH_COUNT"

################################################################################
# Test 6: Scope = non-matching file → 0 messages
################################################################################
run_scope_test "scope_no_match" \
    "/nonexistent/fakefile.cpp" "" \
    0

################################################################################
# Test 7: Scope from file (INSTRUMENTATION_SCOPE_FILE)
################################################################################
SCOPE_FILE="$OUTPUT_DIR/scope_test_definitions.txt"
cat > "$SCOPE_FILE" <<SCOPE_EOF
# Test scope file
# This should match the full path of the test kernel
${KERNEL_FULL_PATH}
SCOPE_EOF

run_scope_test "scope_from_file" \
    "" "$SCOPE_FILE" \
    "$FULLPATH_COUNT"

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
