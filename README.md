# Homelab Configuration

Version-controlled infrastructure configuration with encrypted secrets.

## 🔐 Security

This repository uses **git-crypt** to encrypt sensitive files:
- API keys and secrets
- SSL private keys  
- Cloudflare credentials

Encrypted files are safe to store on GitHub!

## 📚 Documentation

- [Backup & Recovery Guide](docs/BACKUP_README.md)
- [Quick Reference](docs/QUICK_REFERENCE.md)
- [Git-Crypt Usage](docs/GIT_CRYPT_GUIDE.md)

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
├── scripts/             # Automation scripts
├── docs/                # Documentation
└── configs/             # Service configurations
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

See  for database backup procedures.

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
