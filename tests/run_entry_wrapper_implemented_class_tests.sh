#!/bin/bash
################################################################################
# Entry-wrapper implemented-class tests
#
# Validates that the executable wrapper precondition layer accepts only the
# entry ABI classes that are both recognized symbolically and implemented in
# the runtime wrapper path.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

WORK_DIR="$OUTPUT_DIR/entry_wrapper_implemented_class"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PYTHON_CHECKER="$WORK_DIR/check_entry_wrapper_implemented_class.py"
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
expected_class = sys.argv[5]

sys.path.insert(0, str(REPO_ROOT / "tools" / "codeobj"))

from regenerate_code_object import (  # type: ignore
    ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES,
    validate_entry_wrapper_proof_preconditions,
)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


manifest = load_json(manifest_path)
ir = load_json(ir_path)
_, analysis, recipe, _, scratch_pair = validate_entry_wrapper_proof_preconditions(
    manifest,
    ir,
    kernel_name=function_name,
)

supported_class = analysis.get("entry_wrapper_supported_class")
assert supported_class == expected_class, {
    "supported_class": supported_class,
    "expected_class": expected_class,
}
assert supported_class in ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES
assert recipe.get("supported") is True
assert recipe.get("supported_class") == expected_class

liveins = set(int(value) for value in analysis.get("entry_livein_sgprs", []) if isinstance(value, int))
assert scratch_pair[0] not in liveins
assert scratch_pair[1] not in liveins

print(
    json.dumps(
        {
            "supported_class": supported_class,
            "scratch_pair": list(scratch_pair),
            "entry_livein_sgprs": sorted(liveins),
        },
        indent=2,
    )
)
PY
chmod +x "$PYTHON_CHECKER"

run_implemented_class_test() {
    local test_id="$1"
    local fixture_ir="$2"
    local fixture_manifest="$3"
    local function_name="$4"
    local expected_class="$5"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="entry_wrapper_implemented_class_${test_id}"
    local stdout_file="$WORK_DIR/${test_name}.stdout"
    local stderr_file="$WORK_DIR/${test_name}.stderr"

    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Validate executable wrapper preconditions accept implemented entry class ${expected_class}"

    if python3 "$PYTHON_CHECKER" \
        "$REPO_ROOT" \
        "$fixture_manifest" \
        "$fixture_ir" \
        "$function_name" \
        "$expected_class" > "$stdout_file" 2> "$stderr_file"; then
        if python3 - "$stdout_file" "$expected_class" <<'PY'
from pathlib import Path
import json
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_class = sys.argv[2]
assert payload["supported_class"] == expected_class
assert len(payload["scratch_pair"]) == 2
assert payload["scratch_pair"][0] % 2 == 0
assert payload["scratch_pair"][1] == payload["scratch_pair"][0] + 1
assert payload["scratch_pair"][0] not in payload["entry_livein_sgprs"]
assert payload["scratch_pair"][1] not in payload["entry_livein_sgprs"]
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${test_id} executable wrapper preconditions accept the expected implemented class"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${test_id} executable wrapper preconditions returned malformed acceptance details"
            echo "  Stdout saved to: $stdout_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${test_id} executable wrapper precondition check failed unexpectedly"
        echo "  Stdout saved to: $stdout_file"
        echo "  Stderr saved to: $stderr_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_implemented_class_test \
    "gfx90a_packed" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "entry_abi_kernel" \
    "wave64-packed-v0-10_10_10-flat-scratch-alias-v1"

run_implemented_class_test \
    "gfx942_packed" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "entry_abi_kernel" \
    "wave64-packed-v0-10_10_10-src-private-base-v1"

run_implemented_class_test \
    "gfx90a_mi210_direct" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json" \
    "mlk_xyz" \
    "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"

run_implemented_class_test \
    "gfx942_real_single_vgpr" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_single_vgpr.manifest.json" \
    "Cijk_S_GA" \
    "wave64-single-vgpr-x-workgroup-x-kernarg-only-v1"

run_implemented_class_test \
    "gfx942_real_mlk_xyz" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942_real_mlk_xyz.manifest.json" \
    "mlk_xyz" \
    "wave64-direct-vgpr-xyz-src-private-base-v1"

print_summary
