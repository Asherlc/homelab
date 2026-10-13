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

Setup marks the host interface on its own wired LAN switch as **Private** so home devices can reach Plex through the Private-network firewall rule. It leaves other host interfaces unchanged. If Windows is still identifying that network and setup pauses, open Windows Settings → Network & internet, set the installer-owned `vEthernet (MediaKit-LAN-…)` home network to Private, and rerun `Install.cmd`. Managed domain networks require separate policy review.

## Everyday use

Use the Requests shortcut for Seerr and the Plex shortcut for playback/server settings. Add provider/indexer accounts through the app setup links. Set Windows Settings → System → Power → Sleep to **Never** while plugged in so the dedicated server stays available. The installer keeps your existing Windows sleep policy.

Open the **Credentials** shortcut and accept the administrator prompt to view the generated Sonarr, Radarr, Prowlarr and selected downloader web logins. Choose an app, open its link, and reveal or copy its password. Use the Prowlarr login to add indexers/providers, and the SABnzbd login to enter your Usenet server account when selected. Plex and Seerr use your own account sign-in. Passwords are concealed until revealed; copied passwords clear after 30 seconds or when the window closes. Credentials stay out of Status and console output.

The Windows sign-in screen can remain displayed after a reboot. The VM and Plex service should start independently; the candidate must pass the checks in [VALIDATION.md](VALIDATION.md) on the actual PC before unattended operation is considered verified.

## Maintenance

Run `Maintenance.ps1` through Windows PowerShell with an action:

```powershell
.\Maintenance.ps1 -Action Status
.\Maintenance.ps1 -Action Credentials
.\Maintenance.ps1 -Action Backup
.\Maintenance.ps1 -Action Update
.\Maintenance.ps1 -Action Restore
.\Maintenance.ps1 -Action Uninstall
```

The wizard creates shortcuts for common actions. Backups include Plex preferences/database and the supporting apps' configuration and credentials; media files are excluded by default. Store backups somewhere with enough space and keep their access restricted. Updates use a complete tested release manifest. Restore uses the matching backup/release so database migrations and binary versions stay together. Uninstall preserves media and backups.

For an update, select the new extracted kit's manifest explicitly:

```powershell
.\Maintenance.ps1 -Action Update -Path 'D:\Downloads\NewKit\release.json'
```

If interrupted, run that same command with the same kit. The saved update checkpoint records the original and target releases, the before-update backup, and progress. It retries guest setup without backing up a mixture of old and new versions. Status reports `update-pending` until the target setup succeeds. Artifact caches are kept separately for each release.

To restore the original release after an interrupted update, use its complete kit and the before-update ZIP shown by Status:

```powershell
.\Maintenance.ps1 -Action Update -Path 'D:\Downloads\OriginalKit\release.json' -MatchingBackup 'C:\ProgramData\MediaKit\backups\before-update-YYYYMMDDHHMMSS.zip'
```

This reinstalls the matching native binaries and guest runtime before restoring their state. Follow the verified Plex setup screens and leave Launch unchecked. Windows may require removing a newer native application version before permitting its older installer; preserve its profile data. First boot, image downloads and guest archive operations have bounded 30-minute waits. A failed initial setup can be retried after fixing the reported network/storage issue; the wizard waits for cloud-init to finish or fail before retrying guest configuration.

## Candidate status

The automated build verifies source/input checksums, PowerShell/Python behavior, patched wrapper logging, and the package allowlist. Actual Windows cold-boot behavior, Intel Quick Sync, and LAN discovery require validation on the target machine. See [VALIDATION.md](VALIDATION.md) for the exact procedure and recorded results.
