BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    foreach($name in @('Common','Secrets','UserHive','Maintenance')) {if(Test-Path "$root/modules/MediaKit.$name.psm1") {Import-Module "$root/modules/MediaKit.$name.psm1" -Force}}
    function Get-Fixture { Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json }
}
Describe 'Safe maintenance' {
    It 'requires matching install and release for restoring a backup' {
        $c=Get-Fixture; $m=[pscustomobject]@{schemaVersion=1;installationId=$c.installationId;releaseId=$c.releaseId;files=@()}
        Test-KitBackupManifest $m $c | Should -BeTrue
        $m.releaseId='other'; {Test-KitBackupManifest $m $c} | Should -Throw
        $m.releaseId=$c.releaseId; $m.installationId=[guid]::NewGuid().ToString(); {Test-KitBackupManifest $m $c} | Should -Throw
    }
    It 'rejects archive traversal and absolute paths' {
        foreach($name in @('../a','/a','C:\\a','a/../../b','a\\..\\b')) { {Assert-KitArchiveEntry $name} | Should -Throw }
        Assert-KitArchiveEntry 'plex/Preferences.xml' | Should -BeTrue
    }
    It 'uses stable local hostname for Requests and excludes media from owned teardown' {
        $c=Get-Fixture
        Get-KitRequestsUrl $c | Should -Be "http://$($c.hostname).local:5055"
        $items=Get-KitUninstallPlan $c @([pscustomobject]@{type='media';name=$c.mediaRoot;installationId=$c.installationId},[pscustomobject]@{type='vm';name=$c.vmName;installationId=$c.installationId},[pscustomobject]@{type='vm';name='unrelated';installationId='other'})
        @($items).Count | Should -Be 1
        $items[0].name | Should -Be $c.vmName
    }
    It 'rejects registry exports outside the dedicated Plex account hive' {
        $sid='S-1-5-21-1-2-3-1001'; $p=Join-Path $TestDrive 'preferences.reg'
        [IO.File]::WriteAllText($p,"Windows Registry Editor Version 5.00`n[HKEY_LOCAL_MACHINE\SOFTWARE\Unsafe]`n")
        {Test-KitPlexRegistryExport $p $sid} | Should -Throw
        [IO.File]::WriteAllText($p,"Windows Registry Editor Version 5.00`n[HKEY_USERS\$sid\Software\Plex, Inc.\Plex Media Server]`n")
        Test-KitPlexRegistryExport $p $sid | Should -BeTrue
    }
    It 'cleans a failed backup stage even when restarting Plex fails' {
        function global:Get-LocalUser {param($Name)}
        function global:Get-Service {param($Name)}
        function global:Stop-Service {param($Name)}
        function global:Start-Service {param($Name)}
        try {
            $c=Get-Fixture; $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='ready';completed=@();resources=@()}; Set-KitContext (Join-Path $TestDrive 'state.json') $s
            InModuleScope MediaKit.Maintenance -Parameters @{Base=$TestDrive;Config=$c} {
                param($Base,$Config)
                Mock Get-LocalUser {[pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-1-2-3-1001'}}}
                Mock Get-KitProfilePath {return Join-Path $Base 'uninitialized-profile'}
                Mock Protect-KitPath {}
                Mock Get-Service {$service=[pscustomobject]@{Status='Running'}; $service | Add-Member ScriptMethod WaitForStatus {}; return $service}
                Mock Stop-Service {}
                Mock Start-Service {throw 'restart-boundary-failure'}
                {New-KitBackup $Config (Join-Path $Base 'backup.zip')} | Should -Throw
                @(Get-ChildItem -LiteralPath $Base -Directory -Filter 'backup-*').Count | Should -Be 0
            }
        } finally {foreach($n in @('Get-LocalUser','Get-Service','Stop-Service','Start-Service')) {Remove-Item "Function:\$n"}}
    }
    It 'recognizes downgrades that require a matching state backup' {
        Test-KitReleaseDowngrade '0.2.0-candidate.2' '0.1.0-candidate.1' | Should -BeTrue
        Test-KitReleaseDowngrade '0.1.0-candidate.2' '0.1.0-candidate.1' | Should -BeTrue
        Test-KitReleaseDowngrade '0.1.0-candidate.1' '0.2.0-candidate.1' | Should -BeFalse
    }
}
