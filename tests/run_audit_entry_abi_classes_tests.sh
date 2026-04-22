#!/bin/bash
################################################################################
# Entry-ABI class audit tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

AUDIT_TOOL="${REPO_ROOT}/tools/codeobj/audit_entry_abi_classes.py"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"

echo ""
echo "================================================================================"
echo "Entry-ABI Class Audit Tests"
echo "================================================================================"
echo "  Tool: $AUDIT_TOOL"
echo "================================================================================"

if [ ! -f "$AUDIT_TOOL" ]; then
    echo -e "${RED}ERROR: required audit tool is missing${NC}"
    exit 1
fi

WORK_DIR="$OUTPUT_DIR/audit_entry_abi_classes"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="audit_entry_abi_classes_fixture_ir_manifest"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$REPO_ROOT" "$WORK_DIR" "$SCRIPT_DIR" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
work_dir = Path(sys.argv[2]).resolve()
script_dir = Path(sys.argv[3]).resolve()

base_ir = json.loads((script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx90a_mi210_direct.ir.json").read_text())
base_manifest = json.loads((script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json").read_text())

mlk_xyz_function = base_ir["functions"][0]
decoy_function = json.loads(json.dumps(mlk_xyz_function))
decoy_function["name"] = "decoy_kernel"

descriptor = base_manifest["kernels"]["descriptors"][0]
decoy_descriptor = json.loads(json.dumps(descriptor))
decoy_descriptor["name"] = "decoy_kernel.kd"
decoy_descriptor["kernel_name"] = "decoy_kernel"

function_symbol = base_manifest["kernels"]["function_symbols"][0]
decoy_function_symbol = json.loads(json.dumps(function_symbol))
decoy_function_symbol["name"] = "decoy_kernel"

metadata_kernel = base_manifest["kernels"]["metadata"]["kernels"][0]
decoy_metadata_kernel = json.loads(json.dumps(metadata_kernel))
decoy_metadata_kernel["name"] = "decoy_kernel"
decoy_metadata_kernel["symbol"] = "decoy_kernel.kd"

composite_ir = {
    "arch": base_ir["arch"],
    "functions": [decoy_function, mlk_xyz_function],
}
composite_manifest = json.loads(json.dumps(base_manifest))
composite_manifest["kernels"]["function_symbols"] = [decoy_function_symbol, function_symbol]
composite_manifest["kernels"]["descriptors"] = [decoy_descriptor, descriptor]
composite_manifest["kernels"]["metadata"]["kernels"] = [decoy_metadata_kernel, metadata_kernel]

input_ir = work_dir / "composite.ir.json"
input_manifest = work_dir / "composite.manifest.json"
output_json = work_dir / "audit.json"
input_ir.write_text(json.dumps(composite_ir, indent=2) + "\n", encoding="utf-8")
input_manifest.write_text(json.dumps(composite_manifest, indent=2) + "\n", encoding="utf-8")

subprocess.run(
    [
        sys.executable,
        str(repo_root / "tools" / "codeobj" / "audit_entry_abi_classes.py"),
        "--input-ir",
        str(input_ir),
        "--input-manifest",
        str(input_manifest),
        "--output",
        str(output_json),
    ],
    check=True,
)

payload = json.loads(output_json.read_text(encoding="utf-8"))
kernels = {entry["kernel_name"]: entry for entry in payload["kernels"]}
assert kernels["mlk_xyz"]["recognized_class"] == "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"
assert kernels["mlk_xyz"]["implemented_in_runtime_wrapper"] is True
assert kernels["mlk_xyz"]["workitem_pattern"] == "direct_vgpr_xyz"
assert kernels["mlk_xyz"]["private_pattern"] == "flat_scratch_alias_init"
assert kernels["decoy_kernel"]["recognized_class"] == "wave64-direct-vgpr-xyz-flat-scratch-alias-v1"
assert kernels["decoy_kernel"]["implemented_in_runtime_wrapper"] is True
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Audit tool reported the expected MI210 direct-entry class inventory from IR+manifest input"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Audit tool IR+manifest mode did not report the expected class inventory"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="audit_entry_abi_classes_code_object"
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
code_object = Path(sys.argv[3]).resolve()
output_json = work_dir / "code_object_audit.json"

subprocess.run(
    [
        sys.executable,
        str(repo_root / "tools" / "codeobj" / "audit_entry_abi_classes.py"),
        "--input-code-object",
        str(code_object),
        "--output",
        str(output_json),
    ],
    check=True,
)

payload = json.loads(output_json.read_text(encoding="utf-8"))
kernels = {entry["kernel_name"]: entry for entry in payload["kernels"]}
assert "mlk" in kernels
assert "mlk_d" in kernels
assert "mlk_xyz" in kernels
assert kernels["mlk"]["recognized_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert kernels["mlk"]["implemented_in_runtime_wrapper"] is True
assert kernels["mlk_d"]["recognized_class"] == "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1"
assert kernels["mlk_d"]["implemented_in_runtime_wrapper"] is True
assert kernels["mlk_xyz"]["recognized_class"] in {
    "wave32-direct-vgpr-xyz-setreg-flat-scratch-v1",
    "wave64-direct-vgpr-xyz-flat-scratch-alias-v1",
}
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Audit tool reported the expected kernel ABI inventory from a real code object"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Audit tool code-object mode did not report the expected class inventory"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

print_summary
