Set-StrictMode -Version 2.0
function Protect-KitPath([string]$Path,[string[]]$AdditionalSids=@()) {
    $item=Get-Item -LiteralPath $Path
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Protected paths cannot be links or reparse points.'}
    $acl=Get-Acl -LiteralPath $Path; $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.Access)) {$acl.RemoveAccessRuleSpecific($rule)}
    $inherit=[Security.AccessControl.InheritanceFlags]::None
    if($item.PSIsContainer) {$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}
    foreach($sid in @('S-1-5-18','S-1-5-32-544')+$AdditionalSids) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl',$inherit,[Security.AccessControl.PropagationFlags]::None,'Allow'); $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))); Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-KitSecretDirectory {
    $ctx=Get-KitContext; $path=Join-Path (Split-Path $ctx.Path -Parent) 'secrets'
    [IO.Directory]::CreateDirectory($path) | Out-Null; Protect-KitPath $path; return $path
}
function New-KitPassword {
    $bytes=New-Object byte[] 36; $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {$rng.GetBytes($bytes); $text='Mk1!'+[Convert]::ToBase64String($bytes); return ConvertTo-SecureString $text -AsPlainText -Force}
    finally {[Array]::Clear($bytes,0,$bytes.Length); $rng.Dispose(); $text=$null}
}
function Save-KitSecret([string]$Name,[Security.SecureString]$Value) {
    if($Name -notmatch '^[a-z][a-z0-9-]{0,63}$') {throw 'Invalid secret reference.'}
    $path=Join-Path (Get-KitSecretDirectory) ($Name+'.dpapi')
    if(Test-Path -LiteralPath $path) {return} # create once: interrupted setup retains credentials
    Add-Type -AssemblyName System.Security
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Value); $bytes=$null
    try {
        $chars=New-Object char[] $Value.Length; [Runtime.InteropServices.Marshal]::Copy($ptr,$chars,0,$chars.Length)
        $bytes=[Text.Encoding]::Unicode.GetBytes($chars); [Array]::Clear($chars,0,$chars.Length)
        $encrypted=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$stream.Write($encrypted,0,$encrypted.Length)} finally {$stream.Dispose()}
        Protect-KitPath $path
    } finally {if($bytes) {[Array]::Clear($bytes,0,$bytes.Length)}; [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)}
}
function Get-KitSecret([string]$Name) {
    if($Name -notmatch '^[a-z][a-z0-9-]{0,63}$') {throw 'Invalid secret reference.'}
    Add-Type -AssemblyName System.Security
    $path=Join-Path (Get-KitSecretDirectory) ($Name+'.dpapi'); Protect-KitPath $path
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $chars=[Text.Encoding]::Unicode.GetChars($bytes); $value=New-Object Security.SecureString
        foreach($ch in $chars) {$value.AppendChar($ch)}; $value.MakeReadOnly(); return $value
    } finally {[Array]::Clear($bytes,0,$bytes.Length); if($chars) {[Array]::Clear($chars,0,$chars.Length)}}
}
function Get-KitCredential([string]$Name,[string]$Account) {
    $dir=Get-KitSecretDirectory
    if(-not (Test-Path -LiteralPath (Join-Path $dir ($Name+'.dpapi')))) {Save-KitSecret $Name (New-KitPassword)}
    return New-Object Management.Automation.PSCredential($Account,(Get-KitSecret $Name))
}
Export-ModuleMember -Function *-Kit*
