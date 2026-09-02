#!/usr/bin/env bash
# Produce a weekly storage report without mutating NAS content.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STORAGE_ROOT="/mnt/storage"
REPORT_DIR="$STORAGE_ROOT/backups/homelab/reports"
TIMESTAMP=$(date '+%Y-%m-%d-%H%M%S')
LATEST_REPORT="$REPORT_DIR/latest-storage-report.txt"
ARCHIVE_REPORT="$REPORT_DIR/storage-report-$TIMESTAMP.txt"
TEMP_REPORT=$(mktemp)

cleanup() {
    rm -f "$TEMP_REPORT"
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"

{
    echo "Homelab storage report: $(date --iso-8601=seconds)"
    echo
    echo "=== Capacity ==="
    df -h "$STORAGE_ROOT"
    echo
    echo "=== Primary consumers ==="
    for path in media downloads frigate backups transcode tmp; do
        if [[ -e "$STORAGE_ROOT/$path" ]]; then
            du -sh "$STORAGE_ROOT/$path"
        fi
    done | sort -h
    echo
    echo "=== Completed-download audit ==="
    "$REPO_DIR/scripts/audit-downloads.sh" --local
} >"$TEMP_REPORT"

install -m 0644 "$TEMP_REPORT" "$LATEST_REPORT"
install -m 0644 "$TEMP_REPORT" "$ARCHIVE_REPORT"

summary=$(df -h "$STORAGE_ROOT" | awk 'NR == 2 { print $3 " used of " $2 " (" $5 ")" }')
logger -t homelab-storage-maintenance "Weekly report written to $LATEST_REPORT; $summary"
echo "Weekly storage report written to $LATEST_REPORT; $summary"
