#!/bin/bash
################################################################################
# Binary-only lifecycle exit injector tests
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
LIFECYCLE_SPEC="${SCRIPT_DIR}/probe_specs/kernel_timing_v1.yaml"

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

prepare_shared_artifacts() {
    local prefix="$1"
    local bundle_dir="$OUTPUT_DIR/${prefix}_bundle"
    local bundle_json="$bundle_dir/generated_probe_bundle.json"
    local plan_json="$OUTPUT_DIR/${prefix}.plan.json"
    local thunk_manifest="$OUTPUT_DIR/${prefix}.thunks.json"
    local thunk_source="$OUTPUT_DIR/${prefix}.thunks.hip"
    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir"
    python3 "$PREPARE_BUNDLE" "$LIFECYCLE_SPEC" --output-dir "$bundle_dir" --skip-compile > "$OUTPUT_DIR/${prefix}.bundle.out"
    python3 "$PLANNER" "$PLAN_MANIFEST" --probe-bundle "$bundle_json" --kernel simple_kernel --output "$plan_json" > "$OUTPUT_DIR/${prefix}.plan.out"
    python3 "$THUNK_GENERATOR" "$plan_json" --probe-bundle "$bundle_json" --output "$thunk_source" --manifest-output "$thunk_manifest" > "$OUTPUT_DIR/${prefix}.thunk.out"
}

prepare_shared_artifacts "binary_probe_injector"

run_inject_test() {
    local arch="$1"
    local ir_fixture="$2"
    local expected_runtime_pair="$3"
    local expected_target_pair="$4"
    local expected_kernarg_pair="$5"
    local source_kind="${6:-observed}"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="binary_probe_inject_${arch}"
    if [ "$source_kind" = "fallback" ]; then
        test_name="${test_name}_fallback"
    fi
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local out_ir="$OUTPUT_DIR/${test_name}.ir.json"

    if python3 "$INJECTOR" "$ir_fixture" \
        --plan "$OUTPUT_DIR/binary_probe_injector.plan.json" \
        --thunk-manifest "$OUTPUT_DIR/binary_probe_injector.thunks.json" \
        --manifest "$DESCRIPTOR_MANIFEST" \
        --function simple_kernel \
        --output "$out_ir" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$out_ir" "$expected_runtime_pair" "$expected_target_pair" "$expected_kernarg_pair" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_runtime = [int(part) for part in sys.argv[2].split(":")]
expected_target = [int(part) for part in sys.argv[3].split(":")]
expected_kernarg = [int(part) for part in sys.argv[4].split(":")]
fn = payload["functions"][0]
meta = fn["instrumentation"]["lifecycle_exit_stub"]
assert meta["target_pair"] == expected_target
assert meta["kernarg_pair"] == expected_kernarg
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
assert entry_stub[0]["operand_text"].endswith(", 0x10")
assert entry_stub[1]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[1]["operand_text"].startswith("s[38:39]")
assert entry_stub[1]["operand_text"].endswith(", 0x0")
assert entry_stub[2]["mnemonic"] == "s_load_dwordx2"
assert entry_stub[2]["operand_text"].startswith("s[40:41]")
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

run_inject_test "gfx1030" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" "8:9" "14:15" "4:5"
run_inject_test "gfx90a" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" "8:9" "14:15" "4:5"
run_inject_test "gfx942" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" "4:5" "10:11" "0:1"
run_inject_test "gfx1030" "$OUTPUT_DIR/binary_probe_injector_gfx1030_fallback.ir.json" "8:9" "14:15" "4:5" "fallback"
run_inject_test "gfx90a" "$OUTPUT_DIR/binary_probe_injector_gfx90a_fallback.ir.json" "8:9" "14:15" "4:5" "fallback"
run_inject_test "gfx942" "$OUTPUT_DIR/binary_probe_injector_gfx942_fallback.ir.json" "4:5" "10:11" "0:1" "fallback"

print_summary
