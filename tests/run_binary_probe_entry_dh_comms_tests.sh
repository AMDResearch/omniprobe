#!/bin/bash
################################################################################
# Binary-only lifecycle entry dh_comms rejection tests
#
# Verifies the donor-free binary-only path:
#   1. can still plan an entry-only lifecycle request that references dh_comms
#   2. can still generate entry thunks for that request
#   3. rejects donor-free carrier regeneration before producing a misleadingly
#      valid binary whose helper would appear to support entry-time dh_comms
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
CLANG_OFFLOAD_BUNDLER="${CLANG_OFFLOAD_BUNDLER:-/opt/rocm/llvm/bin/clang-offload-bundler}"

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLAN_PROBE="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
GENERATE_THUNKS="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Module-load runtime smoke artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Build with: cmake --build build --target module_load_kernel_plain_hsaco"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ ! -x "$HIPCC" ] || [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ] || [ ! -x "$CLANG_OFFLOAD_BUNDLER" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm toolchain components not found${NC}"
    echo "  Expected: $HIPCC"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    echo "  Expected: $CLANG_OFFLOAD_BUNDLER"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/binary_probe_entry_dh_comms"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_entry_dh_comms.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_entry_dh_comms_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_entry_dh_comms.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_entry_dh_comms.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_entry_dh_comms.thunks.json"
REGENERATE_LOG="$WORK_DIR/module_load_binary_entry_dh_comms.regenerate.log"

cat > "$SPEC_FILE" <<EOF
version: 1

helpers:
  source: module_load_binary_entry_dh_comms_helper.hip
  namespace: omniprobe_user

defaults:
  emission: vector
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_entry_dh_comms
    target:
      kernels: ["mlk"]
    inject:
      when: [kernel_entry]
      helper: module_load_binary_entry_dh_comms_probe
      contract: kernel_lifecycle_v1
    payload:
      mode: vector
      message: address
    capture:
      kernel_args:
        - name: data
          type: u64
        - name: size
          type: u64
EOF

cat > "$HELPER_FILE" <<EOF
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_entry_dh_comms_probe(
    const helper_args<omniprobe_user::module_load_binary_entry_dh_comms_captures,
                      kernel_lifecycle_event> &args) {
  if (!lifecycle_event_is_dispatch_origin(*args.event)) {
    return;
  }

  auto *data = reinterpret_cast<void *>(static_cast<uintptr_t>(args.captures->data));
  dh_comms::v_submit_address(
      args.runtime->dh, data, 0, 3334, 0,
      static_cast<uint8_t>(memory_access_kind::write),
      static_cast<uint8_t>(address_space_kind::global),
      static_cast<uint16_t>(sizeof(uint32_t)), args.runtime->dh_builtins);
}
EOF

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$PLAN_PROBE"     "$MANIFEST_JSON"     --probe-bundle "$BUNDLE_JSON"     --kernel mlk     --output "$PLAN_JSON" >/dev/null
python3 "$GENERATE_THUNKS"     "$PLAN_JSON"     --probe-bundle "$BUNDLE_JSON"     --output "$THUNK_SOURCE"     --manifest-output "$THUNK_MANIFEST" >/dev/null

echo ""
echo "================================================================================"
echo "Binary Probe Entry dh_comms Rejection Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Plan: $PLAN_JSON"
echo "  Thunks: $THUNK_MANIFEST"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_dh_comms_plan"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$PLAN_JSON" "$THUNK_MANIFEST" <<PY2
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = json.load(open(sys.argv[2], encoding="utf-8"))

kernel = next(entry for entry in plan["kernels"] if entry.get("source_kernel") == "mlk")
site = next(
    entry
    for entry in kernel.get("planned_sites", [])
    if entry.get("when") == "kernel_entry" and entry.get("contract") == "kernel_lifecycle_v1"
)
assert site.get("status") == "planned"
assert site.get("helper") == "module_load_binary_entry_dh_comms_probe"

thunk = next(
    entry
    for entry in manifest.get("thunks", [])
    if entry.get("source_kernel") == "mlk" and entry.get("when") == "kernel_entry"
)
assert thunk.get("probe_id") == "module_load_binary_entry_dh_comms"
PY2
then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only dh_comms planning still emits a kernel_entry site and thunk manifest"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only dh_comms planning/thunk generation did not produce the expected artifacts"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_dh_comms_rejected"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

python3 "$REGENERATE_CODE_OBJECT"     "$MODULE_LOAD_PLAIN_HSACO"     --output "$WORK_DIR/module_load_binary_entry_dh_comms.carrier.hsaco"     --manifest "$MANIFEST_JSON"     --kernel mlk     --report-output "$WORK_DIR/module_load_binary_entry_dh_comms.carrier.report.json"     --add-hidden-abi-clone     --probe-plan "$PLAN_JSON"     --thunk-manifest "$THUNK_MANIFEST"     --hipcc "$HIPCC"     --llvm-mc "$LLVM_MC"     --ld-lld "$LD_LLD"     --clang-offload-bundler "$CLANG_OFFLOAD_BUNDLER" >"$REGENERATE_LOG" 2>&1     && run_status=0 || run_status=$?

if [ "$run_status" -ne 0 ] &&    grep -q "donor-free binary rewrite does not support kernel_entry lifecycle helper execution" "$REGENERATE_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only donor-free regeneration for dh_comms was rejected with the expected unsupported message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only donor-free dh_comms regeneration did not fail closed as expected"
    cat "$REGENERATE_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
