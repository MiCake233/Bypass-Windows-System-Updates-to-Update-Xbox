<#
.SYNOPSIS
    Read-only diagnostic report for the Xbox platform packages and the Windows Update state.

.DESCRIPTION
    Collects information that is useful when filing an issue. The script changes nothing:
    no package is installed, no service is started or stopped, no registry value is written.

.EXAMPLE
    .\Test-Environment.ps1
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Get-Location) 'xbox-offline-diagnostics.txt')
)

$ErrorActionPreference = 'Continue'

$lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Text)
    $lines.Add($Text)
    Write-Host $Text
}

Add-Line ('Generated: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K'))

$cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
Add-Line ('OS: ' + $cv.ProductName + ' ' + $cv.DisplayVersion + ' build ' + $cv.CurrentBuild + '.' + $cv.UBR)
Add-Line ('Architecture: ' + $env:PROCESSOR_ARCHITECTURE)
Add-Line ('PowerShell: ' + $PSVersionTable.PSVersion.ToString() + ' (' + $PSVersionTable.PSEdition + ')')

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
Add-Line ('Elevated: ' + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Add-Line ''

Add-Line '--- packages ---'
$identities = @(
    'Microsoft.GamingServices',
    'Microsoft.GamingApp',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.Xbox.TCUI',
    'Microsoft.WindowsAppRuntime.2',
    'Microsoft.VCLibs.140.00',
    'Microsoft.UI.Xaml.2.8'
)
foreach ($identity in $identities) {
    $packages = Get-AppxPackage -Name $identity -ErrorAction SilentlyContinue
    if ($null -eq $packages) {
        Add-Line ('  ' + $identity.PadRight(32) + ' not installed')
        continue
    }
    foreach ($package in $packages) {
        Add-Line ('  ' + $identity.PadRight(32) + ' ' + $package.Version + ' ' + $package.Architecture + ' ' + $package.PackageFullName)
    }
}
Add-Line ''

Add-Line '--- services (state only, nothing is modified) ---'
$serviceNames = @(
    'GamingServices',
    'GamingServicesNet',
    'AppXSvc',
    'ClipSVC',
    'InstallService',
    'wuauserv',
    'UsoSvc',
    'dosvc',
    'BITS',
    'WaaSMedicSvc'
)
foreach ($name in $serviceNames) {
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Add-Line ('  ' + $name.PadRight(20) + ' not present')
        continue
    }
    Add-Line ('  ' + $name.PadRight(20) + ' ' + $service.Status + ' / ' + $service.StartType)
}
Add-Line ''

Add-Line '--- windows update policy keys (read only) ---'
$policyPaths = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
)
foreach ($path in $policyPaths) {
    Add-Line ('  ' + $path + ' exists: ' + (Test-Path -Path $path))
}
Add-Line ''

Add-Line '--- network ---'
$proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
Add-Line ('  proxy enabled: ' + $proxy.ProxyEnable + ' server: ' + $proxy.ProxyServer)
foreach ($hostName in 'store.rg-adguard.net', 'tlu.dl.delivery.mp.microsoft.com', 'dl.delivery.mp.microsoft.com', 'xboxlive.com') {
    $resolved = $null
    try {
        $resolved = (Resolve-DnsName -Name $hostName -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 2 -ExpandProperty IPAddress) -join ', '
    } catch {
        $resolved = 'resolution failed'
    }
    Add-Line ('  ' + $hostName.PadRight(40) + ' ' + $resolved)
}
Add-Line ('  TLS 1.2 available: ' + ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12))
Add-Line ''

Add-Line '--- disk ---'
$systemDrive = $env:SystemDrive
if ($systemDrive) {
    $drive = Get-PSDrive -Name $systemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($null -ne $drive) {
        Add-Line ('  ' + $systemDrive + ' free: ' + [math]::Round($drive.Free / 1GB, 1) + ' GB')
    }
}

[IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ('Report written to ' + $Path)
