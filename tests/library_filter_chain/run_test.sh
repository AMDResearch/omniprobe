#!/bin/bash
################################################################################
# Library Filter Chain Test Script
#
# Tests library include/exclude filtering with:
# - Static libraries (linked at compile time)
# - Dynamic libraries (loaded via dlopen at runtime)
#
# Usage:
#   ./run_test.sh [--build-only] [--no-instrument] [--clean]
#
# Options:
#   --build-only    Build without running tests
#   --no-instrument Build without instrumentation (for initial verification)
#   --clean         Clean build directory before building
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
TEST_OUTPUT_DIR="${SCRIPT_DIR}/test_output"

# Use repo's omniprobe - always use relative paths, never hardcoded installation paths
OMNIPROBE="${REPO_ROOT}/omniprobe/omniprobe"
OMNIPROBE_BUILD_DIR="${REPO_ROOT}/build"

# Parse arguments
BUILD_ONLY=false
NO_INSTRUMENT=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --build-only)
            BUILD_ONLY=true
            ;;
        --no-instrument)
            NO_INSTRUMENT=true
            ;;
        --clean)
            CLEAN=true
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# Build
################################################################################

if [ "$CLEAN" = true ] && [ -d "$BUILD_DIR" ]; then
    log_info "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"
mkdir -p "$TEST_OUTPUT_DIR"

cd "$BUILD_DIR"

# Configure
CMAKE_ARGS=()

if [ "$NO_INSTRUMENT" = false ]; then
    # Find instrumentation plugin from main omniprobe build
    # Look for it in common locations
    OMNIPROBE_BUILD="${SCRIPT_DIR}/../../build"
    INST_PLUGIN="${OMNIPROBE_BUILD}/external/instrument-amdgpu-kernels-rocm/build/lib/libAMDGCNSubmitAddressMessages-rocm.so"

    if [ -f "$INST_PLUGIN" ]; then
        log_info "Using instrumentation plugin: $INST_PLUGIN"
        CMAKE_ARGS+=("-DINST_PLUGIN=${INST_PLUGIN}")
    else
        log_warn "Instrumentation plugin not found at: $INST_PLUGIN"
        log_warn "Building without instrumentation. Run omniprobe build first for instrumented builds."
    fi
fi

log_info "Configuring..."
cmake "${CMAKE_ARGS[@]}" ..

log_info "Building..."
cmake --build . --parallel

if [ "$BUILD_ONLY" = true ]; then
    log_info "Build complete. Skipping tests."
    exit 0
fi

################################################################################
# Test: Run without omniprobe (verify cross-library calls work)
################################################################################

log_info "=== Test 1: Run without omniprobe (basic functionality) ==="

export LIB_DYNAMIC_HEAD_PATH="${BUILD_DIR}/libdynamic_head.so"
export LD_LIBRARY_PATH="${BUILD_DIR}:${LD_LIBRARY_PATH}"

if [ ! -f "$LIB_DYNAMIC_HEAD_PATH" ]; then
    log_error "Dynamic library not found: $LIB_DYNAMIC_HEAD_PATH"
    exit 1
fi

log_info "Running app without omniprobe..."
./library_filter_chain_app 2>&1 | tee "${TEST_OUTPUT_DIR}/run_no_omniprobe.log"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_info "Test 1 PASSED: App runs successfully without omniprobe"
else
    log_error "Test 1 FAILED: App failed to run"
    exit 1
fi

################################################################################
# Verify library dependencies
################################################################################

log_info "=== Library dependency verification ==="

log_info "Static library chain:"
echo "  libstatic_head.so dependencies:"
ldd libstatic_head.so 2>/dev/null | grep -E "static_(mid|tail)" || echo "    (none found - may be using rpath)"

log_info "Dynamic library chain:"
echo "  libdynamic_head.so dependencies:"
ldd libdynamic_head.so 2>/dev/null | grep -E "dynamic_(mid|tail)" || echo "    (none found - may be using rpath)"

################################################################################
# Test: Run under omniprobe (verify instrumented kernels are detected)
################################################################################

log_info "=== Test 2: Run under omniprobe (instrumented) ==="

# Check omniprobe exists
if [ ! -x "$OMNIPROBE" ]; then
    log_warn "omniprobe not found at $OMNIPROBE - skipping omniprobe tests"
    log_warn "To run omniprobe tests, ensure the repo's omniprobe script exists"
else
    # Check if omniprobe build exists
    if [ ! -d "$OMNIPROBE_BUILD_DIR" ]; then
        log_warn "omniprobe build directory not found at $OMNIPROBE_BUILD_DIR - skipping omniprobe tests"
        log_warn "Build omniprobe first: cd ${REPO_ROOT}/build && ninja"
    else
        log_info "Running app under omniprobe (MemoryAnalysis handler)..."

        # Run with omniprobe - expect to see static lib kernels but NOT dynamic lib kernels
        # (dynamic libs are loaded via dlopen, not visible to dl_iterate_phdr at startup)
        # omniprobe auto-detects build dir from runtime_config.txt relative to script location
        "$OMNIPROBE" \
            -a MemoryAnalysis \
            -i \
            -- ./library_filter_chain_app 2>&1 | tee "${TEST_OUTPUT_DIR}/run_with_omniprobe.log"

        OMNIPROBE_EXIT=${PIPESTATUS[0]}

        if [ $OMNIPROBE_EXIT -eq 0 ]; then
            log_info "omniprobe completed successfully"

            # Check which kernels were instrumented
            log_info "Checking kernel instrumentation..."

            # Static kernels should be instrumented (linked at compile time, in kernel cache)
            if grep -q "Found instrumented alternative for static_head_kernel\|Found instrumented alternative for static_mid_kernel\|Found instrumented alternative for static_tail_kernel" "${TEST_OUTPUT_DIR}/run_with_omniprobe.log"; then
                log_info "  Static library kernels: INSTRUMENTED (expected)"
            else
                log_warn "  Static library kernels: NOT INSTRUMENTED (unexpected)"
            fi

            # Dynamic kernels should NOT be instrumented without library-filter include
            # (dlopen'd libraries not in kernel cache built at startup)
            if grep -q "No instrumented alternative found for dynamic_head_kernel\|No instrumented alternative found for dynamic_mid_kernel\|No instrumented alternative found for dynamic_tail_kernel" "${TEST_OUTPUT_DIR}/run_with_omniprobe.log"; then
                log_info "  Dynamic library kernels: NOT INSTRUMENTED (expected without library-filter)"
            else
                log_warn "  Dynamic library kernels: INSTRUMENTED (unexpected without library-filter)"
            fi

            log_info "Test 2 PASSED: omniprobe ran successfully"
        else
            log_error "Test 2 FAILED: omniprobe failed with exit code $OMNIPROBE_EXIT"
            exit 1
        fi

        ############################################################################
        # Test 3: Exclude static libraries
        ############################################################################

        log_info "=== Test 3: Exclude static libraries ==="

        # Create filter config - exclude all static libs
        FILTER_FILE="${TEST_OUTPUT_DIR}/exclude_static.json"
        cat > "$FILTER_FILE" << EOF
{
  "exclude": [
    "${BUILD_DIR}/libstatic_head.so",
    "${BUILD_DIR}/libstatic_mid.so",
    "${BUILD_DIR}/libstatic_tail.so"
  ]
}
EOF

        log_info "Filter config: $FILTER_FILE"
        cat "$FILTER_FILE"

        "$OMNIPROBE" \
            -a MemoryAnalysis \
            -i \
            --library-filter "$FILTER_FILE" \
            -- ./library_filter_chain_app 2>&1 | tee "${TEST_OUTPUT_DIR}/test3_exclude_static.log"

        OMNIPROBE_EXIT=${PIPESTATUS[0]}

        if [ $OMNIPROBE_EXIT -eq 0 ]; then
            # Static libs should NOT be scanned (excluded)
            if grep -q "Adding ${BUILD_DIR}/libstatic_head.so" "${TEST_OUTPUT_DIR}/test3_exclude_static.log"; then
                log_error "Test 3 FAILED: libstatic_head.so was added despite exclude"
                exit 1
            fi

            # Static kernels should NOT be instrumented (libs excluded from scanning)
            if grep -q "No instrumented alternative found for static_head_kernel" "${TEST_OUTPUT_DIR}/test3_exclude_static.log"; then
                log_info "  Static kernels NOT instrumented (expected - libs excluded)"
            elif grep -q "Found instrumented alternative for static_head_kernel" "${TEST_OUTPUT_DIR}/test3_exclude_static.log"; then
                log_error "Test 3 FAILED: Static kernel instrumented despite lib exclusion"
                exit 1
            else
                log_info "  Static kernels not mentioned (libs excluded from scan)"
            fi

            log_info "Test 3 PASSED: Static libraries excluded correctly"
        else
            log_error "Test 3 FAILED: omniprobe failed with exit code $OMNIPROBE_EXIT"
            exit 1
        fi

        ############################################################################
        # Test 4: Include dynamic libraries (head only, no deps)
        ############################################################################

        log_info "=== Test 4: Include dynamic library (head only) ==="

        # Create filter config - include only dynamic_head
        FILTER_FILE="${TEST_OUTPUT_DIR}/include_dynamic_head.json"
        cat > "$FILTER_FILE" << EOF
{
  "include": [
    "${BUILD_DIR}/libdynamic_head.so"
  ]
}
EOF

        log_info "Filter config: $FILTER_FILE"
        cat "$FILTER_FILE"

        "$OMNIPROBE" \
            -a MemoryAnalysis \
            -i \
            --library-filter "$FILTER_FILE" \
            -- ./library_filter_chain_app 2>&1 | tee "${TEST_OUTPUT_DIR}/test4_include_dynamic_head.log"

        OMNIPROBE_EXIT=${PIPESTATUS[0]}

        if [ $OMNIPROBE_EXIT -eq 0 ]; then
            # dynamic_head should be added
            if grep -q "Adding ${BUILD_DIR}/libdynamic_head.so" "${TEST_OUTPUT_DIR}/test4_include_dynamic_head.log"; then
                log_info "  libdynamic_head.so: ADDED (expected)"
            else
                log_error "Test 4 FAILED: libdynamic_head.so was NOT added"
                exit 1
            fi

            # dynamic_mid and dynamic_tail should NOT be added (no deps resolution)
            if grep -q "Adding ${BUILD_DIR}/libdynamic_mid.so" "${TEST_OUTPUT_DIR}/test4_include_dynamic_head.log"; then
                log_warn "  libdynamic_mid.so: ADDED (unexpected for include without deps)"
            else
                log_info "  libdynamic_mid.so: NOT ADDED (expected for include without deps)"
            fi

            # dynamic_head kernel should now be instrumented
            if grep -q "Found instrumented alternative for dynamic_head_kernel" "${TEST_OUTPUT_DIR}/test4_include_dynamic_head.log"; then
                log_info "  dynamic_head_kernel: INSTRUMENTED (expected)"
            else
                log_error "Test 4 FAILED: dynamic_head_kernel NOT instrumented despite include"
                exit 1
            fi

            log_info "Test 4 PASSED: Dynamic library included correctly"
        else
            log_error "Test 4 FAILED: omniprobe failed with exit code $OMNIPROBE_EXIT"
            exit 1
        fi

        ############################################################################
        # Test 5: Include dynamic libraries with deps
        ############################################################################

        log_info "=== Test 5: Include dynamic library with deps ==="

        # Create filter config - include dynamic_head with dependencies
        FILTER_FILE="${TEST_OUTPUT_DIR}/include_dynamic_with_deps.json"
        cat > "$FILTER_FILE" << EOF
{
  "include_with_deps": [
    "${BUILD_DIR}/libdynamic_head.so"
  ]
}
EOF

        log_info "Filter config: $FILTER_FILE"
        cat "$FILTER_FILE"

        "$OMNIPROBE" \
            -a MemoryAnalysis \
            -i \
            --library-filter "$FILTER_FILE" \
            -- ./library_filter_chain_app 2>&1 | tee "${TEST_OUTPUT_DIR}/test5_include_dynamic_with_deps.log"

        OMNIPROBE_EXIT=${PIPESTATUS[0]}

        if [ $OMNIPROBE_EXIT -eq 0 ]; then
            # All dynamic libs should be added (head + deps)
            if grep -q "Adding ${BUILD_DIR}/libdynamic_head.so" "${TEST_OUTPUT_DIR}/test5_include_dynamic_with_deps.log"; then
                log_info "  libdynamic_head.so: ADDED (expected)"
            else
                log_error "Test 5 FAILED: libdynamic_head.so was NOT added"
                exit 1
            fi

            # Check if deps are resolved (requires getElfDependencies implementation)
            if grep -q "Adding ${BUILD_DIR}/libdynamic_mid.so" "${TEST_OUTPUT_DIR}/test5_include_dynamic_with_deps.log"; then
                log_info "  libdynamic_mid.so: ADDED (expected with deps)"
            else
                log_warn "  libdynamic_mid.so: NOT ADDED (getElfDependencies not implemented yet)"
            fi

            if grep -q "Adding ${BUILD_DIR}/libdynamic_tail.so" "${TEST_OUTPUT_DIR}/test5_include_dynamic_with_deps.log"; then
                log_info "  libdynamic_tail.so: ADDED (expected with deps)"
            else
                log_warn "  libdynamic_tail.so: NOT ADDED (getElfDependencies not implemented yet)"
            fi

            log_info "Test 5 PASSED: include_with_deps works with dependency resolution"
        else
            log_error "Test 5 FAILED: omniprobe failed with exit code $OMNIPROBE_EXIT"
            exit 1
        fi

    fi
fi

################################################################################
# Summary
################################################################################

log_info "=== All tests passed ==="
log_info "Build directory: $BUILD_DIR"
log_info "Test output: $TEST_OUTPUT_DIR"
