#!/bin/bash
################################################################################
# Binary-only kernel-exit summary capability tests
#
# Verifies the donor-free binary-only path can:
#   1. inject a kernel-exit lifecycle helper into an existing hsaco
#   2. write a per-dispatch summary value into kernel-visible memory at exit
#   3. preserve the original kernel's functional result while exposing the summary
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

WORK_DIR="$OUTPUT_DIR/binary_probe_kernel_exit_summary"
CACHE_DIR="$OUTPUT_DIR/binary_probe_kernel_exit_summary_cache"
rm -rf "$WORK_DIR" "$CACHE_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_kernel_exit_summary.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_kernel_exit_summary_helper.hip"
HOST_SOURCE="$WORK_DIR/module_load_exit_summary_host.cpp"
HOST_BINARY="$WORK_DIR/module_load_exit_summary_host"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_kernel_exit_summary.plan.json"
THUNK_SOURCE="$WORK_DIR/module_load_binary_kernel_exit_summary.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/module_load_binary_kernel_exit_summary.thunks.json"
CARRIER_HSACO="$WORK_DIR/module_load_binary_kernel_exit_summary.carrier.hsaco"
CARRIER_REPORT="$WORK_DIR/module_load_binary_kernel_exit_summary.carrier.report.json"
CARRIER_MANIFEST="$WORK_DIR/module_load_binary_kernel_exit_summary.carrier.manifest.json"
HOST_BUILD_LOG="$WORK_DIR/module_load_exit_summary_host.build.log"
RUNTIME_LOG="$WORK_DIR/module_load_binary_kernel_exit_summary.runtime.log"

cat > "$SPEC_FILE" <<'SPEC'
version: 1

helpers:
  source: module_load_binary_kernel_exit_summary_helper.hip
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_kernel_exit_summary
    target:
      kernels: ["mlk"]
    inject:
      when: [kernel_exit]
      helper: module_load_binary_kernel_exit_summary_probe
      contract: kernel_lifecycle_v1
      event_usage: none
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

extern "C" __device__ void module_load_binary_kernel_exit_summary_probe(
    const helper_args<omniprobe_user::module_load_binary_kernel_exit_summary_captures,
                      kernel_lifecycle_event> &args) {

  auto *data = reinterpret_cast<unsigned int *>(static_cast<uintptr_t>(args.captures->data));
  const size_t size = static_cast<size_t>(args.captures->size);
  data[size] = 0x4f500001u;
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
    constexpr unsigned int expected_summary = 0x4f500001u;

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

    if (ok && static_cast<unsigned int>(h_data[size]) != expected_summary) {
        std::cerr << "  SUMMARY MISMATCH at index " << size
                  << ": expected 0x" << std::hex << expected_summary
                  << ", got 0x" << static_cast<unsigned int>(h_data[size])
                  << std::dec << std::endl;
        ok = false;
    }

    CHECK_HIP(hipFree(d_data));
    CHECK_HIP(hipModuleUnload(module));

    if (ok) {
        std::cerr << "module_load_exit_summary_test: PASS summary=0x" << std::hex
                  << static_cast<unsigned int>(h_data[size]) << std::dec << std::endl;
        return 0;
    }

    std::cerr << "module_load_exit_summary_test: FAIL" << std::endl;
    return 1;
}
HOST

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
"$HIPCC" -std=c++17 -o "$HOST_BINARY" "$HOST_SOURCE" > "$HOST_BUILD_LOG" 2>&1

echo ""
echo "================================================================================"
echo "Binary Probe Kernel-Exit Summary Tests"
echo "================================================================================"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Carrier hsaco: $CARRIER_HSACO"
echo "  Plan: $PLAN_JSON"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_kernel_exit_summary_build"
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
site = next(
    entry
    for entry in kernel.get("planned_sites", [])
    if entry.get("when") == "kernel_exit" and entry.get("contract") == "kernel_lifecycle_v1"
)
assert site.get("status") == "planned"
assert site.get("helper") == "module_load_binary_kernel_exit_summary_probe"
assert site.get("event_usage") == "none"

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
    echo -e "  ${GREEN}✓ PASS${NC} - Kernel-exit summary regeneration produced a hidden-ABI carrier with lifecycle instrumentation"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Kernel-exit summary carrier regeneration metadata was not correct"
    echo "  Host build log: $HOST_BUILD_LOG"
    echo "  Plan: $PLAN_JSON"
    echo "  Report: $CARRIER_REPORT"
    echo "  Manifest: $CARRIER_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_kernel_exit_summary_runtime"
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
   grep -q "module_load_exit_summary_test: PASS summary=0x4f500001" "$RUNTIME_LOG" && \
   ! grep -q "Memory access fault by GPU" "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Kernel-exit helper recorded a deterministic summary value without perturbing kernel results"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Kernel-exit summary runtime validation failed"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
