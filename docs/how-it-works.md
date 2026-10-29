# How the update path works

This document describes the components involved, the artifact format, and why bypassing the
Windows Update client is safe for the packages in scope.

## Two separate delivery stages

Windows installs Store packages through two independent mechanisms.

| Stage | Components | Function |
| --- | --- | --- |
| Acquisition | `wuauserv`, `UsoSvc`, `BITS`, `dosvc` (Delivery Optimization), Store front end | Determines that an update exists, downloads payloads into the SoftwareDistribution cache |
| Installation | `AppXSvc`, `ClipSVC`, `InstallService`, deployment API | Validates the package signature, stages files, registers the package, activates declared services |

The Store drives both. `Add-AppxPackage` drives only the second. When `wuauserv` is disabled, the
acquisition stage cannot run, so the Store can report download or update failures (`0x80070422` is
the representative one) even though installation itself is unaffected.

Which Store updates are resolved through the client update stack is not documented and varies by
package and Store version. That variability explains the common report: most Store applications
update normally, while one or two system-level packages stall. The updater in this repository does
not try to reason about that decision. It supplies the artifacts and the installation request, so
the decision point is no longer in the path.

## Artifact format

A `.appxbundle` or `.msixbundle` is a ZIP archive:

```
AppxMetadata/AppxBundleManifest.xml   bundle identity, version, payload list, dependencies
AppxBlockMap.xml                      per-block hashes of the archive contents
AppxSignature.p7x                     4-byte "PKCX" magic followed by a DER PKCS#7 blob
<Package>_<version>_x64.appx          per-architecture payload
<Package>_<version>_language-xx.appx  resource payload
```

Package identity is a tuple of `Name`, `Version`, `Publisher` (a distinguished name) and
`ProcessorArchitecture`. The 13-character publisher id in a package family name
(`Microsoft.GamingServices_8wekyb3d8bbwe`) is derived from that distinguished name. The deployment
service checks that the package signing certificate chains to a trusted root *and* corresponds to
that derived id. This is the reason the identity checks in this repository are meaningful: a
package cannot claim `Microsoft.GamingServices_8wekyb3d8bbwe` unless it is signed by the matching
Microsoft certificate.

### Signature validity is not certificate lifetime

The signing block carries RFC 3161 timestamps. A package signed before the signing certificate's
`NotAfter` remains valid after that date; the deployment service evaluates the timestamp, not the
current clock. A verifier that rejects a package because the leaf certificate has expired is wrong.
This updater checks the signer subject and the manifest publisher, and deliberately does not
enforce certificate lifetime.

## Deployment sequence

1. `Invoke-XboxOfflineUpdate.ps1` resolves the newest payload whose identity and architecture match.
2. The bundle is downloaded and inspected: manifest identity, manifest publisher, signature block.
3. The installed version is read with `Get-AppxPackage`. When it is equal or newer, the package is
   skipped unless `-Force` is supplied.
4. `Add-AppxPackage -Path <bundle> -ForceApplicationShutdown` hands the file to the deployment
   service.
5. The deployment service validates the signature, stages the directory under
   `C:\Program Files\WindowsApps`, registers the package for the invoking user, and re-creates the
   services declared in the manifest:
   - `GamingServices` (`GamingServices.exe`)
   - `GamingServicesNet` (`GamingServicesNet.exe`)

   Both service image paths are rewritten to the new package directory; this is observable with
   `Get-CimInstance Win32_Service -Filter "Name='GamingServices'"`.
6. A `Microsoft-Windows-AppXDeploymentServer/Operational` event records the result, including the
   `ActivityId` that appears in any failure message.

## Dependencies

GDK-based packages declare framework dependencies in their inner manifest, for example:

```xml
<PackageDependency Name="Microsoft.WindowsAppRuntime.2" MinVersion="2.1.1.0" />
```

Frameworks are separate packages with their own identities, published by the same publisher and
listed in the same catalog response. When deployment reports `0x80073CF3`, the message names the
framework and its minimum version. The updater resolves that identity from the same listing,
applies the same provenance checks, installs it, and retries. Frameworks are never downloaded from
a source that is not the resolved catalog for the same product.

Resolution order for frameworks is `x64` then `neutral`, matching the architecture of the inner
application package.

## Version numbering

Versions are four numeric components (`39.118.21002.0`). No public scheme maps them to release
dates, so the updater treats them as monotonic and compares numerically, component by component.
A version is never inferred from a file name suffix, a date, or a release channel label.

## What the title sees

A GDK title queries the Gaming Services version through the runtime and compares it against a
minimum it was compiled with. When the installed version is lower, the title stops with the "update
Xbox services" gate. The comparison is on installed state, not on Store state; a newer package
installed out-of-band satisfies the check exactly like a Store-delivered one.

## Reproducing the verification manually

```powershell
$bundle = 'C:\path\Microsoft.GamingServices_39.118.21002.0_neutral_~_8wekyb3d8bbwe.appxbundle'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [IO.Compression.ZipFile]::OpenRead($bundle)
$entry = $zip.GetEntry('AppxSignature.p7x')
$stream = $entry.Open(); $buffer = New-Object IO.MemoryStream
$stream.CopyTo($buffer); $stream.Dispose(); $zip.Dispose()

$bytes = $buffer.ToArray()          # first 4 bytes are the "PKCX" magic
$blob = New-Object byte[] ($bytes.Length - 4)
[Array]::Copy($bytes, 4, $blob, 0, $blob.Length)

$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
$cms.Decode($blob)
$cms.SignerInfos[0].Certificate.Subject
```

The subject must be `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US`.
