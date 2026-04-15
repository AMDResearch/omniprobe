#!/bin/bash
################################################################################
# Code-object round-trip tests for Omniprobe's binary-only tooling
#
# Exercises the current validated editable-IR path on a simple extracted HIP
# code object:
#   1. extract a code object from simple_heatmap_test
#   2. inspect + disassemble to IR
#   3. rebuild a no-op equivalent code object
#   4. validate the rebuilt object with hipModuleLoad
#   5. mutate one instruction, rebuild again, and confirm behavior diverges
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

SIMPLE_HEATMAP_TEST="${BUILD_DIR}/tests/test_kernels/simple_heatmap_test"
EXTRACT_CODE_OBJECTS="${BUILD_DIR}/tools/extract_code_objects"
HIP_LAUNCH_TEST="${BUILD_DIR}/tools/test_hip_module_launch"
MODULE_LOAD_TEST="${BUILD_DIR}/tests/test_kernels/module_load_test"
MODULE_LOAD_PLAIN_HSACO="${BUILD_DIR}/tests/test_kernels/module_load_kernel_plain.hsaco"
LLVM_MC="${LLVM_MC:-/opt/rocm/llvm/bin/llvm-mc}"
LD_LLD="${LD_LLD:-/opt/rocm/llvm/bin/ld.lld}"
KERNEL_NAME="_Z13simple_kernelPim"
MUTATION_ADDRESS="0x114c"
MUTATION_OPERANDS="v[1:2], v1, off"

if [ ! -x "$SIMPLE_HEATMAP_TEST" ] || [ ! -x "$EXTRACT_CODE_OBJECTS" ] || [ ! -x "$HIP_LAUNCH_TEST" ]; then
    echo -e "${YELLOW}SKIP: Code-object round-trip artifacts not built${NC}"
    echo "  Expected: $SIMPLE_HEATMAP_TEST"
    echo "  Expected: $EXTRACT_CODE_OBJECTS"
    echo "  Expected: $HIP_LAUNCH_TEST"
    echo "  Build with: cmake --build build --target simple_heatmap_test extract_code_objects test_hip_module_launch"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

if [ ! -x "$LLVM_MC" ] || [ ! -x "$LD_LLD" ]; then
    echo -e "${YELLOW}SKIP: Required ROCm LLVM tools not found${NC}"
    echo "  Expected: $LLVM_MC"
    echo "  Expected: $LD_LLD"
    export TESTS_RUN TESTS_PASSED TESTS_FAILED
    return 0 2>/dev/null || exit 0
fi

echo ""
echo "================================================================================"
echo "Code-Object Round-Trip Tests"
echo "================================================================================"
echo "  Host binary: $SIMPLE_HEATMAP_TEST"
echo "  Extract tool: $EXTRACT_CODE_OBJECTS"
echo "  Launch test: $HIP_LAUNCH_TEST"
echo "================================================================================"

WORK_DIR="$OUTPUT_DIR/codeobj_roundtrip"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

EXTRACT_LOG="$WORK_DIR/extract.log"
"$EXTRACT_CODE_OBJECTS" "$SIMPLE_HEATMAP_TEST" > "$EXTRACT_LOG" 2>&1
EXTRACTED_PATH="$(tail -n 1 "$EXTRACT_LOG")"
if [ ! -f "$EXTRACTED_PATH" ]; then
    echo -e "${RED}ERROR: failed to locate extracted code object${NC}"
    cat "$EXTRACT_LOG"
    return 1 2>/dev/null || exit 1
fi
cp "$EXTRACTED_PATH" "$WORK_DIR/simple.orig.co"

MANIFEST="$WORK_DIR/simple.manifest.json"
IR="$WORK_DIR/simple.ir.json"
REBUILT_ASM="$WORK_DIR/simple.rebuilt.s"
REBUILT_OBJ="$WORK_DIR/simple.rebuilt.o"
REBUILT_CO="$WORK_DIR/simple.rebuilt.co"
REBUILT_REPORT="$WORK_DIR/simple.rebuilt.report.json"
REGEN_CO="$WORK_DIR/simple.regen.co"
REGEN_REPORT="$WORK_DIR/simple.regen.report.json"
REGEN_CLONE_CO="$WORK_DIR/simple.regen.clone.co"
REGEN_CLONE_REPORT="$WORK_DIR/simple.regen.clone.report.json"
REGEN_CLONE_MANIFEST="$WORK_DIR/simple.regen.clone.manifest.json"
REGEN_HIDDEN_CLONE_CO="$WORK_DIR/simple.regen.hidden.clone.co"
REGEN_HIDDEN_CLONE_REPORT="$WORK_DIR/simple.regen.hidden.clone.report.json"
REGEN_HIDDEN_CLONE_MANIFEST="$WORK_DIR/simple.regen.hidden.clone.manifest.json"
MUTATED_IR="$WORK_DIR/simple.storev1.ir.json"
MUTATED_DESCRIPTOR_REPORT="$WORK_DIR/simple.storev1.descriptor_safety.json"
MUTATED_ASM="$WORK_DIR/simple.storev1.s"
MUTATED_OBJ="$WORK_DIR/simple.storev1.o"
MUTATED_CO="$WORK_DIR/simple.storev1.co"
MUTATED_REBUILD_REPORT="$WORK_DIR/simple.storev1.rebuild.report.json"
HIDDEN_ABI_CO="$WORK_DIR/simple.hidden_abi.co"
HIDDEN_ABI_REPORT="$WORK_DIR/simple.hidden_abi.report.json"
HIDDEN_ABI_MANIFEST="$WORK_DIR/simple.hidden_abi.manifest.json"

python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" "$WORK_DIR/simple.orig.co" --output "$MANIFEST"
python3 "$REPO_ROOT/tools/codeobj/disasm_to_ir.py" "$WORK_DIR/simple.orig.co" --manifest "$MANIFEST" --output "$IR"

python3 "$REPO_ROOT/tools/codeobj/rebuild_code_object.py" \
    "$IR" "$MANIFEST" \
    --mode exact \
    --output "$REBUILT_CO" \
    --asm-output "$REBUILT_ASM" \
    --object-output "$REBUILT_OBJ" \
    --report-output "$REBUILT_REPORT" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD"

python3 "$REPO_ROOT/tools/codeobj/regenerate_code_object.py" \
    "$WORK_DIR/simple.orig.co" \
    --output "$REGEN_CO" \
    --manifest "$MANIFEST" \
    --report-output "$REGEN_REPORT" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD"

python3 "$REPO_ROOT/tools/codeobj/regenerate_code_object.py" \
    "$WORK_DIR/simple.orig.co" \
    --output "$REGEN_CLONE_CO" \
    --manifest "$MANIFEST" \
    --report-output "$REGEN_CLONE_REPORT" \
    --add-noop-clone \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD"
python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" \
    "$REGEN_CLONE_CO" \
    --output "$REGEN_CLONE_MANIFEST"
python3 "$REPO_ROOT/tools/codeobj/regenerate_code_object.py" \
    "$WORK_DIR/simple.orig.co" \
    --output "$REGEN_HIDDEN_CLONE_CO" \
    --manifest "$MANIFEST" \
    --report-output "$REGEN_HIDDEN_CLONE_REPORT" \
    --add-hidden-abi-clone \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD"
python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" \
    "$REGEN_HIDDEN_CLONE_CO" \
    --output "$REGEN_HIDDEN_CLONE_MANIFEST"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_roundtrip_noop"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate original extracted object"
ORIG_OUT="$OUTPUT_DIR/${TEST_NAME}.orig.out"
REBUILT_OUT="$OUTPUT_DIR/${TEST_NAME}.rebuilt.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$WORK_DIR/simple.orig.co" "$KERNEL_NAME" index > "$ORIG_OUT" 2>&1 && \
   ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$REBUILT_CO" "$KERNEL_NAME" index > "$REBUILT_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Original and rebuilt code objects both execute"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No-op round-trip validation failed"
    echo "  Original output: $ORIG_OUT"
    echo "  Rebuilt output: $REBUILT_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_regenerate_noop"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-free regeneration scaffold on the extracted code object"
REGEN_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$REGEN_CO" "$KERNEL_NAME" index > "$REGEN_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Regenerated code object executes successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-free regeneration scaffold failed"
    echo "  Output saved to: $REGEN_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_regenerate_noop_clone"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-free same-ABI clone insertion on the extracted code object"
REGEN_CLONE_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

CLONE_KERNEL_NAME="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["clone_result"]["clone_kernel"])' "$REGEN_CLONE_REPORT")"

if ! python3 -c 'import json,sys; manifest_path,clone_name=sys.argv[1:3]; m=json.load(open(manifest_path, encoding="utf-8")); kernels=m["kernels"]["metadata"]["kernels"]; names=[k.get("name") for k in kernels]; sys.exit(0 if "_Z13simple_kernelPim" in names and clone_name in names else 1)' \
    "$REGEN_CLONE_MANIFEST" "$CLONE_KERNEL_NAME"; then
    echo -e "  ${RED}✗ FAIL${NC} - Inserted clone metadata was not reflected in the rebuilt manifest"
    echo "  Manifest saved to: $REGEN_CLONE_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$REGEN_CLONE_CO" "$CLONE_KERNEL_NAME" index > "$REGEN_CLONE_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-free no-op clone launches successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-free no-op clone failed to launch"
    echo "  Output saved to: $REGEN_CLONE_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_regenerate_hidden_abi_clone"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate donor-free hidden-ABI clone insertion on the extracted code object"
REGEN_HIDDEN_CLONE_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

HIDDEN_CLONE_KERNEL_NAME="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["clone_result"]["clone_kernel"])' "$REGEN_HIDDEN_CLONE_REPORT")"
HIDDEN_CLONE_KERNARG_SIZE="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["clone_result"]["instrumented_kernarg_length"])' "$REGEN_HIDDEN_CLONE_REPORT")"
HIDDEN_CLONE_CTX_OFFSET="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["clone_result"]["hidden_omniprobe_ctx"]["offset"])' "$REGEN_HIDDEN_CLONE_REPORT")"

if ! python3 -c 'import json,sys; manifest_path,clone_name=sys.argv[1:3]; m=json.load(open(manifest_path, encoding="utf-8")); kernels=m["kernels"]["metadata"]["kernels"]; target=next((k for k in kernels if k.get("name")==clone_name or k.get("symbol")==clone_name), None); args=target.get("args", []) if target else []; has_hidden=any(arg.get("name")=="hidden_omniprobe_ctx" for arg in args); grown=target is not None and int(target.get("kernarg_segment_size", 0)) > 16; sys.exit(0 if has_hidden and grown else 1)' \
    "$REGEN_HIDDEN_CLONE_MANIFEST" "$HIDDEN_CLONE_KERNEL_NAME"; then
    echo -e "  ${RED}✗ FAIL${NC} - Hidden-ABI clone metadata was not reflected in the rebuilt manifest"
    echo "  Manifest saved to: $REGEN_HIDDEN_CLONE_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$REGEN_HIDDEN_CLONE_CO" "$HIDDEN_CLONE_KERNEL_NAME" index \
    --raw-kernarg-size "$HIDDEN_CLONE_KERNARG_SIZE" \
    --hidden-ctx-offset "$HIDDEN_CLONE_CTX_OFFSET" > "$REGEN_HIDDEN_CLONE_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Donor-free hidden-ABI clone launches successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Donor-free hidden-ABI clone failed to launch"
    echo "  Output saved to: $REGEN_HIDDEN_CLONE_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

python3 "$REPO_ROOT/tools/codeobj/mutate_ir.py" \
    "$IR" \
    --output "$MUTATED_IR" \
    --address "$MUTATION_ADDRESS" \
    --operand-text "$MUTATION_OPERANDS"
python3 "$REPO_ROOT/tools/codeobj/analyze_descriptor_safety.py" \
    "$IR" "$MUTATED_IR" "$MANIFEST" \
    --function "$KERNEL_NAME" \
    --json > "$MUTATED_DESCRIPTOR_REPORT"
python3 "$REPO_ROOT/tools/codeobj/rebuild_code_object.py" \
    "$MUTATED_IR" "$MANIFEST" \
    --mode abi-preserving \
    --original-ir "$IR" \
    --output "$MUTATED_CO" \
    --asm-output "$MUTATED_ASM" \
    --object-output "$MUTATED_OBJ" \
    --report-output "$MUTATED_REBUILD_REPORT" \
    --function "$KERNEL_NAME" \
    --llvm-mc "$LLVM_MC" \
    --ld-lld "$LD_LLD"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_roundtrip_mutation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate the mutated code object changes runtime behavior"
MUTATED_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

if ! python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if report["likely_safe_to_preserve_descriptor_bytes"] else 1)' \
    "$MUTATED_DESCRIPTOR_REPORT"; then
    echo -e "  ${RED}✗ FAIL${NC} - Descriptor-safety analysis flagged the simple mutation"
    echo "  Report saved to: $MUTATED_DESCRIPTOR_REPORT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$MUTATED_CO" "$KERNEL_NAME" index > "$MUTATED_OUT" 2>&1; then
    echo -e "  ${RED}✗ FAIL${NC} - Mutated code object still matched original expectation"
    echo "  Output saved to: $MUTATED_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif grep -q "mismatch\\[" "$MUTATED_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Mutated rebuild diverged from original behavior as expected"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Mutated rebuild failed for an unexpected reason"
    echo "  Output saved to: $MUTATED_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

python3 "$REPO_ROOT/tools/codeobj/mutate_hidden_abi_kernel.py" \
    "$WORK_DIR/simple.orig.co" "$MANIFEST" \
    --kernel "$KERNEL_NAME" \
    --output "$HIDDEN_ABI_CO" \
    --report-output "$HIDDEN_ABI_REPORT"
python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" \
    "$HIDDEN_ABI_CO" \
    --output "$HIDDEN_ABI_MANIFEST"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codeobj_roundtrip_hidden_abi_mutation"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Validate true ABI-changing hidden-ABI mutation on the simple extracted kernel"
HIDDEN_ABI_OUT="$OUTPUT_DIR/${TEST_NAME}.out"

HIDDEN_KERNARG_SIZE="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["instrumented_kernarg_length"])' "$HIDDEN_ABI_REPORT")"
HIDDEN_CTX_OFFSET="$(python3 -c 'import json,sys; report=json.load(open(sys.argv[1], encoding="utf-8")); print(report["hidden_omniprobe_ctx"]["offset"])' "$HIDDEN_ABI_REPORT")"

if ! python3 -c 'import json,sys; manifest_path,kernel_name=sys.argv[1:3]; m=json.load(open(manifest_path, encoding="utf-8")); kernels=m["kernels"]["metadata"]["kernels"]; target=next((k for k in kernels if k.get("name")==kernel_name or k.get("symbol")==kernel_name), None); args=target.get("args", []) if target else []; has_hidden=any(arg.get("name")=="hidden_omniprobe_ctx" or arg.get("value_kind")=="hidden_omniprobe_ctx" for arg in args); grown=target is not None and int(target.get("kernarg_segment_size", 0)) > 16; sys.exit(0 if has_hidden and grown else 1)' \
    "$HIDDEN_ABI_MANIFEST" "$KERNEL_NAME"; then
    echo -e "  ${RED}✗ FAIL${NC} - Hidden-ABI metadata mutation was not reflected in the manifest"
    echo "  Manifest saved to: $HIDDEN_ABI_MANIFEST"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$HIP_LAUNCH_TEST" \
    "$HIDDEN_ABI_CO" "$KERNEL_NAME" index \
    --raw-kernarg-size "$HIDDEN_KERNARG_SIZE" \
    --hidden-ctx-offset "$HIDDEN_CTX_OFFSET" > "$HIDDEN_ABI_OUT" 2>&1; then
    echo -e "  ${GREEN}✓ PASS${NC} - Hidden-ABI ABI-changing mutation launched successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Hidden-ABI ABI-changing mutation failed to launch"
    echo "  Output saved to: $HIDDEN_ABI_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

if [ -x "$MODULE_LOAD_TEST" ] && [ -f "$MODULE_LOAD_PLAIN_HSACO" ]; then
    HELPER_DIR="$WORK_DIR/module_load_plain"
    mkdir -p "$HELPER_DIR"

    HELPER_MANIFEST="$HELPER_DIR/module_load_plain.manifest.json"
    HELPER_IR="$HELPER_DIR/module_load_plain.ir.json"
    HELPER_ASM="$HELPER_DIR/module_load_plain.rebuilt.s"
    HELPER_OBJ="$HELPER_DIR/module_load_plain.rebuilt.o"
    HELPER_CO="$HELPER_DIR/module_load_plain.rebuilt.co"
    HELPER_REPORT="$HELPER_DIR/module_load_plain.rebuild.report.json"
    HELPER_OUT="$OUTPUT_DIR/codeobj_roundtrip_module_load_plain.out"

    python3 "$REPO_ROOT/tools/codeobj/inspect_code_object.py" \
        "$MODULE_LOAD_PLAIN_HSACO" \
        --output "$HELPER_MANIFEST"
    python3 "$REPO_ROOT/tools/codeobj/disasm_to_ir.py" \
        "$MODULE_LOAD_PLAIN_HSACO" \
        --manifest "$HELPER_MANIFEST" \
        --output "$HELPER_IR"

    python3 "$REPO_ROOT/tools/codeobj/rebuild_code_object.py" \
        "$HELPER_IR" "$HELPER_MANIFEST" \
        --mode exact \
        --output "$HELPER_CO" \
        --asm-output "$HELPER_ASM" \
        --object-output "$HELPER_OBJ" \
        --report-output "$HELPER_REPORT" \
        --llvm-mc "$LLVM_MC" \
        --ld-lld "$LD_LLD"

    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="codeobj_roundtrip_module_load_plain"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Validate helper-heavy exact rebuild of module_load_kernel_plain.hsaco"

    if LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" \
       ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       "$MODULE_LOAD_TEST" "$HELPER_CO" > "$HELPER_OUT" 2>&1 && \
       grep -q "module_load_test: PASS" "$HELPER_OUT"; then
        echo -e "  ${GREEN}✓ PASS${NC} - Helper-heavy exact rebuild executes successfully"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - Helper-heavy exact rebuild failed"
        echo "  Output saved to: $HELPER_OUT"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
fi
