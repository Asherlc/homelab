#!/bin/bash
# Auto-deploy: polls git for changes, pulls and runs docker compose up -d
set -e

REPO_DIR="/opt/homelab-config"
COMPOSE_FILE="docker/compose.yml"
LOG_TAG="auto-deploy"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cd "$REPO_DIR"

# Fetch latest from remote
git fetch origin main --quiet

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
    exit 0
fi

log "Changes detected: $LOCAL -> $REMOTE"

# Record what changed before pulling
CHANGED_FILES=$(git diff --name-only "$LOCAL" "$REMOTE")
log "Changed files: $CHANGED_FILES"

# Pull changes
git pull origin main --quiet
log "Pulled latest changes"

# Always run docker compose up -d (idempotent — only recreates changed services)
sudo docker compose -f "$REPO_DIR/$COMPOSE_FILE" up -d
log "Docker compose up complete"

# Restart traefik if its config changed
if echo "$CHANGED_FILES" | grep -q "configs/traefik/"; then
    sudo docker restart traefik
    log "Traefik restarted due to config change"
fi

log "Deploy complete"
