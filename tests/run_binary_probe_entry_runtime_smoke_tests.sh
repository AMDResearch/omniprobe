#!/bin/bash
################################################################################
# Binary-only lifecycle entry rejection tests
#
# Verifies the donor-free binary-only path:
#   1. can still plan and generate helper thunks for an entry-only request
#   2. rejects carrier regeneration for kernel_entry lifecycle helpers before
#      producing a misleadingly valid binary-only carrier
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

WORK_DIR="$OUTPUT_DIR/binary_probe_entry_runtime_smoke"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_entry_runtime.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_entry_runtime_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_entry_runtime.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_entry_runtime.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_entry_runtime.thunks.json"
REGENERATE_LOG="$WORK_DIR/module_load_binary_entry_runtime.regenerate.log"

cat > "$SPEC_FILE" <<EOF
version: 1

helpers:
  source: module_load_binary_entry_runtime_helper.hip
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_entry_runtime
    target:
      kernels: ["mlk"]
    inject:
      when: [kernel_entry]
      helper: module_load_binary_entry_runtime_probe
      contract: kernel_lifecycle_v1
    payload:
      mode: scalar
      message: custom
    capture:
      kernel_args:
        - name: data
          type: u64
        - name: size
          type: u64
EOF

cat > "$HELPER_FILE" <<EOF
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_entry_runtime_probe(
    const helper_args<omniprobe_user::module_load_binary_entry_runtime_captures,
                      kernel_lifecycle_event> &args) {
  auto *data = reinterpret_cast<int *>(static_cast<uintptr_t>(args.captures->data));
  if (data != nullptr) {
    data[0] = 4321;
  }
}
EOF

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$PLAN_PROBE"     "$MANIFEST_JSON"     --probe-bundle "$BUNDLE_JSON"     --kernel mlk     --output "$PLAN_JSON" >/dev/null
python3 "$GENERATE_THUNKS"     "$PLAN_JSON"     --probe-bundle "$BUNDLE_JSON"     --output "$THUNK_SOURCE"     --manifest-output "$THUNK_MANIFEST" >/dev/null

echo ""
echo "================================================================================"
echo "Binary Probe Entry Rejection Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Plan: $PLAN_JSON"
echo "  Thunks: $THUNK_MANIFEST"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_runtime_plan"
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

thunk = next(
    entry
    for entry in manifest.get("thunks", [])
    if entry.get("source_kernel") == "mlk" and entry.get("when") == "kernel_entry"
)
assert thunk.get("probe_id") == "module_load_binary_entry_runtime"
PY2
then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only binary planning still emits a kernel_entry site and thunk manifest"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only binary planning/thunk generation did not produce the expected artifacts"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_runtime_rejected"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

python3 "$REGENERATE_CODE_OBJECT"     "$MODULE_LOAD_PLAIN_HSACO"     --output "$WORK_DIR/module_load_binary_entry_runtime.carrier.hsaco"     --manifest "$MANIFEST_JSON"     --kernel mlk     --report-output "$WORK_DIR/module_load_binary_entry_runtime.carrier.report.json"     --add-hidden-abi-clone     --probe-plan "$PLAN_JSON"     --thunk-manifest "$THUNK_MANIFEST"     --hipcc "$HIPCC"     --llvm-mc "$LLVM_MC"     --ld-lld "$LD_LLD"     --clang-offload-bundler "$CLANG_OFFLOAD_BUNDLER" >"$REGENERATE_LOG" 2>&1     && run_status=0 || run_status=$?

if [ "$run_status" -ne 0 ] &&    grep -q "donor-free binary rewrite does not support kernel_entry lifecycle helper execution" "$REGENERATE_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only donor-free regeneration was rejected with the expected unsupported message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only donor-free regeneration did not fail closed as expected"
    cat "$REGENERATE_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
