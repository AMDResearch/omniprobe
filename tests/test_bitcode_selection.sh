#!/bin/bash
################################################################################
# Device bitcode selection (rf_exact-arch-bitcode).
#
# The pass plugins link dh_comms device bitcode compiled for the exact target
# architecture (dh_comms_dev_<arch>_co<N>.bc) when the build has it, and fall
# back to the legacy bucket (cdna3 for gfx94x, cdna2 otherwise) with a warning
# when it does not. Architectures dh_comms does not identify always get the
# legacy bucket: their exact-arch bitcode would report gcnarch::unsupported.
# For modules without target-cpu (Triton), the architecture comes from the
# target triple (amdgpu9.0a-amd-amdhsa -> gfx90a).
#
# Needs no GPU: it compiles for several architectures, it does not run.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

HIPCC="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/hipcc"
[ -x "$HIPCC" ] || HIPCC="$(command -v hipcc)"
PLUGIN="$BUILD_DIR/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"
BCDIR="$BUILD_DIR/lib/bitcode"

WORK="$OUTPUT_DIR/bitcode_selection"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "================================================================================"
echo "Device bitcode selection"
echo "================================================================================"
echo "Build dir: $BUILD_DIR"
echo "Bitcode:   $(cd "$BCDIR" 2>/dev/null && ls | tr '\n' ' ')"
echo "================================================================================"

cat > "$WORK/k.hip" <<'EOF'
#include <hip/hip_runtime.h>
__global__ void k(int* d) { d[threadIdx.x] = threadIdx.x; }
int main() { int* d; (void)hipMalloc(&d, 256); k<<<1, 64>>>(d); (void)hipDeviceSynchronize(); return 0; }
EOF

pass() { echo -e "  ${GREEN}✓ PASS${NC} - $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} - $1"; echo "  Output saved to: $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# compile_for <arch>: compile k.hip for <arch> with the -rocm plugin; log in $WORK/<arch>.log
compile_for() {
    "$HIPCC" --offload-arch="$1" -g -fgpu-rdc -fpass-plugin="$PLUGIN" \
        "$WORK/k.hip" -o "$WORK/k_$1" > "$WORK/$1.log" 2>&1
}

# linked <log>: basename of the bitcode file the plugin linked
linked() { sed -n 's|^Linking device module from .*/\(dh_comms_dev_[^/]*\.bc\) into GPU module$|\1|p' "$1" | sort -u | tr '\n' ' '; }

################################################################################
# Exact-arch file present: it is the one linked
################################################################################
# Must match IdentifiedByDhComms in InstrumentationCommon.cpp
IDENTIFIED="gfx906 gfx908 gfx90a gfx940 gfx941 gfx942 gfx950"
ARCH="$(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"
: "${ARCH:=gfx90a}"
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} exact_arch_bitcode_$ARCH"
if ! echo " $IDENTIFIED " | grep -q " $ARCH "; then
    pass "not applicable: dh_comms does not identify $ARCH (see unidentified_arch test)"
elif [ ! -f "$BCDIR/dh_comms_dev_${ARCH}_co6.bc" ]; then
    fail "build has no dh_comms_dev_${ARCH}_co6.bc (CMAKE_HIP_ARCHITECTURES without $ARCH?)" "$BCDIR"
elif compile_for "$ARCH" && [ "$(linked "$WORK/$ARCH.log")" = "dh_comms_dev_${ARCH}_co6.bc " ]; then
    pass "linked dh_comms_dev_${ARCH}_co6.bc"
else
    fail "linked: $(linked "$WORK/$ARCH.log")" "$WORK/$ARCH.log"
fi

################################################################################
# Exact-arch file absent, architecture known to dh_comms: legacy bucket + warning
################################################################################
for spec in gfx942:cdna3 gfx908:cdna2; do
    a="${spec%%:*}"; bucket="${spec##*:}"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} missing_exact_falls_back_${a}_to_${bucket}"
    if [ -f "$BCDIR/dh_comms_dev_${a}_co6.bc" ]; then
        pass "not applicable: this build has dh_comms_dev_${a}_co6.bc"
        continue
    fi
    compile_for "$a"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(linked "$WORK/$a.log")" = "dh_comms_dev_${bucket}_co6.bc " ] \
       && grep -q "no device bitcode for $a (.*dh_comms_dev_${a}_co6.bc not found); using $bucket" "$WORK/$a.log"; then
        pass "linked dh_comms_dev_${bucket}_co6.bc with a warning naming the missing file"
    else
        fail "hipcc rc $rc; linked: $(linked "$WORK/$a.log"); $(grep -m1 -i 'warning: no device\|dh_comms does not' "$WORK/$a.log")" "$WORK/$a.log"
    fi
done

################################################################################
# Architecture dh_comms does not identify (gfx900): legacy bucket + warning,
# even if an exact-arch file exists
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} unidentified_arch_gfx900_uses_cdna2"
compile_for gfx900; rc=$?
if [ "$rc" -eq 0 ] && [ "$(linked "$WORK/gfx900.log")" = "dh_comms_dev_cdna2_co6.bc " ] \
   && grep -q "dh_comms does not identify gfx900; using cdna2" "$WORK/gfx900.log"; then
    pass "linked dh_comms_dev_cdna2_co6.bc with a warning"
else
    fail "hipcc rc $rc; linked: $(linked "$WORK/gfx900.log"); $(grep -m1 -i 'warning: no device\|dh_comms does not' "$WORK/gfx900.log")" "$WORK/gfx900.log"
fi

################################################################################
# Triton: no target-cpu, architecture in the triple (Triton >= v3.9.0)
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} triton_triple_amdgpu9.0a_selects_gfx90a"
TRITON_LLVM="$(sed -n 's/^TRITON_LLVM:[A-Z]*=//p' "$BUILD_DIR/CMakeCache.txt" 2>/dev/null)"
TPLUGIN="$BUILD_DIR/lib/plugins/libAMDGCNSubmitAddressMessages-triton.so"
if [ -z "$TRITON_LLVM" ] || [ ! -x "$TRITON_LLVM/bin/opt" ] || [ ! -f "$TPLUGIN" ]; then
    pass "not applicable: build has no Triton plugin"
else
    cat > "$WORK/triton.ll" <<'EOF'
target triple = "amdgpu9.0a-amd-amdhsa"
define amdgpu_kernel void @k(ptr addrspace(1) %p) {
  store i32 1, ptr addrspace(1) %p, align 4
  ret void
}
EOF
    "$TRITON_LLVM/bin/opt" -load-pass-plugin="$TPLUGIN" -passes='default<O1>' \
        "$WORK/triton.ll" -o "$WORK/triton.bc" > "$WORK/triton.log" 2>&1; rc=$?
    want=dh_comms_dev_gfx90a_co5.bc # a build without gfx90a falls back to cdna2
    [ -f "$BCDIR/$want" ] || want=dh_comms_dev_cdna2_co5.bc
    if [ "$rc" -eq 0 ] && [ "$(linked "$WORK/triton.log")" = "$want " ] \
       && grep -q "Detected architecture: gfx90a (from target triple" "$WORK/triton.log"; then
        pass "gfx90a from the triple, linked $want"
    else
        fail "opt rc $rc; linked: $(linked "$WORK/triton.log"); $(grep -m1 -i 'architecture' "$WORK/triton.log")" "$WORK/triton.log"
    fi
fi

print_summary
