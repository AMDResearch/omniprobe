#!/bin/bash
################################################################################
# AMDGPU backend calling-convention inference tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

ANALYZER="${REPO_ROOT}/tools/codeobj/analyze_amdgpu_calling_convention.py"
MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_descriptor.manifest.json"

echo ""
echo "================================================================================"
echo "AMDGPU Calling Convention Tests"
echo "================================================================================"
echo "  Analyzer: $ANALYZER"
echo "================================================================================"

if [ ! -f "$ANALYZER" ] || [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}ERROR: required call-convention fixtures are missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

run_arch_test() {
    local arch="$1"
    local fixture="$2"
    local expected_kernarg_pair="$3"
    local expected_target_pair="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="amdgpu_callconv_${arch}"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local output_json="$OUTPUT_DIR/${test_name}.json"

    if python3 "$ANALYZER" "$fixture" \
        --manifest "$MANIFEST" \
        --function simple_kernel \
        --output "$output_json" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$output_json" "$arch" "$expected_kernarg_pair" "$expected_target_pair" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_arch = sys.argv[2]
expected_kernarg_pair = [int(part) for part in sys.argv[3].split(":")]
expected_target_pair = [int(part) for part in sys.argv[4].split(":")]

assert payload["arch"] == expected_arch
assert payload["descriptor_has_kernarg_segment_ptr"] is True
assert payload["supported_for_lifecycle_exit_stub"] is True
assert payload["inferred_kernarg_base"]["base_pair"] == expected_kernarg_pair
assert payload["observed_lifecycle_call"]["target_pair"] == expected_target_pair
arg_pairs = payload["observed_lifecycle_call"]["arg_pairs"]
assert [entry["vgpr_pair"] for entry in arg_pairs] == [[0, 1], [2, 3], [4, 5]]
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} call ABI inference matched the observed sample"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} inference output did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} analyzer execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_fallback_test() {
    local arch="$1"
    local fixture="$2"
    local expected_kernarg_pair="$3"
    local expected_target_pair="$4"
    local expected_runtime_pair="$5"
    local expected_timestamp_pair="$6"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="amdgpu_callconv_${arch}_fallback"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    local stripped_ir="$OUTPUT_DIR/${test_name}.ir.json"
    local output_json="$OUTPUT_DIR/${test_name}.json"

    if python3 - "$fixture" "$stripped_ir" <<'PY'
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
    then
        :
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} fallback fixture generation failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    fi

    if python3 "$ANALYZER" "$stripped_ir" \
        --manifest "$MANIFEST" \
        --function simple_kernel \
        --output "$output_json" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$output_json" "$arch" "$expected_kernarg_pair" "$expected_target_pair" "$expected_runtime_pair" "$expected_timestamp_pair" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_arch = sys.argv[2]
expected_kernarg_pair = [int(part) for part in sys.argv[3].split(":")]
expected_target_pair = [int(part) for part in sys.argv[4].split(":")]
expected_runtime_pair = [int(part) for part in sys.argv[5].split(":")]
expected_timestamp_pair = [int(part) for part in sys.argv[6].split(":")]

assert payload["arch"] == expected_arch
assert payload["supported_for_lifecycle_exit_stub"] is True
assert payload["lifecycle_call_source"] == "synthetic_from_kernarg_base"
assert payload["observed_lifecycle_call"] is None
assert payload["inferred_kernarg_base"]["base_pair"] == expected_kernarg_pair
resolved = payload["resolved_lifecycle_call"]
assert resolved["target_pair"] == expected_target_pair
assert resolved["arg_pairs"][0]["source_sgpr_pair"] == expected_runtime_pair
assert resolved["arg_pairs"][1]["source_sgpr_pair"] == expected_kernarg_pair
assert resolved["arg_pairs"][2]["source_sgpr_pair"] == expected_timestamp_pair
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} fallback ABI synthesis recovered the lifecycle call shape without an observed helper call"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} fallback inference output did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} fallback analyzer execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_arch_test "gfx1030" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" "4:5" "14:15"
run_arch_test "gfx90a" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" "4:5" "14:15"
run_arch_test "gfx942" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" "0:1" "10:11"
run_fallback_test "gfx1030" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx1030.ir.json" "4:5" "14:15" "8:9" "12:13"
run_fallback_test "gfx90a" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx90a.ir.json" "4:5" "14:15" "8:9" "12:13"
run_fallback_test "gfx942" "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_callconv_gfx942.ir.json" "0:1" "10:11" "4:5" "8:9"

print_summary
