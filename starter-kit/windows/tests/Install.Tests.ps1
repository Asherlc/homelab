BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    if(Test-Path "$root/modules/MediaKit.Common.psm1") {Import-Module "$root/modules/MediaKit.Common.psm1" -Force}
}
Describe 'Resumable wizard operations' {
    It 'preserves completed operations and does not repeat host mutation' {
        $c=Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json
        $p=Join-Path $TestDrive 'state.json'; $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='preflight';completed=@();resources=@()}
        $script:calls=0
        Invoke-KitOperation $p $s 'hyperv-enable' { $script:calls++ } | Out-Null
        $resumed=Get-KitCheckpoint $p
        Invoke-KitOperation $p $resumed 'hyperv-enable' { $script:calls++ } | Out-Null
        $script:calls | Should -Be 1
        $resumed.config.installationId | Should -Be $c.installationId
    }
    It 'does not checkpoint a failed operation as completed' {
        $c=Get-Content "$PSScriptRoot/fixtures/host-config.json" -Raw | ConvertFrom-Json
        $s=[pscustomobject]@{schemaVersion=1;config=$c;phase='preflight';completed=@();resources=@()}; $p=Join-Path $TestDrive 'failure.json'
        {Invoke-KitOperation $p $s 'guest' {throw 'boundary failure'}} | Should -Throw
        @($s.completed) | Should -Not -Contain 'guest'
    }
}
