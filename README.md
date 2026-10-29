# Updating Xbox Gaming Services without enabling Windows Update

Out-of-band updater for the two Microsoft Store packages that Xbox PC titles depend on.

| Package | Identity | Store product id |
| --- | --- | --- |
| Gaming Services | `Microsoft.GamingServices` | `9MWPM2CQNLHN` |
| Xbox app | `Microsoft.GamingApp` | `9MV0B5HZVK9Z` |

The tool resolves the current bundles, downloads them from Microsoft delivery hosts, verifies
identity, publisher and signature block, and deploys them with `Add-AppxPackage`. Windows Update
is never enabled, started, reconfigured or used as a delivery channel.

## Background

Microsoft Store package updates are delivered through the Windows client update stack. When the
Windows Update service (`wuauserv`) is disabled, as a deliberate user or policy choice, the Store
can fail to update packages that it would otherwise update silently. A typical failure surfaces as
`0x80070422` (*the service cannot be started because it is disabled or because it has no enabled
devices associated with it*) or as an update that never completes.

Xbox PC titles built on the Microsoft Game Development Kit query the installed Gaming Services
version at startup. A title that requires a newer version than the one installed refuses to start
and reports that Xbox services must be updated. The in-box remedy is the Store update flow, which
requires the service that the user has intentionally disabled.

The two concerns are separable: the Windows Update client is one *delivery channel* for Store
packages, while `AppXDeploymentServer` (`AppXSvc`) is the component that actually installs them.
Deploying a signed bundle directly uses the latter and does not involve the former.

## What the tool does

1. Resolves the current payload for each product id and selects the highest version matching the
   expected package identity.
2. Downloads the bundle from a Microsoft delivery host over HTTPS. Any URL that does not resolve
   to `*.delivery.mp.microsoft.com` is discarded.
3. Verifies the downloaded bundle before deployment:
   - package manifest identity equals the expected identity;
   - manifest publisher is Microsoft Corporation;
   - the `AppxSignature.p7x` signing block decodes and its signer subject is Microsoft Corporation.
4. Compares the resolved version with the installed version and stops when nothing is older.
5. Deploys with `Add-AppxPackage`. If deployment reports `0x80073CF3` (missing framework), the
   required framework is resolved from the same catalog, verified with the same checks, installed,
   and deployment is retried. This repeats for up to five frameworks.
6. Reports the installed version after deployment and writes a full log.

## What the tool does not do

- It does not enable, disable, start, stop or reconfigure `wuauserv`, `UsoSvc`, `dosvc`, `BITS` or
  `WaaSMedicSvc`.
- It does not write to `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` or any other
  servicing policy key.
- It does not modify game files, patch binaries, alter licensing or bypass DRM. The packages it
  installs are unmodified Microsoft artifacts.
- It does not accept unsigned, re-signed or third-party packages. There is no switch that disables
  the provenance checks.
- It does not install anything outside `Microsoft.GamingServices`, `Microsoft.GamingApp` and the
  framework packages that the former declares as dependencies.

## Requirements

- Windows 10 version 2004 (build 19041) or later; Windows 11. x64 or arm64.
- Windows PowerShell 5.1 (in-box) or PowerShell 7.x.
- Network access to `store.rg-adguard.net` (version resolution) and `*.delivery.mp.microsoft.com`
  (payload download).
- Administrator rights are **not** required for the normal path. They are required only for
  `-StopServices`.

## Quick start

```powershell
git clone https://github.com/MiCake233/Bypass-Windows-System-Updates-to-Update-Xbox.git
cd Bypass-Windows-System-Updates-to-Update-Xbox
.\Update-Xbox.cmd
```

`Update-Xbox.cmd` runs the updater with the default parameters and pauses so the result stays
visible. To inspect the plan first, without downloading or deploying anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-XboxOfflineUpdate.ps1 -DryRun
```

## Parameters

| Parameter | Effect |
| --- | --- |
| `-DryRun` | Resolve versions and print the plan. No download, no deployment. |
| `-SkipXboxApp` | Update Gaming Services only. |
| `-StopServices` | Stop the Gaming Services service pair before deployment and start it afterwards. Requires elevation. Use when deployment fails with `0x80073D02` / `0x80073D05`. |
| `-Force` | Deploy even when the installed version is equal to or newer than the resolved one. |
| `-CacheRoot <path>` | Directory for logs and downloaded bundles. Default `%LOCALAPPDATA%\XboxOfflineUpdate`. |
| `-GamingServicesBundle <path>` | Deploy a local `.appxbundle` instead of resolving one. |
| `-GamingServicesUrl <url>` | Deploy from a specific download URL instead of resolving one. |
| `-XboxAppBundle <path>` | Same as above for the Xbox app bundle. |
| `-XboxAppUrl <url>` | Same as above for the Xbox app bundle. |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Nothing to do, or every requested package is current after the run. |
| `1` | Pre-flight, resolution, download or verification failure. |
| `6` | Deployment failed; the HRESULT and a remedy are printed and written to the log. |

## Reference run

Versions observed on a Windows 11 24H2 host where `wuauserv` and `dosvc` were disabled:

| Package | Before | After | Note |
| --- | --- | --- | --- |
| `Microsoft.GamingServices` | `34.111.20001.0` | `39.118.21002.0` | deployed without elevation |
| `Microsoft.GamingApp` | `2604.1001.9.0` | `2610.1001.20.0` | deployment first failed with `0x80073CF3` |
| `Microsoft.WindowsAppRuntime.2` | not installed | `2.6.4.0` | resolved automatically from the same catalog |

## Safety model

Short version: the operating system remains the trust anchor. `Add-AppxPackage` validates the
package signature chain and the publisher identity encoded in the package family name; a package
that is not signed by Microsoft Corporation cannot be registered as `Microsoft.GamingServices` or
`Microsoft.GamingApp`. The checks performed by this tool run *before* deployment to fail early and
to produce a readable reason; they do not replace the operating system check.

Details, including the threat model for the third-party catalog helper, are in
[docs/security-model.md](docs/security-model.md).

To audit the claim that Windows Update is untouched:

```powershell
Select-String -Path .\scripts\*.ps1, .\scripts\lib\*.ps1 `
    -Pattern 'wuauserv|UsoSvc|dosvc|WindowsUpdate|Set-Service|New-ItemProperty|Set-ItemProperty|sc\.exe|reg\.exe'
```

The only expected matches are the read-only diagnostics in `scripts\Test-Environment.ps1` and the
string that names the components in error guidance. No script changes a service start type or a
servicing registry value.

## Troubleshooting

| Symptom | Cause | Remedy |
| --- | --- | --- |
| `0x80073CF3` persists | a framework is still missing | re-run; the log names the framework it selected |
| `0x80073D02` / `0x80073D05` | Xbox app, Store or a game holds the package open | close them, or re-run elevated with `-StopServices` |
| `0x80070005` | user-scope deployment was rejected | re-run from an elevated PowerShell |
| Catalog request fails | the resolver host is unreachable | supply a known bundle with `-GamingServicesBundle` |
| Game still asks for an update | another package is stale | run without `-SkipXboxApp` |

Full table, error-code reference and the observed failure modes are in
[docs/troubleshooting.md](docs/troubleshooting.md).

## Repository layout

```
Update-Xbox.cmd                     one-click entry point
scripts\Invoke-XboxOfflineUpdate.ps1  main flow
scripts\lib\Common.ps1              constants, logging, version and name helpers
scripts\lib\StoreCatalog.ps1        product id to payload resolution
scripts\lib\PackageInspector.ps1    manifest and signature inspection
scripts\lib\Deployment.ps1          Add-AppxPackage wrapper and error mapping
scripts\Test-Environment.ps1        read-only diagnostics for issue reports
tests\Run-Tests.ps1                 parser and unit tests, no network, no deployment
docs\how-it-works.md                delivery path and why the split exists
docs\security-model.md              trust anchors, threat model, limitations
docs\troubleshooting.md             error codes and remedies
```

## Disclaimer

Not affiliated with Microsoft. The updater installs unmodified Microsoft packages; it does not
alter the Windows Update configuration, and it does not make a system more or less supported.
Microsoft may change the catalog or the package layout at any time, which is why the verification
layer refuses unknown identities instead of guessing.

## License

MIT. See [LICENSE](LICENSE).
