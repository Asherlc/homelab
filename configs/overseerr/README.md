# Overseerr Configuration

## Files

- **settings.template.json** - Template configuration (safe to view on GitHub)
- **Actual config** - Stored at `/srv/appdata/overseerr/settings.json` (backed up to NAS daily)

## Why Not in Git?

The actual `settings.json` contains multiple API keys scattered throughout:
- Overseerr API key
- Sonarr API key (reference)
- Radarr API key (reference)
- VAPID keys for notifications
- Webhook URLs (may contain tokens)

Rather than encrypt the entire file (making it unreadable), we:
1. Store a template here for reference
2. Back up the real file to NAS daily
3. Don't version control the runtime configuration

## Restore Procedure

To restore Overseerr:
1. Deploy Overseerr container
2. Copy settings from backup: `cp /mnt/storage/backups/homelab/configs/settings.json /srv/appdata/overseerr/`
3. Restart container
