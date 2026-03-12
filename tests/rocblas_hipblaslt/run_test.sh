#!/bin/bash
################################################################################
# rocBLAS + hipBLASLt combined instrumentation test for omniprobe
#
# Verifies that omniprobe can instrument rocBLAS kernels from a maximal build
# (Tensile hip_full + hipBLASLt matrix transform) end-to-end.
#
# Prerequisites:
#   - INSTRUMENTED_ROCBLAS_LIB_DIR: Path to rocBLAS built with maximal
#     instrumentation (Tensile hip_full + CMAKE_CXX_FLAGS -fpass-plugin).
#   - INSTRUMENTED_HIPBLASLT_LIB_DIR: Path to hipBLASLt built with instrumented
#     matrix transform kernels (custom installation with instrumented device
#     code objects and symlinked system host library).
#
# This test reuses the test binaries from tests/rocblas_filter/ (scal, gemm).
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"
TEST_SCAL="${REPO_ROOT}/tests/rocblas_filter/test_rocblas_scal"
TEST_GEMM="${REPO_ROOT}/tests/rocblas_filter/test_rocblas_gemm"
OUTPUT_DIR="${REPO_ROOT}/tests/test_output"
ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[38;5;208m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

mkdir -p "$OUTPUT_DIR"

################################################################################
# Preflight checks
################################################################################

if [ -z "$INSTRUMENTED_ROCBLAS_LIB_DIR" ]; then
    echo -e "${YELLOW}SKIP: INSTRUMENTED_ROCBLAS_LIB_DIR not set.${NC}"
    echo "Set it to the lib directory of a rocBLAS built with Tensile hip_full + instrumentation."
    exit 0
fi

if [ ! -f "$INSTRUMENTED_ROCBLAS_LIB_DIR/librocblas.so" ]; then
    echo -e "${RED}ERROR: librocblas.so not found in $INSTRUMENTED_ROCBLAS_LIB_DIR${NC}"
    exit 1
fi

if [ -z "$INSTRUMENTED_HIPBLASLT_LIB_DIR" ]; then
    echo -e "${YELLOW}SKIP: INSTRUMENTED_HIPBLASLT_LIB_DIR not set.${NC}"
    echo "Set it to the lib directory of hipBLASLt with instrumented matrix transform."
    exit 0
fi

if [ ! -f "$INSTRUMENTED_HIPBLASLT_LIB_DIR/libhipblaslt.so" ]; then
    echo -e "${RED}ERROR: libhipblaslt.so not found in $INSTRUMENTED_HIPBLASLT_LIB_DIR${NC}"
    exit 1
fi

if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

if [ ! -x "$TEST_SCAL" ] || [ ! -x "$TEST_GEMM" ]; then
    echo -e "${RED}ERROR: test binaries not found (test_rocblas_scal / test_rocblas_gemm)${NC}"
    echo "Build them first in tests/rocblas_filter/"
    exit 1
fi

# Set combined LD_LIBRARY_PATH: rocBLAS first, then hipBLASLt, then system
COMBINED_LIB_PATH="$INSTRUMENTED_ROCBLAS_LIB_DIR:$INSTRUMENTED_HIPBLASLT_LIB_DIR:$LD_LIBRARY_PATH"

# Find instrumented Tensile .hsaco files for library-filter
# Prefer xnack- variant (matching typical gfx90a configuration)
TENSILE_LIB_DIR="$INSTRUMENTED_ROCBLAS_LIB_DIR/rocblas/library"
TENSILE_HSACO=""
for hsaco in $(find "$TENSILE_LIB_DIR" -name "Kernels.so-*.hsaco" 2>/dev/null | sort); do
    if readelf -sW "$hsaco" 2>/dev/null | grep -q "__amd_crk_Cijk"; then
        TENSILE_HSACO="$hsaco"
        # Prefer xnack- over xnack+ (keep looking if we found xnack+)
        if echo "$hsaco" | grep -q "xnack-"; then
            break
        fi
    fi
done

# Find instrumented hipBLASLt transform .hsaco (unbundled raw ELF)
HIPBLASLT_HSACO=""
HIPBLASLT_LIBRARY_DIR="$INSTRUMENTED_HIPBLASLT_LIB_DIR/hipblaslt/library"
for hsaco in $(find "$HIPBLASLT_LIBRARY_DIR" -name "hipblasltTransform-*.hsaco" 2>/dev/null); do
    if nm "$hsaco" 2>/dev/null | grep -q "__amd_crk_Transform_"; then
        HIPBLASLT_HSACO="$hsaco"
        break
    fi
done

echo "================================================================================"
echo "rocBLAS + hipBLASLt Combined Instrumentation Tests"
echo "================================================================================"
echo "Omniprobe:          $OMNIPROBE"
echo "rocBLAS lib:        $INSTRUMENTED_ROCBLAS_LIB_DIR"
echo "hipBLASLt lib:      $INSTRUMENTED_HIPBLASLT_LIB_DIR"
echo "Tensile .hsaco:     ${TENSILE_HSACO:-not found}"
echo "hipBLASLt .hsaco:   ${HIPBLASLT_HSACO:-not found}"
echo "Test binary (scal): $TEST_SCAL"
echo "Test binary (gemm): $TEST_GEMM"
echo "Output dir:         $OUTPUT_DIR"
echo "GPU:                ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

################################################################################
# Test 1: Scal with maximal rocBLAS (non-Tensile kernel instrumentation)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="maximal_scal_instrumented"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run rocblas_sscal with maximal instrumented rocBLAS build"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

SECONDS=0
if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   LD_LIBRARY_PATH="$COMBINED_LIB_PATH" \
   "$OMNIPROBE" -i -a MemoryAnalysis \
   -- "$TEST_SCAL" > "$OUTPUT_FILE" 2>&1; then
    ELAPSED_SECONDS=$SECONDS

    if grep -q "rocblas_sscal: PASS" "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}PASS${NC} - rocblas_sscal computation correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} - rocblas_sscal computation failed"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}FAIL${NC} - omniprobe execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 2: Scal instrumented alternative found (non-Tensile kernel)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="maximal_scal_alternative"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumented alternative found for sscal kernel"

if grep -q "Found instrumented alternative for.*rocblas_sscal" "$OUTPUT_DIR/maximal_scal_instrumented.out"; then
    echo -e "  ${GREEN}PASS${NC} - Found instrumented alternative for sscal"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC} - No instrumented alternative found for sscal"
    echo "  Output saved to: $OUTPUT_DIR/maximal_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 3: Gemm with instrumented Tensile kernels (hip_full)
################################################################################

if [ -n "$TENSILE_HSACO" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="maximal_gemm_tensile_instrumented"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Run rocblas_sgemm with instrumented Tensile kernels (hip_full)"

    FILTER_FILE=$(mktemp /tmp/maximal_filter_XXXXXX.json)
    echo "{\"include\": [\"$TENSILE_HSACO\"]}" > "$FILTER_FILE"
    trap "rm -f $FILTER_FILE" EXIT

    OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       LD_LIBRARY_PATH="$COMBINED_LIB_PATH" \
       "$OMNIPROBE" -i -a MemoryAnalysis --library-filter "$FILTER_FILE" \
       -- "$TEST_GEMM" > "$OUTPUT_FILE" 2>&1; then

        if grep -q "rocblas_sgemm: PASS" "$OUTPUT_FILE"; then
            echo -e "  ${GREEN}PASS${NC} - rocblas_sgemm computation correct"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC} - rocblas_sgemm computation failed"
            echo "  Output saved to: $OUTPUT_FILE"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}FAIL${NC} - omniprobe execution failed"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Test 4: Tensile kernel instrumented alternative found
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="maximal_gemm_tensile_alternative"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Verify instrumented alternative found for Tensile GEMM kernel"

    if grep -q "Found instrumented alternative for.*Cijk" "$OUTPUT_DIR/maximal_gemm_tensile_instrumented.out"; then
        echo -e "  ${GREEN}PASS${NC} - Found instrumented alternative for Tensile kernel"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} - No instrumented alternative for Tensile kernel"
        echo "  Output saved to: $OUTPUT_DIR/maximal_gemm_tensile_instrumented.out"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "\n${YELLOW}SKIP${NC}: No instrumented Tensile .hsaco files found (requires hip_full build)"
fi

################################################################################
# Test 5: MemoryAnalysis reports generated
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="maximal_reports_generated"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify L2 cache and bank conflicts reports"

SCAL_OUT="$OUTPUT_DIR/maximal_scal_instrumented.out"
if grep -q "L2 cache line use report" "$SCAL_OUT" && grep -q "Bank conflicts report" "$SCAL_OUT"; then
    echo -e "  ${GREEN}PASS${NC} - Both MemoryAnalysis reports present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}FAIL${NC} - MemoryAnalysis reports not found"
    echo "  Output saved to: $SCAL_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Summary
################################################################################

echo ""
echo "================================================================================"
echo "rocBLAS + hipBLASLt Combined Test Summary"
echo "================================================================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "================================================================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All combined instrumentation tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some combined instrumentation tests failed.${NC}"
    exit 1
fi
