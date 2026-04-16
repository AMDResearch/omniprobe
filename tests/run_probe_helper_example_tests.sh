#!/bin/bash
################################################################################
# Probe helper example tests
#
# Exercises practically useful v1 probe bundles:
#   1. memory trace
#   2. kernel timing stamps
#   3. basic-block timing stamps
#   4. call tracing
#
# Runtime smoke coverage is limited to paths that are currently wired through the
# generated-surrogate manifest flow. Today that means:
#   - memory_op_v1: full compile + runtime smoke
#   - kernel_lifecycle_v1: bundle compilation and compile-time selection checks
# Basic-block and call examples are still valuable bundle examples, but their
# generated-surrogate runtime plumbing is not yet converged.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

VALIDATOR="${REPO_ROOT}/tools/probes/validate_probe_spec.py"
GENERATOR="${REPO_ROOT}/tools/probes/generate_probe_surrogates.py"
PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"

MEMORY_SPEC="${SCRIPT_DIR}/probe_specs/memory_trace_v1.yaml"
KERNEL_TIMING_SPEC="${SCRIPT_DIR}/probe_specs/kernel_timing_v1.yaml"
BB_TIMING_SPEC="${SCRIPT_DIR}/probe_specs/basic_block_timing_v1.yaml"
CALL_TRACE_SPEC="${SCRIPT_DIR}/probe_specs/call_trace_v1.yaml"

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
HIP_ARCH="${HIP_ARCH:-gfx1030}"
DH_COMMS_INCLUDE_DIR="${REPO_ROOT}/external/dh_comms/include"
TEST_SOURCE="${REPO_ROOT}/tests/test_kernels/simple_heatmap_test.cpp"
TEST_INCLUDE_DIR="${REPO_ROOT}/tests/test_kernels"
ADDRESS_PLUGIN_SO="${BUILD_DIR}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"
LIFECYCLE_PLUGIN_SO="${BUILD_DIR}/lib/plugins/libAMDGCNSubmitKernelLifecycle-rocm.so"

echo ""
echo "================================================================================"
echo "Probe Helper Example Tests"
echo "================================================================================"
echo "  Validator: $VALIDATOR"
echo "  Generator: $GENERATOR"
echo "  Bundle tool: $PREPARE_BUNDLE"
echo "================================================================================"

if [ ! -f "$VALIDATOR" ] || [ ! -f "$GENERATOR" ] || [ ! -f "$PREPARE_BUNDLE" ]; then
    echo -e "${RED}ERROR: required probe tools are missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$OUTPUT_DIR/probe_helper_examples"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

CAN_PREPARE=0
if [ -x "$HIPCC" ] && [ -d "$DH_COMMS_INCLUDE_DIR" ]; then
    CAN_PREPARE=1
fi

run_example_validation() {
    local example_name="$1"
    local spec_path="$2"
    local expected_sites="$3"
    local expected_surrogates="$4"
    local expected_contracts="$5"
    local expected_messages="$6"
    local expected_builtins="$7"
    local expected_struct_fields="$8"
    local expected_event_fields="$9"

    local json_out="$WORK_DIR/${example_name}.normalized.json"
    local manifest_out="$WORK_DIR/${example_name}.manifest.json"
    local hip_out="$WORK_DIR/${example_name}.hip"
    local bundle_dir="$WORK_DIR/${example_name}.bundle"

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="${example_name}_schema"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

    if ! python3 "$VALIDATOR" "$spec_path" --json > "$json_out"; then
        echo -e "  ${RED}✗ FAIL${NC} - Validator rejected $spec_path"
        echo "  Output saved to: $json_out"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    fi

    if ! python3 "$GENERATOR" "$spec_path" \
        --hip-output "$hip_out" \
        --manifest-output "$manifest_out"; then
        echo -e "  ${RED}✗ FAIL${NC} - Generator failed for $spec_path"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    fi

    if python3 - "$manifest_out" "$expected_sites" "$expected_surrogates" \
        "$expected_contracts" "$expected_messages" "$expected_builtins" \
        "$expected_struct_fields" "$expected_event_fields" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
expected_sites = int(sys.argv[2])
expected_surrogates = [item for item in sys.argv[3].split(",") if item]
expected_contracts = {item for item in sys.argv[4].split(",") if item}
expected_messages = {item for item in sys.argv[5].split(",") if item}
expected_builtins = [item for item in sys.argv[6].split(",") if item]
expected_struct_fields = [item for item in sys.argv[7].split(",") if item]
expected_event_fields = [item for item in sys.argv[8].split(",") if item]

payload = json.load(open(manifest_path, encoding="utf-8"))
surrogates = payload["surrogates"]
assert len(surrogates) == expected_sites
names = {entry["surrogate"] for entry in surrogates}
for expected in expected_surrogates:
    assert expected in names
assert {entry["contract"] for entry in surrogates} == expected_contracts
assert {entry["payload"]["message"] for entry in surrogates} == expected_messages
helper_context = surrogates[0]["helper_context"]["builtins"]
assert helper_context == expected_builtins
struct_fields = [field["name"] if isinstance(field, dict) else field for field in surrogates[0]["capture_layout"]["struct_fields"]]
event_fields = surrogates[0]["capture_layout"]["event_fields"]
assert struct_fields == expected_struct_fields
assert event_fields == expected_event_fields
assert not any(field in struct_fields for field in expected_builtins)
PY
    then
        if [ -n "$expected_builtins" ] && \
           ! grep -q "Helper-visible execution context: ${expected_builtins//,/\, }" "$hip_out"; then
            echo -e "  ${RED}✗ FAIL${NC} - Generated surrogate source lost helper-context commentary"
            echo "  HIP output: $hip_out"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        else
            echo -e "  ${GREEN}✓ PASS${NC} - Schema and generated manifest/source match expectations"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Generated manifest did not match expectations"
        echo "  Manifest saved to: $manifest_out"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="${example_name}_bundle"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

    if [ "$CAN_PREPARE" -ne 1 ]; then
        echo -e "  ${YELLOW}SKIP${NC} - hipcc or dh_comms headers are unavailable for helper bitcode compilation"
        return
    fi

    if python3 "$PREPARE_BUNDLE" "$spec_path" \
        --output-dir "$bundle_dir" \
        --hipcc "$HIPCC" \
        --arch "$HIP_ARCH" > "$bundle_dir.prepare.json"; then
        if [ -f "$bundle_dir/generated_probe_helpers.bc" ] && \
           [ -f "$bundle_dir/generated_probe_manifest.json" ] && \
           [ -f "$bundle_dir/generated_probe_env.sh" ]; then
            echo -e "  ${GREEN}✓ PASS${NC} - Helper bundle compiled successfully"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Bundle outputs were incomplete"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Bundle preparation failed"
        echo "  Output saved to: $bundle_dir.prepare.json"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_example_validation \
    "memory_trace" \
    "$MEMORY_SPEC" \
    "1" \
    "__omniprobe_probe_memory_trace_surrogate" \
    "memory_op_v1" \
    "address" \
    "block_idx,thread_idx" \
    "data,size" \
    "address,bytes,addr_space,access_kind"

run_example_validation \
    "kernel_timing" \
    "$KERNEL_TIMING_SPEC" \
    "2" \
    "__omniprobe_probe_kernel_timing_kernel_entry_surrogate,__omniprobe_probe_kernel_timing_kernel_exit_surrogate" \
    "kernel_lifecycle_v1" \
    "time_interval" \
    "grid_dim,block_dim,block_idx,thread_idx,dispatch_id" \
    "data,size" \
    ""

run_example_validation \
    "basic_block_timing" \
    "$BB_TIMING_SPEC" \
    "1" \
    "__omniprobe_probe_basic_block_timing_surrogate" \
    "basic_block_v1" \
    "time_interval" \
    "block_idx,thread_idx,dispatch_id" \
    "size" \
    ""

run_example_validation \
    "call_trace" \
    "$CALL_TRACE_SPEC" \
    "2" \
    "__omniprobe_probe_call_trace_call_before_surrogate,__omniprobe_probe_call_trace_call_after_surrogate" \
    "call_v1" \
    "custom" \
    "dispatch_id" \
    "" \
    "callee"

if [ "$CAN_PREPARE" -eq 1 ] && [ -x "$ADDRESS_PLUGIN_SO" ] && [ -f "$TEST_SOURCE" ] && [ -x "$OMNIPROBE" ]; then
    MEMORY_BUNDLE_DIR="$WORK_DIR/memory_trace.bundle"
    MEMORY_BINARY="$WORK_DIR/memory_trace_example_test"
    MEMORY_COMPILE_LOG="$WORK_DIR/memory_trace.compile.log"
    MEMORY_RUNTIME_LOG="$WORK_DIR/memory_trace.runtime.log"

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="memory_trace_runtime_smoke"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

    OMNIPROBE_PROBE_MANIFEST="$MEMORY_BUNDLE_DIR/generated_probe_manifest.json" \
    OMNIPROBE_PROBE_BITCODE="$MEMORY_BUNDLE_DIR/generated_probe_helpers.bc" \
    "$HIPCC" -x hip -fgpu-rdc -g \
        -fpass-plugin="$ADDRESS_PLUGIN_SO" \
        -I"$TEST_INCLUDE_DIR" \
        -o "$MEMORY_BINARY" \
        "$TEST_SOURCE" > "$MEMORY_COMPILE_LOG" 2>&1

    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
        "$OMNIPROBE" -i -a AddressLogger -- "$MEMORY_BINARY" > "$MEMORY_RUNTIME_LOG" 2>&1

    if ! grep -q "Using generated memory-op surrogate __omniprobe_probe_memory_trace_surrogate" "$MEMORY_COMPILE_LOG"; then
        echo -e "  ${RED}✗ FAIL${NC} - Memory trace surrogate was not selected"
        echo "  Compile log: $MEMORY_COMPILE_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q "falling back to kernel-arg ordinal" "$MEMORY_COMPILE_LOG"; then
        echo -e "  ${RED}✗ FAIL${NC} - Memory trace capture resolution regressed to ordinal fallback"
        echo "  Compile log: $MEMORY_COMPILE_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q '"dwarf_line": 4101' "$MEMORY_RUNTIME_LOG"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Memory trace helper executed through the runtime path"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Runtime output did not contain the memory trace sentinel"
        echo "  Runtime log: $MEMORY_RUNTIME_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

if [ "$CAN_PREPARE" -eq 1 ] && [ -x "$LIFECYCLE_PLUGIN_SO" ] && [ -f "$TEST_SOURCE" ]; then
    KERNEL_BUNDLE_DIR="$WORK_DIR/kernel_timing.bundle"
    KERNEL_BINARY="$WORK_DIR/kernel_timing_example_test"
    KERNEL_COMPILE_LOG="$WORK_DIR/kernel_timing.compile.log"

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="kernel_timing_compile_path"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

    OMNIPROBE_PROBE_MANIFEST="$KERNEL_BUNDLE_DIR/generated_probe_manifest.json" \
    OMNIPROBE_PROBE_BITCODE="$KERNEL_BUNDLE_DIR/generated_probe_helpers.bc" \
    "$HIPCC" -x hip -fgpu-rdc -g \
        -fpass-plugin="$LIFECYCLE_PLUGIN_SO" \
        -I"$TEST_INCLUDE_DIR" \
        -o "$KERNEL_BINARY" \
        "$TEST_SOURCE" > "$KERNEL_COMPILE_LOG" 2>&1

    if ! grep -q "Using generated kernel-entry surrogate __omniprobe_probe_kernel_timing_kernel_entry_surrogate" "$KERNEL_COMPILE_LOG"; then
        echo -e "  ${RED}✗ FAIL${NC} - Kernel entry timing surrogate was not selected"
        echo "  Compile log: $KERNEL_COMPILE_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif ! grep -q "Using generated kernel-exit surrogate __omniprobe_probe_kernel_timing_kernel_exit_surrogate" "$KERNEL_COMPILE_LOG"; then
        echo -e "  ${RED}✗ FAIL${NC} - Kernel exit timing surrogate was not selected"
        echo "  Compile log: $KERNEL_COMPILE_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q "falling back to kernel-arg ordinal" "$KERNEL_COMPILE_LOG"; then
        echo -e "  ${RED}✗ FAIL${NC} - Kernel timing capture resolution regressed to ordinal fallback"
        echo "  Compile log: $KERNEL_COMPILE_LOG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}✓ PASS${NC} - Kernel timing example is selectable by the lifecycle pass"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
fi

print_summary
