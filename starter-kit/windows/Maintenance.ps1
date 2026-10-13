#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Status','OpenRequests','OpenPlex','Backup','Restore','Update','Uninstall')][string]$Action='Status',[string]$StatePath=(Join-Path $env:ProgramData 'MediaKit\state.json'),[string]$Path,[string]$MatchingBackup)
$ErrorActionPreference='Stop'; Set-StrictMode -Version 2.0
foreach($name in @('Common','Artifacts','Secrets','UserHive','Windows','HyperV','Maintenance')) {Import-Module (Join-Path $PSScriptRoot "modules\MediaKit.$name.psm1")}
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $args='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-KitWindowsArgument $PSCommandPath)+' -Action '+$Action+' -StatePath '+(ConvertTo-KitWindowsArgument $StatePath)
        if($Path) {$args+=' -Path '+(ConvertTo-KitWindowsArgument $Path)}
        if($MatchingBackup) {$args+=' -MatchingBackup '+(ConvertTo-KitWindowsArgument $MatchingBackup)}
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -Wait; exit
    }
    $state=Get-KitCheckpoint $StatePath; if(-not $state) {throw 'Install Media Kit first.'}
    Set-KitContext $StatePath $state; $config=$state.config
    switch($Action) {
        'Status' {
            if($state.PSObject.Properties.Name -contains 'update') {Write-Host "Update pending: $($state.update.originalReleaseId) -> $($state.update.targetReleaseId). Retry Update with the same target kit, or use the original kit plus -MatchingBackup $($state.update.backupPath)."; break}
            Get-KitPlexStatus $config | ConvertTo-Json -Depth 5
            $vm=Get-VM -Name $config.vmName -ErrorAction SilentlyContinue
            if(-not $vm -or $vm.State -ne 'Running') {Write-Host 'The companion VM is stopped. Rerun Install.cmd or start the owned VM in Hyper-V Manager.'}
            else {Invoke-KitGuest $config 'status' | ConvertTo-Json -Depth 10}
            Write-Host "Requests: $(Get-KitRequestsUrl $config)"
        }
        'OpenRequests' {Start-Process (Get-KitRequestsUrl $config)}
        'OpenPlex' {Open-KitPlexClaim $config}
        'Backup' {
            if(-not $Path) {$Path=Join-Path (Join-Path (Split-Path $StatePath -Parent) 'backups') ('media-kit-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'.zip')}
            $backup=New-KitBackup $config $Path; Write-Host "Protected backup saved: $backup. It excludes media files. Keep it on this Windows machine; DPAPI credentials remain machine-local."
        }
        'Restore' {if(-not $Path) {$Path=Read-Host 'Matching backup ZIP path'}; Restore-KitBackup $config $Path | ConvertTo-Json -Depth 10}
        'Update' {if(-not $Path) {$Path=Read-Host 'New downloaded kit release.json path'}; Update-KitRelease $config $Path $MatchingBackup | ConvertTo-Json -Depth 10}
        'Uninstall' {Write-Host 'This removes the owned VM registration, shares, service, firewall rules, shortcuts and accounts. Media, profile data, disks and backups remain.'; if((Read-Host 'Type the installation hostname to confirm') -ne $config.hostname) {throw 'Uninstall confirmation did not match.'}; Uninstall-Kit $config}
    }
} catch {Write-Host ('Maintenance paused: '+$_.Exception.Message); exit 1}
if($Action -in @('Status','Backup','Restore','Update','Uninstall')) {Read-Host 'Press Enter to close' | Out-Null}
