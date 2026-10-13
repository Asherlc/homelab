Set-StrictMode -Version 2.0
$script:Context = $null
function Assert-KitFields($Object, [string[]]$Required, [string[]]$Optional=@()) {
    if ($null -eq $Object) { throw 'Required configuration object is missing.' }
    $names = @($Object.PSObject.Properties.Name)
    if ($Object -is [System.Collections.IDictionary]) { $names = @($Object.Keys) }
    foreach ($key in $Required) { if ($names -notcontains $key -or $null -eq $Object.$key) { throw "Required field missing: $key" } }
    foreach ($key in $names) { if (($Required+$Optional) -notcontains $key) { throw "Unknown public field: $key" } }
}
function ConvertTo-KitIPv4Number([string]$Address) {
    $ip=$null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw 'Invalid IPv4 address.' }
    $b=$ip.GetAddressBytes(); return [uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]
}
function Get-KitSubnetRange([string]$Cidr) {
    $p=$Cidr.Split('/'); if ($p.Count -ne 2 -or $p[1] -notmatch '^\d+$' -or [int]$p[1] -gt 32) { throw 'Invalid IPv4 subnet.' }
    $size=[uint64][Math]::Pow(2,32-[int]$p[1]); $n=ConvertTo-KitIPv4Number $p[0]
    $start=[uint64]([Math]::Floor($n/$size)*$size); return @{Start=$start;End=$start+$size-1}
}
function Test-KitWindowsPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\[^<>:"|?*\x00-\x1f]+$' -or $Path -match '(?:^|\\)\.\.?($|\\)' -or $Path -match '[ .](?:\\|$)') { throw 'Select a literal absolute path on a local Windows disk.' }
    return $true
}
function Test-KitConfig($Config) {
    Assert-KitFields $Config @('schemaVersion','installationId','releaseId','hostname','timezone','downloader','mediaRoot','vmRoot','vmName','externalSwitchName','internalSwitchName','externalAdapterName','hostIP','guestIP','prefixLength','network','smb','plex','sshPublicKey','guestHostPublicKey')
    if ($Config.schemaVersion -ne 1) { throw 'Unsupported installation schema.' }
    $id=[guid]::Empty; if(-not [guid]::TryParse($Config.installationId,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Invalid installation identity.' }
    if ($Config.releaseId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$' -or $Config.hostname -notmatch '^[a-z][a-z0-9-]{1,61}[a-z0-9]$') { throw 'Invalid release or guest hostname.' }
    if (@('qbittorrent','sabnzbd') -notcontains $Config.downloader) { throw 'Choose one supported downloader.' }
    $schema=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../schemas/bootstrap.schema.json')) | ConvertFrom-Json
    if ($schema.properties.timezone.enum -notcontains $Config.timezone) { throw 'Select a valid IANA timezone.' }
    Test-KitWindowsPath $Config.mediaRoot | Out-Null; Test-KitWindowsPath $Config.vmRoot | Out-Null
    $a=$Config.mediaRoot.TrimEnd('\'); $b=$Config.vmRoot.TrimEnd('\')
    if ($a -eq $b -or $a.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Media and VM directories must be separate.' }
    foreach($name in @($Config.vmName,$Config.externalSwitchName,$Config.internalSwitchName)) {if($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}$') {throw 'Unsafe resource name.'}}
    if ([string]::IsNullOrWhiteSpace($Config.externalAdapterName)) { throw 'Select a wired network adapter.' }
    if ($Config.prefixLength -ne 30) { throw 'The private link requires a /30 subnet.' }
    $range=Get-KitSubnetRange "$($Config.hostIP)/$($Config.prefixLength)"; $h=ConvertTo-KitIPv4Number $Config.hostIP; $g=ConvertTo-KitIPv4Number $Config.guestIP
    if($h -eq $g -or $h -le $range.Start -or $h -ge $range.End -or $g -le $range.Start -or $g -ge $range.End) {throw 'Host and guest must be distinct usable addresses in one subnet.'}
    if ($Config.hostIP -notmatch '^172\.29\.\d+\.1$' -or $Config.guestIP -notmatch '^172\.29\.\d+\.2$') {throw 'Private link must use the installer reserved 172.29.x.0/30 range.'}
    Assert-KitFields $Config.network @('internalMac','externalMac')
    foreach($mac in @($Config.network.internalMac,$Config.network.externalMac)) {if($mac -notmatch '^00155D[0-9A-Fa-f]{6}$') {throw 'Invalid Hyper-V MAC address.'}}
    if ($Config.network.internalMac -eq $Config.network.externalMac) {throw 'NIC MAC addresses must differ.'}
    Assert-KitFields $Config.smb @('account','domain','share','credentialsRef'); Assert-KitFields $Config.plex @('account')
    foreach($name in @($Config.smb.account,$Config.plex.account)) {if($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{1,19}$') {throw 'Unsafe local account name.'}}
    if ($Config.smb.account -eq $Config.plex.account -or $Config.smb.domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$' -or $Config.smb.share -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{1,79}$' -or $Config.smb.credentialsRef -ne '/run/starter-kit-secrets/smb.credentials') { throw 'Unsafe SMB configuration.' }
    foreach($key in @($Config.sshPublicKey,$Config.guestHostPublicKey)) {if($key -and $key -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?$') {throw 'Invalid SSH public key.'}}
    return $true
}
function Test-KitManifest($Manifest) {
    Assert-KitFields $Manifest @('schemaVersion','releaseId','minimumWindowsBuild','artifacts','images','templateRevisions','files') @('candidate','validation','builtAt','source')
    if($Manifest.schemaVersion -ne 1 -or $Manifest.minimumWindowsBuild -lt 22631 -or $Manifest.releaseId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$') {throw 'Unsupported release manifest.'}
    foreach($key in @('plex','wrapper','appliance')) {
        $a=$Manifest.artifacts.$key; Assert-KitFields $a @('filename','sha256','architecture') @('url','publisher','version','source')
        $expectedArchitecture='amd64'; if($key -eq 'wrapper') {$expectedArchitecture='x86'}
        if($a.filename -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or $a.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $a.architecture -ne $expectedArchitecture) {throw 'Invalid release artifact.'}
        if($a.PSObject.Properties.Name -contains 'url' -and $a.url -and ([uri]$a.url).Scheme -ne 'https') {throw 'Artifact URLs require HTTPS.'}
        if($key -eq 'plex' -and (-not ($a.PSObject.Properties.Name -contains 'publisher') -or -not $a.publisher)) {throw 'Plex requires an expected Authenticode publisher.'}
    }
    foreach($key in @('sonarr','radarr','prowlarr','seerr','qbittorrent','sabnzbd','configarr')) {if($Manifest.images.$key -notmatch '^[^\s]+@sha256:[0-9a-f]{64}$') {throw 'Container images require immutable SHA-256 digests.'}}
    foreach($key in @('trash','recyclarr')) {if($Manifest.templateRevisions.$key -notmatch '^[0-9a-f]{40}$') {throw 'Template revisions must be full commit identifiers.'}}
    if (@($Manifest.files).Count -eq 0) {throw 'Release allowlist is empty.'}
    foreach($file in $Manifest.files) {if($file -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_./-]*$' -or $file -match '(^|/)\.\.(/|$)') {throw 'Unsafe release asset path.'}}
    return $true
}
function Get-KitGuestConfig($Config) {
    Test-KitConfig $Config | Out-Null; $g=[ordered]@{}
    foreach($key in @('schemaVersion','installationId','releaseId','hostname','timezone','downloader','hostIP','guestIP','prefixLength','network','smb')) {$g[$key]=$Config.$key}
    return [pscustomobject]$g
}
function Get-KitCheckpoint([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) {return $null}
    $s=[IO.File]::ReadAllText($Path) | ConvertFrom-Json
    Assert-KitFields $s @('schemaVersion','config','phase','completed','resources') @('pending','lastBackup','previousRelease','rebootRequired','update')
    Test-KitConfig $s.config | Out-Null; return $s
}
function Save-KitCheckpoint([string]$Path,$Checkpoint) {
    Assert-KitFields $Checkpoint @('schemaVersion','config','phase','completed','resources') @('pending','lastBackup','previousRelease','rebootRequired','update')
    if($Checkpoint.schemaVersion -ne 1) {throw 'Unsupported checkpoint schema.'}
    Test-KitConfig $Checkpoint.config | Out-Null
    if($Checkpoint.PSObject.Properties.Name -contains 'update') {
        Assert-KitFields $Checkpoint.update @('originalReleaseId','targetReleaseId','backupPath','manifestSha256','phase','matchingRestorePath')
        foreach($key in @('originalReleaseId','targetReleaseId')) {if($Checkpoint.update.$key -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$') {throw 'Invalid update release identity.'}}
        if($Checkpoint.update.manifestSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Checkpoint.update.phase -notin @('native','guest')) {throw 'Invalid update checkpoint.'}
    }
    foreach($r in $Checkpoint.resources) {Assert-KitFields $r @('type','name','installationId') @('sid','path','productCode'); if($r.installationId -ne $Checkpoint.config.installationId) {throw 'Resource ownership identity differs from the installation.'}}
    $previous=Get-KitCheckpoint $Path
    if($previous -and $previous.config.installationId -ne $Checkpoint.config.installationId) {throw 'Checkpoint installation identity cannot change.'}
    if($previous) {
        foreach($field in $previous.config.PSObject.Properties.Name) {
            if($field -in @('releaseId','sshPublicKey','guestHostPublicKey')) {continue}
            if(($previous.config.$field|ConvertTo-Json -Depth 10 -Compress) -cne ($Checkpoint.config.$field|ConvertTo-Json -Depth 10 -Compress)) {throw "Selected configuration field '$field' cannot change during resume."}
        }
        foreach($key in @('sshPublicKey','guestHostPublicKey')) {if($previous.config.$key -and $previous.config.$key -ne $Checkpoint.config.$key) {throw 'Pinned SSH identity cannot change during resume.'}}
    }
    if($previous) {foreach($id in $previous.completed) {if(@($Checkpoint.completed) -notcontains $id) {throw 'Completed operations cannot be discarded.'}}}
    $parent=Split-Path $Path -Parent; if($parent) {[IO.Directory]::CreateDirectory($parent) | Out-Null}
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($tmp,($Checkpoint | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path) {[IO.File]::Replace($tmp,$Path,[Management.Automation.Language.NullString]::Value)} else {[IO.File]::Move($tmp,$Path)}
    } finally {if(Test-Path -LiteralPath $tmp) {Remove-Item -LiteralPath $tmp -Force}}
}
function Set-KitContext([string]$Path,$Checkpoint) {$script:Context=@{Path=$Path;State=$Checkpoint}}
function Get-KitContext {if(-not $script:Context) {throw 'Installer context has not been initialized.'}; return $script:Context}
function Get-KitArtifactDirectory([string]$ReleaseId) {
    if($ReleaseId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$') {throw 'Invalid artifact release identity.'}
    $ctx=Get-KitContext; return Join-Path (Join-Path (Split-Path $ctx.Path -Parent) 'artifacts') $ReleaseId
}
function Register-KitResource([string]$Type,[string]$Name,[string]$Sid='',[string]$Path='',[string]$ProductCode='') {
    $ctx=Get-KitContext; $c=$ctx.State.config
    $existing=@($ctx.State.resources | Where-Object {$_.type -eq $Type -and $_.name -eq $Name})
    if($existing.Count) {Assert-KitOwnership $Type $Name $c.installationId $ctx.State.resources | Out-Null; return}
    $r=[ordered]@{type=$Type;name=$Name;installationId=$c.installationId}
    if($Sid) {$r.sid=$Sid}; if($Path) {$r.path=$Path}; if($ProductCode) {$r.productCode=$ProductCode}
    $ctx.State.resources=@($ctx.State.resources)+[pscustomobject]$r; Save-KitCheckpoint $ctx.Path $ctx.State
}
function Assert-KitOwnership([string]$Type,[string]$Name,[string]$InstallationId,$Resources) {
    $owned=@($Resources | Where-Object {$_.type -eq $Type -and $_.name -eq $Name -and $_.installationId -eq $InstallationId})
    if($owned.Count -ne 1) {throw "Existing $Type '$Name' is not owned by this installation. Choose a different name or remove the conflict manually."}
    return $true
}
function Invoke-KitOperation([string]$Path,$State,[string]$Id,[scriptblock]$Action) {
    if(@($State.completed) -contains $Id) {return}
    $State.phase=$Id; Save-KitCheckpoint $Path $State
    & $Action | Out-Null
    $State.completed=@($State.completed)+$Id; Save-KitCheckpoint $Path $State
}
function Get-KitPreflight($HostFacts,$Config) {
    Test-KitConfig $Config | Out-Null; $errors=@(); $warnings=@()
    if(-not $HostFacts.IsAdmin) {$errors+='Run Install.cmd as administrator.'}
    if($HostFacts.Edition -notmatch '^(Professional|Enterprise|Education)$' -or $HostFacts.Build -lt 22631) {$errors+='Windows 11 Pro/Enterprise/Education build 22631 or newer is required.'}
    if($HostFacts.Architecture -ne 'AMD64') {$errors+='An x64 Windows host is required.'}
    if($HostFacts.MemoryBytes -lt 8GB) {$errors+='At least 8 GB host memory is required.'} elseif($HostFacts.MemoryBytes -lt 16GB) {$warnings+='16 GB RAM and an SSD are recommended for smoother imports.'}
    if(-not $HostFacts.Virtualization) {$errors+='Enable CPU virtualization in firmware, then rerun Install.cmd.'}
    if($HostFacts.FreeBytes -lt 80GB) {$errors+='At least 80 GB free space is required for VM disks and installation.'}
    $errors+=@($HostFacts.Conflicts)
    return [pscustomobject]@{Ready=($errors.Count -eq 0);Errors=$errors;Warnings=$warnings}
}
function Get-KitHostFacts($Config) {
    $os=Get-CimInstance Win32_OperatingSystem; $cpu=@(Get-CimInstance Win32_Processor); $computer=Get-CimInstance Win32_ComputerSystem
    $edition=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    $drive=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='"+$Config.vmRoot.Substring(0,2)+"'")
    $conflicts=@(); $ctx=Get-KitContext
    $existingPlex=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -eq 'Plex Media Server'}
    if($existingPlex -and -not @($ctx.State.resources | Where-Object {$_.type -eq 'plex-install'}).Count) {$conflicts+='An existing Plex installation requires manual migration; it will not be adopted.'}
    foreach($port in @(32400)) {if(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {if(-not @($ctx.State.resources | Where-Object {$_.type -eq 'service' -and $_.name -eq 'PlexService'}).Count) {$conflicts+='Port 32400 is already in use.'}}}
    return @{IsAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);Edition=$edition;Build=[int]$os.BuildNumber;Architecture=$env:PROCESSOR_ARCHITECTURE;MemoryBytes=[long]$computer.TotalPhysicalMemory;Virtualization=($computer.HypervisorPresent -or @($cpu | Where-Object {$_.VirtualizationFirmwareEnabled}).Count -gt 0);FreeBytes=[long]$drive.FreeSpace;Conflicts=$conflicts}
}
Export-ModuleMember -Function *-Kit*
