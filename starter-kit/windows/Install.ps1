#requires -Version 5.1
[CmdletBinding()]
param([string]$StatePath=(Join-Path $env:ProgramData 'MediaKit\state.json'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
foreach($name in @('Common','Artifacts','Secrets','UserHive','Windows','HyperV','Maintenance')) {Import-Module (Join-Path $PSScriptRoot "modules\MediaKit.$name.psm1")}
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $args='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-KitWindowsArgument $PSCommandPath)+' -StatePath '+(ConvertTo-KitWindowsArgument $StatePath)
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait
        exit
    }
    $state=Get-KitCheckpoint $StatePath
    $releasePath=Join-Path $PSScriptRoot 'release.json'; $release=Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json; Test-KitManifest $release | Out-Null
    if($state -and $state.config.releaseId -ne $release.releaseId) {
        $releasePath=Join-Path (Split-Path $StatePath -Parent) 'release.json'
        if(-not (Test-Path -LiteralPath $releasePath)) {throw 'This installation belongs to another release. Use its original kit to resume, or Maintenance Update after setup is complete.'}
        $release=Get-Content -LiteralPath $releasePath -Raw|ConvertFrom-Json; Test-KitManifest $release|Out-Null
        if($release.releaseId -ne $state.config.releaseId) {throw 'Persisted release does not match the installation.'}
    }
    if(-not $state) {
        Write-Host 'Media Kit will create a Windows Plex service and a Linux companion VM. Existing media files will be preserved.'
        $media=Read-Host 'Media folder (Enter for C:\MediaStack\data)'; if(-not $media) {$media='C:\MediaStack\data'}
        $vmRoot=Read-Host 'VM folder (Enter for C:\MediaStack\vm)'; if(-not $vmRoot) {$vmRoot='C:\MediaStack\vm'}
        $timezone=Read-Host 'IANA timezone (Enter for America/Los_Angeles)'; if(-not $timezone) {$timezone='America/Los_Angeles'}
        $downloader=Read-Host 'Downloader: qbittorrent or sabnzbd (Enter for qbittorrent)'; if(-not $downloader) {$downloader='qbittorrent'}
        $adapters=@(Get-NetAdapter -Physical | Where-Object {$_.Status -eq 'Up' -and $_.PhysicalMediaType -in @('802.3',14)})
        if(-not $adapters.Count) {throw 'Connect a wired Ethernet adapter before installing.'}
        for($i=0;$i -lt $adapters.Count;$i++) {Write-Host "$($i+1). $($adapters[$i].Name)"}
        $selection=Read-Host 'Wired adapter number (Enter for 1)'; if(-not $selection) {$selection='1'}
        if($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $adapters.Count) {throw 'Select one of the listed wired adapter numbers.'}
        $id=[guid]::NewGuid().ToString(); $suffix=$id.Substring(0,8)
        $routes=@(Get-NetRoute -AddressFamily IPv4 | Where-Object {$_.DestinationPrefix -ne '0.0.0.0/0'} | Select-Object -ExpandProperty DestinationPrefix)
        $subnet=Select-KitSubnet $routes
        $random=New-Object byte[] 6; $rng=[Security.Cryptography.RandomNumberGenerator]::Create(); try {$rng.GetBytes($random)} finally {$rng.Dispose()}
        $mac1='00155D'+([BitConverter]::ToString($random[0..2]).Replace('-','')); $mac2='00155D'+([BitConverter]::ToString($random[3..5]).Replace('-',''))
        $config=[pscustomobject]@{schemaVersion=1;installationId=$id;releaseId=$release.releaseId;hostname="media-$suffix";timezone=$timezone;downloader=$downloader;mediaRoot=$media;vmRoot=$vmRoot;vmName="MediaKit-$suffix";externalSwitchName="MediaKit-LAN-$suffix";internalSwitchName="MediaKit-Private-$suffix";externalAdapterName=$adapters[[int]$selection-1].Name;hostIP=$subnet.hostIP;guestIP=$subnet.guestIP;prefixLength=30;network=[pscustomobject]@{internalMac=$mac1;externalMac=$mac2};smb=[pscustomobject]@{account="media-smb-$suffix";domain=$env:COMPUTERNAME;share="MediaKit-$suffix";credentialsRef='/run/starter-kit-secrets/smb.credentials'};plex=[pscustomobject]@{account="media-plex-$suffix"};sshPublicKey='';guestHostPublicKey=''}
        Test-KitConfig $config | Out-Null
        Write-Host "Media: $media`nVM: $vmRoot (two 32 GB expanding disks; 3 GB RAM; 2 CPUs)`nAdapter: $($config.externalAdapterName)`nDownloader: $downloader"
        $state=[pscustomobject]@{schemaVersion=1;config=$config;phase='preflight';completed=@();resources=@();pending=@('Plex sign-in and libraries','Seerr sign-in and library selection','Provider/indexer credentials','Cold boot and Quick Sync verification')}
        Save-KitCheckpoint $StatePath $state
    }
    if($state.phase -eq 'uninstalled') {throw 'This installation was uninstalled. Preserve or rename its state directory before starting a new installation.'}
    Set-KitContext $StatePath $state; $config=$state.config
    Protect-KitPath (Split-Path $StatePath -Parent)
    $preflight=Get-KitPreflight (Get-KitHostFacts $config) $config
    foreach($warning in $preflight.Warnings) {Write-Host $warning}
    if(-not $preflight.Ready) {throw ($preflight.Errors -join "`n")}
    # Persist the final tested manifest; no private repository lookup is needed.
    $persistedRelease=Join-Path (Split-Path $StatePath -Parent) 'release.json'
    if([IO.Path]::GetFullPath($releasePath) -ne [IO.Path]::GetFullPath($persistedRelease)) {Copy-Item -LiteralPath $releasePath -Destination $persistedRelease -Force}
    Invoke-KitOperation $StatePath $state 'hyperv-enable' {
        $feature=Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
        if($feature.State -ne 'Enabled') {
            $result=Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
            if($result.RestartNeeded) {$state|Add-Member -NotePropertyName rebootRequired -NotePropertyValue $true -Force}
        }
    }
    if($state.PSObject.Properties.Name -contains 'rebootRequired' -and $state.rebootRequired) {
        if(-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
            Write-Host 'Hyper-V is enabled. Restart Windows, then run Install.cmd again to continue with these same choices.'
            $restart=Read-Host 'Enter R to restart now, or Enter to restart later'; if($restart -eq 'R') {Restart-Computer}
            exit
        }
        $state.rebootRequired=$false; Save-KitCheckpoint $StatePath $state
    }
    Import-Module Hyper-V
    Invoke-KitOperation $StatePath $state 'ssh-client' {
        if(-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
            $result=Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
            if($result.RestartNeeded) {throw 'OpenSSH requires a restart. Restart Windows and rerun Install.cmd.'}
        }
    }
    Invoke-KitOperation $StatePath $state 'artifacts' {
        foreach($key in @('plex','wrapper','appliance')) {Save-KitVerifiedArtifact $release.artifacts.$key (Join-Path (Join-Path (Split-Path $StatePath -Parent) 'artifacts') $release.artifacts.$key.filename) -AssetDirectory $PSScriptRoot | Out-Null}
    }
    $plexCredential=Get-KitCredential 'plex' "$($config.smb.domain)\$($config.plex.account)"
    $smbCredential=Get-KitCredential 'smb' "$($config.smb.domain)\$($config.smb.account)"
    Invoke-KitOperation $StatePath $state 'accounts' {New-KitServiceIdentity $config.plex.account $plexCredential.Password | Out-Null; New-KitServiceIdentity $config.smb.account $smbCredential.Password | Out-Null}
    Invoke-KitOperation $StatePath $state 'media-share' {New-KitMediaShare $config $smbCredential}
    Invoke-KitOperation $StatePath $state 'plex-install' {Install-KitPlex $config $release}
    Invoke-KitOperation $StatePath $state 'plex-service' {Install-KitPlexService $config $release.artifacts.wrapper $plexCredential}
    Invoke-KitOperation $StatePath $state 'network' {New-KitNetwork $config}
    Invoke-KitOperation $StatePath $state 'vm' {New-KitVM $config $release | Out-Null}
    $seedPath=Join-Path (Get-KitSecretDirectory) 'cidata.iso'
    Invoke-KitOperation $StatePath $state 'seed' {
        New-KitSshIdentity $config
        $password=$smbCredential.GetNetworkCredential().Password
        try {
            $files=@{'smb.credentials'="username=$($config.smb.account)`npassword=$password`ndomain=$($config.smb.domain)`n";'ssh_host_ed25519_key'=(Get-Content -LiteralPath (Join-Path (Get-KitSecretDirectory) 'guest-host') -Raw)}
            New-KitSeed (Get-KitGuestConfig $config) $files $seedPath | Out-Null
        } finally {$password=$null;$files=$null}
        if(-not @(Get-VMDvdDrive -VMName $config.vmName | Where-Object {$_.Path -eq $seedPath}).Count) {Add-VMDvdDrive -VMName $config.vmName -Path $seedPath}
    }
    if((Get-VM -Name $config.vmName).State -ne 'Running') {Start-VM -Name $config.vmName}
    Invoke-KitOperation $StatePath $state 'guest' {Wait-KitGuest $config | Out-Null; Invoke-KitGuest $config 'apply' | Out-Null; Complete-KitSeed $config $seedPath | Out-Null}
    $kitDirectory=Join-Path (Split-Path $StatePath -Parent) 'kit'
    Invoke-KitOperation $StatePath $state 'shortcuts' {
        [IO.Directory]::CreateDirectory($kitDirectory) | Out-Null
        foreach($asset in $release.files) {if($asset -match '^(modules/|schemas/|Install\.|Maintenance\.|release\.json)' -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot $asset))) {$target=Join-Path $kitDirectory $asset; [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null; Copy-Item -LiteralPath (Join-Path $PSScriptRoot $asset) -Destination $target -Force}}
        Copy-Item -LiteralPath $persistedRelease -Destination (Join-Path $kitDirectory 'release.json') -Force
        New-KitShortcuts $config $kitDirectory
    }
    $state.phase='account-handoff'; Save-KitCheckpoint $StatePath $state
    Write-Host "Background services are configured. Requests: $(Get-KitRequestsUrl $config)"
    Write-Host "Create Plex Movies library at $(Join-Path $config.mediaRoot 'media\movies') and TV library at $(Join-Path $config.mediaRoot 'media\tv')."
    Write-Host 'Open Plex from the Media Kit shortcuts, sign into your own Plex account, then sign into Requests and select those libraries. Add your own provider/indexer details. Status keeps these steps pending until checked.'
    Write-Host 'Cold boot without Windows sign-in and Plex hardware transcoding still require verification on this machine.'
} catch {
    # Boundary implementations emit sanitized errors; avoid exception objects/stack logs.
    Write-Host ('Setup paused: '+$_.Exception.Message)
    Write-Host 'Your installation choices and completed steps were saved. Fix the reported issue, then run Install.cmd again.'
    exit 1
}
