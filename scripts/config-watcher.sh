#!/bin/bash
#
# Config File Watcher - Auto-sync changes to git
# Watches service config files and syncs to /opt/homelab-config when changed
#

set -e

REPO_DIR="/opt/homelab-config"
LOG_FILE="/var/log/config-watcher.log"
DEBOUNCE_TIME=30  # Wait 30 seconds after last change before syncing

# Files to watch (source -> destination in repo)
declare -A WATCH_PATHS=(
    ["/srv/appdata/overseerr/settings.json"]="configs/overseerr/settings.json"
    ["/srv/appdata/bazarr/config/config.yaml"]="configs/bazarr/config.yaml"
    ["/srv/appdata/homarr/configs/default.json"]="configs/homarr/default.json"
    ["/srv/appdata/configarr/config/config.yml"]="configarr/config.yml"
    ["/srv/appdata/configarr/config/secrets.yml"]="configarr/secrets.yml"
    ["/srv/appdata/traefik/traefik.yml"]="configs/traefik/traefik.yml"
    ["/srv/appdata/traefik/dynamic.yml"]="configs/traefik/dynamic.yml"
    ["/srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf"]="configs/qbittorrent/qBittorrent.conf"
    ["/srv/appdata/qbittorrent/qBittorrent/categories.json"]="configs/qbittorrent/categories.json"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

sync_config() {
    local source="$1"
    local dest="$2"

    if [ ! -f "$source" ]; then
        log "WARNING: Source file not found: $source"
        return
    fi

    log "Syncing: $source -> $dest"

    # Copy file to repo
    mkdir -p "$REPO_DIR/$(dirname "$dest")"
    cp "$source" "$REPO_DIR/$dest"

    # Change ownership to asherlc user
    chown -R asherlc:asherlc "$REPO_DIR/$(dirname "$dest")"
}

sync_all_and_commit() {
    log "=========================================="
    log "Config change detected, syncing to git..."

    # Sync all watched files
    for source in "${!WATCH_PATHS[@]}"; do
        sync_config "$source" "${WATCH_PATHS[$source]}"
    done

    # Commit and push
    cd "$REPO_DIR"

    # Check if there are changes (as asherlc user)
    if ! sudo -u asherlc git -c safe.directory="$REPO_DIR" status --porcelain | grep -q .; then
        log "No changes to commit"
        return
    fi

    log "Changes detected, committing..."

    # Run as asherlc user with SOPS key and safe.directory override
    sudo -u asherlc bash << 'EOF'
export SOPS_AGE_KEY_FILE=~/.sops/key.txt
cd /opt/homelab-config

# Use git -c to bypass safe.directory check
git -c safe.directory=/opt/homelab-config add -A

# Encrypt SOPS files
./scripts/sops-encrypt.sh

# Commit
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
git -c safe.directory=/opt/homelab-config commit -m "Auto-sync: $TIMESTAMP from $(hostname)" || exit 0

# Push
git -c safe.directory=/opt/homelab-config push origin main || {
    echo "WARNING: Push failed"
    exit 1
}

echo "✓ Changes committed and pushed successfully"
EOF

    log "Sync complete!"
    log "=========================================="
}

# Build inotifywait paths
WATCH_DIRS=""
for path in "${!WATCH_PATHS[@]}"; do
    WATCH_DIRS="$WATCH_DIRS $path"
done

log "Config watcher started"
log "Watching: ${!WATCH_PATHS[@]}"
log "Debounce time: ${DEBOUNCE_TIME}s"

# Main watch loop with debouncing
while true; do
    # Wait for a change
    inotifywait -q -e modify,close_write $WATCH_DIRS 2>&1 | while read path action file; do
        log "Change detected: $path$file ($action)"

        # Start debounce timer
        sleep "$DEBOUNCE_TIME" &
        TIMER_PID=$!

        # Keep resetting timer if more changes come in
        while inotifywait -q -t "$DEBOUNCE_TIME" -e modify,close_write $WATCH_DIRS >/dev/null 2>&1; do
            log "Additional changes detected, extending debounce..."
            kill $TIMER_PID 2>/dev/null || true
            sleep "$DEBOUNCE_TIME" &
            TIMER_PID=$!
        done

        # Timer expired, sync now
        wait $TIMER_PID 2>/dev/null || true
        sync_all_and_commit
    done

    # If inotifywait exits, restart after a delay
    log "WARNING: inotifywait exited, restarting in 5 seconds..."
    sleep 5
done
