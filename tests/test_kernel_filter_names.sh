#!/bin/bash
################################################################################
# -k is an ECMAScript regex SEARCHED in the demangled kernel name, for every
# kind of kernel name, and "nothing matched -k" is reported as such.
#
# Regression test for bf_kernel-filter-search (2026-11-08 report from PENNANT
# runs: "-k gpuMain stopped matching gpuMain2, gpuMain3_interior"; not
# reproduced at 13ca707 or later, where 'gpuMain' and '.*gpuMain.*' select the
# same 40 dispatches — this test pins the semantics so they cannot drift).
#
# kernel_filter_names_test dispatches five kernels once each: filterAlpha(int*),
# void filterTemplate<4>(int*), static filterStatic (an .intern clone under
# -fgpu-rdc), filterNoParams(), (anonymous namespace)::filterAnon(int*).
# For each filter, the kernels that must run instrumented are listed; every
# other kernel must be reported as excluded. Note '^filterTemplate' matches
# nothing: a template's demangled name starts with its return type ("void ").
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/kernel_filter_names_test"
check_kernel "$BIN"
OUT="$OUTPUT_DIR/kernel_filter_names"
mkdir -p "$OUT"
ALL="filterAlpha filterTemplate filterStatic filterNoParams filterAnon"

echo "================================================================================"
echo "Kernel filter (-k): regex search in the demangled name"
echo "================================================================================"

n=0
case_() {   # case_ <filter> <kernels that must run instrumented...>
    local filter="$1"; shift
    local want=" $* "
    n=$((n + 1))
    local log="$OUT/case_$n.log"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 120 "$OMNIPROBE" -i -a MemoryAnalysis -k "$filter" -- "$BIN" > "$log" 2>&1
    local status=$? bad=""
    for k in $ALL; do
        local excluded=no
        grep -q "^Kernel filter excluded [^;]*\b$k\b" "$log" && excluded=yes
        if [[ "$want" == *" $k "* ]]; then
            [ "$excluded" = yes ] && bad="$bad $k:excluded"
            grep -q "Found instrumented alternative for [^;]*\b$k\b" "$log" || bad="$bad $k:no-clone"
        else
            [ "$excluded" = no ] && bad="$bad $k:not-excluded"
        fi
    done
    local warned=no
    grep -q "no dispatched kernel matched the kernel filter" "$log" && warned=yes
    local want_warn=no
    [ $# -eq 0 ] && want_warn=yes
    [ "$warned" != "$want_warn" ] && bad="$bad no-match-warning:$warned"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} -k '$filter'"
    if [ "$status" -eq 0 ] && [ -z "$bad" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - instrumented: ${*:-none}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - exit $status;$bad; see $log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

case_ "filter"                     filterAlpha filterTemplate filterStatic filterNoParams filterAnon
case_ "Static"                     filterStatic
case_ "NoParams"                   filterNoParams
case_ "Anon"                       filterAnon
case_ "Templ"                      filterTemplate
case_ "^filterAlpha"               filterAlpha
case_ "^void filterTemplate"       filterTemplate
case_ "filterAlpha|filterNoParams" filterAlpha filterNoParams
case_ "^filterTemplate"
case_ "nomatch_xyz"

print_summary
