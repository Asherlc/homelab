#!/bin/bash
# Auto-commit and push changes
set -e

REPO_DIR="/opt/homelab-config"
cd "$REPO_DIR"

# Check if there are changes
if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to commit"
    exit 0
fi

# Unlock git-crypt if needed
if [ -f ~/.homelab-secure/homelab-git-crypt.key ]; then
    git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key 2>/dev/null || true
fi

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
