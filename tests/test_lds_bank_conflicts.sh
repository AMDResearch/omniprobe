#!/bin/bash
################################################################################
# LDS bank conflicts: omniprobe against the hardware counter.
#
# Runs tests/test_kernels/lds_bank_patterns.cpp twice: uninstrumented under
# rocprofv3 for SQ_LDS_BANK_CONFLICT, and instrumented under omniprobe
# (MemoryAnalysis, JSON). tests/lds_bank_check.py requires the two to be equal
# for every pattern kernel and prints which LDS geometry (32 or 64 banks,
# 32- or 64-lane phases) the hardware matches. Needs a GPU and rocprofv3.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

ROCPROF="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/rocprofv3"
[ -x "$ROCPROF" ] || ROCPROF="$(command -v rocprofv3)"
PLAIN="$BUILD_DIR/tests/test_kernels/lds_bank_patterns_plain"
INSTR="$BUILD_DIR/tests/test_kernels/lds_bank_patterns_test"
WORK="$OUTPUT_DIR/lds_bank_conflicts"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "================================================================================"
echo "LDS bank conflicts vs SQ_LDS_BANK_CONFLICT"
echo "================================================================================"
echo "GPU:      $(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
echo "rocprof:  $ROCPROF"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} omniprobe_bank_conflicts_equal_hardware_counter"
if [ ! -x "$ROCPROF" ] || [ ! -x "$PLAIN" ] || [ ! -x "$INSTR" ]; then
    echo -e "  ${RED}✗ FAIL${NC} - missing rocprofv3 or pattern binaries ($ROCPROF, $PLAIN, $INSTR)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print_summary; exit $?
fi
# From $WORK: rocprofv3 leaves a .rocprofv3/ directory in its working directory.
(cd "$WORK" && "$ROCPROF" --pmc SQ_LDS_BANK_CONFLICT SQ_WAVES -d "$WORK/prof" -o run \
    --output-format csv -- "$PLAIN" > "$WORK/rocprof.log" 2>&1)
rc_hw=$?
"$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$WORK/omniprobe.json" -- "$INSTR" > "$WORK/omniprobe.log" 2>&1
rc_om=$?
csv="$(find "$WORK/prof" -name '*counter_collection.csv' 2>/dev/null | head -1)"
if [ "$rc_hw" -ne 0 ] || [ "$rc_om" -ne 0 ] || [ -z "$csv" ]; then
    echo -e "  ${RED}✗ FAIL${NC} - rocprofv3 rc $rc_hw, omniprobe rc $rc_om, counter csv '${csv}'"
    echo "  Output saved to: $WORK"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif python3 -I "$SCRIPT_DIR/lds_bank_check.py" "$csv" "$WORK/omniprobe.json" > "$WORK/check.txt" 2>&1; then
    sed 's/^/    /' "$WORK/check.txt"
    echo -e "  ${GREEN}✓ PASS${NC} - omniprobe equals SQ_LDS_BANK_CONFLICT for all $(grep -c "^read_\|^write_\|^atomic_" "$WORK/check.txt") pattern kernels"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    sed 's/^/    /' "$WORK/check.txt"
    echo -e "  ${RED}✗ FAIL${NC} - see table above"
    echo "  Output saved to: $WORK"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
