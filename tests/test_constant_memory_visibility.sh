#!/bin/bash
################################################################################
# __constant__ visibility inside an instrumented clone.
#
# Regression test for bf_hip-duplicate-code-object-load: Omniprobe used to build a
# second, private HSA executable from code the application had already loaded. That
# copy got its own __constant__ segment, which nothing initialised, so clones
# dispatched out of it read every __device__/__constant__ global as zero while their
# kernel arguments arrived intact. The run completed and produced empty-but-plausible
# analysis output — it failed silently, which is what made it worth a packet.
#
#   --no-filter              AC-2: correct __constant__ with no -k argument
#   --with-matching-filter   AC-3: correct __constant__ when -k matches the kernel
#
# AC-3 has its own mode because -k used to decide which *copy* a clone came from
# rather than whether one was used: a kernel that matched the filter was served from
# the broken private copy, and a kernel that did not match was served, still
# instrumented, from the application's own. Matching the filter was what broke it.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"
source "${SCRIPT_DIR}/test_instrumented_kernel_common.sh"

MODE="${1:---no-filter}"
case "$MODE" in
    --no-filter|--with-matching-filter) ;;
    *) echo "usage: $0 [--no-filter|--with-matching-filter]"; exit 2 ;;
esac

check_omniprobe

SCRATCH="$(instrumented_scratch_dir)" || { echo -e "${RED}ERROR: cannot create scratch dir${NC}"; exit 1; }
BINARY="${SCRATCH}/constant_memory_test"
SRC="${TEST_KERNELS_DIR}/constant_memory_test.hip"

echo "================================================================================"
echo "__constant__ visibility under instrumentation  (${MODE})"
echo "================================================================================"
echo "Omniprobe:  $OMNIPROBE"
echo "Kernel:     $SRC"
echo "Binary:     $BINARY"
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

OUT="${SCRATCH}/constant_memory_${MODE#--}.out"
if [ "$MODE" = "--with-matching-filter" ]; then
    # probe_g is the kernel in constant_memory_test.hip; this regex matches it.
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -k "probe_g" -- "$BINARY" > "$OUT" 2>&1
else
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -- "$BINARY" > "$OUT" 2>&1
fi
run_rc=$?

failures=0

# The kernel must actually have been swapped for its clone. Without this the test is
# vacuous: an uninstrumented run reads __constant__ correctly by construction, so
# "__constant__ OK" alone would pass against a build that had silently stopped
# instrumenting anything at all.
if grep -q "Found instrumented alternative for probe_g" "$OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - instrumented clone was dispatched"
else
    echo -e "  ${RED}✗ FAIL${NC} - no instrumented clone was dispatched; the check below would be vacuous"
    failures=$((failures + 1))
fi

if grep -q "ARGPROBE_G kernargs OK, __constant__ OK" "$OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - __constant__ globals visible inside the clone"
elif grep -q "__constant__ CORRUPT" "$OUT"; then
    echo -e "  ${RED}✗ FAIL${NC} - __constant__ read as zero inside the clone (the original defect)"
    grep "ARGPROBE_G" "$OUT" | sed 's/^/      /'
    failures=$((failures + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - reproducer produced no verdict (exit ${run_rc}); see $OUT"
    failures=$((failures + 1))
fi

echo "================================================================================"
if [ $failures -eq 0 ]; then
    echo -e "${GREEN}__constant__ visibility: PASS (${MODE})${NC}"
    exit 0
fi
echo -e "${RED}__constant__ visibility: FAIL (${MODE}) — output at $OUT${NC}"
exit 1
