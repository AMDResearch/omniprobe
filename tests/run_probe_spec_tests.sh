#!/bin/bash
################################################################################
# Probe spec schema tests
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

VALIDATOR="${REPO_ROOT}/tools/probes/validate_probe_spec.py"
GENERATOR="${REPO_ROOT}/tools/probes/generate_probe_surrogates.py"
VALID_SPEC="${SCRIPT_DIR}/probe_specs/valid_v1.yaml"
INVALID_SPEC="${SCRIPT_DIR}/probe_specs/invalid_contract.yaml"

echo ""
echo "================================================================================"
echo "Probe Spec Tests"
echo "================================================================================"
echo "  Validator: $VALIDATOR"
echo "  Generator: $GENERATOR"
echo "================================================================================"

if [ ! -f "$VALIDATOR" ]; then
    echo -e "${RED}ERROR: validator not found at $VALIDATOR${NC}"
    exit 1
fi

if [ ! -f "$GENERATOR" ]; then
    echo -e "${RED}ERROR: generator not found at $GENERATOR${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_spec_valid_v1"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
VALID_JSON_OUT="$OUTPUT_DIR/${TEST_NAME}.json"

if python3 "$VALIDATOR" "$VALID_SPEC" --json > "$VALID_JSON_OUT"; then
    if python3 - "$VALID_JSON_OUT" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["version"] == 1
assert len(payload["probes"]) == 2
assert payload["probes"][0]["inject"]["contract"] == "kernel_lifecycle_v1"
assert payload["probes"][0]["inject"]["event_usage"] == "dispatch_origin"
assert payload["probes"][1]["payload"]["mode"] == "vector"
assert payload["probes"][0]["capture"]["builtins"] == ["grid_dim", "block_dim"]
helper_abi = payload["probes"][0]["helper_abi"]
assert helper_abi["schema"] == "omniprobe.helper_abi.v1"
assert helper_abi["model"] == "explicit_runtime_v1"
assert helper_abi["compiler_generated_liveins_allowed"] is False
assert helper_abi["compiler_generated_builtins_allowed"] is False
assert helper_abi["requires_wrapper_captured_state"] is True
assert helper_abi["requires_runtime_dispatch_payload"] is True
assert helper_abi["helper_visible_sources"]["builtins"]["requested"] == ["grid_dim", "block_dim"]
assert helper_abi["helper_visible_sources"]["builtins"]["provider"] == "runtime_ctx.dh_builtins"
assert "runtime_ctx.dh_builtins" in helper_abi["required_runtime_views"]
PY
    then
        echo -e "  ${GREEN}✓ PASS${NC} - Valid v1 spec normalized successfully"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Normalized JSON shape did not match expectations"
        echo "  Output saved to: $VALID_JSON_OUT"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Validator rejected valid spec"
    echo "  Output saved to: $VALID_JSON_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_spec_surrogate_generation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
GENERATED_HIP_OUT="$OUTPUT_DIR/${TEST_NAME}.hip"
GENERATED_MANIFEST_OUT="$OUTPUT_DIR/${TEST_NAME}.manifest.json"

if python3 "$GENERATOR" "$VALID_SPEC" \
    --hip-output "$GENERATED_HIP_OUT" \
    --manifest-output "$GENERATED_MANIFEST_OUT"; then
    if python3 - "$GENERATED_MANIFEST_OUT" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
surrogates = payload["surrogates"]
assert len(surrogates) == 3
names = {entry["surrogate"] for entry in surrogates}
assert "__omniprobe_probe_kernel_timing_kernel_entry_surrogate" in names
assert "__omniprobe_probe_kernel_timing_kernel_exit_surrogate" in names
assert "__omniprobe_probe_global_loads_surrogate" in names
contracts = {entry["surrogate"]: entry["contract"] for entry in surrogates}
assert contracts["__omniprobe_probe_global_loads_surrogate"] == "memory_op_v1"
entry = next(item for item in surrogates if item["probe_id"] == "kernel_timing")
assert entry["helper_context"]["builtins"] == ["grid_dim", "block_dim"]
assert entry["helper_abi"]["schema"] == "omniprobe.helper_abi.v1"
assert entry["helper_abi"]["model"] == "explicit_runtime_v1"
assert entry["helper_abi"]["helper_visible_sources"]["builtins"]["requested"] == ["grid_dim", "block_dim"]
assert entry["helper_abi"]["helper_visible_sources"]["builtins"]["provider"] == "runtime_ctx.dh_builtins"
assert entry["event_usage"] == "dispatch_origin"
assert entry["capture_layout"]["struct_fields"] == [{"name": "n"}]
assert entry["capture_layout"]["event_fields"] == []
PY
    then
        if grep -q "memory_op_event event" "$GENERATED_HIP_OUT" && \
           grep -q "kernel_lifecycle_event event" "$GENERATED_HIP_OUT" && \
           ! grep -q "dim3_capture grid_dim" "$GENERATED_HIP_OUT" && \
           ! grep -q "dim3_capture block_dim" "$GENERATED_HIP_OUT"; then
            echo -e "  ${GREEN}✓ PASS${NC} - Surrogate source and manifest generated as expected"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - Generated source did not contain expected event contracts"
            echo "  HIP output: $GENERATED_HIP_OUT"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - Generated surrogate manifest did not match expectations"
        echo "  Manifest saved to: $GENERATED_MANIFEST_OUT"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - Generator failed on valid spec"
    echo "  HIP output: $GENERATED_HIP_OUT"
    echo "  Manifest: $GENERATED_MANIFEST_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_spec_rejects_compiler_builtin_aliases"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
INVALID_ALIAS_SPEC="$OUTPUT_DIR/${TEST_NAME}.yaml"
INVALID_ALIAS_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

cat > "$INVALID_ALIAS_SPEC" <<'YAML'
version: 1

helpers:
  source: ./helpers/example.hip

probes:
  - id: alias_probe
    target:
      kernels: ["demo_kernel"]
    inject:
      when: kernel_entry
      helper: alias_helper
      contract: kernel_lifecycle_v1
    capture:
      builtins: ["gridDim"]
YAML

if python3 "$VALIDATOR" "$INVALID_ALIAS_SPEC" > "$INVALID_ALIAS_OUT" 2>&1; then
    echo -e "  ${RED}✗ FAIL${NC} - Invalid helper builtin alias unexpectedly passed validation"
    echo "  Output saved to: $INVALID_ALIAS_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "helper requests must use Omniprobe runtime-context names" "$INVALID_ALIAS_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Compiler builtin aliases were rejected"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Invalid alias failed for an unexpected reason"
    echo "  Output saved to: $INVALID_ALIAS_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="probe_spec_invalid_contract"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
INVALID_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

if python3 "$VALIDATOR" "$INVALID_SPEC" > "$INVALID_OUT" 2>&1; then
    echo -e "  ${RED}✗ FAIL${NC} - Invalid spec unexpectedly passed validation"
    echo "  Output saved to: $INVALID_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "does not support" "$INVALID_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Invalid contract mismatch was rejected"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Invalid spec failed for an unexpected reason"
    echo "  Output saved to: $INVALID_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
