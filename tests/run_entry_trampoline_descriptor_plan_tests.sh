#!/bin/bash
################################################################################
# Entry trampoline descriptor merge-policy tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PLANNER="${REPO_ROOT}/tools/codeobj/plan_entry_trampoline_descriptor.py"

echo ""
echo "================================================================================"
echo "Entry Trampoline Descriptor Plan Tests"
echo "================================================================================"
echo "  Planner: $PLANNER"
echo "================================================================================"

if [ ! -f "$PLANNER" ]; then
    echo -e "${RED}ERROR: planner tool is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
PREFIX="entry_trampoline_descriptor_plan"
ORIGINAL_JSON="$OUTPUT_DIR/${PREFIX}.original.json"
TRAMPOLINE_JSON="$OUTPUT_DIR/${PREFIX}.trampoline.json"
REPORT_JSON="$OUTPUT_DIR/${PREFIX}.report.json"
MISMATCH_JSON="$OUTPUT_DIR/${PREFIX}.mismatch.report.json"

cat > "$ORIGINAL_JSON" <<'JSON'
{
  "kernels": {
    "descriptors": [
      {
        "name": "mlk.kd",
        "kernel_name": "mlk",
        "group_segment_fixed_size": 128,
        "private_segment_fixed_size": 32,
        "kernarg_size": 16,
        "compute_pgm_rsrc3": {
          "shared_vgpr_count": 0,
          "inst_pref_size": 0,
          "trap_on_start": 0,
          "trap_on_end": 0,
          "image_op": 0
        },
        "compute_pgm_rsrc1": {
          "granulated_workitem_vgpr_count": 2,
          "granulated_wavefront_sgpr_count": 4,
          "float_round_mode_32": 0,
          "float_round_mode_16_64": 0,
          "float_denorm_mode_32": 0,
          "float_denorm_mode_16_64": 0,
          "enable_dx10_clamp": 0,
          "enable_ieee_mode": 1,
          "fp16_overflow": 0,
          "workgroup_processor_mode": 0,
          "memory_ordered": 1,
          "forward_progress": 1
        },
        "compute_pgm_rsrc2": {
          "enable_private_segment": 1,
          "user_sgpr_count": 8,
          "enable_sgpr_workgroup_id_x": 1,
          "enable_sgpr_workgroup_id_y": 0,
          "enable_sgpr_workgroup_id_z": 0,
          "enable_sgpr_workgroup_info": 0,
          "enable_vgpr_workitem_id": 0,
          "exception_fp_ieee_invalid_op": 0,
          "exception_fp_denorm_src": 0,
          "exception_fp_ieee_div_zero": 0,
          "exception_fp_ieee_overflow": 0,
          "exception_fp_ieee_underflow": 0,
          "exception_fp_ieee_inexact": 0,
          "exception_int_div_zero": 0
        },
        "kernel_code_properties": {
          "enable_sgpr_private_segment_buffer": 1,
          "enable_sgpr_dispatch_ptr": 0,
          "enable_sgpr_queue_ptr": 0,
          "enable_sgpr_kernarg_segment_ptr": 1,
          "enable_sgpr_dispatch_id": 0,
          "enable_sgpr_flat_scratch_init": 1,
          "enable_sgpr_private_segment_size": 1,
          "enable_wavefront_size32": 1,
          "uses_dynamic_stack": 1
        }
      }
    ],
    "metadata": {
      "kernels": [
        {
          "name": "mlk",
          "sgpr_count": 40,
          "vgpr_count": 24
        }
      ]
    }
  }
}
JSON

cat > "$TRAMPOLINE_JSON" <<'JSON'
{
  "kernels": {
    "descriptors": [
      {
        "name": "__omniprobe_trampoline_mlk.kd",
        "kernel_name": "__omniprobe_trampoline_mlk",
        "group_segment_fixed_size": 64,
        "private_segment_fixed_size": 96,
        "kernarg_size": 24,
        "compute_pgm_rsrc3": {
          "shared_vgpr_count": 2,
          "inst_pref_size": 0,
          "trap_on_start": 0,
          "trap_on_end": 0,
          "image_op": 0
        },
        "compute_pgm_rsrc1": {
          "granulated_workitem_vgpr_count": 4,
          "granulated_wavefront_sgpr_count": 6,
          "float_round_mode_32": 0,
          "float_round_mode_16_64": 0,
          "float_denorm_mode_32": 0,
          "float_denorm_mode_16_64": 0,
          "enable_dx10_clamp": 0,
          "enable_ieee_mode": 1,
          "fp16_overflow": 0,
          "workgroup_processor_mode": 0,
          "memory_ordered": 1,
          "forward_progress": 1
        },
        "compute_pgm_rsrc2": {
          "enable_private_segment": 1,
          "user_sgpr_count": 10,
          "enable_sgpr_workgroup_id_x": 1,
          "enable_sgpr_workgroup_id_y": 1,
          "enable_sgpr_workgroup_id_z": 1,
          "enable_sgpr_workgroup_info": 1,
          "enable_vgpr_workitem_id": 2,
          "exception_fp_ieee_invalid_op": 0,
          "exception_fp_denorm_src": 0,
          "exception_fp_ieee_div_zero": 0,
          "exception_fp_ieee_overflow": 0,
          "exception_fp_ieee_underflow": 0,
          "exception_fp_ieee_inexact": 0,
          "exception_int_div_zero": 0
        },
        "kernel_code_properties": {
          "enable_sgpr_private_segment_buffer": 1,
          "enable_sgpr_dispatch_ptr": 1,
          "enable_sgpr_queue_ptr": 1,
          "enable_sgpr_kernarg_segment_ptr": 1,
          "enable_sgpr_dispatch_id": 1,
          "enable_sgpr_flat_scratch_init": 1,
          "enable_sgpr_private_segment_size": 1,
          "enable_wavefront_size32": 1,
          "uses_dynamic_stack": 1
        }
      }
    ],
    "metadata": {
      "kernels": [
        {
          "name": "__omniprobe_trampoline_mlk",
          "sgpr_count": 56,
          "vgpr_count": 40
        }
      ]
    }
  }
}
JSON

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_trampoline_descriptor_merge_policy"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 "$PLANNER" \
    --original-manifest "$ORIGINAL_JSON" \
    --original-kernel mlk \
    --trampoline-manifest "$TRAMPOLINE_JSON" \
    --output "$REPORT_JSON" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$REPORT_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["safe_for_phase3_handoff_prototype"] is True
assert payload["merged_launch_candidate"]["group_segment_fixed_size"] == 192
assert payload["merged_launch_candidate"]["private_segment_fixed_size"] == 96
assert payload["merged_launch_candidate"]["kernarg_size"] == 24
assert payload["merged_launch_candidate"]["metadata"]["sgpr_count"] == 56
assert payload["merged_launch_candidate"]["metadata"]["vgpr_count"] == 40
assert payload["merged_launch_candidate"]["compute_pgm_rsrc2"]["enable_sgpr_workgroup_id_y"] == 1
assert payload["merged_launch_candidate"]["compute_pgm_rsrc2"]["enable_vgpr_workitem_id"] == 2
assert payload["body_handoff_requirements"]["entry_abi"]["compute_pgm_rsrc2"]["enable_sgpr_workgroup_id_y"] == 0
policies = {entry["field"]: entry for entry in payload["field_policies"]}
assert policies["group_segment_fixed_size"]["policy"] == "additive-conservative"
assert policies["kernarg_size"]["policy"] == "launch-contract-only"
assert policies["kernel_code_properties.enable_wavefront_size32"]["policy"] == "must-match"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planner emits the expected merged launch candidate and body-handoff split"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planner output did not match the expected merge policy"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Planner failed on the compatible descriptor pair"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_trampoline_descriptor_wave_mismatch"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

python3 - "$TRAMPOLINE_JSON" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["kernels"]["descriptors"][0]["kernel_code_properties"]["enable_wavefront_size32"] = 0
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if python3 "$PLANNER" \
    --original-manifest "$ORIGINAL_JSON" \
    --original-kernel mlk \
    --trampoline-manifest "$TRAMPOLINE_JSON" \
    --output "$MISMATCH_JSON" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$MISMATCH_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["safe_for_phase3_handoff_prototype"] is False
assert any("enable_wavefront_size32" in entry for entry in payload["unresolved"])
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planner fails closed when the trampoline wavefront mode diverges"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planner did not surface the wavefront-mode mismatch"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Planner failed unexpectedly on the mismatch case"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
