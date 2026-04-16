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

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="amdgpu_entry_abi_${arch}"
    local output_json="$OUTPUT_DIR/${test_name}.json"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"

    if python3 "$ANALYZER" "$fixture" \
        --manifest "$manifest" \
        --function entry_abi_kernel \
        --output "$output_json" > "$OUTPUT_DIR/${test_name}.out"; then
        if python3 - "$output_json" "$arch" "$expected_wavefront_size" "$expected_kernarg_pair" "$expected_liveins" "$expected_role_sgprs" "$expected_workitem_pattern" "$expected_private_pattern" <<'PY'
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

assert payload["arch"] == expected_arch
assert payload["descriptor_has_kernarg_segment_ptr"] is True
assert payload["allocated_vgpr_count"] == 8
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

print_summary
