#!/bin/bash
################################################################################
# Configuration mistakes end the run with an error; tool failures never drop
# the application's work; the exit summary arrives in one piece.
#
# Regression tests for bf_robustness-errors:
#   - a handler plugin that does not exist / is not a plugin, and an unknown
#     analyzer name: exit 1 with an error (were: a hang until killed; silently
#     ignored; "Ignoring." and the default handlers, exit 0)
#   - -a PythonHandler with OMNIPROBE_PYTHON_HANDLER unset or naming an unusable
#     module: exit 1 (was: Heatmap instead, exit 0)
#   - ROCM_PATH unset and no /opt/rocm: the launcher finds ROCm itself (was:
#     kernelDB failed, and the instrumented dispatches were silently dropped)
#   - kernelDB failing anyway (fake llvm-objdump): an ERROR, and the kernels
#     still run correctly (were: dropped)
#   - 12 concurrent runs into files: every exit summary intact (was: a stdout
#     line inserted into it by the launcher's line-by-line forwarding)
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

K="${BUILD_DIR}/tests/test_kernels"
OUT="$OUTPUT_DIR/robustness"
mkdir -p "$OUT"
check_kernel "$K/python_handler_test"

echo "================================================================================"
echo "Robustness: configuration errors, kernelDB failures, exit summary"
echo "================================================================================"

result() {   # result <name> <ok 0|1> <message>
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $1"
    if [ "$2" = 0 ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $3"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $3"; TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

op() {   # op <name> <omniprobe args...> -> $OUT/<name>.log, sets STATUS
    local name="$1"; shift
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 60 "$OMNIPROBE" "$@" > "$OUT/$name.log" 2>&1
    STATUS=$?
}

expect_error() {   # expect_error <name> <pattern> <omniprobe args...>
    local name="$1" pattern="$2"; shift 2
    op "$name" "$@"
    if [ "$STATUS" -eq 1 ] && grep -q "omniprobe: ERROR: .*$pattern" "$OUT/$name.log"; then
        result "$name" 0 "exit 1: $(grep -m1 'omniprobe: ERROR' "$OUT/$name.log" | cut -c1-110)"
    else
        result "$name" 1 "exit $STATUS (124 = hung until killed), no 'ERROR: ...$pattern'; see $OUT/$name.log"
    fi
}

APP=("$K/python_handler_test" 1 1 64 1)
printf 'not an ELF file\n' > "$OUT/bogus.so"
printf 'x = 1\n' > "$OUT/no_functions.py"

expect_error missing_plugin "does not exist" -i -a "$OUT/no_such_plugin.so" -- "${APP[@]}"
expect_error unloadable_plugin "cannot load handler plugin" -i -a "$OUT/bogus.so" -- "${APP[@]}"
expect_error not_a_plugin "not an omniprobe handler plugin" -i -a "${BUILD_DIR}/lib/libkernelDB64.so" -- "${APP[@]}"
expect_error unknown_analyzer "is not an analyzer" -i -a MemoryAnalyss -- "${APP[@]}"
OMNIPROBE_PYTHON_HANDLER= expect_error python_module_unset "OMNIPROBE_PYTHON_HANDLER" -i -a PythonHandler -- "${APP[@]}"
OMNIPROBE_PYTHON_HANDLER="$OUT/no_functions.py" expect_error python_module_unusable "defines none of" -i -a PythonHandler -- "${APP[@]}"

# ROCM_PATH unset (and this node has no /opt/rocm): the launcher must find ROCm.
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" env -u ROCM_PATH timeout -k 5 120 "$OMNIPROBE" -i -a MemoryAnalysis \
    -t json -o "$OUT/no_rocm_path.json" -- "$K/python_handler_test" 1 2 1024 1 > "$OUT/no_rocm_path.log" 2>&1
STATUS=$?
n_acc="$(python3 -c "import json,sys; print(sum(len(k['accesses']) for k in json.load(open(sys.argv[1]))))" "$OUT/no_rocm_path.json" 2>/dev/null)"
if [ "$STATUS" -eq 0 ] && grep -q "2 dispatches, 0 wrong results" "$OUT/no_rocm_path.log" && [ "${n_acc:-0}" -gt 0 ] \
   && ! grep -q "kernelDB could not\|Command failed" "$OUT/no_rocm_path.log"; then
    result no_rocm_path 0 "kernels correct, $n_acc analyzed accesses"
else
    result no_rocm_path 1 "exit $STATUS, accesses '${n_acc:-}', $(grep -m1 'wrong results' "$OUT/no_rocm_path.log")"
fi

# kernelDB failing anyway: a ROCm whose llvm-objdump always fails.
FAKE="$OUT/fake_rocm"
mkdir -p "$FAKE/llvm/bin"
printf '#!/bin/sh\nexit 1\n' > "$FAKE/llvm/bin/llvm-objdump"
chmod +x "$FAKE/llvm/bin/llvm-objdump"
ROCM_PATH="$FAKE" op kerneldb_failure -i -a MemoryAnalysis -- "$K/python_handler_test" 1 2 1024 1
if [ "$STATUS" -eq 0 ] && grep -q "2 dispatches, 0 wrong results" "$OUT/kerneldb_failure.log" \
   && grep -q "omniprobe: ERROR: kernelDB could not read" "$OUT/kerneldb_failure.log"; then
    result kerneldb_failure 0 "ERROR reported, kernels still ran correctly"
else
    result kerneldb_failure 1 "exit $STATUS, $(grep -m1 'wrong results' "$OUT/kerneldb_failure.log"); see $OUT/kerneldb_failure.log"
fi

# Exit summary in one piece, 12 runs at once, each into its own file.
HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
cat > "$OUT/plain.hip" <<'HIP'
#include <hip/hip_runtime.h>
__global__ void plain_kernel(int* d) { d[threadIdx.x] = 1; }
int main() { int* d; (void)hipMalloc(&d, 256); plain_kernel<<<1, 64>>>(d); plain_kernel<<<1, 64>>>(d);
             (void)hipDeviceSynchronize(); return 0; }
HIP
"$HIPCC" --offload-arch="${ARCH:-gfx90a}" "$OUT/plain.hip" -o "$OUT/plain" > "$OUT/plain_build.log" 2>&1
for i in $(seq 1 12); do
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 120 "$OMNIPROBE" -i -a MemoryAnalysis -- "$OUT/plain" > "$OUT/summary_$i.log" 2>&1 &
done
wait
intact=0
for i in $(seq 1 12); do
    python3 - "$OUT/summary_$i.log" <<'PY' && intact=$((intact + 1))
import sys
L = open(sys.argv[1], errors="replace").read().splitlines()
i = [n for n, l in enumerate(L) if "kernel(s) ran uninstrumented" in l]
sys.exit(0 if len(i) == 1 and L[i[0]].startswith("omniprobe: WARNING: ") and L[i[0] + 1].startswith("  plain_kernel") else 1)
PY
done
result exit_summary_intact "$([ "$intact" -eq 12 ] && echo 0 || echo 1)" "$intact of 12 concurrent runs have the exit summary in one piece"

print_summary
