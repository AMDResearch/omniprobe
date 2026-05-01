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
MEMORY_HELPER_SOURCE="${SCRIPT_DIR}/probe_specs/helpers/memory_trace.hip"
BASIC_BLOCK_HELPER_SOURCE="${SCRIPT_DIR}/probe_specs/helpers/basic_block_timing.hip"
ENTRY_ABI_GFX1030_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json"
ENTRY_ABI_GFX1030_IR="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json"
ENTRY_ABI_GFX942_SINGLE_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json"
ENTRY_ABI_GFX942_SINGLE_IR="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json"

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
BUNDLE_MANIFEST="$BUNDLE_DIR/generated_probe_manifest.json"

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
assert sites["kernel_entry"]["helper_abi"]["schema"] == "omniprobe.helper_abi.v1"
assert sites["kernel_entry"]["helper_abi"]["model"] == "explicit_runtime_v1"
assert sites["kernel_entry"]["helper_abi"]["compiler_generated_liveins_allowed"] is False
assert sites["kernel_entry"]["helper_abi"]["compiler_generated_builtins_allowed"] is False
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
TEST_NAME="binary_probe_plan_requires_helper_abi"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BROKEN_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"

if python3 - "$BUNDLE_MANIFEST" "$BROKEN_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for entry in payload.get("surrogates", []):
    if isinstance(entry, dict):
        entry.pop("helper_abi", None)
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
then
    if python3 "$PLANNER" "$FIXTURE_MANIFEST" \
        --probe-manifest "$BROKEN_MANIFEST" \
        --kernel simple_kernel > "$OUTPUT_DIR/${TEST_NAME}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - Planner accepted a manifest without helper_abi"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q "missing helper_abi" "$OUTPUT_DIR/${TEST_NAME}.out"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Planner rejected manifests without helper_abi"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planner failed for an unexpected reason"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Could not generate broken manifest fixture"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_emits_source_entry_abi"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
ENTRY_ABI_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"
ENTRY_ABI_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 - "$FIXTURE_MANIFEST" "$ENTRY_ABI_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
payload["kernels"]["descriptors"] = [
    {
        "name": "simple_kernel.kd",
        "kernel_name": "simple_kernel",
        "compute_pgm_rsrc2": {
            "enable_sgpr_workgroup_id_x": 1,
            "enable_sgpr_workgroup_id_y": 0,
            "enable_sgpr_workgroup_id_z": 0,
            "enable_sgpr_workgroup_info": 0,
            "enable_vgpr_workitem_id": 0,
            "user_sgpr_count": 2
        },
        "kernel_code_properties": {
            "enable_sgpr_kernarg_segment_ptr": 1,
            "enable_sgpr_dispatch_id": 0
        }
    }
]
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
then
    if python3 "$PLANNER" "$ENTRY_ABI_MANIFEST" \
        --probe-bundle "$BUNDLE_JSON" \
        --kernel simple_kernel \
        --output "$ENTRY_ABI_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
        if python3 - "$ENTRY_ABI_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
kernel = payload["kernels"][0]
entry_abi = kernel["source_entry_abi"]
assert entry_abi["compute_pgm_rsrc2"]["enable_sgpr_workgroup_id_x"] == 1
assert entry_abi["compute_pgm_rsrc2"]["enable_sgpr_workgroup_id_y"] == 0
assert entry_abi["compute_pgm_rsrc2"]["enable_sgpr_workgroup_id_z"] == 0
assert entry_abi["compute_pgm_rsrc2"]["enable_vgpr_workitem_id"] == 0
assert entry_abi["entry_workitem_vgpr_count"] == 1
assert entry_abi["kernel_code_properties"]["enable_sgpr_dispatch_id"] == 0
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Planner includes source entry ABI shape for thunk generation"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Planner output did not contain the expected source_entry_abi payload"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planner failed on manifest with descriptor-backed source entry ABI"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Could not generate descriptor-backed manifest fixture"
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
           grep -q 'runtime.site_snapshot = &__omniprobe_site_snapshot_storage;' "$THUNK_SOURCE" && \
           grep -q 'entry_snapshot->workgroup_x = static_cast<uint32_t>(blockIdx.x);' "$THUNK_SOURCE" && \
           grep -q 'entry_snapshot->timestamp = timestamp;' "$THUNK_SOURCE" && \
           grep -q 'captures.data = static_cast<uint64_t>(capture_data);' "$THUNK_SOURCE" && \
           grep -q 'captures.size = static_cast<uint64_t>(capture_size);' "$THUNK_SOURCE" && \
           grep -q 'if (!(blockIdx.x == 0 && blockIdx.y == 0 && blockIdx.z == 0 &&' "$THUNK_SOURCE" && \
           grep -Fq 'const auto *__omniprobe_event_snapshot = runtime.entry_snapshot;' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_event_wavefront_size = __omniprobe_event_snapshot->wavefront_size;' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_dh_builtins.grid_dim_x = __omniprobe_has_grid_dim' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_dh_builtins.block_idx_x = __omniprobe_has_site_snapshot' "$THUNK_SOURCE" && \
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
TEST_NAME="binary_probe_thunks_require_helper_abi"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BROKEN_PLAN="$OUTPUT_DIR/${TEST_NAME}.plan.json"
BROKEN_THUNK_SOURCE="$OUTPUT_DIR/${TEST_NAME}.hip"

if python3 - "$LIFECYCLE_PLAN" "$BROKEN_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for kernel in payload.get("kernels", []):
    if not isinstance(kernel, dict):
        continue
    for site in kernel.get("planned_sites", []):
        if isinstance(site, dict):
            site.pop("helper_abi", None)
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
then
    if python3 "$THUNK_GENERATOR" "$BROKEN_PLAN" \
        --probe-bundle "$BUNDLE_JSON" \
        --output "$BROKEN_THUNK_SOURCE" > "$OUTPUT_DIR/${TEST_NAME}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - Thunk generator accepted a plan without helper_abi"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q "missing helper_abi" "$OUTPUT_DIR/${TEST_NAME}.out"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Thunk generator rejected plans without helper_abi"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Thunk generator failed for an unexpected reason"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Could not generate broken plan fixture"
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
TEST_NAME="binary_probe_plan_memory_op_local_and_global"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
MIXED_MEMORY_SPEC="$OUTPUT_DIR/${TEST_NAME}.yaml"
MIXED_MEMORY_IR="$OUTPUT_DIR/${TEST_NAME}.ir.json"
MIXED_MEMORY_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
MIXED_MEMORY_BUNDLE_JSON="$MIXED_MEMORY_BUNDLE_DIR/generated_probe_bundle.json"
MIXED_MEMORY_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$MIXED_MEMORY_BUNDLE_DIR"
mkdir -p "$MIXED_MEMORY_BUNDLE_DIR"

cat > "$MIXED_MEMORY_SPEC" <<YAML
version: 1

helpers:
  source: ${MEMORY_HELPER_SOURCE}
  namespace: omniprobe_user

defaults:
  emission: vector
  lane_headers: true
  state: none

probes:
  - id: mixed_memory_trace
    target:
      kernels: ["simple_kernel"]
      match:
        kind: isa_mnemonic
        values: [ds_load, ds_store, global_store]
    inject:
      when: memory_op
      helper: memory_trace_probe
      contract: memory_op_v1
    payload:
      mode: vector
      message: address
    capture:
      instruction: [address, bytes, addr_space, access_kind]
YAML

cat > "$MIXED_MEMORY_IR" <<'JSON'
{
  "input_file": "binary_probe_sites_local_global.s",
  "arch": "gfx1100",
  "functions": [
    {
      "name": "simple_kernel",
      "start_address": 4096,
      "instructions": [
        {
          "address": 4096,
          "mnemonic": "ds_store_b32",
          "operand_text": "v1, v0",
          "operands": ["v1", "v0"],
          "control_flow": "linear",
          "encoding_words": ["0xd81a0000"]
        },
        {
          "address": 4100,
          "mnemonic": "ds_load_b32",
          "operand_text": "v0, v1",
          "operands": ["v0", "v1"],
          "control_flow": "linear",
          "encoding_words": ["0xd86c0000"]
        },
        {
          "address": 4104,
          "mnemonic": "global_store_b32",
          "operand_text": "v2, v0, s[0:1]",
          "operands": ["v2", "v0", "s[0:1]"],
          "control_flow": "linear",
          "encoding_words": ["0xdc7c0000"]
        },
        {
          "address": 4108,
          "mnemonic": "s_endpgm",
          "operand_text": "",
          "operands": [],
          "control_flow": "return",
          "encoding_words": ["0xbf810000"]
        }
      ]
    }
  ]
}
JSON

if python3 "$PREPARE_BUNDLE" "$MIXED_MEMORY_SPEC" \
    --output-dir "$MIXED_MEMORY_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   python3 "$PLANNER" "$FIXTURE_MANIFEST" \
      --ir "$MIXED_MEMORY_IR" \
      --probe-bundle "$MIXED_MEMORY_BUNDLE_JSON" \
      --kernel simple_kernel \
      --output "$MIXED_MEMORY_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$MIXED_MEMORY_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is True
assert payload["planned_site_count"] == 3
assert payload["unsupported_site_count"] == 0
kernel = payload["kernels"][0]
sites = kernel["planned_sites"]
assert [site["injection_point"]["instruction_address"] for site in sites] == [4096, 4100, 4104]
assert [site["event_materialization"]["bytes"]["value"] for site in sites] == [4, 4, 4]
assert [site["event_materialization"]["access_kind"]["value"] for site in sites] == ["store", "load", "store"]
assert [site["event_materialization"]["address_space"]["value"] for site in sites] == ["local", "local", "global"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Memory-op planning recognizes LDS and global instruction families with correct widths"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Mixed LDS/global memory-op plan content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Mixed LDS/global memory-op planner unexpectedly failed"
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
TEST_NAME="binary_probe_plan_basic_block_gfx1030_mid_kernel_profile"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
GFX1030_SPEC="$OUTPUT_DIR/${TEST_NAME}.yaml"
GFX1030_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
GFX1030_BUNDLE_JSON="$GFX1030_BUNDLE_DIR/generated_probe_bundle.json"
GFX1030_IR="$OUTPUT_DIR/${TEST_NAME}.ir.json"
GFX1030_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$GFX1030_BUNDLE_DIR"
mkdir -p "$GFX1030_BUNDLE_DIR"

cat > "$GFX1030_SPEC" <<YAML
version: 1

helpers:
  source: ${BASIC_BLOCK_HELPER_SOURCE}
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: gfx1030_mid_kernel_profile
    target:
      kernels: ["entry_abi_kernel"]
    inject:
      when: basic_block
      helper: basic_block_timing_probe
      contract: basic_block_v1
    payload:
      mode: scalar
      message: time_interval
    capture:
      builtins: [dispatch_id]
YAML

if ! python3 - "$ENTRY_ABI_GFX1030_IR" "$GFX1030_IR" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
fn = payload["functions"][0]
instructions = fn["instructions"]
start = int(instructions[0]["address"])
mid = int(instructions[8]["address"])
end = int(instructions[-1]["address"]) + 4
fn["start_address"] = start
fn["end_address"] = end
fn["basic_blocks"] = [
    {
        "id": 0,
        "label": "bb0",
        "start_address": start,
        "end_address": mid,
    },
    {
        "id": 1,
        "label": "bb1",
        "start_address": mid,
        "end_address": end,
    },
]
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
then
    echo -e "  ${RED}✗ FAIL${NC} - Could not materialize gfx1030 CFG-backed IR fixture"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif python3 "$PREPARE_BUNDLE" "$GFX1030_SPEC" \
    --output-dir "$GFX1030_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   python3 "$PLANNER" "$ENTRY_ABI_GFX1030_MANIFEST" \
      --ir "$GFX1030_IR" \
      --probe-bundle "$GFX1030_BUNDLE_JSON" \
      --kernel entry_abi_kernel \
      --output "$GFX1030_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$GFX1030_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is True
assert payload["unsupported_site_count"] == 0
kernel = payload["kernels"][0]
resume = kernel["mid_kernel_resume_profile"]
assert resume["supported"] is True
assert resume["supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-mid-kernel-private-spill-v1"
assert "basic_block" in resume["supported_modes"]
assert len(kernel["planned_sites"]) == 1
site = kernel["planned_sites"][0]
site_resume = site["mid_kernel_resume_profile"]
assert site_resume["supported_class"] == resume["supported_class"]
assert site_resume["helper_policy"]["compiler_generated_liveins_allowed"] is False
state = site["site_state_requirements"]
assert state["schema"] == "omniprobe.site_state_requirements.v1"
assert state["supported"] is True
assert state["entry_dependencies"]["private_segment"]["pattern"] == "setreg_flat_scratch_init"
plan = site["site_resume_plan"]
assert plan["schema"] == "omniprobe.site_resume_plan.v1"
assert plan["supported"] is True
assert plan["storage"]["address_ops"] == "buffer"
assert plan["lowering_constraints"]["current_lowering_policy"]["vgpr_selection"] == "semantic_preserve_set_union"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planner attaches descriptor-backed gfx1030 mid-kernel resume classes to supported basic-block sites"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - gfx1030 mid-kernel resume profile planning content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - gfx1030 mid-kernel profile planning unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_basic_block_gfx942_rejects_unsupported_mid_kernel_profile"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
GFX942_SPEC="$OUTPUT_DIR/${TEST_NAME}.yaml"
GFX942_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
GFX942_BUNDLE_JSON="$GFX942_BUNDLE_DIR/generated_probe_bundle.json"
GFX942_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$GFX942_BUNDLE_DIR"
mkdir -p "$GFX942_BUNDLE_DIR"

cat > "$GFX942_SPEC" <<YAML
version: 1

helpers:
  source: ${BASIC_BLOCK_HELPER_SOURCE}
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: gfx942_mid_kernel_profile
    target:
      kernels: ["Cijk_S_GA"]
    inject:
      when: basic_block
      helper: basic_block_timing_probe
      contract: basic_block_v1
    payload:
      mode: scalar
      message: time_interval
    capture:
      builtins: [dispatch_id]
YAML

if python3 "$PREPARE_BUNDLE" "$GFX942_SPEC" \
    --output-dir "$GFX942_BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.bundle.out"; then
    if python3 "$PLANNER" "$ENTRY_ABI_GFX942_SINGLE_MANIFEST" \
        --ir "$ENTRY_ABI_GFX942_SINGLE_IR" \
        --probe-bundle "$GFX942_BUNDLE_JSON" \
        --kernel Cijk_S_GA \
        --output "$GFX942_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - Planner unexpectedly accepted an unsupported gfx942 mid-kernel resume shape"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif python3 - "$GFX942_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is False
assert payload["planned_site_count"] == 0
assert payload["unsupported_site_count"] > 0
kernel = payload["kernels"][0]
resume = kernel["mid_kernel_resume_profile"]
assert resume["supported"] is False
assert resume["supported_class"] is None
assert "missing-private-segment-wave-offset-livein" in resume["blockers"]
first = kernel["unsupported_sites"][0]
assert first["when"] == "basic_block"
assert "missing-private-segment-wave-offset-livein" in first["reason"]
assert first["site_state_requirements"]["schema"] == "omniprobe.site_state_requirements.v1"
assert first["site_resume_plan"]["supported"] is False
assert "missing-private-segment-wave-offset-livein" in first["site_resume_plan"]["blockers"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planner fail-closed rejected unsupported gfx942 mid-kernel resume sites before injection"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Unsupported gfx942 mid-kernel resume rejection details were incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Could not generate gfx942 mid-kernel profile probe bundle"
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
