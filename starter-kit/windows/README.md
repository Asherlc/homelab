# Windows Plex starter kit

This package sets up Plex and a media-request/download stack on a dedicated Windows 11 Pro PC. Plex runs on Windows. The supporting apps run in an Ubuntu Hyper-V VM that starts when the PC boots, before Windows sign-in.

## Install

1. Download the built `media-kit-windows.zip` candidate and extract the whole ZIP to a local folder. A complete bundle includes `PlexMediaServer.exe`, `PmsServiceInstaller.msi`, `media-kit.vhdx`, and `release.json` beside `Install.cmd`.
2. Double-click `Install.cmd` and accept the Windows administrator prompt.
3. Choose your media folder, VM location, timezone, wired network adapter, and either qBittorrent or SABnzbd.
4. If Windows needs a restart to enable Hyper-V, restart and run `Install.cmd` again. Setup resumes with the same installation settings.
5. Follow the Plex account/library and Seerr sign-in steps. Use the Windows Movies/TV folder paths shown by setup. Add your own indexers/providers and, for Usenet, your own server account.
6. Use the Requests and Plex shortcuts to start watching/requesting. The Status shortcut shows services, storage, and any remaining account setup.

The source checkout's manifest is a build input. Install from the completed ZIP whose actual installer/image checksums were filled by the candidate build. If downloading a separate `media-kit.vhdx`, place it beside `Install.cmd`; setup verifies it against the manifest. The complete ZIP can be shared directly with a friend without access to the homelab repository.

## Requirements

- Windows 11 Pro x64, build 22631 or later, with administrator access and firmware virtualization enabled.
- A wired network connection and local NTFS media storage.
- At least 8 GB RAM; 16 GB and an SSD for Windows/VM/app data are recommended. The default VM uses two CPUs and 3 GB RAM, with separate expanding 32 GB OS and app-data disks.
- Internet access for initial application images and Plex/provider sign-in.
- Your own Plex account. Hardware transcoding also needs compatible drivers and Plex Pass.

The kit creates a dedicated Plex service account, a separate SMB account, and a private host/VM link. Generated credentials stay on the installation machine. It keeps media on the Windows disk and stores the supporting applications' databases in the VM's separate data disk.

## Everyday use

Use the Requests shortcut for Seerr and the Plex shortcut for playback/server settings. Add provider/indexer accounts through the app setup links. Set Windows Settings → System → Power → Sleep to **Never** while plugged in so the dedicated server stays available. The installer keeps your existing Windows sleep policy.

The Windows sign-in screen can remain displayed after a reboot. The VM and Plex service should start independently; the candidate must pass the checks in [VALIDATION.md](VALIDATION.md) on the actual PC before unattended operation is considered verified.

## Maintenance

Run `Maintenance.ps1` through Windows PowerShell with an action:

```powershell
.\Maintenance.ps1 -Action Status
.\Maintenance.ps1 -Action Backup
.\Maintenance.ps1 -Action Update
.\Maintenance.ps1 -Action Restore
.\Maintenance.ps1 -Action Uninstall
```

The wizard creates shortcuts for common actions. Backups include Plex preferences/database and the supporting apps' configuration and credentials; media files are excluded by default. Store backups somewhere with enough space and keep their access restricted. Updates use a complete tested release manifest. Restore uses the matching backup/release so database migrations and binary versions stay together. Uninstall preserves media and backups.

## Candidate status

The automated build verifies source/input checksums, PowerShell/Python behavior, patched wrapper logging, and the package allowlist. Actual Windows cold-boot behavior, Intel Quick Sync, and LAN discovery require validation on the target machine. See [VALIDATION.md](VALIDATION.md) for the exact procedure and recorded results.
