#!/bin/bash
################################################################################
# Omniprobe leaves no extracted code objects behind in /tmp.
#
# Regression test for bf_temp-code-object-leak. coCache::addFile extracts the
# code objects of every indexed binary with kernelDB's extractCodeObjects(),
# which writes each to a tmpnam() file (/tmp/fileXXXXXX), and never removed
# them: one file per instrumented binary per run, the size of its code objects.
# Full test-suite runs with instrumented rocBLAS left ~3,350 files of ~97 MB and
# filled a node's /tmp (2026-11-09).
#
# tmpnam() ignores TMPDIR, so the files are found in /tmp, and told apart from
# other processes' by their content: the debug info names temp_co_test.cpp.
# Expected: none left after a run, in instrumented and in timing mode.
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/temp_co_test"
check_kernel "$BIN"
OUT="$OUTPUT_DIR/temp_code_objects"
mkdir -p "$OUT"

echo "================================================================================"
echo "Temporary code objects"
echo "================================================================================"

# This test's code objects among /tmp's tmpnam() files.
ours() {
    find /tmp -maxdepth 1 -name 'file??????' -type f -user "$(id -u)" 2>/dev/null |
        xargs -r grep -l -a 'temp_co_test\.cpp' 2>/dev/null | sort
}

run_case() {   # run_case <name> <omniprobe args...>
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local before
    before="$(ours)"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 120 "$OMNIPROBE" "$@" -- "$BIN" > "$OUT/$name.log" 2>&1
    local status=$?
    local left
    left="$(comm -13 <(echo "$before") <(ours) | sed '/^$/d')"
    if [ "$status" -eq 0 ] && [ -z "$left" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - exit 0, no extracted code object left in /tmp"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - exit $status, left in /tmp: $(echo "$left" | sed '/^$/d' | wc -l) file(s); see $OUT/$name.log"
        echo "$left" | sed '/^$/d; s/^/    /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_case instrumented -i -a MemoryAnalysis
run_case timing

print_summary
