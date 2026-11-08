#!/bin/bash
################################################################################
# A GPU fault under omniprobe ends the run promptly with the application's own
# exit status, instead of hanging at exit.
#
# Regression test for bf_faulted-dispatch-hang. signal_runner waited for every
# dispatch's completion signal without ever checking for shutdown; a faulted
# dispatch's signal never completes, so the exit-time join blocked forever.
#
# fault_test stores to an unmapped address and exits 3 when synchronization
# reports the fault (0 with --no-fault). Expected under omniprobe, in timing
# and in instrumented mode: the bare application's exit status (3 where the
# runtime reports the fault) well within the timeout, and a warning that names
# fault_kernel when the process survives the fault. Without a fault: exit 0 and
# no such warning.
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/fault_test"
check_kernel "$BIN"
OUT="$OUTPUT_DIR/faulted_dispatch"
mkdir -p "$OUT"
LIMIT=30   # seconds; the fixed build takes about 4

echo "================================================================================"
echo "Faulted dispatch: omniprobe exits instead of hanging"
echo "================================================================================"

run_case() {   # run_case <name> <expected status> <expect warning: yes|no> <omniprobe args...> -- <app args>
    local name="$1" want="$2" warn="$3"; shift 3
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local start=$SECONDS
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 "$LIMIT" "$OMNIPROBE" "$@" > "$OUT/$name.log" 2>&1
    local status=$? elapsed=$((SECONDS - start))
    local warned=no
    grep -q "never completed" "$OUT/$name.log" && grep -q "^  fault_kernel" "$OUT/$name.log" && warned=yes
    if [ "$status" -eq "$want" ] && [ "$warned" = "$warn" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - exit $status after ${elapsed}s, abandonment warning: $warned"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - exit $status after ${elapsed}s (124 = hung until the ${LIMIT}s timeout), abandonment warning: $warned; want exit $want, warning: $warn; see $OUT/$name.log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# How the fault ends the bare application depends on the runtime and node: on
# gfx90a (MI210) synchronization reports it and fault_test exits 3; on a gfx950
# VM (MI350, 2026-11-08) the runtime kills the process (SIGPIPE, 141) before
# fault_test can. Omniprobe must end promptly with that same status; the
# abandonment warning can only be printed when the process survives the fault.
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 "$LIMIT" "$BIN" > "$OUT/bare.log" 2>&1
BARE=$?
echo "fault_test without omniprobe: exit $BARE"
[ "$BARE" -lt 128 ] && FAULT_WARN=yes || FAULT_WARN=no
run_case fault_timing_mode       "$BARE" "$FAULT_WARN" -- "$BIN"
run_case fault_instrumented_mode "$BARE" "$FAULT_WARN" -i -a AddressLogger -- "$BIN"
run_case no_fault                0 no  -i -a AddressLogger -- "$BIN" --no-fault

print_summary
