#!/bin/bash
################################################################################
# rocBLAS offload compression test for omniprobe
#
# Verifies that omniprobe can decompress CCOB (Compressed Clang Offload Bundle)
# files and find instrumented kernel alternatives in:
#   - Compressed .hip_fatbin sections in librocblas.so (scal, Level 1 BLAS)
#   - Compressed Tensile .co files (gemm, Level 3 BLAS) [decompression only]
#
# Prerequisites:
#   - ROCBLAS_COMPRESSED_LIB_DIR environment variable pointing to the directory
#     containing an instrumented librocblas.so built WITH offload compression.
#     Example: /path/to/rocBLAS/build-with-offload-compression/release/rocblas-install/lib
#   - Pre-built test binaries in tests/rocblas_filter/ (test_rocblas_scal, test_rocblas_gemm)
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

if [ -z "$ROCBLAS_COMPRESSED_LIB_DIR" ]; then
    echo -e "${YELLOW}SKIP: ROCBLAS_COMPRESSED_LIB_DIR not set.${NC}"
    echo "Set it to the directory containing an instrumented librocblas.so built WITH offload compression."
    exit 0
fi

if [ ! -f "$ROCBLAS_COMPRESSED_LIB_DIR/librocblas.so" ]; then
    echo -e "${RED}ERROR: librocblas.so not found in $ROCBLAS_COMPRESSED_LIB_DIR${NC}"
    exit 1
fi

if [ ! -x "$OMNIPROBE" ]; then
    echo -e "${RED}ERROR: omniprobe not found at $OMNIPROBE${NC}"
    exit 1
fi

if [ ! -x "$TEST_SCAL" ]; then
    echo -e "${RED}ERROR: test_rocblas_scal not found at $TEST_SCAL${NC}"
    exit 1
fi

echo "================================================================================"
echo "rocBLAS Offload Compression Tests"
echo "================================================================================"
echo "Omniprobe:          $OMNIPROBE"
echo "rocBLAS lib (comp): $ROCBLAS_COMPRESSED_LIB_DIR"
echo "Test binary (scal): $TEST_SCAL"
echo "Test binary (gemm): $TEST_GEMM"
echo "Output dir:         $OUTPUT_DIR"
echo "GPU:                ROCR_VISIBLE_DEVICES=$ROCR_VISIBLE_DEVICES"
echo "================================================================================"

################################################################################
# Test 1: Scal kernel runs with compressed .hip_fatbin instrumentation
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="offload_compression_scal_instrumented"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Run rocblas_sscal with MemoryAnalysis on compressed librocblas.so"

OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

SECONDS=0
if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
   LD_LIBRARY_PATH="$ROCBLAS_COMPRESSED_LIB_DIR:$LD_LIBRARY_PATH" \
   "$OMNIPROBE" -i -a MemoryAnalysis \
   -- "$TEST_SCAL" > "$OUTPUT_FILE" 2>&1; then
    ELAPSED_SECONDS=$SECONDS

    if grep -q "rocblas_sscal: PASS" "$OUTPUT_FILE"; then
        echo -e "  ${GREEN}✓ PASS${NC} - rocblas_sscal computation correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - rocblas_sscal computation failed"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
    echo "  Output saved to: $OUTPUT_FILE"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 2: Instrumented alternative found for scal kernel (compressed .hip_fatbin)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="offload_compression_scal_alternative"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify instrumented alternative found in decompressed .hip_fatbin"

if grep -q "Found instrumented alternative for.*rocblas_sscal" "$OUTPUT_DIR/offload_compression_scal_instrumented.out"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Found instrumented alternative for sscal kernel"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - No instrumented alternative found"
    echo "  Output saved to: $OUTPUT_DIR/offload_compression_scal_instrumented.out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 3: MemoryAnalysis reports generated (proves end-to-end instrumentation)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="offload_compression_scal_reports"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify L2 cache and bank conflicts reports generated"

SCAL_OUTPUT="$OUTPUT_DIR/offload_compression_scal_instrumented.out"
if grep -q "L2 cache line use report" "$SCAL_OUTPUT" && grep -q "Bank conflicts report" "$SCAL_OUTPUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - Both MemoryAnalysis reports present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - MemoryAnalysis reports not found"
    echo "  Output saved to: $SCAL_OUTPUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 4: Scal completes in reasonable time (< 120 seconds)
################################################################################

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="offload_compression_scal_elapsed_time"
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
echo "  Verify total elapsed time < 120 seconds"

if [ "$ELAPSED_SECONDS" -lt 120 ] 2>/dev/null; then
    echo -e "  ${GREEN}✓ PASS${NC} - Total elapsed time: ${ELAPSED_SECONDS}s"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - Total elapsed time: ${ELAPSED_SECONDS:-unknown}s (limit: 120s)"
    echo "  Output saved to: $SCAL_OUTPUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 5: Gemm runs correctly (correctness check)
################################################################################

if [ -x "$TEST_GEMM" ]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TEST_NAME="offload_compression_gemm_runs"
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
    echo "  Run rocblas_sgemm correctness check"

    OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

    if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
       LD_LIBRARY_PATH="$ROCBLAS_COMPRESSED_LIB_DIR:$LD_LIBRARY_PATH" \
       "$OMNIPROBE" -i -a MemoryAnalysis \
       -- "$TEST_GEMM" > "$OUTPUT_FILE" 2>&1; then

        if grep -q "rocblas_sgemm: PASS" "$OUTPUT_FILE"; then
            echo -e "  ${GREEN}✓ PASS${NC} - rocblas_sgemm computation correct"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗ FAIL${NC} - rocblas_sgemm computation failed"
            echo "  Output saved to: $OUTPUT_FILE"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
        echo "  Output saved to: $OUTPUT_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    ############################################################################
    # Test 6: Gemm with instrumented Tensile kernels via library-filter include
    #
    # When Tensile .hsaco files are present (hip_full build), we can use
    # --library-filter to include them and match instrumented alternatives.
    ############################################################################

    TENSILE_LIB_DIR="$ROCBLAS_COMPRESSED_LIB_DIR/rocblas/library"
    TENSILE_HSACO=$(find "$TENSILE_LIB_DIR" -name "*.hsaco" 2>/dev/null | head -1)

    # Only run if a .hsaco contains instrumented sgemm Tensile clones (hip_full build).
    # The asm_full build may have Kernels.so-*.hsaco but its sgemm kernels come from
    # assembly .co files and won't have __amd_crk_ clones in the .hsaco.
    TENSILE_HSACO=""
    for hsaco in $(find "$TENSILE_LIB_DIR" -name "Kernels.so-*.hsaco" 2>/dev/null); do
        if readelf -sW "$hsaco" 2>/dev/null | grep -q "__amd_crk_Cijk_Ailk_Bljk_S_"; then
            TENSILE_HSACO="$hsaco"
            break
        fi
    done

    if [ -n "$TENSILE_HSACO" ]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        TEST_NAME="offload_compression_gemm_tensile_instrumented"
        echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $TEST_NAME"
        echo "  Run rocblas_sgemm with instrumented Tensile kernels via library-filter"

        # Create temporary library-filter config
        FILTER_CONFIG="$OUTPUT_DIR/tensile_include_filter.json"
        echo "{\"include\": [\"$TENSILE_HSACO\"]}" > "$FILTER_CONFIG"

        OUTPUT_FILE="$OUTPUT_DIR/${TEST_NAME}.out"

        if ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" \
           LD_LIBRARY_PATH="$ROCBLAS_COMPRESSED_LIB_DIR:$LD_LIBRARY_PATH" \
           "$OMNIPROBE" -i -a MemoryAnalysis --library-filter "$FILTER_CONFIG" \
           -- "$TEST_GEMM" > "$OUTPUT_FILE" 2>&1; then

            if grep -q "Found instrumented alternative for.*Cijk" "$OUTPUT_FILE"; then
                echo -e "  ${GREEN}✓ PASS${NC} - Found instrumented alternative for Tensile kernel"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "  ${RED}✗ FAIL${NC} - No instrumented alternative found for Tensile kernel"
                echo "  Output saved to: $OUTPUT_FILE"
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        else
            echo -e "  ${RED}✗ FAIL${NC} - omniprobe execution failed"
            echo "  Output saved to: $OUTPUT_FILE"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    else
        echo -e "\n${YELLOW}SKIP${NC}: No instrumented Tensile .hsaco files found (requires hip_full build)"
    fi
else
    echo -e "\n${YELLOW}SKIP${NC}: test_rocblas_gemm not found, skipping gemm tests"
fi

################################################################################
# Summary
################################################################################

echo ""
echo "================================================================================"
echo "rocBLAS Offload Compression Test Summary"
echo "================================================================================"
echo "Total tests run: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "================================================================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All offload compression tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some offload compression tests failed.${NC}"
    exit 1
fi
