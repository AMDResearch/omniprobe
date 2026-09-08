#!/bin/bash
################################################################################
# -k kernel-filter semantics, and DWARF survival under a filter.
#
#   (no argument)    AC-7: -k restricts WHICH KERNELS run instrumented. A kernel
#                    matching the regex runs its clone; one that does not match runs
#                    its original.
#   --assert-dwarf   AC-8: a filtered run still gets source-line attribution for the
#                    kernel it does instrument, so no sacrificial kernel is needed.
#
# Both use a two-kernel program so the claim is asserted per kernel within a single
# run rather than inferred by comparing message volume between runs.
#
# Before bf_hip-duplicate-code-object-load, -k did neither of these. It gated which
# kernels coCache::addFile recorded, so it selected the *copy* a clone was taken from
# while every kernel was swapped either way; and because it also gated
# kernel_co_map_, a filtered run lost DWARF correlation unless some dispatched kernel
# was sacrificed to the filter purely to prime the kernel database.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"
source "${SCRIPT_DIR}/test_instrumented_kernel_common.sh"

ASSERT_DWARF=0
if [ "${1:-}" = "--assert-dwarf" ]; then
    ASSERT_DWARF=1
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--assert-dwarf]"; exit 2
fi

check_omniprobe

SCRATCH="$(instrumented_scratch_dir)" || { echo -e "${RED}ERROR: cannot create scratch dir${NC}"; exit 1; }
BINARY="${SCRATCH}/filter_semantics_test"
SRC="${TEST_KERNELS_DIR}/filter_semantics_test.hip"

echo "================================================================================"
echo "Kernel filter semantics$([ $ASSERT_DWARF -eq 1 ] && echo '  (--assert-dwarf)')"
echo "================================================================================"
echo "Omniprobe:  $OMNIPROBE"
echo "Kernel:     $SRC"
echo "================================================================================"

compile_msg="$(compile_instrumented_kernel "$SRC" "$BINARY")"
compile_rc=$?
if [ $compile_rc -eq 1 ]; then
    echo -e "${YELLOW}SKIP: ${compile_msg}${NC}"
    exit 0
elif [ $compile_rc -ne 0 ]; then
    echo -e "${RED}✗ FAIL${NC} - ${compile_msg}"
    exit 1
fi

# Filter matches kernel_strided and not kernel_linear.
OUT="${SCRATCH}/filter_semantics.out"
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$OMNIPROBE" -i -k "kernel_strided" -a MemoryAnalysis -- "$BINARY" > "$OUT" 2>&1
run_rc=$?

failures=0

if ! grep -q "FILTER_SEMANTICS: both kernels dispatched" "$OUT"; then
    echo -e "  ${RED}✗ FAIL${NC} - the program did not run to completion (exit ${run_rc}); see $OUT"
    exit 1
fi

if [ $ASSERT_DWARF -eq 0 ]; then
    # AC-7. Both halves are needed: that the matching kernel was instrumented, and
    # that the non-matching one was not. Either alone is satisfied by a build that
    # instruments everything or nothing.
    if grep -q "Found instrumented alternative for kernel_strided" "$OUT"; then
        echo -e "  ${GREEN}✓ PASS${NC} - matching kernel (kernel_strided) ran its instrumented clone"
    else
        echo -e "  ${RED}✗ FAIL${NC} - matching kernel was not instrumented"
        failures=$((failures + 1))
    fi

    if grep -q "Kernel filter excluded kernel_linear" "$OUT"; then
        echo -e "  ${GREEN}✓ PASS${NC} - non-matching kernel (kernel_linear) ran its original"
    else
        echo -e "  ${RED}✗ FAIL${NC} - non-matching kernel was not left on its original; -k does not restrict dispatch"
        failures=$((failures + 1))
    fi

    if grep -q "Kernel filter excluded kernel_strided" "$OUT"; then
        echo -e "  ${RED}✗ FAIL${NC} - the matching kernel was excluded; the filter is inverted"
        failures=$((failures + 1))
    fi
else
    # AC-8, part 1: code-object coverage must not depend on the filter.
    #
    # This is the discriminating check, and the reason the source-line assertion below
    # is not sufficient on its own. Before the fix, kernel_co_map_ was populated behind
    # the -k regex, so only kernels matching the filter got a code-object reference —
    # which is what forced the sacrificial-kernel workaround. Filtering on
    # kernel_strided therefore left kernel_linear with no reference at all.
    #
    # Measured 2026-09-08: pre-fix this run emits ONE "kernel location:" line, post-fix
    # TWO. The source-line assertion below passes in both cases, because the kernel the
    # filter happens to match is the one being reported on — so it would have been
    # vacuous alone. Verified by building with the fix disabled and watching this check,
    # and only this one, fail.
    location_lines=$(grep -c "kernel location:" "$OUT" || true)
    if [ "$location_lines" -ge 2 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - every dispatched kernel has a code-object reference under a filter (${location_lines})"
    else
        echo -e "  ${RED}✗ FAIL${NC} - only ${location_lines} kernel(s) have a code-object reference; the filter still gates kernelDB coverage"
        failures=$((failures + 1))
    fi

    # AC-8, part 2: DWARF actually produced a source-line attribution. Anchored on the
    # source file name and a line:column, the shape MemoryAnalysis prints.
    if grep -qE "filter_semantics_test\.hip:[0-9]+:[0-9]+" "$OUT"; then
        echo -e "  ${GREEN}✓ PASS${NC} - filtered run has source-line attribution for the kernel it instrumented"
        grep -oE "filter_semantics_test\.hip:[0-9]+:[0-9]+" "$OUT" | head -3 | sed 's/^/      /'
    else
        echo -e "  ${RED}✗ FAIL${NC} - no source-line attribution in a filtered run; a sacrificial kernel is still needed"
        failures=$((failures + 1))
    fi
fi

echo "================================================================================"
if [ $failures -eq 0 ]; then
    echo -e "${GREEN}Kernel filter semantics: PASS${NC}"
    exit 0
fi
echo -e "${RED}Kernel filter semantics: FAIL — output at $OUT${NC}"
exit 1
