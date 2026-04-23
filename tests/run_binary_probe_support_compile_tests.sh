#!/bin/bash
################################################################################
# Binary probe support compile command tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
PLANNER="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
THUNK_GENERATOR="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
TRAMPOLINE_GENERATOR="${REPO_ROOT}/tools/codeobj/generate_entry_trampolines.py"
SUPPORT_COMPILER="${REPO_ROOT}/tools/codeobj/compile_binary_probe_support.py"
PLAN_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/binary_probe_manifest.json"
LIFECYCLE_SPEC="${SCRIPT_DIR}/probe_specs/kernel_timing_v1.yaml"

echo ""
echo "================================================================================"
echo "Binary Probe Support Compile Tests"
echo "================================================================================"
echo "  Compiler: $SUPPORT_COMPILER"
echo "================================================================================"

if [ ! -f "$PREPARE_BUNDLE" ] || [ ! -f "$PLANNER" ] || [ ! -f "$THUNK_GENERATOR" ] || [ ! -f "$TRAMPOLINE_GENERATOR" ] || [ ! -f "$SUPPORT_COMPILER" ]; then
    echo -e "${RED}ERROR: required support compile tooling is missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
PREFIX="binary_probe_support_compile"
BUNDLE_DIR="$OUTPUT_DIR/${PREFIX}_bundle"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"
PLAN_JSON="$OUTPUT_DIR/${PREFIX}.plan.json"
THUNK_MANIFEST="$OUTPUT_DIR/${PREFIX}.thunks.json"
THUNK_SOURCE="$OUTPUT_DIR/${PREFIX}.thunks.hip"
TRAMPOLINE_MANIFEST="$OUTPUT_DIR/${PREFIX}.entry_trampoline.json"
TRAMPOLINE_SOURCE="$OUTPUT_DIR/${PREFIX}.entry_trampoline.hip"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
python3 "$PREPARE_BUNDLE" "$LIFECYCLE_SPEC" --output-dir "$BUNDLE_DIR" --skip-compile > "$OUTPUT_DIR/${PREFIX}.bundle.out"
python3 "$PLANNER" "$PLAN_MANIFEST" --probe-bundle "$BUNDLE_JSON" --kernel simple_kernel --output "$PLAN_JSON" > "$OUTPUT_DIR/${PREFIX}.plan.out"
python3 "$THUNK_GENERATOR" "$PLAN_JSON" --probe-bundle "$BUNDLE_JSON" --output "$THUNK_SOURCE" --manifest-output "$THUNK_MANIFEST" > "$OUTPUT_DIR/${PREFIX}.thunk.out"
python3 "$TRAMPOLINE_GENERATOR" "$PLAN_JSON" --probe-bundle "$BUNDLE_JSON" --output "$TRAMPOLINE_SOURCE" --manifest-output "$TRAMPOLINE_MANIFEST" --body-template none > "$OUTPUT_DIR/${PREFIX}.trampoline.out"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_support_compile_dry_run"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
DRYRUN_JSON="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$SUPPORT_COMPILER" \
    --thunk-manifest "$THUNK_MANIFEST" \
    --output "$OUTPUT_DIR/${TEST_NAME}.o" \
    --arch gfx1030 \
    --dry-run > "$DRYRUN_JSON"; then
    if python3 - "$DRYRUN_JSON" "$THUNK_SOURCE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.load(open(sys.argv[1], encoding="utf-8"))
thunk_source = str(Path(sys.argv[2]).resolve())
assert payload["manifest_kind"] == "thunk"
assert payload["arch"] == "gfx1030"
assert payload["output_format"] == "obj"
assert payload["support_source"] == thunk_source
compile_command = payload["compile_command"]
llc_command = payload["llc_command"]
assert "--offload-device-only" in compile_command
assert "-c" in compile_command
assert any(arg == thunk_source for arg in compile_command)
assert any(arg.startswith("--offload-arch=gfx1030") for arg in compile_command)
assert any("external/dh_comms/include" in arg for arg in compile_command)
assert any("inc" in arg for arg in compile_command)
assert "-march=amdgcn" in llc_command
assert any(arg == "-mcpu=gfx1030" for arg in llc_command)
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Dry-run support compile emits the expected ROCm object-build command shape"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Dry-run support compile JSON was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Dry-run support compile failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_entry_trampoline_compile_dry_run"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
TRAMPOLINE_DRYRUN_JSON="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$SUPPORT_COMPILER" \
    --entry-trampoline-manifest "$TRAMPOLINE_MANIFEST" \
    --output "$OUTPUT_DIR/${TEST_NAME}.hsaco" \
    --arch gfx1030 \
    --output-format hsaco \
    --dry-run > "$TRAMPOLINE_DRYRUN_JSON"; then
    if python3 - "$TRAMPOLINE_DRYRUN_JSON" "$TRAMPOLINE_SOURCE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.load(open(sys.argv[1], encoding="utf-8"))
trampoline_source = str(Path(sys.argv[2]).resolve())
assert payload["manifest_kind"] == "entry-trampoline"
assert payload["arch"] == "gfx1030"
assert payload["output_format"] == "hsaco"
assert payload["support_source"] == trampoline_source
compile_command = payload["compile_command"]
assert payload["llc_command"] is None
assert "--offload-device-only" in compile_command
assert "--no-gpu-bundle-output" in compile_command
assert "-c" not in compile_command
assert any(arg == trampoline_source for arg in compile_command)
assert any(arg.startswith("--offload-arch=gfx1030") for arg in compile_command)
assert any("external/dh_comms/include" in arg for arg in compile_command)
assert any("inc" in arg for arg in compile_command)
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Dry-run entry-trampoline compile emits the expected standalone-HSACO command shape"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Dry-run entry-trampoline compile JSON was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Dry-run entry-trampoline compile failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_support_compile_requires_helper_abi"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BROKEN_THUNK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.thunks.json"

if python3 - "$THUNK_MANIFEST" "$BROKEN_THUNK_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for thunk in payload.get("thunks", []):
    if isinstance(thunk, dict):
        thunk.pop("helper_abi", None)
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
open(sys.argv[2], "a", encoding="utf-8").write("\n")
PY
then
    if python3 "$SUPPORT_COMPILER" \
        --thunk-manifest "$BROKEN_THUNK_MANIFEST" \
        --output "$OUTPUT_DIR/${TEST_NAME}.o" \
        --arch gfx1030 \
        --dry-run > "$OUTPUT_DIR/${TEST_NAME}.out" 2>&1; then
        echo -e "  ${RED}✗ FAIL${NC} - Support compiler accepted a thunk manifest without helper_abi"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    elif grep -q "missing helper_abi" "$OUTPUT_DIR/${TEST_NAME}.out"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Support compiler rejected thunk manifests without helper_abi"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Support compiler failed for an unexpected reason"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Could not generate broken thunk manifest fixture"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
