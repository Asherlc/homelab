# Windows candidate acceptance

Record the candidate release ID, ZIP SHA-256, Windows build, CPU/GPU, graphics driver, RAM, storage, and Plex version alongside the result of each check. Automated CI reports are evidence for the source/build; they do not establish behavior on the actual Windows PC.

## Before login

1. Complete first-time setup, Plex claiming/library creation, Seerr sign-in, and provider configuration.
2. Reboot the Windows host and leave it at the sign-in screen.
3. From another device on the home network, open Plex and the Requests bookmark advertised during setup.
4. Confirm existing media plays; submit a request for media you are authorized to acquire and verify download/import into the correct Movies/TV folder.
5. Check that exactly one Plex instance and the selected downloader are running. If the Windows share becomes unavailable, the guest must not write downloads into its OS disk; restore the share and verify recovery.
6. Change the guest DHCP lease/address and confirm the stable `.local` Requests bookmark still opens without Windows login.

## Hardware transcoding

With Plex Pass and the target graphics driver installed, force a video-quality conversion from another device while Windows remains signed out. Confirm hardware decoding/encoding indicators in the Plex dashboard and sustained playback. Test SDR H.264/HEVC first. HDR tone mapping is a separate capability check; do not infer it from ordinary hardware transcoding.

## Maintenance

Create a backup, update Plex/supporting applications through the kit, and repeat the reboot/playback/import checks. Restore the backup and verify the same service identity, library state, application credentials and app connections. Confirm media files remain present. Exercise a failed backup to confirm workloads recover to their previous running state.

## Current evidence

Target: Dell OptiPlex 5080 SFF, Intel Core i5-10500 / UHD 630, 8 GB RAM, 1 TB HDD, Windows 11 Pro.

- Source/unit/package checks: results are recorded in the PR and candidate CI artifacts.
- Windows wrapper compilation and MSI logging: candidate CI job.
- Linux application integration and appliance build: candidate CI jobs.
- Actual Windows installation/cold reboot: pending target-machine access.
- Intel Quick Sync before login: pending target-machine access.
- Client mDNS discovery after guest DHCP change: pending target-machine access.
- Actual-machine update/backup/restore: pending target-machine access.
