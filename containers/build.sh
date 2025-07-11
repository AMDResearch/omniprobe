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
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--docker] [--apptainer] -- At least one option is required."
      exit 1
      ;;
  esac
done

if [ "$build_docker" = false ] && [ "$build_apptainer" = false ]; then
    echo "Error: At least one of the options --docker or --apptainer is required."
    echo "Usage: $0 [--docker] [--apptainer]"
    exit 1
fi

pushd "$parent_dir"

if [ "$build_docker" = true ]; then
    echo "Building Docker container..."
    git submodule update --init --recursive $parent_dir

    # Enable BuildKit and build the Docker image
    export DOCKER_BUILDKIT=1
    docker build \
        -t "$name:$(cat "$parent_dir/VERSION")" \
        -f "$script_dir/omniprobe.Dockerfile" \
        .

    echo "Docker build complete!"
fi

if [ "$build_apptainer" = true ]; then
    echo "Building Apptainer container..."

    # Check if apptainer is installed
    if ! command -v apptainer &> /dev/null; then
        echo "Error: Apptainer is not installed or not in PATH"
        echo "Please install Apptainer first: https://apptainer.org/docs/admin/main/installation.html"
        exit 1
    fi

    # Build the Apptainer container
    apptainer build \
      "${name}_$(cat "$parent_dir/VERSION").sif" "$script_dir/omniprobe.def"

    echo "Apptainer build complete!"
fi
  
popd