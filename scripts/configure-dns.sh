#!/bin/bash
# Configure resilient DNS on the homelab server.
# Tailscale MagicDNS forwards to Pi-hole; when Pi-hole is down, public fallbacks keep services working.
set -euo pipefail

LOG_TAG="configure-dns"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

IFACE="${HOMELAB_DNS_IFACE:-enp1s0}"
PRIMARY_DNS="${HOMELAB_PRIMARY_DNS:-1.1.1.1}"
SECONDARY_DNS="${HOMELAB_SECONDARY_DNS:-8.8.8.8}"
PIHOLE_DNS="${HOMELAB_PIHOLE_DNS:-192.168.1.218}"

CONN=$(nmcli -t -f NAME,DEVICE con show --active | grep "$IFACE" | cut -d: -f1 | head -1)
if [ -z "$CONN" ]; then
    log "ERROR: No active NetworkManager connection found for $IFACE"
    exit 1
fi

log "Configuring DNS on connection '$CONN' ($IFACE)"
sudo nmcli con mod "$CONN" ipv4.dns "$PRIMARY_DNS $SECONDARY_DNS $PIHOLE_DNS"
sudo nmcli con mod "$CONN" ipv4.ignore-auto-dns yes
sudo nmcli con up "$CONN"

# Prevent Tailscale from overwriting resolv.conf with broken MagicDNS when Pi-hole is unavailable.
if command -v tailscale >/dev/null 2>&1; then
    sudo tailscale set --accept-dns=false
    log "Disabled Tailscale DNS override"
fi

log "DNS configured: $(tr '\n' ' ' </etc/resolv.conf | sed 's/#.*//g')"
