# Windows Plex Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a downloadable Windows starter kit that provisions the friend's media stack and runs it before Windows login.

**Architecture:** Native Windows Plex runs under a dedicated PmsService account. An automatically started Hyper-V Ubuntu VM runs the supporting Docker applications and mounts Windows-local media through SMB. A PowerShell wizard coordinates provisioning and maintenance; a versioned manifest binds the Windows installers, patched wrapper, VM image, guest configuration, and container digests together.

**Tech Stack:** Windows PowerShell 5.1, Hyper-V/SMB cmdlets, .NET Framework 4.7.2/MSBuild/WiX 3 for PmsService, Python 3 standard library, Docker Compose, systemd, cloud-init, Avahi, Packer/QEMU, Pester, Python unittest, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-13-windows-plex-installer-design.md`

## Global Constraints

- Target: Windows 11 Pro x64, Dell OptiPlex 5080 SFF, i5-10500/UHD 630, 8 GB RAM, 1 TB HDD. Windows remains the host OS.
- VM: Ubuntu Server 24.04 LTS; two virtual CPUs, 3 GB static RAM, 32 GB expanding OS VHDX and 32 GB expanding ext4 application-data VHDX.
- Native Plex and every supporting service start after host reboot without Windows sign-in. Hyper-V uses automatic Start and graceful guest shutdown.
- Windows media root contains `downloads`, `media/movies`, and `media/tv`. Guest mount is `/data`; app state is separate guest ext4 storage.
- Select exactly one downloader: `qbittorrent` or `sabnzbd`. Configarr preserves the specified Sonarr/Radarr quality, naming, and WEB 1080p cutoff preferences.
- Fresh per-install credentials; separate nonadministrator Plex and SMB accounts; no passwords/tokens in command arguments, logs, resume state, or release assets.
- Gate Docker itself on verified SMB and ext4 mounts, including socket-triggered starts. Missing storage blocks startup and has a bounded recovery loop.
- Use a wired external switch plus fixed-address internal host/guest link. Advertise the unique guest `.local` hostname only on the external interface.
- PmsService must include claim-URL logging redaction and hidden MSI password aliases. Preserve upstream and bundled third-party licenses/notices.
- Existing homelab deployment and credentials remain outside the package. Release packaging uses an explicit allowlist.
- Actual Windows cold-boot and Quick Sync tests are release gates; tests on macOS or hosted CI do not satisfy them.

## Review Focus

- An interrupted wizard must preserve its installation ID, credentials, selected paths, and resources when rerun; Task 1 owns resume tests.
- Existing Plex, shares, VMs, ports, or switches must not be overwritten or adopted without matching installer ownership; Tasks 2 and 3 own conflict tests.
- An empty or wrong media mount must never let a restarted downloader write into the VM OS disk; Task 4 owns storage failure/recovery tests.
- Spaces, apostrophes, non-ASCII characters, and shell metacharacters in supported Windows paths must remain literal data; Tasks 1 and 3 own path/seed tests.
- A guest DHCP change must preserve Requests access from another device while Windows remains signed out; Tasks 3 and 8 own discovery tests.

## Shared contracts

All source lives under `starter-kit/windows/`. Public settings use `schemaVersion: 1` and contain no secret values. `installationId` is a generated UUID persisted once. `releaseId` identifies the immutable manifest; updates change it explicitly.

`InstallConfig` contains `installationId`, `releaseId`, `hostname`, `timezone`, `downloader`, Windows `mediaRoot`/`vmRoot`, VM/switch/share names, two assigned MAC addresses, internal host/guest IPv4 addresses and prefix, and local Plex/SMB account names. Host-only fields are excluded from the guest projection. The hostname is installation-specific and remains stable.

Guest `BootstrapConfig` contains `schemaVersion`, `installationId`, `releaseId`, `hostname`, `hostIP`, `guestIP`, `prefixLength`, `timezone`, `downloader`, `network.internalMac`, `network.externalMac`, `smb.account`, `smb.domain`, `smb.share`, and `smb.credentialsRef`. `credentialsRef` is a protected provisioning file, never a password. The host and guest addresses must be distinct members of the selected subnet. `/data` and `/var/lib/starter-kit` are fixed mount paths.

`release.json` records `schemaVersion`, `releaseId`, the minimum supported Windows build, guest/wrapper/native installer artifacts with immutable URL and SHA-256, container references with digests, quality-template revisions, and asset filenames. Every downloadable executable requires a checksum match; Plex additionally requires a valid expected Authenticode publisher. Unknown schema versions or incomplete manifests fail before host mutation.

Guest CLI commands emit JSON containing `installationId`, `releaseId`, `phase`, `downloader`, health checks, and unresolved interactive steps. They never emit passwords/API keys. The host authenticates guest SSH using a per-install client key protected by NTFS ACLs. Generate a separate per-install guest SSH host key during seed creation, install it through the protected seed, and write its public key into the host's `known_hosts` before connection. Delete the host-side copy of the guest private key with the seed after successful provisioning; the guest's restricted host key persists. Credentials/bootstrap media are restricted and removed once their persistent replacements are verified.

## Task 1: Installer contracts, preflight, and repeatable state

**Files:** Create `modules/MediaKit.{Common,Artifacts,Secrets}.psm1`, `schemas/install.schema.json`, `schemas/bootstrap.schema.json`, `schemas/release.schema.json`, `tests/Common.Tests.ps1`, and guest fixture files under `tests/fixtures/`.

**Interfaces:** Produce `Test-KitConfig($Config)`, `Test-KitManifest($Manifest)`, `Get-KitCheckpoint($Path)`, `Save-KitCheckpoint($Path,$Checkpoint)`, `Get-KitGuestConfig($Config)`, and `Get-KitPreflight($HostFacts,$Config)` in the common module. Artifacts provides `Save-KitVerifiedArtifact($Artifact,$Destination)`; Secrets provides `New-KitPassword()`, `Save-KitSecret($Name,[SecureString]$Value)`, and `Get-KitSecret($Name)`. Checkpoints expose phase/completed operation IDs and public config only; secrets use machine-local DPAPI storage with Administrator/SYSTEM-only ACLs.

- [ ] Write Pester tests that reject overlapping/equal internal addresses, unsafe share names, invalid downloader/timezone, incomplete manifests, and changed installation identity on resume; verify a path such as `D:\Friend's Media\Films & TV` survives serialization unchanged and a supplied secret is absent from checkpoint/diagnostics.
- [ ] Run `pwsh -NoProfile -Command "Invoke-Pester starter-kit/windows/tests/Common.Tests.ps1 -CI"`; expect failures for missing functions, not syntax/fixture errors.
- [ ] Implement the common interfaces with atomic JSON state writes, strict validation, Windows build/RAM/virtualization/disk checks, and explicit ownership records. Artifact download/cache verification rejects wrong hashes, HTTP redirects, wrong architecture and invalid expected signers before execution; select Plex's `windows-x86_64` release metadata and freeze SHA-256 rather than relying on its SHA-1 metadata alone. Preserve completed checkpoints and original credentials on rerun.
- [ ] Rerun the same Pester command; expect all tests passing. Commit the contracts/module/tests and push the new commit.

## Task 2: Native Plex, service identities, and patched wrapper

**Files:** Create `modules/MediaKit.Windows.psm1`, `modules/MediaKit.UserHive.psm1`, `vendor/pmsservice/{source.lock.json,redact-secrets.patch,NOTICES.md}`, `build/Build-PmsService.ps1`, and `tests/Windows.Tests.ps1`.

**Interfaces:** Consume Task 1 config/manifest/checkpoints. Produce `Install-KitPlex($Config,$Manifest)`, `New-KitServiceIdentity($Name,[SecureString]$Password)`, `Install-KitPlexService($Config,$Artifact,[PSCredential]$Credential)`, `New-KitMediaShare($Config,[PSCredential]$Credential)`, `Open-KitPlexClaim($Config)`, and `Get-KitPlexStatus($Config)`. UserHive exposes `Invoke-KitUserHive($AccountSid,[scriptblock]$Action)`, selecting the Plex service SID's hive and unloading only a hive it explicitly loaded.

- [ ] Write tests for conflicting existing identities/services, the same Plex account/profile across first start and resume, share plus NTFS permissions, no password-bearing process arguments, and a dummy claim URL absent from retained wrapper/MSI logs. External Windows service/MSI operations are the mock boundary; actual config/state serialization remains real.
- [ ] Run `pwsh -NoProfile -Command "Invoke-Pester starter-kit/windows/tests/Windows.Tests.ps1 -CI"`; expect missing-interface failures.
- [ ] Implement identities/profile creation, local folders/share ACLs, authenticated SMB3/signing, restrictive firewall scope, Plex install without launching as the interactive user, and automatic PmsService/crash recovery. Use an in-process `MsiOpenPackageW`/`MsiSetPropertyW`/`MsiDoActionW` session bridge for credential properties, with masked UI and both `SERVICE_PASSWORD` and `LOGON_PASSWORD` hidden/secure as required; do not pass passwords to `msiexec` arguments. Pin PmsService v1.2.3 commit `f1cb2de5795aa4149b4670b6f0f2973b41003c08`, remove complete claim-URL logging, fix the invalid installer postbuild copy, distinguish the patched package version, and build Release/Any CPU with .NET 4.7.2 targeting/WCF tools and WiX 3.14.1. Record bundled DLL hashes/notices and discard upstream temporary signing identities. Use the verified interactive Plex EXE Launch option unless the pinned installer's silent behavior has been tested; do not invent a no-launch flag. Use the correct service-profile claim link; guide Movies/TV library creation with Windows paths.
- [ ] Run the Pester tests plus the Windows wrapper build and dummy-secret logging test; expect green tests, a checksummed MSI, and no dummy credential/token in retained output. Commit and push. A hosted runner proves build behavior, not target-machine GPU/startup behavior.

## Task 3: Hyper-V VM, network, and protected first-boot seed

**Files:** Create `modules/MediaKit.HyperV.psm1`, `build/New-CidataImage.ps1`, `tests/HyperV.Tests.ps1`, and `tests/fixtures/seed/`.

**Interfaces:** Consume config, manifest, native service/share ownership from Tasks 1/2. Produce `New-KitNetwork($Config)`, `New-KitVM($Config,$Manifest)`, `New-KitSeed($GuestConfig,$SecretFiles,$OutputPath)`, `Wait-KitGuest($Config,$TimeoutSeconds)`, and `Invoke-KitGuest($Config,$Command,$InputFile)`. The seed carries per-install SSH public key, config, MAC-matched networking and restricted credential files; persisted host checkpoints carry none of them.

- [ ] Write tests for conflicting resources/subnets, preservation of an unrelated existing switch/VM, literal special-character paths, secret-free public checkpoint/network config, unique seed instance IDs, and both NICs with gateway/DNS only on the external NIC. Verify reruns reuse only resources bearing the matching installation ownership record.
- [ ] Run `pwsh -NoProfile -Command "Invoke-Pester starter-kit/windows/tests/HyperV.Tests.ps1 -CI"`; expect failures for missing provisioning functions.
- [ ] Implement Generation 2 VM provisioning with the Linux Secure Boot template and fixed resource defaults; choose nonoverlapping internal addressing and wired external adapter. Set automatic Start/delay/graceful shutdown, attach separate app-state VHDX, and build CIDATA using Windows image APIs without a development HTTP server. Establish per-install SSH trust, discover guest readiness, and safely detach/delete secret seed after verified provisioning. Guest hostname discovery and status remain usable without host login.
- [ ] Run Pester tests and seed extraction/validation; expect matching public contract, protected secret locations, and no incorrect routes. Commit and push; record real Hyper-V boot/discovery as Task 8 validation.

## Task 4: Guest provisioning, media checks, and daemon startup

**Files:** Create `guest/{bootstrap.py,storage.py,secrets.py,compose.yml}`, `guest/systemd/{data.mount,starter-kit-state.mount,storage-retry.service,storage-retry.timer}`, `guest/systemd/docker.service.d/storage.conf`, and `guest/tests/{test_bootstrap.py,test_storage.py,test_secrets.py}`.

**Interfaces:** Consume `BootstrapConfig`, restricted SMB credential input, release manifest and empty app-state disk. Produce `bootstrap.py validate|apply|status`, `storage.py verify|probe-hardlinks`, atomic `create_once(path,installation_id,value)` secret storage, and installed mount/systemd/Compose state. Persist credentials under root-only `/etc/starter-kit/`; state disk uses a fixed label/verified filesystem UUID and mounts at `/var/lib/starter-kit`.

- [ ] Write unittest cases that reject malformed IP/MAC/timezone/credential references before mutation; reject nonregular/world-readable credential files; preserve existing credentials on interrupted resume; and reject wrong mount source/type/installation marker. Simulated mount inspectors are the OS boundary; probes and writes use real temporary files. Ensure the CLI sanitizes exceptions/status.
- [ ] Run `python3 -m unittest discover -s starter-kit/windows/guest/tests -v`; expect missing-function/module failures attributable to unimplemented behavior.
- [ ] Implement strict bootstrap, empty-disk initialization protection, SMB mount ownership, root-only underlying `/data`, ext4 appstate, Avahi on the MAC-matched external NIC, and Docker daemon `RequiresMountsFor`/ordering/`BindsTo` checks including socket activation. Add bounded health/retry behavior for an unavailable share; verify expected source/marker plus read-write probe before daemon startup. Render Compose with common `/data`, persistent ext4 configs and one selected downloader profile; no personal auth bypass or populated databases.
- [ ] Rerun guest unittests and a Linux systemd VM integration test that removes/replaces/reconnects SMB and appstate; expect Docker blocked for invalid storage, no OS-disk downloads, and recovery after the proper share returns. Commit and push.

## Task 5: App credentials, preferences, and connection setup

**Files:** Create `guest/api_setup.py`, `guest/templates/{configarr.yml,qbittorrent.conf,sabnzbd.ini}`, `guest/tests/test_api_setup.py`, and pinned API fixtures under `guest/tests/fixtures/`.

**Interfaces:** Consume guest config, manifest, persistent secrets and verified storage from Task 4. Produce `configure_apps(config,transport)->SetupResult` and `verify_apps(config,transport)->HealthReport`, with bounded readiness retries and managed-resource reconciliation. Configarr manages quality/naming; Python manages roots/downloaders/Prowlarr so experimental Configarr integrations do not become required dependencies.

- [ ] Write fixture-driven tests that capture real adapter request payloads: `rootfolder` paths `/data/media/tv` and `/data/media/movies`; correct downloader host/category; Prowlarr schema-based Sonarr/Radarr fields; repeat setup without duplicate IDs/deleting unrelated clients; preserve keys on failure/retry; and no secret values in error/status output. Separate qBit and SAB fixtures must expose complete documented response structures.
- [ ] Run the guest unittest command; expect missing adapter/reconciliation failures.
- [ ] Implement fresh protected Arr/Prowlarr/downloader auth before LAN exposure, authenticated qBit API login/category/path setup or SAB version/config/category setup, Arr v3 schemas/client tests, and Prowlarr v1 application schemas/tests. Apply the actual-container hardlink probe to `copyUsingHardlinks`; select copy import with storage guidance on failure. Run pinned Configarr templates and read back profile/naming/cutoff. After interactive Plex/Seerr sign-in, configure supported Seerr integration APIs where available and guide remaining library selection; report account/provider steps as pending until actually verified.
- [ ] Run unittests and real pinned-container integration runs for each downloader, including failure/resume and Configarr readback; expect exactly one downloader and successful Arr connection tests. Any HTTP development test server started during execution must have the required quick tunnel for its lifetime. Commit and push.

## Task 6: Wizard handoff and maintenance commands

**Files:** Create `Install.cmd`, `Install.ps1`, `Maintenance.ps1`, `modules/MediaKit.Maintenance.psm1`, `guest/{backup.py,restore.py}`, `tests/{Install.Tests.ps1,Maintenance.Tests.ps1}`, and `guest/tests/test_backup.py`.

**Interfaces:** Consume all completed host/guest interfaces. Produce the guided entrypoint and `Maintenance.ps1 -Action Status|OpenRequests|OpenPlex|Backup|Restore|Update|Uninstall`. Backups carry installation/release identity, checksums, native Plex profile/HKCU data and stopped guest appstate/secrets; media is excluded by default.

- [ ] Write tests for restart/resume after Hyper-V enablement, bounded readiness timeouts with actionable status, unresolved account setup remaining pending, shortcut address discovery, backup failure restarting stopped services, mismatched-release/identity restoration rejection, archive traversal rejection, and uninstall removing only owned resources while preserving media/backups.
- [ ] Run all Pester and guest unittest suites; expect the new wizard/maintenance behavior to fail before implementation.
- [ ] Implement elevation, safe selected-disk/network summary, secure credential prompts, checkpoints, claim/request handoff and shortcuts. Backup native Plex consistently while its service is stopped, with profile-aware preferences export; stop guest apps before archiving and restart in guaranteed cleanup. Restore only validated matching state, recheck mounts/integrations, and require an explicit matching backup for downgrade. Updates install manifest-pinned binaries/images/configuration after backup and checks; uninstall preserves user data. Keep product prompts focused on storage, accounts and progress.
- [ ] Rerun all suites and a real backup/mutate/restore integration check; expect recovered credentials/IDs, unchanged media, and no orphaned stopped services after failure. Commit and push.

## Task 7: Reproducible appliance, release ZIP, and build automation

**Files:** Create `build/{appliance.pkr.hcl,build-appliance.sh,package.py,refresh-manifest.py}`, `build/autoinstall/{user-data,meta-data}`, `release.json`, `tests/test_package.py`, `.github/workflows/windows-plex-kit.yml`, and kit `README.md`/`VALIDATION.md`.

**Interfaces:** Consume all kit source and verified wrapper MSI. Produce generalized `media-kit.vhdx`, complete `release.json`, `media-kit-windows.zip`, checksums, and an asset/build report. `package.py build|verify` includes only explicitly listed assets and checks every manifest reference exists with the recorded digest.

- [ ] Write unittest cases that build/extract a real fixture ZIP and reject extra files, symlinks, path traversal, missing artifacts, mismatched digests, populated appdata/credentials and inappropriate private-repo dependencies. Test deterministic archive contents/metadata and preservation of required license notices.
- [ ] Run `python3 -m unittest discover -s starter-kit/windows/tests -p 'test_*.py' -v`; expect missing package builder behavior.
- [ ] Build from `ubuntu-24.04.5-live-server-amd64.iso`, pinned SHA-256 `97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8`, with publisher signature verification. Use Packer QEMU plugin 1.1.7, UEFI, attached autoinstall CIDATA and no HTTP seed server; provision Docker/cloud-init/guest source, remove builder identity/secrets/cache and generalize before shutdown. Convert to VHDX and verify image format/boot. Resolve supported current official native installers and container tags during manifest refresh, record SHA-256/digests/template commits, and commit the complete tested manifest; never resolve mutable `latest` during friend installation. CI separates Linux image/guest checks from Windows wrapper/PowerShell builds, then assembles ZIP/artifacts with no publishing of a stable release before Task 8 gates pass.
- [ ] Run package tests, Packer validation/build, artifact verification, PowerShell parse/Pester on Windows 5.1 and 7, and clean-image boot smoke checks; expect verified ZIP and generalized companion image. Commit and push source, manifest and CI; retain large generated files as build artifacts rather than Git blobs.

## Task 8: Full review, Windows acceptance, and PR completion

**Files:** Update root `README.md`, the approved spec's implementation status, kit `README.md`/`VALIDATION.md`, and PR #21 title/body to describe the built installer.

**Interfaces:** Consume the verified ZIP/image/manifest and test reports. Produce a reviewed PR with direct install/download instructions, exact validation evidence and explicit unresolved target-machine checks.

- [ ] Run the complete kit suites, the repository's `bash tests/storage-maintenance-test.sh`, shell/PowerShell syntax checks, Compose validation for both downloader selections, release verification and `git diff --check`. Expect all available checks passing; record any unavailable Windows capability separately.
- [ ] Obtain a fresh whole-branch review against the spec, plan, shared contracts and Review Focus. Fix material findings with a failing regression test followed by green suite runs. Rebuild artifacts after relevant fixes.
- [ ] Run the target Windows acceptance procedure: fresh install on the 8 GB OptiPlex; cold reboot without sign-in; access Plex/Requests from another device; submit/import playable media; change guest DHCP address; force Plex hardware transcode and confirm `(hw)` with Plex Pass; update/reboot; backup/restore. Record machine, versions and results. These checks require access to the actual Windows machine and cannot be replaced with mocks.
- [ ] Commit/push documentation and final fixes, update PR #21, and link the generated artifact. If target access is unavailable, deliver the built candidate with the exact unverified checks and keep stable release publication pending; do not claim unattended Windows/GPU operation is proven. Merge remains a separate user action.

## Plan self-review

The host/guest projection and release manifest connect Tasks 1-7 through one versioned contract. Task 2's Windows profile owns native Plex claim/backup state; Task 4's ext4 disk owns guest appstate, and Task 6 backs up both. Task 4 controls Docker startup before Task 5's app restart policies can run. Tasks 3/4 implement the stable hostname; Task 8 verifies access after DHCP changes without host login. The source/build checks and actual-machine acceptance gates are deliberately distinct.

Implementation can be divided into three bounded ownership groups after this plan is reviewed: Windows provisioning/wizard, guest runtime/configuration, and appliance/wrapper/release tooling. Common contracts are implemented first; integrations and final review follow the component work.
