#!/usr/bin/env bash
# Apply the version-controlled qBittorrent settings and restart only when changed.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE="$REPO_DIR/configs/qbittorrent/qBittorrent.conf"
TARGET="/srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf"

if sudo cmp -s "$SOURCE" "$TARGET"; then
    exit 0
fi

sudo install -D -m 0644 -o 1000 -g 1000 "$SOURCE" "$TARGET"
sudo docker restart qbittorrent >/dev/null
echo "qBittorrent configuration applied and container restarted"
