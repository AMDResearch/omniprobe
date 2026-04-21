#!/bin/bash
################################################################################
# Binary-only memory-op address-space runtime tests
#
# Verifies the donor-free binary-only path can:
#   1. plan LDS and global-like memory_op instrumentation for an hsaco with no
#      source-integrated Omniprobe build
#   2. regenerate a hidden-ABI carrier hsaco with linked probe support code
#   3. execute mid-kernel helpers for LDS loads/stores and global-like stores
#   4. emit host-visible dh_comms traffic for all supported memory classes
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
AMDGPU_ARCH_TOOL="${AMDGPU_ARCH_TOOL:-/opt/rocm/llvm/bin/amdgpu-arch}"
if [ ! -x "$AMDGPU_ARCH_TOOL" ]; then
    AMDGPU_ARCH_TOOL="/opt/rocm/bin/amdgpu-arch"
fi

INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLAN_PROBE="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
GENERATE_THUNKS="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"

if [ ! -x "$HIPCC" ] || [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ] || [ ! -x "$CLANG_OFFLOAD_BUNDLER" ] || [ ! -x "$AMDGPU_ARCH_TOOL" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm toolchain components not found${NC}"
    echo "  Expected: $HIPCC"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    echo "  Expected: $CLANG_OFFLOAD_BUNDLER"
    echo "  Expected: $AMDGPU_ARCH_TOOL"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

GPU_ARCH="$("$AMDGPU_ARCH_TOOL" | head -n 1)"
if [ -z "$GPU_ARCH" ]; then
    echo -e "${YELLOW}SKIP: Could not determine active AMDGPU target${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/binary_probe_memory_op_address_space"
CACHE_DIR="$OUTPUT_DIR/binary_probe_memory_op_address_space_cache"
rm -rf "$WORK_DIR" "$CACHE_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

KERNEL_SOURCE="$WORK_DIR/memory_space_kernel.hip"
HOST_SOURCE="$WORK_DIR/memory_space_host.cpp"
HOST_BIN="$WORK_DIR/memory_space_host"
PLAIN_HSACO="$WORK_DIR/memory_space_kernel_plain.hsaco"
SPEC_FILE="$WORK_DIR/memory_space_binary_probe.yaml"
HELPER_FILE="$WORK_DIR/memory_space_binary_probe_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/memory_space_plain.manifest.json"
IR_JSON="$WORK_DIR/memory_space_plain.ir.json"
PLAN_JSON="$WORK_DIR/memory_space_binary_probe.plan.json"
THUNK_SOURCE="$WORK_DIR/memory_space_binary_probe.thunks.hip"
THUNK_MANIFEST="$WORK_DIR/memory_space_binary_probe.thunks.json"
CARRIER_HSACO="$WORK_DIR/memory_space_binary_probe.carrier.hsaco"
CARRIER_REPORT="$WORK_DIR/memory_space_binary_probe.carrier.report.json"
CARRIER_MANIFEST="$WORK_DIR/memory_space_binary_probe.carrier.manifest.json"
RUNTIME_LOG="$WORK_DIR/memory_space_binary_probe.runtime.log"

cat > "$KERNEL_SOURCE" <<'HIP'
#include <hip/hip_runtime.h>
#include <stdint.h>

extern "C" __global__ void mixed_memory_kernel(uint32_t* data) {
    __shared__ uint32_t scratch[64];
    volatile uint32_t private_scratch[64];
    const uint32_t tid = threadIdx.x;
    const uint32_t value = tid + 1;
    private_scratch[tid] = value;
    const uint32_t staged = private_scratch[tid];
    scratch[tid] = staged;
    __syncthreads();
    const uint32_t loaded = scratch[tid];
    data[tid] = loaded;
}
HIP

cat > "$HOST_SOURCE" <<'CPP'
#include <hip/hip_runtime.h>

#include <cstdlib>
#include <iostream>
#include <vector>

#define CHECK_HIP(call)                                                       \
    do {                                                                      \
        hipError_t err = call;                                                \
        if (err != hipSuccess) {                                              \
            std::cerr << #call << " failed: " << hipGetErrorString(err)       \
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

    hipModule_t module;
    CHECK_HIP(hipModuleLoad(&module, hsaco_path));

    hipFunction_t kernel;
    CHECK_HIP(hipModuleGetFunction(&kernel, module, "mixed_memory_kernel"));

    constexpr size_t size = 64;
    uint32_t* d_data = nullptr;
    CHECK_HIP(hipMalloc(&d_data, size * sizeof(uint32_t)));
    CHECK_HIP(hipMemset(d_data, 0, size * sizeof(uint32_t)));

    void* args[] = {&d_data};
    CHECK_HIP(hipModuleLaunchKernel(
        kernel,
        1, 1, 1,
        size, 1, 1,
        0,
        nullptr,
        args,
        nullptr));
    CHECK_HIP(hipDeviceSynchronize());

    std::vector<uint32_t> h_data(size, 0);
    CHECK_HIP(hipMemcpy(
        h_data.data(),
        d_data,
        size * sizeof(uint32_t),
        hipMemcpyDeviceToHost));

    bool ok = true;
    for (size_t i = 0; i < size; ++i) {
        if (h_data[i] != static_cast<uint32_t>(i + 1)) {
            std::cerr << "mismatch at index " << i
                      << ": expected " << (i + 1)
                      << ", got " << h_data[i] << std::endl;
            ok = false;
            break;
        }
    }

    CHECK_HIP(hipFree(d_data));
    CHECK_HIP(hipModuleUnload(module));

    if (!ok) {
        std::cerr << "memory_space_host: FAIL" << std::endl;
        return 1;
    }
    std::cerr << "memory_space_host: PASS" << std::endl;
    return 0;
}
CPP

cat > "$SPEC_FILE" <<'SPEC'
version: 1

helpers:
  source: memory_space_binary_probe_helper.hip
  namespace: omniprobe_user

defaults:
  emission: vector
  lane_headers: false
  state: none

probes:
  - id: memory_space_binary_probe
    target:
      kernels: ["mixed_memory_kernel"]
      match:
        kind: isa_mnemonic
        values: [ds_load, ds_store, ds_read, ds_write, global_store, flat_store]
    inject:
      when: memory_op
      helper: memory_space_binary_probe_helper
      contract: memory_op_v1
    payload:
      mode: vector
      message: address
    capture:
      instruction: [address, bytes, addr_space, access_kind]
      kernel_args:
        - name: data
          type: u64
SPEC

cat > "$HELPER_FILE" <<'HELPER'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void memory_space_binary_probe_helper(
    const helper_args<omniprobe_user::memory_space_binary_probe_captures,
                      memory_op_event> &args) {
  if (args.event->bytes != sizeof(uint32_t)) {
    return;
  }

  const auto access = args.event->access;
  const auto address_space = args.event->address_space;
  const uintptr_t address = static_cast<uintptr_t>(args.event->address);

  if (address_space == address_space_kind::shared &&
      access == memory_access_kind::write) {
    dh_comms::v_submit_address(
        args.runtime->dh, reinterpret_cast<void *>(address), 0, 4666, 0,
        static_cast<uint8_t>(access), static_cast<uint8_t>(address_space),
        static_cast<uint16_t>(args.event->bytes), args.runtime->dh_builtins);
    return;
  }

  if (address_space == address_space_kind::shared &&
      access == memory_access_kind::read) {
    dh_comms::v_submit_address(
        args.runtime->dh, reinterpret_cast<void *>(address), 0, 4667, 0,
        static_cast<uint8_t>(access), static_cast<uint8_t>(address_space),
        static_cast<uint16_t>(args.event->bytes), args.runtime->dh_builtins);
    return;
  }

  if ((address_space == address_space_kind::global ||
       address_space == address_space_kind::flat) &&
      access == memory_access_kind::write) {
    dh_comms::v_submit_address(
        args.runtime->dh, reinterpret_cast<void *>(address), 0, 4777, 0,
        static_cast<uint8_t>(access), static_cast<uint8_t>(address_space),
        static_cast<uint16_t>(args.event->bytes), args.runtime->dh_builtins);
  }
}
HELPER

"$HIPCC" -x hip \
    --offload-device-only \
    --no-gpu-bundle-output \
    --offload-arch="$GPU_ARCH" \
    -Werror \
    -Wno-error=unused-parameter \
    -o "$PLAIN_HSACO" \
    "$KERNEL_SOURCE"

"$HIPCC" -std=c++17 -o "$HOST_BIN" "$HOST_SOURCE"

python3 "$INSPECT_CODE_OBJECT" "$PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$DISASM_TO_IR" \
    "$PLAIN_HSACO" \
    --manifest "$MANIFEST_JSON" \
    --output "$IR_JSON" >/dev/null
python3 "$PLAN_PROBE" \
    "$MANIFEST_JSON" \
    --ir "$IR_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --kernel mixed_memory_kernel \
    --output "$PLAN_JSON" >/dev/null
python3 - "$PLAN_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
kernel = next(
    entry for entry in payload.get("kernels", []) if entry.get("source_kernel") == "mixed_memory_kernel"
)
selected = []
seen = set()
global_fallback = None
for entry in kernel.get("planned_sites", []):
    event = entry.get("event_materialization", {})
    address_space = str(event.get("address_space", {}).get("value", ""))
    access = str(event.get("access_kind", {}).get("value", ""))
    bytes_value = int(event.get("bytes", {}).get("value", 0) or 0)
    if bytes_value != 4:
        continue
    key = None
    if address_space == "local" and access == "store":
        key = "local_store"
    elif address_space == "local" and access == "load":
        key = "local_load"
    elif address_space == "global" and access == "store":
        key = "global_like_store"
    elif address_space == "flat" and access == "store" and global_fallback is None:
        global_fallback = entry
    if key is None or key in seen:
        continue
    selected.append(entry)
    seen.add(key)
if "global_like_store" not in seen and global_fallback is not None:
    selected.append(global_fallback)
    seen.add("global_like_store")
if seen != {"local_store", "local_load", "global_like_store"}:
    raise SystemExit(
        f"expected local load/store and one global-like store, selected={sorted(seen)}"
    )
kernel["planned_sites"] = selected
json.dump(payload, open(path, "w", encoding="utf-8"), indent=2)
open(path, "a", encoding="utf-8").write("\n")
PY
python3 "$GENERATE_THUNKS" \
    "$PLAN_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --output "$THUNK_SOURCE" \
    --manifest-output "$THUNK_MANIFEST" >/dev/null
python3 "$REGENERATE_CODE_OBJECT" \
    "$PLAIN_HSACO" \
    --output "$CARRIER_HSACO" \
    --manifest "$MANIFEST_JSON" \
    --kernel mixed_memory_kernel \
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
echo "Binary Probe Memory-Op Address-Space Tests"
echo "================================================================================"
echo "  GPU arch: $GPU_ARCH"
echo "  Plain hsaco: $PLAIN_HSACO"
echo "  Carrier hsaco: $CARRIER_HSACO"
echo "  Plan: $PLAN_JSON"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_memory_op_address_space_build"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$PLAN_JSON" "$CARRIER_REPORT" "$CARRIER_MANIFEST" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
report = json.load(open(sys.argv[2], encoding="utf-8"))
manifest = json.load(open(sys.argv[3], encoding="utf-8"))

kernel = next(entry for entry in plan["kernels"] if entry.get("source_kernel") == "mixed_memory_kernel")
sites = kernel["planned_sites"]
assert len(sites) == 3
address_spaces = [site["event_materialization"]["address_space"]["value"] for site in sites]
assert address_spaces.count("local") == 2
assert any(value in {"global", "flat"} for value in address_spaces)
clone = report.get("clone_result", {})
assert clone.get("clone_kernel") == "__amd_crk_mixed_memory_kernel"
extra = report.get("extra_link_objects", [])
assert isinstance(extra, list) and extra
kernels = manifest["kernels"]["metadata"]["kernels"]
target = next(
    kernel
    for kernel in kernels
    if kernel.get("name") == "__amd_crk_mixed_memory_kernel"
    or kernel.get("symbol") == "__amd_crk_mixed_memory_kernel.kd"
)
args = target.get("args", [])
assert any(arg.get("name") == "hidden_omniprobe_ctx" for arg in args)
assert int(target.get("kernarg_segment_size", 0)) >= 16
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Mixed LDS/global memory-op regeneration produced a carrier clone"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Mixed LDS/global memory-op carrier regeneration metadata was not correct"
    echo "  Plan: $PLAN_JSON"
    echo "  Report: $CARRIER_REPORT"
    echo "  Manifest: $CARRIER_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_memory_op_address_space_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

LOGDUR_LOG_FORMAT=json \
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a AddressLogger \
    --hsaco-input "$PLAIN_HSACO" \
    --carrier-input "$CARRIER_HSACO" \
    --cache-location "$CACHE_DIR" \
    -- "$HOST_BIN" "$PLAIN_HSACO" > "$RUNTIME_LOG" 2>&1 \
    && run_status=0 || run_status=$?

if [ "$run_status" -ne 124 ] && \
   grep -q "Found instrumented alternative for mixed_memory_kernel" "$RUNTIME_LOG" && \
   grep -Eq '"dwarf_line":[[:space:]]*4666' "$RUNTIME_LOG" && \
   grep -Eq '"dwarf_line":[[:space:]]*4667' "$RUNTIME_LOG" && \
   grep -Eq '"dwarf_line":[[:space:]]*4777' "$RUNTIME_LOG" && \
   grep -Eq '"kernel_name":[[:space:]]*"mixed_memory_kernel.kd"' "$RUNTIME_LOG" && \
   ! grep -q "0 bytes processed" "$RUNTIME_LOG" && \
   grep -q "memory_space_host: PASS" "$RUNTIME_LOG" && \
   ! grep -q "Memory access fault by GPU" "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Memory-op carrier emitted host-visible dh_comms traffic for LDS loads, LDS stores, and global-like stores"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Memory-op carrier did not produce the expected mixed address-space dh_comms output"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
