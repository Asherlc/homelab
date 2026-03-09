#!/bin/bash
# Build OpenWearables Docker images from source
# Run this once for initial setup, and again to pick up upstream updates
set -e

REPO_URL="https://github.com/the-momentum/open-wearables.git"
BUILD_DIR="/tmp/open-wearables-build"
VITE_API_URL="${VITE_API_URL:-https://openwearables-api.asherlc.com}"

echo "==> Cloning/updating OpenWearables source..."
if [ -d "$BUILD_DIR" ]; then
    cd "$BUILD_DIR" && git pull
else
    git clone "$REPO_URL" "$BUILD_DIR"
    cd "$BUILD_DIR"
fi

echo "==> Building backend image..."
docker build -t openwearables-backend:latest -f backend/Dockerfile backend/

echo "==> Building frontend image (VITE_API_URL=$VITE_API_URL)..."
docker build -t openwearables-frontend:latest \
    --build-arg VITE_API_URL="$VITE_API_URL" \
    -f frontend/Dockerfile frontend/

echo "==> Done. Images built:"
docker images | grep openwearables

echo ""
echo "Now run: cd /opt/homelab-config/docker && docker compose up -d"
