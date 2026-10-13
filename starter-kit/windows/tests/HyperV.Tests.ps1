BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    foreach($name in @('Common','HyperV')) {if(Test-Path "$root/modules/MediaKit.$name.psm1") {Import-Module "$root/modules/MediaKit.$name.psm1" -Force}}
    function Get-Fixture { Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json }
}
Describe 'Hyper-V seed and network decisions' {
    It 'serializes frozen guest config literally into restricted cloud init files' {
        $c=Get-Fixture; $g=Get-KitGuestConfig $c
        $files=@{ 'smb.credentials'="username=$($c.smb.account)`npassword=test-dummy`ndomain=FRIEND-PC`n"; 'ssh_host_ed25519_key'='host-private-fixture' }
        $seed=Get-KitSeedDocuments $g $files $c.sshPublicKey $c.guestHostPublicKey
        $seed.MetaData | Should -Match $c.installationId
        $seed.UserData | Should -Match 'permissions: ''0600'''
        $seed.UserData | Should -Match 'encoding: b64'
        $seed.NetworkConfig | Should -Match 'dhcp4: true'
        $seed.NetworkConfig | Should -Match 'dhcp4: false'
        $seed.NetworkConfig | Should -Not -Match 'gateway|nameservers'
        $seed.UserData | Should -Not -Match 'test-dummy'
    }
    It 'chooses an unused subnet and never overlaps existing routes' {
        $r=Select-KitSubnet @('172.29.240.0/30','172.29.241.0/24')
        $r.hostIP | Should -Be '172.29.242.1'
        $r.guestIP | Should -Be '172.29.242.2'
    }
    It 'validates SSH commands and binds known_hosts to the installation host key' {
        $c=Get-Fixture
        Get-KitKnownHostEntry $c | Should -Be '172.29.240.2 ssh-ed25519 AAAAHOST fixture-only'
        { Get-KitGuestCommand "status; rm -rf /" } | Should -Throw
        Get-KitGuestCommand 'status' | Should -Be 'sudo /opt/starter-kit/bootstrap.py status --config /etc/starter-kit/config.json'
    }
    It 'includes guest source and final manifest as encoded executable seed assets' {
        $c=Get-Fixture; $g=Get-KitGuestConfig $c
        $seed=Get-KitSeedDocuments $g @{'smb.credentials'='dummy'} $c.sshPublicKey $c.guestHostPublicKey @{'bootstrap.py'='print(1)';'release.json'='{"releaseId":"fixture"}'}
        $seed.UserData | Should -Match 'path: /opt/starter-kit/bootstrap.py'
        $seed.UserData | Should -Match "permissions: '0755'"
        $seed.UserData | Should -Match 'path: /opt/starter-kit/release.json'
    }
    It 'rejects an unrelated VM before changing any host resource' {
        function global:Get-VM {param($Name) [pscustomobject]@{Notes='unrelated';Generation=2}}
        try {
            $c=Get-Fixture; $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='vm';completed=@();resources=@()}; Set-KitContext (Join-Path $TestDrive 'vm.json') $s
            {New-KitVM $c ([pscustomobject]@{})} | Should -Throw '*unrelated VM*'
        } finally {Remove-Item Function:\Get-VM}
    }
    It 'isolates backup spool files and rejects remote path injection' {
        $a='host-backup-'+[guid]::NewGuid().ToString('N')+'.tar'; $b='host-backup-'+[guid]::NewGuid().ToString('N')+'.tar'
        $first=Get-KitGuestCommand 'backup' $a; $second=Get-KitGuestCommand 'backup' $b
        $first | Should -Not -Be $second
        $first | Should -Match ([regex]::Escape('/var/lib/starter-kit/'+$a))
        Get-KitGuestCommand 'backup-download' $a | Should -Match ([regex]::Escape($a))
        Get-KitGuestCommand 'backup-remove' $a | Should -Be "sudo rm -- /var/lib/starter-kit/$a"
        {Get-KitGuestCommand 'backup' '../unsafe;touch x'} | Should -Throw
    }
    It 'allows retrying apply after first boot failed with a still reachable guest' {
        $c=Get-Fixture
        InModuleScope MediaKit.HyperV -Parameters @{Config=$c} {
            param($Config)
            Mock Invoke-KitGuest {
                param($Config,$Command)
                if($Command -eq 'validate') {return [pscustomobject]@{installationId=$Config.installationId;releaseId=$Config.releaseId;phase='validated'}}
                return [pscustomobject]@{installationId=$Config.installationId;releaseId=$Config.releaseId;phase='blocked'}
            }
            Mock Start-Sleep {}
            (Wait-KitGuest $Config -TimeoutSeconds 1 -ConfigOnly).phase | Should -Be 'validated'
        }
        Get-KitGuestCommand 'validate' | Should -Match 'cloud-init status --format json'
        Get-KitGuestCommand 'validate' | Should -Match '/opt/starter-kit/bootstrap.py validate'
    }
    It 'allows bounded image pulls and archive operations on the small HDD server' {
        Get-KitGuestTimeoutSeconds 'apply' | Should -Be 1800
        Get-KitGuestTimeoutSeconds 'backup' | Should -Be 1800
        Get-KitGuestTimeoutSeconds 'restore' | Should -Be 1800
        Get-KitGuestTimeoutSeconds 'validate' | Should -Be 60
    }
    It 'builds a private identity-checked SSH handoff without requesting API keys' {
        $c=Get-Fixture; $command=Get-KitCredentialCommand $c
        $command | Should -Match ([regex]::Escape($c.installationId))
        $command | Should -Match 'read_private'
        $command | Should -Match 'username'
        $command | Should -Match 'password'
        $command | Should -Not -Match 'apiKey'
        $command | Should -Match 'downloader'
    }
}
