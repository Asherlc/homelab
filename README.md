# Homelab Configuration

Version-controlled infrastructure configuration with encrypted secrets.

## 🔐 Security

This repository uses **SOPS** (Secrets OPerational Support) to encrypt sensitive keys and credentials.
Previously, **git-crypt** was used, but it is now deprecated in favor of SOPS for better granular control.

Encrypted files are safe to store on GitHub!

## 📚 Documentation

- [Backup & Recovery Guide](docs/BACKUP_README.md)
- [Quick Reference](docs/QUICK_REFERENCE.md)
- [SOPS Encryption Guide](docs/SOPS_GUIDE.md)

## 🚀 Quick Start

### Clone on New Machine

```bash
git clone git@github.com:Asherlc/homelab.git /opt/homelab-config
cd /opt/homelab-config
git-crypt unlock ~/.homelab-secure/homelab-git-crypt.key
```

### Auto-Deploy (one-time setup)

A systemd timer polls GitHub every 2 minutes and automatically pulls changes and runs `docker compose up -d`. To enable it:

```bash
cd /opt/homelab-config && git pull
sudo cp systemd/homelab-deploy.service /etc/systemd/system/
sudo cp systemd/homelab-deploy.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-deploy.timer
```

Once enabled, the workflow is: **edit locally → commit → push → done**. Changes deploy within ~2 minutes.

Check deploy logs: `journalctl -t auto-deploy`

### Local Network Access

When on the home network, SSH directly to the server at `192.168.1.197`. SSH keys are managed via 1Password — make sure the 1Password SSH agent is available:

```bash
# Set the 1Password SSH agent socket
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

# SSH to server
ssh asherlc@192.168.1.197
```

Services are accessible locally via `<service>.home` through Traefik (no auth required).

### Remote Access via Tailscale

When off the home network, use Tailscale to reach the server. The server's Tailscale IP is `100.96.33.27`.

```bash
# SSH to server
ssh asherlc@100.96.33.27

# Check Tailscale status and find peers
tailscale status
```

| Device | Tailscale IP |
|--------|-------------|
| Homelab server | `100.96.33.27` |

Services are also accessible externally via `*.asherlc.com` (Cloudflare Tunnel), which does not require Tailscale.

### Manual Sync

```bash
cd /opt/homelab-config
./scripts/auto-commit-push.sh
```

## 📂 Repository Structure

```
├── docker/              # Docker Compose files
├── configarr/           # Configarr IaC configs (secrets encrypted)
├── configs/tdarr/       # Tdarr desired state (flow, worker limits, server settings)
├── scripts/             # Automation scripts
├── docs/                # Documentation
└── configs/             # Service configurations
```

## Tdarr (Remote Node Architecture)

Tdarr Server runs on the homelab (orchestration only, no internal node) while the actual transcoding runs on a native Tdarr Node on the laptop. This avoids saturating the server's 4 cores / 8GB RAM and gives the node direct access to macOS VideoToolbox for hardware-accelerated HEVC encoding.

- Desired state file: `configs/tdarr/state.json`
- Apply script: `scripts/tdarr-apply-config.sh`

The auto-deploy timer runs the apply script after each pull, so manual UI changes are automatically corrected on the next deploy.

### Laptop Node Setup

The node runs **natively on macOS** (not in Docker) so it can use the Apple Silicon VideoToolbox hardware encoder. It is installed at `~/tdarr/` and managed by a launchd agent (`~/Library/LaunchAgents/com.tdarr.node.plist`) that starts it on login and keeps it alive.

The node operates in **mapped mode** with the NAS media share mounted via SMB. A launchd agent (`~/Library/LaunchAgents/com.homelab.smb-mount.plist`) runs `~/bin/mount-homelab-media.sh` every 60 seconds, which fetches the NAS password from 1Password (`op item get "Synology NAS"`) and mounts `//asherlc@192.168.1.161/data` at `~/mnt/homelab-media`. The agent acts as a watchdog — it detects stale mounts (failed `ls` on the media dir) and remounts automatically. Path translators in the node config map the server's `/media` and `/temp` paths to the local SMB mount.

SMB was chosen over SSHFS because SSHFS is ~3-5x slower for file reads and silently stales out on network hiccups. SMB natively reconnects and delivers 60-300 fps transcode throughput vs 12-35 fps on SSHFS.

Config file: `~/tdarr/configs/Tdarr_Node_Config.json`

Key settings:
- `nodeName`: `LaptopNode`
- `serverIP`: `192.168.1.197` (LAN) or `100.96.33.27` (Tailscale)
- `nodeType`: `mapped`
- Workers: 3 GPU transcode (VideoToolbox), 2 CPU health check

Transcoding only happens when the laptop is running and connected. The server handles disconnections gracefully.

#### Managing the node

```bash
# Check status
launchctl list | grep tdarr

# Stop
launchctl unload ~/Library/LaunchAgents/com.tdarr.node.plist

# Start
launchctl load ~/Library/LaunchAgents/com.tdarr.node.plist

# View logs
tail -f ~/tdarr/logs/Tdarr_Node_Log.txt
```

#### Reinstalling / updating

The Tdarr Node auto-updates to match the server version on startup. To do a fresh install:

```bash
launchctl unload ~/Library/LaunchAgents/com.tdarr.node.plist
rm -rf ~/tdarr
curl -L -o /tmp/Tdarr_Updater.zip https://storage.tdarr.io/versions/2.17.01/darwin_arm64/Tdarr_Updater.zip
mkdir -p ~/tdarr && cd ~/tdarr && unzip /tmp/Tdarr_Updater.zip && chmod +x Tdarr_Updater && ./Tdarr_Updater
# Edit ~/tdarr/configs/Tdarr_Node_Config.json (set serverIP, nodeName, nodeType=mapped, pathTranslators)
launchctl load ~/Library/LaunchAgents/com.tdarr.node.plist
```

#### Checking transcode status

The Tdarr web UI is at `http://192.168.1.197:8265` (or `tdarr.asherlc.com` externally).

From the CLI, query the server API:

```bash
# Overall statistics (files processed, space saved, queue sizes)
curl -s -X POST http://192.168.1.197:8266/api/v2/cruddb \
  -H 'Content-Type: application/json' \
  -d '{"data":{"collection":"StatisticsJSONDB","mode":"getAll"}}' | jq '.[0] | {
    totalFiles: .totalFileCount,
    transcoded: .totalTranscodeCount,
    spaceSavedGB: (.sizeDiff | round),
    transcodeQueue: .table2Count,
    healthCheckQueue: .table3Count,
    transcodeErrors: .table1Count
  }'

# Node status (connected, worker limits, active workers)
curl -s http://192.168.1.197:8266/api/v2/get-nodes | jq '.[] | {
    name: .nodeName,
    type: .config.nodeType,
    platform: .config.platform_arch_isdocker,
    workerLimits: .workerLimits,
    activeWorkers: (.workers | length),
    queue: .queueLengths,
    paused: .nodePaused
  }'
```

## 🔑 Encryption Key

**Location:** `~/.homelab-secure/homelab-git-crypt.key`

**⚠️ BACKUP THIS KEY!** Without it, encrypted files cannot be decrypted.

---

**Managed with git-crypt** - See `docs/GIT_CRYPT_GUIDE.md` for details.

## ⚠️ Services Not Version Controlled

Some services use formats incompatible with SOPS or are better managed through other means:

- **Prowlarr**: Managed via Configarr IaC + database backups (XML format not SOPS-compatible)
- **Overseerr users/permissions**: Stored in SQLite database, backed up to NAS

See [Backup & Recovery Guide](docs/BACKUP_README.md) for database backup procedures.

## DNS Management (OpenTofu)

Cloudflare DNS records for tunnel services are managed via OpenTofu in `terraform/`.

### Prerequisites

- OpenTofu installed (`tofu` command)
- Cloudflare API token stored in `terraform/.env` (see below)

### Cloudflare API Token

The Cloudflare API token is stored in `/opt/homelab-config/terraform/.env` with permissions 600.

**To use the token:**
```bash
cd /opt/homelab-config/terraform
source .env  # Loads TF_VAR_cloudflare_api_token
```

The token has **Zone:DNS:Edit** and **Zone:Zone:Read** permissions for `asherlc.com`.

**⚠️ IMPORTANT:** The `.env` file is in `.gitignore` and will not be committed to git. Back up this file or document the token in a password manager.

### Adding a New Service

1. Add the service to `terraform/terraform.tfvars`:
   ```hcl
   services = {
     existing = { description = "..." }
     newservice = { description = "My new service" }
   }
   ```

2. Add the ingress rule to `configs/cloudflared/config.yml`:
   ```yaml
   - hostname: newservice.asherlc.com
     service: http://traefik:80
     originRequest:
       httpHostHeader: newservice.asherlc.com
       originServerName: newservice.asherlc.com
   ```

3. Add the Traefik router and service to `configs/traefik/dynamic.yml`:
   ```yaml
   routers:
     newservice-external:
       rule: "Host(`newservice.asherlc.com`)"
       entryPoints:
         - web
       service: newservice
       middlewares:
         - add-forward-headers
         - authentik  # if authentication required
   
   services:
     newservice:
       loadBalancer:
         servers:
           - url: "http://service-name:port"
   ```

4. Apply the DNS changes:
   ```bash
   cd /opt/homelab-config/terraform
   source .env            # Load API token
   tofu plan              # Review changes
   tofu apply             # Apply changes (will prompt for confirmation)
   # Or: tofu apply -auto-approve
   ```

5. Restart cloudflared to pick up new ingress rules:
   ```bash
   docker restart cloudflared
   ```

6. Verify DNS resolution:
   ```bash
   nslookup newservice.asherlc.com
   # Should resolve to Cloudflare IPs (104.21.x.x, 172.67.x.x)
   ```

### Example: Adding Pi-hole

This was the workflow used to add `pihole.asherlc.com`:

```bash
# 1. Added to terraform.tfvars
pihole = { description = "DNS ad-blocker" }

# 2. Applied DNS record
cd /opt/homelab-config/terraform
source .env
tofu apply -auto-approve

# 3. Verified resolution
nslookup pihole.asherlc.com  # → 104.21.64.245, 172.67.156.169
```

The Cloudflare Tunnel and Traefik configurations were already in place.
