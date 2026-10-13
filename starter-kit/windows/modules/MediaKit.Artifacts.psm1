Set-StrictMode -Version 2.0
function Assert-KitArtifact([string]$Path,$Artifact) {
    $compatible=$Artifact.architecture -eq 'amd64' -or ($Artifact.architecture -eq 'x86' -and $Artifact.filename -eq 'PmsServiceInstaller.msi')
    if(-not $compatible -or $Artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$') {throw 'Invalid artifact architecture or digest.'}
    if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Artifact.sha256) {throw 'Artifact checksum verification failed. Execution is blocked.'}
    if($Artifact.PSObject.Properties.Name -contains 'publisher' -and $Artifact.publisher) {
        $signature=Get-AuthenticodeSignature -LiteralPath $Path
        if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject.IndexOf($Artifact.publisher,[StringComparison]::OrdinalIgnoreCase) -lt 0) {throw 'Artifact Authenticode publisher verification failed.'}
    }
}
function Save-KitVerifiedArtifact($Artifact,[string]$Destination,[string]$AssetDirectory=(Split-Path $PSScriptRoot -Parent)) {
    $compatible=$Artifact.architecture -eq 'amd64' -or ($Artifact.architecture -eq 'x86' -and $Artifact.filename -eq 'PmsServiceInstaller.msi')
    if(-not $compatible -or $Artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Artifact.filename -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {throw 'Invalid artifact descriptor.'}
    if(Test-Path -LiteralPath $Destination) {Assert-KitArtifact $Destination $Artifact; return $Destination}
    [IO.Directory]::CreateDirectory((Split-Path $Destination -Parent)) | Out-Null
    $temp=$Destination+'.partial'; $adjacent=Join-Path $AssetDirectory $Artifact.filename
    try {
        if(Test-Path -LiteralPath $adjacent) {Copy-Item -LiteralPath $adjacent -Destination $temp -Force}
        else {
            if(-not ($Artifact.PSObject.Properties.Name -contains 'url') -or -not $Artifact.url) {throw "Place the verified companion asset '$($Artifact.filename)' beside Install.cmd."}
            $url=[uri]$Artifact.url; if($url.Scheme -ne 'https' -or $url.UserInfo) {throw 'Downloads require HTTPS without embedded credentials.'}
            Add-Type -AssemblyName System.Net.Http
            [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
            $handler=New-Object Net.Http.HttpClientHandler; $handler.AllowAutoRedirect=$false
            $client=New-Object Net.Http.HttpClient($handler); $client.Timeout=[TimeSpan]::FromHours(2)
            try {
                $response=$client.GetAsync($url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    if([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {throw 'Redirected artifact download is blocked; use the manifest URL or adjacent verified asset.'}
                    $response.EnsureSuccessStatusCode() | Out-Null
                    $stream=[IO.File]::Create($temp)
                    try {$response.Content.CopyToAsync($stream).GetAwaiter().GetResult()} finally {$stream.Dispose()}
                } finally {$response.Dispose()}
            } finally {$client.Dispose(); $handler.Dispose()}
        }
        Assert-KitArtifact $temp $Artifact; [IO.File]::Move($temp,$Destination); return $Destination
    } finally {if(Test-Path -LiteralPath $temp) {Remove-Item -LiteralPath $temp -Force}}
}
Export-ModuleMember -Function Assert-KitArtifact,Save-KitVerifiedArtifact
