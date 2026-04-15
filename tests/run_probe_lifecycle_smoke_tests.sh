#!/bin/bash
################################################################################
# Kernel lifecycle surrogate smoke tests
#
# Verifies the compile-time kernel lifecycle path can:
#   1. load generated kernel-entry and kernel-exit surrogates
#   2. resolve captured kernel args by source name
#   3. inject true entry/exit helper calls into a cloned kernel
#   4. route runtime messages through the generated helper path
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
HIP_ARCH="${HIP_ARCH:-gfx1030}"
PLUGIN_SO="${BUILD_DIR}/lib/plugins/libAMDGCNSubmitKernelLifecycle-rocm.so"
GENERATOR="${REPO_ROOT}/tools/probes/generate_probe_surrogates.py"
TEST_SOURCE="${REPO_ROOT}/tests/test_kernels/simple_heatmap_test.cpp"
TEST_INCLUDE_DIR="${REPO_ROOT}/tests/test_kernels"
DH_COMMS_INCLUDE_DIR="${REPO_ROOT}/external/dh_comms/include"
PROBE_ABI_INCLUDE_DIR="${REPO_ROOT}/inc"

if [ ! -x "$HIPCC" ] || [ ! -x "$PLUGIN_SO" ] || [ ! -x "$OMNIPROBE" ]; then
    echo -e "${YELLOW}SKIP: ROCm toolchain or kernel lifecycle plugin not available${NC}"
    echo "  Expected hipcc: $HIPCC"
    echo "  Expected plugin: $PLUGIN_SO"
    echo "  Expected omniprobe: $OMNIPROBE"
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SPEC_FILE="${WORK_DIR}/simple_lifecycle_probe.yaml"
GENERATED_HIP="${WORK_DIR}/generated_lifecycle_surrogates.hip"
GENERATED_MANIFEST="${WORK_DIR}/generated_lifecycle_surrogates.json"
HELPER_SOURCE="${WORK_DIR}/lifecycle_helper.hip"
HELPER_BC="${WORK_DIR}/lifecycle_helper.bc"
TEST_BINARY="${WORK_DIR}/simple_lifecycle_test"
COMPILE_LOG="${WORK_DIR}/compile.log"
RUNTIME_LOG="${WORK_DIR}/runtime.log"

cat > "$SPEC_FILE" <<'EOF'
version: 1

helpers:
  source: probes/generated_lifecycle_helper.hip
  namespace: omniprobe_user

defaults:
  emission: auto
  lane_headers: false
  state: none

probes:
  - id: simple_kernel_lifecycle
    target:
      kernels: ["simple_kernel"]
    inject:
      when: [kernel_entry, kernel_exit]
      helper: lifecycle_probe
      contract: kernel_lifecycle_v1
    payload:
      mode: scalar
      message: address
    capture:
      kernel_args:
        - name: data
          type: u64
        - name: size
          type: u64
EOF

cat > "$HELPER_SOURCE" <<'EOF'
#include <stdint.h>
#include "generated_lifecycle_surrogates.hip"

using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void lifecycle_probe(
    const helper_args<omniprobe_user::simple_kernel_lifecycle_captures,
                      kernel_lifecycle_event> &args) {
  uint32_t line = args.site->event == event_kind::kernel_entry ? 1111 : 2222;
  dh_comms::v_submit_address(
      args.runtime->dh, reinterpret_cast<void *>(args.captures->data), 0, line,
      0, static_cast<uint8_t>(memory_access_kind::read),
      static_cast<uint8_t>(address_space_kind::global),
      static_cast<uint16_t>(sizeof(uint32_t)));
}
EOF

python3 "$GENERATOR" "$SPEC_FILE" \
    --hip-output "$GENERATED_HIP" \
    --manifest-output "$GENERATED_MANIFEST"

"$HIPCC" -x hip --offload-device-only --offload-arch="${HIP_ARCH}" -fgpu-rdc \
    -emit-llvm -c \
    -I"$DH_COMMS_INCLUDE_DIR" \
    -I"$PROBE_ABI_INCLUDE_DIR" \
    -I"$WORK_DIR" \
    -o "$HELPER_BC" \
    "$HELPER_SOURCE"

OMNIPROBE_PROBE_MANIFEST="$GENERATED_MANIFEST" \
OMNIPROBE_PROBE_BITCODE="$HELPER_BC" \
"$HIPCC" -x hip -fgpu-rdc -g \
    -fpass-plugin="$PLUGIN_SO" \
    -I"$TEST_INCLUDE_DIR" \
    -o "$TEST_BINARY" \
    "$TEST_SOURCE" > "$COMPILE_LOG" 2>&1

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    "$OMNIPROBE" -i -a AddressLogger -- "$TEST_BINARY" > "$RUNTIME_LOG" 2>&1

echo ""
echo "================================================================================"
echo "Probe Lifecycle Smoke Tests"
echo "================================================================================"
echo "  Manifest: $GENERATED_MANIFEST"
echo "  Helper bitcode: $HELPER_BC"
echo "  Test binary: $TEST_BINARY"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_lifecycle_compile_path"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if ! grep -q "Using generated kernel-entry surrogate __omniprobe_probe_simple_kernel_lifecycle_kernel_entry_surrogate" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Kernel-entry surrogate was not selected"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ! grep -q "Using generated kernel-exit surrogate __omniprobe_probe_simple_kernel_lifecycle_kernel_exit_surrogate" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Kernel-exit surrogate was not selected"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "falling back to kernel-arg ordinal" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Kernel lifecycle capture resolution regressed to ordinal fallback"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "  ${GREEN}✓ PASS${NC} - Kernel lifecycle surrogates selected without ordinal fallback"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_lifecycle_runtime_path"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if grep -q '"dwarf_line": 1111' "$RUNTIME_LOG" && grep -q '"dwarf_line": 2222' "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Runtime helper path emitted entry and exit sentinels"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Runtime output did not contain both lifecycle sentinels"
    echo "  Runtime log: $RUNTIME_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
