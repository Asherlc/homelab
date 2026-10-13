# Windows Plex starter kit

Date: 2026-10-13

Status: Design approved in conversation. Implementation plan prepared for review; product code and machine validation have not started.

## Intended outcome

Package the media portion of this homelab as a guided installer for a friend's dedicated Windows 11 Pro server. The friend should download one ZIP, run `Install.cmd`, choose storage, and supply their own account/provider information. Routine operation should happen through the browser and Windows shortcuts. Plex and the supporting applications must recover after a host reboot without anyone signing into Windows.

The target supplied by the user is a Dell OptiPlex 5080 SFF with an Intel Core i5-10500, integrated Intel UHD 630 graphics, 8 GB RAM, and a 1 TB HDD. Windows 11 Pro remains the host OS. The user approved the proposed native Plex plus Hyper-V architecture in conversation.

Success means a fresh installation has functioning requests, downloads, imports, and Plex playback, with the user's quality and naming preferences and independent credentials. The release must pass a cold-boot test at the Windows sign-in screen, including hardware transcoding on the actual target hardware when Plex Pass is available.

## Selected architecture

- **Windows host:** native Plex Media Server, PmsService as its third-party Windows service wrapper, local media storage, authenticated SMB sharing, and the installer/maintenance shortcuts.
- **Hyper-V guest:** Ubuntu Server 24.04 LTS, Docker Engine, Seerr, Sonarr, Radarr, Prowlarr, one selected downloader, and Configarr. Docker is a Linux boot service inside the VM.
- **Storage boundary:** Windows owns the media files; the VM mounts one Windows share at `/data`. Application databases and Docker storage use an ext4 guest data disk.
- **Configuration boundary:** ship clean desired-state templates; initialize fresh application databases and connect them through supported APIs.

Native Plex preserves access to the Intel GPU. Microsoft-supported GPU passthrough is unavailable on Windows 11 Pro Hyper-V, so the VM has no GPU dependency. Plex supports hardware transcoding on headless Windows; the particular driver, service account, and GPU configuration still require a real-machine test.

Docker Desktop is outside this design because its documented automatic startup occurs at Windows sign-in. Hyper-V starts the VM at host boot with `AutomaticStartAction=Start`, a short startup delay, and graceful guest shutdown when Windows shuts down.

## First release scope

The installer offers qBittorrent or SABnzbd and provisions exactly the selected downloader. Configarr applies the existing Sonarr WEB-1080p and Radarr HD Bluray + WEB preferences, including the WEB 1080p upgrade cutoff and naming settings, after checking them against the pinned Configarr/templates release.

Bazarr and Tautulli are optional additions after the core installation is working. Tdarr, automatic content deletion, the existing homelab deployment timers, domains, Cloudflare, Authentik, monitoring, and home automation are deferred. The starter kit has its own release and update lifecycle.

Suggested VM defaults are two virtual CPUs, 3 GB static RAM, a 32 GB expanding OS disk, and a 32 GB expanding application-data disk. These defaults must be validated on the supplied 8 GB machine. Recommend 16 GB host RAM and an SSD for Windows/VM/application data, while supporting the supplied HDD configuration where validation permits it. Media capacity is separate from these VM disks.

## Installation experience

1. `Install.cmd` starts the packaged PowerShell wizard and requests administrator elevation for machine setup. Preflight checks verify Windows edition/build, x64 CPU, virtualization, RAM, available storage, existing Hyper-V resources, and port/service conflicts.
2. Choose the Windows media root, VM location, timezone, and downloader. Show the storage that will be created and the network adapter used for the VM. Preserve existing directories and decline incompatible existing installations with an actionable explanation.
3. Enable Hyper-V if needed. Record a nonsecret checkpoint before requesting a reboot. Rerunning `Install.cmd` resumes setup; runtime operation after completion needs no Windows login. Enabling BIOS virtualization remains a guided manual step if necessary.
4. Download and verify the versioned appliance and application installers. Create fresh local service accounts, restricted storage, the Windows share, and the Hyper-V VM. Install native Plex with its final Launch option cleared so it first runs under its intended service account. Configure PmsService through its masked credential dialog, using the dedicated Plex account.
5. Start the guest, initialize application credentials, and apply the selected templates. Wait for application readiness and connect root folders, download categories/clients, and Prowlarr's Sonarr/Radarr integrations. Configuration actions are repeatable and preserve unrelated existing settings.
6. Use Open Plex in the PmsService tray to open Plex's claim/setup flow. Its fallback is the service profile's protected `Setup Plex.html`; simply opening `/web` is insufficient for initial claiming on modern Windows Plex. Guide creation of Movies and TV libraries in Plex using the selected Windows `media/movies` and `media/tv` paths, then open Seerr's Plex sign-in flow. The friend supplies their own Plex login and provider/indexer credentials. Browser-based sign-in and MFA remain interactive steps. Confirm that Seerr selects the configured Sonarr/Radarr profiles and the newly created Plex libraries.
7. Verify the selected download client, writable storage, app integrations, and Plex connectivity. Create shortcuts for Requests, Plex, Status, Update, and Backup. Clearly distinguish completed setup from the remaining cold-boot/hardware validation.

## Windows services and credentials

Use separate nonadministrator local accounts for Plex and the VM's SMB access. Grant Plex the local profile, application-data, media, and transcode permissions it needs; grant the SMB account access only to the selected media root. The SMB account needs both share Change permission and NTFS Modify permission. Windows service logon rights must permit Plex to start before login.

Plex must initialize and run under the same service account/profile throughout claiming, updates, and normal use. Configure PmsService's automatic startup and crash recovery, and disable duplicate Plex startup at interactive login. Account/profile provisioning and the wrapper's installation must be tested as part of the Windows implementation. Package a pinned wrapper build with a minimal redaction patch: upstream v1.2.3 logs the complete initial-claim URL, which must be removed from logging before distribution. Preserve the upstream license and the reproducible source patch.

Generate unique passwords and application API keys for each installation. Credentials belong in Windows service credential storage and restricted local/guest secret files. Logs, command-line arguments, public templates, release assets, and the nonsecret resume checkpoint must not contain passwords or tokens. PmsService's MSI credential dialog uses both `SERVICE_PASSWORD` and `LOGON_PASSWORD`; hide/redact both and validate the distributed MSI with dummy credentials. Use interactive credential entry rather than its documented password-bearing silent-install arguments. Guest SMB credentials are readable only by root. Require SMB3 and retain Windows SMB signing requirements. Any secret-bearing bootstrap seed and cloud-init cached user data must be removed after provisioning, without resetting the installation identity.

No existing Plex claim/token, Arr keys, downloader password, provider credentials, personal app database, or decrypted SOPS file is used to build the package. The existing qBittorrent authentication-bypass settings must be replaced with authenticated access.

## Storage and startup ordering

The Windows root contains `downloads`, `media/movies`, and `media/tv`. Native Plex reads the local `media` paths. The VM accesses the same root through an authenticated SMB share mounted once at `/data`; downloader, Sonarr, and Radarr receive the same `/data` mount. Use the release's configured Linux user/group IDs and compatible CIFS mount ownership.

Application state lives on a separate guest ext4 VHDX so OS maintenance can preserve databases/configuration. Windows media remains outside the VM disks. Backups cover both guest state and native Plex's database/preferences; they do not include the full media library by default.

The guest Docker service depends on both the expected CIFS media mount and the application-data mount. Before starting Docker, verify the media mount type, installation marker, and a write probe. Block startup when the share is missing and retry when Windows SMB becomes available. Stop dependent services on a deliberate unmount. This applies to Docker itself so container restart policies cannot bypass the storage checks. The underlying empty mount directory is inaccessible to application users.

Test hardlinks from the actual Arr containers between the download and library folders, including reading changed content through both links. A common mount is necessary but does not establish hardlink support through CIFS/Windows SMB. If the test fails, configure copy imports and explain the extra disk use while torrents remain seeding. Never move/delete the friend's existing media during setup.

## VM networking and access

Use a wired external Hyper-V switch with host sharing enabled for guest internet/LAN access. Add a private internal switch with an installer-selected, nonoverlapping subnet and fixed host/guest addresses for Windows SMB and Plex communication. The internal guest NIC has no default route or DNS; the external NIC uses LAN DHCP. Keep the host connection stable without requiring a router change.

Keep SMB on the internal link and restrict its Windows firewall rule to that subnet. Publish the necessary authenticated web interfaces on the guest's LAN address. Restrict native Plex's firewall rule to the intended private/internal networks. Advertise a stable, installation-specific `.local` hostname through Avahi on the guest's external LAN interface only, and use it in Requests bookmarks/shortcuts so DHCP changes do not require Windows login. Validate this discovery mechanism on the friend's client devices. Status also resolves/displays the current LAN address for clients without mDNS. Explain any network interruption before creating an external switch; reuse compatible existing switches and preserve unrelated host networks.

Support local disks and wired networking in the first release. Network drives, Wi-Fi-only hosts, VPN routing, and externally exposed management interfaces require separate support work. The friend can access Plex and Requests from devices on the home network.

## Release packaging and maintenance

Keep source under a separate `starter-kit/windows/` directory; use an explicit asset allowlist for packaging. The ZIP contains the Windows entrypoint/wizard, clean templates, maintenance commands, a short guide, and a version/checksum manifest. The larger generalized VHDX is a versioned downloadable companion asset. Sharing this release gives the friend no dependency on cloning or decrypting the homelab repository.

Build the appliance from an official Ubuntu Server ISO and verify its source checksum/signature. Prepare a Generation 2 Hyper-V VHDX with the Linux Secure Boot template, cloud-init, Docker Engine, and versioned bootstrap resources. Ubuntu's published Azure VHD artifacts are unsuitable for local Hyper-V. Generalize machine/cloud-init identity and SSH host keys before release; regenerate per-install identities at first boot. The public image contains no populated application databases or credentials.

Pin and test the native installers, wrapper, container images, Configarr, and quality-template revisions together in the release manifest. Updates are explicit: create a consistent backup, apply a tested release, verify services and integrations, and preserve installation credentials/media. Rollback restores the matching application state and binary/image versions, rather than assuming database migrations are reversible. Uninstall preserves media and backups and removes only installer-owned resources; data deletion requires a separate explicit choice.

## Validation required before distributing the installer

- Windows PowerShell tests: preflight failures, interrupted setup/resume, existing-resource protection, special-character paths, secret redaction, and rerunning setup without resetting credentials.
- Guest tests: fresh app configuration, repeated API setup without duplicates, selected-downloader-only behavior, mount failure/recovery, hardlink/copy selection, and backup/restore.
- Release checks: source/image integrity, pinned dependency manifest, complete ZIP asset allowlist, and absence of personal credentials or installation state. Exercise wrapper claiming and MSI installation with dummy secrets, and confirm those secrets do not appear in any retained logs.
- Actual Windows 11 Pro test: install on the target class of hardware, cold reboot without sign-in, and confirm Plex, Requests, provider connectivity, downloads, and imports from another device. Change the guest's DHCP address and confirm its Requests bookmark still works through the advertised hostname without host login.
- Hardware test with Plex Pass: force a video transcode before Windows sign-in and confirm hardware decoding/encoding in the Plex dashboard. Treat HDR tone mapping as a separate capability test.
- Maintenance test: update Plex/the supporting stack, reboot again without sign-in, and verify playback and integrations. Restore a backup and repeat the functional checks.

The current development workspace is macOS. Local checks can validate source and guest behavior, but cannot prove Windows service startup or this machine's Quick Sync behavior. Release readiness depends on the actual Windows checks above.

## Evidence used for the design

- [Target listing](https://www.amazon.com/dp/B0D7C196TW) and [Intel i5-10500 specifications](https://www.intel.com/content/www/us/en/products/sku/199277/intel-core-i510500-processor-12m-cache-up-to-4-50-ghz/specifications.html).
- [Hyper-V automatic host-boot actions](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-virtualsystemsettingdata) and [GPU support boundaries](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues).
- [Plex headless Windows hardware-transcoding announcement](https://forums.plex.tv/t/plex-media-server/30447/593), [PmsService](https://github.com/cjmurph/PmsService), and [Plex hardware-transcoding requirements](https://support.plex.tv/articles/115002178853-using-hardware-accelerated-streaming/).
- [Windows Plex initial claiming](https://forums.plex.tv/t/new-claiming-requirement-for-windows/839096), [wrapper claim handling](https://github.com/cjmurph/PmsService/blob/v1.2.3/PlexServiceWCF/TrayInteraction.cs), and [MSI credential logging rules](https://learn.microsoft.com/en-us/windows/win32/msi/preventing-confidential-information-from-being-written-into-the-log-file).
- [Configarr configuration capabilities](https://configarr.de/docs/configuration/config-file/), including experimental root-folder, download-client, and Prowlarr support that requires validation against the pinned release.
- [Ubuntu image formats and Azure VHD restriction](https://ubuntu.com/docs/public-images/public-images-reference/artifacts/), [NoCloud bootstrap](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html), and [cloud-init cleanup](https://docs.cloud-init.io/en/latest/reference/cli.html).
- Repository starting points: `docker/compose.yml`, `configarr/config.yml`, and cleaned downloader preferences/categories. The package has independent paths, credentials, service accounts, and startup machinery.
