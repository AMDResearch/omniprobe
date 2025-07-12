#!/bin/bash

# Container name
name="omniprobe"

# Script directories
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parent_dir="$(dirname "$script_dir")"
cur_dir=$(pwd)

# Parse arguments
build_docker=false
build_apptainer=false
rocm_version="6.3"  # Default ROCm version

# Supported ROCm versions
supported_rocm_versions=("6.3" "6.4")

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
      echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION] -- Choose containerization type and ROCm version."
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
    echo "  --rocm        ROCm version (default: 6.3, supported: ${supported_rocm_versions[*]})"
    exit 1
fi

pushd "$parent_dir"

if [ "$build_docker" = true ]; then
    echo "Building Docker container with ROCm $rocm_version..."
    git submodule update --init --recursive $parent_dir

    # Enable BuildKit and build the Docker image
    export DOCKER_BUILDKIT=1
    docker build \
        --build-arg ROCM_VERSION="$rocm_version" \
        -t "$name:$(cat "$parent_dir/VERSION")-rocm$rocm_version" \
        -f "$script_dir/omniprobe.Dockerfile" \
        .

    echo "Docker build complete!"
fi

if [ "$build_apptainer" = true ]; then
    echo "Building Apptainer container with ROCm $rocm_version..."
    git submodule update --init --recursive $parent_dir

    # Check if apptainer is installed
    if ! command -v apptainer &> /dev/null; then
        echo "Error: Apptainer is not installed or not in PATH"
        echo "Please install Apptainer first: https://apptainer.org/docs/admin/main/installation.html"
        exit 1
    fi

    # Build the Apptainer container with ROCm version
    apptainer build \
      --build-arg ROCM_VERSION="$rocm_version" \
      "${script_dir}/${name}_$(cat "$parent_dir/VERSION")-rocm${rocm_version}.sif" "$script_dir/omniprobe.def"

    echo "Apptainer build complete!"
fi
  
popd