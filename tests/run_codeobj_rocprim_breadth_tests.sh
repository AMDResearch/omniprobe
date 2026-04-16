#!/bin/bash
################################################################################
# rocPRIM donor-free breadth tests
#
# Builds one representative rocPRIM benchmark, extracts its bundled code object,
# and checks donor-free hidden-ABI regeneration on a bounded set of kernels from
# a real multi-kernel code object.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build-hsaco-core}"

HIPCC="${HIPCC:-/opt/rocm/bin/hipcc}"
ROCM_AGENT_ENUMERATOR="${ROCM_AGENT_ENUMERATOR:-/opt/rocm/bin/rocm_agent_enumerator}"
EXTRACT_CODE_OBJECTS="${BUILD_DIR}/tools/extract_code_objects"
PREPARE_CACHE_TOOL="${REPO_ROOT}/tools/codeobj/prepare_hsaco_cache.py"
INSPECT_TOOL="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"

ROCPRIM_REPO_URL="${ROCPRIM_REPO_URL:-https://github.com/ROCm/rocPRIM.git}"
ROCPRIM_SRC="${ROCPRIM_SRC:-/tmp/rocPRIM}"
ROCPRIM_BUILD="${ROCPRIM_BUILD:-/tmp/rocPRIM-build}"
ROCPRIM_TARGET="${ROCPRIM_TARGET:-benchmark_device_partition}"

if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP: git and cmake are required for rocPRIM breadth coverage${NC}"
    exit 0
fi

if [ ! -x "$HIPCC" ] || [ ! -x "$ROCM_AGENT_ENUMERATOR" ] || \
   [ ! -x "$EXTRACT_CODE_OBJECTS" ] || [ ! -f "$PREPARE_CACHE_TOOL" ] || \
   [ ! -f "$INSPECT_TOOL" ]; then
    echo -e "${YELLOW}SKIP: ROCm toolchain or Omniprobe code-object tools not available${NC}"
    echo "  hipcc: $HIPCC"
    echo "  rocm_agent_enumerator: $ROCM_AGENT_ENUMERATOR"
    echo "  extract_code_objects: $EXTRACT_CODE_OBJECTS"
    exit 0
fi

HIP_ARCH="${HIP_ARCH:-$("$ROCM_AGENT_ENUMERATOR" | grep '^gfx' | head -n 1)}"
if [ -z "$HIP_ARCH" ]; then
    echo -e "${YELLOW}SKIP: no GPU ISA reported by rocm_agent_enumerator${NC}"
    exit 0
fi

echo ""
echo "================================================================================"
echo "rocPRIM Breadth Tests"
echo "================================================================================"
echo "  rocPRIM repo: $ROCPRIM_REPO_URL"
echo "  Target arch:  $HIP_ARCH"
echo "================================================================================"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$OUTPUT_DIR/codeobj_rocprim_breadth"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if [ ! -d "$ROCPRIM_SRC/.git" ]; then
    if ! git clone --depth 1 "$ROCPRIM_REPO_URL" "$ROCPRIM_SRC" >/dev/null 2>&1; then
        echo -e "${YELLOW}SKIP: unable to clone rocPRIM from $ROCPRIM_REPO_URL${NC}"
        exit 0
    fi
fi

cmake -S "$ROCPRIM_SRC" -B "$ROCPRIM_BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER="$HIPCC" \
    -DBUILD_BENCHMARK=ON \
    -DBUILD_TEST=OFF \
    -DBUILD_EXAMPLE=OFF \
    -DGPU_TARGETS="$HIP_ARCH" >/dev/null
cmake --build "$ROCPRIM_BUILD" --target "$ROCPRIM_TARGET" -j4 >/dev/null

BENCHMARK_EXE="$ROCPRIM_BUILD/benchmark/$ROCPRIM_TARGET"
if [ ! -x "$BENCHMARK_EXE" ]; then
    echo -e "${RED}ERROR: rocPRIM benchmark executable not found: $BENCHMARK_EXE${NC}"
    exit 1
fi

EXTRACTED_LIST="$WORK_DIR/extracted_code_objects.txt"
"$EXTRACT_CODE_OBJECTS" "$BENCHMARK_EXE" > "$EXTRACTED_LIST"
INPUT_CO="$(grep '^/' "$EXTRACTED_LIST" | tail -n 1 || true)"

if [ ! -f "$INPUT_CO" ]; then
    echo -e "${RED}ERROR: no code object was extracted from $BENCHMARK_EXE${NC}"
    exit 1
fi

SOURCE_MANIFEST="$WORK_DIR/rocprim_input.manifest.json"
python3 "$INSPECT_TOOL" "$INPUT_CO" --output "$SOURCE_MANIFEST" >/dev/null

run_cache_prep() {
    local tag="$1"
    local filter="$2"
    local output_dir="$WORK_DIR/$tag"
    mkdir -p "$output_dir"
    python3 "$PREPARE_CACHE_TOOL" \
        --output-dir "$output_dir" \
        --surrogate-mode donor-free \
        --kernel-filter "$filter" \
        "$INPUT_CO" > "$output_dir/prepare.json"
}

TRANSFORM_PREP_OK=0
INIT_SCAN_PREP_OK=0
PARTITION_PREP_OK=0

if run_cache_prep "transform" "transform_kernel"; then
    TRANSFORM_PREP_OK=1
fi

if run_cache_prep "init_scan" "init_lookback_scan_state_kernel"; then
    INIT_SCAN_PREP_OK=1
fi

if run_cache_prep "partition" "partition_kernel.*empty_type.*Pi"; then
    PARTITION_PREP_OK=1
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocprim_transform_surrogate_generation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ "$TRANSFORM_PREP_OK" -eq 1 ] && ls "$WORK_DIR/transform"/*.surrogate.report.json >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - transform_kernel donor-free surrogate was generated"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No transform_kernel surrogate report was generated"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocprim_init_scan_surrogate_generation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ "$INIT_SCAN_PREP_OK" -eq 1 ] && ls "$WORK_DIR/init_scan"/*.surrogate.report.json >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - init_lookback_scan_state_kernel donor-free surrogate was generated"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No init_lookback_scan_state_kernel surrogate report was generated"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

PARTITION_REPORT="$(find "$WORK_DIR/partition" -name '*.surrogate.report.json' -print -quit)"
PARTITION_HSACO=""
if [ -n "$PARTITION_REPORT" ]; then
    PARTITION_HSACO="${PARTITION_REPORT%.report.json}.hsaco"
fi
PARTITION_MANIFEST="$WORK_DIR/partition.manifest.json"

if [ "$PARTITION_PREP_OK" -eq 1 ] && [ -n "$PARTITION_HSACO" ]; then
    python3 "$INSPECT_TOOL" "$PARTITION_HSACO" --output "$PARTITION_MANIFEST" >/dev/null
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="rocprim_partition_hidden_abi_fidelity"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"

if [ -z "$PARTITION_REPORT" ] || [ ! -f "$PARTITION_MANIFEST" ]; then
    echo -e "  ${RED}✗ FAIL${NC} - Partition surrogate artifacts were not produced"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif python3 - "$SOURCE_MANIFEST" "$PARTITION_MANIFEST" "$PARTITION_REPORT" <<'PY'
import json
import sys

source_manifest = json.load(open(sys.argv[1], encoding="utf-8"))
clone_manifest = json.load(open(sys.argv[2], encoding="utf-8"))
report = json.load(open(sys.argv[3], encoding="utf-8"))

clone_result = report["clone_result"]
source_kernel = clone_result["source_kernel"]
clone_kernel = clone_result["clone_kernel"]
hidden_offset = int(clone_result["hidden_omniprobe_ctx"]["offset"])

def kernel_meta(manifest, kernel_name):
    for kernel in manifest["kernels"]["metadata"]["kernels"]:
        if kernel.get("name") == kernel_name or kernel.get("symbol") == kernel_name:
            return kernel
    raise AssertionError(f"kernel metadata for {kernel_name!r} not found")

def descriptor(manifest, kernel_name):
    for item in manifest["kernels"]["descriptors"]:
        if item.get("kernel_name") == kernel_name:
            return item
    raise AssertionError(f"descriptor for {kernel_name!r} not found")

src_meta = kernel_meta(source_manifest, source_kernel)
clone_meta = kernel_meta(clone_manifest, clone_kernel)
src_desc = descriptor(source_manifest, source_kernel)
clone_desc = descriptor(clone_manifest, clone_kernel)

src_size = int(src_meta.get("kernarg_segment_size", 0))
clone_size = int(clone_meta.get("kernarg_segment_size", 0))
assert clone_size > src_size

clone_args = clone_meta.get("args", [])
hidden_arg = next(
    arg
    for arg in clone_args
    if arg.get("name") == "hidden_omniprobe_ctx" or arg.get("value_kind") == "hidden_omniprobe_ctx"
)
assert int(hidden_arg["offset"]) == hidden_offset

for field in ("compute_pgm_rsrc1", "compute_pgm_rsrc2", "kernel_code_properties"):
    assert src_desc.get(field) == clone_desc.get(field), field
PY
then
    echo -e "  ${GREEN}✓ PASS${NC} - Partition surrogate preserved descriptor controls while appending hidden_omniprobe_ctx"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Partition surrogate metadata/descriptor audit failed"
    echo "  Source manifest: $SOURCE_MANIFEST"
    echo "  Surrogate manifest: $PARTITION_MANIFEST"
    echo "  Report: $PARTITION_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
