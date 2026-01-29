# Homelab Backup & Recovery Documentation

**Last Updated**: January 27, 2026
**Version**: 1.0

## Overview

This homelab uses a multi-layered backup strategy combining Infrastructure-as-Code (IaC) configuration management with traditional database and file backups.

### Backup Components

1. **Configarr** - IaC management for Sonarr/Radarr (quality profiles, custom formats)
2. **Automated backup script** - Daily backups of databases and critical configs
3. **PostgreSQL backup container** - Automated Authentik database backups
4. **Manual snapshots** - One-time backups on demand

---

## Backup Schedule

| Component | Schedule | Retention | Location |
|-----------|----------|-----------|----------|
| Configarr sync | Daily @ 3:00 AM | Current state only | `/srv/appdata/configarr/config/` |
| Main backup script | Daily @ 2:00 AM | 7 days | `/mnt/storage/backups/homelab/` |
| Authentik PostgreSQL | Daily @ midnight | 7d / 4w / 3m | `/mnt/storage/backups/homelab/databases/` |
| Sonarr/Radarr/Prowlarr DBs | Daily @ 2:00 AM | 7 days | `/mnt/storage/backups/homelab/databases/` |

---

## What Gets Backed Up

### Infrastructure-as-Code (Configarr)
- **Sonarr**: Quality profiles, custom formats, naming settings
- **Radarr**: Quality profiles, custom formats, naming settings
- **Location**: `/mnt/storage/backups/homelab/configs/configarr/`
- **Files**: `config.yml`, `secrets.yml`

### Databases
- **Sonarr**: `/mnt/storage/backups/homelab/databases/sonarr/sonarr-YYYYMMDD-HHMMSS.db`
- **Radarr**: `/mnt/storage/backups/homelab/databases/radarr/radarr-YYYYMMDD-HHMMSS.db`
- **Prowlarr**: `/mnt/storage/backups/homelab/databases/prowlarr/prowlarr-YYYYMMDD-HHMMSS.db`
- **Authentik**: Managed by postgres-backup-local container (compressed SQL dumps)

### Identity & Authentication
- **Authentik blueprints**: `/mnt/storage/backups/homelab/configs/authentik-blueprint.yml`
  - Contains: Flows, policies, providers, applications, users, groups

### Service Configurations
- **Docker Compose**: `/mnt/storage/backups/homelab/docker/compose.yml`
- **Overseerr**: `configs/settings.json`
- **Nginx Proxy Manager**: `configs/nginx-proxy-manager/` (proxy configs, SSL certs)
- **qBittorrent**: `configs/qBittorrent.conf`, `configs/categories.json`
- **Zigbee2mqtt**: `configs/configuration.yaml`
- **Mosquitto**: `configs/mosquitto/`
- **Cloudflared**: `configs/cloudflared/`
- **Traefik**: `configs/traefik/`

### What's NOT Backed Up
- **Plex metadata** - Too large (20GB), easily regenerated
- **Media files** - Stored on NAS, separate backup strategy
- **Download cache** - Temporary files, not critical
- **Log files** - Regenerated, not critical for restore

---

## Verification & Monitoring

### Check Backup Status

```bash
# Verify last backup timestamp
ls -lh /mnt/storage/backups/homelab/

# Check backup script logs
tail -50 /var/log/homelab-backup.log

# Verify Configarr is syncing
docker logs configarr --tail 50

# Check Authentik PostgreSQL backup status
docker logs authentik-postgres-backup --tail 20

# List recent database backups
ls -lht /mnt/storage/backups/homelab/databases/sonarr/ | head -5
ls -lht /mnt/storage/backups/homelab/databases/radarr/ | head -5
ls -lht /mnt/storage/backups/homelab/databases/prowlarr/ | head -5
```

### Manual Backup Trigger

```bash
# Run backup script immediately
sudo /opt/scripts/homelab-backup.sh

# Force Configarr sync
docker restart configarr

# Manual Authentik blueprint export
docker exec authentik-worker ak export_blueprint > /tmp/authentik-manual-backup.yml
```

### Verify Backup Integrity

```bash
# Check SQLite database integrity
sqlite3 /mnt/storage/backups/homelab/databases/sonarr/sonarr-YYYYMMDD-HHMMSS.db "PRAGMA integrity_check;"

# Verify YAML files are valid
docker run --rm -v /mnt/storage/backups/homelab:/backups alpine/yamllint /backups/configs/configarr/config.yml
```

---

## Restore Procedures

### 🔴 CRITICAL: Always test restores in a non-production environment first!

### Restore Sonarr Configuration

**Option 1: Using Configarr (Recommended)**

1. Ensure Configarr container is running:
   ```bash
   docker ps | grep configarr
   ```

2. Configarr automatically syncs from `/srv/appdata/configarr/config/config.yml`
   - No manual restore needed if config file is intact
   - Configarr will push settings to Sonarr on next sync (3 AM daily or on container restart)

3. To force immediate sync:
   ```bash
   docker restart configarr
   docker logs -f configarr
   ```

**Option 2: Database Restore (Full State Recovery)**

1. Stop Sonarr:
   ```bash
   docker stop sonarr
   ```

2. Backup current database (just in case):
   ```bash
   cp /srv/appdata/sonarr/sonarr.db /srv/appdata/sonarr/sonarr.db.before-restore
   ```

3. Restore database from backup:
   ```bash
   cp /mnt/storage/backups/homelab/databases/sonarr/sonarr-YYYYMMDD-HHMMSS.db /srv/appdata/sonarr/sonarr.db
   chown 1000:1000 /srv/appdata/sonarr/sonarr.db
   ```

4. Start Sonarr:
   ```bash
   docker start sonarr
   ```

5. Verify in UI that quality profiles, custom formats, and shows are restored

### Restore Radarr Configuration

Follow same steps as Sonarr, but use `/srv/appdata/radarr/radarr.db`

### Restore Prowlarr Configuration

**Note**: Prowlarr is not managed by Configarr, only database backups available.

1. Stop Prowlarr:
   ```bash
   docker stop prowlarr
   ```

2. Restore database:
   ```bash
   cp /mnt/storage/backups/homelab/databases/prowlarr/prowlarr-YYYYMMDD-HHMMSS.db /srv/appdata/prowlarr/prowlarr.db
   chown 1000:1000 /srv/appdata/prowlarr/prowlarr.db
   ```

3. Start Prowlarr:
   ```bash
   docker start prowlarr
   ```

### Restore Authentik

**Option 1: Blueprint Import (Configuration Only)**

1. Access Authentik Admin UI: `https://authentik.asherlc.com/if/admin`

2. Navigate to: **System** → **Blueprints**

3. Click **Import** and upload:
   ```
   /mnt/storage/backups/homelab/configs/authentik-blueprint.yml
   ```

4. Review and apply the blueprint

**Option 2: Full Database Restore (Complete State)**

1. Stop Authentik services:
   ```bash
   docker stop authentik-server authentik-worker
   ```

2. Find the latest Authentik PostgreSQL backup:
   ```bash
   ls -lt /mnt/storage/backups/homelab/databases/ | grep authentik
   ```

3. Restore PostgreSQL database:
   ```bash
   # Decompress if gzipped
   gunzip /mnt/storage/backups/homelab/databases/authentik-YYYYMMDD-HHMMSS.sql.gz

   # Restore
   docker exec -i authentik-postgresql psql -U authentik -d authentik < /mnt/storage/backups/homelab/databases/authentik-YYYYMMDD-HHMMSS.sql
   ```

4. Start Authentik services:
   ```bash
   docker start authentik-server authentik-worker
   ```

### Restore Other Services

**Overseerr:**
```bash
docker stop overseerr
cp /mnt/storage/backups/homelab/configs/settings.json /srv/appdata/overseerr/settings.json
chown 1000:1000 /srv/appdata/overseerr/settings.json
docker start overseerr
```

**Nginx Proxy Manager:**
```bash
docker stop nginx-proxy-manager
rsync -av /mnt/storage/backups/homelab/configs/nginx-proxy-manager/ /srv/appdata/nginx-proxy-manager/data/
rsync -av /mnt/storage/backups/homelab/configs/nginx-proxy-manager-letsencrypt/ /srv/appdata/nginx-proxy-manager/letsencrypt/
docker start nginx-proxy-manager
```

**qBittorrent:**
```bash
docker stop qbittorrent
cp /mnt/storage/backups/homelab/configs/qBittorrent.conf /srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf
cp /mnt/storage/backups/homelab/configs/categories.json /srv/appdata/qbittorrent/qBittorrent/categories.json
chown -R 1000:1000 /srv/appdata/qbittorrent
docker start qbittorrent
```

**Zigbee2mqtt:**
```bash
docker stop zigbee2mqtt
cp /mnt/storage/backups/homelab/configs/configuration.yaml /srv/appdata/zigbee2mqtt/configuration.yaml
docker start zigbee2mqtt
```

**Mosquitto:**
```bash
docker stop mosquitto
rsync -av /mnt/storage/backups/homelab/configs/mosquitto/ /srv/appdata/mosquitto/config/
docker start mosquitto
```

**Cloudflare Tunnel:**
```bash
rsync -av /mnt/storage/backups/homelab/configs/cloudflared/ /opt/docker/.cloudflared/
docker restart cloudflared
```

**Traefik:**
```bash
docker stop traefik
cp /mnt/storage/backups/homelab/configs/traefik/*.yml /srv/appdata/traefik/
docker start traefik
```

### Full Disaster Recovery

If rebuilding the entire homelab from scratch:

1. **Install base system** (Debian/Ubuntu)

2. **Install Docker**:
   ```bash
   curl -fsSL https://get.docker.com | sh
   ```

3. **Restore Docker Compose file**:
   ```bash
   mkdir -p /opt/docker
   cp /mnt/storage/backups/homelab/docker/compose.yml /opt/docker/
   ```

4. **Restore service config directories**:
   ```bash
   mkdir -p /srv/appdata
   # Restore each service config from backups
   ```

5. **Restore databases** (before starting containers):
   ```bash
   cp /mnt/storage/backups/homelab/databases/sonarr/sonarr-LATEST.db /srv/appdata/sonarr/sonarr.db
   cp /mnt/storage/backups/homelab/databases/radarr/radarr-LATEST.db /srv/appdata/radarr/radarr.db
   cp /mnt/storage/backups/homelab/databases/prowlarr/prowlarr-LATEST.db /srv/appdata/prowlarr/prowlarr.db
   chown -R 1000:1000 /srv/appdata
   ```

6. **Start services**:
   ```bash
   cd /opt/docker
   docker compose up -d
   ```

7. **Restore Configarr configuration**:
   ```bash
   mkdir -p /srv/appdata/configarr/config
   cp /mnt/storage/backups/homelab/configs/configarr/* /srv/appdata/configarr/config/
   chown -R 1000:1000 /srv/appdata/configarr
   docker restart configarr
   ```

8. **Restore backup script and cron**:
   ```bash
   mkdir -p /opt/scripts
   cp /mnt/storage/backups/homelab/homelab-backup.sh /opt/scripts/
   chmod +x /opt/scripts/homelab-backup.sh
   (crontab -l 2>/dev/null; echo "0 2 * * * /opt/scripts/homelab-backup.sh") | crontab -
   ```

---

## Configuration Management

### Modifying Configarr Settings

Edit the configuration files:

```bash
# Edit main config
sudo nano /srv/appdata/configarr/config/config.yml

# Edit secrets (API keys)
sudo nano /srv/appdata/configarr/config/secrets.yml
```

**After making changes:**
```bash
# Restart Configarr to apply changes
docker restart configarr

# Watch logs to verify sync
docker logs -f configarr
```

### Adding Services to Backup

Edit the backup script:

```bash
sudo nano /opt/scripts/homelab-backup.sh
```

Add new backup commands in the "Backup other critical service configs" section:

```bash
# Example: Add new service
if [ -f /srv/appdata/newservice/config.yml ]; then
    cp /srv/appdata/newservice/config.yml "$BACKUP_DIR/configs/" 2>&1 | tee -a "$LOG_FILE"
fi
```

Test the modified script:
```bash
sudo /opt/scripts/homelab-backup.sh
```

### Adjusting Backup Schedules

**Main backup script:**
```bash
# Edit root crontab
sudo crontab -e

# Current: 0 2 * * * /opt/scripts/homelab-backup.sh
# Change to 3 AM: 0 3 * * * /opt/scripts/homelab-backup.sh
```

**Configarr sync:**

Edit `/srv/appdata/configarr/config/config.yml`:
```yaml
buildarr:
  update_times:
    - "04:00"  # Change to 4 AM
```

**Authentik PostgreSQL backup:**

Edit `/opt/docker/compose.yml`:
```yaml
authentik-postgres-backup:
  environment:
    - SCHEDULE=@daily      # Change to specific time: SCHEDULE=0 1 * * *
    - BACKUP_KEEP_DAYS=14  # Increase retention
```

Apply changes:
```bash
cd /opt/docker
sudo docker compose up -d authentik-postgres-backup
```

---

## Troubleshooting

### Backup Script Not Running

**Check cron job exists:**
```bash
sudo crontab -l | grep homelab-backup
```

**Check script permissions:**
```bash
ls -l /opt/scripts/homelab-backup.sh
# Should be: -rwxr-xr-x (executable)
```

**Fix permissions:**
```bash
sudo chmod +x /opt/scripts/homelab-backup.sh
```

**Check logs:**
```bash
tail -50 /var/log/homelab-backup.log
```

### Configarr Not Syncing

**Check container status:**
```bash
docker ps | grep configarr
```

**View logs:**
```bash
docker logs configarr --tail 100
```

**Common issues:**

1. **Permission denied errors:**
   ```bash
   sudo chown -R 1000:1000 /srv/appdata/configarr
   docker restart configarr
   ```

2. **API connection errors:**
   - Verify API keys in `/srv/appdata/configarr/config/secrets.yml`
   - Ensure Sonarr/Radarr containers are running
   - Check network connectivity: `docker exec configarr ping sonarr`

3. **Config validation errors:**
   ```bash
   # Validate YAML syntax
   docker run --rm -v /srv/appdata/configarr/config:/config alpine/yamllint /config/config.yml
   ```

### Database Restore Fails

**SQLite database locked:**
```bash
# Make sure service is stopped
docker stop sonarr

# Check for lock files
ls -la /srv/appdata/sonarr/*.db*
rm /srv/appdata/sonarr/*.db-shm /srv/appdata/sonarr/*.db-wal

# Retry restore
```

**Database corruption:**
```bash
# Check integrity
sqlite3 /mnt/storage/backups/homelab/databases/sonarr/sonarr-LATEST.db "PRAGMA integrity_check;"

# If corrupted, try older backup
ls -lt /mnt/storage/backups/homelab/databases/sonarr/
```

### Authentik Blueprint Import Fails

**Check blueprint syntax:**
```bash
# Validate YAML
docker run --rm -v /mnt/storage/backups/homelab/configs:/backups alpine/yamllint /backups/authentik-blueprint.yml
```

**Import via CLI instead of UI:**
```bash
docker exec -i authentik-worker ak import_blueprint < /mnt/storage/backups/homelab/configs/authentik-blueprint.yml
```

### Disk Space Issues

**Check backup directory size:**
```bash
du -sh /mnt/storage/backups/homelab/
```

**Clean old database backups manually:**
```bash
# Remove backups older than 14 days
find /mnt/storage/backups/homelab/databases -name "*.db" -type f -mtime +14 -delete
```

**Compress large config backups:**
```bash
cd /mnt/storage/backups/homelab/configs
tar -czf nginx-proxy-manager-$(date +%Y%m%d).tar.gz nginx-proxy-manager/
rm -rf nginx-proxy-manager/
```

---

## Security Considerations

### Sensitive Files

The following files contain sensitive information:

- `/srv/appdata/configarr/config/secrets.yml` - API keys
- `/mnt/storage/backups/homelab/configs/configarr/secrets.yml` - Backup of API keys
- `/mnt/storage/backups/homelab/configs/cloudflared/` - Cloudflare tunnel credentials
- `/mnt/storage/backups/homelab/configs/nginx-proxy-manager-letsencrypt/` - SSL private keys

**Recommendations:**

1. **Restrict permissions:**
   ```bash
   sudo chmod 600 /srv/appdata/configarr/config/secrets.yml
   sudo chmod -R 700 /mnt/storage/backups/homelab/configs/cloudflared
   ```

2. **Encrypt backups for off-site storage:**
   ```bash
   # Create encrypted archive
   tar -czf - /mnt/storage/backups/homelab | gpg -c > homelab-backup-$(date +%Y%m%d).tar.gz.gpg
   ```

3. **Use separate user for backups:**
   ```bash
   # Create backup user with read-only access
   sudo useradd -r -s /bin/false backupuser
   sudo chown -R backupuser:backupuser /mnt/storage/backups/homelab
   ```

### Audit Log

Document all restore operations:

```bash
echo "$(date): Restored Sonarr database from sonarr-20260127-223636.db" | sudo tee -a /var/log/homelab-restore.log
```

---

## Monitoring & Alerts

### Set Up Backup Monitoring

**Option 1: Email alerts on backup failure**

Add to `/opt/scripts/homelab-backup.sh`:

```bash
# At the end of the script
if [ $? -eq 0 ]; then
    echo "Backup completed successfully" | mail -s "Homelab Backup Success" admin@example.com
else
    echo "Backup failed! Check logs at /var/log/homelab-backup.log" | mail -s "Homelab Backup FAILED" admin@example.com
fi
```

**Option 2: Healthcheck endpoint**

Create monitoring endpoint:

```bash
# Create healthcheck script
cat > /opt/scripts/backup-healthcheck.sh <<'EOF'
#!/bin/bash
LAST_BACKUP=$(find /mnt/storage/backups/homelab/databases/sonarr -name "*.db" -type f -mtime -2 | wc -l)
if [ $LAST_BACKUP -gt 0 ]; then
    echo "OK: Backup found within last 48 hours"
    exit 0
else
    echo "CRITICAL: No backup found in last 48 hours"
    exit 2
fi
EOF

chmod +x /opt/scripts/backup-healthcheck.sh
```

**Option 3: Integration with monitoring tools**

- Add to Uptime Kuma / Healthchecks.io
- Configure webhook to Slack/Discord
- Use Prometheus exporter for backup metrics

---

## Maintenance Tasks

### Monthly

- [ ] Verify a restore from backup (test environment)
- [ ] Check backup directory size and clean up if needed
- [ ] Review and update this documentation
- [ ] Test Authentik blueprint import
- [ ] Verify Configarr is applying TRaSH Guide updates

### Quarterly

- [ ] Restore full homelab in test environment (disaster recovery test)
- [ ] Review and update retention policies
- [ ] Audit sensitive file permissions
- [ ] Update Configarr settings with new TRaSH Guide recommendations
- [ ] Consider off-site backup sync

### Annually

- [ ] Review and optimize backup strategy
- [ ] Update container images
- [ ] Document any infrastructure changes
- [ ] Review restore procedures for accuracy

---

## Quick Reference

### Important Paths

| Component | Primary Location | Backup Location |
|-----------|------------------|-----------------|
| Configarr config | `/srv/appdata/configarr/config/` | `/mnt/storage/backups/homelab/configs/configarr/` |
| Sonarr DB | `/srv/appdata/sonarr/sonarr.db` | `/mnt/storage/backups/homelab/databases/sonarr/` |
| Radarr DB | `/srv/appdata/radarr/radarr.db` | `/mnt/storage/backups/homelab/databases/radarr/` |
| Prowlarr DB | `/srv/appdata/prowlarr/prowlarr.db` | `/mnt/storage/backups/homelab/databases/prowlarr/` |
| Authentik blueprint | - | `/mnt/storage/backups/homelab/configs/authentik-blueprint.yml` |
| Docker Compose | `/opt/docker/compose.yml` | `/mnt/storage/backups/homelab/docker/compose.yml` |
| Backup script | `/opt/scripts/homelab-backup.sh` | `/mnt/storage/backups/homelab/homelab-backup.sh` |

### Essential Commands

```bash
# Manual backup
sudo /opt/scripts/homelab-backup.sh

# Check backup status
ls -lh /mnt/storage/backups/homelab/

# View backup logs
tail -50 /var/log/homelab-backup.log

# Restart Configarr
docker restart configarr

# Check all backup containers
docker ps | grep -E 'configarr|authentik-postgres-backup'

# Force Configarr sync
docker restart configarr && docker logs -f configarr

# Export Authentik blueprint manually
docker exec authentik-worker ak export_blueprint > /tmp/authentik-backup-$(date +%Y%m%d).yml
```

---

## Support & Resources

### Documentation

- **Configarr**: https://configarr.de/docs/
- **Authentik Backups**: https://docs.goauthentik.io/sys-mgmt/ops/backup-restore/
- **TRaSH Guides**: https://trash-guides.info/

### Container Images

- **Configarr**: `ghcr.io/raydak-labs/configarr:latest`
- **PostgreSQL Backup**: `prodrigestivill/postgres-backup-local:16`

### Log Locations

- Backup script: `/var/log/homelab-backup.log`
- Configarr: `docker logs configarr`
- Authentik backup: `docker logs authentik-postgres-backup`
- System cron: `/var/log/syslog` (search for "homelab-backup")

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-27 | Initial documentation |

---

**Questions or Issues?**

Review this documentation first, then check:
1. Container logs: `docker logs <container-name>`
2. Backup logs: `/var/log/homelab-backup.log`
3. System logs: `journalctl -xe`
