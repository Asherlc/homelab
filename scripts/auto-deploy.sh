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

if [ "$LOCAL" != "$REMOTE" ]; then
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

    # Prepare service-owned persistent directories before Compose creates bind mounts.
    if [ -x "$REPO_DIR/scripts/maintainerr-prepare.sh" ]; then
        "$REPO_DIR/scripts/maintainerr-prepare.sh"
    fi

    # Always run docker compose up -d after a configuration change.
    sudo docker compose -f "$REPO_DIR/$COMPOSE_FILE" up -d
    log "Docker compose up complete"

    # Enforce Tdarr configuration as code after a configuration change.
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
fi

# Apply qBittorrent settings from the repository after containers are available.
if [ -x "$REPO_DIR/scripts/qbittorrent-apply-config.sh" ]; then
    if "$REPO_DIR/scripts/qbittorrent-apply-config.sh"; then
        log "qBittorrent configuration applied"
    else
        log "WARNING: qBittorrent configuration apply failed"
    fi
fi

# Keep the weekly storage-report timer managed as infrastructure code.
sudo python3 "$REPO_DIR/scripts/download-safety-apply.py"

for unit in \
    homelab-storage-maintenance.service \
    homelab-storage-maintenance.timer \
    homelab-qbittorrent-cleanup.service \
    homelab-qbittorrent-cleanup.timer; do
    sudo install -m 0644 "$REPO_DIR/systemd/$unit" "/etc/systemd/system/$unit"
done
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-storage-maintenance.timer homelab-qbittorrent-cleanup.timer
log "Storage maintenance and qBittorrent cleanup timers enabled"

log "Deploy complete"
