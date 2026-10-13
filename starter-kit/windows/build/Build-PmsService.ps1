[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts'),
    [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'media-kit-pmsservice-build'),
    [string]$SourceArchive,
    [string]$WixArchive,
    [switch]$PrepareOnly,
    [switch]$FunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PmsServiceHash {
    param([string]$Path, [string]$Expected)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "PmsService build input failed SHA-256 verification: $([IO.Path]::GetFileName($Path))"
    }
}

function Save-PmsServiceInput {
    param($Artifact, [string]$Path)
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Artifact.url -OutFile $Path -UseBasicParsing
    }
    Assert-PmsServiceHash -Path $Path -Expected $Artifact.sha256
}

function Get-PmsServicePatchBytes {
    param([string]$Path, [string]$Expected)
    # The committed patch is locked as UTF-8/LF text. Git for Windows may
    # materialize CRLF before build; normalize only that representation before
    # checking the same immutable digest and applying those verified bytes.
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    if ($actual -ne $Expected) { throw 'PmsService security patch failed canonical UTF-8/LF SHA-256 verification.' }
    return ,$bytes
}

function Invoke-PmsServicePatch {
    param([Parameter(Mandatory)][string]$SourceDirectory, [Parameter(Mandatory)][string]$PatchPath)
    $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
    $patch = (Resolve-Path -LiteralPath $PatchPath).Path
    # Normalize source text to LF before a strict git patch
    # so git core.autocrlf and the build OS cannot change patch applicability.
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        if ($file.Extension -in @('.cs', '.csproj', '.wxs', '.wxi', '.wixproj')) {
            $text = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
            [IO.File]::WriteAllText($file.FullName, $text, (New-Object Text.UTF8Encoding $false))
        }
    }
    # Do not discover the kit's parent repository or traverse /tmp symlinks in
    # absolute patch paths. This is a source transformation, never an index edit.
    $previousCeiling = $env:GIT_CEILING_DIRECTORIES
    try {
        $env:GIT_CEILING_DIRECTORIES = [IO.Directory]::GetParent($source).FullName
        & git -C $source apply --check -- $patch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Pinned PmsService security patch does not apply; refusing source drift.' }
        & git -C $source apply -- $patch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'PmsService security patch application failed.' }
    } finally {
        $env:GIT_CEILING_DIRECTORIES = $previousCeiling
    }
    # The upstream temporary identity is intentionally never retained or built.
    Get-ChildItem -LiteralPath $source -Recurse -File -Filter '*.pfx' | Remove-Item -Force
}

function Initialize-PmsServiceSource {
    param([string]$Archive, [string]$Destination, [string]$VendorDirectory)
    $lock = Get-Content -LiteralPath (Join-Path $VendorDirectory 'source.lock.json') -Raw | ConvertFrom-Json
    Assert-PmsServiceHash -Path $Archive -Expected $lock.archive.sha256
    $patchPath = Join-Path $VendorDirectory $lock.patch.filename
    $patchBytes = Get-PmsServicePatchBytes -Path $patchPath -Expected $lock.patch.sha256
    if (Test-Path -LiteralPath $Destination) { throw 'Build source destination already exists; choose a clean work directory.' }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $canonicalPatch = Join-Path $Destination 'verified-security.patch'
    [IO.File]::WriteAllBytes($canonicalPatch, $patchBytes)
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
    $source = Join-Path $Destination $lock.archive.root
    foreach ($dll in $lock.bundledDlls) {
        Assert-PmsServiceHash -Path (Join-Path $source $dll.filename) -Expected $dll.sha256
    }
    foreach ($archiveSource in $lock.bundledSourceArchives) {
        Assert-PmsServiceHash -Path (Join-Path $source $archiveSource.filename) -Expected $archiveSource.sha256
    }
    Invoke-PmsServicePatch -SourceDirectory $source -PatchPath $canonicalPatch
    return $source
}

if ($FunctionsOnly) { return }

$vendor = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../vendor/pmsservice')).Path
$lock = Get-Content -LiteralPath (Join-Path $vendor 'source.lock.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
$work = (Resolve-Path -LiteralPath $WorkDirectory).Path
if (!$SourceArchive) {
    $SourceArchive = Join-Path $work 'pmsservice-source.zip'
    Save-PmsServiceInput -Artifact $lock.archive -Path $SourceArchive
}
$source = Initialize-PmsServiceSource -Archive $SourceArchive -Destination (Join-Path $work ('source-' + [guid]::NewGuid().ToString('N'))) -VendorDirectory $vendor
if ($PrepareOnly) {
    [pscustomobject]@{ sourceDirectory = $source; commit = $lock.commit; patchedVersion = $lock.patchedVersion }
    return
}
if ($env:OS -ne 'Windows_NT') { throw 'Building PmsService requires Windows MSBuild, .NET Framework 4.7.2 and WCF build tools.' }

if (!$WixArchive) {
    $WixArchive = Join-Path $work 'wix314-binaries.zip'
    Save-PmsServiceInput -Artifact $lock.wix -Path $WixArchive
}
Assert-PmsServiceHash -Path $WixArchive -Expected $lock.wix.sha256
$wix = Join-Path $work ('wix-' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $WixArchive -DestinationPath $wix
$wixTargets = Join-Path $wix 'wix.targets'
foreach ($name in @('wix.targets', 'candle.exe', 'light.exe', 'WixNetFxExtension.dll', 'WixUIExtension.dll', 'WixUtilExtension.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $wix $name))) { throw "Required WiX 3.14.1 file missing: $name" }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools with MSBuild and WCF tooling are required.' }
$vs = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
if (!$vs) { throw 'Visual Studio MSBuild installation not found.' }
$msbuild = Join-Path $vs 'MSBuild/Current/Bin/MSBuild.exe'
$wcf = Join-Path $vs 'MSBuild/Microsoft/VisualStudio/v17.0/WCF/Microsoft.VisualStudio.ServiceModel.targets'
if (!(Test-Path -LiteralPath $wcf)) { throw 'Install Visual Studio component Microsoft.VisualStudio.Component.Wcf.Tooling before building.' }
$framework = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies/Microsoft/Framework/.NETFramework/v4.7.2/mscorlib.dll'
if (!(Test-Path -LiteralPath $framework)) { throw 'The .NET Framework 4.7.2 targeting pack is required.' }

$solution = Join-Path $source 'PlexMediaServerService.sln'
$buildArguments = @(
    $solution, '/restore', '/t:Rebuild', '/m', '/nologo', '/verbosity:minimal',
    '/p:Configuration=Release', '/p:Platform=Any CPU', '/p:VisualStudioVersion=17.0',
    "/p:WixTargetsPath=$wixTargets", "/p:WixToolPath=$wix/", "/p:WixExtDir=$wix", '/p:SignManifests=false'
)
& $msbuild @buildArguments
if ($LASTEXITCODE -ne 0) { throw 'PmsService MSBuild/WiX build failed.' }
$msis = @(Get-ChildItem -LiteralPath (Join-Path $source 'PlexServiceInstaller/bin/Release') -Filter '*.msi' -File)
if ($msis.Count -ne 1) { throw 'PmsService build did not produce exactly one MSI.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$msi = Join-Path $output 'PmsServiceInstaller.msi'
Copy-Item -LiteralPath $msis[0].FullName -Destination $msi
$report = [ordered]@{
    schemaVersion = 1; upstreamCommit = $lock.commit; sourceSha256 = $lock.archive.sha256
    patchSha256 = $lock.patch.sha256; patchedVersion = $lock.patchedVersion
    assemblyVersion = $lock.assemblyVersion; wixVersion = $lock.wix.version; wixSha256 = $lock.wix.sha256
    configuration = 'Release'; solutionPlatform = 'Any CPU'; binaryArchitecture = 'x86'
    supportedHostArchitecture = 'amd64'; filename = 'PmsServiceInstaller.msi'
    sha256 = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
    authenticode = 'unsigned candidate'; validation = 'Windows build only; target cold boot and GPU acceptance remain required'
}
[IO.File]::WriteAllText((Join-Path $output 'wrapper-build.json'), ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
$report | ConvertTo-Json -Depth 8
