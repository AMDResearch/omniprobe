#!/bin/bash
################################################################################
# Binary-only probe planning tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
GENERATOR="${REPO_ROOT}/tools/probes/generate_probe_surrogates.py"
PLANNER="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
THUNK_GENERATOR="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
FIXTURE_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/binary_probe_manifest.json"
FIXTURE_IR="${SCRIPT_DIR}/probe_specs/fixtures/binary_probe_sites.ir.json"
LIFECYCLE_SPEC="${SCRIPT_DIR}/probe_specs/kernel_timing_v1.yaml"
MEMORY_SPEC="${SCRIPT_DIR}/probe_specs/memory_trace_v1.yaml"
BASIC_BLOCK_SPEC="${SCRIPT_DIR}/probe_specs/basic_block_timing_v1.yaml"
CALL_SPEC="${SCRIPT_DIR}/probe_specs/call_trace_v1.yaml"

echo ""
echo "================================================================================"
echo "Binary Probe Planning Tests"
echo "================================================================================"
echo "  Bundle tool: $PREPARE_BUNDLE"
echo "  Planner: $PLANNER"
echo "================================================================================"

if [ ! -f "$PREPARE_BUNDLE" ] || [ ! -f "$GENERATOR" ] || [ ! -f "$PLANNER" ] || [ ! -f "$THUNK_GENERATOR" ] || [ ! -f "$FIXTURE_MANIFEST" ] || [ ! -f "$FIXTURE_IR" ]; then
    echo -e "${RED}ERROR: required planning artifacts are missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_bundle_skip_compile"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"

if python3 "$PREPARE_BUNDLE" "$LIFECYCLE_SPEC" \
    --output-dir "$BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$BUNDLE_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["compile_skipped"] is True
assert payload["helper_bitcode"] is None
assert payload["environment"]["OMNIPROBE_PROBE_MANIFEST"]
assert payload["environment"]["OMNIPROBE_PROBE_BITCODE"] == ""
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planning-only probe bundle generation succeeded"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planning-only bundle report shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Planning-only probe bundle generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_lifecycle"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
LIFECYCLE_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$PLANNER" "$FIXTURE_MANIFEST" \
    --probe-bundle "$BUNDLE_JSON" \
    --kernel simple_kernel \
    --output "$LIFECYCLE_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$LIFECYCLE_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["planning_only"] is True
assert payload["supported"] is True
assert payload["planned_site_count"] == 2
assert payload["unsupported_site_count"] == 0
assert payload["selected_kernel_count"] == 1
kernel = payload["kernels"][0]
assert kernel["source_kernel"] == "simple_kernel"
assert kernel["clone_kernel"].startswith("__amd_crk_")
sites = {site["when"]: site for site in kernel["planned_sites"]}
assert set(sites) == {"kernel_entry", "kernel_exit"}
entry_bindings = sites["kernel_entry"]["capture_bindings"]
assert [binding["kernel_arg_name"] for binding in entry_bindings] == ["data", "size"]
assert sites["kernel_entry"]["helper_context"]["builtins"] == [
    "grid_dim", "block_dim", "block_idx", "thread_idx", "dispatch_id"
]
assert sites["kernel_entry"]["event_usage"] == "dispatch_origin"
assert sites["kernel_exit"]["event_usage"] == "dispatch_origin"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Lifecycle probe planning resolved kernel targets and captures"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Lifecycle plan content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Lifecycle planner unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_generate_lifecycle_thunks"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
THUNK_SOURCE="$OUTPUT_DIR/${TEST_NAME}.hip"
THUNK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"

if python3 "$THUNK_GENERATOR" "$LIFECYCLE_PLAN" \
    --probe-bundle "$BUNDLE_JSON" \
    --output "$THUNK_SOURCE" \
    --manifest-output "$THUNK_MANIFEST" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$THUNK_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(payload["thunks"]) == 2
names = {entry["thunk"] for entry in payload["thunks"]}
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_entry_thunk" in names
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_exit_thunk" in names
PY
    then
        if grep -q '__omniprobe_binary_kernel_timing_simple_kernel_kernel_entry_thunk' "$THUNK_SOURCE" && \
           grep -q 'using namespace omniprobe_user;' "$THUNK_SOURCE" && \
           grep -q 'runtime.raw_hidden_ctx = hidden_ctx;' "$THUNK_SOURCE" && \
           grep -q 'runtime.entry_snapshot = &runtime_storage->entry_snapshot;' "$THUNK_SOURCE" && \
           grep -q 'runtime.dispatch_uniform = &runtime_storage->dispatch_uniform;' "$THUNK_SOURCE" && \
           grep -q 'entry_snapshot->workgroup_x = static_cast<uint32_t>(blockIdx.x);' "$THUNK_SOURCE" && \
           grep -q 'entry_snapshot->timestamp = timestamp;' "$THUNK_SOURCE" && \
           grep -q 'captures.data = static_cast<uint64_t>(capture_data);' "$THUNK_SOURCE" && \
           grep -q 'captures.size = static_cast<uint64_t>(capture_size);' "$THUNK_SOURCE" && \
           grep -q 'if (!(blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 &&' "$THUNK_SOURCE" && \
           grep -Fq 'const auto *__omniprobe_event_snapshot = runtime.entry_snapshot;' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_event_wavefront_size = __omniprobe_event_snapshot->wavefront_size;' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_dh_builtins.grid_dim_x = __omniprobe_has_grid_dim' "$THUNK_SOURCE" && \
           ! grep -q 'capture_builtin_snapshot' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_probe_kernel_timing_kernel_entry_surrogate(&runtime, &captures, timestamp, __omniprobe_event_workgroup_x, __omniprobe_event_workgroup_y, __omniprobe_event_workgroup_z, __omniprobe_event_thread_x, __omniprobe_event_thread_y, __omniprobe_event_thread_z, __omniprobe_event_block_dim_x, __omniprobe_event_block_dim_y, __omniprobe_event_block_dim_z, __omniprobe_event_lane_id, __omniprobe_event_wave_id, __omniprobe_event_wavefront_size, __omniprobe_event_hw_id, __omniprobe_event_exec_mask);' "$THUNK_SOURCE"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Lifecycle thunk source reconstructs captures from marshalled arguments and forwards to the shared surrogate"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Generated thunk source did not contain expected capture loads and surrogate calls"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Thunk manifest shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Lifecycle thunk generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_memory_op"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
MEMORY_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
MEMORY_BUNDLE_JSON="$MEMORY_BUNDLE_DIR/generated_probe_bundle.json"
MEMORY_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$MEMORY_BUNDLE_DIR"
mkdir -p "$MEMORY_BUNDLE_DIR"

if python3 "$PREPARE_BUNDLE" "$MEMORY_SPEC" \
    --output-dir "$MEMORY_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   python3 "$PLANNER" "$FIXTURE_MANIFEST" \
      --ir "$FIXTURE_IR" \
      --probe-bundle "$MEMORY_BUNDLE_JSON" \
      --kernel simple_kernel \
      --output "$MEMORY_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$MEMORY_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is True
assert payload["planned_site_count"] == 4
assert payload["unsupported_site_count"] == 0
kernel = payload["kernels"][0]
sites = kernel["planned_sites"]
assert len(sites) == 4
assert [site["injection_point"]["instruction_address"] for site in sites] == [4100, 4112, 4120, 4128]
assert [site["event_materialization"]["access_kind"]["value"] for site in sites] == ["load", "store", "store", "load"]
assert [site["event_materialization"]["address_space"]["value"] for site in sites] == ["global", "flat", "global", "flat"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Memory-op planning resolved stable binary instruction sites from IR"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Memory-op plan content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Memory-op planner unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_generate_memory_thunks"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
MEMORY_THUNK_SOURCE="$OUTPUT_DIR/${TEST_NAME}.hip"
MEMORY_THUNK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"

if python3 "$THUNK_GENERATOR" "$MEMORY_PLAN" \
    --probe-bundle "$MEMORY_BUNDLE_JSON" \
    --output "$MEMORY_THUNK_SOURCE" \
    --manifest-output "$MEMORY_THUNK_MANIFEST" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$MEMORY_THUNK_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(payload["thunks"]) == 1
entry = payload["thunks"][0]
assert entry["when"] == "memory_op"
assert entry["contract"] == "memory_op_v1"
names = [argument["name"] for argument in entry["call_arguments"]]
assert names == ["hidden_ctx", "capture_data", "capture_size", "address", "memory_info"]
assert entry["call_argument_dwords"] == 9
assert entry["binary_event_abi"] == "memory_op_compact_v1"
PY
    then
        if grep -q '__omniprobe_binary_memory_trace_simple_kernel_memory_op_thunk' "$MEMORY_THUNK_SOURCE" && \
           grep -q 'const uint32_t __omniprobe_event_bytes = static_cast<uint32_t>(memory_info & 0xffffu);' "$MEMORY_THUNK_SOURCE" && \
           grep -q '__omniprobe_probe_memory_trace_surrogate(&runtime, &captures, address, __omniprobe_event_bytes, __omniprobe_event_access_kind, __omniprobe_event_address_space);' "$MEMORY_THUNK_SOURCE"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Memory-op thunk generation deduplicated per-site wrappers and forwarded event arguments"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Memory-op thunk source did not contain expected wrapper logic"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Memory-op thunk manifest shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Memory-op thunk generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_basic_block"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BASIC_BLOCK_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
BASIC_BLOCK_BUNDLE_JSON="$BASIC_BLOCK_BUNDLE_DIR/generated_probe_bundle.json"
BASIC_BLOCK_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$BASIC_BLOCK_BUNDLE_DIR"
mkdir -p "$BASIC_BLOCK_BUNDLE_DIR"

if python3 "$PREPARE_BUNDLE" "$BASIC_BLOCK_SPEC" \
    --output-dir "$BASIC_BLOCK_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   python3 "$PLANNER" "$FIXTURE_MANIFEST" \
      --ir "$FIXTURE_IR" \
      --probe-bundle "$BASIC_BLOCK_BUNDLE_JSON" \
      --kernel simple_kernel \
      --output "$BASIC_BLOCK_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$BASIC_BLOCK_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is True
assert payload["planned_site_count"] == 4
kernel = payload["kernels"][0]
sites = kernel["planned_sites"]
assert [site["injection_point"]["block_id"] for site in sites] == [1, 2, 3, 4]
assert [site["injection_point"]["start_address"] for site in sites] == [4108, 4112, 4120, 4128]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Basic-block planning assigned stable block IDs from the CFG"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Basic-block plan content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Basic-block planner unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_and_generate_call_thunks"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
CALL_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
CALL_BUNDLE_JSON="$CALL_BUNDLE_DIR/generated_probe_bundle.json"
CALL_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
CALL_THUNK_SOURCE="$OUTPUT_DIR/${TEST_NAME}.hip"
CALL_THUNK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"
rm -rf "$CALL_BUNDLE_DIR"
mkdir -p "$CALL_BUNDLE_DIR"

if python3 "$PREPARE_BUNDLE" "$CALL_SPEC" \
    --output-dir "$CALL_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   python3 "$PLANNER" "$FIXTURE_MANIFEST" \
      --ir "$FIXTURE_IR" \
      --probe-bundle "$CALL_BUNDLE_JSON" \
      --kernel simple_kernel \
      --output "$CALL_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.plan.out" && \
   python3 "$THUNK_GENERATOR" "$CALL_PLAN" \
      --probe-bundle "$CALL_BUNDLE_JSON" \
      --output "$CALL_THUNK_SOURCE" \
      --manifest-output "$CALL_THUNK_MANIFEST" > "$OUTPUT_DIR/${TEST_NAME}.thunk.out"; then
    if python3 - "$CALL_PLAN" "$CALL_THUNK_MANIFEST" <<'PY'
import json
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
payload = json.load(open(sys.argv[2], encoding="utf-8"))
kernel = plan["kernels"][0]
sites = kernel["planned_sites"]
assert len(sites) == 2
assert [site["when"] for site in sites] == ["call_before", "call_after"]
assert [site["injection_point"]["callee"] for site in sites] == ["helper_target", "helper_target"]
assert len(payload["thunks"]) == 2
names = {entry["thunk"] for entry in payload["thunks"]}
assert "__omniprobe_binary_call_trace_simple_kernel_call_before_thunk" in names
assert "__omniprobe_binary_call_trace_simple_kernel_call_after_thunk" in names
PY
    then
        if grep -q '__omniprobe_probe_call_trace_call_before_surrogate(&runtime, &captures, timestamp, callee_id);' "$CALL_THUNK_SOURCE" && \
           grep -q '__omniprobe_probe_call_trace_call_after_surrogate(&runtime, &captures, timestamp, callee_id);' "$CALL_THUNK_SOURCE"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Call-site planning and thunk generation handled before/after insertion points"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Call thunk source did not contain expected wrapper logic"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Call planning or thunk manifest content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Call planning/thunk generation unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
