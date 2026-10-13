Set-StrictMode -Version 2.0
function Initialize-KitWindowsNative {
    if('MediaKit.NativeWindows' -as [type]) {return}
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Security;
namespace MediaKit {
 public static class NativeWindows {
  [DllImport("userenv.dll", CharSet=CharSet.Unicode)] static extern int CreateProfile(string sid,string user,StringBuilder path,uint size);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiOpenPackageW(string path,out uint handle);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiSetPropertyW(uint handle,string name,string value);
  [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiDoActionW(uint handle,string action);
  [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint handle);
  [DllImport("msi.dll")] static extern uint MsiSetInternalUI(uint level,IntPtr window);
  [DllImport("msi.dll",CharSet=CharSet.Unicode)] static extern uint MsiEnableLogW(uint mode,string path,uint attrs);
  [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES {public uint Length;public IntPtr RootDirectory;public IntPtr ObjectName;public uint Attributes;public IntPtr SecurityDescriptor;public IntPtr SecurityQualityOfService;}
  [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING {public ushort Length;public ushort MaximumLength;public IntPtr Buffer;}
  [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,ref LSA_OBJECT_ATTRIBUTES attrs,uint access,out IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy,byte[] sid,LSA_UNICODE_STRING[] rights,uint count);
  [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
  [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
  public static string EnsureProfile(string sid,string user) {var p=new StringBuilder(1024);int result=CreateProfile(sid,user,p,1024);if(result!=0 && result!=unchecked((int)0x800700B7)) Marshal.ThrowExceptionForHR(result);return p.ToString();}
  public static void GrantRight(byte[] sid,string right) {var attrs=new LSA_OBJECT_ATTRIBUTES();attrs.Length=(uint)Marshal.SizeOf(attrs);IntPtr policy;uint result=LsaOpenPolicy(IntPtr.Zero,ref attrs,0x810,out policy);if(result!=0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(result));IntPtr text=Marshal.StringToHGlobalUni(right);try {var r=new LSA_UNICODE_STRING {Length=(ushort)(right.Length*2),MaximumLength=(ushort)((right.Length+1)*2),Buffer=text};result=LsaAddAccountRights(policy,sid,new[]{r},1);if(result!=0) throw new System.ComponentModel.Win32Exception((int)LsaNtStatusToWinError(result));}finally {Marshal.FreeHGlobal(text);LsaClose(policy);}}
  public static void InstallMsi(string path,string account,SecureString password,string hidden,string secure) {
   uint handle=0;IntPtr ptr=IntPtr.Zero;uint oldUI=MsiSetInternalUI(2,IntPtr.Zero);
   try {
    // Disable explicit logging; hidden properties also cover machine-policy logs.
    MsiEnableLogW(0,null,0);
    Check(MsiOpenPackageW(path,out handle));
    Check(MsiSetPropertyW(handle,"MsiHiddenProperties",hidden));Check(MsiSetPropertyW(handle,"SecureCustomProperties",secure));
    Check(MsiSetPropertyW(handle,"SERVICE_USERNAME",account));Check(MsiSetPropertyW(handle,"LOGON_USERNAME",account));
    Check(MsiSetPropertyW(handle,"SERV_LOGON_TYPE","ServiceAccount"));Check(MsiSetPropertyW(handle,"ASSISTANCE_START_VIA_REGISTRY","0"));
    ptr=Marshal.SecureStringToGlobalAllocUnicode(password);string value=Marshal.PtrToStringUni(ptr);
    Check(MsiSetPropertyW(handle,"SERVICE_PASSWORD",value));Check(MsiSetPropertyW(handle,"LOGON_PASSWORD",value));value=null;
    uint result=MsiDoActionW(handle,"INSTALL");if(result!=0 && result!=3010) throw new InvalidOperationException("Wrapper MSI failed with code "+result);
   } finally {if(handle!=0) {MsiSetPropertyW(handle,"SERVICE_PASSWORD","");MsiSetPropertyW(handle,"LOGON_PASSWORD","");MsiCloseHandle(handle);}if(ptr!=IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(ptr);MsiSetInternalUI(oldUI,IntPtr.Zero);}
  }
  static void Check(uint code) {if(code!=0) throw new InvalidOperationException("Windows Installer operation failed with code "+code);}
 }
}
'@
}
function New-KitServiceIdentity([string]$Name,[Security.SecureString]$Password) {
    $ctx=Get-KitContext; $id=$ctx.State.config.installationId; $marker="MediaKit:$id"
    $user=Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if($user) {
        if($user.Description -ne $marker) {throw "Local account '$Name' already exists and belongs to another installation."}
    } else {$user=New-LocalUser -Name $Name -Password $Password -Description $marker -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword}
    $admins=Get-LocalGroupMember -SID 'S-1-5-32-544'
    if(@($admins | Where-Object {$_.SID -eq $user.SID}).Count) {throw 'Installer service identities must never be administrators.'}
    Register-KitResource 'account' $Name -Sid $user.SID.Value
    Initialize-KitWindowsNative
    $sidBytes=New-Object byte[] $user.SID.BinaryLength; $user.SID.GetBinaryForm($sidBytes,0)
    if($Name -eq $ctx.State.config.plex.account) {
        [MediaKit.NativeWindows]::GrantRight($sidBytes,'SeServiceLogonRight')
        [MediaKit.NativeWindows]::EnsureProfile($user.SID.Value,$Name) | Out-Null
        Get-KitProfilePath $user.SID.Value | Out-Null
    } else {
        [MediaKit.NativeWindows]::GrantRight($sidBytes,'SeDenyInteractiveLogonRight')
        [MediaKit.NativeWindows]::GrantRight($sidBytes,'SeDenyRemoteInteractiveLogonRight')
    }
    return $user
}
function Add-KitModifyAccess([string]$Path,[string]$Sid) {
    $acl=Get-Acl -LiteralPath $Path
    $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($Sid)),'Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.SetAccessRule($rule); Set-Acl -LiteralPath $Path -AclObject $acl
}
function New-KitMediaShare($Config,[Management.Automation.PSCredential]$Credential) {
    $ctx=Get-KitContext; $marker="MediaKit:$($Config.installationId)"
    $existing=Get-SmbShare -Name $Config.smb.share -ErrorAction SilentlyContinue
    if($existing -and ($existing.Description -ne $marker -or $existing.Path -ne $Config.mediaRoot)) {throw 'An unrelated SMB share already uses this name.'}
    $ownerFile=Join-Path $Config.mediaRoot '.starter-kit-installation.json'
    if(Test-Path -LiteralPath $ownerFile) {
        $old=Get-Content -LiteralPath $ownerFile -Raw | ConvertFrom-Json
        if($old.installationId -ne $Config.installationId) {throw 'Media root belongs to another installation.'}
    }
    foreach($path in @($Config.mediaRoot,(Join-Path $Config.mediaRoot 'downloads'),(Join-Path $Config.mediaRoot 'media\movies'),(Join-Path $Config.mediaRoot 'media\tv'))) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
        if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Media directories must be local directories, not links.'}
    }
    $smb=Get-LocalUser $Config.smb.account; $plex=Get-LocalUser $Config.plex.account
    # Preserve existing media ACLs; add only the two explicit dedicated identities.
    Add-KitModifyAccess $Config.mediaRoot $smb.SID.Value; Add-KitModifyAccess $Config.mediaRoot $plex.SID.Value
    if(-not (Test-Path -LiteralPath $ownerFile)) {[IO.File]::WriteAllText($ownerFile,(@{schemaVersion=1;installationId=$Config.installationId}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
    if(-not $existing) {New-SmbShare -Name $Config.smb.share -Path $Config.mediaRoot -Description $marker -ChangeAccess $Credential.UserName -FullAccess 'BUILTIN\Administrators' -EncryptData $true -CachingMode None | Out-Null}
    Set-SmbShare -Name $Config.smb.share -EncryptData $true -Force | Out-Null
    $access=@(Get-SmbShareAccess -Name $Config.smb.share)
    foreach($entry in $access) {
        $sid=(New-Object Security.Principal.NTAccount($entry.AccountName)).Translate([Security.Principal.SecurityIdentifier]).Value
        if($sid -notin @($smb.SID.Value,'S-1-5-32-544')) {throw 'Owned share has unexpected access grants. Remove them before continuing.'}
    }
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -EnableSMB2Protocol $true -RequireSecuritySignature $true -Force | Out-Null
    Register-KitResource 'share' $Config.smb.share; Register-KitResource 'media' $Config.mediaRoot
    New-KitFirewallRule $Config 'SMB' 445 $Config.guestIP
    New-KitFirewallRule $Config 'Plex' 32400 'LocalSubnet'
}
function New-KitFirewallRule($Config,[string]$Suffix,[int]$Port,[string]$Remote) {
    $name="MediaKit-$($Config.installationId)-$Suffix"; $marker="MediaKit:$($Config.installationId)"
    $existing=Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if($existing -and $existing.Description -ne $marker) {throw 'Conflicting firewall ownership.'}
    if(-not $existing) {New-NetFirewallRule -Name $name -DisplayName "MediaKit $Suffix" -Description $marker -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $Remote -Profile Private | Out-Null}
    Register-KitResource 'firewall' $name
}
function Install-KitPlex($Config,$Manifest) {
    $ctx=Get-KitContext; $cache=Join-Path (Split-Path $ctx.Path -Parent) 'artifacts'
    $path=Save-KitVerifiedArtifact $Manifest.artifacts.plex (Join-Path $cache $Manifest.artifacts.plex.filename)
    if(@($ctx.State.resources | Where-Object {$_.type -eq 'plex-install'}).Count) {return}
    Write-Host 'In Plex setup, clear the final Launch Plex Media Server checkbox before finishing.'
    $process=Start-Process -FilePath $path -Wait -PassThru
    if($process.ExitCode -notin @(0,3010)) {throw 'Plex installation did not complete successfully.'}
    if(Get-Process -Name 'Plex Media Server' -ErrorAction SilentlyContinue) {throw 'Plex was launched under the interactive user. Exit Plex, clear Launch on setup, and rerun Install.cmd.'}
    Register-KitResource 'plex-install' 'Plex Media Server' -Path $path
}
function Get-KitMsiPublicProperties($Config) {
    return @{SERVICE_USERNAME="$($Config.smb.domain)\$($Config.plex.account)";LOGON_USERNAME="$($Config.smb.domain)\$($Config.plex.account)";MsiHiddenProperties='SERVICE_PASSWORD;LOGON_PASSWORD';SecureCustomProperties='SERVICE_USERNAME;SERVICE_PASSWORD;LOGON_USERNAME;LOGON_PASSWORD';SERV_LOGON_TYPE='ServiceAccount'}
}
function Install-KitPlexService($Config,$Artifact,[Management.Automation.PSCredential]$Credential) {
    $ctx=Get-KitContext; $service=Get-CimInstance Win32_Service -Filter "Name='PlexService'" -ErrorAction SilentlyContinue
    if($service) {
        Assert-KitOwnership 'service' 'PlexService' $Config.installationId $ctx.State.resources | Out-Null
        if($service.StartName -ne $Credential.UserName) {throw 'PlexService uses a different profile. Migration requires manual review.'}
    } else {
        $path=Save-KitVerifiedArtifact $Artifact (Join-Path (Join-Path (Split-Path $ctx.Path -Parent) 'artifacts') $Artifact.filename)
        Initialize-KitWindowsNative; $p=Get-KitMsiPublicProperties $Config
        # Intent record survives a crash after MSI creates the service. StartName is revalidated on resume.
        Register-KitResource 'service' 'PlexService' -Path $path
        [MediaKit.NativeWindows]::InstallMsi($path,$Credential.UserName,$Credential.Password,$p.MsiHiddenProperties,$p.SecureCustomProperties)
    }
    Set-Service -Name PlexService -StartupType Automatic
    & "$env:SystemRoot\System32\sc.exe" failure PlexService reset= 86400 actions= restart/20000/restart/20000/restart/20000 | Out-Null
    if($LASTEXITCODE -ne 0) {throw 'Could not configure Plex service recovery.'}
    $user=Get-LocalUser $Config.plex.account
    Invoke-KitUserHive $user.SID.Value {param($hive,$profile)
        $run=Join-Path $hive 'Software\Microsoft\Windows\CurrentVersion\Run'
        if(Test-Path -LiteralPath $run) {Remove-ItemProperty -LiteralPath $run -Name 'Plex Media Server' -ErrorAction SilentlyContinue}
    }
    Start-Service PlexService
}
function Get-KitPlexClaimPath($Config,[string]$Profile) {return $Profile.TrimEnd('\')+'\AppData\Local\Plex Media Server\Setup Plex.html'}
function Open-KitPlexClaim($Config) {
    $user=Get-LocalUser $Config.plex.account; $profile=Get-KitProfilePath $user.SID.Value; $path=Get-KitPlexClaimPath $Config $profile
    if(-not (Test-Path -LiteralPath $path)) {throw 'The Plex service has not created Setup Plex.html yet. Check Status and retry Open Plex.'}
    # Never echo the protected claim link or copy it to a public shortcut.
    Start-Process -FilePath $path
}
function Get-KitPlexStatus($Config) {
    $ctx=Get-KitContext; $s=Get-CimInstance Win32_Service -Filter "Name='PlexService'" -ErrorAction SilentlyContinue
    $health=$false
    if($s) {Assert-KitOwnership 'service' 'PlexService' $Config.installationId $ctx.State.resources | Out-Null; $health=$s.State -eq 'Running' -and $s.StartName -eq "$($Config.smb.domain)\$($Config.plex.account)"}
    return [pscustomobject]@{installationId=$Config.installationId;releaseId=$Config.releaseId;running=$health;account=$Config.plex.account;interactiveSteps=@('Plex sign-in and Movies/TV library setup','Plex Pass hardware-transcoding test before Windows sign-in')}
}
Export-ModuleMember -Function *-Kit*
