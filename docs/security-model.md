# Security model

## Trust anchors

Three properties decide whether a package may be installed, and only the first is implemented by
this repository.

| Property | Enforced by | Consequence |
| --- | --- | --- |
| Signature chains to a trusted root and matches the publisher id | `AppXDeploymentServer` during `Add-AppxPackage` | A package that is not signed by Microsoft Corporation cannot be registered as `Microsoft.GamingServices` or `Microsoft.GamingApp` |
| Package identity equals the expected identity | this repository, before deployment | A Microsoft-signed package for a different product is not installed |
| Publisher distinguished name is Microsoft Corporation | this repository, before deployment | A failure is reported with a readable reason instead of an opaque HRESULT |

The repository therefore does not weaken the operating system's trust decision. It adds an early,
legible check and refuses to continue when a check fails. There is no switch that disables the
identity or publisher checks, and none is planned.

## Checks performed on every artifact

| Check | What it establishes | What it does not establish |
| --- | --- | --- |
| `AppxMetadata/AppxBundleManifest.xml` parses and `Identity/@Name` matches | the artifact is a bundle for the requested product | that the artifact is authentic |
| `Identity/@Publisher` equals the Microsoft distinguished name | the manifest claims Microsoft as publisher | that the signature agrees |
| `AppxSignature.p7x` decodes and the signer subject is Microsoft Corporation | the signing block is present and names Microsoft | full chain and revocation state |

The third check is intentionally described as weak. Certificate chain validation, revocation
handling and the publisher-id derivation are performed by the deployment service, which is the
component designed for it. Reimplementing that logic in PowerShell would add failure modes without
adding assurance.

## Download channel

| Control | Implementation |
| --- | --- |
| Scheme | every URL is rebuilt as `https`; an `http` URL from the catalog is upgraded, not followed |
| Host allow list | only `*.delivery.mp.microsoft.com` is accepted |
| Missing hash pinning | Microsoft does not publish a per-file hash for these bundles, so integrity rests on TLS to a Microsoft host plus signature validation at install time |

A signed URL issued by the Microsoft delivery service is bound to the requested path. A modified
catalog response cannot redirect the download to a non-Microsoft host, because the host allow list
is applied to the response rather than trusted from it.

## Third-party component

Version resolution uses `store.rg-adguard.net`, an independent catalog helper that forwards to
Microsoft's product and delivery APIs. Its output is treated as untrusted input:

- only HTTPS responses are parsed;
- every entry is re-validated against the Microsoft host allow list;
- the selected artifact must match the expected identity and publisher;
- the artifact must pass the signature block check.

The realistic worst case for a compromised resolver is therefore a *valid Microsoft package for the
same identity at a different version*, for example an older one. Version comparison and the
`-Force` semantics bound that: without `-Force`, a package older than the installed one is not
installed. A resolver cannot deliver arbitrary code, because arbitrary code cannot be signed as
`Microsoft.GamingServices_8wekyb3d8bbwe`.

Users who want to remove the dependency entirely can pass `-GamingServicesBundle` /
`-XboxAppBundle` with a bundle they obtained and verified themselves, or `-GamingServicesUrl` with
a URL they trust. The provenance checks still apply.

## Privilege

The normal path runs unelevated. Package registration for a user-scope package does not require
administrator rights; the service definitions declared by the package are created by the deployment
service running as `SYSTEM`, not by the caller.

Administrator rights are requested only for `-StopServices`, which uses `Stop-Service` and
`Start-Service` on `GamingServices` and `GamingServicesNet`, and only when the switch is present.
The script refuses `-StopServices` in an unelevated session instead of silently degrading.

## What this tool does not do

- No modification of service start types, service configuration or update policy. `Test-Environment.ps1`
  reads those values; no script writes them.
- No modification of `C:\Windows\SoftwareDistribution` or the update cache.
- No patching of executables, DLLs or game content.
- No license or entitlement change. Nothing here makes a title run without the license the platform
  already granted.
- No telemetry. The only outbound requests are the catalog POST (product id, ring, locale) and
  GET requests for the resolved payload URLs. Logs stay on disk under `%LOCALAPPDATA%\XboxOfflineUpdate`.

## Residual risk

| Risk | Assessment |
| --- | --- |
| A Microsoft-signed package is malicious | out of scope; the same artifact would be delivered by the Store |
| A local administrator replaces the scripts | out of scope; audit the checkout before use |
| The title requires a version newer than the public Retail ring | possible during staged rollouts; re-run later, or supply a bundle from the ring the title expects |
| Registry or service state was already altered by other tooling | the updater does not repair servicing state, and it will fail loudly rather than guess |
| The out-of-band version is not known to the Store | the Store compares installed versions and normally treats a newer one as current; if it later offers an older payload it is not installed without `-Force` |

## Auditing a checkout

```powershell
# Only read-only diagnostics and error guidance should match.
Select-String -Path .\scripts\*.ps1, .\scripts\lib\*.ps1 -Pattern 'wuauserv|UsoSvc|dosvc|WindowsUpdate'

# Every state-changing call in the repository.
Select-String -Path .\scripts\*.ps1, .\scripts\lib\*.ps1 `
    -Pattern 'Add-AppxPackage|Stop-Service|Start-Service|New-Item|Remove-Item|Move-Item|Invoke-WebRequest'
```

The set of state-changing operations is small and complete: create directories, write log files,
move a downloaded `.partial` file into place, optionally stop and start the two Gaming Services
services, and call `Add-AppxPackage`.
