#!/bin/bash
################################################################################
# BasicBlockAnalysis must not crash on messages it cannot interpret.
#
# Regression test for bf_bba-hardening. The handler took hdr.user_data as an
# index into kernelDB's basic-block table without checking the message type or
# the index (the bounds check was an assert, compiled out). On a binary built
# with the default AddressMessages plugin, user_data packs access kind and size,
# so the index ran off the table and the process died of SIGSEGV (exit 139).
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

AM_BIN="${BUILD_DIR}/tests/test_kernels/dual_kernel_test"
BB_BIN="${BUILD_DIR}/tests/test_kernels/dual_kernel_bbstart_test"
for k in "$AM_BIN" "$BB_BIN"; do
    if [ ! -x "$k" ]; then
        echo -e "${RED}ERROR: test kernel not found: $k${NC}"
        exit 1
    fi
done

OUT="$OUTPUT_DIR/bba_robustness"
mkdir -p "$OUT"

echo "================================================================================"
echo "BasicBlockAnalysis robustness"
echo "================================================================================"

# bba_case <name> <binary> <expect warning: yes|no>
bba_case() {
    local name="$1" bin="$2" want_warn="$3"
    local log="$OUT/$name.log" json="$OUT/$name.json"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    rm -f "$json"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a BasicBlockAnalysis \
        -t json -o "$json" -- "$bin" > "$log" 2>&1
    local rc=$?
    local warned=no
    grep -q "omniprobe basic block analysis: ignoring" "$log" && warned=yes
    local parses=no
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" 2>/dev/null && parses=yes
    if [ "$rc" -eq 0 ] && [ "$warned" = "$want_warn" ] && [ "$parses" = yes ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - rc 0, warning: $warned, JSON parses"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - rc $rc (want 0), warning: $warned (want $want_warn), JSON parses: $parses"
        echo "  Output saved to: $log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

bba_case "bba_on_address_messages_binary" "$AM_BIN" yes
bba_case "bba_on_bbstart_binary" "$BB_BIN" no

print_summary
