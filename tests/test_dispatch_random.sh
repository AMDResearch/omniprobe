#!/bin/bash
################################################################################
# -d random never ends silently empty.
#
# -d random captures each dispatch the kernel filter lets through with
# probability 1/100, so an application with a few dispatches per kernel is
# usually captured not at all -- and omniprobe used to say nothing. Now every
# eligible kernel is either in the output or named in an end-of-run warning,
# and kernels excluded by -k are in neither (the draw is among matching
# dispatches only). Needs a GPU.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

APP="$BUILD_DIR/tests/test_kernels/dual_kernel_test" # kernel_alpha and kernel_beta, one dispatch each
WORK="$OUTPUT_DIR/dispatch_random"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "================================================================================"
echo "-d random"
echo "================================================================================"

# check <name> <expected kernels, space-separated> <excluded kernel or ""> <omniprobe args...>
check() {
    local name="$1" expect="$2" excluded="$3"; shift 3
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    "$OMNIPROBE" -i -a MemoryAnalysis -d random -t json -o "$WORK/$name.json" "$@" -- "$APP" > "$WORK/$name.log" 2>&1
    local rc=$? bad=""
    for k in $expect; do
        local captured=0 warned=0
        python3 -I -c 'import json,sys; sys.exit(0 if any(d["kernel"].startswith(sys.argv[2] + "(") for d in json.load(open(sys.argv[1]))) else 1)' \
            "$WORK/$name.json" "$k" 2>/dev/null && captured=1
        sed -n '/-d random captured no dispatch/,$p' "$WORK/$name.log" | grep -q "^  $k(" && warned=1
        [ $((captured + warned)) -eq 1 ] || bad="$bad $k(captured=$captured,warned=$warned)"
    done
    if [ -n "$excluded" ] && sed -n '/-d random captured no dispatch/,$p' "$WORK/$name.log" | grep -q "^  $excluded("; then
        bad="$bad $excluded(excluded by -k but counted)"
    fi
    if [ "$rc" -eq 0 ] && [ -z "$bad" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - each of [$expect] captured or named in the warning"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - omniprobe rc $rc;$bad"
        echo "  Output saved to: $WORK/$name.log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

check random_all_kernels "kernel_alpha kernel_beta" ""
check random_with_kernel_filter "kernel_beta" "kernel_alpha" -k kernel_beta

print_summary
