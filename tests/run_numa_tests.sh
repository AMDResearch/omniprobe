#!/bin/bash
################################################################################
# NUMA memory manager tests for omniprobe.
#
# Verifies the env-var-gated NUMA memory manager (OMNIPROBE_NUMA_NODE):
#   numa_default      - env unset, default behavior unchanged (no NUMA logs)
#   numa_node_0       - env=0, manager invoked; on multi-node systems,
#                       move_pages self-verification confirms placement
#   numa_invalid_node - env=999, invalid-node guard raises an error
#
# Reuses simple_heatmap_test as the workload because it is the smallest
# instrumented kernel that exercises dh_comms shared-buffer allocation.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

################################################################################
# Locate test binary
################################################################################

HEATMAP_TEST="${BUILD_DIR}/tests/test_kernels/simple_heatmap_test"

if [ ! -x "$HEATMAP_TEST" ]; then
    echo -e "${YELLOW}SKIP: NUMA tests require simple_heatmap_test (${HEATMAP_TEST})${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

################################################################################
# Topology detection
#
# numa_default and numa_invalid_node only need libnuma loadable at runtime
# (the library handles single-node systems gracefully).  numa_node_0 only
# needs node 0 to exist, which is true on every NUMA-capable system.  The
# placement assertion in numa_node_0 is skipped on single-node systems
# because move_pages will always return node 0 there, making the test
# tautological rather than a real check.
################################################################################

if command -v numactl >/dev/null 2>&1; then
    NUMA_NODES=$(numactl --hardware | awk '/^available:/ {print $2}')
else
    NUMA_NODES=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
fi

if ! ldconfig -p 2>/dev/null | grep -q 'libnuma\.so'; then
    echo -e "${YELLOW}SKIP: libnuma not found on this system${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ -z "$NUMA_NODES" ] || [ "$NUMA_NODES" -lt 1 ]; then
    echo -e "${YELLOW}SKIP: No NUMA nodes detected${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "================================================================================"
echo "NUMA Memory Manager Tests"
echo "================================================================================"
echo "  Test kernel : $HEATMAP_TEST"
echo "  NUMA nodes  : $NUMA_NODES"
echo "================================================================================"

################################################################################
# Test: numa_default - default behavior unchanged (env var unset)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="numa_default"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run without OMNIPROBE_NUMA_NODE - expect default mem manager (no NUMA logs)"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   env -u OMNIPROBE_NUMA_NODE \
   "$OMNIPROBE" -i -a Heatmap -- "$HEATMAP_TEST" > "$OUTPUT_FILE" 2>&1; then
    if ! grep -q '^numa_mem_mgr:' "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}PASS${NC} - Default path used, no numa_mem_mgr output"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} - numa_mem_mgr output present with env unset"
        grep '^numa_mem_mgr:' "$OUTPUT_FILE" | head -3 || true
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}FAIL${NC} - Kernel execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: numa_node_0 - manager invoked, placement verified where possible
#
# OMNIPROBE_NUMA_VERBOSE=1 is required for the per-allocation "allocated ...
# on node X (requested 0)" lines that the placement assertion grep'es for.
# Without it the manager runs but emits only the one-shot "targeting NUMA
# node 0" line from the constructor.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="numa_node_0"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  OMNIPROBE_NUMA_NODE=0 - expect manager invoked + placement on node 0"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   OMNIPROBE_NUMA_NODE=0 \
   OMNIPROBE_NUMA_VERBOSE=1 \
   "$OMNIPROBE" -i -a Heatmap -- "$HEATMAP_TEST" > "$OUTPUT_FILE" 2>&1; then

    invocation_ok=false
    placement_ok=true

    if grep -q "numa_mem_mgr: targeting NUMA node 0" "$OUTPUT_FILE"; then
        invocation_ok=true
    fi

    if [ "$NUMA_NODES" -gt 1 ]; then
        # Multi-node: every allocated... line must report node 0
        alloc_lines=$(grep -c "numa_mem_mgr: allocated " "$OUTPUT_FILE" || true)
        if [ "$alloc_lines" -eq 0 ]; then
            placement_ok=false
            placement_reason="no 'allocated' lines emitted (move_pages may have failed)"
        else
            mismatches=$(grep "numa_mem_mgr: allocated " "$OUTPUT_FILE" |
                         grep -vE 'on node 0 \(requested 0\)' |
                         wc -l)
            if [ "$mismatches" -ne 0 ]; then
                placement_ok=false
                placement_reason="$mismatches allocation(s) landed off node 0"
            fi
        fi
    else
        echo "  [INFO] single-node system: skipping placement assertion"
    fi

    if [ "$invocation_ok" = true ] && [ "$placement_ok" = true ]; then
        if [ "$NUMA_NODES" -gt 1 ]; then
            echo -e "  ${GREEN}PASS${NC} - Manager invoked and placement verified on node 0"
        else
            echo -e "  ${GREEN}PASS${NC} - Manager invoked (placement assertion skipped: single-node)"
        fi
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        if [ "$invocation_ok" != true ]; then
            echo -e "  ${RED}FAIL${NC} - 'targeting NUMA node 0' not in output"
        fi
        if [ "$placement_ok" != true ]; then
            echo -e "  ${RED}FAIL${NC} - placement check: ${placement_reason}"
            grep "numa_mem_mgr:" "$OUTPUT_FILE" | head -10 || true
        fi
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}FAIL${NC} - Kernel execution failed with OMNIPROBE_NUMA_NODE=0"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: numa_invalid_node - constructor rejects out-of-range node, comms_mgr
# catches and aborts.
#
# Contract is verified via two stderr messages (both must be present):
#   1. "numa_mem_mgr: invalid NUMA node 999" - constructor validation fires
#   2. "failed to create numa_mem_mgr ... aborting" - comms_mgr try/catch
#      reached std::abort()
#
# Process exit code is informational, not asserted: the omniprobe Python
# wrapper (omniprobe/omniprobe::capture_subprocess_output) currently does
# not propagate child exit codes, so SIGABRT from the child surfaces as
# exit 0 to the harness.  Tracked as a separate follow-up; when that fix
# lands this test will start observing exit != 0 automatically.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="numa_invalid_node"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  OMNIPROBE_NUMA_NODE=999 - expect constructor rejection + abort diagnostic in stderr"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

run_exit=0
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" OMNIPROBE_NUMA_NODE=999 \
    "$OMNIPROBE" -i -a Heatmap -- "$HEATMAP_TEST" > "$OUTPUT_FILE" 2>&1 || run_exit=$?

ctor_ok=false
abort_ok=false
grep -q "numa_mem_mgr: invalid NUMA node" "$OUTPUT_FILE" && ctor_ok=true
grep -q "failed to create numa_mem_mgr.*aborting" "$OUTPUT_FILE" && abort_ok=true

if [ "$ctor_ok" = true ] && [ "$abort_ok" = true ]; then
    if [ "$run_exit" -ne 0 ]; then
        echo -e "  ${GREEN}PASS${NC} - Invalid node rejected and process aborted (exit=$run_exit)"
    else
        echo -e "  ${YELLOW}[WARN]${NC} omniprobe wrapper masked the abort exit code (known issue)"
        echo -e "  ${GREEN}PASS${NC} - Invalid node rejected: both diagnostic messages present in stderr"
    fi
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC} - Expected diagnostic messages not all present:"
    if [ "$ctor_ok" = true ]; then
        echo "    constructor 'invalid NUMA node': found"
    else
        echo "    constructor 'invalid NUMA node': MISSING"
    fi
    if [ "$abort_ok" = true ]; then
        echo "    'failed to create ... aborting': found"
    else
        echo "    'failed to create ... aborting': MISSING"
    fi
    echo "  exit=$run_exit"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

export TESTS_RUN TESTS_PASSED TESTS_FAILED
