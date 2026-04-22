#!/bin/bash
################################################################################
# AMDGPU backend entry-ABI inference tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

ANALYZER="${REPO_ROOT}/tools/codeobj/analyze_amdgpu_entry_abi.py"

echo ""
echo "================================================================================"
echo "AMDGPU Entry ABI Tests"
echo "================================================================================"
echo "  Analyzer: $ANALYZER"
echo "================================================================================"

if [ ! -f "$ANALYZER" ]; then
    echo -e "${RED}ERROR: required entry-ABI analyzer is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

run_arch_test() {
    local arch="$1"
    local fixture="$2"
    local manifest="$3"
    local expected_wavefront_size="$4"
    local expected_kernarg_pair="$5"
    local expected_liveins="$6"
    local expected_role_sgprs="$7"
    local expected_workitem_pattern="$8"
    local expected_private_pattern="$9"
    local function_name="${10:-entry_abi_kernel}"
    local expected_allocated_sgpr_count="${11:-}"
    local expected_allocated_vgpr_count="${12:-8}"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="amdgpu_entry_abi_${arch}"
    local output_json="$OUTPUT_DIR/${test_name}.json"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"

    if python3 "$ANALYZER" "$fixture" \
        --manifest "$manifest" \
        --function "$function_name" \
        --output "$output_json" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$output_json" "$arch" "$expected_wavefront_size" "$expected_kernarg_pair" "$expected_liveins" "$expected_role_sgprs" "$expected_workitem_pattern" "$expected_private_pattern" "$expected_allocated_sgpr_count" "$expected_allocated_vgpr_count" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected_arch = sys.argv[2]
expected_wavefront_size = int(sys.argv[3])
expected_kernarg_pair = [int(part) for part in sys.argv[4].split(":")]
expected_liveins = [int(part) for part in sys.argv[5].split(",") if part]
expected_role_sgprs = [int(part) for part in sys.argv[6].split(":")]
expected_workitem_pattern = sys.argv[7]
expected_private_pattern = sys.argv[8]
expected_allocated_sgpr_count = int(sys.argv[9]) if sys.argv[9] else None
expected_allocated_vgpr_count = int(sys.argv[10])

assert payload["arch"] == expected_arch
assert payload["descriptor_has_kernarg_segment_ptr"] is True
if expected_allocated_sgpr_count is not None:
    assert payload["allocated_sgpr_count"] == expected_allocated_sgpr_count
assert payload["allocated_vgpr_count"] == expected_allocated_vgpr_count
assert payload["wavefront_size"] == expected_wavefront_size
assert payload["entry_livein_sgprs"] == expected_liveins
roles = payload["entry_system_sgpr_roles"]
assert [entry["role"] for entry in roles] == [
    "workgroup_id_x",
    "workgroup_id_y",
    "workgroup_id_z",
    "private_segment_wave_offset",
]
assert [entry["sgpr"] for entry in roles] == expected_role_sgprs
assert payload["entry_workitem_vgpr_count"] == 3
assert payload["inferred_kernarg_base"]["base_pair"] == expected_kernarg_pair
assert payload["observed_workitem_id_materialization"]["pattern_class"] == expected_workitem_pattern
assert payload["observed_private_segment_materialization"]["pattern_class"] == expected_private_pattern
support = payload["current_entry_stub_support"]
assert payload["supported_for_current_entry_stub"] is True
assert support["supported"] is True
assert support["reasons"] == []
assert support["assumptions"]["workitem_preservation_policy"] == "spill_original_entry_vgprs"
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} entry ABI facts matched the tracked backend pattern"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} entry ABI inference did not match expectations"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} analyzer execution failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_arch_test \
    "gfx1030" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
    "32" \
    "4:5" \
    "0,1,2,3,4,5,6,7,8,9,10,11" \
    "8:9:10:11" \
    "direct_vgpr_xyz" \
    "setreg_flat_scratch_init"

run_arch_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "64" \
    "4:5" \
    "0,1,2,3,4,5,6,7,8,9,10,11" \
    "8:9:10:11" \
    "packed_v0_10_10_10_unpack" \
    "flat_scratch_alias_init"

run_arch_test \
    "gfx942" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "64" \
    "0:1" \
    "0,1,2,3,4,5" \
    "2:3:4:5" \
    "packed_v0_10_10_10_unpack" \
    "src_private_base"

run_arch_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json" \
    "64" \
    "8:9" \
    "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17" \
    "14:15:16:17" \
    "direct_vgpr_xyz" \
    "flat_scratch_alias_init" \
    "mlk_xyz" \
    "40" \
    "40"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="amdgpu_entry_abi_wave64_direct_v0_regression"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$REPO_ROOT" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(repo_root / "tools" / "codeobj"))

from amdgpu_entry_abi import observe_workitem_id_materialization  # type: ignore

function = {
    "instructions": [
        {
            "mnemonic": "v_mov_b32_e32",
            "operands": ["v31", "v0"],
            "operand_text": "v31, v0",
            "address": 0x100,
        },
        {
            "mnemonic": "v_accvgpr_write_b32",
            "operands": ["a0", "v31"],
            "operand_text": "a0, v31",
            "address": 0x104,
        },
    ]
}

payload = observe_workitem_id_materialization(function, 3)
assert payload is not None
assert payload["pattern_class"] == "direct_vgpr_xyz", payload
first_use = payload["details"]["first_direct_uses"][0]
assert first_use["operand_text"] == "v31, v0", first_use
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Wave64 direct-VGPR detection now recognizes an early v0-only use"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Wave64 direct-VGPR detection regressed on the v0-only case"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="amdgpu_entry_abi_gfx942_real_single_vgpr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 "$ANALYZER" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    --function Cijk_S_GA \
    --output "$OUTPUT_DIR/${TEST_NAME}.json" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$OUTPUT_DIR/${TEST_NAME}.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["arch"] == "gfx942"
assert payload["function"] == "Cijk_S_GA"
assert payload["descriptor_has_kernarg_segment_ptr"] is True
assert payload["allocated_sgpr_count"] == 24
assert payload["allocated_vgpr_count"] == 16
assert payload["wavefront_size"] == 64
assert payload["private_segment_fixed_size"] == 0
assert payload["entry_livein_sgprs"] == [0, 1, 2]
roles = payload["entry_system_sgpr_roles"]
assert [entry["role"] for entry in roles] == ["workgroup_id_x"]
assert [entry["sgpr"] for entry in roles] == [2]
assert payload["entry_workitem_vgpr_count"] == 1
assert payload["inferred_kernarg_base"]["base_pair"] == [0, 1]
assert payload["observed_workitem_id_materialization"]["pattern_class"] == "single_vgpr_workitem_id"
assert payload["observed_private_segment_materialization"] is None
support = payload["current_entry_stub_support"]
assert payload["supported_for_current_entry_stub"] is True
assert support["supported"] is True
assert support["reasons"] == []
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Real gfx942 fixture exposes the audited single-VGPR entry ABI shape"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR entry ABI inference did not match expectations"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR analyzer execution failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
