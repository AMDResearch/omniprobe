#!/bin/bash
################################################################################
# Binary-only lifecycle entry runtime smoke tests
#
# Verifies the donor-free binary-only path can:
#   1. plan entry-only lifecycle instrumentation for an existing hsaco with no
#      source build
#   2. regenerate a hidden-ABI carrier hsaco with linked probe support code
#   3. execute an entry-only helper path from a non-kernel_exit insertion point
#   4. preserve original kernel behavior while the instrumented carrier runs
#
# The stronger hidden-runtime-context proof now lives in the companion
# dh_comms runtime test, which exercises helper execution end-to-end.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe
OMNIPROBE_TIMEOUT="${OMNIPROBE_TIMEOUT:-20s}"

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
CLANG_OFFLOAD_BUNDLER="${CLANG_OFFLOAD_BUNDLER:-/opt/rocm/llvm/bin/clang-offload-bundler}"

MODULE_LOAD_TEST="${BUILD_DIR}/tests/test_kernels/module_load_test"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLAN_PROBE="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
GENERATE_THUNKS="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"

if [ ! -x "$MODULE_LOAD_TEST" ] || [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Module-load runtime smoke artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_TEST"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Build with: cmake --build build --target module_load_test module_load_kernel_plain_hsaco"
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
CACHE_DIR="$OUTPUT_DIR/binary_probe_entry_runtime_smoke_cache"
rm -rf "$WORK_DIR" "$CACHE_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_entry_runtime.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_entry_runtime_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_entry_runtime.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_entry_runtime.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_entry_runtime.thunks.json"
CARRIER_HSACO="$WORK_DIR/module_load_binary_entry_runtime.carrier.hsaco"
CARRIER_REPORT="$WORK_DIR/module_load_binary_entry_runtime.carrier.report.json"
CARRIER_MANIFEST="$WORK_DIR/module_load_binary_entry_runtime.carrier.manifest.json"
RUNTIME_LOG="$WORK_DIR/module_load_binary_entry_runtime.runtime.log"

cat > "$SPEC_FILE" <<'EOF'
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

cat > "$HELPER_FILE" <<'EOF'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_entry_runtime_probe(
    const helper_args<omniprobe_user::module_load_binary_entry_runtime_captures,
                      kernel_lifecycle_event> &args) {
  (void)args;
}
EOF

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$PLAN_PROBE" \
    "$MANIFEST_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --kernel mlk \
    --output "$PLAN_JSON" >/dev/null
python3 "$GENERATE_THUNKS" \
    "$PLAN_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --output "$THUNK_SOURCE" \
    --manifest-output "$THUNK_MANIFEST" >/dev/null
python3 "$REGENERATE_CODE_OBJECT" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output "$CARRIER_HSACO" \
    --manifest "$MANIFEST_JSON" \
    --kernel mlk \
    --report-output "$CARRIER_REPORT" \
    --add-hidden-abi-clone \
    --probe-plan "$PLAN_JSON" \
    --thunk-manifest "$THUNK_MANIFEST" \
    --hipcc "$HIPCC" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" \
    --clang-offload-bundler "$CLANG_OFFLOAD_BUNDLER" >/dev/null
python3 "$INSPECT_CODE_OBJECT" "$CARRIER_HSACO" --output "$CARRIER_MANIFEST" >/dev/null

echo ""
echo "================================================================================"
echo "Binary Probe Entry Runtime Smoke Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Carrier hsaco: $CARRIER_HSACO"
echo "  Plan: $PLAN_JSON"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_runtime_build"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$CARRIER_REPORT" "$CARRIER_MANIFEST" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
manifest = json.load(open(sys.argv[2], encoding="utf-8"))

clone = report.get("clone_result", {})
assert clone.get("clone_kernel") == "__amd_crk_mlk"
extra = report.get("extra_link_objects", [])
assert isinstance(extra, list) and extra

kernels = manifest["kernels"]["metadata"]["kernels"]
target = next(
    kernel
    for kernel in kernels
    if kernel.get("name") == "__amd_crk_mlk" or kernel.get("symbol") == "__amd_crk_mlk.kd"
)
args = target.get("args", [])
assert any(arg.get("name") == "hidden_omniprobe_ctx" for arg in args)
assert int(target.get("kernarg_segment_size", 0)) > 16
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only binary regeneration produced a hidden-ABI carrier with linked probe support"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only binary carrier regeneration metadata was not correct"
    echo "  Report: $CARRIER_REPORT"
    echo "  Manifest: $CARRIER_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_runtime_exec"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a AddressLogger \
    --hsaco-input "$MODULE_LOAD_PLAIN_HSACO" \
    --carrier-input "$CARRIER_HSACO" \
    --cache-location "$CACHE_DIR" \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_PLAIN_HSACO" > "$RUNTIME_LOG" 2>&1 \
    && run_status=0 || run_status=$?

if [ "$run_status" -ne 124 ] && \
   grep -q "Found instrumented alternative for mlk" "$RUNTIME_LOG" && \
   grep -q "module_load_test: PASS" "$RUNTIME_LOG" && \
   ! grep -q "Memory access fault by GPU" "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Entry-only carrier executed without fault and preserved kernel behavior"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Entry-only carrier runtime validation failed"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
