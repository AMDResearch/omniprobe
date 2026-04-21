#!/bin/bash
################################################################################
# Binary-only support-wrapper ABI guard tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

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
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

GPU_ARCH="$("$AMDGPU_ARCH_TOOL" | head -n 1)"
if [ -z "$GPU_ARCH" ]; then
    echo -e "${YELLOW}SKIP: Could not determine active AMDGPU target${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/binary_probe_support_abi_guard"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

prepare_case() {
    local case_dir="$1"
    local kernel_source="$case_dir/kernel.hip"
    local plain_hsaco="$case_dir/kernel.hsaco"
    local spec_file="$case_dir/probe.yaml"
    local helper_file="$case_dir/helper.hip"
    local bundle_dir="$case_dir/bundle"
    local bundle_json="$bundle_dir/generated_probe_bundle.json"
    local manifest_json="$case_dir/kernel.manifest.json"
    local ir_json="$case_dir/kernel.ir.json"
    local plan_json="$case_dir/probe.plan.json"
    local thunk_source="$case_dir/probe.thunks.hip"
    local thunk_manifest="$case_dir/probe.thunks.json"

    mkdir -p "$case_dir" "$bundle_dir"

    cat > "$kernel_source" <<'HIP'
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

    cat > "$helper_file" <<'HELPER'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void memory_space_binary_probe_helper(
    const helper_args<omniprobe_user::memory_space_binary_probe_captures,
                      memory_op_event> &args) {
  (void)args;
}
HELPER

    cat > "$spec_file" <<'SPEC'
version: 1

helpers:
  source: helper.hip
  namespace: omniprobe_user

defaults:
  emission: vector
  lane_headers: true
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

    "$HIPCC" -x hip \
        --offload-device-only \
        --no-gpu-bundle-output \
        --offload-arch="$GPU_ARCH" \
        -Werror \
        -Wno-error=unused-parameter \
        -o "$plain_hsaco" \
        "$kernel_source"

    python3 "$INSPECT_CODE_OBJECT" "$plain_hsaco" --output "$manifest_json" >/dev/null
    python3 "$PREPARE_BUNDLE" "$spec_file" --output-dir "$bundle_dir" --skip-compile >/dev/null
    python3 "$DISASM_TO_IR" \
        "$plain_hsaco" \
        --manifest "$manifest_json" \
        --output "$ir_json" >/dev/null
    python3 "$PLAN_PROBE" \
        "$manifest_json" \
        --ir "$ir_json" \
        --probe-bundle "$bundle_json" \
        --kernel mixed_memory_kernel \
        --output "$plan_json" >/dev/null

    python3 - "$plan_json" <<'PY'
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
    raise SystemExit(f"expected local load/store and one global-like store, selected={sorted(seen)}")
kernel["planned_sites"] = selected
json.dump(payload, open(path, "w", encoding="utf-8"), indent=2)
open(path, "a", encoding="utf-8").write("\n")
PY

    python3 "$GENERATE_THUNKS" \
        "$plan_json" \
        --probe-bundle "$bundle_json" \
        --output "$thunk_source" \
        --manifest-output "$thunk_manifest" >/dev/null
}

run_regen() {
    local case_dir="$1"
    local plain_hsaco="$case_dir/kernel.hsaco"
    local manifest_json="$case_dir/kernel.manifest.json"
    local plan_json="$case_dir/probe.plan.json"
    local thunk_manifest="$case_dir/probe.thunks.json"
    local carrier_hsaco="$case_dir/carrier.hsaco"
    local carrier_report="$case_dir/carrier.report.json"

    python3 "$REGENERATE_CODE_OBJECT" \
        "$plain_hsaco" \
        --output "$carrier_hsaco" \
        --manifest "$manifest_json" \
        --kernel mixed_memory_kernel \
        --report-output "$carrier_report" \
        --add-hidden-abi-clone \
        --probe-plan "$plan_json" \
        --thunk-manifest "$thunk_manifest" \
        --hipcc "$HIPCC" \
        --llvm-mc "$LLVM_MC" \
        --ld-lld "$LD_LLD" \
        --clang-offload-bundler "$CLANG_OFFLOAD_BUNDLER"
}

echo ""
echo "================================================================================"
echo "Binary Probe Support ABI Guard Tests"
echo "================================================================================"
echo "  GPU arch: $GPU_ARCH"
echo "  Work dir: $WORK_DIR"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_support_abi_guard_accepts_simple_helper"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
SIMPLE_DIR="$WORK_DIR/simple"
prepare_case "$SIMPLE_DIR"
cat > "$SIMPLE_DIR/helper.hip" <<'HELPER'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void memory_space_binary_probe_helper(
    const helper_args<omniprobe_user::memory_space_binary_probe_captures,
                      memory_op_event> &args) {
  dh_comms::v_submit_address(
      args.runtime->dh,
      reinterpret_cast<void *>(static_cast<uintptr_t>(args.event->address)),
      0,
      4777,
      0,
      static_cast<uint8_t>(args.event->access),
      static_cast<uint8_t>(args.event->address_space),
      static_cast<uint16_t>(args.event->bytes),
      args.runtime->dh_builtins);
}
HELPER
if run_regen "$SIMPLE_DIR" >"$SIMPLE_DIR/regen.log" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Simple helper remained ABI-compatible with the source kernel"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Simple helper regeneration unexpectedly failed"
    cat "$SIMPLE_DIR/regen.log"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_support_abi_guard_rejects_extra_entry_state"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
HEAVY_DIR="$WORK_DIR/heavy"
prepare_case "$HEAVY_DIR"
cat > "$HEAVY_DIR/helper.hip" <<'HELPER'
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
if run_regen "$HEAVY_DIR" >"$HEAVY_DIR/regen.log" 2>&1; then
    echo -e "  ${RED}✗ FAIL${NC} - Heavy helper regeneration unexpectedly succeeded"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "binary probe support wrapper requires initial-kernel ABI state" "$HEAVY_DIR/regen.log" && \
     grep -q "enable_vgpr_workitem_id" "$HEAVY_DIR/regen.log"; then
    echo -e "  ${GREEN}✓ PASS${NC} - ABI guard rejected a helper that requested unsupported entry state"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Heavy helper failed for an unexpected reason"
    cat "$HEAVY_DIR/regen.log"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
