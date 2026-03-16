#!/bin/bash
################################################################################
# End-to-end test script for omniprobe handlers
# Orchestrates feature-specific test scripts
################################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities to get color definitions
source "${SCRIPT_DIR}/test_common.sh"

echo "================================================================================"
echo "Omniprobe Handler End-to-End Tests"
echo "================================================================================"
echo "Omniprobe: $OMNIPROBE"
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "GPU: ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

# Initialize counters
export TESTS_RUN=0
export TESTS_PASSED=0
export TESTS_FAILED=0

# Run feature-specific test scripts
# Each script sources test_common.sh and uses/exports the counters

# Basic handler tests (Heatmap, MemoryAnalysis)
source "${SCRIPT_DIR}/run_basic_tests.sh"

# Block index filter tests (--filter-x/y/z)
source "${SCRIPT_DIR}/run_block_filter_tests.sh"

# Library filter tests (--library-filter)
source "${SCRIPT_DIR}/run_library_filter_tests.sh"

# Scope filter tests (INSTRUMENTATION_SCOPE)
source "${SCRIPT_DIR}/run_scope_filter_tests.sh"

# Print summary
print_summary
