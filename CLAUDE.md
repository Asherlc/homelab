# Homelab

## Server Access
- Host: `192.168.1.197`, user: `asherlc`
- SSH requires 1Password agent: `SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ssh asherlc@192.168.1.197`
- Docker requires `sudo` on the server
- Config repo on server: `/opt/homelab-config/`

## Deployment Workflow
1. Edit configs locally in this repo
2. Commit and push to GitHub (remote: `Asherlc/homelab`)
3. SSH to server, `cd /opt/homelab-config && git pull`
4. `sudo docker compose -f docker/compose.yml up -d`
5. For DNS changes: `cd terraform && source .env && tofu apply` then `sudo docker restart cloudflared`

## Repo Structure
- `docker/compose.yml` — single compose file for all services
- `configs/traefik/dynamic.yml` — Traefik routers, services, and middlewares
- `terraform/terraform.tfvars` — Cloudflare DNS service definitions (applied with OpenTofu)
- `configs/` — per-service config files
- `scripts/` — automation scripts (backup, encryption, build)
- `.sops.yaml` — SOPS encryption rules (Age key)

## Cloudflare Tunnel
- Tunnel ID: `2dd6f4cb-7842-47f1-8c49-7e1c2af9aca9`
- Credentials file on server: `/opt/docker/.cloudflared/credentials.json`
- Config file on server: `/opt/docker/.cloudflared/config.yml` (minimal — just `tunnel:` and `credentials-file:`)
- Ingress rules are **remotely managed** via Terraform (`cloudflare_zero_trust_tunnel_cloudflared_config` resource), not in the local config.yml
- Cloudflared still needs the local `config.yml` with the tunnel ID to authenticate — it then fetches ingress rules from the Cloudflare API
- The wildcard `*.asherlc.com → traefik:80` means new services only need a DNS CNAME record — no cloudflared config changes needed
- Terraform env: `source /opt/homelab-config/terraform/.env` (has `TF_VAR_cloudflare_api_token` and `TF_VAR_authentik_api_token`)

## PostgreSQL
- PostgreSQL 18+ changed the Docker mount point: use `/var/lib/postgresql` (not `/var/lib/postgresql/data`) so Postgres can create its own versioned subdirectory

## Conventions
- Services use `image:` references, not `build:` — for build-from-source projects, create a build script in `scripts/` that tags locally
- App data stored at `/srv/appdata/<service>/` on the server
- Database backups: `/mnt/storage/backups/homelab/databases/` using `prodrigestivill/postgres-backup-local` (7 days, 4 weeks, 3 months retention)
- External access: `<service>.asherlc.com` via Cloudflare Tunnel + Traefik
- Local access: `<service>.home` via Traefik (no auth)
- External routes go behind Authentik forward auth middleware
- Secrets inline in compose.yml (same pattern as Authentik) — SOPS used for config files in `configs/`

## Adding a New Service
1. Add container(s) to `docker/compose.yml`
2. Add Traefik router + service to `configs/traefik/dynamic.yml` (both `-external` and `-local` routers)
3. Add entry to `terraform/terraform.tfvars` for Cloudflare DNS
4. If build-from-source: add `scripts/<service>-build.sh`
5. Commit, push, pull on server, `docker compose up -d`, `tofu apply`, `docker restart cloudflared`

## Network Map
| IP | Device |
|----|--------|
| 192.168.1.1 | Ubiquiti EdgeRouter |
| 192.168.1.89 | Scrypted |
| 192.168.1.97 | Frigate |
| 192.168.1.197 | Homelab server |
| 192.168.1.218 | Pi-hole |
| 192.168.1.221 | Synology NAS (nas.local) |

## User Preferences
- Execute deployments directly on the server rather than giving instructions
- Auth handled via Authentik SSO, not per-app credentials
