#!/bin/bash
################################################################################
# Dynamic LDS preservation tests for omniprobe instrumentation.
#
# Verifies that instrumented dispatches preserve the dynamic shared memory
# portion of group_segment_size requested at launch (extern __shared__ with
# dynamicSharedMemoryBytes). Without the corresponding fix in
# interceptor.cc::fixupPacket the instrumented dispatch only allocates the
# instrumented clone's fixed LDS, the kernel reads past its allocated LDS,
# and the output mismatches.
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

DYNAMIC_LDS_TEST="${BUILD_DIR}/tests/test_kernels/dynamic_lds_test"

if [ ! -x "$DYNAMIC_LDS_TEST" ]; then
    echo -e "\n${YELLOW}SKIP: Dynamic LDS tests (dynamic_lds_test not built)${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "================================================================================"
echo "Dynamic LDS Preservation Tests"
echo "================================================================================"
echo "  Test binary: $DYNAMIC_LDS_TEST"
echo "================================================================================"

################################################################################
# Test: Native run (no instrumentation) produces correct output.
#
# Sanity check that the test kernel itself is correct and that the dynamic
# LDS request is honoured by the runtime under normal dispatch.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="dynamic_lds_native"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run native (no instrumentation): kernel uses extern __shared__ with"
echo "  dynamicSharedMemoryBytes set at launch"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$DYNAMIC_LDS_TEST" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true

if grep -q "dynamic_lds_test: PASS" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Native execution correct"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Native execution incorrect (test kernel itself is broken)"
    tail -20 "$OUTPUT_FILE"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: Instrumented run preserves dynamic LDS.
#
# Without the fixupPacket fix, the instrumented dispatch overwrites
# group_segment_size with the instrumented kernel's fixed-LDS value, dropping
# the dynamic portion requested at launch. The kernel then reads/writes past
# its allocated LDS region, producing incorrect output.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="dynamic_lds_instrumented"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe -i: instrumented dispatch must preserve dynamic LDS"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$OMNIPROBE" -i -a Heatmap -- "$DYNAMIC_LDS_TEST" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true

if grep -q "dynamic_lds_test: PASS" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Instrumented execution correct (dynamic LDS preserved)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Instrumented execution incorrect (dynamic LDS dropped?)"
    tail -20 "$OUTPUT_FILE"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
