BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    foreach($name in @('Common','Artifacts','Secrets','UserHive','Windows','HyperV','Maintenance')) {if(Test-Path "$root/modules/MediaKit.$name.psm1") {Import-Module "$root/modules/MediaKit.$name.psm1" -Force}}
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
    It 'resumes a persisted guest update without creating a mixed-release backup' {
        function global:Get-Service {param($Name)}
        function global:Start-Service {param($Name)}
        function global:Stop-Service {param($Name)}
        try {
            $c=Get-Fixture; $original=$c.releaseId; $c.releaseId='0.2.0-candidate.1'
            $m=[IO.File]::ReadAllText((Join-Path $root 'release.json'))|ConvertFrom-Json; $m.releaseId=$c.releaseId; $m.files=@('guest/bootstrap.py')
            foreach($k in @('plex','wrapper','appliance')) {$m.artifacts.$k.sha256='a'*64}
            $manifest=Join-Path $TestDrive 'release.json'; [IO.File]::WriteAllText($manifest,($m|ConvertTo-Json -Depth 20))
            [IO.Directory]::CreateDirectory((Join-Path $TestDrive 'guest'))|Out-Null; [IO.File]::WriteAllText((Join-Path $TestDrive 'guest/bootstrap.py'),'fixture')
            $state=[pscustomobject]@{schemaVersion=1;config=$c;phase='update-pending';completed=@();resources=@();update=[pscustomobject]@{originalReleaseId=$original;targetReleaseId=$c.releaseId;backupPath=(Join-Path $TestDrive 'original.zip');manifestSha256=(Get-FileHash $manifest -Algorithm SHA256).Hash;phase='guest';matchingRestorePath=''}}
            $statePath=Join-Path $TestDrive 'state.json'; Set-KitContext $statePath $state
            InModuleScope MediaKit.Maintenance -Parameters @{Config=$c;Manifest=$manifest;Base=$TestDrive;StatePath=$statePath} {
                param($Config,$Manifest,$Base,$StatePath)
                Mock Save-KitVerifiedArtifact {return $Destination}
                Mock New-KitBackup {throw 'A new backup of mixed versions is forbidden'}
                Mock Get-Service {[pscustomobject]@{Status='Stopped'}}
                Mock Start-Service {}; Mock Stop-Service {}; Mock Protect-KitPath {}
                Mock Get-KitSecretDirectory {return $Base}
                $script:applyAttempts=0
                Mock Invoke-KitGuest {
                    param($Config,$Command)
                    if($Command -eq 'apply') {$script:applyAttempts++; if($script:applyAttempts -eq 1) {throw 'first apply interrupted'}; return [pscustomobject]@{phase='account-handoff'}}
                    if($Command -eq 'status') {return [pscustomobject]@{phase='blocked'}}
                }
                {Update-KitRelease $Config $Manifest} | Should -Throw '*interrupted*'
                (Get-KitCheckpoint $StatePath).update.targetReleaseId | Should -Be $Config.releaseId
                (Update-KitRelease $Config $Manifest).phase | Should -Be 'account-handoff'
                (Get-KitCheckpoint $StatePath).PSObject.Properties.Name | Should -Not -Contain 'update'
            }
        } finally {foreach($n in @('Get-Service','Start-Service','Stop-Service')) {Remove-Item "Function:\$n"}}
    }
    It 'filters the credential handoff to selected web logins and rejects keys or mismatched identity' {
        $c=Get-Fixture; $entries=[ordered]@{}
        foreach($app in @('sonarr','radarr','prowlarr',$c.downloader)) {$entries[$app]=[pscustomobject]@{username='mediaadmin';password='dummy-private-password'}}
        $p=[pscustomobject]@{installationId=$c.installationId;releaseId=$c.releaseId;credentials=[pscustomobject]$entries}
        $private=ConvertFrom-KitCredentialPayload $p $c
        @($private).Count | Should -Be 4
        $private[0].url | Should -Be "http://$($c.hostname).local:8989"
        $private[0].password | Should -Be 'dummy-private-password'
        ($private|ConvertTo-Json -Depth 5) | Should -Not -Match 'apiKey'
        $p.credentials.sonarr|Add-Member -NotePropertyName apiKey -NotePropertyValue 'dummy-key'
        {ConvertFrom-KitCredentialPayload $p $c} | Should -Throw
        $p.credentials.sonarr.PSObject.Properties.Remove('apiKey'); $p.releaseId='other'
        {ConvertFrom-KitCredentialPayload $p $c} | Should -Throw
    }
}
