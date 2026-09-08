#!/bin/bash
################################################################################
# Shared helpers for tests that compile an instrumented kernel on the fly.
#
# Source AFTER test_common.sh.
#
# These tests cannot use the kernels CMake builds into $BUILD_DIR/tests/: those are
# compiled for CMAKE_HIP_ARCHITECTURES, which need not match the GPU in the machine
# running the test. Measured 2026-09-08: the gfx90a `build/` tree's test kernels
# dispatch nothing at all on a gfx950 node, silently — the run exits 0 and produces
# no reports. So each kernel here is compiled for the architecture actually present.
################################################################################

# Detect the GPU architecture. Echoes e.g. gfx950, or nothing if it cannot tell.
detect_gpu_arch() {
    local rocminfo_bin="${ROCM_PATH:-/opt/rocm}/bin/rocminfo"
    [ -x "$rocminfo_bin" ] || rocminfo_bin="$(command -v rocminfo 2>/dev/null)"
    [ -n "$rocminfo_bin" ] || return 1
    "$rocminfo_bin" 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1
}

# A directory the GPU loader can mmap. /work1 and /home1 are fuseblk on some nodes of
# this cluster and virtiofs on others; neither supports mmap, and hipModuleLoad fails
# on them. /tmp is local XFS everywhere we have measured.
instrumented_scratch_dir() {
    local dir="${OMNIPROBE_TEST_SCRATCH:-/tmp/omniprobe-tests-$$}"
    mkdir -p "$dir" || return 1
    echo "$dir"
}

# compile_instrumented_kernel <source> <output-binary> [extra hipcc args...]
#
# Returns 0 on success, 1 if the toolchain or plugin is missing (caller should SKIP),
# 2 if compilation itself failed (caller should FAIL — that is a real defect).
compile_instrumented_kernel() {
    local src="$1" out="$2"; shift 2
    local hipcc="${ROCM_PATH:-/opt/rocm}/bin/hipcc"
    local plugin="${BUILD_DIR}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"

    [ -x "$hipcc" ] || { echo "hipcc not found at $hipcc"; return 1; }
    [ -f "$plugin" ] || { echo "instrumentation plugin not built at $plugin"; return 1; }
    [ -f "$src" ] || { echo "kernel source not found at $src"; return 1; }

    local arch
    arch="$(detect_gpu_arch)"
    [ -n "$arch" ] || { echo "cannot detect GPU architecture via rocminfo"; return 1; }

    if ! "$hipcc" -fgpu-rdc -g --offload-arch="$arch" -fpass-plugin="$plugin" \
            "$@" "$src" -o "$out" > "${out}.compile.log" 2>&1; then
        echo "compilation failed for $src (arch $arch) — see ${out}.compile.log"
        return 2
    fi
    return 0
}
