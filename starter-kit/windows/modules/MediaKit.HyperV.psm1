Set-StrictMode -Version 2.0
function Select-KitSubnet([string[]]$ExistingRoutes) {
    $ranges=@($ExistingRoutes | ForEach-Object {Get-KitSubnetRange $_})
    for($i=240;$i -le 254;$i++) {
        $r=Get-KitSubnetRange "172.29.$i.0/30"; $overlap=@($ranges | Where-Object {$_.Start -le $r.End -and $_.End -ge $r.Start})
        if(-not $overlap.Count) {return @{hostIP="172.29.$i.1";guestIP="172.29.$i.2";prefixLength=30}}
    }
    throw 'No free private subnet is available. Remove a conflicting VPN route or choose a supported network.'
}
function Set-KitHostLanPrivate($Config,[int]$TimeoutSeconds=60) {
    $switch=Get-VMSwitch -Name $Config.externalSwitchName -ErrorAction Stop
    if($switch.Notes -ne "MediaKit:$($Config.installationId)" -or [string]$switch.SwitchType -ne 'External') {throw 'LAN switch ownership does not match this installation.'}
    $name="vEthernet ($($Config.externalSwitchName))"; $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $adapter=Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        if($adapter) {
            $profiles=@(Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue)
            if($profiles.Count -gt 1) {throw 'The owned LAN interface has ambiguous network profiles; review Windows Network settings before continuing.'}
            if($profiles.Count -eq 1) {
                if([string]$profiles[0].NetworkCategory -eq 'DomainAuthenticated') {throw 'The selected LAN uses a managed domain profile. A home Private network is required; review the network policy before continuing.'}
                if([string]$profiles[0].NetworkCategory -ne 'Private') {Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private -ErrorAction Stop}
                return
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "Windows has not classified the owned LAN interface '$name'. Set this home network to Private in Windows Network settings, then rerun Install.cmd."
}
function New-KitNetwork($Config) {
    $ctx=Get-KitContext; $marker="MediaKit:$($Config.installationId)"
    $adapter=Get-NetAdapter -Name $Config.externalAdapterName -ErrorAction Stop
    if($adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface -or $adapter.PhysicalMediaType -notin @('802.3',14)) {throw 'Select a connected physical wired Ethernet adapter.'}
    foreach($spec in @(@{name=$Config.externalSwitchName;type='External'},@{name=$Config.internalSwitchName;type='Internal'})) {
        $s=Get-VMSwitch -Name $spec.name -ErrorAction SilentlyContinue
        if($s) {if($s.Notes -ne $marker -or [string]$s.SwitchType -ne $spec.type) {throw 'A conflicting Hyper-V switch will not be modified.'}}
        else {
            if($spec.type -eq 'External') {
                $attached=@(Get-VMSwitch | Where-Object {$_.NetAdapterInterfaceDescription -eq $adapter.InterfaceDescription})
                if($attached.Count) {throw 'The selected adapter already belongs to another Hyper-V switch. Choose a free wired adapter.'}
                Write-Host 'Creating the LAN switch may briefly interrupt the host network connection.'
                $s=New-VMSwitch -Name $spec.name -NetAdapterName $Config.externalAdapterName -AllowManagementOS $true
            } else {$s=New-VMSwitch -Name $spec.name -SwitchType Internal}
            Set-VMSwitch -Name $spec.name -Notes $marker
        }
        Register-KitResource 'switch' $spec.name
    }
    # The Plex rule allows only Private networks. Classify this one owned host
    # LAN interface before proceeding, preserving every unrelated interface.
    Set-KitHostLanPrivate $Config
    $nic=Get-NetAdapter -Name "vEthernet ($($Config.internalSwitchName))" -ErrorAction Stop
    $addresses=@(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $wrong=@($addresses | Where-Object {$_.IPAddress -ne $Config.hostIP -and $_.IPAddress -notlike '169.254.*'})
    if($wrong.Count) {throw 'The private switch has conflicting host addresses.'}
    $otherRoutes=@(Get-NetRoute -AddressFamily IPv4 | Where-Object {$_.InterfaceIndex -ne $nic.ifIndex -and $_.DestinationPrefix -ne '0.0.0.0/0'})
    $desired=Get-KitSubnetRange "$($Config.hostIP)/30"
    foreach($route in $otherRoutes) {$r=Get-KitSubnetRange $route.DestinationPrefix; if($r.Start -le $desired.End -and $r.End -ge $desired.Start) {throw 'The private subnet overlaps an existing route.'}}
    if(-not @($addresses | Where-Object {$_.IPAddress -eq $Config.hostIP -and $_.PrefixLength -eq 30}).Count) {New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $Config.hostIP -PrefixLength 30 | Out-Null}
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled | Out-Null
    Set-DnsClient -InterfaceIndex $nic.ifIndex -RegisterThisConnectionsAddress $false
    Set-NetConnectionProfile -InterfaceIndex $nic.ifIndex -NetworkCategory Private
}
function New-KitVM($Config,$Manifest) {
    $ctx=Get-KitContext; $marker="MediaKit:$($Config.installationId)"; $vm=Get-VM -Name $Config.vmName -ErrorAction SilentlyContinue
    if($vm) {
        if($vm.Notes -ne $marker -or $vm.Generation -ne 2) {throw 'An unrelated VM already uses this name.'}
    }
    [IO.Directory]::CreateDirectory($Config.vmRoot) | Out-Null
    if((Get-Item -LiteralPath $Config.vmRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'VM storage cannot be a reparse point.'}
    $folderMarker=Join-Path $Config.vmRoot '.starter-kit-installation.json'
    if(Test-Path -LiteralPath $folderMarker) {
        if((Get-Content -LiteralPath $folderMarker -Raw | ConvertFrom-Json).installationId -ne $Config.installationId) {throw 'VM storage belongs to another installation.'}
    } elseif(@(Get-ChildItem -LiteralPath $Config.vmRoot -Force).Count) {throw 'Choose an empty VM directory to preserve unrelated files.'}
    else {[IO.File]::WriteAllText($folderMarker,(@{schemaVersion=1;installationId=$Config.installationId}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    $source=Save-KitVerifiedArtifact $Manifest.artifacts.appliance (Join-Path (Get-KitArtifactDirectory $Config.releaseId) $Manifest.artifacts.appliance.filename)
    $os=Join-Path $Config.vmRoot 'os.vhdx'; $state=Join-Path $Config.vmRoot 'appstate.vhdx'
    if(-not (Test-Path -LiteralPath $os)) {Copy-Item -LiteralPath $source -Destination $os}
    if((Get-VHD -Path $os).VhdType -ne 'Dynamic' -or (Get-VHD -Path $os).Size -gt 32GB) {throw 'Appliance must be a dynamic VHDX no larger than 32 GB.'}
    if(-not (Test-Path -LiteralPath $state)) {New-VHD -Path $state -SizeBytes 32GB -Dynamic | Out-Null}
    if(-not $vm) {$vm=New-VM -Name $Config.vmName -Generation 2 -MemoryStartupBytes 3GB -Path $Config.vmRoot -VHDPath $os -SwitchName $Config.externalSwitchName}
    if($vm.State -eq 'Running') {Register-KitResource 'vm' $Config.vmName -Path $Config.vmRoot; return $vm}
    Set-VM -Name $Config.vmName -Notes $marker -ProcessorCount 2 -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction ShutDown
    Set-VMMemory -VMName $Config.vmName -DynamicMemoryEnabled $false -StartupBytes 3GB
    Set-VMFirmware -VMName $Config.vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    $first=@(Get-VMNetworkAdapter -VMName $Config.vmName | Where-Object {$_.SwitchName -eq $Config.externalSwitchName})
    if($first.Count -ne 1) {throw 'Owned VM LAN adapter is missing or duplicated.'}
    if($first[0].Name -ne 'LAN') {Rename-VMNetworkAdapter -VMNetworkAdapter $first[0] -NewName 'LAN'}
    Set-VMNetworkAdapter -VMName $Config.vmName -Name LAN -StaticMacAddress $Config.network.externalMac
    if(-not @(Get-VMNetworkAdapter -VMName $Config.vmName | Where-Object {$_.Name -eq 'Private' -and $_.SwitchName -eq $Config.internalSwitchName}).Count) {Add-VMNetworkAdapter -VMName $Config.vmName -Name Private -SwitchName $Config.internalSwitchName -StaticMacAddress $Config.network.internalMac}
    Set-VMNetworkAdapter -VMName $Config.vmName -Name Private -StaticMacAddress $Config.network.internalMac
    $drives=@(Get-VMHardDiskDrive -VMName $Config.vmName)
    if(-not @($drives | Where-Object {$_.Path -eq $state}).Count) {
        if(@($drives | Where-Object {$_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 1}).Count) {throw 'App-state disk slot is occupied by an unexpected disk.'}
        Add-VMHardDiskDrive -VMName $Config.vmName -Path $state -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
    }
    Register-KitResource 'vm' $Config.vmName -Path $Config.vmRoot
    return Get-VM -Name $Config.vmName
}
function Get-KitMacColon([string]$Mac) {return ($Mac.ToLowerInvariant() -replace '(.{2})(?=.)','$1:')}
function Get-KitSeedDocuments($GuestConfig,$SecretFiles,[string]$SshPublicKey,[string]$GuestHostPublicKey,$AssetFiles=@{}) {
    $configJson=$GuestConfig | ConvertTo-Json -Depth 10 -Compress
    $files=[ordered]@{'/etc/starter-kit/config.json'=$configJson}
    foreach($name in $SecretFiles.Keys) {
        if($name -eq 'smb.credentials') {$files[$GuestConfig.smb.credentialsRef]=$SecretFiles[$name]}
        elseif($name -eq 'ssh_host_ed25519_key') {$files['/etc/ssh/ssh_host_ed25519_key']=$SecretFiles[$name]}
        else {throw 'Unknown seed secret file.'}
    }
    $files['/etc/ssh/ssh_host_ed25519_key.pub']=$GuestHostPublicKey+"`n"
    foreach($name in $AssetFiles.Keys) {
        if($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_./-]*$' -or $name -match '(^|/)\.\.(/|$)') {throw 'Unsafe guest asset path.'}
        $files['/opt/starter-kit/'+$name]=$AssetFiles[$name]
    }
    $writes=@()
    foreach($path in $files.Keys) {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($files[$path]))
        $permissions='0600'; if($path.StartsWith('/opt/starter-kit/') -and $path.EndsWith('.py')) {$permissions='0755'}
        $writes+="  - path: $path`n    owner: root:root`n    permissions: '$permissions'`n    encoding: b64`n    content: $encoded"
    }
    if($SshPublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?$' -or $GuestHostPublicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]*)?$') {throw 'Seed requires pinned SSH public keys.'}
    $user=@"
#cloud-config
hostname: $($GuestConfig.hostname)
manage_etc_hosts: true
ssh_deletekeys: false
ssh_genkeytypes: []
disable_root: true
ssh_pwauth: false
users:
  - name: mediakit
    lock_passwd: true
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    ssh_authorized_keys:
      - '$($SshPublicKey.Replace("'","''"))'
write_files:
$($writes -join "`n")
runcmd:
  - [systemctl, restart, ssh]
  - [/opt/starter-kit/bootstrap.py, apply, --config, /etc/starter-kit/config.json]
"@
    $network=@"
version: 2
ethernets:
  private:
    match:
      macaddress: '$(Get-KitMacColon $GuestConfig.network.internalMac)'
    set-name: kit-private
    dhcp4: false
    dhcp6: false
    addresses: ['$($GuestConfig.guestIP)/$($GuestConfig.prefixLength)']
  lan:
    match:
      macaddress: '$(Get-KitMacColon $GuestConfig.network.externalMac)'
    set-name: kit-lan
    dhcp4: true
    dhcp6: false
"@
    return [pscustomobject]@{UserData=$user;MetaData="instance-id: $($GuestConfig.installationId)`nlocal-hostname: $($GuestConfig.hostname)`n";NetworkConfig=$network}
}
function Initialize-KitIsoWriter {
    if('MediaKit.IsoWriter' -as [type]) {return}
    Add-Type -TypeDefinition @'
using System;using System.IO;using System.Runtime.InteropServices;using System.Runtime.InteropServices.ComTypes;
namespace MediaKit {public static class IsoWriter {public static void Write(object stream,string path) {var source=(IStream)stream;IntPtr read=Marshal.AllocHGlobal(4);try {using(var output=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {byte[] buffer=new byte[65536];while(true) {source.Read(buffer,buffer.Length,read);int size=Marshal.ReadInt32(read);if(size<=0) break;output.Write(buffer,0,size);}}}finally {Marshal.FreeHGlobal(read);}}}}
'@
}
function New-KitSeed($GuestConfig,$SecretFiles,[string]$OutputPath,[string]$SshPublicKey='', [string]$GuestHostPublicKey='',[string]$KitDirectory=(Split-Path $PSScriptRoot -Parent)) {
    if(-not $SshPublicKey) {$c=(Get-KitContext).State.config; $SshPublicKey=$c.sshPublicKey; $GuestHostPublicKey=$c.guestHostPublicKey}
    $manifestPath=Join-Path $KitDirectory 'release.json'; $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json; Test-KitManifest $manifest|Out-Null
    if($manifest.releaseId -ne $GuestConfig.releaseId) {throw 'Seed release does not match the installation.'}
    $assets=@{'release.json'=([IO.File]::ReadAllText($manifestPath))}
    foreach($file in $manifest.files) {
        if($file.StartsWith('guest/') -and $file -notmatch '(^|/)(tests|__pycache__)(/|$)') {$assets[$file.Substring(6)]=[IO.File]::ReadAllText((Join-Path $KitDirectory $file))}
    }
    $docs=Get-KitSeedDocuments $GuestConfig $SecretFiles $SshPublicKey $GuestHostPublicKey $assets
    $dir=Join-Path (Split-Path $OutputPath -Parent) ('seed-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($dir) | Out-Null; Protect-KitPath $dir
    $fs=$null; $streams=@()
    try {
        foreach($pair in @(@{Name='user-data';Value=$docs.UserData},@{Name='meta-data';Value=$docs.MetaData},@{Name='network-config';Value=$docs.NetworkConfig})) {[IO.File]::WriteAllText((Join-Path $dir $pair.Name),$pair.Value,[Text.UTF8Encoding]::new($false))}
        Initialize-KitIsoWriter
        $fs=New-Object -ComObject IMAPI2FS.MsftFileSystemImage; $fs.FileSystemsToCreate=3; $fs.VolumeName='CIDATA'; $fs.Root.AddTree($dir,$false)
        $result=$fs.CreateResultImage()
        if(Test-Path -LiteralPath $OutputPath) {Protect-KitPath $OutputPath; Remove-Item -LiteralPath $OutputPath -Force}
        # Parent directory is protected before the secret-bearing ISO is created.
        Protect-KitPath (Split-Path $OutputPath -Parent)
        [MediaKit.IsoWriter]::Write($result.ImageStream,$OutputPath); Protect-KitPath $OutputPath
        return $OutputPath
    } finally {
        if($fs) {[Runtime.InteropServices.Marshal]::FinalReleaseComObject($fs) | Out-Null}
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function ConvertTo-KitWindowsArgument([string]$Value) {
    if($Value -notmatch '[\s"]' -and $Value.Length) {return $Value}
    # CommandLineToArgvW: double backslashes only when followed by a quote or final quote.
    return '"'+([regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'
}
function Invoke-KitNative([string]$Program,[string[]]$Arguments,[string]$InputText='',[int]$TimeoutSeconds=300) {
    if($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 7200) {throw 'Unsupported external-operation timeout.'}
    $start=New-Object Diagnostics.ProcessStartInfo; $start.FileName=$Program; $start.Arguments=(@($Arguments | ForEach-Object {ConvertTo-KitWindowsArgument $_}) -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        $process.Start() | Out-Null; $outTask=$process.StandardOutput.ReadToEndAsync(); $errorTask=$process.StandardError.ReadToEndAsync()
        if($InputText) {$process.StandardInput.Write($InputText)}; $process.StandardInput.Close()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)) {$process.Kill(); throw "External operation exceeded the bounded $TimeoutSeconds second timeout."}
        $stdout=$outTask.GetAwaiter().GetResult(); $stderr=$errorTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0) {throw "External operation failed ($Program, exit $($process.ExitCode)); check service and network status."}
        return $stdout
    } finally {$process.Dispose()}
}
function New-KitSshIdentity($Config) {
    $dir=Get-KitSecretDirectory
    foreach($name in @('client','guest-host')) {
        $path=Join-Path $dir $name
        if(-not (Test-Path -LiteralPath $path)) {Invoke-KitNative 'ssh-keygen.exe' @('-t','ed25519','-N','','-f',$path,'-C',('mediakit-'+$Config.installationId)) | Out-Null}
        Protect-KitPath $path; Protect-KitPath ($path+'.pub')
    }
    $Config.sshPublicKey=(Get-Content -LiteralPath (Join-Path $dir 'client.pub') -Raw).Trim()
    $Config.guestHostPublicKey=(Get-Content -LiteralPath (Join-Path $dir 'guest-host.pub') -Raw).Trim()
    $known=Join-Path $dir 'known_hosts'; [IO.File]::WriteAllText($known,(Get-KitKnownHostEntry $Config)+"`n",[Text.UTF8Encoding]::new($false)); Protect-KitPath $known
    $ctx=Get-KitContext; Save-KitCheckpoint $ctx.Path $ctx.State
}
function Get-KitKnownHostEntry($Config) {return "$($Config.guestIP) $($Config.guestHostPublicKey)"}
function Get-KitGuestCommand([string]$Command,[string]$BackupName='') {
    if($Command -in @('backup','backup-download','backup-remove') -and $BackupName -notmatch '^host-backup-[0-9a-f]{32}\.tar$') {throw 'Backup operations require an installation-generated UUID spool name.'}
    switch($Command) {
        'validate' {return 'sudo cloud-init status --format json | python3 -c ''import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") in ("done","error","disabled") else 1)'' && sudo /opt/starter-kit/bootstrap.py validate --config /etc/starter-kit/config.json'}
        'apply' {return 'sudo /opt/starter-kit/bootstrap.py apply --config /etc/starter-kit/config.json'}
        'status' {return 'sudo /opt/starter-kit/bootstrap.py status --config /etc/starter-kit/config.json'}
        'backup' {return "sudo python3 /opt/starter-kit/backup.py --config /etc/starter-kit/config.json --output /var/lib/starter-kit/$BackupName"}
        'restore' {return 'sudo python3 /opt/starter-kit/restore.py --config /etc/starter-kit/config.json --input /var/lib/starter-kit/host-restore.tar'}
        'backup-download' {return "sudo base64 --wrap=0 /var/lib/starter-kit/$BackupName"}
        'backup-remove' {return "sudo rm -- /var/lib/starter-kit/$BackupName"}
        'restore-upload' {return 'sudo python3 -c ''import base64,os,sys; p="/var/lib/starter-kit/host-restore.tar"; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); f=os.fdopen(fd,"wb"); f.write(base64.b64decode(sys.stdin.buffer.read(),validate=True)); f.close()'''}
        'release-upload' {return 'sudo python3 -c ''import base64,json,os,pathlib,sys; p=json.load(sys.stdin); root=pathlib.Path("/opt/starter-kit"); [(root.joinpath(k).parent.mkdir(parents=True,exist_ok=True),root.joinpath(k).write_bytes(base64.b64decode(v)),os.chmod(root.joinpath(k),0o755 if k.endswith(".py") else 0o600)) for k,v in p["files"].items() if not pathlib.PurePosixPath(k).is_absolute() and ".." not in pathlib.PurePosixPath(k).parts]; pathlib.Path("/etc/starter-kit/config.json").write_text(json.dumps(p["config"])); os.chmod("/etc/starter-kit/config.json",0o600)'''}
        'stop' {return 'sudo systemctl stop docker.service docker.socket'}
        'start' {return 'sudo systemctl start docker.service'}
        default {throw 'Unsupported guest operation.'}
    }
}
function Get-KitCredentialCommand($Config) {
    Test-KitConfig $Config | Out-Null
    # Only validated public identity is interpolated. Secret values travel over
    # the existing pinned SSH stream, never in argv or a temporary JSON file.
    $code='import json,sys;sys.path.insert(0,"/opt/starter-kit");import kit_secrets;c=json.loads(kit_secrets.read_private("/etc/starter-kit/config.json"));s=json.loads(kit_secrets.read_private("/etc/starter-kit/app-secrets.json"));assert c["installationId"]=="'+$Config.installationId+'" and c["releaseId"]=="'+$Config.releaseId+'" and s["installationId"]==c["installationId"];apps=["sonarr","radarr","prowlarr",c["downloader"]];print(json.dumps({"installationId":c["installationId"],"releaseId":c["releaseId"],"credentials":{a:{k:s["values"][a][k] for k in ["username","password"]} for a in apps}}))'
    return "sudo python3 -c '$code'"
}
function Invoke-KitGuest($Config,[string]$Command,[string]$InputFile='',[string]$BackupName='') {
    $dir=Get-KitSecretDirectory
    if($Command -eq 'credentials') {$remote=Get-KitCredentialCommand $Config} else {$remote=Get-KitGuestCommand $Command $BackupName}
    $args=@('-i',(Join-Path $dir 'client'),'-o',('UserKnownHostsFile='+(Join-Path $dir 'known_hosts')),'-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-o','ConnectTimeout=10','-o','LogLevel=ERROR',('mediakit@'+$Config.guestIP),$remote)
    $input=''; if($InputFile) {$input=[IO.File]::ReadAllText($InputFile)}
    $output=Invoke-KitNative 'ssh.exe' $args $input -TimeoutSeconds (Get-KitGuestTimeoutSeconds $Command)
    if($Command -in @('validate','apply','status','backup','restore','credentials')) {
        try {$result=$output | ConvertFrom-Json} catch {throw 'Guest returned an invalid status document.'}
        if($result.installationId -ne $Config.installationId -or $result.releaseId -ne $Config.releaseId) {throw 'Guest installation or release identity does not match.'}
        return $result
    }
    return $output
}
function Get-KitGuestTimeoutSeconds([string]$Command) {
    if($Command -in @('apply','backup','backup-download','restore','restore-upload')) {return 1800}
    if($Command -eq 'validate') {return 60}
    return 300
}
function Wait-KitGuest($Config,[int]$TimeoutSeconds=1800,[switch]$ConfigOnly) {
    $timer=[Diagnostics.Stopwatch]::StartNew(); $last=$null
    while($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $command='status'; if($ConfigOnly) {$command='validate'}
            $last=Invoke-KitGuest $Config $command
            if($ConfigOnly -and $last.phase -eq 'validated') {return $last}
            if($last.phase -in @('ready','complete','interactive-pending','configured','account-handoff')) {return $last}
        } catch { } # bounded retries, no raw SSH output or secret-bearing remote error
        Start-Sleep -Seconds 5
    }
    throw 'The companion VM is not ready. Use Maintenance.ps1 -Action Status to check VM startup, SMB storage, and guest setup; then rerun Install.cmd.'
}
function Complete-KitSeed($Config,[string]$SeedPath) {
    $status=Wait-KitGuest $Config
    foreach($dvd in @(Get-VMDvdDrive -VMName $Config.vmName | Where-Object {$_.Path -eq $SeedPath})) {Remove-VMDvdDrive -VMDvdDrive $dvd}
    if(Test-Path -LiteralPath $SeedPath) {Remove-Item -LiteralPath $SeedPath -Force}
    $hostPrivate=Join-Path (Get-KitSecretDirectory) 'guest-host'
    if(Test-Path -LiteralPath $hostPrivate) {Remove-Item -LiteralPath $hostPrivate -Force}
    return $status
}
Export-ModuleMember -Function *-Kit*
