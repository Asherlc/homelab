# PmsService candidate fork

This kit builds a modified PmsService 1.2.3 from the immutable upstream commit
`f1cb2de5795aa4149b4670b6f0f2973b41003c08`. Upstream source:
https://github.com/cjmurph/PmsService/tree/f1cb2de5795aa4149b4670b6f0f2973b41003c08

Copyright (c) 2014 Chris Murphy. PmsService is distributed under the MIT license;
the complete upstream license is retained in `licenses/LICENSE.md`. The
Media Kit modifications remove complete claim-link logging, hide and secure
both MSI password aliases, remove a broken postbuild copy, remove the upstream
temporary signing identity, and identify the fork as MSI 1.2.300 / assembly
1.2.300.1. The Windows service name remains `PlexService`.

`source.lock.json` records the upstream archive, patch, bundled DLLs, and WiX
3.14.1 download SHA-256 values. These are locally calculated locks of bytes from
the upstream HTTPS distributions, not claims of upstream signed provenance.
`redact-secrets.patch` contains the modifications. `fixtures/upstream/` preserves
the original files needed to exercise the actual source transformation and
compile the actual `GetWebLink` method in regression tests. No upstream PFX is
vendored or used to sign the candidate. The generated MSI is unsigned.

## Bundled installer extensions

`ActiveDirectory.dll`, `UserPrivileges.dll`, and `WixCommonUiExtension.dll`
originate from msiext (https://github.com/dblock/msiext), distributed under the
Eclipse Public License 1.0. Their complete upstream EPL is retained in
`licenses/msiext-license.txt`; the original PmsService source archive also
contains the corresponding source distribution at
`ThirdPartyLibraries/msiext-master.zip`. Recipients can obtain it directly in
the immutable PmsService archive URL recorded in `source.lock.json`. The DLLs
are hash-verified before build and remain unmodified.

## Other third-party components

The upstream archive's third-party notices for Newtonsoft.Json, MahApps.Metro,
Ookii.Dialogs, and FontAwesome.WPF are retained verbatim in `licenses/` and
included by the upstream MSI. NuGet dependencies retain the explicit upstream
project versions. WiX 3.14.1 and its extensions retain the license files in the
verified WiX build distribution. They are build tools, not kit runtime assets.

Build the candidate on Windows with Visual Studio MSBuild, the .NET Framework
4.7.2 targeting pack, WCF tooling, Git, and `build/Build-PmsService.ps1`. The
solution's `Release|Any CPU` configuration intentionally maps the service and
tray projects to x86; this does not make Plex Media Server itself 32-bit.

A successful hosted Windows build and regression test do not prove unattended
startup or Quick Sync on the friend's machine. Those remain acceptance gates.
