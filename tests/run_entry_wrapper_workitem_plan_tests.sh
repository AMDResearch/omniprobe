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

REGENERATE_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
DISASM_TO_IR="${REPO_ROOT}/tools/codeobj/disasm_to_ir.py"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"

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
TEST_NAME="entry_wrapper_workitem_plan_gfx942_real_mlk_xyz"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner derives a coherent multi-VGPR src_private_base plan for the real gfx942 mlk_xyz class"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json" \
    "mlk_xyz" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
assert supported_class == "wave64-direct-vgpr-xyz-src-private-base-v1", blockers
assert blockers == [], blockers
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 2, pair_candidates
assert pair_candidates[0]["pair"] == [12, 13], pair_candidates
assert pair_candidates[1]["pair"] == [14, 15], pair_candidates

recipe = build_entry_wrapper_handoff_recipe(
    function_name=function_name,
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    scratch_pair=(12, 13),
)
assert recipe.get("supported") is True
assert recipe.get("supported_class") == supported_class

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=(12, 13),
    branch_pair=(14, 15),
)
assert plan["source_vgprs"] == [0, 1, 2], plan
assert plan["pattern_class"] == "direct_vgpr_xyz", plan
assert plan["spill_offset"] == 192, plan
assert plan["spill_bytes"] == 12, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "src_private_base", plan
assert plan["address_vgprs"] == [40, 41], plan
assert plan["data_pair_vgprs"] == [42, 43], plan
assert plan["tail_data_vgpr"] == 44, plan
assert plan["required_total_vgprs"] == 45, plan
assert plan["save_pair"] == [12, 13], plan
assert plan["branch_pair"] == [14, 15], plan
assert plan["soffset_sgpr"] == 14, plan

print(json.dumps({"pairs": pair_candidates[:4], "plan": plan}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["pairs"][0]["pair"] == [12, 13]
assert payload["pairs"][1]["pair"] == [14, 15]
assert payload["plan"]["source_vgprs"] == [0, 1, 2]
assert payload["plan"]["private_segment_pattern_class"] == "src_private_base"
assert payload["plan"]["address_vgprs"] == [40, 41]
assert payload["plan"]["data_pair_vgprs"] == [42, 43]
assert payload["plan"]["tail_data_vgpr"] == 44
assert payload["plan"]["required_total_vgprs"] == 45
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Offline workitem spill/restore planning now derives a real gfx942 multi-VGPR src_private_base carrier layout"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 mlk_xyz workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 mlk_xyz workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_ir_gfx942_real_mlk_xyz"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate direct wrapper IR construction now emits flat dwordx2+dword spill/restore for the real gfx942 mlk_xyz class"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json" \
    "mlk_xyz" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
    kernel_metadata=kernel_metadata,
    save_pair=(12, 13),
    branch_pair=(14, 15),
)
wrapper = build_entry_wrapper_ir(
    wrapper_name=function_name,
    body_name="__body",
    start_address=0x1000,
    scratch_pair=(14, 15),
    workitem_spill_restore_plan=plan,
)
instructions = wrapper.get("instructions", [])

def find_index(mnemonic: str, operand_text: str, start: int = 0) -> int:
    for index in range(start, len(instructions)):
        insn = instructions[index]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return index
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")


save_lo = find_index("s_mov_b32", "s12, s0")
save_hi = find_index("s_mov_b32", "s13, s1")
private_base_0 = find_index("s_mov_b64", "s[0:1], src_private_base")
spill_add_0 = find_index("s_add_u32", "s0, s0, 0xc0", private_base_0 + 1)
addr_lo_0 = find_index("v_mov_b32_e32", "v40, s0", private_base_0 + 1)
addr_hi_0 = find_index("v_mov_b32_e32", "v41, s1", addr_lo_0 + 1)
pair_lo_0 = find_index("v_mov_b32_e32", "v42, v0", addr_hi_0 + 1)
pair_hi_0 = find_index("v_mov_b32_e32", "v43, v1", pair_lo_0 + 1)
store_pair = find_index("flat_store_dwordx2", "v[40:41], v[42:43]", pair_hi_0 + 1)
tail_copy = find_index("v_mov_b32_e32", "v44, v2", store_pair + 1)
tail_add = find_index("s_add_u32", "s0, s0, 0x8", tail_copy + 1)
tail_store = find_index("flat_store_dword", "v[40:41], v44", tail_add + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s12", tail_store + 1)
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s13", restore_lo_before_clobber + 1)
clobber_v0 = find_index("v_mov_b32_e32", "v0, 0", restore_hi_before_clobber + 1)
clobber_v1 = find_index("v_mov_b32_e32", "v1, 0", clobber_v0 + 1)
clobber_v2 = find_index("v_mov_b32_e32", "v2, 0", clobber_v1 + 1)
private_base_1 = find_index("s_mov_b64", "s[0:1], src_private_base", clobber_v2 + 1)
spill_add_1 = find_index("s_add_u32", "s0, s0, 0xc0", private_base_1 + 1)
addr_lo_1 = find_index("v_mov_b32_e32", "v40, s0", private_base_1 + 1)
addr_hi_1 = find_index("v_mov_b32_e32", "v41, s1", addr_lo_1 + 1)
load_pair = find_index("flat_load_dwordx2", "v[42:43], v[40:41]", addr_hi_1 + 1)
restore_v0 = find_index("v_mov_b32_e32", "v0, v42", load_pair + 1)
restore_v1 = find_index("v_mov_b32_e32", "v1, v43", restore_v0 + 1)
tail_add_1 = find_index("s_add_u32", "s0, s0, 0x8", restore_v1 + 1)
tail_load = find_index("flat_load_dword", "v44, v[40:41]", tail_add_1 + 1)
restore_v2 = find_index("v_mov_b32_e32", "v2, v44", tail_load + 1)
wait = find_index("s_waitcnt", "vmcnt(0)", restore_v2 + 1)
restore_lo_after_load = find_index("s_mov_b32", "s0, s12", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s13", restore_lo_after_load + 1)
branch = find_index("s_setpc_b64", "s[14:15]", restore_hi_after_load + 1)

assert save_lo < save_hi < private_base_0 < spill_add_0 < addr_lo_0 < addr_hi_0 < pair_lo_0 < pair_hi_0 < store_pair < tail_copy < tail_add < tail_store
assert tail_store < restore_lo_before_clobber < restore_hi_before_clobber < clobber_v0 < clobber_v1 < clobber_v2
assert clobber_v2 < private_base_1 < spill_add_1 < addr_lo_1 < addr_hi_1 < load_pair < restore_v0 < restore_v1 < tail_add_1 < tail_load < restore_v2 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < branch

print(json.dumps({"plan": plan, "instruction_count": len(instructions)}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["plan"]["private_segment_pattern_class"] == "src_private_base"
assert payload["plan"]["address_vgprs"] == [40, 41]
assert payload["plan"]["data_pair_vgprs"] == [42, 43]
assert payload["plan"]["tail_data_vgpr"] == 44
assert payload["instruction_count"] > 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Real gfx942 mlk_xyz wrapper IR now builds through flat dwordx2+dword src_private_base spill carriers"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 mlk_xyz wrapper IR output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Real gfx942 mlk_xyz wrapper IR construction failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_plan_gfx90a_packed"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner derives the packed-wave64 flat-scratch-alias carrier plan for gfx90a"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
kernel_metadata = model.metadata_by_kernel_name(function_name)
assert descriptor is not None

_, analysis, recipe, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 2, pair_candidates
assert list(scratch_pair) == [12, 13], scratch_pair
assert pair_candidates[1]["pair"] == [14, 15], pair_candidates
assert analysis["entry_wrapper_supported_class"] == "wave64-packed-v0-10_10_10-flat-scratch-alias-v1"
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave64-packed-v0-10_10_10-flat-scratch-alias-v1"

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=(12, 13),
    branch_pair=(14, 15),
)
assert plan["source_vgprs"] == [0], plan
assert plan["pattern_class"] == "packed_v0_10_10_10_unpack", plan
assert plan["spill_offset"] == 528, plan
assert plan["spill_bytes"] == 4, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "flat_scratch_alias_init", plan
assert plan["private_segment_offset_source_sgpr"] == 11, plan
assert plan["save_pair"] == [12, 13], plan
assert plan["branch_pair"] == [14, 15], plan
assert plan["soffset_sgpr"] == 14, plan

print(json.dumps(plan, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["source_vgprs"] == [0]
assert payload["spill_offset"] == 528
assert payload["spill_bytes"] == 4
assert payload["private_segment_growth"] == 16
assert payload["private_segment_pattern_class"] == "flat_scratch_alias_init"
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx90a workitem spill/restore planning produces the expected flat-scratch-alias carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_ir_gfx90a_packed"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate direct wrapper IR construction emits the packed-wave64 scalar-tail spill/restore sequence for gfx90a"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
    build_entry_wrapper_ir,
    build_entry_wrapper_workitem_spill_restore_plan,
    validate_entry_wrapper_proof_preconditions,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
model = CodeObjectModel.from_manifest(manifest)
descriptor = model.descriptor_by_kernel_name(function_name)
kernel_metadata = model.metadata_by_kernel_name(function_name)
assert descriptor is not None

_, analysis, _, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=tuple(scratch_pair),
    branch_pair=tuple(pair_candidates[1]["pair"]),
)
wrapper = build_entry_wrapper_ir(
    wrapper_name=function_name,
    body_name="__body",
    start_address=0x1000,
    scratch_pair=tuple(pair_candidates[1]["pair"]),
    workitem_spill_restore_plan=plan,
)
instructions = wrapper.get("instructions", [])

def find_index(mnemonic: str, operand_text: str, start: int = 0) -> int:
    for index in range(start, len(instructions)):
        insn = instructions[index]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return index
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")

save_lo = find_index("s_mov_b32", "s12, s0")
save_hi = find_index("s_mov_b32", "s13, s1")
private_add = find_index("s_add_u32", "s0, s0, s11", save_hi + 1)
private_addc = find_index("s_addc_u32", "s1, s1, 0", private_add + 1)
store_soffset = find_index("s_mov_b32", "s14, 0", private_addc + 1)
store_v0 = find_index("buffer_store_dword", "v0, off, s[0:3], s14 offset:528", store_soffset + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s12", store_v0 + 1)
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s13", restore_lo_before_clobber + 1)
clobber_v0 = find_index("v_mov_b32_e32", "v0, 0", restore_hi_before_clobber + 1)
private_add_1 = find_index("s_add_u32", "s0, s0, s11", clobber_v0 + 1)
private_addc_1 = find_index("s_addc_u32", "s1, s1, 0", private_add_1 + 1)
load_soffset = find_index("s_mov_b32", "s14, 0", private_addc_1 + 1)
load_v0 = find_index("buffer_load_dword", "v0, off, s[0:3], s14 offset:528", load_soffset + 1)
wait = find_index("s_waitcnt", "vmcnt(0)", load_v0 + 1)
restore_lo_after_load = find_index("s_mov_b32", "s0, s12", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s13", restore_lo_after_load + 1)
branch = find_index("s_setpc_b64", "s[14:15]", restore_hi_after_load + 1)

assert save_lo < save_hi < private_add < private_addc < store_soffset < store_v0
assert store_v0 < restore_lo_before_clobber < restore_hi_before_clobber < clobber_v0
assert clobber_v0 < private_add_1 < private_addc_1 < load_soffset < load_v0 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < branch

print(json.dumps({"plan": plan, "instruction_count": len(instructions)}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["plan"]["pattern_class"] == "packed_v0_10_10_10_unpack"
assert payload["plan"]["private_segment_pattern_class"] == "flat_scratch_alias_init"
assert payload["instruction_count"] > 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx90a wrapper IR builds through the expected scalar-tail spill carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a wrapper IR output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a wrapper IR construction failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_plan_gfx942_packed"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner derives the packed-wave64 src_private_base carrier plan for gfx942"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
kernel_metadata = model.metadata_by_kernel_name(function_name)
assert descriptor is not None

_, analysis, recipe, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 2, pair_candidates
assert list(scratch_pair) == [8, 9], scratch_pair
assert pair_candidates[1]["pair"] == [10, 11], pair_candidates
assert analysis["entry_wrapper_supported_class"] == "wave64-packed-v0-10_10_10-src-private-base-v1"
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave64-packed-v0-10_10_10-src-private-base-v1"

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=(8, 9),
    branch_pair=(10, 11),
)
assert plan["source_vgprs"] == [0], plan
assert plan["pattern_class"] == "packed_v0_10_10_10_unpack", plan
assert plan["spill_offset"] == 528, plan
assert plan["spill_bytes"] == 4, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "src_private_base", plan
assert plan["private_segment_offset_source_sgpr"] == 5, plan
assert plan["save_pair"] == [8, 9], plan
assert plan["branch_pair"] == [10, 11], plan
assert plan["soffset_sgpr"] == 10, plan
assert plan["address_vgprs"] == [6, 7], plan
assert plan["tail_data_vgpr"] == 8, plan
assert plan["required_total_vgprs"] == 9, plan

print(json.dumps(plan, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["source_vgprs"] == [0]
assert payload["spill_offset"] == 528
assert payload["spill_bytes"] == 4
assert payload["private_segment_growth"] == 16
assert payload["private_segment_pattern_class"] == "src_private_base"
assert payload["address_vgprs"] == [6, 7]
assert payload["tail_data_vgpr"] == 8
assert payload["required_total_vgprs"] == 9
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx942 workitem spill/restore planning produces the expected src_private_base carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_ir_gfx942_packed"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate direct wrapper IR construction emits the packed-wave64 src_private_base spill/restore sequence for gfx942"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
    build_entry_wrapper_ir,
    build_entry_wrapper_workitem_spill_restore_plan,
    validate_entry_wrapper_proof_preconditions,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
model = CodeObjectModel.from_manifest(manifest)
descriptor = model.descriptor_by_kernel_name(function_name)
kernel_metadata = model.metadata_by_kernel_name(function_name)
assert descriptor is not None

_, analysis, _, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=tuple(scratch_pair),
    branch_pair=tuple(pair_candidates[1]["pair"]),
)
wrapper = build_entry_wrapper_ir(
    wrapper_name=function_name,
    body_name="__body",
    start_address=0x1000,
    scratch_pair=tuple(pair_candidates[1]["pair"]),
    workitem_spill_restore_plan=plan,
)
instructions = wrapper.get("instructions", [])

def find_index(mnemonic: str, operand_text: str, start: int = 0) -> int:
    for index in range(start, len(instructions)):
        insn = instructions[index]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return index
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")

save_lo = find_index("s_mov_b32", "s8, s0")
save_hi = find_index("s_mov_b32", "s9, s1")
private_base_0 = find_index("s_mov_b64", "s[0:1], src_private_base")
private_add_0 = find_index("s_add_u32", "s0, s0, s5", private_base_0 + 1)
private_addc_0 = find_index("s_addc_u32", "s1, s1, 0", private_add_0 + 1)
spill_add_0 = find_index("s_add_u32", "s0, s0, 0x210", private_addc_0 + 1)
spill_addc_0 = find_index("s_addc_u32", "s1, s1, 0", spill_add_0 + 1)
addr_lo_0 = find_index("v_mov_b32_e32", "v6, s0", spill_addc_0 + 1)
addr_hi_0 = find_index("v_mov_b32_e32", "v7, s1", addr_lo_0 + 1)
tail_copy = find_index("v_mov_b32_e32", "v8, v0", addr_hi_0 + 1)
tail_add_0 = find_index("s_add_u32", "s0, s0, 0x8", tail_copy + 1)
tail_addc_0 = find_index("s_addc_u32", "s1, s1, 0", tail_add_0 + 1)
tail_addr_lo_0 = find_index("v_mov_b32_e32", "v6, s0", tail_addc_0 + 1)
tail_addr_hi_0 = find_index("v_mov_b32_e32", "v7, s1", tail_addr_lo_0 + 1)
store_tail = find_index("flat_store_dword", "v[6:7], v8", tail_addr_hi_0 + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s8", store_tail + 1)
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s9", restore_lo_before_clobber + 1)
clobber_v0 = find_index("v_mov_b32_e32", "v0, 0", restore_hi_before_clobber + 1)
private_base_1 = find_index("s_mov_b64", "s[0:1], src_private_base", clobber_v0 + 1)
private_add_1 = find_index("s_add_u32", "s0, s0, s5", private_base_1 + 1)
private_addc_1 = find_index("s_addc_u32", "s1, s1, 0", private_add_1 + 1)
spill_add_1 = find_index("s_add_u32", "s0, s0, 0x210", private_addc_1 + 1)
spill_addc_1 = find_index("s_addc_u32", "s1, s1, 0", spill_add_1 + 1)
addr_lo_1 = find_index("v_mov_b32_e32", "v6, s0", spill_addc_1 + 1)
addr_hi_1 = find_index("v_mov_b32_e32", "v7, s1", addr_lo_1 + 1)
tail_add_1 = find_index("s_add_u32", "s0, s0, 0x8", addr_hi_1 + 1)
tail_addc_1 = find_index("s_addc_u32", "s1, s1, 0", tail_add_1 + 1)
tail_addr_lo_1 = find_index("v_mov_b32_e32", "v6, s0", tail_addc_1 + 1)
tail_addr_hi_1 = find_index("v_mov_b32_e32", "v7, s1", tail_addr_lo_1 + 1)
load_tail = find_index("flat_load_dword", "v8, v[6:7]", tail_addr_hi_1 + 1)
restore_v0 = find_index("v_mov_b32_e32", "v0, v8", load_tail + 1)
wait = find_index("s_waitcnt", "vmcnt(0)", restore_v0 + 1)
restore_lo_after_load = find_index("s_mov_b32", "s0, s8", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s9", restore_lo_after_load + 1)
branch = find_index("s_setpc_b64", "s[10:11]", restore_hi_after_load + 1)

assert save_lo < save_hi < private_base_0 < private_add_0 < private_addc_0 < spill_add_0 < spill_addc_0 < addr_lo_0 < addr_hi_0 < tail_copy
assert tail_copy < tail_add_0 < tail_addc_0 < tail_addr_lo_0 < tail_addr_hi_0 < store_tail
assert store_tail < restore_lo_before_clobber < restore_hi_before_clobber < clobber_v0
assert clobber_v0 < private_base_1 < private_add_1 < private_addc_1 < spill_add_1 < spill_addc_1 < addr_lo_1 < addr_hi_1
assert addr_hi_1 < tail_add_1 < tail_addc_1 < tail_addr_lo_1 < tail_addr_hi_1 < load_tail < restore_v0 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < branch

print(json.dumps({"plan": plan, "instruction_count": len(instructions)}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["plan"]["pattern_class"] == "packed_v0_10_10_10_unpack"
assert payload["plan"]["private_segment_pattern_class"] == "src_private_base"
assert payload["plan"]["address_vgprs"] == [6, 7]
assert payload["plan"]["tail_data_vgpr"] == 8
assert payload["instruction_count"] > 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx942 wrapper IR builds through the expected src_private_base scalar-tail carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 wrapper IR output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 wrapper IR construction failed unexpectedly"
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

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_plan_gfx1030_direct"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the offline workitem spill/restore planner derives the wave32 setreg-flat-scratch carrier plan for gfx1030"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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

_, analysis, recipe, kernel_metadata, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
pair_candidates = analysis.get("entry_dead_sgpr_pair_candidates", [])
assert isinstance(pair_candidates, list) and len(pair_candidates) >= 2, pair_candidates
assert list(scratch_pair) == [12, 13], scratch_pair
assert pair_candidates[1]["pair"] == [14, 15], pair_candidates
assert analysis["entry_wrapper_supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert recipe.get("supported") is True
assert recipe.get("supported_class") == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"

plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=(12, 13),
    branch_pair=(14, 15),
)
assert plan["source_vgprs"] == [0, 1, 2], plan
assert plan["pattern_class"] == "direct_vgpr_xyz", plan
assert plan["spill_offset"] == 528, plan
assert plan["spill_bytes"] == 12, plan
assert plan["private_segment_growth"] == 16, plan
assert plan["private_segment_pattern_class"] == "setreg_flat_scratch_init", plan
assert plan["private_segment_offset_source_sgpr"] == 11, plan
assert plan["save_pair"] == [12, 13], plan
assert plan["branch_pair"] == [14, 15], plan
assert plan["soffset_sgpr"] == 14, plan

print(json.dumps(plan, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["source_vgprs"] == [0, 1, 2]
assert payload["spill_offset"] == 528
assert payload["spill_bytes"] == 12
assert payload["private_segment_growth"] == 16
assert payload["private_segment_pattern_class"] == "setreg_flat_scratch_init"
assert payload["private_segment_offset_source_sgpr"] == 11
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - gfx1030 workitem spill/restore planning produces the expected wave32 setreg-flat-scratch carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - gfx1030 workitem spill/restore planning output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - gfx1030 workitem spill/restore planner failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="entry_wrapper_workitem_ir_gfx1030_direct"
STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate direct wrapper IR construction emits the wave32 buffer spill/restore sequence for gfx1030"

if python3 - "$REPO_ROOT" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
    "entry_abi_kernel" > "$STDOUT_FILE" 2> "$STDERR_FILE" <<'PY'
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
    build_entry_wrapper_ir,
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

_, analysis, _, kernel_metadata, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)
plan = build_entry_wrapper_workitem_spill_restore_plan(
    analysis=analysis,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
    save_pair=(scratch_pair[0], scratch_pair[1]),
    branch_pair=(14, 15),
)
wrapper = build_entry_wrapper_ir(
    wrapper_name=function_name,
    body_name="__body",
    start_address=0x1000,
    scratch_pair=(14, 15),
    workitem_spill_restore_plan=plan,
)
instructions = wrapper.get("instructions", [])

def find_index(mnemonic: str, operand_text: str, start: int = 0) -> int:
    for index in range(start, len(instructions)):
        insn = instructions[index]
        if insn.get("mnemonic") == mnemonic and insn.get("operand_text") == operand_text:
            return index
    raise AssertionError(f"missing instruction: {mnemonic} {operand_text}")


save_lo = find_index("s_mov_b32", "s12, s0")
save_hi = find_index("s_mov_b32", "s13, s1")
private_add_0 = find_index("s_add_u32", "s0, s0, s11", save_hi + 1)
private_addc_0 = find_index("s_addc_u32", "s1, s1, 0", private_add_0 + 1)
soffset_0 = find_index("s_mov_b32", "s14, 0", private_addc_0 + 1)
store_v0 = find_index("buffer_store_dword", "v0, off, s[0:3], s14 offset:528", soffset_0 + 1)
store_v1 = find_index("buffer_store_dword", "v1, off, s[0:3], s14 offset:532", store_v0 + 1)
store_v2 = find_index("buffer_store_dword", "v2, off, s[0:3], s14 offset:536", store_v1 + 1)
restore_lo_before_clobber = find_index("s_mov_b32", "s0, s12", store_v2 + 1)
restore_hi_before_clobber = find_index("s_mov_b32", "s1, s13", restore_lo_before_clobber + 1)
clobber_v0 = find_index("v_mov_b32_e32", "v0, 0", restore_hi_before_clobber + 1)
clobber_v1 = find_index("v_mov_b32_e32", "v1, 0", clobber_v0 + 1)
clobber_v2 = find_index("v_mov_b32_e32", "v2, 0", clobber_v1 + 1)
private_add_1 = find_index("s_add_u32", "s0, s0, s11", clobber_v2 + 1)
private_addc_1 = find_index("s_addc_u32", "s1, s1, 0", private_add_1 + 1)
soffset_1 = find_index("s_mov_b32", "s14, 0", private_addc_1 + 1)
load_v0 = find_index("buffer_load_dword", "v0, off, s[0:3], s14 offset:528", soffset_1 + 1)
load_v1 = find_index("buffer_load_dword", "v1, off, s[0:3], s14 offset:532", load_v0 + 1)
load_v2 = find_index("buffer_load_dword", "v2, off, s[0:3], s14 offset:536", load_v1 + 1)
wait = find_index("s_waitcnt", "vmcnt(0)", load_v2 + 1)
restore_lo_after_load = find_index("s_mov_b32", "s0, s12", wait + 1)
restore_hi_after_load = find_index("s_mov_b32", "s1, s13", restore_lo_after_load + 1)
getpc = find_index("s_getpc_b64", "s[14:15]", restore_hi_after_load + 1)
add_lo = find_index("s_add_u32", "s14, s14, __body@rel32@lo+4", getpc + 1)
add_hi = find_index("s_addc_u32", "s15, s15, __body@rel32@hi+4", add_lo + 1)
branch = find_index("s_setpc_b64", "s[14:15]", add_hi + 1)

assert save_lo < save_hi < private_add_0 < private_addc_0 < soffset_0 < store_v0 < store_v1 < store_v2
assert store_v2 < restore_lo_before_clobber < restore_hi_before_clobber < clobber_v0 < clobber_v1 < clobber_v2
assert clobber_v2 < private_add_1 < private_addc_1 < soffset_1 < load_v0 < load_v1 < load_v2 < wait
assert wait < restore_lo_after_load < restore_hi_after_load < getpc < add_lo < add_hi < branch

print(json.dumps({"plan": plan, "instruction_count": len(instructions)}, indent=2))
PY
then
    if python3 - "$STDOUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["plan"]["private_segment_pattern_class"] == "setreg_flat_scratch_init"
assert payload["plan"]["save_pair"] == [12, 13]
assert payload["plan"]["branch_pair"] == [14, 15]
assert payload["instruction_count"] > 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - gfx1030 wrapper IR now builds through the expected wave32 buffer spill/restore carrier"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - gfx1030 wrapper IR output was malformed"
        echo "  Stdout saved to: $STDOUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - gfx1030 wrapper IR construction failed unexpectedly"
    echo "  Stdout saved to: $STDOUT_FILE"
    echo "  Stderr saved to: $STDERR_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

if [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ]; then
    echo -e "\n${YELLOW}SKIP${NC} - Packed fixture regeneration tests require llvm-mc and ld.lld"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="entry_wrapper_workitem_regen_gfx1030_direct"
    PROOF_HSACO="$WORK_DIR/${TEST_NAME}.hsaco"
    PROOF_REPORT="$WORK_DIR/${TEST_NAME}.report.json"
    PROOF_MANIFEST="$WORK_DIR/${TEST_NAME}.manifest.json"
    PROOF_IR="$WORK_DIR/${TEST_NAME}.ir.json"
    STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
    STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Validate gfx1030 fixtures round-trip through regenerate_code_object proof mode"

    if python3 "$REGENERATE_CODE_OBJECT" \
        --input-ir "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.ir.json" \
        --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx1030.manifest.json" \
        --output "$PROOF_HSACO" \
        --report-output "$PROOF_REPORT" \
        --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
        --kernel entry_abi_kernel \
        --keep-temp-dir \
        --llvm-mc "$LLVM_MC" \
        --ld-lld "$LD_LLD" > "$STDOUT_FILE" 2> "$STDERR_FILE" && \
       python3 "$INSPECT_CODE_OBJECT" "$PROOF_HSACO" --output "$PROOF_MANIFEST" >/dev/null && \
       python3 "$DISASM_TO_IR" "$PROOF_HSACO" --manifest "$PROOF_MANIFEST" --output "$PROOF_IR" >/dev/null; then
        if python3 - "$PROOF_REPORT" "$PROOF_IR" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
ir = json.load(open(sys.argv[2], encoding="utf-8"))

assert report["input_code_object"] is None
assert report["input_ir_source"].endswith("amdgpu_entry_abi_gfx1030.ir.json")
entry = report["entry_wrapper_result"]
assert entry["mode"] == "entry-wrapper-workitem-vgpr-capture-restore-proof"
assert entry["source_kernel"] == "entry_abi_kernel"
assert entry["entry_handoff_recipe"]["supported_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
workitem = entry["workitem_spill_restore"]
assert workitem["source_vgprs"] == [0, 1, 2]
assert workitem["spill_offset"] == 528
assert workitem["spill_bytes"] == 12
assert workitem["private_segment_growth"] == 16
assert workitem["private_segment_pattern_class"] == "setreg_flat_scratch_init"
assert workitem["private_segment_offset_source_sgpr"] == 11
assert workitem["save_pair"] == [12, 13]
assert workitem["soffset_sgpr"] == 14

wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "entry_abi_kernel")
instructions = [(insn.get("mnemonic"), insn.get("operand_text")) for insn in wrapper.get("instructions", [])]
assert ("buffer_store_dword", "v0, off, s[0:3], s14 offset:528") in instructions
assert ("buffer_store_dword", "v1, off, s[0:3], s14 offset:532") in instructions
assert ("buffer_store_dword", "v2, off, s[0:3], s14 offset:536") in instructions
assert ("buffer_load_dword", "v0, off, s[0:3], s14 offset:528") in instructions
assert ("buffer_load_dword", "v1, off, s[0:3], s14 offset:532") in instructions
assert ("buffer_load_dword", "v2, off, s[0:3], s14 offset:536") in instructions
assert ("s_setpc_b64", "s[14:15]") in instructions
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - gfx1030 fixture proof survives the regenerate/rebuild/disassemble path"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - gfx1030 regeneration proof output was incorrect"
            echo "  Report saved to: $PROOF_REPORT"
            echo "  IR saved to: $PROOF_IR"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - gfx1030 regeneration proof failed unexpectedly"
        echo "  Stdout saved to: $STDOUT_FILE"
        echo "  Stderr saved to: $STDERR_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="entry_wrapper_workitem_regen_gfx90a_packed"
    PROOF_HSACO="$WORK_DIR/${TEST_NAME}.hsaco"
    PROOF_REPORT="$WORK_DIR/${TEST_NAME}.report.json"
    PROOF_MANIFEST="$WORK_DIR/${TEST_NAME}.manifest.json"
    PROOF_IR="$WORK_DIR/${TEST_NAME}.ir.json"
    STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
    STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Validate packed gfx90a fixtures round-trip through regenerate_code_object proof mode"

    if python3 "$REGENERATE_CODE_OBJECT" \
        --input-ir "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
        --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
        --output "$PROOF_HSACO" \
        --report-output "$PROOF_REPORT" \
        --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
        --kernel entry_abi_kernel \
        --keep-temp-dir \
        --llvm-mc "$LLVM_MC" \
        --ld-lld "$LD_LLD" > "$STDOUT_FILE" 2> "$STDERR_FILE" && \
       python3 "$INSPECT_CODE_OBJECT" "$PROOF_HSACO" --output "$PROOF_MANIFEST" >/dev/null && \
       python3 "$DISASM_TO_IR" "$PROOF_HSACO" --manifest "$PROOF_MANIFEST" --output "$PROOF_IR" >/dev/null; then
        if python3 - "$PROOF_REPORT" "$PROOF_IR" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
ir = json.load(open(sys.argv[2], encoding="utf-8"))

assert report["input_code_object"] is None
assert report["input_ir_source"].endswith("amdgpu_entry_abi_gfx90a.ir.json")
entry = report["entry_wrapper_result"]
assert entry["mode"] == "entry-wrapper-workitem-vgpr-capture-restore-proof"
assert entry["source_kernel"] == "entry_abi_kernel"
assert entry["entry_handoff_recipe"]["supported_class"] == "wave64-packed-v0-10_10_10-flat-scratch-alias-v1"
workitem = entry["workitem_spill_restore"]
assert workitem["source_vgprs"] == [0]
assert workitem["spill_offset"] == 528
assert workitem["spill_bytes"] == 4
assert workitem["private_segment_growth"] == 16
assert workitem["private_segment_pattern_class"] == "flat_scratch_alias_init"
assert workitem["save_pair"] == [12, 13]
assert workitem["soffset_sgpr"] == 14

wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "entry_abi_kernel")
instructions = [(insn.get("mnemonic"), insn.get("operand_text")) for insn in wrapper.get("instructions", [])]
assert ("buffer_store_dword", "v0, off, s[0:3], s14 offset:528") in instructions
assert ("buffer_load_dword", "v0, off, s[0:3], s14 offset:528") in instructions
assert ("s_setpc_b64", "s[14:15]") in instructions
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx90a fixture proof survives the regenerate/rebuild/disassemble path"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a regeneration proof output was incorrect"
            echo "  Report saved to: $PROOF_REPORT"
            echo "  IR saved to: $PROOF_IR"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx90a regeneration proof failed unexpectedly"
        echo "  Stdout saved to: $STDOUT_FILE"
        echo "  Stderr saved to: $STDERR_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="entry_wrapper_workitem_regen_gfx942_packed"
    PROOF_HSACO="$WORK_DIR/${TEST_NAME}.hsaco"
    PROOF_REPORT="$WORK_DIR/${TEST_NAME}.report.json"
    PROOF_MANIFEST="$WORK_DIR/${TEST_NAME}.manifest.json"
    PROOF_IR="$WORK_DIR/${TEST_NAME}.ir.json"
    STDOUT_FILE="$WORK_DIR/${TEST_NAME}.stdout"
    STDERR_FILE="$WORK_DIR/${TEST_NAME}.stderr"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Validate packed gfx942 fixtures round-trip through regenerate_code_object proof mode"

    if python3 "$REGENERATE_CODE_OBJECT" \
        --input-ir "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
        --manifest "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
        --output "$PROOF_HSACO" \
        --report-output "$PROOF_REPORT" \
        --add-entry-wrapper-workitem-vgpr-capture-restore-proof \
        --kernel entry_abi_kernel \
        --keep-temp-dir \
        --llvm-mc "$LLVM_MC" \
        --ld-lld "$LD_LLD" > "$STDOUT_FILE" 2> "$STDERR_FILE" && \
       python3 "$INSPECT_CODE_OBJECT" "$PROOF_HSACO" --output "$PROOF_MANIFEST" >/dev/null && \
       python3 "$DISASM_TO_IR" "$PROOF_HSACO" --manifest "$PROOF_MANIFEST" --output "$PROOF_IR" >/dev/null; then
        if python3 - "$PROOF_REPORT" "$PROOF_IR" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
ir = json.load(open(sys.argv[2], encoding="utf-8"))

assert report["input_code_object"] is None
assert report["input_ir_source"].endswith("amdgpu_entry_abi_gfx942.ir.json")
entry = report["entry_wrapper_result"]
assert entry["mode"] == "entry-wrapper-workitem-vgpr-capture-restore-proof"
assert entry["source_kernel"] == "entry_abi_kernel"
assert entry["entry_handoff_recipe"]["supported_class"] == "wave64-packed-v0-10_10_10-src-private-base-v1"
workitem = entry["workitem_spill_restore"]
assert workitem["source_vgprs"] == [0]
assert workitem["spill_offset"] == 528
assert workitem["spill_bytes"] == 4
assert workitem["private_segment_growth"] == 16
assert workitem["private_segment_pattern_class"] == "src_private_base"
assert workitem["address_vgprs"] == [6, 7]
assert workitem["tail_data_vgpr"] == 8
assert workitem["required_total_vgprs"] == 9
assert workitem["save_pair"] == [8, 9]
assert workitem["soffset_sgpr"] == 10

wrapper = next(fn for fn in ir["functions"] if fn.get("name") == "entry_abi_kernel")
instructions = [(insn.get("mnemonic"), insn.get("operand_text")) for insn in wrapper.get("instructions", [])]
assert ("flat_store_dword", "v[6:7], v8") in instructions
assert ("flat_load_dword", "v8, v[6:7]") in instructions
assert ("s_setpc_b64", "s[10:11]") in instructions
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - Packed gfx942 fixture proof survives the regenerate/rebuild/disassemble path"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 regeneration proof output was incorrect"
            echo "  Report saved to: $PROOF_REPORT"
            echo "  IR saved to: $PROOF_IR"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Packed gfx942 regeneration proof failed unexpectedly"
        echo "  Stdout saved to: $STDOUT_FILE"
        echo "  Stderr saved to: $STDERR_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
