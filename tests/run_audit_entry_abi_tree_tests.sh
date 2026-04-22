#!/bin/bash
################################################################################
# Entry-ABI tree audit tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

TREE_AUDIT_TOOL="${REPO_ROOT}/tools/codeobj/audit_entry_abi_tree.py"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

echo ""
echo "================================================================================"
echo "Entry-ABI Tree Audit Tests"
echo "================================================================================"
echo "  Tool: $TREE_AUDIT_TOOL"
echo "================================================================================"

if [ ! -f "$TREE_AUDIT_TOOL" ]; then
    echo -e "${RED}ERROR: required tree audit tool is missing${NC}"
    exit 1
fi

WORK_DIR="$OUTPUT_DIR/audit_entry_abi_tree"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="audit_entry_abi_tree_single_hsaco"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    echo -e "  ${YELLOW}SKIP${NC} - Required hsaco is not built: $MODULE_LOAD_PLAIN_HSACO"
else
    if python3 - "$REPO_ROOT" "$WORK_DIR" "$MODULE_LOAD_PLAIN_HSACO" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
work_dir = Path(sys.argv[2]).resolve()
hsaco = Path(sys.argv[3]).resolve()
audit_root = work_dir / "tree_root"
audit_root.mkdir(parents=True, exist_ok=True)
copied = audit_root / hsaco.name
copied.write_bytes(hsaco.read_bytes())
output_json = work_dir / "tree_audit.json"

subprocess.run(
    [
        sys.executable,
        str(repo_root / "tools" / "codeobj" / "audit_entry_abi_tree.py"),
        str(audit_root),
        "--output",
        str(output_json),
    ],
    check=True,
)

payload = json.loads(output_json.read_text(encoding="utf-8"))
assert payload["summary"]["code_object_count"] == 1
assert payload["summary"]["kernel_count"] == 3
assert len(payload["hsaco_paths"]) == 1
assert payload["code_objects"][0]["path"].endswith(hsaco.name)
kernels = {entry["kernel_name"]: entry for entry in payload["code_objects"][0]["kernels"]}
assert kernels["mlk"]["recognized_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert kernels["mlk_d"]["recognized_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert kernels["mlk_xyz"]["recognized_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert payload["summary"]["recognized_class_counts"]["wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"] == 3
assert payload["summary"]["runtime_wrapper_coverage"]["implemented"] == 3
assert payload["summary"]["runtime_wrapper_coverage"]["not_implemented"] == 0
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Tree audit summarized the expected RDNA class inventory from a copied hsaco tree"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Tree audit did not report the expected hsaco inventory"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
