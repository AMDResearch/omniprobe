#!/bin/bash

# Usage: ./start_gpu_container.sh -n <container-name> -i <image-name> -m <mount-path>
# Example: ./start_gpu_container.sh -n my-container -i my-image -m /path/to/mount

function show_help() {
  echo "Usage: $0 -n <container-name> -i <image-name> -m <mount-path>"
  echo
  echo "Options:"
  echo "  -n    Name of the container"
  echo "  -i    Name of the Docker image"
  echo "  -m    Path to mount as the working directory"
  echo "  -h    Show this help message"
}

# Default values
CONTAINER_NAME=""
IMAGE_NAME=""
WORKDIR=""

# Parse arguments
while getopts "n:i:m:h" opt; do
  case $opt in
    n) CONTAINER_NAME="$OPTARG" ;;
    i) IMAGE_NAME="$OPTARG" ;;
    m) WORKDIR="$OPTARG" ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# Validate arguments
if [[ -z "$CONTAINER_NAME" || -z "$IMAGE_NAME" || -z "$WORKDIR" ]]; then
  echo "Error: Missing required arguments."
  show_help
  exit 1
fi

# Run the Docker container
docker run -d --rm \
  --name "$CONTAINER_NAME" \
  --user "$(id -u):$(id -g)" \
  --network=host \
  --device=/dev/kfd \
  --device=/dev/dri/renderD128 \
  --group-add video \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -v "$WORKDIR":/workspace \
  -w /workspace \
  "$IMAGE_NAME" tail -f /dev/null