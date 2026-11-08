#!/bin/bash
################################################################################
# Run all omniprobe tests
#
# Usage: ./run_all_tests.sh
#
# Test suites:
#   1. Handler tests (basic, block filter, library filter)
#   2. Library filter chain tests (builds its own test libraries)
#   3. hipBLASLt instrumentation (requires INSTRUMENTED_HIPBLASLT_LIB_DIR)
#   4. rocBLAS integration (requires INSTRUMENTED_ROCBLAS_LIB_DIR)
#   5. rocBLAS + hipBLASLt combined (requires INSTRUMENTED_ROCBLAS_LIB_DIR + INSTRUMENTED_HIPBLASLT_LIB_DIR)
#   6. Triton integration (requires TRITON_DIR)
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
NC='\033[0m'

SUITES_RUN=0
SUITES_PASSED=0
SUITES_SKIPPED=0
SUITES_FAILED=0
FAILED_SUITES=""

run_suite() {
    local name="$1"
    local script="$2"
    shift 2

    SUITES_RUN=$((SUITES_RUN + 1))
    echo ""
    echo "################################################################################"
    echo -e "${YELLOW}Suite ${SUITES_RUN}: ${name}${NC}"
    echo "################################################################################"

    if [ ! -x "$script" ]; then
        echo -e "${RED}SKIP${NC}: $script not found or not executable"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES="${FAILED_SUITES}  - ${name} (script not found)\n"
        return 1
    fi

    local output exit_code
    output=$("$script" "$@" 2>&1) && exit_code=0 || exit_code=$?

    echo "$output"

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Suite FAILED: ${name}${NC}"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES="${FAILED_SUITES}  - ${name}\n"
    # Skipped only on a skip notice at the start of a line ("SKIP: <reason>",
    # colour codes stripped), the form the suites print when they cannot run.
    # A bare substring match counted any incidental "SKIP" in passing output
    # as a skipped suite, and missed lowercase "skipping" notices entirely.
    elif echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -qE '^[[:space:]]*SKIP:'; then
        echo -e "${YELLOW}Suite SKIPPED: ${name}${NC}"
        SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
    else
        echo -e "${GREEN}Suite PASSED: ${name}${NC}"
        SUITES_PASSED=$((SUITES_PASSED + 1))
    fi
}

echo "================================================================================"
echo "Omniprobe — All Tests"
echo "================================================================================"

# Suite 1: Handler tests (basic + block filter + library filter)
run_suite "Handler tests" "${SCRIPT_DIR}/run_handler_tests.sh"

# Suite 2: Library filter chain (has its own build step)
run_suite "Library filter chain" "${SCRIPT_DIR}/library_filter_chain/run_test.sh"

# Suite 3: hipBLASLt instrumentation (requires INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "hipBLASLt instrumentation" "${SCRIPT_DIR}/hipblaslt/run_test.sh"

# Suite 4: rocBLAS integration (requires INSTRUMENTED_ROCBLAS_LIB_DIR)
run_suite "rocBLAS integration" "${SCRIPT_DIR}/rocblas_filter/run_test.sh"

# Suite 5: rocBLAS + hipBLASLt combined (requires INSTRUMENTED_ROCBLAS_LIB_DIR + INSTRUMENTED_HIPBLASLT_LIB_DIR)
run_suite "rocBLAS + hipBLASLt combined" "${SCRIPT_DIR}/rocblas_hipblaslt/run_test.sh"

# Suite 6: Triton integration (requires TRITON_DIR)
run_suite "Triton integration" "${SCRIPT_DIR}/triton/run_test.sh"

# Suites 7-10: regression coverage for bf_hip-duplicate-code-object-load. Each mode is
# its own suite so that a mode silently ceasing to run is visible in the tally rather
# than hidden inside a script that also does something else. These compile their own
# kernels for the GPU actually present, so they do not depend on CMAKE_HIP_ARCHITECTURES
# matching the machine.
run_suite "Constant memory visibility (no filter)" "${SCRIPT_DIR}/test_constant_memory_visibility.sh" --no-filter
run_suite "Constant memory visibility (matching -k)" "${SCRIPT_DIR}/test_constant_memory_visibility.sh" --with-matching-filter
run_suite "Kernel filter semantics" "${SCRIPT_DIR}/test_kernel_filter_semantics.sh"
run_suite "Kernel filter DWARF survival" "${SCRIPT_DIR}/test_kernel_filter_semantics.sh" --assert-dwarf

# Suite 11: regression coverage for bf_exit-status-not-propagated. Needs no GPU —
# every target is a /bin/sh stub — so this one suite runs on any node.
run_suite "Exit status propagation" "${SCRIPT_DIR}/test_exit_status.sh"

# Suite 12: regression coverage for bf_json-output-integrity — every analyzer's
# -t json -o file parses (two kernels, -k excluding the first, a second run to
# the same file), and -o/-l files are replaced, not appended to. Needs a GPU.
run_suite "Output file integrity" "${SCRIPT_DIR}/test_json_output.sh"

# Suite 13: the build tree's plugins find their device bitcode (build/lib/bitcode
# holds every .bc dh_comms builds). Compiles only; needs no GPU.
run_suite "Build-tree device bitcode" "${SCRIPT_DIR}/test_build_tree_bitcode.sh"

# Suite 14: regression coverage for bf_bba-hardening — BasicBlockAnalysis on a
# binary it cannot interpret warns and exits 0 instead of crashing. Needs a GPU.
run_suite "BasicBlockAnalysis robustness" "${SCRIPT_DIR}/test_bba_robustness.sh"

# Suite 15: bf_bba-hardening phase 2 — BasicBlockAnalysis counts and source
# lines match the analytic answer for known control flow; identical runs give
# identical blocks. Needs a GPU.
run_suite "BasicBlockAnalysis counts" "${SCRIPT_DIR}/test_bba_counts.sh"

# Suite 16: regression coverage for bf_intern-clone-name — static and
# anonymous-namespace kernels under -fgpu-rdc, both .intern hash flavours, and
# the end-of-run summary of kernels without an instrumented clone. Needs a GPU.
run_suite "Internal-linkage kernels" "${SCRIPT_DIR}/test_intern_linkage.sh"

# Suite 17: ft_python-api-coverage — the Python API end to end on real
# instrumented binaries (heatmap, address and basic-block traces, extended
# memory fields, flat-access count, uninstrumented kernels). Needs a GPU.
run_suite "Python API end to end" "${SCRIPT_DIR}/test_python_api_e2e.sh"

# Suite 18: a two-file application built without -fgpu-rdc, as a Makefile
# would: source attribution with and without -g, and AddressLogger records from
# overlapping dispatches. Needs a GPU.
run_suite "Two-file application" "${SCRIPT_DIR}/test_two_file_app.sh"

# Suite 19: regression coverage for bf_pyhandler-gil — a user Python module
# (-a PythonHandler) receives every message of many and of concurrently
# delivering dispatches, with exact counts, in one interpreter. Needs a GPU.
run_suite "PythonHandler message handler" "${SCRIPT_DIR}/test_python_handler.sh"

# Suite 20: regression coverage for bf_faulted-dispatch-hang — a kernel that
# faults on the GPU ends the run with the application's status instead of
# hanging at exit. Needs a GPU.
run_suite "Faulted dispatch" "${SCRIPT_DIR}/test_faulted_dispatch.sh"

# Suite 21: ft_flat-address-classification — MemoryAnalysis analyzes flat-pointer
# accesses (-O0 builds, pointers loaded from memory): the same findings at -O0 as
# at -O2. Needs a GPU.
run_suite "Flat-pointer accesses" "${SCRIPT_DIR}/test_flat_access.sh"

# Suite 22: bf_bb-interval-dynamic-alloca — a BBInterval-instrumented loop runs
# to completion with real (non-zero) intervals, one per block executed. Needs a GPU.
run_suite "BBInterval loop" "${SCRIPT_DIR}/test_bb_interval.sh"

# Suite 23: bf_robustness-errors — configuration errors exit 1 with an error
# (no hang, no silent fallback), kernelDB failures never drop dispatches, and
# the exit summary arrives in one piece. Needs a GPU.
run_suite "Robustness" "${SCRIPT_DIR}/test_robustness.sh"

# Suite 24: bf_kernel-filter-search — -k is a regex searched in the demangled
# name for plain, template, static (.intern), no-parameter and anonymous-
# namespace kernels; "no kernel matched -k" is its own warning. Needs a GPU.
run_suite "Kernel filter names" "${SCRIPT_DIR}/test_kernel_filter_names.sh"

# Suite 25: rf_exact-arch-bitcode — the plugins link exact-arch dh_comms bitcode,
# fall back to the cdna2/cdna3 bucket with a warning when it is missing or when
# dh_comms does not identify the architecture, and read the architecture from a
# Triton module's triple. Compiles only; no GPU needed.
run_suite "Bitcode selection" "${SCRIPT_DIR}/test_bitcode_selection.sh"

# Suite 26: LDS bank conflicts — omniprobe's counts equal the SQ_LDS_BANK_CONFLICT
# hardware counter on pattern kernels that separate 32/64 banks, 32/64-lane
# phases, and 16-byte read/write phases. Needs a GPU and rocprofv3.
run_suite "LDS bank conflicts vs hardware" "${SCRIPT_DIR}/test_lds_bank_conflicts.sh"

# Suite 27: -d random — every eligible kernel is captured or named in the
# end-of-run warning; kernels excluded by -k are neither. Needs a GPU.
run_suite "Random dispatch capture" "${SCRIPT_DIR}/test_dispatch_random.sh"

# Summary
echo ""
echo "================================================================================"
echo "Overall Summary"
echo "================================================================================"
echo "Suites run:     $SUITES_RUN"
echo -e "${GREEN}Suites passed:  $SUITES_PASSED${NC}"
echo -e "${YELLOW}Suites skipped: $SUITES_SKIPPED${NC}"
echo -e "${RED}Suites failed:  $SUITES_FAILED${NC}"

if [ $SUITES_FAILED -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed suites:${NC}"
    echo -e "$FAILED_SUITES"
    echo "================================================================================"
    exit 1
else
    echo "================================================================================"
    echo -e "${GREEN}All suites passed!${NC}"
    exit 0
fi
