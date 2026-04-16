#!/bin/bash
################################################################################
# Binary-only probe planning tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

PREPARE_BUNDLE="${REPO_ROOT}/tools/probes/prepare_probe_bundle.py"
GENERATOR="${REPO_ROOT}/tools/probes/generate_probe_surrogates.py"
PLANNER="${REPO_ROOT}/tools/codeobj/plan_probe_instrumentation.py"
THUNK_GENERATOR="${REPO_ROOT}/tools/codeobj/generate_binary_probe_thunks.py"
FIXTURE_MANIFEST="${SCRIPT_DIR}/probe_specs/fixtures/binary_probe_manifest.json"
LIFECYCLE_SPEC="${SCRIPT_DIR}/probe_specs/kernel_timing_v1.yaml"
MIXED_SPEC="${SCRIPT_DIR}/probe_specs/valid_v1.yaml"

echo ""
echo "================================================================================"
echo "Binary Probe Planning Tests"
echo "================================================================================"
echo "  Bundle tool: $PREPARE_BUNDLE"
echo "  Planner: $PLANNER"
echo "================================================================================"

if [ ! -f "$PREPARE_BUNDLE" ] || [ ! -f "$GENERATOR" ] || [ ! -f "$PLANNER" ] || [ ! -f "$THUNK_GENERATOR" ] || [ ! -f "$FIXTURE_MANIFEST" ]; then
    echo -e "${RED}ERROR: required planning artifacts are missing${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_bundle_skip_compile"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
BUNDLE_JSON="$BUNDLE_DIR/generated_probe_bundle.json"

if python3 "$PREPARE_BUNDLE" "$LIFECYCLE_SPEC" \
    --output-dir "$BUNDLE_DIR" \
    --skip-compile > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$BUNDLE_JSON" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["compile_skipped"] is True
assert payload["helper_bitcode"] is None
assert payload["environment"]["OMNIPROBE_PROBE_MANIFEST"]
assert payload["environment"]["OMNIPROBE_PROBE_BITCODE"] == ""
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Planning-only probe bundle generation succeeded"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Planning-only bundle report shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Planning-only probe bundle generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_lifecycle"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
LIFECYCLE_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$PLANNER" "$FIXTURE_MANIFEST" \
    --probe-bundle "$BUNDLE_JSON" \
    --kernel simple_kernel \
    --output "$LIFECYCLE_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$LIFECYCLE_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["planning_only"] is True
assert payload["supported"] is True
assert payload["planned_site_count"] == 2
assert payload["unsupported_site_count"] == 0
assert payload["selected_kernel_count"] == 1
kernel = payload["kernels"][0]
assert kernel["source_kernel"] == "simple_kernel"
assert kernel["clone_kernel"].startswith("__amd_crk_")
sites = {site["when"]: site for site in kernel["planned_sites"]}
assert set(sites) == {"kernel_entry", "kernel_exit"}
entry_bindings = sites["kernel_entry"]["capture_bindings"]
assert [binding["kernel_arg_name"] for binding in entry_bindings] == ["data", "size"]
assert sites["kernel_entry"]["helper_context"]["builtins"] == [
    "grid_dim", "block_dim", "block_idx", "thread_idx", "dispatch_id"
]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Lifecycle probe planning resolved kernel targets and captures"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Lifecycle plan content was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Lifecycle planner unexpectedly failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_generate_lifecycle_thunks"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
THUNK_SOURCE="$OUTPUT_DIR/${TEST_NAME}.hip"
THUNK_MANIFEST="$OUTPUT_DIR/${TEST_NAME}.manifest.json"

if python3 "$THUNK_GENERATOR" "$LIFECYCLE_PLAN" \
    --probe-bundle "$BUNDLE_JSON" \
    --output "$THUNK_SOURCE" \
    --manifest-output "$THUNK_MANIFEST" > "$OUTPUT_DIR/${TEST_NAME}.out"; then
    if python3 - "$THUNK_MANIFEST" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(payload["thunks"]) == 2
names = {entry["thunk"] for entry in payload["thunks"]}
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_entry_thunk" in names
assert "__omniprobe_binary_kernel_timing_simple_kernel_kernel_exit_thunk" in names
PY
    then
        if grep -q '__omniprobe_binary_kernel_timing_simple_kernel_kernel_entry_thunk' "$THUNK_SOURCE" && \
           grep -q 'using namespace omniprobe_user;' "$THUNK_SOURCE" && \
           grep -q 'load_kernarg<uint64_t>(kernarg_base, 0)' "$THUNK_SOURCE" && \
           grep -q 'load_kernarg<uint64_t>(kernarg_base, 8)' "$THUNK_SOURCE" && \
           grep -q '__omniprobe_probe_kernel_timing_kernel_entry_surrogate(&runtime, &captures, timestamp);' "$THUNK_SOURCE"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Lifecycle thunk source reconstructs captures and forwards to the shared surrogate"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Generated thunk source did not contain expected capture loads and surrogate calls"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Thunk manifest shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Lifecycle thunk generation failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="binary_probe_plan_fail_closed_memory_op"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
MIXED_BUNDLE_DIR="$OUTPUT_DIR/${TEST_NAME}_bundle"
MIXED_MANIFEST="$MIXED_BUNDLE_DIR/generated_probe_manifest.json"
MIXED_PLAN="$OUTPUT_DIR/${TEST_NAME}.json"
rm -rf "$MIXED_BUNDLE_DIR"
mkdir -p "$MIXED_BUNDLE_DIR"

if python3 "$GENERATOR" "$MIXED_SPEC" \
    --hip-output "$MIXED_BUNDLE_DIR/generated_probe_surrogates.hip" \
    --manifest-output "$MIXED_MANIFEST" > "$OUTPUT_DIR/${TEST_NAME}.bundle.out" && \
   ! python3 "$PLANNER" "$FIXTURE_MANIFEST" \
      --probe-manifest "$MIXED_MANIFEST" \
      --kernel vector_add \
      --output "$MIXED_PLAN" > "$OUTPUT_DIR/${TEST_NAME}.out" 2>&1; then
    if python3 - "$MIXED_PLAN" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["supported"] is False
assert payload["planned_site_count"] == 2
assert payload["unsupported_site_count"] == 1
kernel = payload["kernels"][0]
assert len(kernel["planned_sites"]) == 2
assert len(kernel["unsupported_sites"]) == 1
unsupported = kernel["unsupported_sites"][0]
assert unsupported["contract"] == "memory_op_v1"
assert "not yet supported" in unsupported["reason"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Unsupported memory-op planning fails closed while preserving lifecycle plans"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Fail-closed mixed-contract plan shape was incorrect"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Mixed-contract planner did not fail closed as expected"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
