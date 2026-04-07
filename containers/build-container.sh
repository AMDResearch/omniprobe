#!/bin/bash
set -euo pipefail

# Build Omniprobe container images (Docker or Apptainer).
#
# Two-stage build:
#   1. Toolchain image: ROCm + LLVM + Triton (expensive, rarely rebuilt)
#   2. Omniprobe image: project code + build (cheap, rebuilt on code changes)

# Script directories
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parent_dir="$(dirname "$script_dir")"

# Parse arguments
build_docker=false
build_apptainer=false
rocm_version="7.2"

# Supported ROCm versions
supported_rocm_versions=("7.0" "7.1" "7.2")

while [[ $# -gt 0 ]]; do
  case $1 in
    --apptainer)
      build_apptainer=true
      shift
      ;;
    --docker)
      build_docker=true
      shift
      ;;
    --rocm)
      rocm_version="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION]"
      exit 1
      ;;
  esac
done

# Validate ROCm version
if [[ ! " ${supported_rocm_versions[@]} " =~ " ${rocm_version} " ]]; then
    echo "Error: Unsupported ROCm version '$rocm_version'"
    echo "Supported ROCm versions: ${supported_rocm_versions[*]}"
    exit 1
fi

if [ "$build_docker" = false ] && [ "$build_apptainer" = false ]; then
    echo "Error: At least one of the options --docker or --apptainer is required."
    echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION]"
    echo "  --docker      Build Docker container"
    echo "  --apptainer   Build Apptainer container"
    echo "  --rocm        ROCm version (default: 7.2, supported: ${supported_rocm_versions[*]})"
    exit 1
fi

version="$(cat "$parent_dir/VERSION")"

pushd "$parent_dir"

if [ "$build_docker" = true ]; then
    echo "Building Docker container with ROCm $rocm_version..."
    git submodule update --init --recursive "$parent_dir"

    export DOCKER_BUILDKIT=1
    docker build \
        --load \
        --build-arg ROCM_VERSION="$rocm_version" \
        -t "omniprobe:${version}-rocm${rocm_version}" \
        -f "$script_dir/omniprobe.Dockerfile" \
        .

    echo "Docker build complete!"
fi

if [ "$build_apptainer" = true ]; then
    echo "Building Apptainer container with ROCm $rocm_version..."
    git submodule update --init --recursive "$parent_dir"

    if ! command -v apptainer &> /dev/null; then
        echo "Error: Apptainer is not installed or not in PATH"
        echo "Please install Apptainer first: https://apptainer.org/docs/admin/main/installation.html"
        exit 1
    fi

    toolchain_sif="${script_dir}/toolchain_${version}-rocm${rocm_version}.sif"
    omniprobe_sif="${script_dir}/omniprobe_${version}-rocm${rocm_version}.sif"

    # Stage 1: Build toolchain SIF if it doesn't exist
    if [ ! -f "$toolchain_sif" ]; then
        echo "Toolchain SIF not found at $toolchain_sif"
        echo "Building toolchain (this is expensive — LLVM + Triton)..."
        apptainer build \
            --build-arg ROCM_VERSION="$rocm_version" \
            "$toolchain_sif" "$script_dir/toolchain.def"
        echo "Toolchain build complete!"
    else
        echo "Reusing existing toolchain SIF: $toolchain_sif"
    fi

    # Stage 2: Build omniprobe SIF from toolchain
    echo "Building omniprobe SIF..."
    apptainer build \
        --build-arg TOOLCHAIN_SIF="$toolchain_sif" \
        --build-arg HIP_ARCHITECTURES=gfx90a \
        "$omniprobe_sif" "$script_dir/omniprobe.def"

    echo "Apptainer build complete!"
    echo "  Toolchain: $toolchain_sif"
    echo "  Omniprobe: $omniprobe_sif"
fi

popd
