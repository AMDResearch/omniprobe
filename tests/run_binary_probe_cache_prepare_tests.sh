#!/bin/bash
################################################################################
# Binary-only probe cache-preparation tests
#
# Verifies prepare_hsaco_cache.py can consume a probe YAML spec and produce a
# donor-free hidden-ABI probe carrier for supported lifecycle-exit sites.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PREPARE_HSACO_CACHE="${REPO_ROOT}/tools/codeobj/prepare_hsaco_cache.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
LLVM_READELF="${LLVM_READELF:-/opt/rocm/llvm/bin/llvm-readelf}"
LLVM_OBJDUMP="${LLVM_OBJDUMP:-/opt/rocm/llvm/bin/llvm-objdump}"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"

MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "${YELLOW}SKIP: Module-load hsaco artifact not built${NC}"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Build with: cmake --build build --target module_load_kernel_plain_hsaco"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ ! -x "$HIPCC" ] || [ ! -x "$LLVM_READELF" ] || [ ! -x "$LLVM_OBJDUMP" ] || \
   [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm toolchain components not found${NC}"
    echo "  Expected: $HIPCC"
    echo "  Expected: $LLVM_READELF"
    echo "  Expected: $LLVM_OBJDUMP"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

WORK_DIR="$OUTPUT_DIR/binary_probe_cache_prepare"
CACHE_DIR="$WORK_DIR/cache"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$CACHE_DIR"

SPEC_FILE="$WORK_DIR/module_load_binary_lifecycle.yaml"
HELPER_FILE="$WORK_DIR/module_load_binary_lifecycle_helper.hip"
SUMMARY_JSON="$WORK_DIR/cache_prepare.summary.json"
OUTPUT_MANIFEST="$WORK_DIR/cache_prepare.output.manifest.json"

cat > "$SPEC_FILE" <<'EOF'
version: 1

helpers:
  source: module_load_binary_lifecycle_helper.hip
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: module_load_binary_lifecycle
    target:
      kernels: ["mlk"]
    inject:
      when: [kernel_exit]
      helper: module_load_binary_lifecycle_probe
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

extern "C" __device__ void module_load_binary_lifecycle_probe(
    const helper_args<omniprobe_user::module_load_binary_lifecycle_captures,
                      kernel_lifecycle_event> &args) {
  if (blockIdx.x != 0 || blockIdx.y != 0 || blockIdx.z != 0 || threadIdx.x != 0 ||
      threadIdx.y != 0 || threadIdx.z != 0) {
    return;
  }

  auto *data = reinterpret_cast<int *>(static_cast<uintptr_t>(args.captures->data));
  data[0] = 1234;
}
EOF

echo ""
echo "================================================================================"
echo "Binary Probe Cache-Preparation Tests"
echo "================================================================================"
echo "  Source hsaco: $MODULE_LOAD_PLAIN_HSACO"
echo "  Cache dir: $CACHE_DIR"
echo "================================================================================"

python3 "$PREPARE_HSACO_CACHE" \
    "$MODULE_LOAD_PLAIN_HSACO" \
    --output-dir "$CACHE_DIR" \
    --kernel-filter '^mlk$' \
    --surrogate-mode donor-free \
    --probe-spec "$SPEC_FILE" \
    --hipcc "$HIPCC" \
    --llvm-readelf "$LLVM_READELF" \
    --llvm-objdump "$LLVM_OBJDUMP" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" > "$SUMMARY_JSON"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_cache_prepare_summary"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(summary) == 1
item = summary[0]
probe = item["probe_instrumentation"]
assert probe["status"] == "rewritten"
assert probe["supported"] is True
assert probe["rewrite_pending"] is False
kernel_rewrite = probe["kernel_rewrite"]["mlk"]
assert kernel_rewrite["supported"] is True
assert kernel_rewrite["instrumented"] is True
outputs = item["outputs"]
assert len(outputs) == 1
output = outputs[0]
assert output["mode"] == "probe-surrogate"
assert output["surrogate_mode"] == "donor-free"
assert output["probe_plan"]
assert output["thunk_manifest"]
assert output["thunk_source"]
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Cache preparation summary reports a completed probe rewrite"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Cache preparation summary did not describe the expected probe rewrite"
    echo "  Summary: $SUMMARY_JSON"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

OUTPUT_HSACO="$(python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
print(summary[0]["outputs"][0]["output"])
PY
)"
OUTPUT_REPORT="$(python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
print(summary[0]["outputs"][0]["report"])
PY
)"

python3 "$INSPECT_CODE_OBJECT" "$OUTPUT_HSACO" --llvm-readelf "$LLVM_READELF" --output "$OUTPUT_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_cache_prepare_output"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$OUTPUT_REPORT" "$OUTPUT_MANIFEST" <<'PY'
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
    echo -e "  ${GREEN}✓ PASS${NC} - Cache preparation emitted a hidden-ABI probe carrier with linked support metadata"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Prepared cache artifact metadata was not correct"
    echo "  Report: $OUTPUT_REPORT"
    echo "  Manifest: $OUTPUT_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
