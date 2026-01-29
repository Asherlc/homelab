#!/bin/bash
# Auto-commit and push changes (with SOPS encryption)
set -e

REPO_DIR="/opt/homelab-config"
cd "$REPO_DIR"

# Check if there are changes
if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to commit"
    exit 0
fi

# Set SOPS key
export SOPS_AGE_KEY_FILE=~/.sops/key.txt

# Encrypt SOPS-managed files before committing
echo "Encrypting SOPS files..."
./scripts/sops-encrypt.sh

# Stage and commit
git add -A
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
git commit -m "Auto-sync: $TIMESTAMP from $(hostname)" || exit 0

# Push
git push origin main || {
    echo "WARNING: Push failed" >&2
    exit 1
}

echo "✓ Changes committed and pushed successfully"
