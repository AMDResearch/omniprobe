#!/bin/bash
################################################################################
# Binary-only lifecycle injector tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLANNER="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
THUNK_GENERATOR="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
INJECTOR="${REPO_ROOT}/tools/codeobj/inject_probe_calls.py"
PLAN_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/binary_probe_manifest.json"
DESCRIPTOR_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_descriptor.manifest.json"
KERNEL_TIMING_HELPER="${SCRIPT_DIR}/probe_specs/helpers/kernel_timing.hip"

echo ""
echo "================================================================================"
echo "Binary Probe Injector Tests"
echo "================================================================================"
echo "  Injector: $INJECTOR"
echo "================================================================================"

if [ ! -f "$PREPARE_BUNDLE" ] || [ ! -f "$PLANNER" ] || [ ! -f "$THUNK_GENERATOR" ] || [ ! -f "$INJECTOR" ]; then
    echo -e "${RED}ERROR: required injector tooling is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

write_lifecycle_spec() {
    local output="$1"
    local when="$2"
    cat > "$output" <<EOF
version: 1

helpers:
  source: ${KERNEL_TIMING_HELPER}
  namespace: omniprobe_user

defaults:
  emission: scalar
  lane_headers: false
  state: none

probes:
  - id: kernel_timing
    target:
      kernels: ["simple_kernel"]
    inject:
      when: [${when}]
      helper: kernel_timing_probe
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
}

prepare_shared_artifacts() {
    local prefix="$1"
    local spec_path="$2"
    local bundle_dir="$OUTPUT_DIR/${prefix}_bundle"
    local bundle_json="$bundle_dir/generated_probe_bundle.json"
    local plan_json="$OUTPUT_DIR/${prefix}.plan.json"
    local thunk_manifest="$OUTPUT_DIR/${prefix}.thunks.json"
    local thunk_source="$OUTPUT_DIR/${prefix}.thunks.hip"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir"
    python3 "$PREPARE_BUNDLE" "$spec_path" --output-dir "$bundle_dir" --skip-compile > "$OUTPUT_DIR/${prefix}.bundle.out"
    python3 "$PLANNER" "$PLAN_MANIFEST" --probe-bundle "$bundle_json" --kernel simple_kernel --output "$plan_json" > "$OUTPUT_DIR/${prefix}.plan.out"
    python3 "$THUNK_GENERATOR" "$plan_json" --probe-bundle "$bundle_json" --output "$thunk_source" --manifest-output "$thunk_manifest" > "$OUTPUT_DIR/${prefix}.thunk.out"
}

EXIT_SPEC="$OUTPUT_DIR/binary_probe_injector_exit.yaml"
ENTRY_SPEC="$OUTPUT_DIR/binary_probe_injector_entry.yaml"
write_lifecycle_spec "$EXIT_SPEC" "kernel_exit"
write_lifecycle_spec "$ENTRY_SPEC" "kernel_entry"

prepare_shared_artifacts "binary_probe_injector_exit" "$EXIT_SPEC"
prepare_shared_artifacts "binary_probe_injector_entry" "$ENTRY_SPEC"

ENTRY_BACKEND_PLAN_JSON="$OUTPUT_DIR/binary_probe_injector_entry_backend.plan.json"
ENTRY_BACKEND_THUNK_JSON="$OUTPUT_DIR/binary_probe_injector_entry_backend.thunks.json"
ENTRY_BACKEND_MISSING_HELPER_ABI_PLAN_JSON="$OUTPUT_DIR/binary_probe_injector_entry_backend_missing_helper_abi.plan.json"
BASIC_BLOCK_BACKEND_PLAN_JSON="$OUTPUT_DIR/binary_probe_injector_basic_block_backend.plan.json"
BASIC_BLOCK_BACKEND_THUNK_JSON="$OUTPUT_DIR/binary_probe_injector_basic_block_backend.thunks.json"
BASIC_BLOCK_BACKEND_BUILTINS_PLAN_JSON="$OUTPUT_DIR/binary_probe_injector_basic_block_backend_builtins.plan.json"
BASIC_BLOCK_BACKEND_UNSUPPORTED_BUILTINS_PLAN_JSON="$OUTPUT_DIR/binary_probe_injector_basic_block_backend_unsupported_builtins.plan.json"

python3 - "$ENTRY_BACKEND_PLAN_JSON" "$ENTRY_BACKEND_THUNK_JSON" "$ENTRY_BACKEND_MISSING_HELPER_ABI_PLAN_JSON" <<'PY'
import json
import sys

helper_abi = {
    "schema": "omniprobe.helper_abi.v1",
    "model": "explicit_runtime_v1",
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "required_runtime_views": [],
    "helper_visible_sources": {
        "kernel_args": [],
        "instruction_fields": [],
        "builtins": {
            "requested": [],
            "provider": "runtime_ctx.dh_builtins",
        },
        "event_payload": {
            "contract": "kernel_lifecycle_v1",
            "when": ["kernel_entry"],
        },
    },
    "notes": [],
}

plan = {
    "kernels": [
        {
            "source_kernel": "entry_abi_kernel",
            "clone_kernel": "__amd_crk_entry_abi_kernel",
            "hidden_omniprobe_ctx": {
                "offset": 272,
            },
            "planned_sites": [
                {
                    "status": "planned",
                    "contract": "kernel_lifecycle_v1",
                    "when": "kernel_entry",
                    "helper_context": {
                        "builtins": [],
                    },
                    "helper_abi": helper_abi,
                }
            ],
        }
    ]
}

thunks = {
    "thunks": [
        {
            "source_kernel": "entry_abi_kernel",
            "when": "kernel_entry",
            "thunk": "__omniprobe_binary_kernel_timing_entry_abi_kernel_kernel_entry_thunk",
            "call_arguments": [
                {
                    "kind": "hidden_ctx",
                    "name": "hidden_ctx",
                    "c_type": "const void *",
                    "size_bytes": 8,
                    "vgprs": [0, 1],
                },
                {
                    "kind": "capture",
                    "name": "capture_data",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "kernel_arg_offset": 0,
                    "vgprs": [2, 3],
                },
                {
                    "kind": "capture",
                    "name": "capture_size",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "kernel_arg_offset": 8,
                    "vgprs": [4, 5],
                },
                {
                    "kind": "timestamp",
                    "name": "timestamp",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "vgprs": [6, 7],
                },
            ],
        }
    ]
}

json.dump(plan, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
open(sys.argv[1], "a", encoding="utf-8").write("\n")
broken_plan = json.loads(json.dumps(plan))
broken_plan["kernels"][0]["planned_sites"][0].pop("helper_abi", None)
json.dump(broken_plan, open(sys.argv[3], "w", encoding="utf-8"), indent=2)
open(sys.argv[3], "a", encoding="utf-8").write("\n")
json.dump(thunks, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY

python3 - "$BASIC_BLOCK_BACKEND_PLAN_JSON" "$BASIC_BLOCK_BACKEND_THUNK_JSON" "$BASIC_BLOCK_BACKEND_BUILTINS_PLAN_JSON" "$BASIC_BLOCK_BACKEND_UNSUPPORTED_BUILTINS_PLAN_JSON" <<'PY'
import json
import sys

helper_abi = {
    "schema": "omniprobe.helper_abi.v1",
    "model": "explicit_runtime_v1",
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "required_runtime_views": [],
    "helper_visible_sources": {
        "kernel_args": [],
        "instruction_fields": [],
        "builtins": {
            "requested": [],
            "provider": "runtime_ctx.dh_builtins",
        },
        "event_payload": {
            "contract": "basic_block_v1",
            "when": ["basic_block"],
        },
    },
    "notes": [],
}

plan = {
    "kernels": [
        {
            "source_kernel": "entry_abi_kernel",
            "clone_kernel": "__amd_crk_entry_abi_kernel",
            "hidden_omniprobe_ctx": {
                "offset": 272,
            },
            "planned_sites": [
                {
                    "status": "planned",
                    "contract": "basic_block_v1",
                    "when": "basic_block",
                    "binary_site_id": 0,
                    "helper_context": {
                        "builtins": [],
                    },
                    "helper_abi": helper_abi,
                    "injection_point": {
                        "kind": "basic_block",
                        "block_id": 0,
                        "block_label": "bb_0",
                        "start_address": 6400,
                        "end_address": 6500,
                    },
                    "event_materialization": {
                        "timestamp": {"kind": "dynamic_timestamp"},
                        "block_id": {"kind": "static_block_id", "value": 0},
                    },
                }
            ],
        }
    ]
}

plan_with_builtins = json.loads(json.dumps(plan))
plan_with_builtins["kernels"][0]["planned_sites"][0]["helper_context"]["builtins"] = ["block_idx", "thread_idx", "dispatch_id"]
plan_with_builtins["kernels"][0]["planned_sites"][0]["helper_abi"]["required_runtime_views"] = [
    "runtime_ctx.dh_builtins",
    "runtime_ctx.dispatch_id",
    "runtime_ctx.site_snapshot",
]
plan_with_builtins["kernels"][0]["planned_sites"][0]["helper_abi"]["helper_visible_sources"]["builtins"]["requested"] = [
    "block_idx", "thread_idx", "dispatch_id"
]

plan_with_unsupported_builtins = json.loads(json.dumps(plan))
plan_with_unsupported_builtins["kernels"][0]["planned_sites"][0]["helper_context"]["builtins"] = ["queue_ptr"]
plan_with_unsupported_builtins["kernels"][0]["planned_sites"][0]["helper_abi"]["required_runtime_views"] = [
    "runtime_ctx.dh_builtins"
]
plan_with_unsupported_builtins["kernels"][0]["planned_sites"][0]["helper_abi"]["helper_visible_sources"]["builtins"]["requested"] = [
    "queue_ptr"
]

thunks = {
    "thunks": [
        {
            "source_kernel": "entry_abi_kernel",
            "when": "basic_block",
            "thunk": "__omniprobe_binary_basic_block_entry_abi_kernel_basic_block_thunk",
            "call_arguments": [
                {
                    "kind": "hidden_ctx",
                    "name": "hidden_ctx",
                    "c_type": "const void *",
                    "size_bytes": 8,
                    "vgprs": [0, 1],
                },
                {
                    "kind": "capture",
                    "name": "capture_size",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "kernel_arg_offset": 8,
                    "vgprs": [2, 3],
                },
                {
                    "kind": "timestamp",
                    "name": "timestamp",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "vgprs": [4, 5],
                },
                {
                    "kind": "event",
                    "name": "block_id",
                    "c_type": "uint32_t",
                    "size_bytes": 4,
                    "vgprs": [6],
                },
            ],
        }
    ]
}

json.dump(plan, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
open(sys.argv[1], "a", encoding="utf-8").write("\n")
json.dump(thunks, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
json.dump(plan_with_builtins, open(sys.argv[3], "w", encoding="utf-8"), indent=2)
open(sys.argv[3], "a", encoding="utf-8").write("\n")
json.dump(plan_with_unsupported_builtins, open(sys.argv[4], "w", encoding="utf-8"), indent=2)
open(sys.argv[4], "a", encoding="utf-8").write("\n")
PY

make_high_vgpr_entry_manifest() {
    local input_manifest="$1"
    local output_manifest="$2"
    python3 - "$input_manifest" "$output_manifest" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
descriptor = manifest["kernels"]["descriptors"][0]
descriptor.setdefault("compute_pgm_rsrc1", {})["granulated_workitem_vgpr_count"] = 3
kernel = manifest["kernels"]["metadata"]["kernels"][0]
kernel["vgpr_count"] = 32
json.dump(manifest, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
}

make_split_entry_kernarg_fixture() {
    local input_ir="$1"
    local output_ir="$2"
    python3 - "$input_ir" "$output_ir" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
fn = payload["functions"][0]
first = fn["instructions"][0]
address = int(first.get("address", 0) or 0)
fn["instructions"].insert(
    0,
    {
        "address": max(0, address - 4),
        "mnemonic": "s_mov_b64",
        "operands": ["s[0:1]", "s[4:5]"],
    },
)
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
}

run_inject_test() {
    local arch="$1"
    local ir_fixture="$2"
    local expected_runtime_pair="$3"
    local expected_target_pair="$4"
    local expected_kernarg_pair="$5"
    local expected_entry_kernarg_pair="${6:-$expected_kernarg_pair}"
    local source_kind="${7:-observed}"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_${arch}"
    if [ "$source_kind" = "fallback" ]; then
        test_name="${test_name}_fallback"
    fi
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$OUTPUT_DIR/binary_probe_injector_exit.plan.json" \
        --thunk-manifest "$OUTPUT_DIR/binary_probe_injector_exit.thunks.json" \
        --manifest "$DESCRIPTOR_MANIFEST" \
        --function simple_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" "$expected_runtime_pair" "$expected_target_pair" "$expected_kernarg_pair" "$expected_entry_kernarg_pair" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_runtime = [int(part) for part in sys.argv[2].split(":")]
expected_target = [int(part) for part in sys.argv[3].split(":")]
expected_kernarg = [int(part) for part in sys.argv[4].split(":")]
expected_entry_kernarg = [int(part) for part in sys.argv[5].split(":")]
fn = payload["functions"][0]
meta = fn["instrumentation"]["lifecycle_exit_stub"]
assert meta["target_pair"] == expected_target
assert meta["kernarg_pair"] == expected_kernarg
assert meta["entry_kernarg_pair"] == expected_entry_kernarg
assert meta["call_source"] in {"observed", "synthetic_from_kernarg_base"}
timestamp_pair = meta["timestamp_pair"]
call_args = meta["call_arguments"]
assert [entry["kind"] for entry in call_args] == ["hidden_ctx", "capture", "capture", "timestamp"]
assert call_args[0]["vgprs"] == [0, 1]
assert call_args[1]["vgprs"] == [2, 3]
assert call_args[1]["kernel_arg_offset"] == 0
assert call_args[2]["vgprs"] == [4, 5]
assert call_args[2]["kernel_arg_offset"] == 8
assert call_args[3]["vgprs"] == [6, 7]
saved_args = meta["saved_call_arguments"]
assert [entry["kind"] for entry in saved_args] == ["hidden_ctx", "capture", "capture"]
assert saved_args[0]["saved_sgprs"] == [36, 37]
assert saved_args[0]["kernel_arg_offset"] == 16
assert saved_args[1]["saved_sgprs"] == [38, 39]
assert saved_args[2]["saved_sgprs"] == [40, 41]
assert meta["saved_sgpr_base"] == 36
assert meta["saved_sgpr_count"] == 6
assert meta["total_sgprs"] == 42
instructions = fn["instructions"]
entry_stub = []
for insn in instructions:
    if not insn.get("synthetic"):
        break
    entry_stub.append(insn)
assert len(entry_stub) == 3
assert entry_stub[0]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[0]["operand_text"].startswith("s[36:37]")
assert f"s[{expected_entry_kernarg[0]}:{expected_entry_kernarg[1]}]" in entry_stub[0]["operand_text"]
assert entry_stub[0]["operand_text"].endswith(", 0x10")
assert entry_stub[1]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[1]["operand_text"].startswith("s[38:39]")
assert f"s[{expected_entry_kernarg[0]}:{expected_entry_kernarg[1]}]" in entry_stub[1]["operand_text"]
assert entry_stub[1]["operand_text"].endswith(", 0x0")
assert entry_stub[2]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[2]["operand_text"].startswith("s[40:41]")
assert f"s[{expected_entry_kernarg[0]}:{expected_entry_kernarg[1]}]" in entry_stub[2]["operand_text"]
assert entry_stub[2]["operand_text"].endswith(", 0x8")
end_index = next(i for i, insn in enumerate(instructions) if insn["mnemonic"] == "s_endpgm")
stub = []
cursor = end_index - 1
while cursor >= 0 and instructions[cursor].get("synthetic"):
    stub.append(instructions[cursor])
    cursor -= 1
stub.reverse()
assert len(stub) == 14
assert stub[0]["mnemonic"] == "s_memtime"
assert stub[1]["mnemonic"] == "s_waitcnt"
assert stub[2]["mnemonic"] == "v_mov_b32_e32"
assert stub[2]["operand_text"] == "v0, s36"
assert stub[3]["operand_text"] == "v1, s37"
assert stub[4]["operand_text"] == "v2, s38"
assert stub[5]["operand_text"] == "v3, s39"
assert stub[6]["operand_text"] == "v4, s40"
assert stub[7]["operand_text"] == "v5, s41"
assert stub[8]["operand_text"] == f"v6, s{timestamp_pair[0]}"
assert stub[9]["operand_text"] == f"v7, s{timestamp_pair[1]}"
assert stub[-1]["mnemonic"] == "s_swappc_b64"
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_exit_thunk@rel32@lo+4" in stub[-3]["operand_text"]
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} exit stub injection used the inferred backend-specific register pairs"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} injected IR did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} injector execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_entry_inject_test() {
    local arch="$1"
    local ir_fixture="$2"
    local expected_kernarg_pair="$3"
    local source_kind="${4:-observed}"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_entry_${arch}"
    if [ "$source_kind" = "fallback" ]; then
        test_name="${test_name}_fallback"
    fi
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$OUTPUT_DIR/binary_probe_injector_entry.plan.json" \
        --thunk-manifest "$OUTPUT_DIR/binary_probe_injector_entry.thunks.json" \
        --manifest "$DESCRIPTOR_MANIFEST" \
        --function simple_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" "$expected_kernarg_pair" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_kernarg = [int(part) for part in sys.argv[2].split(":")]
fn = payload["functions"][0]
meta = fn["instrumentation"]["lifecycle_entry_stub"]
assert meta["when"] == "kernel_entry"
assert meta["call_source"] == "reserved_entry_stub_sgprs"
assert meta["kernarg_pair"] == expected_kernarg
assert meta["injected_before_instruction_address"] > 0
assert [entry["kind"] for entry in meta["call_arguments"]] == ["hidden_ctx", "capture", "capture", "timestamp"]
assert meta["call_arguments"][0]["vgprs"] == [0, 1]
assert meta["call_arguments"][1]["vgprs"] == [2, 3]
assert meta["call_arguments"][2]["vgprs"] == [4, 5]
assert meta["call_arguments"][3]["vgprs"] == [6, 7]
staged = meta["staged_call_arguments"]
assert [entry["kind"] for entry in staged] == ["hidden_ctx", "capture", "capture"]
assert staged[0]["staging_sgprs"] == [36, 37]
assert staged[0]["kernel_arg_offset"] == 16
assert staged[1]["staging_sgprs"] == [38, 39]
assert staged[1]["kernel_arg_offset"] == 0
assert staged[2]["staging_sgprs"] == [40, 41]
assert staged[2]["kernel_arg_offset"] == 8
assert meta["staging_sgpr_base"] == 36
assert meta["staging_sgpr_count"] == 10
assert meta["timestamp_pair"] == [42, 43]
assert meta["target_pair"] == [44, 45]
assert meta["kernarg_restore_pair"] == [46, 47]
assert meta["exec_restore_pair"] == [48, 49]
assert meta["total_sgprs"] == 50
instructions = fn["instructions"]
entry_stub = []
first_stub = next(i for i, insn in enumerate(instructions) if insn.get("synthetic"))
assert first_stub == meta["injected_before_instruction_index"]
cursor = first_stub
while cursor < len(instructions) and instructions[cursor].get("synthetic"):
    entry_stub.append(instructions[cursor])
    cursor += 1
assert len(entry_stub) == 26
assert entry_stub[0]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[0]["operand_text"].startswith("s[36:37]")
assert f"s[{expected_kernarg[0]}:{expected_kernarg[1]}]" in entry_stub[0]["operand_text"]
assert entry_stub[0]["operand_text"].endswith(", 0x10")
assert entry_stub[1]["mnemonic"] == "s_waitcnt"
assert entry_stub[2]["operand_text"] == "v0, s36"
assert entry_stub[3]["operand_text"] == "v1, s37"
assert entry_stub[4]["operand_text"].startswith("s[38:39]")
assert f"s[{expected_kernarg[0]}:{expected_kernarg[1]}]" in entry_stub[4]["operand_text"]
assert entry_stub[4]["operand_text"].endswith(", 0x0")
assert entry_stub[6]["operand_text"] == "v2, s38"
assert entry_stub[7]["operand_text"] == "v3, s39"
assert entry_stub[8]["operand_text"].startswith("s[40:41]")
assert f"s[{expected_kernarg[0]}:{expected_kernarg[1]}]" in entry_stub[8]["operand_text"]
assert entry_stub[8]["operand_text"].endswith(", 0x8")
assert entry_stub[10]["operand_text"] == "v4, s40"
assert entry_stub[11]["operand_text"] == "v5, s41"
assert entry_stub[12]["mnemonic"] == "s_memtime"
assert entry_stub[13]["mnemonic"] == "s_waitcnt"
assert entry_stub[14]["operand_text"] == "v6, s42"
assert entry_stub[15]["operand_text"] == "v7, s43"
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_entry_thunk@rel32@lo+4" in entry_stub[17]["operand_text"]
assert entry_stub[19]["operand_text"] == "s[48:49], exec"
assert entry_stub[20]["operand_text"] == "s46, s{}".format(expected_kernarg[0])
assert entry_stub[21]["operand_text"] == "s47, s{}".format(expected_kernarg[1])
assert entry_stub[-4]["mnemonic"] == "s_swappc_b64"
assert entry_stub[-4]["operand_text"] == "s[30:31], s[44:45]"
assert entry_stub[-3]["operand_text"] == "s{}, s46".format(expected_kernarg[0])
assert entry_stub[-2]["operand_text"] == "s{}, s47".format(expected_kernarg[1])
assert entry_stub[-1]["operand_text"] == "exec, s[48:49]"
assert instructions[cursor]["address"] == meta["injected_before_instruction_address"]
assert first_stub == 0
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} entry stub injection reserved fresh SGPRs and marshalled the thunk arguments"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} entry injected IR did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} entry injector execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_entry_backend_pattern_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"
    local expected_kernarg_pair="$4"
    local expected_workitem_pattern="$5"
    local expected_private_pattern="$6"
    local expected_private_offset="$7"
    local expected_setup_pattern="$8"
    local expected_restore_kind="$9"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_entry_backend_${arch}"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"

    local adjusted_manifest="$OUTPUT_DIR/${test_name}.manifest.json"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    make_high_vgpr_entry_manifest "$manifest_fixture" "$adjusted_manifest"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$ENTRY_BACKEND_PLAN_JSON" \
        --thunk-manifest "$ENTRY_BACKEND_THUNK_JSON" \
        --manifest "$adjusted_manifest" \
        --function entry_abi_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" "$expected_kernarg_pair" "$expected_workitem_pattern" "$expected_private_pattern" "$expected_private_offset" "$expected_setup_pattern" "$expected_restore_kind" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_kernarg = [int(part) for part in sys.argv[2].split(":")]
expected_workitem_pattern = sys.argv[3]
expected_private_pattern = sys.argv[4]
expected_private_offset = None if sys.argv[5] == "none" else int(sys.argv[5])
expected_setup_pattern = sys.argv[6]
expected_restore_kind = sys.argv[7]

fn = payload["functions"][0]
meta = fn["instrumentation"]["lifecycle_entry_stub"]
preserved = meta["preserved_workitem_vgprs"]
entry_abi = meta["entry_abi_analysis"]
assert meta["kernarg_pair"] == expected_kernarg
assert preserved["count"] == 3
assert preserved["packed_workitem_dest_vgpr"] is None
assert preserved["pattern_class"] == expected_workitem_pattern
assert preserved["private_segment_pattern_class"] == expected_private_pattern
assert preserved["private_segment_offset_source_sgpr"] == expected_private_offset
assert preserved["restore_mode"] == "direct"
assert entry_abi["observed_workitem_id_materialization"]["pattern_class"] == expected_workitem_pattern
assert entry_abi["observed_private_segment_materialization"]["pattern_class"] == expected_private_pattern

synthetic = [insn for insn in fn["instructions"] if insn.get("synthetic")]
texts = [f"{insn['mnemonic']} {insn.get('operand_text', '')}".strip() for insn in synthetic]
assert any(expected_setup_pattern in text for text in texts)
if expected_workitem_pattern == "direct_vgpr_xyz":
    assert any("buffer_store_dword v0" in text and "offset:528" in text for text in texts)
    assert any("buffer_store_dword v1" in text and "offset:532" in text for text in texts)
    assert any("buffer_store_dword v2" in text and "offset:536" in text for text in texts)
    assert any("buffer_load_dword v0" in text and "offset:528" in text for text in texts)
    assert any("buffer_load_dword v1" in text and "offset:532" in text for text in texts)
    assert any("buffer_load_dword v2" in text and "offset:536" in text for text in texts)
else:
    assert any("buffer_store_dword v0" in text and "offset:528" in text for text in texts)
    assert any("buffer_load_dword v0" in text and "offset:528" in text for text in texts)

if expected_restore_kind == "unpack":
    assert any("buffer_load_dword v1" in text and "offset:532" in text for text in texts)
    assert any("buffer_load_dword v2" in text and "offset:536" in text for text in texts)
elif expected_restore_kind == "restore_v0":
    assert not any("offset:532" in text and "buffer_load_dword v1" in text for text in texts)
    assert not any("offset:536" in text and "buffer_load_dword v2" in text for text in texts)
else:
    raise AssertionError(f"unknown expected restore kind {expected_restore_kind!r}")
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} entry injector followed the tracked workitem/private-segment backend pattern"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} backend-pattern entry injection did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} backend-pattern injector execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_entry_missing_helper_abi_rejection_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_entry_${arch}_reject_missing_helper_abi"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local adjusted_manifest="$OUTPUT_DIR/${test_name}.manifest.json"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    make_high_vgpr_entry_manifest "$manifest_fixture" "$adjusted_manifest"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$ENTRY_BACKEND_MISSING_HELPER_ABI_PLAN_JSON" \
        --thunk-manifest "$ENTRY_BACKEND_THUNK_JSON" \
        --manifest "$adjusted_manifest" \
        --function entry_abi_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} entry injector unexpectedly accepted a plan without helper_abi"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        if grep -q 'missing helper_abi' "$OUTPUT_DIR/${test_name}.out"; then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} entry injector rejected plans without helper_abi"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} missing-helper_abi rejection reason was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
}

run_basic_block_resume_rejection_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"
    local function_name="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_basic_block_${arch}_reject_unsupported_resume"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    local resume_plan_json="$OUTPUT_DIR/${test_name}.plan.json"
    local resume_thunk_json="$OUTPUT_DIR/${test_name}.thunks.json"
    python3 - "$resume_plan_json" "$resume_thunk_json" "$function_name" <<'PY'
import json
import sys

helper_abi = {
    "schema": "omniprobe.helper_abi.v1",
    "model": "explicit_runtime_v1",
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "required_runtime_views": [],
    "helper_visible_sources": {
        "kernel_args": [],
        "instruction_fields": [],
        "builtins": {
            "requested": [],
            "provider": "runtime_ctx.dh_builtins",
        },
        "event_payload": {
            "contract": "basic_block_v1",
            "when": ["basic_block"],
        },
    },
    "notes": [],
}

plan = {
    "kernels": [
        {
            "source_kernel": sys.argv[3],
            "clone_kernel": f"__amd_crk_{sys.argv[3]}",
            "hidden_omniprobe_ctx": {"offset": 0},
            "planned_sites": [
                {
                    "binary_site_id": 0,
                    "status": "planned",
                    "contract": "basic_block_v1",
                    "when": "basic_block",
                    "helper_context": {"builtins": []},
                    "helper_abi": helper_abi,
                    "event_materialization": {
                        "block_id": {"kind": "static_block_id", "value": 0},
                    },
                    "injection_point": {
                        "kind": "basic_block",
                        "block_id": 0,
                        "block_label": "bb0",
                        "start_address": 0,
                    },
                }
            ],
        }
    ]
}

thunks = {
    "thunks": [
        {
            "source_kernel": sys.argv[3],
            "thunk": f"__omniprobe_basic_block_{sys.argv[3]}_thunk",
            "when": "basic_block",
            "contract": "basic_block_v1",
            "helper_context": {
                "builtins": [],
            },
            "helper_abi": helper_abi,
            "capture_bindings": [],
            "call_layout": {
                "hidden_ctx": {"c_type": "runtime_ctx *", "size_bytes": 8},
                "capture": {"c_type": "void *", "size_bytes": 8},
                "timestamp": {"c_type": "uint64_t", "size_bytes": 8},
                "event": [{"name": "block_id", "c_type": "uint32_t", "size_bytes": 4}],
            },
            "call_arguments": [
                {
                    "kind": "hidden_ctx",
                    "name": "runtime",
                    "c_type": "runtime_ctx *",
                    "size_bytes": 8,
                    "kernel_arg_offset": 0,
                    "vgprs": [0, 1],
                },
                {
                    "kind": "capture",
                    "name": "captures",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "kernel_arg_offset": 8,
                    "vgprs": [2, 3],
                },
                {
                    "kind": "timestamp",
                    "name": "timestamp",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "vgprs": [4, 5],
                },
                {
                    "kind": "event",
                    "name": "block_id",
                    "c_type": "uint32_t",
                    "size_bytes": 4,
                    "vgprs": [6],
                },
            ],
        }
    ]
}

json.dump(plan, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
open(sys.argv[1], "a", encoding="utf-8").write("\n")
json.dump(thunks, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$resume_plan_json" \
        --thunk-manifest "$resume_thunk_json" \
        --manifest "$manifest_fixture" \
        --function "$function_name" \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block injector unexpectedly accepted an unsupported mid-kernel resume shape"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        if grep -q 'missing-private-segment-wave-offset-livein' "$OUTPUT_DIR/${test_name}.out"; then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} basic-block injector rejected kernels without the required private-segment resume facts"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} unsupported-resume rejection reason was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
}

run_basic_block_src_private_base_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"
    local function_name="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_basic_block_${arch}_src_private_base"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    local plan_json="$OUTPUT_DIR/${test_name}.plan.json"
    local thunk_json="$OUTPUT_DIR/${test_name}.thunks.json"

    python3 - "$ir_fixture" "$plan_json" "$thunk_json" "$function_name" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
function_name = sys.argv[4]
function = next(entry for entry in payload["functions"] if entry.get("name") == function_name)
start_address = int(function["instructions"][0]["address"])

helper_abi = {
    "schema": "omniprobe.helper_abi.v1",
    "model": "explicit_runtime_v1",
    "compiler_generated_liveins_allowed": False,
    "compiler_generated_builtins_allowed": False,
    "requires_wrapper_captured_state": True,
    "requires_runtime_dispatch_payload": True,
    "required_runtime_views": [],
    "helper_visible_sources": {
        "kernel_args": [],
        "instruction_fields": [],
        "builtins": {
            "requested": [],
            "provider": "runtime_ctx.dh_builtins",
        },
        "event_payload": {
            "contract": "basic_block_v1",
            "when": ["basic_block"],
        },
    },
    "notes": [],
}

plan = {
    "kernels": [
        {
            "source_kernel": function_name,
            "clone_kernel": f"__amd_crk_{function_name}",
            "hidden_omniprobe_ctx": {"offset": 224},
            "planned_sites": [
                {
                    "binary_site_id": 0,
                    "status": "planned",
                    "contract": "basic_block_v1",
                    "when": "basic_block",
                    "helper_context": {"builtins": []},
                    "helper_abi": helper_abi,
                    "event_materialization": {
                        "timestamp": {"kind": "dynamic_timestamp"},
                        "block_id": {"kind": "static_block_id", "value": 0},
                    },
                    "injection_point": {
                        "kind": "basic_block",
                        "block_id": 0,
                        "block_label": "bb0",
                        "start_address": start_address,
                    },
                }
            ],
        }
    ]
}

thunks = {
    "thunks": [
        {
            "source_kernel": function_name,
            "clone_kernel": f"__amd_crk_{function_name}",
            "thunk": f"__omniprobe_basic_block_{function_name}_thunk",
            "when": "basic_block",
            "contract": "basic_block_v1",
            "helper_context": {"builtins": []},
            "helper_abi": helper_abi,
            "capture_bindings": [],
            "call_arguments": [
                {
                    "kind": "hidden_ctx",
                    "name": "hidden_ctx",
                    "c_type": "const void *",
                    "size_bytes": 8,
                    "dword_count": 2,
                    "kernel_arg_offset": 224,
                    "vgprs": [0, 1],
                },
                {
                    "kind": "timestamp",
                    "name": "timestamp",
                    "c_type": "uint64_t",
                    "size_bytes": 8,
                    "dword_count": 2,
                    "vgprs": [2, 3],
                },
                {
                    "kind": "event",
                    "name": "block_id",
                    "c_type": "uint32_t",
                    "size_bytes": 4,
                    "dword_count": 1,
                    "vgprs": [4],
                },
            ],
        }
    ]
}

json.dump(plan, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
json.dump(thunks, open(sys.argv[3], "w", encoding="utf-8"), indent=2)
open(sys.argv[3], "a", encoding="utf-8").write("\n")
PY

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$plan_json" \
        --thunk-manifest "$thunk_json" \
        --manifest "$manifest_fixture" \
        --function "$function_name" \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" "$function_name" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
function_name = sys.argv[2]
fn = next(entry for entry in payload["functions"] if entry.get("name") == function_name)
meta = fn["instrumentation"]["basic_block_stubs"]
spill = meta["preserved_low_vgprs"]
resume = meta["mid_kernel_resume_profile"]

assert spill["private_segment_pattern_class"] == "src_private_base"
assert spill["private_segment_offset_source_sgpr"] == 11
expected_addr_lo = len(spill["source_vgprs"])
if expected_addr_lo % 2:
    expected_addr_lo += 1
assert spill["address_vgprs"] == [expected_addr_lo, expected_addr_lo + 1]
assert spill["required_total_vgprs"] == expected_addr_lo + 2
assert meta["total_vgprs"] == expected_addr_lo + 2
assert meta["total_vgprs"] > len(spill["source_vgprs"])
assert resume["supported_class"] == "wave64-direct-vgpr-xyz-src-private-base-mid-kernel-private-spill-v1"

site = meta["injected_sites"][0]
instructions = fn["instructions"]
cursor = site["original_instruction_index"]
synthetic_before = []
while cursor < len(instructions) and instructions[cursor].get("synthetic"):
    synthetic_before.append(instructions[cursor])
    cursor += 1
assert synthetic_before
texts = [f"{insn['mnemonic']} {insn.get('operand_text', '')}".strip() for insn in synthetic_before]
addr_pair = f"v[{expected_addr_lo}:{expected_addr_lo + 1}]"
assert any(text == "s_mov_b64 s[0:1], src_private_base" for text in texts)
assert any(text == "s_add_u32 s0, s0, s11" for text in texts)
assert any(text == f"v_mov_b32_e32 v{expected_addr_lo}, s0" for text in texts)
assert any(text == f"v_mov_b32_e32 v{expected_addr_lo + 1}, s1" for text in texts)
assert any(text == f"flat_store_dword {addr_pair}, v0" for text in texts)
assert any(text == f"flat_load_dword v0, {addr_pair}" for text in texts)
assert not any("buffer_store_dword" in text and "s[0:3]" in text for text in texts)
assert not any("buffer_load_dword" in text and "s[0:3]" in text for text in texts)
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} basic-block injector uses flat-address private spills for src_private_base mid-kernel resumes"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} src_private_base basic-block injection did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} src_private_base basic-block injector execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_basic_block_inject_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_basic_block_${arch}"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local adjusted_manifest="$OUTPUT_DIR/${test_name}.manifest.json"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    make_high_vgpr_entry_manifest "$manifest_fixture" "$adjusted_manifest"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$BASIC_BLOCK_BACKEND_PLAN_JSON" \
        --thunk-manifest "$BASIC_BLOCK_BACKEND_THUNK_JSON" \
        --manifest "$adjusted_manifest" \
        --function entry_abi_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
fn = payload["functions"][0]
meta = fn["instrumentation"]["basic_block_stubs"]
assert meta["mode"] == "basic_block"
assert meta["when"] == "basic_block"
assert meta["contract"] == "basic_block_v1"
assert meta["call_source"] == "reserved_mid_kernel_stub_sgprs"
assert meta["kernarg_pair"] == [4, 5]
assert [entry["kind"] for entry in meta["call_arguments"]] == ["hidden_ctx", "capture", "timestamp", "event"]
assert meta["call_arguments"][0]["vgprs"] == [0, 1]
assert meta["call_arguments"][1]["vgprs"] == [2, 3]
assert meta["call_arguments"][2]["vgprs"] == [4, 5]
assert meta["call_arguments"][3]["vgprs"] == [6]
staged = meta["staged_call_arguments"]
assert [entry["kind"] for entry in staged] == ["hidden_ctx", "capture"]
assert meta["saved_kernarg_pair"] == [64, 65]
assert staged[0]["staging_sgprs"] == [66, 67]
assert staged[0]["kernel_arg_offset"] == 272
assert staged[1]["staging_sgprs"] == [68, 69]
assert staged[1]["kernel_arg_offset"] == 8
assert meta["timestamp_pair"] == [70, 71]
assert meta["target_pair"] == [72, 73]
assert meta["scratch_restore_pair"] == [74, 75]
assert meta["return_restore_pair"] == [76, 77]
assert meta["exec_restore_pair"] == [78, 79]
assert meta["vcc_restore_pair"] == [80, 81]
assert meta["m0_restore_sgpr"] == 82
assert meta["total_sgprs"] == 84
spill = meta["preserved_low_vgprs"]
assert spill["source_vgprs"] == list(range(32))
assert spill["spill_offset"] == 528
assert spill["spill_bytes"] == 128
assert spill["source_sgprs"] == list(range(2, 26)) + [64, 65]
assert spill["sgpr_spill_offset"] == 656
assert spill["sgpr_spill_bytes"] == 104
assert spill["private_segment_growth"] == 240
assert spill["private_segment_pattern_class"] == "flat_scratch_alias_init"
assert spill["private_segment_offset_source_sgpr"] == 11
resume = meta["mid_kernel_resume_profile"]
assert resume["supported"] is True
assert resume["supported_class"] == "wave64-packed-v0-10_10_10-unpack-flat-scratch-alias-mid-kernel-private-spill-v1"
assert resume["resume_requirements"]["spill_storage_class"] == "private_segment_tail"
assert "runtime.site_snapshot" in resume["resume_requirements"]["helper_runtime_views"]
sites = meta["injected_sites"]
assert [site["block_id"] for site in sites] == [0]
assert [site["start_address"] for site in sites] == [6400]
instructions = fn["instructions"]
assert instructions[0]["mnemonic"] == "s_mov_b64"
assert instructions[0]["operand_text"] == "s[64:65], s[4:5]"
for site in sites:
    start = site["start_address"]
    original_index = site["original_instruction_index"]
    synthetic_before = []
    cursor = original_index
    while cursor < len(instructions) and instructions[cursor].get("synthetic"):
        synthetic_before.append(instructions[cursor])
        cursor += 1
    assert synthetic_before, f"missing stub before block start {start}"
    assert instructions[cursor]["address"] == start
    assert any(insn["mnemonic"] == "s_memtime" for insn in synthetic_before)
    assert any(
        insn["mnemonic"] == "v_mov_b32_e32" and insn["operand_text"] == f"v6, {site['block_id']}"
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "s_mov_b64" and insn["operand_text"] == "s[76:77], s[30:31]"
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "s_mov_b64" and insn["operand_text"] == "s[64:65], s[2:3]"
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "s_mov_b64" and insn["operand_text"] == "exec, s[78:79]"
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "s_mov_b64" and insn["operand_text"] == "s[2:3], s[64:65]"
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "buffer_store_dword" and "offset:552" in insn["operand_text"]
        for insn in synthetic_before
    )
    assert any(
        insn["mnemonic"] == "buffer_load_dword" and "offset:552" in insn["operand_text"]
        for insn in synthetic_before
    )
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} basic-block injector inserted mid-kernel thunk calls at each planned block leader"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block injected IR did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block injector execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_basic_block_builtin_acceptance_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_basic_block_${arch}_accept_builtins"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local adjusted_manifest="$OUTPUT_DIR/${test_name}.manifest.json"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    make_high_vgpr_entry_manifest "$manifest_fixture" "$adjusted_manifest"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$BASIC_BLOCK_BACKEND_BUILTINS_PLAN_JSON" \
        --thunk-manifest "$BASIC_BLOCK_BACKEND_THUNK_JSON" \
        --manifest "$adjusted_manifest" \
        --function entry_abi_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out" 2>&1; then
        if python3 - "$out_ir" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
fn = payload["functions"][0]
meta = fn["instrumentation"]["basic_block_stubs"]
assert meta["call_arguments"][0]["kind"] == "hidden_ctx"
assert meta["call_arguments"][1]["kind"] == "capture"
assert meta["call_arguments"][2]["kind"] == "timestamp"
assert meta["call_arguments"][3]["kind"] == "event"
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} basic-block injector now accepts helper builtins that map onto Omniprobe runtime state"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} accepted helper builtins but produced malformed instrumentation metadata"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block injector rejected supported helper builtins unexpectedly"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_basic_block_unsupported_builtin_rejection_test() {
    local arch="$1"
    local ir_fixture="$2"
    local manifest_fixture="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_basic_block_${arch}_reject_unsupported_builtins"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local adjusted_manifest="$OUTPUT_DIR/${test_name}.manifest.json"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"
    make_high_vgpr_entry_manifest "$manifest_fixture" "$adjusted_manifest"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$BASIC_BLOCK_BACKEND_UNSUPPORTED_BUILTINS_PLAN_JSON" \
        --thunk-manifest "$BASIC_BLOCK_BACKEND_THUNK_JSON" \
        --manifest "$adjusted_manifest" \
        --function entry_abi_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block injector unexpectedly accepted unsupported helper builtins"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        if grep -q 'unsupported builtins: queue_ptr' "$OUTPUT_DIR/${test_name}.out"; then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} basic-block injector still fails closed for helper builtins outside the Omniprobe runtime contract"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} basic-block unsupported-builtin rejection reason was incorrect"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
}

make_fallback_fixture() {
    local input_ir="$1"
    local output_ir="$2"
    python3 - "$input_ir" "$output_ir" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
fn = payload["functions"][0]
fn["instructions"] = [
    insn
    for insn in fn["instructions"]
    if insn.get("mnemonic")
    not in {"s_getpc_b64", "s_add_u32", "s_addc_u32", "s_swappc_b64", "v_mov_b32_e32"}
]
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
}

make_fallback_fixture \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" \
    "$OUTPUT_DIR/binary_probe_injector_gfx1030_fallback.ir.json"
make_fallback_fixture \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" \
    "$OUTPUT_DIR/binary_probe_injector_gfx90a_fallback.ir.json"
make_fallback_fixture \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" \
    "$OUTPUT_DIR/binary_probe_injector_gfx942_fallback.ir.json"
make_split_entry_kernarg_fixture \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" \
    "$OUTPUT_DIR/binary_probe_injector_gfx942_split_entry.ir.json"

run_inject_test "gfx1030" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" "8:9" "14:15" "4:5"
run_inject_test "gfx90a" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" "8:9" "14:15" "4:5"
run_inject_test "gfx942" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" "4:5" "10:11" "0:1"
run_inject_test "gfx942_split_entry" "$OUTPUT_DIR/binary_probe_injector_gfx942_split_entry.ir.json" "4:5" "10:11" "0:1" "4:5"
run_inject_test "gfx1030" "$OUTPUT_DIR/binary_probe_injector_gfx1030_fallback.ir.json" "8:9" "14:15" "4:5" "4:5" "fallback"
run_inject_test "gfx90a" "$OUTPUT_DIR/binary_probe_injector_gfx90a_fallback.ir.json" "8:9" "14:15" "4:5" "4:5" "fallback"
run_inject_test "gfx942" "$OUTPUT_DIR/binary_probe_injector_gfx942_fallback.ir.json" "4:5" "10:11" "0:1" "0:1" "fallback"
run_entry_inject_test "gfx1030" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" "4:5"
run_entry_inject_test "gfx90a" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" "4:5"
run_entry_inject_test "gfx942" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" "0:1"
run_entry_inject_test "gfx942_split_entry" "$OUTPUT_DIR/binary_probe_injector_gfx942_split_entry.ir.json" "4:5"
run_entry_inject_test "gfx1030" "$OUTPUT_DIR/binary_probe_injector_gfx1030_fallback.ir.json" "4:5" "fallback"
run_entry_inject_test "gfx90a" "$OUTPUT_DIR/binary_probe_injector_gfx90a_fallback.ir.json" "4:5" "fallback"
run_entry_inject_test "gfx942" "$OUTPUT_DIR/binary_probe_injector_gfx942_fallback.ir.json" "0:1" "fallback"
run_basic_block_inject_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json"
run_basic_block_builtin_acceptance_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json"
run_basic_block_unsupported_builtin_rejection_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json"
run_entry_backend_pattern_test \
    "gfx1030" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
    "4:5" \
    "direct_vgpr_xyz" \
    "setreg_flat_scratch_init" \
    "11" \
    "s_add_u32 s0, s0, s11" \
    "unpack"
run_entry_backend_pattern_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "4:5" \
    "packed_v0_10_10_10_unpack" \
    "flat_scratch_alias_init" \
    "11" \
    "s_add_u32 s0, s0, s11" \
    "restore_v0"
run_entry_backend_pattern_test \
    "gfx942" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "0:1" \
    "packed_v0_10_10_10_unpack" \
    "src_private_base" \
    "5" \
    "s_add_u32 s0, s0, s5" \
    "restore_v0"
run_entry_missing_helper_abi_rejection_test \
    "gfx942" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json"
run_basic_block_src_private_base_test \
    "gfx942_real" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json" \
    "mlk_xyz"
run_basic_block_resume_rejection_test \
    "gfx942_single" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    "Cijk_S_GA"

print_summary
