#!/usr/bin/env bash
# Remove completed torrents and their payloads after qBittorrent stops them for inactivity.
set -euo pipefail

QBITTORRENT_CONTAINER="${QBITTORRENT_CONTAINER:-qbittorrent}"
INACTIVE_SECONDS=$((7 * 24 * 60 * 60))
CUTOFF=$(( $(date +%s) - INACTIVE_SECONDS ))

completed=$(sudo docker exec "$QBITTORRENT_CONTAINER" \
    curl -fsS 'http://localhost:8080/api/v2/torrents/info?filter=completed')

mapfile -t hashes < <(
    jq -r --argjson cutoff "$CUTOFF" '
        .[]
        | select(.state == "pausedUP")
        | select(.last_activity > 0 and .last_activity <= $cutoff)
        | .hash
    ' <<<"$completed"
)

if (( ${#hashes[@]} == 0 )); then
    logger -t homelab-qbittorrent-cleanup "No inactive completed torrents eligible for removal"
    exit 0
fi

for hash in "${hashes[@]}"; do
    sudo docker exec "$QBITTORRENT_CONTAINER" \
        curl -fsS -X POST \
        --data-urlencode "hashes=$hash" \
        --data 'deleteFiles=true' \
        'http://localhost:8080/api/v2/torrents/delete' >/dev/null
done

logger -t homelab-qbittorrent-cleanup "Removed ${#hashes[@]} inactive completed torrent payload(s)"
echo "Removed ${#hashes[@]} inactive completed torrent payload(s)"
