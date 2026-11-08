#!/bin/bash
################################################################################
# The build tree can compile instrumented code.
#
# The pass plugins load device bitcode from ../bitcode relative to themselves
# (InstrumentationCommon.cpp getBitcodePath). build/lib/bitcode/ used to be
# populated only by the tests' CMakeLists, and with only the four legacy files:
# a tree configured without INTERCEPTOR_BUILD_TESTING had no bitcode at all, and
# hipcc -fpass-plugin=build/lib/plugins/... printed "Bitcode file not found",
# exited 0, and produced a binary with no instrumented clones.
#
# Needs no GPU: it compiles, it does not run.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
: "${ARCH:=gfx90a}"

mkdir -p "$OUTPUT_DIR/build_tree_bitcode"
WORK="$OUTPUT_DIR/build_tree_bitcode"

echo "================================================================================"
echo "Build-tree device bitcode"
echo "================================================================================"
echo "Build dir: $BUILD_DIR"
echo "hipcc:     $HIPCC (--offload-arch=$ARCH)"
echo "================================================================================"

################################################################################
# Every bitcode file dh_comms builds is where the plugins look for it
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} all_bitcode_in_build_lib_bitcode"
missing=""
n=0
for bc in "$BUILD_DIR"/external/dh_comms/lib/*.bc; do
    [ -e "$bc" ] || continue
    n=$((n + 1))
    [ -f "$BUILD_DIR/lib/bitcode/$(basename "$bc")" ] || missing="$missing $(basename "$bc")"
done
if [ "$n" -eq 0 ]; then
    echo -e "  ${RED}✗ FAIL${NC} - no bitcode under $BUILD_DIR/external/dh_comms/lib"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif [ -n "$missing" ]; then
    echo -e "  ${RED}✗ FAIL${NC} - missing from lib/bitcode:$missing"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "  ${GREEN}✓ PASS${NC} - all $n bitcode files present in lib/bitcode"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

################################################################################
# Each -rocm plugin, used straight from the build tree, links the bitcode
################################################################################
cat > "$WORK/k.hip" <<'EOF'
#include <hip/hip_runtime.h>
__global__ void k(int* d) { d[threadIdx.x] = threadIdx.x; }
int main() { int* d; (void)hipMalloc(&d, 256); k<<<1, 64>>>(d); (void)hipDeviceSynchronize(); return 0; }
EOF
for p in AddressMessages BBStart BBInterval; do
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} build_tree_plugin_links_bitcode_$p"
    log="$WORK/$p.log"
    "$HIPCC" --offload-arch="$ARCH" -g -fgpu-rdc \
        -fpass-plugin="$BUILD_DIR/lib/plugins/libAMDGCNSubmit$p-rocm.so" \
        "$WORK/k.hip" -o "$WORK/k_$p" > "$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q "Linking device module from .*/lib/plugins/../bitcode/" "$log" \
       && ! grep -q "Bitcode file not found" "$log"; then
        echo -e "  ${GREEN}✓ PASS${NC} - linked device bitcode from lib/bitcode"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - hipcc rc $rc; $(grep -m1 -E 'Bitcode|Linking|error' "$log")"
        echo "  Output saved to: $log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done

################################################################################
# A plugin that cannot find its bitcode stops the compilation
# (bf_plugin-missing-bitcode-fatal). It used to print an error, let hipcc exit
# 0 and emit a binary without instrumented clones.
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} missing_bitcode_is_a_compile_error"
NOBC="$WORK/nobc/lib/plugins"
rm -rf "$WORK/nobc" "$WORK/k_nobc"; mkdir -p "$NOBC"
cp "$BUILD_DIR/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so" "$NOBC/"
"$HIPCC" --offload-arch="$ARCH" -g -fgpu-rdc -fpass-plugin="$NOBC/libAMDGCNSubmitAddressMessages-rocm.so" \
    "$WORK/k.hip" -o "$WORK/k_nobc" > "$WORK/nobc.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$WORK/k_nobc" ] && \
   grep -q "omniprobe instrumentation plugin: device bitcode file not found: '$NOBC/dh_comms_dev_.*' (target $ARCH)" "$WORK/nobc.log"; then
    echo -e "  ${GREEN}✓ PASS${NC} - hipcc rc $rc, no binary, error names the missing file and $ARCH"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - hipcc rc $rc, binary $( [ -e "$WORK/k_nobc" ] && echo produced || echo absent ); $(grep -m1 -iE 'bitcode' "$WORK/nobc.log")"
    echo "  Output saved to: $WORK/nobc.log"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
