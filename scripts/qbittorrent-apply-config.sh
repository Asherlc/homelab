#!/usr/bin/env bash
# Apply the version-controlled qBittorrent settings and restart only when changed.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE="$REPO_DIR/configs/qbittorrent/qBittorrent.conf"
TARGET="/srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf"

if ! sudo cmp -s "$SOURCE" "$TARGET"; then
    sudo docker stop qbittorrent >/dev/null
    sudo install -D -m 0644 -o 1000 -g 1000 "$SOURCE" "$TARGET"
    sudo docker start qbittorrent >/dev/null
    echo "qBittorrent configuration applied and container restarted"
fi

for attempt in {1..15}; do
    if preferences=$(sudo docker exec qbittorrent \
        curl -fsS 'http://localhost:8080/api/v2/app/preferences' 2>/dev/null); then
        break
    fi
    sleep 2
done

if [[ -z "${preferences:-}" ]]; then
    echo "qBittorrent Web API did not become ready" >&2
    exit 1
fi

if ! jq -e '.excluded_file_names_enabled and
    (.excluded_file_names | split("\n") | index("*.exe") != null)' \
    <<<"$preferences" >/dev/null; then
    echo "qBittorrent executable exclusions are not active" >&2
    exit 1
fi

if jq -e '.max_ratio_act == 0' <<<"$preferences" >/dev/null; then
    exit 0
fi

sudo docker exec qbittorrent \
    curl -fsS -X POST \
    --data-urlencode 'json={"max_ratio_act":0}' \
    'http://localhost:8080/api/v2/app/setPreferences' >/dev/null
echo "qBittorrent share-limit action set to Stop"
