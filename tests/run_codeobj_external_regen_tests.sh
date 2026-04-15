#!/bin/bash
################################################################################
# External code-object regeneration tests
#
# Fetches a representative third-party single-kernel code object and validates
# donor-free no-op regeneration structurally. This complements the executable
# round-trip tests without requiring a bespoke host harness for the external
# object.
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

AITER_URL="${AITER_URL:-https://raw.githubusercontent.com/ROCm/aiter/main/hsa/gfx942/mla/mla_dec_stage1_bf16_a16w16_subQ16_mqa16.co}"
REGENERATE_TOOL="${REPO_ROOT}/tools/codeobj/regenerate_code_object.py"
INSPECT_TOOL="${REPO_ROOT}/tools/codeobj/inspect_code_object.py"
AUDIT_TOOL="${REPO_ROOT}/tools/codeobj/audit_code_object_structure.py"

LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${YELLOW}SKIP: curl not available for external code-object fetch${NC}"
    exit 0
fi

if [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm LLVM tools not found${NC}"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    exit 0
fi

echo ""
echo "================================================================================"
echo "External Code-Object Regeneration Tests"
echo "================================================================================"
echo "  Input URL: $AITER_URL"
echo "================================================================================"

WORK_DIR="$OUTPUT_DIR/codeobj_external_regen"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

INPUT_CO="$WORK_DIR/aiter_input.co"
INPUT_MANIFEST="$WORK_DIR/aiter_input.manifest.json"
REGEN_CO="$WORK_DIR/aiter_regen.co"
REGEN_REPORT="$WORK_DIR/aiter_regen.report.json"
REGEN_MANIFEST="$WORK_DIR/aiter_regen.manifest.json"
AUDIT_JSON="$WORK_DIR/aiter_regen.audit.json"

curl -L "$AITER_URL" -o "$INPUT_CO" >/dev/null 2>&1

python3 "$INSPECT_TOOL" "$INPUT_CO" --output "$INPUT_MANIFEST" >/dev/null
python3 "$REGENERATE_TOOL" \
    "$INPUT_CO" \
    --output "$REGEN_CO" \
    --manifest "$INPUT_MANIFEST" \
    --report-output "$REGEN_REPORT" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD" >/dev/null
python3 "$INSPECT_TOOL" "$REGEN_CO" --output "$REGEN_MANIFEST" >/dev/null

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_external_regen_aiter_structure"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-free no-op regeneration of the external AITER code object"

if python3 "$AUDIT_TOOL" \
    "$INPUT_MANIFEST" \
    "$REGEN_MANIFEST" \
    --require-descriptor-bytes-match \
    --require-metadata-note-match \
    --symbol _ZN5aiter39mla_dec_stage1_bf16_a16w16_subQ16_mqa16E \
    --symbol _ZN5aiter39mla_dec_stage1_bf16_a16w16_subQ16_mqa16E.kd \
    --json > "$AUDIT_JSON"; then
    echo -e "  ${GREEN}✓ PASS${NC} - External single-kernel object regenerates structurally"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - External regeneration structural audit failed"
    echo "  Audit saved to: $AUDIT_JSON"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary
