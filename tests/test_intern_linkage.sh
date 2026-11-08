#!/bin/bash
################################################################################
# Internal-linkage kernels under -fgpu-rdc are instrumented and analyzed like
# external ones, for both flavours of the ".intern.<hash>" suffix.
#
# Regression test for bf_intern-clone-name. A static or anonymous-namespace
# kernel compiled with -fgpu-rdc gets a symbol ending in ".intern.<hash>".
#   - Letter-leading hash: the original demangled, its instrumented clone did
#     not (the pass puts "Pv" after the suffix), the lookup keys never met, and
#     the kernel ran uninstrumented ("No instrumented alternative found").
#   - Digit-leading hash: neither demangled; the clone was found by accident on
#     raw names, but kernelDB filed the kernel under a different key, so every
#     access lost its source attribution and MemoryAnalysis reported nothing.
# The hash depends only on the compilation unit ID, so the fixture is built
# twice with fixed -cuid values (tests/test_kernels/CMakeLists.txt); this test
# asserts which flavour each build actually got, and fails if a toolchain
# change stops producing the suffix (it would otherwise pass vacuously).
#
# Also checks the end-of-run summary that lists kernels which ran without an
# instrumented clone.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

OUT="$OUTPUT_DIR/intern_linkage"
mkdir -p "$OUT"

echo "================================================================================"
echo "Internal-linkage kernels under -fgpu-rdc"
echo "================================================================================"

pass() { echo -e "  ${GREEN}✓ PASS${NC} - $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} - $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# flavour_case <letter|digit> <leading-character class>
flavour_case() {
    local flavour="$1" class="$2"
    local bin="${BUILD_DIR}/tests/test_kernels/intern_${flavour}_test"
    local log="$OUT/${flavour}.log" json="$OUT/${flavour}.json"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} intern_${flavour}_hash_present"
    if [ ! -x "$bin" ]; then
        fail "fixture not built: $bin"
        return
    fi
    local hash
    hash="$(strings "$bin" | grep -o 'intern\.[0-9a-f]\{16\}' | sort -u | head -1 | cut -d. -f2)"
    if [ -z "$hash" ]; then
        fail "no .intern.<hash> symbol in $bin; the fixture no longer tests anything"
        return
    elif [[ "$hash" =~ ^$class ]]; then
        pass "hash $hash is $flavour-leading"
    else
        fail "hash $hash is not $flavour-leading; adjust the -cuid in tests/test_kernels/CMakeLists.txt"
        return
    fi

    rm -f "$json"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$json" \
        -- "$bin" > "$log" 2>&1

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} intern_${flavour}_all_kernels_instrumented"
    local missing=""
    for k in kernel_external kernel_static kernel_anon; do
        grep -q "Found instrumented alternative for .*$k" "$log" || missing="$missing $k"
    done
    if [ -n "$missing" ] || grep -q "No instrumented alternative found" "$log"; then
        fail "not instrumented:${missing:- (see 'No instrumented alternative' in $log)}"
    else
        pass "all three kernels ran their instrumented clones"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} intern_${flavour}_accesses_attributed"
    local verdict
    verdict="$(python3 - "$json" <<'PY'
import json, os, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"BAD output unusable: {e}"); sys.exit()
bad = []
for k in ("kernel_external", "kernel_static", "kernel_anon"):
    entries = [d for d in data if k in d.get("kernel", "")]
    acc = [a for d in entries for a in d.get("accesses", [])]
    if not acc or any(os.path.basename(a.get("source_file", "")) != "intern_linkage_test.cpp" for a in acc):
        bad.append(f"{k}: {len(acc)} accesses")
print(f"BAD {bad}" if bad else "OK every kernel has accesses attributed to intern_linkage_test.cpp")
PY
)"
    [[ "$verdict" == OK* ]] && pass "$verdict" || fail "$verdict"
}

flavour_case letter '[a-f]'
flavour_case digit '[0-9]'

################################################################################
# A kernel without an instrumented clone is named in the end-of-run summary
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} uninstrumented_kernels_summarised"
HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
cat > "$OUT/plain.hip" <<'EOF'
#include <hip/hip_runtime.h>
__global__ void plain_kernel(int* d) { d[threadIdx.x] = 1; }
int main() { int* d; (void)hipMalloc(&d, 256); plain_kernel<<<1, 64>>>(d); plain_kernel<<<1, 64>>>(d);
             (void)hipDeviceSynchronize(); return 0; }
EOF
if ! "$HIPCC" --offload-arch="${ARCH:-gfx90a}" "$OUT/plain.hip" -o "$OUT/plain" > "$OUT/plain.compile.log" 2>&1; then
    fail "could not compile the uninstrumented probe (see $OUT/plain.compile.log)"
else
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a MemoryAnalysis -- "$OUT/plain" > "$OUT/plain.log" 2>&1
    if grep -q "WARNING: 1 kernel(s) ran uninstrumented" "$OUT/plain.log" && \
       grep -q "plain_kernel(int\*) \[clone .kd\] (2 dispatches)" "$OUT/plain.log"; then
        pass "summary names plain_kernel with 2 dispatches"
    else
        fail "no end-of-run summary for the uninstrumented kernel (see $OUT/plain.log)"
    fi
fi

print_summary
