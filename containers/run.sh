#!/bin/bash

# Script to run the hiptimize container with project mounted
# Supports both Docker and Apptainer with automatic building

# Container name
name="omniprobe"

# Script directories
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parent_dir="$(dirname "$script_dir")"

# Parse arguments
use_docker=false
use_apptainer=false
rocm_version="6.3"  # Default ROCm version

while [[ $# -gt 0 ]]; do
  case $1 in
    --docker)
      use_docker=true
      shift
      ;;
    --apptainer)
      use_apptainer=true
      shift
      ;;
    --rocm)
      rocm_version="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION] -- Exactly one option is required."
      exit 1
      ;;
  esac
done

# Validate arguments
if [ "$use_docker" = true ] && [ "$use_apptainer" = true ]; then
    echo "Error: Cannot use both --docker and --apptainer simultaneously."
    echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION]"
    exit 1
elif [ "$use_docker" = false ] && [ "$use_apptainer" = false ]; then
    echo "Error: Must specify either --docker or --apptainer."
    echo "Usage: $0 [--docker] [--apptainer] [--rocm VERSION]"
    echo "  --docker      Run using Docker container"
    echo "  --apptainer   Run using Apptainer container"
    echo "  --rocm        ROCm version (default: 6.3)"
    exit 1
fi

echo "Starting omniprobe container with ROCm $rocm_version..."
echo "Project directory will be mounted at /workspace"
echo "Any files you create/modify will persist after the container closes."
echo ""

if [ "$use_docker" = true ]; then
    echo "Using Docker containerization..."
    
    # Check if the Docker image exists
    if ! docker image inspect "$name:$(cat "$parent_dir/VERSION")-rocm$rocm_version" > /dev/null 2>&1; then
        echo "Docker image $name:$(cat "$parent_dir/VERSION")-rocm$rocm_version not found."
        echo "Building Docker image..."
        echo ""
        
        if ! "$script_dir/build.sh" --docker --rocm "$rocm_version"; then
            echo "Error: Failed to build Docker image."
            exit 1
        fi
        
        echo ""
        echo "Docker image built successfully!"
    else
        echo "Docker image found."
    fi
    
    # Run the Docker container
    echo "Running Docker container with project directory mounted..."
    docker run -it --rm \
        --device=/dev/kfd \
        --device=/dev/dri \
        --group-add video \
        --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        -v "$parent_dir:/workspace" \
        -w /workspace \
        "$name:$(cat "$parent_dir/VERSION")-rocm$rocm_version"

elif [ "$use_apptainer" = true ]; then
    echo "Using Apptainer containerization..."
    
    # Check if apptainer is installed
    if ! command -v apptainer &> /dev/null; then
        echo "Error: Apptainer is not installed or not in PATH"
        echo "Please install Apptainer first: https://apptainer.org/docs/admin/main/installation.html"
        exit 1
    fi
    
    # Apptainer image filename
    apptainer_image="$script_dir/${name}_$(cat "$parent_dir/VERSION")-rocm${rocm_version}.sif"
    
    # Check if the Apptainer image exists
    if [ ! -f "$apptainer_image" ]; then
        echo "Apptainer image $apptainer_image not found."
        echo "Building Apptainer image automatically..."
        echo ""
        
        if ! "$script_dir/build.sh" --apptainer --rocm "$rocm_version"; then
            echo "Error: Failed to build Apptainer image."
            exit 1
        fi
        
        echo ""
        echo "Apptainer image built successfully!"
    else
        echo "Apptainer image found."
    fi
    
    # Run the Apptainer container
    echo "Running Apptainer container with project directory mounted..."
    cd "$parent_dir"
    apptainer exec \
        --cleanenv \
        --bind "$parent_dir:/workspace" \
        --pwd /workspace \
        "$apptainer_image" \
        /bin/bash \
        --rcfile /etc/bashrc
fi

echo "Container session ended." 