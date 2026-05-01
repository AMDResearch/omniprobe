#!/bin/bash
################################################################################
# Mid-kernel resume matrix tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

MATRIX_TOOL="${REPO_ROOT}/tools/codeobj/emit_mid_kernel_resume_matrix.py"

echo ""
echo "================================================================================"
echo "Mid-Kernel Resume Matrix Tests"
echo "================================================================================"
echo "  Tool: $MATRIX_TOOL"
echo "================================================================================"

if [ ! -f "$MATRIX_TOOL" ]; then
    echo -e "${RED}ERROR: required mid-kernel resume matrix tooling is missing${NC}"
    exit 1
fi

WORK_DIR="$OUTPUT_DIR/mid_kernel_resume_matrix"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="mid_kernel_resume_matrix_fixture_set"
CASES_JSON="$WORK_DIR/${TEST_NAME}.cases.json"
OUTPUT_JSON="$WORK_DIR/${TEST_NAME}.json"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the mid-kernel resume matrix normalizes binary-safe spill/re-entry requirements across gfx1030 and gfx942 fixture families"

python3 - "$SCRIPT_DIR" "$CASES_JSON" <<'PY'
import json
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve()
output_path = Path(sys.argv[2]).resolve()
payload = {
    "cases": [
        {
            "id": "gfx1030_fixture",
            "label": "Synthetic gfx1030 mid-kernel slice",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx1030.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx1030.manifest.json"),
            "function": "entry_abi_kernel",
        },
        {
            "id": "gfx942_packed_fixture",
            "label": "Synthetic gfx942 packed mid-kernel slice",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942.manifest.json"),
            "function": "entry_abi_kernel",
        },
        {
            "id": "gfx942_real_single_vgpr",
            "label": "Real gfx942 single-VGPR body entry",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json"),
            "function": "Cijk_S_GA",
        },
        {
            "id": "gfx942_real_mlk_xyz",
            "label": "Real gfx942 multi-VGPR body entry",
            "ir": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json"),
            "manifest": str(script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json"),
            "function": "mlk_xyz",
        },
    ]
}
output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

if python3 "$MATRIX_TOOL" "$CASES_JSON" --output "$OUTPUT_JSON" > "$WORK_DIR/${TEST_NAME}.out"; then
    if python3 - "$OUTPUT_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["schema"] == "omniprobe.mid_kernel_resume_matrix.v1"
assert payload["generator"] == "emit_mid_kernel_resume_matrix.py"
assert "compiler-generated live-ins or builtins" in payload["helper_contract_note"]
cases = {entry["id"]: entry for entry in payload["cases"]}
assert set(cases) == {
    "gfx1030_fixture",
    "gfx942_packed_fixture",
    "gfx942_real_single_vgpr",
    "gfx942_real_mlk_xyz",
}

gfx1030 = cases["gfx1030_fixture"]
assert gfx1030["supported"] is True
assert gfx1030["supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-mid-kernel-private-spill-v1"
assert gfx1030["entry_shape"]["private_pattern"] == "setreg_flat_scratch_init"
assert gfx1030["resume_requirements"]["spill_storage_class"] == "private_segment_tail"
assert gfx1030["resume_requirements"]["stub_sgpr_floor"] == 64
assert gfx1030["helper_policy"]["compiler_generated_builtins_allowed"] is False
assert "runtime.site_snapshot" in gfx1030["resume_requirements"]["helper_runtime_views"]
assert "dispatch_id" in gfx1030["resume_requirements"]["supported_helper_builtins"]
assert any(
    action["action"] == "reconstruct-private-segment-address" and action["pattern_class"] == "setreg_flat_scratch_init"
    for action in gfx1030["resume_requirements"]["reconstruction_actions"]
)

gfx942_packed = cases["gfx942_packed_fixture"]
assert gfx942_packed["supported"] is True
assert gfx942_packed["supported_class"] == "wave64-packed-v0-10_10_10-unpack-src-private-base-mid-kernel-private-spill-v1"
assert gfx942_packed["entry_shape"]["private_pattern"] == "src_private_base"
assert gfx942_packed["entry_shape"]["private_offset_source_sgpr"] == 5

gfx942_single = cases["gfx942_real_single_vgpr"]
assert gfx942_single["supported"] is False
assert gfx942_single["supported_class"] is None
assert "missing-private-segment-wave-offset-livein" in gfx942_single["blockers"]

gfx942_real = cases["gfx942_real_mlk_xyz"]
assert gfx942_real["supported"] is True
assert gfx942_real["supported_class"] == "wave64-direct-vgpr-xyz-src-private-base-mid-kernel-private-spill-v1"
assert gfx942_real["entry_shape"]["private_pattern"] == "src_private_base"
assert gfx942_real["entry_shape"]["private_offset_source_sgpr"] == 11

summary = {
    entry["supported_class"]: entry
    for entry in payload["class_summary"]
    if entry["supported_class"] is not None
}
assert summary["wave32-direct-vgpr-xyz-setreg-flat-scratch-mid-kernel-private-spill-v1"]["arches"] == ["gfx1030"]
assert summary["wave64-packed-v0-10_10_10-unpack-src-private-base-mid-kernel-private-spill-v1"]["case_ids"] == ["gfx942_packed_fixture"]
assert summary["wave64-direct-vgpr-xyz-src-private-base-mid-kernel-private-spill-v1"]["case_ids"] == ["gfx942_real_mlk_xyz"]
unsupported = next(entry for entry in payload["class_summary"] if entry["supported_class"] is None)
assert unsupported["case_ids"] == ["gfx942_real_single_vgpr"]
assert "missing-private-segment-wave-offset-livein" in unsupported["current_injector_blockers"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Fixture mid-kernel resume matrix captures the expected per-class spill/resume requirements"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Fixture mid-kernel resume matrix output was incorrect"
        echo "  Output saved to: $OUTPUT_JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Fixture mid-kernel resume matrix generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
