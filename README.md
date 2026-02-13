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
- Cloudflare API token with **Zone:DNS:Edit** and **Zone:Zone:Read** permissions for `asherlc.com`

### Adding a New Service

1. Add the service to `terraform/terraform.tfvars`:
   ```hcl
   newservice = { description = "My new service" }
   ```

2. Add the ingress rule to `configs/cloudflared/config.yml`:
   ```yaml
   - hostname: newservice.asherlc.com
     service: http://traefik:80
     originRequest:
       httpHostHeader: newservice.asherlc.com
       originServerName: newservice.asherlc.com
   ```

3. Add the Traefik router and service to `configs/traefik/dynamic.yml`

4. Apply the DNS changes:
   ```bash
   cd /opt/homelab-config/terraform
   export TF_VAR_cloudflare_api_token="your-token"
   tofu plan     # review changes
   tofu apply    # apply changes
   ```

5. Restart cloudflared: `sudo docker restart cloudflared`
