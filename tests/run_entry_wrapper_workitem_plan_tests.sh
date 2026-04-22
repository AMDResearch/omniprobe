#!/bin/bash
################################################################################
# Entry-wrapper workitem spill/restore plan tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

WORK_DIR="$OUTPUT_DIR/entry_wrapper_workitem_plan"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PYTHON_CHECKER="$WORK_DIR/check_entry_wrapper_workitem_plan.py"
cat > "$PYTHON_CHECKER" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
ir_path = Path(sys.argv[3]).resolve()
function_name = sys.argv[4]

sys.path.insert(0, str(REPO_ROOT / "tools" / "codeobj"))

from code_object_model import CodeObjectModel  # type: ignore
from regenerate_code_object import (  # type: ignore
    build_entry_wrapper_workitem_spill_restore_plan,
    validate_entry_wrapper_proof_preconditions,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
model = CodeObjectModel.from_manifest(manifest)
descriptor = model.descriptor_by_kernel_name(function_name)
assert descriptor is not None

_, analysis, recipe, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)

pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 2, pair_candidates
secondary_pair = pair_candidates[1]["pair"]
assert secondary_pair == [32, 33], secondary_pair
analysis["entry_wrapper_secondary_scratch_pair"] = list(secondary_pair)

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    save_pair=(scratch_pair[0], scratch_pair[1]),
    branch_pair=(secondary_pair[0], secondary_pair[1]),
)

assert analysis["entry_wrapper_supported_class"] == "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"
assert list(scratch_pair) == [18, 19], scratch_pair
assert plan["source_vgprs"] == [0, 1, 2], plan
assert plan["pattern_class"] == "direct_vgpr_xyz", plan
assert plan["spill_offset"] == 192, plan
assert plan["spill_bytes"] == 12, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "flat_scratch_alias_init", plan
assert plan["private_segment_offset_source_sgpr"] == 17, plan
assert plan["save_pair"] == [18, 19], plan
assert plan["branch_pair"] == [32, 33], plan
assert plan["soffset_sgpr"] == 32, plan

print(json.dumps(plan, indent=2))
PY
chmod +x "$PYTHON_CHECKER"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_plan_gfx90a_mi210_direct"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner reproduces the MI210 direct-entry ABI plan"

if python3 "$PYTHON_CHECKER" \
    "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.ir.json" \
    "mlk_xyz" > "$STDOUT_FILE" 2> "$STDERR_FILE"; then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["source_vgprs"] == [0, 1, 2]
assert payload["spill_offset"] == 192
assert payload["private_segment_growth"] == 16
assert payload["branch_pair"] == [32, 33]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Offline workitem spill/restore planning matches the validated MI210 direct-entry ABI shape"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_plan_gfx942_real_single_vgpr"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner derives a coherent single-VGPR plan for the real gfx942 class"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    "Cijk_S_GA" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
ir_path = Path(sys.argv[3]).resolve()
function_name = sys.argv[4]

sys.path.insert(0, str(REPO_ROOT / "tools" / "codeobj"))

from amdgpu_entry_abi import analyze_kernel_entry_abi  # type: ignore
from code_object_model import CodeObjectModel  # type: ignore
from regenerate_code_object import (  # type: ignore
    build_entry_wrapper_ir,
    build_entry_wrapper_handoff_recipe,
    build_entry_wrapper_workitem_spill_restore_plan,
    classify_entry_handoff_supported_class,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
model = CodeObjectModel.from_manifest(manifest)
descriptor = model.descriptor_by_kernel_name(function_name)
kernel_metadata = model.metadata_by_kernel_name(function_name)
function = next(
    entry for entry in ir.get("functions", []) if entry.get("name") == function_name
)
assert descriptor is not None

analysis = analyze_kernel_entry_abi(
    function=function,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
)
supported_class, blockers = classify_entry_handoff_supported_class(analysis)
assert supported_class == "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1", blockers
assert blockers == [], blockers
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 4, pair_candidates
assert pair_candidates[0]["pair"] == [4, 5], pair_candidates
assert pair_candidates[1]["pair"] == [6, 7], pair_candidates

recipe = build_entry_wrapper_handoff_recipe(
    function_name=function_name,
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    scratch_pair=(4, 5),
)
assert recipe.get("supported") is True
assert recipe.get("supported_class") == supported_class

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    save_pair=(4, 5),
    branch_pair=(6, 7),
)
assert plan["source_vgprs"] == [0], plan
assert plan["pattern_class"] == "single_vgpr_workitem_id", plan
assert plan["spill_offset"] == 0, plan
assert plan["spill_bytes"] == 4, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "wrapper_owned_src_private_base", plan
assert plan["private_segment_offset_source_sgpr"] == 3, plan
assert plan["address_vgprs"] == [2, 3], plan
assert plan["save_pair"] == [4, 5], plan
assert plan["branch_pair"] == [6, 7], plan
assert plan["soffset_sgpr"] == 6, plan

print(json.dumps({"pairs": pair_candidates[:4], "plan": plan}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["pairs"][0]["pair"] == [4, 5]
assert payload["pairs"][1]["pair"] == [6, 7]
assert payload["plan"]["source_vgprs"] == [0]
assert payload["plan"]["spill_offset"] == 0
assert payload["plan"]["private_segment_growth"] == 16
assert payload["plan"]["private_segment_pattern_class"] == "wrapper_owned_src_private_base"
assert payload["plan"]["private_segment_offset_source_sgpr"] == 3
assert payload["plan"]["address_vgprs"] == [2, 3]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Offline workitem spill/restore planning now derives a wrapper-owned private-tail carrier for the real gfx942 single-VGPR class"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_ir_gfx942_real_single_vgpr"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate direct wrapper IR construction now accepts the real gfx942 single-VGPR plan and materializes a wrapper-owned private base"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    "Cijk_S_GA" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
ir_path = Path(sys.argv[3]).resolve()
function_name = sys.argv[4]

sys.path.insert(0, str(REPO_ROOT / "tools" / "codeobj"))

from amdgpu_entry_abi import analyze_kernel_entry_abi  # type: ignore
from code_object_model import CodeObjectModel  # type: ignore
from regenerate_code_object import (  # type: ignore
    build_entry_wrapper_ir,
    build_entry_wrapper_workitem_spill_restore_plan,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
model = CodeObjectModel.from_manifest(manifest)
descriptor = model.descriptor_by_kernel_name(function_name)
kernel_metadata = model.metadata_by_kernel_name(function_name)
function = next(
    entry for entry in ir.get("functions", []) if entry.get("name") == function_name
)
assert descriptor is not None

analysis = analyze_kernel_entry_abi(
    function=function,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
)
plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    save_pair=(4, 5),
    branch_pair=(6, 7),
)
wrapper = build_entry_wrapper_ir(
    wrapper_name=function_name,
    body_name="__body",
    start_address=0x1000,
    scratch_pair=(6, 7),
    workitem_spill_restore_plan=plan,
)
instructions = wrapper.get("instructions", [])

def find_index(mnemonic: str, operand_text: str, start: int = 0) -> int:
    for index in range(start, len(instructions)):
        insn = instructions[index]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return index
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")


save_lo = find_index("s_mov_b32", "s4, s0")
save_hi = find_index("s_mov_b32", "s5, s1")
private_base_0 = find_index("s_mov_b64", "s[0:1], src_private_base")
private_add_0 = find_index("s_add_u32", "s0, s0, s3", private_base_0 + 1)
private_addc_0 = find_index("s_addc_u32", "s1, s1, 0", private_add_0 + 1)
addr_lo_0 = find_index("v_mov_b32_e32", "v2, s0", private_addc_0 + 1)
addr_hi_0 = find_index("v_mov_b32_e32", "v3, s1", addr_lo_0 + 1)
store_v0 = find_index("flat_store_dword", "v[2:3], v0", addr_hi_0 + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s4", store_v0 + 1)
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s5", restore_lo_before_clobber + 1)
clobber_v0 = find_index("v_mov_b32_e32", "v0, 0", restore_hi_before_clobber + 1)
private_base_1 = find_index("s_mov_b64", "s[0:1], src_private_base", clobber_v0 + 1)
private_add_1 = find_index("s_add_u32", "s0, s0, s3", private_base_1 + 1)
private_addc_1 = find_index("s_addc_u32", "s1, s1, 0", private_add_1 + 1)
addr_lo_1 = find_index("v_mov_b32_e32", "v2, s0", private_addc_1 + 1)
addr_hi_1 = find_index("v_mov_b32_e32", "v3, s1", addr_lo_1 + 1)
load_v0 = find_index("flat_load_dword", "v0, v[2:3]", addr_hi_1 + 1)
wait = find_index("s_waitcnt", "vmcnt(0)", load_v0 + 1)
restore_lo_after_load = find_index("s_mov_b32", "s0, s4", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s5", restore_lo_after_load + 1)
branch = find_index("s_setpc_b64", "s[6:7]", restore_hi_after_load + 1)

assert save_lo < save_hi < private_base_0 < private_add_0 < private_addc_0 < addr_lo_0 < addr_hi_0 < store_v0
assert store_v0 < restore_lo_before_clobber < restore_hi_before_clobber < clobber_v0
assert clobber_v0 < private_base_1 < private_add_1 < private_addc_1 < addr_lo_1 < addr_hi_1 < load_v0 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < branch

print(json.dumps({"plan": plan, "instruction_count": len(instructions)}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["plan"]["private_segment_pattern_class"] == "wrapper_owned_src_private_base"
assert payload["plan"]["private_segment_offset_source_sgpr"] == 3
assert payload["plan"]["address_vgprs"] == [2, 3]
assert payload["instruction_count"] > 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Real gfx942 single-VGPR wrapper IR now builds through a wrapper-owned src_private_base spill carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR wrapper IR output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 single-VGPR wrapper IR construction failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
