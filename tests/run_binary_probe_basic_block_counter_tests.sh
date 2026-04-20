#!/bin/bash
################################################################################
# Binary-only basic-block counter capability tests
#
# Verifies the donor-free binary-only path can:
#   1. inject a mid-kernel helper at a basic-block insertion point
#   2. perform stateful aggregation via atomicAdd into kernel-visible memory
#   3. let the host observe a deterministic counter result after dispatch
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

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLAN_PROBE="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
GENERATE_THUNKS="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Module-load hsaco artifact not built${NC}"
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

WORK_DIR="$OUTPUT_DIR/binary_probe_basic_block_counter"
CACHE_DIR="$OUTPUT_DIR/binary_probe_basic_block_counter_cache"
rm -rf "$WORK_DIR" "$CACHE_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_basic_block_counter.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_basic_block_counter_helper.hip"
HOST_SOURCE="$WORK_DIR/module_load_counter_host.cpp"
HOST_BINARY="$WORK_DIR/module_load_counter_host"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
IR_JSON="$WORK_DIR/module_load_plain.ir.json"
PLAN_JSON="$WORK_DIR/module_load_binary_basic_block_counter.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_basic_block_counter.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_basic_block_counter.thunks.json"
CARRIER_HSACO="$WORK_DIR/module_load_binary_basic_block_counter.carrier.hsaco"
CARRIER_REPORT="$WORK_DIR/module_load_binary_basic_block_counter.carrier.report.json"
CARRIER_MANIFEST="$WORK_DIR/module_load_binary_basic_block_counter.carrier.manifest.json"
HOST_BUILD_LOG="$WORK_DIR/module_load_counter_host.build.log"
RUNTIME_LOG="$WORK_DIR/module_load_binary_basic_block_counter.runtime.log"

cat > "$SPEC_FILE" <<'SPEC'
version: 1

helpers:
  source: module_load_binary_basic_block_counter_helper.hip
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_basic_block_counter
    target:
      kernels: ["mlk"]
    inject:
      when: basic_block
      helper: module_load_binary_basic_block_counter_probe
      contract: basic_block_v1
    payload:
      mode: scalar
      message: custom
    capture:
      kernel_args:
        - name: data
          type: u64
        - name: size
          type: u64
SPEC

cat > "$HELPER_FILE" <<'HELPER'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_basic_block_counter_probe(
    const helper_args<omniprobe_user::module_load_binary_basic_block_counter_captures,
                      basic_block_event> &args) {
  if (args.event->block_id != 5) {
    return;
  }

  const auto *uniform = args.runtime != nullptr ? args.runtime->dispatch_uniform : nullptr;
  if (uniform == nullptr) {
    return;
  }
  if ((uniform->valid_mask & dispatch_uniform_valid_grid_dim) == 0 ||
      (uniform->valid_mask & dispatch_uniform_valid_block_dim) == 0) {
    return;
  }
  if (uniform->grid_dim_x != 4u || uniform->block_dim_x != 64u) {
    return;
  }

  auto *data = reinterpret_cast<unsigned int *>(static_cast<uintptr_t>(args.captures->data));
  const size_t size = static_cast<size_t>(args.captures->size);
  atomicAdd(data + size, 1u);
}
HELPER

cat > "$HOST_SOURCE" <<'HOST'
#include <hip/hip_runtime.h>
#include <cstdlib>
#include <iostream>
#include <vector>

#define CHECK_HIP(call)                                                       \
    do {                                                                      \
        hipError_t err = call;                                                \
        if (err != hipSuccess) {                                              \
            std::cerr << #call << " failed: " << hipGetErrorString(err)     \
                      << std::endl;                                           \
            return 1;                                                         \
        }                                                                     \
    } while (0)

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <path-to-hsaco>" << std::endl;
        return 1;
    }
    const char* hsaco_path = argv[1];

    constexpr size_t blocksize = 64;
    constexpr size_t num_blocks = 4;
    constexpr size_t size = blocksize * num_blocks;
    constexpr size_t storage_size = size + 1;
    constexpr unsigned int expected_counter = static_cast<unsigned int>(size);

    hipModule_t module;
    CHECK_HIP(hipModuleLoad(&module, hsaco_path));

    hipFunction_t kernel;
    CHECK_HIP(hipModuleGetFunction(&kernel, module, "mlk"));

    int* d_data = nullptr;
    CHECK_HIP(hipMalloc(&d_data, storage_size * sizeof(int)));
    CHECK_HIP(hipMemset(d_data, 0, storage_size * sizeof(int)));

    void* args[] = {&d_data, const_cast<size_t*>(&size)};
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        num_blocks, 1, 1,
        blocksize, 1, 1,
        0,
        nullptr,
        args,
        nullptr));
    CHECK_HIP(hipDeviceSynchronize());

    std::vector<int> h_data(storage_size, 0);
    CHECK_HIP(hipMemcpy(h_data.data(), d_data, storage_size * sizeof(int), hipMemcpyDeviceToHost));

    bool ok = true;
    for (size_t i = 0; i < size; ++i) {
        if (h_data[i] != static_cast<int>(i)) {
            std::cerr << "  DATA MISMATCH at index " << i
                      << ": expected " << i << ", got " << h_data[i]
                      << std::endl;
            ok = false;
            break;
        }
    }

    if (ok && static_cast<unsigned int>(h_data[size]) != expected_counter) {
        std::cerr << "  COUNTER MISMATCH at index " << size
                  << ": expected " << expected_counter
                  << ", got " << h_data[size] << std::endl;
        ok = false;
    }

    CHECK_HIP(hipFree(d_data));
    CHECK_HIP(hipModuleUnload(module));

    if (ok) {
        std::cerr << "module_load_counter_test: PASS counter=" << h_data[size] << std::endl;
        return 0;
    }

    std::cerr << "module_load_counter_test: FAIL" << std::endl;
    return 1;
}
HOST

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$DISASM_TO_IR" \
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
"$HIPCC" -std=c++17 -o "$HOST_BINARY" "$HOST_SOURCE" > "$HOST_BUILD_LOG" 2>&1

echo ""
echo "================================================================================"
echo "Binary Probe Basic-Block Counter Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Carrier hsaco: $CARRIER_HSACO"
echo "  Plan: $PLAN_JSON"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_basic_block_counter_build"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$PLAN_JSON" "$CARRIER_REPORT" "$CARRIER_MANIFEST" "$HOST_BINARY" <<'PY'
import json
import sys
from pathlib import Path

plan = json.load(open(sys.argv[1], encoding="utf-8"))
report = json.load(open(sys.argv[2], encoding="utf-8"))
manifest = json.load(open(sys.argv[3], encoding="utf-8"))
host_binary = Path(sys.argv[4])

assert host_binary.exists()
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
    echo -e "  ${GREEN}✓ PASS${NC} - Counter carrier regeneration produced a hidden-ABI clone with a planned exit-block insertion site"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Counter carrier regeneration artifacts were not correct"
    echo "  Host build log: $HOST_BUILD_LOG"
    echo "  Plan: $PLAN_JSON"
    echo "  Report: $CARRIER_REPORT"
    echo "  Manifest: $CARRIER_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_basic_block_counter_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a AddressLogger \
    --hsaco-input "$MODULE_LOAD_PLAIN_HSACO" \
    --carrier-input "$CARRIER_HSACO" \
    --cache-location "$CACHE_DIR" \
    -- "$HOST_BINARY" "$MODULE_LOAD_PLAIN_HSACO" > "$RUNTIME_LOG" 2>&1 \
    && run_status=0 || run_status=$?

if [ "$run_status" -ne 124 ] && \
   grep -q "Found instrumented alternative for mlk" "$RUNTIME_LOG" && \
   grep -q "module_load_counter_test: PASS counter=256" "$RUNTIME_LOG" && \
   ! grep -q "Memory access fault by GPU" "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Mid-kernel helper aggregated a deterministic counter that the host observed after dispatch"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Counter carrier runtime validation failed"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
