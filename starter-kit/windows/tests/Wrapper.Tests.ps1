BeforeAll {
    $script:KitRoot = Split-Path $PSScriptRoot -Parent
    $script:VendorRoot = Join-Path $script:KitRoot 'vendor/pmsservice'
    $builder = Join-Path $script:KitRoot 'build/Build-PmsService.ps1'
    if (Test-Path -LiteralPath $builder) { . $builder -FunctionsOnly }

    function Invoke-FixtureClaim {
        param([string]$SourceDirectory, [string]$DataDirectory, [string]$Token = '')
        $source = Get-Content -LiteralPath (Join-Path $SourceDirectory 'PlexServiceWCF/TrayInteraction.cs') -Raw
        $start = $source.IndexOf('public string GetWebLink()')
        $end = $source.IndexOf('public void Subscribe()', $start)
        $method = $source.Substring($start, $end - $start)
        $namespace = 'ClaimFixture' + [guid]::NewGuid().ToString('N')
        # Compile the actual upstream/patched method. Registry, monitor and log sink
        # are OS/service boundaries; claim-file reads and method branches stay real.
        $code = @"
using System;
using System.IO;
using System.Collections.Generic;
namespace $namespace {
    public enum LogEventLevel { Information }
    public static class Log {
        public static readonly List<string> Entries = new List<string>();
        public static void Write(LogEventLevel level, string text) { Entries.Add(text); }
    }
    public class Monitor { public Version PlexVersion = new Version("1.33.0.0"); }
    public static class PlexRegistryHelper {
        public static string Token;
        public static string ReadUserRegistryValue(string name) { return Token; }
    }
    public static class PlexDirHelper {
        public static string Directory;
        public static string GetPlexDataDir() { return Directory; }
    }
    public class ClaimRunner {
        private readonly Monitor _pms = new Monitor();
        $method
        public static string Run(string directory, string token) {
            PlexDirHelper.Directory = directory;
            PlexRegistryHelper.Token = token;
            return new ClaimRunner().GetWebLink();
        }
        public static string[] GetLogs() { return Log.Entries.ToArray(); }
    }
}
"@
        $types = Add-Type -TypeDefinition $code -PassThru
        $runner = $types | Where-Object { $_.Name -eq 'ClaimRunner' }
        [pscustomobject]@{ Address = $runner::Run($DataDirectory, $Token); Logs = ($runner::GetLogs() -join "`n") }
    }
}

Describe 'Patched pinned PmsService source' {
    BeforeEach {
        $script:Source = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Source | Out-Null
        Copy-Item -Path (Join-Path $script:VendorRoot 'fixtures/upstream/*') -Destination $script:Source -Recurse
        if (Get-Command Invoke-PmsServicePatch -ErrorAction SilentlyContinue) {
            Invoke-PmsServicePatch -SourceDirectory $script:Source -PatchPath (Join-Path $script:VendorRoot 'redact-secrets.patch')
        }
        $script:DataDirectory = Join-Path $TestDrive ('profile-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DataDirectory | Out-Null
    }

    It 'returns the complete claim link without retaining its URL or token in wrapper logs' {
        $claim = 'https://plex.tv/claim?token=dummy-private-claim-token&server=dummy-private-server-id'
        Set-Content -LiteralPath (Join-Path $script:DataDirectory '.claimURL') -Value $claim -NoNewline
        $actual = Invoke-FixtureClaim -SourceDirectory $script:Source -DataDirectory $script:DataDirectory
        $actual.Address | Should -BeExactly $claim
        $actual.Logs | Should -Not -Match 'dummy-private-claim-token|dummy-private-server-id|https://plex.tv/claim'
    }

    It 'keeps the service-profile setup fallback when a claim file is missing or empty' {
        foreach ($hasEmptyFile in @($false, $true)) {
            if ($hasEmptyFile) { Set-Content -LiteralPath (Join-Path $script:DataDirectory '.claimURL') -Value '' -NoNewline }
            $actual = Invoke-FixtureClaim -SourceDirectory $script:Source -DataDirectory $script:DataDirectory
            $actual.Address | Should -BeExactly (Join-Path $script:DataDirectory 'Setup Plex.html')
        }
    }

    It 'does not expose a stale claim link when the service profile is already claimed' {
        Set-Content -LiteralPath (Join-Path $script:DataDirectory '.claimURL') -Value 'https://plex.tv/claim?token=stale-secret' -NoNewline
        $actual = Invoke-FixtureClaim -SourceDirectory $script:Source -DataDirectory $script:DataDirectory -Token 'existing-private-token'
        $actual.Address | Should -BeExactly 'http://localhost:32400/web'
        $actual.Logs | Should -Not -Match 'existing-private-token|stale-secret'
    }

    It 'makes both MSI password aliases hidden and secure while preserving PlexService' {
        [xml]$product = Get-Content -LiteralPath (Join-Path $script:Source 'PlexServiceInstaller/Product.wxs') -Raw
        foreach ($alias in @('SERVICE_PASSWORD', 'LOGON_PASSWORD')) {
            $property = $product.SelectSingleNode("//*[local-name()='Product']/*[local-name()='Property' and @Id='$alias']")
            $property.Hidden | Should -Be 'yes'
            $property.Secure | Should -Be 'yes'
        }
        $product.SelectSingleNode("//*[local-name()='ServiceInstall']").Name | Should -Be 'PlexService'
    }

    It 'produces a distinct MSI version and removes the upstream signing identity and broken copy step' {
        [xml]$product = Get-Content -LiteralPath (Join-Path $script:Source 'PlexServiceInstaller/Product.wxs') -Raw
        ([version]$product.Wix.Product.Version) | Should -BeGreaterThan ([version]'1.2.3')
        [xml]$project = Get-Content -LiteralPath (Join-Path $script:Source 'PlexService/PlexService.csproj') -Raw
        @($project.SelectNodes("//*[local-name()='ManifestKeyFile'] | //*[local-name()='None' and contains(@Include, '.pfx')]")) | Should -HaveCount 0
        [xml]$installer = Get-Content -LiteralPath (Join-Path $script:Source 'PlexServiceInstaller/PlexServiceInstaller.wixproj') -Raw
        @($installer.SelectNodes("//*[local-name()='PostBuildEvent']")) | Should -HaveCount 0
    }

    It 'rejects already patched or drifted sources instead of silently applying a partial security patch' {
        Get-Command Invoke-PmsServicePatch -ErrorAction Stop | Should -Not -BeNullOrEmpty
        { Invoke-PmsServicePatch -SourceDirectory $script:Source -PatchPath (Join-Path $script:VendorRoot 'redact-secrets.patch') } | Should -Throw
    }

    It 'does not read an unbuilt service binary before WiX resolves project references' {
        [xml]$installer = Get-Content -LiteralPath (Join-Path $script:Source 'PlexServiceInstaller/PlexServiceInstaller.wixproj') -Raw
        @($installer.SelectNodes("//*[local-name()='Target' and @Name='BeforeBuild']/*[local-name()='GetAssemblyIdentity']")) | Should -HaveCount 0
        $installer.SelectSingleNode("//*[local-name()='OutputName']").InnerText | Should -Be 'PmsServiceInstaller'
    }
}

Describe 'PmsService build input integrity' {
    It 'verifies the locked patch after a real Windows CRLF checkout conversion' {
        $lock = Get-Content -LiteralPath (Join-Path $script:VendorRoot 'source.lock.json') -Raw | ConvertFrom-Json
        $text = [IO.File]::ReadAllText((Join-Path $script:VendorRoot $lock.patch.filename)).Replace("`r`n", "`n")
        $checkout = Join-Path $TestDrive 'windows-checkout.patch'
        [IO.File]::WriteAllText($checkout, $text.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding $false))
        $canonical = Join-Path $TestDrive 'verified-security.patch'
        [IO.File]::WriteAllBytes($canonical, (Get-PmsServicePatchBytes -Path $checkout -Expected $lock.patch.sha256))
        (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $lock.patch.sha256
    }

    It 'still rejects a genuine patch edit when normalizing checkout line endings' {
        $lock = Get-Content -LiteralPath (Join-Path $script:VendorRoot 'source.lock.json') -Raw | ConvertFrom-Json
        $text = [IO.File]::ReadAllText((Join-Path $script:VendorRoot $lock.patch.filename))
        $checkout = Join-Path $TestDrive 'edited-checkout.patch'
        [IO.File]::WriteAllText($checkout, ($text + "`nunauthorized patch change`n"), (New-Object Text.UTF8Encoding $false))
        { Get-PmsServicePatchBytes -Path $checkout -Expected $lock.patch.sha256 } | Should -Throw '*SHA-256*'
    }

    It 'rejects a corrupt pinned source archive before creating a build source directory' {
        $archive = Join-Path $TestDrive 'corrupt-source.zip'
        Set-Content -LiteralPath $archive -Value 'not the pinned source'
        $destination = Join-Path $TestDrive 'must-not-exist'
        { Initialize-PmsServiceSource -Archive $archive -Destination $destination -VendorDirectory $script:VendorRoot } | Should -Throw '*SHA-256*'
        Test-Path -LiteralPath $destination | Should -BeFalse
    }

    It 'rejects a tampered downloaded dependency instead of executing it' {
        $dependency = Join-Path $TestDrive 'dependency.zip'
        Set-Content -LiteralPath $dependency -Value 'unexpected bytes'
        { Assert-PmsServiceHash -Path $dependency -Expected '0000000000000000000000000000000000000000000000000000000000000000' } | Should -Throw '*SHA-256*'
    }
}

Describe 'Built Windows MSI secret logging' {
    It 'masks both password aliases in retained native Windows Installer logs' -Skip:(!$env:MEDIA_KIT_WRAPPER_MSI -or $env:OS -ne 'Windows_NT') {
        $namespace = 'MsiFixture' + [guid]::NewGuid().ToString('N')
        $native = @"
using System;
using System.Runtime.InteropServices;
namespace $namespace {
    public static class Installer {
        [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern uint MsiEnableLogW(uint mode, string path, uint attributes);
        [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern uint MsiOpenPackageW(string path, out uint handle);
        [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern uint MsiSetPropertyW(uint handle, string name, string value);
        [DllImport("msi.dll", CharSet=CharSet.Unicode)] public static extern uint MsiDoActionW(uint handle, string action);
        [DllImport("msi.dll")] public static extern uint MsiCloseHandle(uint handle);
        [DllImport("msi.dll")] public static extern uint MsiSetInternalUI(uint level, IntPtr owner);
    }
}
"@
        $api = (Add-Type -TypeDefinition $native -PassThru | Where-Object { $_.Name -eq 'Installer' })
        $log = Join-Path $TestDrive 'msi-property-logging.log'
        $servicePassword = 'dummy-service-password-for-logging-test'
        $logonPassword = 'dummy-logon-password-for-logging-test'
        [uint32]$handle = 0
        $oldUI = $api::MsiSetInternalUI(2, [IntPtr]::Zero)
        try {
            # INSTALLLOGMODE_VERBOSE (1 << 12), flush each line (1 << 1).
            $api::MsiEnableLogW(4096, $log, 2) | Should -Be 0
            $api::MsiOpenPackageW($env:MEDIA_KIT_WRAPPER_MSI, [ref]$handle) | Should -Be 0
            $api::MsiSetPropertyW($handle, 'SERVICE_PASSWORD', $servicePassword) | Should -Be 0
            $api::MsiSetPropertyW($handle, 'LOGON_PASSWORD', $logonPassword) | Should -Be 0
            # CostInitialize exercises a real package session and verbose log;
            # no files/accounts/services are installed by this property test.
            $api::MsiDoActionW($handle, 'CostInitialize') | Should -Be 0
        } finally {
            if ($handle) { $api::MsiCloseHandle($handle) | Out-Null }
            $api::MsiEnableLogW(0, $null, 0) | Out-Null
            $api::MsiSetInternalUI($oldUI, [IntPtr]::Zero) | Out-Null
        }
        $retained = Get-Content -LiteralPath $log -Raw
        $retained | Should -Match 'CostInitialize'
        $retained | Should -Not -Match ([regex]::Escape($servicePassword))
        $retained | Should -Not -Match ([regex]::Escape($logonPassword))
    }
}
