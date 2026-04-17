#!/bin/bash
################################################################################
# Binary-only basic-block dh_comms runtime smoke tests
#
# Verifies the donor-free binary-only path can:
#   1. plan basic-block instrumentation for an existing hsaco with no source build
#   2. regenerate a hidden-ABI carrier hsaco with linked probe support code
#   3. execute a mid-kernel helper call from a basic-block insertion point
#   4. emit host-visible dh_comms traffic from that mid-kernel insertion
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

WORK_DIR="$OUTPUT_DIR/binary_probe_basic_block_dh_comms"
CACHE_DIR="$OUTPUT_DIR/binary_probe_basic_block_dh_comms_cache"
rm -rf "$WORK_DIR" "$CACHE_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_basic_block_dh_comms.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_basic_block_dh_comms_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_basic_block_dh_comms.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_basic_block_dh_comms.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_basic_block_dh_comms.thunks.json"
CARRIER_HSACO="$WORK_DIR/module_load_binary_basic_block_dh_comms.carrier.hsaco"
CARRIER_REPORT="$WORK_DIR/module_load_binary_basic_block_dh_comms.carrier.report.json"
CARRIER_MANIFEST="$WORK_DIR/module_load_binary_basic_block_dh_comms.carrier.manifest.json"
IR_JSON="$WORK_DIR/module_load_plain.ir.json"
RUNTIME_LOG="$WORK_DIR/module_load_binary_basic_block_dh_comms.runtime.log"

cat > "$SPEC_FILE" <<'EOF'
version: 1

helpers:
  source: module_load_binary_basic_block_dh_comms_helper.hip
  namespace: omniprobe_user

defaults:
  emission: vector
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_basic_block_dh_comms
    target:
      kernels: ["mlk"]
    inject:
      when: basic_block
      helper: module_load_binary_basic_block_dh_comms_probe
      contract: basic_block_v1
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

cat > "$HELPER_FILE" <<'EOF'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_basic_block_dh_comms_probe(
    const helper_args<omniprobe_user::module_load_binary_basic_block_dh_comms_captures,
                      basic_block_event> &args) {
  if (args.event->block_id != 5) {
    return;
  }

  auto *data = reinterpret_cast<void *>(static_cast<uintptr_t>(args.captures->data));
  dh_comms::v_submit_address(
      args.runtime->dh, data, 0, 4445, 0,
      static_cast<uint8_t>(memory_access_kind::write),
      static_cast<uint8_t>(address_space_kind::global),
      static_cast<uint16_t>(sizeof(uint32_t)), args.runtime->dh_builtins);
}
EOF

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "${REPO_ROOT}/tools/codeobj/disasm_to_ir.py" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --manifest "$MANIFEST_JSON" \
    --output "$IR_JSON" >/dev/null
python3 "$PLAN_PROBE" \
    "$MANIFEST_JSON" \
    --ir "$IR_JSON" \
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
echo "Binary Probe Basic-Block dh_comms Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Carrier hsaco: $CARRIER_HSACO"
echo "  Plan: $PLAN_JSON"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_basic_block_dh_comms_build"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$PLAN_JSON" "$CARRIER_REPORT" "$CARRIER_MANIFEST" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
report = json.load(open(sys.argv[2], encoding="utf-8"))
manifest = json.load(open(sys.argv[3], encoding="utf-8"))

kernel = next(entry for entry in plan["kernels"] if entry.get("source_kernel") == "mlk")
sites = [
    entry
    for entry in kernel.get("planned_sites", [])
    if entry.get("when") == "basic_block" and entry.get("contract") == "basic_block_v1"
]
assert any(site.get("binary_site_id") == 5 for site in sites)

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
assert int(target.get("private_segment_fixed_size", 0)) > 224
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Basic-block dh_comms regeneration produced a carrier with a planned mid-kernel site"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Basic-block dh_comms carrier regeneration metadata was not correct"
    echo "  Plan: $PLAN_JSON"
    echo "  Report: $CARRIER_REPORT"
    echo "  Manifest: $CARRIER_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_basic_block_dh_comms_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

LOGDUR_LOG_FORMAT=json \
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
   grep -Eq '"dwarf_line":[[:space:]]*4445' "$RUNTIME_LOG" && \
   grep -Eq '"kernel_name":[[:space:]]*"mlk.kd"' "$RUNTIME_LOG" && \
   ! grep -q "0 bytes processed" "$RUNTIME_LOG" && \
   grep -q "module_load_test: PASS" "$RUNTIME_LOG" && \
   ! grep -q "Memory access fault by GPU" "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Basic-block carrier emitted host-visible dh_comms traffic from a mid-kernel insertion"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Basic-block carrier did not produce the expected host-visible dh_comms output"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
