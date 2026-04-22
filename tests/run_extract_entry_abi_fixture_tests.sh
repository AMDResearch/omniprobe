#!/bin/bash
################################################################################
# Entry-ABI fixture extraction tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

EXTRACT_TOOL="${REPO_ROOT}/tools/codeobj/extract_entry_abi_fixture.py"
ANALYZER="${REPO_ROOT}/tools/codeobj/analyze_amdgpu_entry_abi.py"

echo ""
echo "================================================================================"
echo "Entry-ABI Fixture Extraction Tests"
echo "================================================================================"
echo "  Tool: $EXTRACT_TOOL"
echo "================================================================================"

if [ ! -f "$EXTRACT_TOOL" ] || [ ! -f "$ANALYZER" ]; then
    echo -e "${RED}ERROR: required extraction tooling is missing${NC}"
    exit 1
fi

WORK_DIR="$OUTPUT_DIR/extract_entry_abi_fixture"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="extract_entry_abi_fixture_slices_target_kernel"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if python3 - "$SCRIPT_DIR" "$WORK_DIR" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve()
work_dir = Path(sys.argv[2]).resolve()
repo_root = script_dir.parent

base_ir_path = script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx90a_mi210_direct.ir.json"
base_manifest_path = script_dir / "probe_specs" / "fixtures" / "amdgpu_entry_abi_gfx90a_mi210_direct.manifest.json"
base_ir = json.loads(base_ir_path.read_text(encoding="utf-8"))
base_manifest = json.loads(base_manifest_path.read_text(encoding="utf-8"))

target_function = base_ir["functions"][0]
decoy_function = json.loads(json.dumps(target_function))
decoy_function["name"] = "decoy_kernel"

composite_ir = {
    "arch": base_ir["arch"],
    "functions": [decoy_function, target_function],
}

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

composite_manifest = json.loads(json.dumps(base_manifest))
composite_manifest["kernels"]["function_symbols"] = [
    decoy_function_symbol,
    function_symbol,
]
composite_manifest["kernels"]["descriptors"] = [
    decoy_descriptor,
    descriptor,
]
composite_manifest["kernels"]["metadata"]["kernels"] = [
    decoy_metadata_kernel,
    metadata_kernel,
]

input_ir = work_dir / "composite.ir.json"
input_manifest = work_dir / "composite.manifest.json"
output_ir = work_dir / "extracted.ir.json"
output_manifest = work_dir / "extracted.manifest.json"

input_ir.write_text(json.dumps(composite_ir, indent=2) + "\n", encoding="utf-8")
input_manifest.write_text(json.dumps(composite_manifest, indent=2) + "\n", encoding="utf-8")

subprocess.run(
    [
        sys.executable,
        str(repo_root / "tools" / "codeobj" / "extract_entry_abi_fixture.py"),
        "--input-ir",
        str(input_ir),
        "--input-manifest",
        str(input_manifest),
        "--function",
        "mlk_xyz",
        "--fixture-input-name",
        "tests/probe_specs/fixtures/generated_mlk_xyz_fixture.hsaco",
        "--output-ir",
        str(output_ir),
        "--output-manifest",
        str(output_manifest),
    ],
    check=True,
)

extracted_ir = json.loads(output_ir.read_text(encoding="utf-8"))
extracted_manifest = json.loads(output_manifest.read_text(encoding="utf-8"))

assert extracted_ir["arch"] == "gfx90a"
assert [entry["name"] for entry in extracted_ir["functions"]] == ["mlk_xyz"]
assert extracted_manifest["input"] == "tests/probe_specs/fixtures/generated_mlk_xyz_fixture.hsaco"
assert extracted_manifest["input_file"] == "tests/probe_specs/fixtures/generated_mlk_xyz_fixture.hsaco"
assert [entry["name"] for entry in extracted_manifest["kernels"]["function_symbols"]] == ["mlk_xyz"]
assert [entry["kernel_name"] for entry in extracted_manifest["kernels"]["descriptors"]] == ["mlk_xyz"]
assert [entry["name"] for entry in extracted_manifest["kernels"]["metadata"]["kernels"]] == ["mlk_xyz"]

analyzed = json.loads(
    subprocess.check_output(
        [
            sys.executable,
            str(repo_root / "tools" / "codeobj" / "analyze_amdgpu_entry_abi.py"),
            str(output_ir),
            "--manifest",
            str(output_manifest),
            "--function",
            "mlk_xyz",
        ],
        text=True,
    )
)
assert analyzed["observed_workitem_id_materialization"]["pattern_class"] == "direct_vgpr_xyz"
assert analyzed["observed_private_segment_materialization"]["pattern_class"] == "flat_scratch_alias_init"
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Extractor sliced a single target-kernel fixture and preserved MI210 entry-ABI facts"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Extractor did not preserve the expected single-kernel fixture slice"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
