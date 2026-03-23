#!/bin/bash
################################################################################
# Module-load kernel discovery tests for omniprobe
#
# Tests that omniprobe can discover instrumented kernels in .hsaco files loaded
# at runtime via hipModuleLoad.  The test kernel (module_load_kernel.hip) is
# compiled to a standalone .hsaco with the AddressMessages instrumentation
# plugin, and the host program (module_load_test) loads it at runtime.
#
# Current expected behavior (before kernel-discovery unification):
#   - Without --library-filter: instrumented alternative NOT found
#   - With    --library-filter: instrumented alternative found
#
# After the rf_unify-kernel-discovery refactor the first case should also
# find the instrumented alternative.
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

################################################################################
# Locate build artifacts
################################################################################

MODULE_LOAD_TEST="${BUILD_DIR}/tests/test_kernels/module_load_test"
MODULE_LOAD_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel.hsaco"

if [ ! -x "$MODULE_LOAD_TEST" ] || [ ! -f "$MODULE_LOAD_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Module-load test artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_TEST"
    echo "  Expected: $MODULE_LOAD_HSACO"
    echo "  Build with: cmake --build build --target module_load_test module_load_kernel_hsaco"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "================================================================================"
echo "Module-Load Kernel Discovery Tests"
echo "================================================================================"
echo "  Host binary: $MODULE_LOAD_TEST"
echo "  Code object: $MODULE_LOAD_HSACO"
echo "================================================================================"

################################################################################
# Test: .hsaco contains both original and instrumented kernel symbols
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_hsaco_symbols"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify .hsaco contains original and __amd_crk_ instrumented kernel"

# Use nm to check for both symbols (the .hsaco is a raw ELF, not an offload bundle)
if nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -q "T module_load_kernel$" && \
   nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -q "T __amd_crk_module_load_kernel"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Both original and instrumented kernel symbols present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Expected both module_load_kernel and __amd_crk_module_load_kernel*"
    nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -E "module_load_kernel|__amd_crk" || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: omniprobe finds instrumented alternative without --library-filter
#
# This tests the core kernel discovery unification.  Before the refactor this
# test is expected to FAIL (omniprobe will print "No instrumented alternative
# found").  After rf_unify-kernel-discovery it should PASS.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_discovery_auto"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe -i (no --library-filter) — expect instrumented alternative found"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    "$OMNIPROBE" -i -a Heatmap \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true  # Don't fail on non-zero exit

if grep -q "Found instrumented alternative for module_load_kernel" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Instrumented alternative auto-discovered"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Instrumented alternative NOT auto-discovered"
    echo "  (This is expected before rf_unify-kernel-discovery refactor)"
    grep -E "instrumented alternative|module_load_kernel" "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: omniprobe finds instrumented alternative WITH --library-filter
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_discovery_filter"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe -i with --library-filter pointing to .hsaco"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
FILTER_FILE="$OUTPUT_DIR/${TEST_NAME}_filter.json"

# Write a filter that includes the .hsaco
cat > "$FILTER_FILE" <<EOF
{
  "include": ["$MODULE_LOAD_HSACO"]
}
EOF

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    "$OMNIPROBE" -i -a Heatmap \
    --library-filter "$FILTER_FILE" \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true

if grep -q "Found instrumented alternative for module_load_kernel" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Instrumented alternative found via --library-filter"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Instrumented alternative NOT found even with --library-filter"
    grep -E "instrumented alternative|module_load_kernel" "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
