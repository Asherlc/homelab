# Homelab Backup Quick Reference Card

## 📅 Backup Schedule
- **Main backup**: Daily @ 2:00 AM
- **Configarr sync**: Daily @ 3:00 AM
- **Authentik DB**: Daily @ midnight

## 📍 Key Locations
```
Backups:    /mnt/storage/backups/homelab/
Configs:    /srv/appdata/
Script:     /opt/scripts/homelab-backup.sh
Logs:       /var/log/homelab-backup.log
Compose:    /opt/docker/compose.yml
```

## ⚡ Quick Commands

### Check Status
```bash
# View backup directory
ls -lh /mnt/storage/backups/homelab/

# Check last backup time
tail -20 /var/log/homelab-backup.log

# Verify containers running
docker ps | grep -E 'configarr|authentik-postgres-backup'
```

### Manual Operations
```bash
# Run backup now
sudo /opt/scripts/homelab-backup.sh

# Force Configarr sync
docker restart configarr

# Export Authentik blueprint
docker exec authentik-worker ak export_blueprint > /tmp/authentik.yml
```

### Common Restores

**Sonarr/Radarr (Database)**
```bash
docker stop sonarr
cp /mnt/storage/backups/homelab/databases/sonarr/sonarr-YYYYMMDD-*.db \
   /srv/appdata/sonarr/sonarr.db
chown 1000:1000 /srv/appdata/sonarr/sonarr.db
docker start sonarr
```

**Configarr (IaC)**
```bash
# Just restart - it auto-syncs from config files
docker restart configarr
docker logs -f configarr
```

**Other Services**
```bash
docker stop <service>
cp /mnt/storage/backups/homelab/configs/<file> /srv/appdata/<service>/
chown 1000:1000 /srv/appdata/<service>/<file>
docker start <service>
```

## 🔍 Troubleshooting

**Backup not running?**
```bash
sudo crontab -l | grep homelab-backup
ls -l /opt/scripts/homelab-backup.sh  # Check permissions
```

**Configarr errors?**
```bash
docker logs configarr --tail 50
sudo chown -R 1000:1000 /srv/appdata/configarr
docker restart configarr
```

**Database locked?**
```bash
docker stop <service>
rm /srv/appdata/<service>/*.db-shm /srv/appdata/<service>/*.db-wal
# Retry restore
```

## 📊 What's Backed Up

✅ Sonarr/Radarr configs (IaC via Configarr)
✅ Sonarr/Radarr/Prowlarr databases
✅ Authentik blueprints + PostgreSQL
✅ Nginx Proxy Manager (configs + SSL)
✅ Overseerr, qBittorrent, Zigbee2mqtt
✅ Mosquitto, Cloudflared, Traefik
✅ Docker Compose file
❌ Plex metadata (too large)
❌ Media files (separate strategy)

## 🔐 Sensitive Files
- `/srv/appdata/configarr/config/secrets.yml`
- `/mnt/storage/backups/homelab/configs/cloudflared/`
- `/mnt/storage/backups/homelab/configs/nginx-proxy-manager-letsencrypt/`

**Keep these secure!** Use `chmod 600` for secrets.

## 📖 Full Documentation
See: `/mnt/storage/backups/homelab/BACKUP_README.md`
