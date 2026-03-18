#!/bin/bash
#
# Build and install Triton with shared-library LLVM for Omniprobe instrumentation.
#
# This script must be sourced (not executed) so that the venv activation and
# environment variables persist in the caller's shell:
#
#   source triton_install.sh [OPTIONS]
#
# Prerequisites:
#   - ROCm installed with ROCM_PATH set (e.g., /opt/rocm or /opt/rocm-7.2.0)
#   - Python 3 with pip and venv
#   - Network access (GitHub API, PyPI, PyTorch wheel index)
#   - ninja, cmake available or installable via pip
#
# The script will:
#   1. Clone Triton at the specified (or latest) release tag
#   2. Build LLVM with shared libraries using Triton's build helper
#   3. Create a Python venv with PyTorch and build dependencies
#   4. Patch Triton source for instrumentation compatibility
#   5. Build and install Triton against the shared LLVM
#
# After completion, the venv is activated and TRITON_HIP_LLD_PATH is set.
# The LLVM build is at ${TRITON_REPO}/llvm-project/build — use this path
# for Omniprobe's CMake: -DTRITON_LLVM=${TRITON_REPO}/llvm-project/build

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced. Run 'source $(basename "${BASH_SOURCE[0]}")'" >&2
    exit 1
fi

# Save original positional parameters and OPTIND
_triton_original_params=("$@")
_triton_original_OPTIND=$OPTIND
OPTIND=1
_triton_restore_env() {
    set -- "${_triton_original_params[@]}"
    OPTIND=$_triton_original_OPTIND
}
trap _triton_restore_env RETURN

# ── Defaults ─────────────────────────────────────────────────────────────────

TRITON_VERSION=""      # auto-detect if empty
PYTORCH_ROCM_VERSION="" # auto-detect if empty

# ── Usage ────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'HELP'
Usage: source triton_install.sh [OPTIONS]

Build Triton with shared-library LLVM for Omniprobe instrumentation.

Options:
  --triton-version TAG   Triton version to build (tag or commit hash)
                         Default: latest release from GitHub API
  -g TAG                 Alias for --triton-version
  --pytorch-rocm VER     PyTorch ROCm wheel index version (e.g., 7.1)
                         Default: highest stable index <= installed ROCm
  -h, --help             Show this help message

Examples:
  source triton_install.sh                           # auto-detect everything
  source triton_install.sh --triton-version v3.6.0   # specific Triton tag
  source triton_install.sh -g v3.6.0 --pytorch-rocm 7.1
HELP
}

# ── Helper functions ─────────────────────────────────────────────────────────

log_step() {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}

log_info() {
    echo "  ▸ $1"
}

log_warn() {
    echo "  ⚠ $1" >&2
}

log_error() {
    echo "  ✖ $1" >&2
}

get_rocm_version() {
    # Extract ROCm version from ROCM_PATH (e.g., /opt/rocm-7.2.0 → 7.2)
    # Falls back to reading the .info/version file
    local version=""
    if [[ "$ROCM_PATH" =~ rocm-([0-9]+\.[0-9]+) ]]; then
        version="${BASH_REMATCH[1]}"
    elif [ -f "${ROCM_PATH}/.info/version" ]; then
        version=$(head -1 "${ROCM_PATH}/.info/version" | grep -oP '[0-9]+\.[0-9]+')
    fi
    echo "$version"
}

detect_triton_version() {
    # Note: this function is called inside $(...), so only echo the result
    # to stdout. Informational messages go to stderr via log_info >&2.
    log_info "Querying GitHub API for latest Triton release..." >&2
    local tag
    tag=$(curl -sL "https://api.github.com/repos/triton-lang/triton/releases/latest" | \
        python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
    if [ -z "$tag" ]; then
        log_error "Failed to detect latest Triton release from GitHub API"
        return 1
    fi
    echo "$tag"
}

detect_pytorch_rocm_version() {
    # Note: this function is called inside $(...), so only echo the result
    # to stdout. Informational messages go to stderr via log_info >&2.
    local rocm_version="$1"
    log_info "Detecting best PyTorch ROCm index for ROCm ${rocm_version}..." >&2
    local best
    best=$(curl -sL "https://download.pytorch.org/whl/" | \
        python3 -c "
import sys, re
html = sys.stdin.read()
versions = sorted(set(re.findall(r'rocm([\d.]+)', html)),
                  key=lambda v: list(map(int, v.split('.'))))
target = list(map(int, '${rocm_version}'.split('.')))
best = None
for v in versions:
    parts = list(map(int, v.split('.')))
    if parts[:2] <= target[:2]:
        best = v
if best:
    print(best)
else:
    sys.exit(1)
" 2>/dev/null)
    if [ -z "$best" ]; then
        log_error "No PyTorch ROCm index found for ROCm <= ${rocm_version}"
        return 1
    fi
    echo "$best"
}

patch_triton_source() {
    # Patch the assertion that fails when instrumentation clones kernels.
    # The file location changed across Triton versions:
    #   Old: python/triton/backends/amd/compiler.py
    #   New: third_party/amd/backend/compiler.py
    local files=(
        "third_party/amd/backend/compiler.py"
        "python/triton/backends/amd/compiler.py"
    )
    local patched=false
    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            if grep -q "^[[:space:]]*assert len(names) == 1" "$file"; then
                sed -i 's/^\([[:space:]]*\)assert len(names) == 1/\1# assert len(names) == 1  # patched for Omniprobe instrumentation/' "$file"
                log_info "Patched assertion in ${file}"
                patched=true
            else
                log_info "Assertion already patched or absent in ${file}"
                patched=true
            fi
            return 0
        fi
    done
    if ! $patched; then
        log_warn "Could not find compiler.py to patch — instrumentation may fail"
    fi
    return 0
}

# ── Parse arguments ──────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            return 0
            ;;
        -g)
            TRITON_VERSION="$2"
            shift 2
            ;;
        --triton-version)
            TRITON_VERSION="$2"
            shift 2
            ;;
        --triton-version=*)
            TRITON_VERSION="${1#*=}"
            shift
            ;;
        --pytorch-rocm)
            PYTORCH_ROCM_VERSION="$2"
            shift 2
            ;;
        --pytorch-rocm=*)
            PYTORCH_ROCM_VERSION="${1#*=}"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            return 1
            ;;
    esac
done

# ── Prerequisites ────────────────────────────────────────────────────────────

log_step "Checking prerequisites"

if [ -z "$ROCM_PATH" ]; then
    log_error "ROCM_PATH is not set. Please set it to your ROCm installation."
    log_error "Example: export ROCM_PATH=/opt/rocm-7.2.0"
    return 1
fi

if [ ! -d "$ROCM_PATH" ]; then
    log_error "ROCM_PATH=${ROCM_PATH} does not exist"
    return 1
fi

if [ ! -x "${ROCM_PATH}/llvm/bin/clang" ]; then
    log_error "ROCm clang not found at ${ROCM_PATH}/llvm/bin/clang"
    log_error "Is ROCm properly installed?"
    return 1
fi

ROCM_VERSION=$(get_rocm_version)
if [ -z "$ROCM_VERSION" ]; then
    log_error "Could not determine ROCm version from ROCM_PATH=${ROCM_PATH}"
    return 1
fi

if ! command -v python3 &>/dev/null; then
    log_error "python3 not found in PATH"
    return 1
fi

log_info "ROCm ${ROCM_VERSION} at ${ROCM_PATH}"
log_info "Python: $(python3 --version)"

# ── Step 1: Detect versions ─────────────────────────────────────────────────

log_step "Step 1: Determining versions"

if [ -z "$TRITON_VERSION" ]; then
    TRITON_VERSION=$(detect_triton_version) || return 1
    log_info "Auto-detected Triton version: ${TRITON_VERSION}"
else
    log_info "Using specified Triton version: ${TRITON_VERSION}"
fi

if [ -z "$PYTORCH_ROCM_VERSION" ]; then
    PYTORCH_ROCM_VERSION=$(detect_pytorch_rocm_version "$ROCM_VERSION") || return 1
    log_info "Auto-detected PyTorch ROCm index: rocm${PYTORCH_ROCM_VERSION}"
else
    log_info "Using specified PyTorch ROCm index: rocm${PYTORCH_ROCM_VERSION}"
fi

# ── Step 2: Clone Triton ────────────────────────────────────────────────────

log_step "Step 2: Cloning Triton ${TRITON_VERSION}"

git clone https://github.com/triton-lang/triton.git
if [ $? -ne 0 ]; then
    log_error "Failed to clone Triton repository"
    return 1
fi

cd triton || return 1
TRITON_REPO="$(pwd)"

git checkout "${TRITON_VERSION}"
if [ $? -ne 0 ]; then
    log_error "Failed to checkout Triton version: ${TRITON_VERSION}"
    return 1
fi

log_info "Triton cloned at ${TRITON_REPO}"
log_info "Checked out: $(git describe --tags --always 2>/dev/null || echo "${TRITON_VERSION}")"

# ── Step 3: Patch Triton source ─────────────────────────────────────────────

log_step "Step 3: Patching Triton source"

patch_triton_source

# ── Step 4: Build LLVM with shared libraries ────────────────────────────────

log_step "Step 4: Building LLVM with shared libraries"

log_info "This may take a while (30-90 minutes depending on hardware)..."
log_info "LLVM commit hash: $(cat cmake/llvm-hash.txt 2>/dev/null || echo 'unknown')"

# Put ROCm's clang on PATH so build-llvm-project.sh picks it up as the
# default CMAKE_C_COMPILER=clang / CMAKE_CXX_COMPILER=clang++
export PATH="${ROCM_PATH}/llvm/bin:${PATH}"

# Set env vars for Triton's build helper script
export LLVM_BUILD_SHARED_LIBS=ON
export LLVM_PROJECTS="clang;mlir;llvm;lld"

scripts/build-llvm-project.sh
if [ $? -ne 0 ]; then
    log_error "LLVM build failed"
    return 1
fi

LLVM_BUILD_DIR="${TRITON_REPO}/llvm-project/build"
log_info "LLVM built at: ${LLVM_BUILD_DIR}"

# Verify shared libraries were built
if ls "${LLVM_BUILD_DIR}/lib/"libLLVM*.so &>/dev/null; then
    log_info "Verified: LLVM shared libraries present"
else
    log_warn "LLVM shared libraries not found — build may have used static linking"
fi

# ── Step 5: Create venv and install Python dependencies ─────────────────────

log_step "Step 5: Setting up Python environment"

python3 -m venv .venv --prompt triton
source .venv/bin/activate

log_info "venv activated: $(which python3)"

# Build-time dependencies
python3 -m pip install ninja cmake wheel pybind11
# Run-time dependencies
python3 -m pip install matplotlib pandas
# PyTorch
log_info "Installing PyTorch from rocm${PYTORCH_ROCM_VERSION} index..."
python3 -m pip install torch torchvision \
    --index-url "https://download.pytorch.org/whl/rocm${PYTORCH_ROCM_VERSION}"

# Remove conflicting Triton package bundled with PyTorch
python3 -m pip uninstall --yes pytorch-triton-rocm 2>/dev/null || true

# ── Step 6: Build and install Triton ────────────────────────────────────────

log_step "Step 6: Building Triton with shared LLVM"

# Clean any stale build artifacts
rm -rf python/triton/_C build compile_commands.json

CC="${LLVM_BUILD_DIR}/bin/clang" \
CXX="${LLVM_BUILD_DIR}/bin/clang++" \
LLVM_BUILD_PATH="${LLVM_BUILD_DIR}" \
LLVM_BUILD_SHARED_LIBS=1 \
TRITON_BUILD_WITH_CLANG_LLD=1 \
TRITON_BUILD_WITH_CCACHE=0 \
LLVM_INCLUDE_DIRS="${LLVM_BUILD_DIR}/include" \
LLVM_LIBRARY_DIR="${LLVM_BUILD_DIR}/lib" \
LLVM_SYSPATH="${LLVM_BUILD_DIR}" \
python3 -m pip install . --no-build-isolation

if [ $? -ne 0 ]; then
    log_error "Triton build/install failed"
    return 1
fi

# ── Step 7: Set environment variables and report ────────────────────────────

log_step "Installation complete"

export TRITON_HIP_LLD_PATH="${ROCM_PATH}/llvm/bin/ld.lld"

log_info "Triton version:     ${TRITON_VERSION}"
log_info "LLVM hash:          $(cat cmake/llvm-hash.txt 2>/dev/null || echo 'unknown')"
log_info "PyTorch ROCm index: rocm${PYTORCH_ROCM_VERSION}"
log_info "ROCm version:       ${ROCM_VERSION}"
log_info ""
log_info "Key paths:"
log_info "  Triton repo:          ${TRITON_REPO}"
log_info "  LLVM build:           ${LLVM_BUILD_DIR}"
log_info "  TRITON_HIP_LLD_PATH: ${TRITON_HIP_LLD_PATH}"
log_info "  Python venv:          ${TRITON_REPO}/.venv"
log_info ""
log_info "For Omniprobe CMake:"
log_info "  -DTRITON_LLVM=${LLVM_BUILD_DIR}"
