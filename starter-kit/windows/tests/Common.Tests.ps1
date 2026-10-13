BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    if (Test-Path "$root/modules/MediaKit.Common.psm1") { Import-Module "$root/modules/MediaKit.Common.psm1" -Force }
    if (Test-Path "$root/modules/MediaKit.Artifacts.psm1") { Import-Module "$root/modules/MediaKit.Artifacts.psm1" -Force }
    function Get-Fixture { Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json }
}
Describe 'Public configuration' {
    It 'accepts the frozen contract and literal Windows paths' {
        $c = Get-Fixture; $c.mediaRoot = "D:\Friend's Media\Films & TV"
        Test-KitConfig $c | Should -BeTrue
        $p = Join-Path $TestDrive 'state.json'
        Save-KitCheckpoint $p ([pscustomobject]@{ schemaVersion=1; config=$c; phase='preflight'; completed=@(); resources=@() })
        (Get-KitCheckpoint $p).config.mediaRoot | Should -BeExactly $c.mediaRoot
    }
    It 'rejects equal or unrelated internal addresses' {
        $c = Get-Fixture; $c.guestIP = $c.hostIP; { Test-KitConfig $c } | Should -Throw
        $c.guestIP = '192.168.1.2'; { Test-KitConfig $c } | Should -Throw
    }
    It 'rejects unsafe shares and unsupported selections' {
        $c = Get-Fixture; $c.smb.share = '../media'; { Test-KitConfig $c } | Should -Throw
        $c = Get-Fixture; $c.downloader = 'both'; { Test-KitConfig $c } | Should -Throw
        $c = Get-Fixture; $c.timezone = 'Nowhere/Invalid'; { Test-KitConfig $c } | Should -Throw
    }
    It 'rejects changed identity on resume' {
        $p = Join-Path $TestDrive 'resume.json'; $c = Get-Fixture
        $s = [pscustomobject]@{ schemaVersion=1; config=$c; phase='preflight'; completed=@('accounts'); resources=@() }
        Save-KitCheckpoint $p $s
        $s.config.installationId = [guid]::NewGuid().ToString()
        { Save-KitCheckpoint $p $s } | Should -Throw
    }
    It 'rejects secret fields instead of retaining them in state' {
        $s = [pscustomobject]@{schemaVersion=1; config=(Get-Fixture); phase='preflight'; completed=@(); resources=@(); password='dummy-secret'}
        { Save-KitCheckpoint (Join-Path $TestDrive 'secret.json') $s } | Should -Throw
    }
    It 'projects only the frozen guest fields' {
        $g = Get-KitGuestConfig (Get-Fixture)
        $g.PSObject.Properties.Name | Should -Not -Contain 'mediaRoot'
        $g.PSObject.Properties.Name | Should -Not -Contain 'sshPublicKey'
        $g.smb.credentialsRef | Should -Be '/run/starter-kit-secrets/smb.credentials'
    }
    It 'preserves selected storage and credentials identity across resume' {
        $p=Join-Path $TestDrive 'choices.json'; $c=Get-Fixture
        $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='preflight';completed=@();resources=@()}; Save-KitCheckpoint $p $s
        $s.config.mediaRoot='D:\Other'; {Save-KitCheckpoint $p $s} | Should -Throw '*cannot change*'
    }
    It 'blocks insufficient memory and unsupported Windows before mutation' {
        $f=@{Edition='Professional'; Build=22631; Architecture='AMD64'; MemoryBytes=8GB; Virtualization=$true; FreeBytes=100GB; IsAdmin=$true; Conflicts=@()}
        (Get-KitPreflight $f (Get-Fixture)).Ready | Should -BeTrue
        $f.MemoryBytes=4GB; (Get-KitPreflight $f (Get-Fixture)).Ready | Should -BeFalse
        $f.MemoryBytes=8GB; $f.Edition='Core'; (Get-KitPreflight $f (Get-Fixture)).Ready | Should -BeFalse
    }
}
Describe 'Artifacts and manifest' {
    It 'rejects incomplete manifests' { { Test-KitManifest ([pscustomobject]@{schemaVersion=1;releaseId='x'}) } | Should -Throw }
    It 'verifies adjacent assets without network access and rejects changed content' {
        $src=Join-Path $TestDrive 'appliance.vhdx'; [IO.File]::WriteAllText($src,'fixture')
        $a=[pscustomobject]@{filename='appliance.vhdx';sha256=(Get-FileHash $src -Algorithm SHA256).Hash;architecture='amd64'}
        $dest=Join-Path $TestDrive 'cache/appliance.vhdx'
        Save-KitVerifiedArtifact $a $dest -AssetDirectory $TestDrive | Should -Be $dest
        [IO.File]::WriteAllText($src,'corrupt'); Remove-Item $dest
        { Save-KitVerifiedArtifact $a $dest -AssetDirectory $TestDrive } | Should -Throw
    }
    It 'rejects HTTP and foreign architectures before fetching' {
        $a=[pscustomobject]@{filename='file';sha256=('a'*64);architecture='arm64';url='http://example.com/file'}
        { Save-KitVerifiedArtifact $a (Join-Path $TestDrive 'file') } | Should -Throw
    }
    It 'accepts the pinned x86 wrapper MSI on the required x64 Windows host' {
        $src=Join-Path $TestDrive 'PmsServiceInstaller.msi'; [IO.File]::WriteAllText($src,'wrapper-fixture')
        $a=[pscustomobject]@{filename='PmsServiceInstaller.msi';sha256=(Get-FileHash $src -Algorithm SHA256).Hash;architecture='x86'}
        $dest=Join-Path $TestDrive 'wrapper-cache/PmsServiceInstaller.msi'
        Save-KitVerifiedArtifact $a $dest -AssetDirectory $TestDrive | Should -Be $dest
    }
}
