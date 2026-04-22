#!/bin/bash
################################################################################
# Entry-wrapper unimplemented-class tests
#
# Validates that the executable wrapper precondition layer fails closed when it
# recognizes a source entry ABI class that is understood symbolically but not
# yet implemented in the runtime wrapper path.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

WORK_DIR="$OUTPUT_DIR/entry_wrapper_unimplemented_class"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PYTHON_CHECKER="$WORK_DIR/check_entry_wrapper_unimplemented_class.py"
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

from amdgpu_entry_abi import analyze_kernel_entry_abi  # type: ignore
from code_object_model import CodeObjectModel  # type: ignore
from regenerate_code_object import (  # type: ignore
    ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES,
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

analysis = analyze_kernel_entry_abi(
    function=function,
    descriptor=descriptor,
    kernel_metadata=kernel_metadata,
)
supported_class, blockers = classify_entry_handoff_supported_class(analysis)

assert supported_class == expected_class, {
    "supported_class": supported_class,
    "expected_class": expected_class,
    "blockers": blockers,
}
assert supported_class not in ENTRY_WRAPPER_PROOF_IMPLEMENTED_CLASSES

message = (
    "entry-wrapper proof recognized entry-handoff class "
    f"{supported_class} but that class is not implemented in the runtime wrapper yet"
)
print(message)
PY
chmod +x "$PYTHON_CHECKER"

run_unimplemented_class_test() {
    local arch="$1"
    local fixture_ir="$2"
    local fixture_manifest="$3"
    local expected_class="$4"

    TESTS_RUN=$((TESTS_RUN + 1))
    local test_name="entry_wrapper_unimplemented_class_${arch}"
    local stdout_file="$WORK_DIR/${test_name}.stdout"
    local stderr_file="$WORK_DIR/${test_name}.stderr"

    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"
    echo "  Validate executable wrapper preconditions reject recognized but unimplemented entry class ${expected_class}"

    if python3 "$PYTHON_CHECKER" \
        "$REPO_ROOT" \
        "$fixture_manifest" \
        "$fixture_ir" \
        entry_abi_kernel \
        "$expected_class" > "$stdout_file" 2> "$stderr_file"; then
        if python3 - "$stdout_file" "$expected_class" <<'PY'
from pathlib import Path
import sys

stdout_text = Path(sys.argv[1]).read_text(encoding="utf-8")
expected_class = sys.argv[2]
needle = (
    "entry-wrapper proof recognized entry-handoff class "
    f"{expected_class} but that class is not implemented in the runtime wrapper yet"
)
assert needle in stdout_text, stdout_text
PY
        then
            echo -e "  ${GREEN}✓ PASS${NC} - ${arch} executable wrapper preconditions fail closed with the expected unimplemented-class message"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - ${arch} executable wrapper preconditions did not emit the expected unimplemented-class message"
            echo "  Stdout saved to: $stdout_file"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - ${arch} executable wrapper precondition check failed unexpectedly"
        echo "  Stdout saved to: $stdout_file"
        echo "  Stderr saved to: $stderr_file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

run_unimplemented_class_test \
    "gfx90a" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx90a.manifest.json" \
    "wave64-packed-v0-10_10_10-flat-scratch-alias-v1"

run_unimplemented_class_test \
    "gfx942" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.ir.json" \
    "${SCRIPT_DIR}/probe_specs/fixtures/amdgpu_entry_abi_gfx942.manifest.json" \
    "wave64-packed-v0-10_10_10-src-private-base-v1"

print_summary
