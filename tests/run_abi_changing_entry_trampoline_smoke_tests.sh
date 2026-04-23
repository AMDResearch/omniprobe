#!/bin/bash
################################################################################
# ABI-changing trampoline smoke tests
#
# Verifies the generated compiler-owned entry-trampoline path can:
#   1. plan an entry-only lifecycle probe for an existing hsaco
#   2. generate trampoline HIP source from the plan and probe bundle
#   3. compile the trampoline into a standalone hsaco
#   4. reconstruct runtime_storage_v2 into runtime_ctx
#   5. capture entry snapshot and dispatch-uniform state
#   6. invoke a helper that emits host-visible dh_comms traffic
#   7. continue into the prototype kernel body and preserve expected results
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe
OMNIPROBE_TIMEOUT="${OMNIPROBE_TIMEOUT:-20s}"

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
AMDGPU_ARCH_TOOL="${AMDGPU_ARCH_TOOL:-}"
if [ -z "$AMDGPU_ARCH_TOOL" ]; then
    for candidate in \
        /opt/rocm/llvm/bin/amdgpu-arch \
        /opt/rocm/bin/amdgpu-arch \
        /opt/rocm-7.2.0/lib/llvm/bin/amdgpu-arch
    do
        if [ -x "$candidate" ]; then
            AMDGPU_ARCH_TOOL="$candidate"
            break
        fi
    done
fi

MODULE_DH_COMMS_TEST="${BUILD_DIR}/tools/test_hip_module_dh_comms"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLAN_PROBE="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
GENERATE_ENTRY_TRAMPOLINES="${REPO_ROOT}/tools/codeobj/generate_entry_trampolines.py"
SUPPORT_COMPILER="${REPO_ROOT}/tools/codeobj/compile_binary_probe_support.py"
PLAN_TRAMPOLINE_DESCRIPTOR="${REPO_ROOT}/tools/codeobj/plan_entry_trampoline_descriptor.py"

if [ ! -x "$MODULE_DH_COMMS_TEST" ] || [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Required trampoline smoke artifacts are not built${NC}"
    echo "  Expected: $MODULE_DH_COMMS_TEST"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Build with: cmake --build build --target test_hip_module_dh_comms module_load_kernel_plain_hsaco"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ ! -x "$HIPCC" ] || [ ! -x "$AMDGPU_ARCH_TOOL" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm tools not found${NC}"
    echo "  Expected: $HIPCC"
    echo "  Expected: $AMDGPU_ARCH_TOOL"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

GPU_ARCH="$($AMDGPU_ARCH_TOOL | head -n 1)"
if [ -z "$GPU_ARCH" ]; then
    echo -e "${YELLOW}SKIP: Unable to detect GPU architecture${NC}"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/abi_changing_entry_trampoline_smoke"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_entry_runtime.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_entry_runtime_helper.hip"
BUNDLE_DIR="$WORK_DIR/bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
MANIFEST_JSON="$WORK_DIR/module_load_plain.manifest.json"
PLAN_JSON="$WORK_DIR/module_load_binary_entry_runtime.plan.json"
TRAMPOLINE_SOURCE="$WORK_DIR/module_load_binary_entry_runtime.trampoline.hip"
TRAMPOLINE_MANIFEST="$WORK_DIR/module_load_binary_entry_runtime.trampoline.json"
TRAMPOLINE_HSACO="$WORK_DIR/module_load_binary_entry_runtime.trampoline.hsaco"
TRAMPOLINE_CODEOBJ_MANIFEST="$WORK_DIR/module_load_binary_entry_runtime.trampoline.codeobj.json"
TRAMPOLINE_DESCRIPTOR_PLAN="$WORK_DIR/module_load_binary_entry_runtime.trampoline.descriptor_plan.json"
RUNTIME_LOG="$WORK_DIR/module_load_binary_entry_runtime.runtime.log"

cat > "$SPEC_FILE" <<'SPEC'
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
SPEC

cat > "$HELPER_FILE" <<'HELPER'
using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void module_load_binary_entry_runtime_probe(
    const helper_args<omniprobe_user::module_load_binary_entry_runtime_captures,
                      kernel_lifecycle_event> &args) {
  auto *data = reinterpret_cast<int *>(static_cast<uintptr_t>(args.captures->data));
  if (data != nullptr) {
    dh_comms::v_submit_address(
        args.runtime->dh, data, 0, 4601, 0,
        static_cast<uint8_t>(memory_access_kind::write),
        static_cast<uint8_t>(address_space_kind::global),
        static_cast<uint16_t>(sizeof(int)), args.runtime->dh_builtins);
  }
}
HELPER

python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" --output "$MANIFEST_JSON" >/dev/null
python3 "$PREPARE_BUNDLE" "$SPEC_FILE" --output-dir "$BUNDLE_DIR" --skip-compile >/dev/null
python3 "$PLAN_PROBE" \
    "$MANIFEST_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --kernel mlk \
    --output "$PLAN_JSON" >/dev/null
python3 "$GENERATE_ENTRY_TRAMPOLINES" \
    "$PLAN_JSON" \
    --probe-bundle "$BUNDLE_JSON" \
    --source-manifest "$MANIFEST_JSON" \
    --output "$TRAMPOLINE_SOURCE" \
    --manifest-output "$TRAMPOLINE_MANIFEST" \
    --body-template source-kernel-model-v1 \
    --body-data-param data \
    --body-size-param size \
    --body-pointee-type int \
    --body-value-expr 'static_cast<int>(idx)' >/dev/null

python3 "$SUPPORT_COMPILER" \
    --entry-trampoline-manifest "$TRAMPOLINE_MANIFEST" \
    --output "$TRAMPOLINE_HSACO" \
    --arch "$GPU_ARCH" \
    --output-format hsaco \
    --hipcc "$HIPCC" >/dev/null

python3 "$INSPECT_CODE_OBJECT" "$TRAMPOLINE_HSACO" --output "$TRAMPOLINE_CODEOBJ_MANIFEST" >/dev/null
python3 "$PLAN_TRAMPOLINE_DESCRIPTOR" \
    --original-manifest "$MANIFEST_JSON" \
    --original-kernel mlk \
    --trampoline-manifest "$TRAMPOLINE_CODEOBJ_MANIFEST" \
    --trampoline-kernel __omniprobe_trampoline_mlk \
    --expected-trampoline-manifest "$TRAMPOLINE_MANIFEST" \
    --expected-trampoline-kernel __omniprobe_trampoline_mlk \
    --output "$TRAMPOLINE_DESCRIPTOR_PLAN" >/dev/null

echo ""
echo "================================================================================"
echo "ABI-Changing Entry Trampoline Smoke Tests"
echo "================================================================================"
echo "  GPU arch: $GPU_ARCH"
echo "  Plain hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Plan: $PLAN_JSON"
echo "  Trampoline source: $TRAMPOLINE_SOURCE"
echo "  Trampoline hsaco: $TRAMPOLINE_HSACO"
echo "  Descriptor plan: $TRAMPOLINE_DESCRIPTOR_PLAN"
echo "  Launcher: $MODULE_DH_COMMS_TEST"
echo "================================================================================"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="abi_changing_entry_trampoline_generation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$TRAMPOLINE_MANIFEST" "$TRAMPOLINE_SOURCE" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
source = open(sys.argv[2], encoding="utf-8").read()
kernel = manifest["kernels"][0]
assert kernel["source_kernel"] == "mlk"
assert kernel["trampoline_kernel"] == "__omniprobe_trampoline_mlk"
assert kernel["prototype_body"] == "source-kernel-model-v1"
assert kernel["prototype_body_strategy"] == "source-kernel-model-device-call"
assert kernel["prototype_body_origin"] == "source-kernel-model"
assert kernel["prototype_body_model"] == "mlk-linear-index-store-v1"
assert kernel["prototype_body_function"] == "__omniprobe_source_model_body_mlk_v1"
assert kernel["prototype_body_handoff_struct"] == "__omniprobe_body_handoff_mlk_v1"
assert kernel["prototype_body_handoff_transport"] == "stack-struct-pointer"
contract = kernel["declared_body_handoff_contract"]
assert contract["original_kernel"] == "mlk"
assert contract["original_symbol"] == "mlk.kd"
assert contract["body_model"] == "mlk-linear-index-store-v1"
assert contract["kernarg_size"] > 0
assert contract["user_sgpr_count"] >= 0
assert "captured_parameters" in contract and len(contract["captured_parameters"]) == 2
assert "__omniprobe_probe_module_load_binary_entry_runtime_surrogate" in source
assert "__omniprobe_capture_entry_snapshot" in source
assert "runtime_storage_v2 *hidden_ctx" in source
assert "struct __omniprobe_body_handoff_mlk_v1" in source
assert "__device__ __noinline__ void __omniprobe_source_model_body_mlk_v1" in source
assert "__omniprobe_source_model_body_mlk_v1(const __omniprobe_body_handoff_mlk_v1 *handoff)" in source
assert "__omniprobe_body_handoff_mlk_v1 body_handoff{};" in source
assert "__omniprobe_source_model_body_mlk_v1(&body_handoff);" in source
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Trampoline generator emitted the expected kernel, surrogate wiring, and structured source-kernel-model handoff boundary"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Trampoline generator output did not contain the expected structure"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="abi_changing_entry_trampoline_descriptor_plan"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$TRAMPOLINE_DESCRIPTOR_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["original_kernel"] == "mlk"
assert payload["trampoline_kernel"] == "__omniprobe_trampoline_mlk"
assert payload["safe_for_phase3_handoff_prototype"] is True
assert payload["declared_body_handoff_matches_planner"] is True
assert payload["declared_body_handoff_mismatches"] == []
assert payload["merged_launch_candidate"]["kernarg_size"] >= payload["body_handoff_requirements"]["kernarg_size"]
assert payload["merged_launch_candidate"]["metadata"]["sgpr_count"] >= payload["original"]["actual_sgpr_count"]
assert payload["merged_launch_candidate"]["metadata"]["vgpr_count"] >= payload["original"]["actual_vgpr_count"]
policies = {entry["field"]: entry["policy"] for entry in payload["field_policies"]}
assert policies["kernarg_size"] == "launch-contract-only"
assert policies["kernel_code_properties.enable_wavefront_size32"] == "must-match"
assert policies["compute_pgm_rsrc2.enable_vgpr_workitem_id"] == "launch-contract-only"
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Compiled trampoline descriptor produces a coherent merged launch candidate and explicit body-handoff contract"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Descriptor planner rejected the compiled trampoline or produced an incoherent merge report"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="abi_changing_entry_trampoline_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

LOGDUR_LOG_FORMAT=json \
ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
timeout "$OMNIPROBE_TIMEOUT" \
    "$MODULE_DH_COMMS_TEST" \
    "$TRAMPOLINE_HSACO" \
    __omniprobe_trampoline_mlk \
    runtime-storage-explicit \
    --min-address-messages 1 >"$RUNTIME_LOG" 2>&1

if grep -q 'mode=runtime-storage-explicit' "$RUNTIME_LOG" && \
   grep -q 'address_messages=1' "$RUNTIME_LOG" && \
   grep -Eq 'entry_wavefront_size=[1-9][0-9]*' "$RUNTIME_LOG" && \
   grep -Eq 'dispatch_valid_mask=0x[0-9a-fA-F]*18' "$RUNTIME_LOG"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Generated compiler-owned trampoline captured runtime state, emitted dh_comms, and preserved kernel execution"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Generated compiler-owned trampoline did not produce the expected runtime evidence"
    cat "$RUNTIME_LOG" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
