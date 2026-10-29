# Troubleshooting

## Symptoms and remedies

| Symptom | Likely cause | Remedy |
| --- | --- | --- |
| Store refuses to update Gaming Services and mentions Windows Update | `wuauserv` disabled; the Store's acquisition stage cannot run | use this updater |
| Game starts, then stops with "an update to Xbox services is required" | installed Gaming Services is below the title's minimum | `.\Update-Xbox.cmd` |
| Xbox app shows "an update to the app is required" and never passes it | the app itself is below the version the title expects | run the updater without `-SkipXboxApp` |
| Updater reports `No action required` but the title still complains | another package in the chain is stale, or the title expects a version from a non-Retail ring | run without `-SkipXboxApp`, restart the title, and check `Test-Environment.ps1` output for all identities |
| `0x80073CF3` on the first deployment attempt | a framework package is missing | re-run; the updater installs the missing framework and retries automatically |
| `0x80073CF3` persists after several runs | the catalog has no deployable payload for that framework | file an issue with the log; the package must be supplied manually |
| `0x80073D02`, `0x80073D05` | a package file is held open | close the Xbox app, the Store and any running game; if it persists, re-run elevated with `-StopServices` |
| `0x80070005` | user-scope deployment rejected on this configuration | re-run from an elevated PowerShell |
| `0x80073CF9` | deployment service in a bad state | restart the computer; if it recurs, check `AppXSvc` |
| Catalog request fails | `store.rg-adguard.net` unreachable | supply a bundle with `-GamingServicesBundle`; see below for obtaining one |
| Xbox app reports no network connection while browsers work | a system proxy on `127.0.0.1` (Clash, v2ray, Steam++) and the AppContainer loopback restriction | see the proxy section below |

## HRESULT reference

| HRESULT | Meaning | Action |
| --- | --- | --- |
| `0x80070422` | the service cannot be started because it is disabled | not an error from this tool; it is the Store/WU symptom this repository exists to avoid |
| `0x80073CF3` | package dependency or framework not found | automatic in this tool; manual when the catalog lacks the framework |
| `0x80073CF0` | archive invalid or incomplete | delete the cached file under `%LOCALAPPDATA%\XboxOfflineUpdate\packages` and re-run |
| `0x80073CF6` | package could not be registered | check the deployment log; a damaged prior registration may need removal |
| `0x80073CF9` | deployment rejected by `AppXSvc` | reboot, then re-run |
| `0x80073CFB` | package already installed at this or a higher version | nothing to do |
| `0x80073D02` | package in use, or another deployment running | close the applications using it |
| `0x80073D05` | package file held open by a process | close all Xbox related processes |
| `0x80070005` | access denied | elevate the session |

## Collecting diagnostics

```powershell
# Read-only report: versions, service states, policy key presence, DNS, disk space
.\scripts\Test-Environment.ps1

# Deployment events for the last hour
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 30 |
    Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-1) } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

# Everything the deployment API recorded for one attempt
Get-AppxLog -ActivityId 00000000-0000-0000-0000-000000000000
```

Every failure message printed by the updater contains the `ActivityId` that `Get-AppxLog` expects,
and the same value is written to the log file at `%LOCALAPPDATA%\XboxOfflineUpdate\logs`.

## Obtaining a bundle manually

When the resolver host is unreachable, the project page for each product exposes the payload:

- Gaming Services: `https://apps.microsoft.com/detail/9mwpm2cqnlhn`
- Xbox app: `https://apps.microsoft.com/detail/9mv0b5hzvk9z`

The updater accepts the resulting file directly:

```powershell
.\scripts\Invoke-XboxOfflineUpdate.ps1 `
    -GamingServicesBundle .\Microsoft.GamingServices_<version>_neutral_~_8wekyb3d8bbwe.appxbundle
```

The identity, publisher and signature checks still run. A bundle that fails them is not installed.

## Proxy on 127.0.0.1 and UWP networking

UWP and MSIX applications run inside an AppContainer. Connections from an AppContainer to the
loopback interface are blocked unless the package holds a loopback exemption. When a desktop proxy
listens on `127.0.0.1` (Clash, v2rayN, Steam++ and similar), Store and Xbox applications can report
no connectivity while browsers and Win32 games work normally.

This is unrelated to package deployment, which is why the updater succeeds in exactly those
environments, but it does affect sign-in and Store browsing inside the app. The exemption is granted
per package family:

```powershell
# Elevated. Grants the Xbox app access to loopback, which is required for a local proxy.
CheckNetIsolation.exe LoopbackExempt -a -n=Microsoft.GamingApp_8wekyb3d8bbwe

# Review and remove
CheckNetIsolation.exe LoopbackExempt -s
CheckNetIsolation.exe LoopbackExempt -d -n=Microsoft.GamingApp_8wekyb3d8bbwe
```

Granting the exemption widens what that application may reach on the local machine. Apply it only
when a loopback proxy is in use and the trade-off is understood.

## Reference failure sequence

The failure mode this project was built around, recorded on Windows 11 24H2 with `wuauserv` and
`dosvc` both disabled:

1. `Microsoft.GamingServices` was `34.111.20001.0`; the title required a newer version.
2. The Store offered no usable update path because the Windows Update service was disabled.
3. A Retail `39.118.21002.0` bundle was downloaded and deployed; the service pair was re-created
   from the new package directory without elevation.
4. The Xbox app then reported that the app itself was too old; deploying `2610.1001.20.0` failed
   with `0x80073CF3` because `Microsoft.WindowsAppRuntime.2` was absent.
5. Installing `Microsoft.WindowsAppRuntime.2 2.6.4.0` from the same catalog response resolved the
   dependency; the app deployed and started.
6. The title launched without the services gate.

Steps 3 and 5 are what this repository automates. Step 4 is why `-SkipXboxApp` exists but is not
the default.
