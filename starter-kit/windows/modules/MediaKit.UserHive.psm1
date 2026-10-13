Set-StrictMode -Version 2.0
function Get-KitProfilePath([string]$AccountSid) {
    if($AccountSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {throw 'Invalid local account SID.'}
    $profile=Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$AccountSid" -ErrorAction Stop
    return [Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath)
}
function Invoke-KitUserHive([string]$AccountSid,[scriptblock]$Action) {
    $profile=Get-KitProfilePath $AccountSid; $hive="Registry::HKEY_USERS\$AccountSid"; $loaded=$false
    try {
        if(-not (Test-Path -LiteralPath $hive)) {
            & "$env:SystemRoot\System32\reg.exe" load "HKU\$AccountSid" (Join-Path $profile 'NTUSER.DAT') | Out-Null
            if($LASTEXITCODE -ne 0) {throw 'Could not load the Plex service profile. Stop Plex and retry.'}
            $loaded=$true
        }
        & $Action $hive $profile
    } finally {
        if($loaded) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & "$env:SystemRoot\System32\reg.exe" unload "HKU\$AccountSid" | Out-Null
            if($LASTEXITCODE -ne 0) {throw 'Plex profile hive remains loaded; close profile tools and retry.'}
        }
    }
}
Export-ModuleMember -Function Get-KitProfilePath,Invoke-KitUserHive
