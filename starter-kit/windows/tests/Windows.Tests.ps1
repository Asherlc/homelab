BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    foreach($name in @('Common','Windows','UserHive','Secrets')) { if(Test-Path "$root/modules/MediaKit.$name.psm1") {Import-Module "$root/modules/MediaKit.$name.psm1" -Force} }
    function Get-Fixture { Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json }
}
Describe 'Windows ownership and service protection' {
    It 'rejects unrelated resources and reuses matching owner records' {
        $c=Get-Fixture
        { Assert-KitOwnership 'account' 'existing' $c.installationId @() } | Should -Throw
        Assert-KitOwnership 'account' $c.plex.account $c.installationId @([pscustomobject]@{type='account';name=$c.plex.account;installationId=$c.installationId}) | Should -BeTrue
    }
    It 'generates strong fresh passwords without shell metacharacters or newlines' {
        $a=New-KitPassword; $b=New-KitPassword
        $a | Should -BeOfType ([Security.SecureString]); $a.Length | Should -BeGreaterOrEqual 32
        $b | Should -Not -Be $a
    }
    It 'uses service profile Setup Plex html for claiming' {
        $c=Get-Fixture
        Get-KitPlexClaimPath $c 'C:\Users\plex-service' | Should -Be 'C:\Users\plex-service\AppData\Local\Plex Media Server\Setup Plex.html'
    }
    It 'MSI properties include both hidden password aliases' {
        $properties=Get-KitMsiPublicProperties (Get-Fixture)
        $properties.MsiHiddenProperties | Should -Match 'SERVICE_PASSWORD'
        $properties.MsiHiddenProperties | Should -Match 'LOGON_PASSWORD'
        $properties.SecureCustomProperties | Should -Match 'LOGON_PASSWORD'
        ($properties | ConvertTo-Json -Depth 5) | Should -Not -Match 'dummy-secret'
    }
    It 'refuses an existing foreign local account before profile or password changes' {
        function global:Get-LocalUser {param($Name) [pscustomobject]@{Description='personal-account'}}
        try {
            $c=Get-Fixture; $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='accounts';completed=@();resources=@()}; Set-KitContext (Join-Path $TestDrive 'account.json') $s
            {New-KitServiceIdentity $c.plex.account (New-KitPassword)} | Should -Throw '*already exists*'
        } finally {Remove-Item Function:\Get-LocalUser}
    }
}
