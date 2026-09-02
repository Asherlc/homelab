#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

assert_contains() {
    local file=$1
    local expected=$2

    if ! grep -Fqx -- "$expected" "$repo_dir/$file"; then
        echo "FAIL: $file must contain: $expected" >&2
        failures=$((failures + 1))
    fi
}

assert_not_contains() {
    local file=$1
    local unexpected=$2

    if grep -Fq -- "$unexpected" "$repo_dir/$file"; then
        echo "FAIL: $file must not contain: $unexpected" >&2
        failures=$((failures + 1))
    fi
}

assert_text_contains() {
    local file=$1
    local expected=$2

    if ! grep -Fq -- "$expected" "$repo_dir/$file"; then
        echo "FAIL: $file must contain: $expected" >&2
        failures=$((failures + 1))
    fi
}

assert_file() {
    local file=$1

    if [[ ! -f "$repo_dir/$file" ]]; then
        echo "FAIL: missing $file" >&2
        failures=$((failures + 1))
    fi
}

assert_contains "configs/qbittorrent/qBittorrent.conf" 'Session\ShareLimitAction=RemoveWithContent'
assert_not_contains "scripts/audit-downloads.sh" ' | bc'
assert_file "scripts/qbittorrent-apply-config.sh"
assert_file "scripts/storage-maintenance.sh"
assert_file "systemd/homelab-storage-maintenance.service"
assert_file "systemd/homelab-storage-maintenance.timer"
assert_text_contains "scripts/auto-deploy.sh" '"$REPO_DIR/scripts/qbittorrent-apply-config.sh"'
assert_text_contains "scripts/auto-deploy.sh" 'homelab-storage-maintenance.timer'

if (( failures > 0 )); then
    exit 1
fi

echo "storage-maintenance tests passed"
