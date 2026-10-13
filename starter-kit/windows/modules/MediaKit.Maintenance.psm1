Set-StrictMode -Version 2.0
function Get-KitRequestsUrl($Config) {return "http://$($Config.hostname).local:5055"}
function ConvertFrom-KitCredentialPayload($Payload,$Config) {
    Assert-KitFields $Payload @('installationId','releaseId','credentials')
    if($Payload.installationId -ne $Config.installationId -or $Payload.releaseId -ne $Config.releaseId) {throw 'Credential handoff identity does not match this installation.'}
    $apps=@('sonarr','radarr','prowlarr',$Config.downloader); Assert-KitFields $Payload.credentials $apps
    $ports=@{sonarr=8989;radarr=7878;prowlarr=9696;qbittorrent=8080;sabnzbd=8080}; $result=@()
    foreach($app in $apps) {
        $entry=$Payload.credentials.$app; Assert-KitFields $entry @('username','password')
        if($entry.username -isnot [string] -or $entry.password -isnot [string] -or -not $entry.username -or -not $entry.password -or $entry.username -match '[\x00-\x1f]' -or $entry.password -match '[\x00-\x1f]') {throw 'Credential handoff contains an invalid web login.'}
        $result+=[pscustomobject]@{app=$app;username=$entry.username;password=$entry.password;url="http://$($Config.hostname).local:$($ports[$app])"}
    }
    return $result
}
function Show-KitCredentials($Config) {
    $ctx=Get-KitContext
    if($ctx.State.PSObject.Properties.Name -contains 'update') {throw 'Complete the pending update before viewing app credentials.'}
    # This private value is consumed only by the modal viewer. Do not Write-Host,
    # return it, pipe it to diagnostics, or use PowerShell transcription here.
    $payload=Invoke-KitGuest $Config 'credentials'; $entries=@(ConvertFrom-KitCredentialPayload $payload $Config); $payload=$null
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form; $form.Text='Media Kit app credentials'; $form.ClientSize=New-Object Drawing.Size(520,310); $form.StartPosition='CenterScreen'; $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $selector=New-Object Windows.Forms.ComboBox; $selector.Location=New-Object Drawing.Point(20,20); $selector.Size=New-Object Drawing.Size(480,28); $selector.DropDownStyle='DropDownList'
    foreach($entry in $entries) {$selector.Items.Add($entry.app)|Out-Null}
    $nameLabel=New-Object Windows.Forms.Label; $nameLabel.Text='Username'; $nameLabel.Location=New-Object Drawing.Point(20,65); $nameLabel.AutoSize=$true
    $username=New-Object Windows.Forms.TextBox; $username.Location=New-Object Drawing.Point(20,85); $username.Size=New-Object Drawing.Size(480,25); $username.ReadOnly=$true
    $passwordLabel=New-Object Windows.Forms.Label; $passwordLabel.Text='Password'; $passwordLabel.Location=New-Object Drawing.Point(20,120); $passwordLabel.AutoSize=$true
    $password=New-Object Windows.Forms.TextBox; $password.Location=New-Object Drawing.Point(20,140); $password.Size=New-Object Drawing.Size(480,25); $password.ReadOnly=$true; $password.UseSystemPasswordChar=$true
    $reveal=New-Object Windows.Forms.CheckBox; $reveal.Text='Reveal password'; $reveal.Location=New-Object Drawing.Point(20,175); $reveal.AutoSize=$true
    $copy=New-Object Windows.Forms.Button; $copy.Text='Copy password'; $copy.Location=New-Object Drawing.Point(340,175); $copy.Size=New-Object Drawing.Size(160,28)
    $url=New-Object Windows.Forms.LinkLabel; $url.Location=New-Object Drawing.Point(20,215); $url.Size=New-Object Drawing.Size(480,25)
    $hint=New-Object Windows.Forms.Label; $hint.Text='Copied passwords clear after 30 seconds or when this window closes.'; $hint.Location=New-Object Drawing.Point(20,250); $hint.Size=New-Object Drawing.Size(480,40)
    $clipboardState=@{Value=$null}; $timer=New-Object Windows.Forms.Timer; $timer.Interval=30000
    $clearClipboard={if($clipboardState.Value) {try {if([Windows.Forms.Clipboard]::ContainsText() -and [Windows.Forms.Clipboard]::GetText() -ceq $clipboardState.Value) {[Windows.Forms.Clipboard]::Clear()}} catch {}; $clipboardState.Value=$null}; $timer.Stop()}.GetNewClosure()
    $timer.Add_Tick($clearClipboard)
    $copy.Add_Click({try {$clipboardState.Value=$password.Text; [Windows.Forms.Clipboard]::SetText($clipboardState.Value); $timer.Stop(); $timer.Start()} catch {[Windows.Forms.MessageBox]::Show('Clipboard is busy. Reveal the password and enter it directly.','Media Kit')|Out-Null}}.GetNewClosure())
    $reveal.Add_CheckedChanged({$password.set_UseSystemPasswordChar(-not $reveal.Checked)}.GetNewClosure())
    $selector.Add_SelectedIndexChanged({$entry=$entries[$selector.SelectedIndex]; $reveal.Checked=$false; $username.Text=$entry.username; $password.Text=$entry.password; $url.Text=$entry.url}.GetNewClosure())
    $url.Add_LinkClicked({Start-Process -FilePath $url.Text}.GetNewClosure())
    $form.Controls.AddRange(@($selector,$nameLabel,$username,$passwordLabel,$password,$reveal,$copy,$url,$hint)); $selector.SelectedIndex=0
    try {$form.ShowDialog()|Out-Null}
    finally {& $clearClipboard; $timer.Dispose(); $password.Text=''; $username.Text=''; foreach($entry in $entries) {$entry.password=$null}; $entries=$null; $form.Dispose()}
}
function Assert-KitArchiveEntry([string]$Name) {
    if(-not $Name -or $Name.StartsWith('/') -or $Name.StartsWith('\') -or $Name -match '^[A-Za-z]:' -or $Name -match '(^|[\\/])\.\.([\\/]|$)' -or $Name -match '[\x00-\x1f]' -or $Name.Contains(':')) {throw 'Unsafe archive entry.'}
    return $true
}
function Test-KitBackupManifest($Manifest,$Config) {
    Assert-KitFields $Manifest @('schemaVersion','installationId','releaseId','files') @('createdAt','accountSid')
    if($Manifest.schemaVersion -ne 1 -or $Manifest.installationId -ne $Config.installationId -or $Manifest.releaseId -ne $Config.releaseId) {throw 'Backup installation/release does not match. Restore matching binaries and state together.'}
    foreach($entry in $Manifest.files) {
        Assert-KitFields $entry @('path','sha256'); Assert-KitArchiveEntry $entry.path | Out-Null
        if($entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {throw 'Invalid backup checksum.'}
    }
    return $true
}
function Get-KitUninstallPlan($Config,$Resources) {
    return @($Resources | Where-Object {$_.installationId -eq $Config.installationId -and $_.type -in @('vm','switch','share','service','firewall','account','shortcut')})
}
function Test-KitPlexRegistryExport([string]$Path,[string]$Sid) {
    $text=Get-Content -LiteralPath $Path -Raw
    if($text -notmatch '^Windows Registry Editor Version 5.00') {throw 'Invalid Plex registry export.'}
    $expected="HKEY_USERS\$Sid\Software\Plex, Inc.\Plex Media Server"
    $keys=[regex]::Matches($text,'(?m)^\[(-?[^\]\r\n]+)\]')
    if(-not $keys.Count) {throw 'Plex registry export has no profile keys.'}
    foreach($key in $keys) {
        $name=$key.Groups[1].Value
        if($name -ne $expected -and -not $name.StartsWith($expected+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Registry export includes a key outside the dedicated Plex account profile.'}
    }
    return $true
}
function New-KitBackup($Config,[string]$Destination) {
    $ctx=Get-KitContext; $user=Get-LocalUser $Config.plex.account; $profile=Get-KitProfilePath $user.SID.Value
    if($ctx.State.PSObject.Properties.Name -contains 'update') {throw 'Finish or restore the pending update before creating another backup.'}
    [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null; Protect-KitPath (Split-Path $Destination -Parent)
    $stage=Join-Path (Split-Path $Destination -Parent) ('backup-'+[guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($stage) | Out-Null; Protect-KitPath $stage
    $service=Get-Service PlexService; $wasRunning=$service.Status -eq 'Running'
    try {
        if($wasRunning) {Stop-Service PlexService -ErrorAction Stop; (Get-Service PlexService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))}
        $plex=Join-Path $stage 'plex'; [IO.Directory]::CreateDirectory($plex) | Out-Null
        $data=Join-Path $profile 'AppData\Local\Plex Media Server'
        if(-not (Test-Path -LiteralPath $data)) {throw 'The Plex service profile has not initialized; backup cannot continue.'}
        if(@(Get-ChildItem -LiteralPath $data -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {throw 'Plex profile backup refuses reparse points.'}
        Copy-Item -LiteralPath $data -Destination (Join-Path $plex 'data') -Recurse
        Invoke-KitUserHive $user.SID.Value {param($hive,$profilePath)
            $key="HKU\$($user.SID.Value)\Software\Plex, Inc.\Plex Media Server"
            & "$env:SystemRoot\System32\reg.exe" export $key (Join-Path $plex 'preferences.reg') /y | Out-Null
            if($LASTEXITCODE -ne 0) {throw 'Plex profile preferences could not be exported.'}
        }
        $backupName='host-backup-'+[guid]::NewGuid().ToString('N')+'.tar'
        $guest=Invoke-KitGuest $Config 'backup' -BackupName $backupName
        $encoded=Invoke-KitGuest $Config 'backup-download' -BackupName $backupName; $guestArchive=Join-Path $stage 'guest.tar'
        [IO.File]::WriteAllBytes($guestArchive,[Convert]::FromBase64String($encoded))
        if($guest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $guestArchive -Algorithm SHA256).Hash -ne $guest.sha256) {throw 'Guest backup transfer checksum verification failed.'}
        Invoke-KitGuest $Config 'backup-remove' -BackupName $backupName | Out-Null
        $hostDirectory=Join-Path $stage 'host'; [IO.Directory]::CreateDirectory($hostDirectory)|Out-Null
        Copy-Item -LiteralPath $ctx.Path -Destination (Join-Path $hostDirectory 'state.json')
        Copy-Item -LiteralPath (Join-Path (Split-Path $ctx.Path -Parent) 'release.json') -Destination (Join-Path $hostDirectory 'release.json')
        $backupSecrets=Join-Path $hostDirectory 'secrets'; [IO.Directory]::CreateDirectory($backupSecrets)|Out-Null
        foreach($name in @('plex.dpapi','smb.dpapi','client','client.pub','known_hosts')) {
            $secretPath=Join-Path (Get-KitSecretDirectory) $name
            if(-not(Test-Path -LiteralPath $secretPath)) {throw 'Host credentials or SSH trust are incomplete; backup cannot continue.'}
            Copy-Item -LiteralPath $secretPath -Destination (Join-Path $backupSecrets $name)
        }
        $files=@()
        foreach($f in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            if($f.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Backup refuses symbolic links.'}
            $relative=$f.FullName.Substring($stage.Length+1).Replace('\','/')
            $files+=[pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash}
        }
        $manifest=[pscustomobject]@{schemaVersion=1;installationId=$Config.installationId;releaseId=$Config.releaseId;createdAt=[DateTime]::UtcNow.ToString('o');accountSid=$user.SID.Value;files=$files}
        [IO.File]::WriteAllText((Join-Path $stage 'backup.json'),($manifest|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if(Test-Path -LiteralPath $Destination) {throw 'Backup destination already exists; choose a new filename.'}
        [IO.Compression.ZipFile]::CreateFromDirectory($stage,$Destination); Protect-KitPath $Destination
        $ctx.State | Add-Member -NotePropertyName lastBackup -NotePropertyValue $Destination -Force; Save-KitCheckpoint $ctx.Path $ctx.State
        return $Destination
    } finally {
        try {if($wasRunning) {Start-Service PlexService -ErrorAction Stop}}
        finally {if(Test-Path -LiteralPath $stage) {Remove-Item -LiteralPath $stage -Recurse -Force}}
    }
}
function Expand-KitBackup([string]$Archive,[string]$Destination,$Config) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names=@(); $total=[long]0
        foreach($entry in $zip.Entries) {
            Assert-KitArchiveEntry $entry.FullName | Out-Null
            if($names -contains $entry.FullName) {throw 'Duplicate archive entry.'}; $names+=$entry.FullName
            if(($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) {throw 'Archive contains a symbolic link.'}
            $total+=$entry.Length; if($total -gt 64GB) {throw 'Backup expands beyond the supported capacity.'}
        }
        $meta=$zip.GetEntry('backup.json'); if(-not $meta) {throw 'Backup manifest missing.'}
        $reader=New-Object IO.StreamReader($meta.Open()); try {$m=$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
        Test-KitBackupManifest $m $Config | Out-Null
        if($names.Count -ne @($m.files).Count+1) {throw 'Backup has unexpected or missing entries.'}
        foreach($file in $m.files) {
            if($names -notcontains $file.path) {throw 'Manifest file missing from backup.'}
            if($file.path -notin @('guest.tar','plex/preferences.reg','host/state.json','host/release.json','host/secrets/plex.dpapi','host/secrets/smb.dpapi','host/secrets/client','host/secrets/client.pub','host/secrets/known_hosts') -and -not $file.path.StartsWith('plex/data/')) {throw 'Unexpected backup payload path.'}
        }
        foreach($required in @('guest.tar','plex/preferences.reg','host/state.json','host/release.json','host/secrets/plex.dpapi','host/secrets/smb.dpapi','host/secrets/client','host/secrets/client.pub','host/secrets/known_hosts')) {if($names -notcontains $required) {throw 'Backup is missing required profile/state data.'}}
        [IO.Directory]::CreateDirectory($Destination) | Out-Null; Protect-KitPath $Destination
        foreach($entry in $zip.Entries) {
            $path=Join-Path $Destination $entry.FullName.Replace('/','\'); [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
            $input=$entry.Open(); $output=[IO.File]::Open($path,[IO.FileMode]::CreateNew)
            try {$input.CopyTo($output)} finally {$input.Dispose();$output.Dispose()}
        }
        foreach($file in $m.files) {if((Get-FileHash -LiteralPath (Join-Path $Destination $file.path) -Algorithm SHA256).Hash -ne $file.sha256) {throw 'Backup checksum verification failed.'}}
        Test-KitPlexRegistryExport (Join-Path $Destination 'plex/preferences.reg') $m.accountSid | Out-Null
        $hostState=Get-KitCheckpoint (Join-Path $Destination 'host/state.json')
        if($hostState.config.installationId -ne $Config.installationId -or $hostState.config.releaseId -ne $Config.releaseId -or $hostState.config.sshPublicKey -ne $Config.sshPublicKey -or $hostState.config.guestHostPublicKey -ne $Config.guestHostPublicKey) {throw 'Host backup identity or SSH trust does not match.'}
        return $m
    } finally {$zip.Dispose()}
}
function Restore-KitBackup($Config,[string]$Archive) {
    $ctx=Get-KitContext; $stage=Join-Path (Split-Path $ctx.Path -Parent) ('restore-'+[guid]::NewGuid().ToString('N'))
    $user=Get-LocalUser $Config.plex.account; $profile=Get-KitProfilePath $user.SID.Value; $wasRunning=$false
    try {
        $manifest=Expand-KitBackup $Archive $stage $Config
        if($manifest.accountSid -ne $user.SID.Value) {throw 'Backup Plex account SID differs from the live service profile.'}
        # Existing machine credentials are create-once and remain authoritative.
        # Recover missing encrypted credentials/key files only on this matching machine.
        foreach($name in @('plex.dpapi','smb.dpapi','client','client.pub','known_hosts')) {
            $target=Join-Path (Get-KitSecretDirectory) $name
            if(-not(Test-Path -LiteralPath $target)) {Copy-Item -LiteralPath (Join-Path $stage ('host/secrets/'+$name)) -Destination $target; Protect-KitPath $target}
        }
        $service=Get-Service PlexService; $wasRunning=$service.Status -eq 'Running'; if($wasRunning) {Stop-Service PlexService; (Get-Service PlexService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))}
        $encoded=Join-Path $stage 'guest.b64'; [IO.File]::WriteAllText($encoded,[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $stage 'guest.tar')))); Protect-KitPath $encoded
        Invoke-KitGuest $Config 'restore-upload' $encoded | Out-Null; Invoke-KitGuest $Config 'restore' | Out-Null
        $data=Join-Path $profile 'AppData\Local\Plex Media Server'; $old=$data+'.before-restore-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
        if(Test-Path -LiteralPath $data) {Move-Item -LiteralPath $data -Destination $old}
        try {Copy-Item -LiteralPath (Join-Path $stage 'plex/data') -Destination $data -Recurse}
        catch {if(Test-Path -LiteralPath $old) {Move-Item -LiteralPath $old -Destination $data}; throw}
        Add-KitModifyAccess $data $user.SID.Value
        Invoke-KitUserHive $user.SID.Value {param($hive,$profilePath)
            & "$env:SystemRoot\System32\reg.exe" import (Join-Path $stage 'plex/preferences.reg') | Out-Null
            if($LASTEXITCODE -ne 0) {throw 'Plex profile preferences could not be restored.'}
        }
        # Keep the previous profile data until the restored installation has been checked.
        Invoke-KitGuest $Config 'status'
    } finally {
        try {if($wasRunning) {Start-Service PlexService -ErrorAction Stop}}
        finally {if(Test-Path -LiteralPath $stage) {Remove-Item -LiteralPath $stage -Recurse -Force}}
    }
}
function Test-KitReleaseDowngrade([string]$Current,[string]$Next) {
    $pattern='^(\d+\.\d+\.\d+)(?:-candidate\.(\d+))?$'
    if($Current -notmatch $pattern -or $Next -notmatch $pattern) {throw 'Release IDs must use semantic versions with an optional candidate number.'}
    $a=[regex]::Match($Current,$pattern); $b=[regex]::Match($Next,$pattern)
    $av=[version]$a.Groups[1].Value; $bv=[version]$b.Groups[1].Value
    if($bv -lt $av) {return $true}; if($bv -gt $av) {return $false}
    $ac=[int]::MaxValue; $bc=[int]::MaxValue
    if($a.Groups[2].Success) {$ac=[int]$a.Groups[2].Value}; if($b.Groups[2].Success) {$bc=[int]$b.Groups[2].Value}
    return $bc -lt $ac
}
function Update-KitRelease($Config,[string]$ManifestPath,[string]$MatchingBackup='') {
    $ctx=Get-KitContext; $next=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json; Test-KitManifest $next | Out-Null
    $transition=$null; if($ctx.State.PSObject.Properties.Name -contains 'update') {$transition=$ctx.State.update}
    if(-not $transition -and $next.releaseId -eq $Config.releaseId) {return Invoke-KitGuest $Config 'status'}
    $manifestHash=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    if($transition -and $next.releaseId -ne $transition.targetReleaseId) {
        if($next.releaseId -ne $transition.originalReleaseId -or -not $MatchingBackup) {throw 'Resume using the same target release kit, or select the original release kit with -MatchingBackup pointing to the before-update ZIP.'}
    } elseif($transition -and $manifestHash -ne $transition.manifestSha256) {throw 'The target manifest changed during a pending update. Use the same immutable kit to resume.'}
    $downgrade=Test-KitReleaseDowngrade $Config.releaseId $next.releaseId
    if($downgrade -and -not $MatchingBackup) {throw 'A downgrade requires -MatchingBackup with the backup made under the target release.'}
    if($MatchingBackup) {
        $targetConfig=$Config|ConvertTo-Json -Depth 10|ConvertFrom-Json; $targetConfig.releaseId=$next.releaseId
        $checkStage=Join-Path (Get-KitSecretDirectory) ('backup-check-'+[guid]::NewGuid().ToString('N'))
        try {Expand-KitBackup $MatchingBackup $checkStage $targetConfig|Out-Null}
        finally {if(Test-Path -LiteralPath $checkStage) {Remove-Item -LiteralPath $checkStage -Recurse -Force}}
    }
    if(-not $transition) {
        $backup=Join-Path (Join-Path (Split-Path $ctx.Path -Parent) 'backups') ('before-update-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'.zip')
        New-KitBackup $Config $backup | Out-Null
        $transition=[pscustomobject]@{originalReleaseId=$Config.releaseId;targetReleaseId=$next.releaseId;backupPath=$backup;manifestSha256=$manifestHash;phase='native';matchingRestorePath=$MatchingBackup}
        $ctx.State|Add-Member -NotePropertyName update -NotePropertyValue $transition -Force
    } elseif($next.releaseId -ne $transition.targetReleaseId) {
        # An explicit original-kit plus matching-backup rollback uses the existing
        # consistent backup. Never snapshot an interrupted, mixed-version system.
        $transition.targetReleaseId=$next.releaseId; $transition.manifestSha256=$manifestHash; $transition.phase='native'; $transition.matchingRestorePath=$MatchingBackup
    }
    $backup=$transition.backupPath; $ctx.State.phase='update-pending'; Save-KitCheckpoint $ctx.Path $ctx.State
    $source=Split-Path $ManifestPath -Parent; $cache=Get-KitArtifactDirectory $next.releaseId
    foreach($key in @('plex','wrapper','appliance')) {Save-KitVerifiedArtifact $next.artifacts.$key (Join-Path $cache $next.artifacts.$key.filename) -AssetDirectory $source | Out-Null}
    $oldRelease=$transition.originalReleaseId; $service=Get-Service PlexService; $wasRunning=$service.Status -eq 'Running'
    try {
        if($wasRunning) {Stop-Service PlexService; (Get-Service PlexService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))}
        if($transition.phase -eq 'native') {
            $plexPath=Join-Path $cache $next.artifacts.plex.filename
            Write-Host 'Update Plex using the verified setup, leaving Launch Plex Media Server unchecked.'
            $p=Start-Process -FilePath $plexPath -Wait -PassThru; if($p.ExitCode -notin @(0,3010)) {throw 'Plex update failed.'}
            if(Get-Process -Name 'Plex Media Server' -ErrorAction SilentlyContinue) {throw 'Exit the interactive Plex process before resuming the update.'}
            $credential=Get-KitCredential 'plex' "$($Config.smb.domain)\$($Config.plex.account)"; Initialize-KitWindowsNative; $props=Get-KitMsiPublicProperties $Config
            [MediaKit.NativeWindows]::InstallMsi((Join-Path $cache $next.artifacts.wrapper.filename),$credential.UserName,$credential.Password,$props.MsiHiddenProperties,$props.SecureCustomProperties)
            $transition.phase='guest'
        }
        $Config.releaseId=$next.releaseId; Save-KitCheckpoint $ctx.Path $ctx.State
        $payloadFiles=@{'release.json'=[Convert]::ToBase64String([IO.File]::ReadAllBytes($ManifestPath))}
        foreach($file in $next.files) {
            if($file.StartsWith('guest/') -and $file -notmatch '(^|/)(tests|__pycache__)(/|$)') {$relative=$file.Substring(6); Assert-KitArchiveEntry $relative | Out-Null; $payloadFiles[$relative]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source $file)))}
        }
        $payload=@{config=(Get-KitGuestConfig $Config);files=$payloadFiles}
        $input=Join-Path (Get-KitSecretDirectory) 'release-upload.json'; [IO.File]::WriteAllText($input,($payload|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false)); Protect-KitPath $input
        try {
            Invoke-KitGuest $Config 'release-upload' $input | Out-Null
            if($transition.matchingRestorePath) {$status=Restore-KitBackup $Config $transition.matchingRestorePath} else {$status=Invoke-KitGuest $Config 'apply'}
        } finally {Remove-Item -LiteralPath $input -Force}
        $persistedManifest=Join-Path (Split-Path $ctx.Path -Parent) 'release.json'
        if([IO.Path]::GetFullPath($ManifestPath) -ne [IO.Path]::GetFullPath($persistedManifest)) {Copy-Item -LiteralPath $ManifestPath -Destination $persistedManifest -Force}
        $ctx.State | Add-Member -NotePropertyName previousRelease -NotePropertyValue $oldRelease -Force
        $ctx.State.PSObject.Properties.Remove('update'); $ctx.State.phase='account-handoff'; Save-KitCheckpoint $ctx.Path $ctx.State
        return $status
    } catch {throw "Update interrupted. Retry Update with this same target release.json. To restore the original release, use its kit release.json plus -MatchingBackup '$backup'. Status remains update-pending until completion."}
    finally {if($wasRunning) {Start-Service PlexService -ErrorAction Stop}}
}
function Uninstall-Kit($Config) {
    $ctx=Get-KitContext; $plan=Get-KitUninstallPlan $Config $ctx.State.resources
    foreach($type in @('vm','service','share','firewall','switch','shortcut','account')) {
        foreach($r in @($plan | Where-Object {$_.type -eq $type})) {
            switch($type) {
                'vm' {$vm=Get-VM -Name $r.name -ErrorAction SilentlyContinue; if($vm) {if($vm.Notes -ne "MediaKit:$($Config.installationId)") {throw 'VM ownership changed.'}; Stop-VM -Name $r.name -Force -ErrorAction Stop; Remove-VM -Name $r.name -Force}}
                'service' {$s=Get-CimInstance Win32_Service -Filter "Name='PlexService'"; if($s -and $s.StartName -ne "$($Config.smb.domain)\$($Config.plex.account)") {throw 'Service identity changed.'}; if($s) {Stop-Service PlexService -ErrorAction Stop; & "$env:SystemRoot\System32\sc.exe" delete PlexService | Out-Null; if($LASTEXITCODE -ne 0) {throw 'Could not remove the owned service.'}}}
                'share' {$s=Get-SmbShare -Name $r.name -ErrorAction SilentlyContinue; if($s) {if($s.Description -ne "MediaKit:$($Config.installationId)") {throw 'Share ownership changed.'}; Remove-SmbShare -Name $r.name -Force}}
                'firewall' {$f=Get-NetFirewallRule -Name $r.name -ErrorAction SilentlyContinue; if($f) {if($f.Description -ne "MediaKit:$($Config.installationId)") {throw 'Firewall ownership changed.'}; Remove-NetFirewallRule -Name $r.name}}
                'switch' {$s=Get-VMSwitch -Name $r.name -ErrorAction SilentlyContinue; if($s) {if($s.Notes -ne "MediaKit:$($Config.installationId)" -or @(Get-VMNetworkAdapter -All | Where-Object {$_.SwitchName -eq $r.name}).Count) {throw 'Owned switch is still used; preserve it and detach its dependents manually.'}; Remove-VMSwitch -Name $r.name -Force}}
                'account' {$u=Get-LocalUser -Name $r.name -ErrorAction SilentlyContinue; if($u) {if($u.Description -ne "MediaKit:$($Config.installationId)" -or $u.SID.Value -ne $r.sid) {throw 'Account ownership changed.'}; Remove-LocalUser -Name $r.name}}
                'shortcut' {if(Test-Path -LiteralPath $r.name) {Remove-Item -LiteralPath $r.name -Force}}
            }
        }
    }
    $ctx.State.phase='uninstalled'; Save-KitCheckpoint $ctx.Path $ctx.State
    Write-Host 'Owned services and access accounts were removed. Media, VM disks, Plex profile data, and backups were preserved.'
}
function New-KitShortcuts($Config,[string]$KitDirectory) {
    $folder=Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Media Kit'; [IO.Directory]::CreateDirectory($folder) | Out-Null
    foreach($action in @('OpenRequests','OpenPlex','Credentials','Status','Update','Backup')) {
        $path=Join-Path $folder ($action+'.lnk'); $shell=New-Object -ComObject WScript.Shell
        try {
            $shortcut=$shell.CreateShortcut($path); $shortcut.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $shortcut.Arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-KitWindowsArgument (Join-Path $KitDirectory 'Maintenance.ps1'))+' -Action '+$action
            $shortcut.WorkingDirectory=$KitDirectory; $shortcut.Save(); Register-KitResource 'shortcut' $path
        } finally {[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null}
    }
}
Export-ModuleMember -Function *-Kit*
