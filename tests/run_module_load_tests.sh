#!/bin/bash
################################################################################
# Module-load kernel discovery tests for omniprobe
#
# Tests that omniprobe can discover instrumented kernels in .hsaco files loaded
# at runtime via hipModuleLoad.  The test kernel (module_load_kernel.hip) is
# compiled to a standalone .hsaco with the AddressMessages instrumentation
# plugin, and the host program (module_load_test) loads it at runtime.
#
# Current expected behavior (before kernel-discovery unification):
#   - Without --library-filter: instrumented alternative NOT found
#   - With    --library-filter: instrumented alternative found
#
# After the rf_unify-kernel-discovery refactor the first case should also
# find the instrumented alternative.
################################################################################

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe
OMNIPROBE_TIMEOUT="${OMNIPROBE_TIMEOUT:-20s}"

################################################################################
# Locate build artifacts
################################################################################

MODULE_LOAD_TEST="${BUILD_DIR}/tests/test_kernels/module_load_test"
MODULE_LOAD_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel.hsaco"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
MODULE_LOAD_MANUAL_CARRIER_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_manual_carrier_kernel.hsaco"
MODULE_LOAD_DONOR_SLOT_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_donor_slot_kernel.hsaco"
SIMPLE_HEATMAP_TEST="${BUILD_DIR}/tests/test_kernels/simple_heatmap_test"
EXTRACT_CODE_OBJECTS="${BUILD_DIR}/tools/extract_code_objects"
HIDDEN_KERNARG_REPACK_TEST="${BUILD_DIR}/tools/test_hidden_kernarg_repack"
PREPARE_HSACO_CACHE="${REPO_ROOT}/tools/codeobj/prepare_hsaco_cache.py"
AUDIT_CODE_OBJECT_STRUCTURE="${REPO_ROOT}/tools/codeobj/audit_code_object_structure.py"
INSPECT_CODE_OBJECT="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
RECLASSIFY_HIDDEN_ARG="${REPO_ROOT}/tools/codeobj/reclassify_kernel_arg_as_hidden.py"

if [ ! -x "$MODULE_LOAD_TEST" ] || [ ! -f "$MODULE_LOAD_HSACO" ] || [ ! -f "$MODULE_LOAD_PLAIN_HSACO" ] || [ ! -f "$MODULE_LOAD_MANUAL_CARRIER_HSACO" ] || [ ! -f "$MODULE_LOAD_DONOR_SLOT_HSACO" ] || [ ! -x "$HIDDEN_KERNARG_REPACK_TEST" ]; then
    echo -e "${YELLOW}SKIP: Module-load test artifacts not built${NC}"
    echo "  Expected: $MODULE_LOAD_TEST"
    echo "  Expected: $MODULE_LOAD_HSACO"
    echo "  Expected: $MODULE_LOAD_PLAIN_HSACO"
    echo "  Expected: $MODULE_LOAD_MANUAL_CARRIER_HSACO"
    echo "  Expected: $MODULE_LOAD_DONOR_SLOT_HSACO"
    echo "  Expected: $HIDDEN_KERNARG_REPACK_TEST"
    echo "  Build with: cmake --build build --target module_load_test module_load_kernel_hsaco module_load_kernel_plain_hsaco module_load_manual_carrier_hsaco module_load_donor_slot_hsaco test_hidden_kernarg_repack"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "================================================================================"
echo "Module-Load Kernel Discovery Tests"
echo "================================================================================"
echo "  Host binary: $MODULE_LOAD_TEST"
echo "  Code object: $MODULE_LOAD_HSACO"
echo "  Plain code object: $MODULE_LOAD_PLAIN_HSACO"
echo "  Extract tool: $EXTRACT_CODE_OBJECTS"
echo "================================================================================"

################################################################################
# Test: binary-only hsaco rewrite path
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Prepare donor-free surrogate cache artifacts from an uninstrumented .hsaco"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

PYTHONDONTWRITEBYTECODE=1 \
    python3 "$PREPARE_HSACO_CACHE" \
    --output-dir "$CACHE_DIR" \
    --surrogate-mode donor-free \
    "$MODULE_LOAD_PLAIN_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=false

if $run_ok && \
   grep -q '"surrogate_mode": "donor-free"' "$OUTPUT_FILE" && \
   ls "$CACHE_DIR"/*.surrogate.hsaco >/dev/null 2>&1 && \
   ls "$CACHE_DIR"/*.surrogate.report.json >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-free surrogate cache artifacts were generated"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-free cache preparation did not complete successfully"
    cat "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: surrogate clone hidden-ABI repack preserves source hidden args and
# writes hidden_omniprobe_ctx at the clone slot used by runtime dispatch rewrite
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_hidden_kernarg_repack"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate surrogate clone hidden-ABI kernarg repack contract"

REPACK_OUT="$OUTPUT_DIR/${TEST_NAME}.out"
SURROGATE_HSACO="$(find "$CACHE_DIR" -name '*.surrogate.hsaco' -print -quit 2>/dev/null || true)"

if [ -n "$SURROGATE_HSACO" ] && \
   LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
   "$HIDDEN_KERNARG_REPACK_TEST" \
      "$MODULE_LOAD_PLAIN_HSACO" \
      "$SURROGATE_HSACO" \
      mlk.kd > "$REPACK_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Hidden-ABI surrogate clone repack matches runtime expectations"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Hidden-ABI surrogate clone repack contract failed"
    cat "$REPACK_OUT" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: donor-free clone descriptor fidelity preserves the source kernel's
# launch-control fields while extending metadata with hidden_omniprobe_ctx
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_clone_descriptor_fidelity"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-free clone descriptor control fields remain aligned with the source kernel"

FIDELITY_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

if [ -n "$SURROGATE_HSACO" ] && \
   PYTHONDONTWRITEBYTECODE=1 python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_PLAIN_HSACO" \
      --output "$OUTPUT_DIR/${TEST_NAME}.source.manifest.json" >/dev/null 2>&1 && \
   PYTHONDONTWRITEBYTECODE=1 python3 "$INSPECT_CODE_OBJECT" "$SURROGATE_HSACO" \
      --output "$OUTPUT_DIR/${TEST_NAME}.surrogate.manifest.json" >/dev/null 2>&1 && \
   python3 - "$OUTPUT_DIR/${TEST_NAME}.source.manifest.json" "$OUTPUT_DIR/${TEST_NAME}.surrogate.manifest.json" > "$FIDELITY_OUT" 2>&1 <<'PY'; then
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
surrogate = json.loads(Path(sys.argv[2]).read_text())

def find_kernel(manifest, name):
    for kernel in manifest["kernels"]["metadata"]["kernels"]:
        if kernel.get("name") == name:
            return kernel
    raise SystemExit(f"kernel {name!r} not found")

def find_descriptor(manifest, name):
    for descriptor in manifest["kernels"]["descriptors"]:
        if descriptor.get("name") == name:
            return descriptor
    raise SystemExit(f"descriptor {name!r} not found")

source_kernel = find_kernel(source, "mlk")
clone_kernel = find_kernel(surrogate, "__amd_crk_mlk")
source_descriptor = find_descriptor(source, "mlk.kd")
clone_descriptor = find_descriptor(surrogate, "__amd_crk_mlk.kd")

if clone_descriptor["compute_pgm_rsrc1"]["raw_value"] != source_descriptor["compute_pgm_rsrc1"]["raw_value"]:
    raise SystemExit(
        "compute_pgm_rsrc1 drifted: "
        f"{clone_descriptor['compute_pgm_rsrc1']['raw_value']} != "
        f"{source_descriptor['compute_pgm_rsrc1']['raw_value']}"
    )
if clone_descriptor["compute_pgm_rsrc2"]["raw_value"] != source_descriptor["compute_pgm_rsrc2"]["raw_value"]:
    raise SystemExit(
        "compute_pgm_rsrc2 drifted: "
        f"{clone_descriptor['compute_pgm_rsrc2']['raw_value']} != "
        f"{source_descriptor['compute_pgm_rsrc2']['raw_value']}"
    )
if clone_descriptor["kernel_code_properties"]["raw_value"] != source_descriptor["kernel_code_properties"]["raw_value"]:
    raise SystemExit(
        "kernel_code_properties drifted: "
        f"{clone_descriptor['kernel_code_properties']['raw_value']} != "
        f"{source_descriptor['kernel_code_properties']['raw_value']}"
    )

source_args = [
    (arg.get("offset"), arg.get("size"), arg.get("value_kind"), arg.get("name"))
    for arg in source_kernel["args"]
]
clone_args = [
    (arg.get("offset"), arg.get("size"), arg.get("value_kind"), arg.get("name"))
    for arg in clone_kernel["args"]
]
expected_clone_args = source_args + [(224, 8, "hidden_omniprobe_ctx", "hidden_omniprobe_ctx")]
if clone_args != expected_clone_args:
    raise SystemExit(
        "clone metadata args did not preserve the source hidden-arg tail as expected"
    )

print("descriptor-control-fields-preserved")
PY
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-free clone descriptor preserved source launch-control fields"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-free clone descriptor fidelity check failed"
    cat "$FIDELITY_OUT" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_donor_slot_unavailable"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-slot mode fails closed when no donor-bearing clone slot exists"

DIRECT_SURROGATE_OUT="$OUTPUT_DIR/${TEST_NAME}.out"
if ! PYTHONDONTWRITEBYTECODE=1 \
   python3 "$PREPARE_HSACO_CACHE" \
      --output-dir "$OUTPUT_DIR/${TEST_NAME}_cache" \
      --surrogate-mode donor-slot \
      "$MODULE_LOAD_PLAIN_HSACO" > "$DIRECT_SURROGATE_OUT" 2>&1 && \
   grep -q "no eligible donor-slot kernel available" "$DIRECT_SURROGATE_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-slot mode rejected the no-donor input clearly"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-slot mode did not fail closed as expected"
    cat "$DIRECT_SURROGATE_OUT" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_donor_slot_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-slot mode can rebind a donor-bearing hsaco and launch mlk with instrumentation"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a Heatmap \
    --hsaco-input "$MODULE_LOAD_DONOR_SLOT_HSACO" \
    --cache-location "$CACHE_DIR" \
    --hsaco-surrogate-mode donor-slot \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_DONOR_SLOT_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=false

if $run_ok && \
   grep -q '"surrogate_mode": "donor-slot"' "$OUTPUT_FILE" && \
   grep -q "Found instrumented alternative for mlk" "$OUTPUT_FILE" && \
   grep -q "memory heatmap report(mlk.kd" "$OUTPUT_FILE" && \
   grep -q "256 accesses" "$OUTPUT_FILE" && \
   grep -q "module_load_test: PASS" "$OUTPUT_FILE" && \
   ls "$CACHE_DIR"/*.surrogate.hsaco >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-slot surrogate rebinding launched successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-slot surrogate runtime validation failed"
    cat "$OUTPUT_FILE" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: binary-only hsaco rewrite path with explicit exact source rebuild
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_exact_rebuild"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Prepare donor-free surrogate cache after an exact source rebuild"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

PYTHONDONTWRITEBYTECODE=1 \
    python3 "$PREPARE_HSACO_CACHE" \
    --output-dir "$CACHE_DIR" \
    --surrogate-mode donor-free \
    --source-rebuild-mode exact \
    "$MODULE_LOAD_PLAIN_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=false

SOURCE_REBUILD_REPORT="$(find "$CACHE_DIR/.source_rebuild" -name '*.exact.report.json' -print -quit 2>/dev/null || true)"
if $run_ok && \
   grep -q '"source_rebuild_mode": "exact"' "$OUTPUT_FILE" && \
   grep -q '"surrogate_mode": "donor-free"' "$OUTPUT_FILE" && \
   ls "$CACHE_DIR"/*.surrogate.hsaco >/dev/null 2>&1 && \
   [ -n "$SOURCE_REBUILD_REPORT" ]; then
    echo -e "  ${GREEN}✓ PASS${NC} - Exact source rebuild fed donor-free surrogate cache prep"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Exact source rebuild cache prep did not complete successfully"
    cat "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: helper-heavy abi-changing source rebuild succeeds through managed cache
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_abi_changing"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Prepare donor-free surrogate cache after helper-heavy abi-changing source rebuild"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

PYTHONDONTWRITEBYTECODE=1 \
    python3 "$PREPARE_HSACO_CACHE" \
    --output-dir "$CACHE_DIR" \
    --surrogate-mode donor-free \
    --source-rebuild-mode abi-changing \
    "$MODULE_LOAD_PLAIN_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=false

SOURCE_REBUILD_REPORT="$(find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.report.json' -print -quit 2>/dev/null || true)"
SOURCE_READINESS_REPORT="$(find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.readiness.json' -print -quit 2>/dev/null || true)"
if $run_ok && \
   grep -q '"source_rebuild_mode": "abi-changing"' "$OUTPUT_FILE" && \
   grep -q '"surrogate_mode": "donor-free"' "$OUTPUT_FILE" && \
   ls "$CACHE_DIR"/*.surrogate.hsaco >/dev/null 2>&1 && \
   [ -n "$SOURCE_REBUILD_REPORT" ] && \
   [ -n "$SOURCE_READINESS_REPORT" ]; then
    echo -e "  ${GREEN}✓ PASS${NC} - Helper-heavy abi-changing rebuild fed donor-free surrogate cache prep"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Helper-heavy abi-changing donor-free cache prep failed"
    cat "$OUTPUT_FILE" || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_only_rewrite_abi_changing_visibility"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Audit the abi-changing source rebuild artifact for descriptor/note/symbol fidelity"

SOURCE_REBUILD_HSACO="$(find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.hsaco' -print -quit 2>/dev/null || true)"
SOURCE_REBUILD_REPORT="$(find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.report.json' -print -quit 2>/dev/null || true)"
SOURCE_REBUILD_MANIFEST="$(find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.hsaco.manifest.json' -print -quit 2>/dev/null || true)"
AUDIT_OUT="$OUTPUT_DIR/${TEST_NAME}.out"
ORIG_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.orig.manifest.json"

if [ -n "$SOURCE_REBUILD_HSACO" ]; then
    PYTHONDONTWRITEBYTECODE=1 \
        python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" \
        "$MODULE_LOAD_PLAIN_HSACO" \
        --output "$ORIG_MANIFEST" >/dev/null 2>&1 \
        || true
fi

if [ -n "$SOURCE_REBUILD_HSACO" ] && \
   [ -n "$SOURCE_REBUILD_REPORT" ] && \
   [ -n "$SOURCE_REBUILD_MANIFEST" ] && \
   [ -f "$ORIG_MANIFEST" ] && \
   python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if report.get("descriptor_policy") == "preserve-original-bytes-override" and report.get("preserve_descriptor_bytes") else 1)' "$SOURCE_REBUILD_REPORT" && \
   PYTHONDONTWRITEBYTECODE=1 \
   python3 "$AUDIT_CODE_OBJECT_STRUCTURE" \
      "$ORIG_MANIFEST" \
      "$SOURCE_REBUILD_MANIFEST" \
      --require-descriptor-bytes-match \
      --require-metadata-note-match \
      --symbol mlk.kd \
      --symbol mlk_d.kd \
      --symbol blockIdx \
      --symbol blockDim \
      --symbol threadIdx \
      --json > "$AUDIT_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Abi-changing rebuild preserved descriptor policy and audited structural fidelity"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Abi-changing rebuild lost descriptor policy or audited structural fidelity"
    cat "$AUDIT_OUT" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: binary-only path prefers a real instrumented carrier when available
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_binary_with_carrier"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe with plain source hsaco plus instrumented carrier hsaco"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a Heatmap \
    --hsaco-input "$MODULE_LOAD_PLAIN_HSACO" \
    --carrier-input "$MODULE_LOAD_HSACO" \
    --cache-location "$CACHE_DIR" \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_PLAIN_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=false

if $run_ok && \
   grep -q "Found instrumented alternative for mlk" "$OUTPUT_FILE" && \
   grep -q "module_load_test: PASS" "$OUTPUT_FILE" && \
   ls "$CACHE_DIR"/*.carrier.hsaco >/dev/null 2>&1 && \
   ! ls "$CACHE_DIR"/*.surrogate.hsaco >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Managed cache preferred real carrier code over surrogate rewrite"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Carrier-backed cache path did not complete successfully"
    grep -E "instrumented alternative|module_load_test:|ERROR:|WARNING:" "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: hidden-ABI carrier emits real dh_comms traffic through Omniprobe's
# runtime packet rewrite
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_hidden_abi_carrier_runtime"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Reclassify a real carrier clone to hidden_omniprobe_ctx and validate runtime dh_comms traffic"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
HIDDEN_CARRIER_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.carrier.manifest.json"
HIDDEN_CARRIER_HSACO="$OUTPUT_DIR/${TEST_NAME}.carrier.hidden.hsaco"
HIDDEN_CARRIER_REPORT="$OUTPUT_DIR/${TEST_NAME}.carrier.hidden.report.json"
rm -rf "$CACHE_DIR"
mkdir -p "$CACHE_DIR"

prep_ok=false
if PYTHONDONTWRITEBYTECODE=1 \
   python3 "$INSPECT_CODE_OBJECT" "$MODULE_LOAD_MANUAL_CARRIER_HSACO" \
      --output "$HIDDEN_CARRIER_MANIFEST" >/dev/null 2>&1 && \
   PYTHONDONTWRITEBYTECODE=1 \
   python3 "$RECLASSIFY_HIDDEN_ARG" \
      "$MODULE_LOAD_MANUAL_CARRIER_HSACO" \
      "$HIDDEN_CARRIER_MANIFEST" \
      --kernel __amd_crk_mlkPv \
      --arg-offset 16 \
      --output "$HIDDEN_CARRIER_HSACO" \
      --report-output "$HIDDEN_CARRIER_REPORT" >/dev/null 2>&1; then
    prep_ok=true
fi

run_ok=false
if $prep_ok; then
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
        LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
        timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a Heatmap \
        --hsaco-input "$MODULE_LOAD_PLAIN_HSACO" \
        --carrier-input "$HIDDEN_CARRIER_HSACO" \
        --cache-location "$CACHE_DIR" \
        -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_PLAIN_HSACO" > "$OUTPUT_FILE" 2>&1 \
        && run_ok=true || run_ok=false
fi

if $prep_ok && $run_ok && \
   grep -q "Found instrumented alternative for mlk" "$OUTPUT_FILE" && \
   grep -q "memory heatmap report(mlk.kd" "$OUTPUT_FILE" && \
   grep -q "256 accesses" "$OUTPUT_FILE" && \
   grep -q "module_load_test: PASS" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Hidden-ABI carrier clone consumed hidden_omniprobe_ctx and emitted dh_comms traffic"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Hidden-ABI carrier runtime validation failed"
    cat "$OUTPUT_FILE" 2>/dev/null || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: .hsaco contains both original and instrumented kernel symbols
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_hsaco_symbols"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify .hsaco contains original and __amd_crk_ instrumented kernel"

# Use nm to check for both symbols (the .hsaco is a raw ELF, not an offload bundle)
if nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -q "T mlk$" && \
   nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -q "T __amd_crk_mlk"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Both original and instrumented kernel symbols present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Expected both mlk and __amd_crk_mlk*"
    nm "$MODULE_LOAD_HSACO" 2>/dev/null | grep -E "mlk|__amd_crk" || true
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: omniprobe finds instrumented alternative without --library-filter
#
# This tests the core kernel discovery unification.  Before the refactor this
# test is expected to FAIL (omniprobe will print "No instrumented alternative
# found").  After rf_unify-kernel-discovery it should PASS.
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_discovery_auto"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe -i (no --library-filter) — expect instrumented alternative found"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a Heatmap \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true  # Don't fail on non-zero exit

if grep -q "Found instrumented alternative for mlk" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Instrumented alternative auto-discovered"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Instrumented alternative NOT auto-discovered"
    echo "  (This is expected before rf_unify-kernel-discovery refactor)"
    grep -E "instrumented alternative|mlk" "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: omniprobe finds instrumented alternative WITH --library-filter
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="module_load_discovery_filter"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run under omniprobe -i with --library-filter pointing to .hsaco"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
FILTER_FILE="$OUTPUT_DIR/${TEST_NAME}_filter.json"

# Write a filter that includes the .hsaco
cat > "$FILTER_FILE" <<EOF
{
  "include": ["$MODULE_LOAD_HSACO"]
}
EOF

ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
    LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
    timeout "$OMNIPROBE_TIMEOUT" "$OMNIPROBE" -i -a Heatmap \
    --library-filter "$FILTER_FILE" \
    -- "$MODULE_LOAD_TEST" "$MODULE_LOAD_HSACO" > "$OUTPUT_FILE" 2>&1 \
    && run_ok=true || run_ok=true

if grep -q "Found instrumented alternative for mlk" "$OUTPUT_FILE"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Instrumented alternative found via --library-filter"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Instrumented alternative NOT found even with --library-filter"
    grep -E "instrumented alternative|mlk" "$OUTPUT_FILE" || true
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test: executable input can be extracted and cached directly
################################################################################

if [ -x "$SIMPLE_HEATMAP_TEST" ] && [ -x "$EXTRACT_CODE_OBJECTS" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="bundled_executable_cache_prep"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Prepare cache directly from an instrumented executable with bundled GPU code"

    OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
    CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"

    BUILD_DIR="$BUILD_DIR" \
        OMNIPROBE_ROOT="$OMNIPROBE_ROOT" \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 "$PREPARE_HSACO_CACHE" \
        --output-dir "$CACHE_DIR" \
        "$SIMPLE_HEATMAP_TEST" > "$OUTPUT_FILE" 2>&1 \
        && run_ok=true || run_ok=false

    if $run_ok && \
       grep -q '"mode": "carrier"' "$OUTPUT_FILE" && \
       grep -q '"rebuild_mode": "exact"' "$OUTPUT_FILE" && \
       ls "$CACHE_DIR"/*.carrier.hsaco >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ PASS${NC} - Bundled executable input was extracted and cached"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Bundled executable input cache preparation failed"
        cat "$OUTPUT_FILE" || true
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

################################################################################
# Test: helper-light bundled input can use gated abi-changing source rebuild
################################################################################

if [ -x "$SIMPLE_HEATMAP_TEST" ] && [ -x "$EXTRACT_CODE_OBJECTS" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="bundled_executable_cache_prep_abi_changing"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Prepare cache from a helper-light executable through the gated abi-changing rebuild path"

    OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"
    CACHE_DIR="$OUTPUT_DIR/${TEST_NAME}_cache"
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"

    BUILD_DIR="$BUILD_DIR" \
        OMNIPROBE_ROOT="$OMNIPROBE_ROOT" \
        PYTHONDONTWRITEBYTECODE=1 \
        python3 "$PREPARE_HSACO_CACHE" \
        --output-dir "$CACHE_DIR" \
        --source-rebuild-mode abi-changing \
        "$SIMPLE_HEATMAP_TEST" > "$OUTPUT_FILE" 2>&1 \
        && run_ok=true || run_ok=false

    if $run_ok && \
       grep -q '"source_rebuild_mode": "abi-changing"' "$OUTPUT_FILE" && \
       grep -q '"mode": "carrier"' "$OUTPUT_FILE" && \
       find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.report.json' -print -quit >/dev/null 2>&1 && \
       find "$CACHE_DIR/.source_rebuild" -name '*.abi-changing.readiness.json' -print -quit >/dev/null 2>&1 && \
       ls "$CACHE_DIR"/*.carrier.hsaco >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ PASS${NC} - Helper-light bundled input passed the gated abi-changing rebuild path"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Helper-light abi-changing cache preparation failed"
        cat "$OUTPUT_FILE" || true
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi

# Export updated counters for parent script
export TESTS_RUN TESTS_PASSED TESTS_FAILED
