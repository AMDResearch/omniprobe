#!/bin/bash
################################################################################
# Probe surrogate smoke tests
#
# Verifies the LLVM pass path can:
#   1. load a generated probe manifest
#   2. link generated helper bitcode
#   3. resolve captured kernel args by source name without ordinal fallback
#   4. route runtime messages through the helper-generated surrogate path
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
HIP_ARCH="${HIP_ARCH:-gfx1030}"
PLUGIN_SO="${BUILD_DIR}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
TEST_SOURCE="${REPO_ROOT}/tests/test_kernels/simple_heatmap_test.cpp"
TEST_INCLUDE_DIR="${REPO_ROOT}/tests/test_kernels"

if [ ! -x "$HIPCC" ] || [ ! -x "$PLUGIN_SO" ] || [ ! -x "$OMNIPROBE" ]; then
    echo -e "${YELLOW}SKIP: ROCm toolchain or Omniprobe plugin not available${NC}"
    echo "  Expected hipcc: $HIPCC"
    echo "  Expected plugin: $PLUGIN_SO"
    echo "  Expected omniprobe: $OMNIPROBE"
    return 0 2>/dev/null || exit 0
fi

if [ ! -f "$PREPARE_BUNDLE" ] || [ ! -f "$TEST_SOURCE" ]; then
    echo -e "${RED}ERROR: required probe smoke inputs are missing${NC}"
    echo "  Bundle tool: $PREPARE_BUNDLE"
    echo "  Test source: $TEST_SOURCE"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SPEC_FILE="${WORK_DIR}/simple_probe.yaml"
GENERATED_HIP="${WORK_DIR}/generated_surrogates.hip"
GENERATED_MANIFEST="${WORK_DIR}/generated_surrogates.json"
HELPER_SOURCE="${WORK_DIR}/smoke_helper.hip"
HELPER_BC="${WORK_DIR}/smoke_helper.bc"
PREPARE_LOG="${WORK_DIR}/prepare_bundle.json"
TEST_BINARY="${WORK_DIR}/simple_surrogate_test"
COMPILE_LOG="${WORK_DIR}/compile.log"
RUNTIME_LOG="${WORK_DIR}/runtime.log"

cat > "$SPEC_FILE" <<'EOF'
version: 1

helpers:
  source: smoke_helper.hip
  namespace: omniprobe_user

defaults:
  emission: auto
  lane_headers: false
  state: none

probes:
  - id: simple_kernel_loads
    target:
      kernels: ["simple_kernel"]
      match:
        kind: isa_mnemonic
        values: [global_load, flat_load]
    inject:
      when: [memory_op]
      helper: load_probe
      contract: memory_op_v1
    payload:
      mode: vector
      message: address
    capture:
      instruction: [address, bytes, addr_space, access_kind]
      kernel_args:
        - name: data
          type: u64
        - name: size
          type: u64
EOF

cat > "$HELPER_SOURCE" <<'EOF'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void load_probe(
    const helper_args<omniprobe_user::simple_kernel_loads_captures,
                      memory_op_event> &args) {
  dh_comms::v_submit_address(
      args.runtime->dh, reinterpret_cast<void *>(args.event->address), 0, 9999,
      0, static_cast<uint8_t>(args.event->access),
      static_cast<uint8_t>(args.event->address_space),
      static_cast<uint16_t>(args.event->bytes));
}
EOF

python3 "$PREPARE_BUNDLE" "$SPEC_FILE" \
    --output-dir "$WORK_DIR" \
    --hipcc "$HIPCC" \
    --arch "$HIP_ARCH" > "$PREPARE_LOG"

GENERATED_HIP="${WORK_DIR}/generated_probe_surrogates.hip"
GENERATED_MANIFEST="${WORK_DIR}/generated_probe_manifest.json"
HELPER_BC="${WORK_DIR}/generated_probe_helpers.bc"

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
echo "Probe Surrogate Smoke Tests"
echo "================================================================================"
echo "  Manifest: $GENERATED_MANIFEST"
echo "  Helper bitcode: $HELPER_BC"
echo "  Test binary: $TEST_BINARY"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_surrogate_compile_path"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if ! grep -q "Loaded 1 generated probe surrogate entries" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Probe manifest was not loaded during compilation"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ! grep -q "Using generated memory-op surrogate __omniprobe_probe_simple_kernel_loads_surrogate" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Generated surrogate was not selected"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "falling back to kernel-arg ordinal" "$COMPILE_LOG"; then
    echo -e "  ${RED}✗ FAIL${NC} - Kernel-arg capture resolution regressed to ordinal fallback"
    echo "  Compile log: $COMPILE_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "  ${GREEN}✓ PASS${NC} - Generated surrogate selected without ordinal fallback"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_surrogate_runtime_path"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if grep -q '"dwarf_line": 9999' "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Runtime helper path emitted sentinel dwarf_line=9999"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Runtime output did not contain the helper sentinel"
    echo "  Runtime log: $RUNTIME_LOG"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
