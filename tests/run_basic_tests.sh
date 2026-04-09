#!/bin/bash
################################################################################
# Basic handler tests for omniprobe
# Tests basic functionality of Heatmap and MemoryAnalysis handlers
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

echo "================================================================================"
echo "Basic Handler Tests"
echo "================================================================================"
echo "Omniprobe: $OMNIPROBE"
echo "Test kernels: $TEST_KERNELS_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "GPU: ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

# Use project's instrumented test kernels
HEATMAP_TEST="${BUILD_DIR}/tests/test_kernels/simple_heatmap_test"
MEMORY_ANALYSIS_TEST="${BUILD_DIR}/tests/test_kernels/simple_memory_analysis_test"
BANK_CONFLICT_TEST="${BUILD_DIR}/tests/test_kernels/bank_conflict_test"

check_kernel "$HEATMAP_TEST"
check_kernel "$MEMORY_ANALYSIS_TEST"
check_kernel "$BANK_CONFLICT_TEST"

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

# Test 4: Verify bank conflict handler reports execution count and conflict count
# The handler prints "executed N times, M bank conflicts in total" only when M > 0,
# confirming both that the handler processed data and that conflicts were quantified.
run_test "bank_conflict_quantified" \
    "$BANK_CONFLICT_TEST" \
    "MemoryAnalysis" \
    "executed .* times, .* bank conflicts in total"

# Test 5: Bank conflict detection - the unpadded transpose must trigger bank conflicts
# The handler prints "N bank conflicts in total" only when N > 0.
run_test "bank_conflict_detected" \
    "$BANK_CONFLICT_TEST" \
    "MemoryAnalysis" \
    "bank conflicts in total"

# Test 6: Bank conflict report header
run_test "bank_conflict_report_header" \
    "$BANK_CONFLICT_TEST" \
    "MemoryAnalysis" \
    "Bank conflicts report"

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
