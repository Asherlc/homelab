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

# Decrypt SOPS files for use by containers
if [ -x "$REPO_DIR/scripts/sops-decrypt.sh" ]; then
    export SOPS_AGE_KEY_FILE=/home/asherlc/.sops/key.txt
    if "$REPO_DIR/scripts/sops-decrypt.sh"; then
        log "SOPS secrets decrypted"
    else
        log "WARNING: SOPS decryption failed"
    fi
fi

# Ensure DNS stays resilient across reboots (Pi-hole + public fallbacks)
if [ -x "$REPO_DIR/scripts/configure-dns.sh" ]; then
    if "$REPO_DIR/scripts/configure-dns.sh"; then
        log "DNS configuration applied"
    else
        log "WARNING: DNS configuration failed"
    fi
fi

# Always run docker compose up -d (idempotent — only recreates changed services)
sudo docker compose -f "$REPO_DIR/$COMPOSE_FILE" up -d
log "Docker compose up complete"

# Enforce Tdarr configuration as code (idempotent, safe to run every deploy)
if [ -x "$REPO_DIR/scripts/tdarr-apply-config.sh" ]; then
    if "$REPO_DIR/scripts/tdarr-apply-config.sh"; then
        log "Tdarr IaC config applied"
    else
        log "WARNING: Tdarr IaC config apply failed"
    fi
fi

# Restart traefik if its config changed
if echo "$CHANGED_FILES" | grep -q "configs/traefik/"; then
    sudo docker restart traefik
    log "Traefik restarted due to config change"
fi

log "Deploy complete"
