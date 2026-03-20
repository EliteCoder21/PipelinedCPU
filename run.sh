#!/bin/bash
# CSE 469 Docker Run Script
# Usage: ./run.sh [workspace_path]
#
# If no path specified, mounts current directory as workspace.

set -e

# Default to current directory
WORKSPACE_PATH="${1:-.}"

# Image name - change this after publishing to Docker Hub
IMAGE_NAME="therapy9903/cse469-tools:latest"
# IMAGE_NAME="YOUR_DOCKERHUB_USERNAME/cse469-tools:latest"

echo "========================================"
echo "CSE 469 Development Environment"
echo "========================================"
echo "Workspace: $(realpath "$WORKSPACE_PATH")"
echo ""
echo "Your files are mounted at: /home/student/workspace"
echo "Type 'exit' to leave the container"
echo ""

export MSYS_NO_PATHCONV=1

# Run the container
docker run -it --rm \
    -v "$(realpath "$WORKSPACE_PATH")":/home/student/workspace \
    -w /home/student/workspace \
    "$IMAGE_NAME"