<#
.SYNOPSIS
    Updates the Xbox PC platform packages (Gaming Services and optionally the Xbox app)
    from Microsoft-signed bundles, without enabling or reconfiguring Windows Update.

.DESCRIPTION
    Resolves the current package bundles, downloads them from Microsoft delivery hosts,
    verifies identity, publisher and signature block, then deploys them with Add-AppxPackage.

    The script never enables, starts or reconfigures Windows Update (wuauserv), Delivery
    Optimization (dosvc), Update Orchestrator (UsoSvc) or any WindowsUpdate policy key.
    Those services may stay disabled; the update path does not use them.

.PARAMETER DryRun
    Resolve versions and report the plan. Nothing is downloaded or deployed.

.PARAMETER SkipXboxApp
    Update only Microsoft.GamingServices.

.PARAMETER StopServices
    Stop the Gaming Services service pair before deployment and start it again afterwards.
    Requires an elevated session. Use when deployment fails with 0x80073D02 or 0x80073D05.

.PARAMETER Force
    Deploy even when the installed version is already equal to or newer than the resolved one.

.PARAMETER CacheRoot
    Directory for logs and downloaded bundles. Default: %LOCALAPPDATA%\XboxOfflineUpdate

.PARAMETER GamingServicesBundle
    Use a local .appxbundle file instead of resolving one.

.PARAMETER GamingServicesUrl
    Use a specific download URL instead of resolving one.

.PARAMETER XboxAppBundle
    Use a local .msixbundle file instead of resolving one.

.PARAMETER XboxAppUrl
    Use a specific download URL instead of resolving one.

.EXAMPLE
    .\Invoke-XboxOfflineUpdate.ps1 -DryRun

.EXAMPLE
    .\Invoke-XboxOfflineUpdate.ps1 -StopServices
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipXboxApp,
    [switch]$StopServices,
    [switch]$Force,
    [string]$CacheRoot,
    [string]$GamingServicesBundle,
    [string]$GamingServicesUrl,
    [string]$XboxAppBundle,
    [string]$XboxAppUrl
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem -Path (Join-Path $scriptRoot 'lib') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

$script:InstalledDependencies = @()

$GamingServicesProductId = '9MWPM2CQNLHN'
$GamingServicesIdentity = 'Microsoft.GamingServices'
$XboxAppProductId = '9MV0B5HZVK9Z'
$XboxAppIdentity = 'Microsoft.GamingApp'

if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path $env:LOCALAPPDATA 'XboxOfflineUpdate'
}
$script:DownloadDir = Join-Path $CacheRoot 'packages'

function Get-HostArchitecture {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64' }
        default { return 'x64' }
    }
}

function Save-PackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MaxAttempts = 3
    )
    $partial = $Destination + '.partial'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            $saved = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 1800
            } finally {
                $ProgressPreference = $saved
            }
            $length = (Get-Item -LiteralPath $partial).Length
            if ($length -lt 1MB) { throw ('Downloaded file is too small (' + $length + ' bytes).') }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Write-Log -Message ('Downloaded ' + (Split-Path -Leaf $Destination) + ' (' + [math]::Round($length / 1MB, 1) + ' MB)') -Level OK
            return $true
        } catch {
            Write-Log -Message ('Download attempt ' + $attempt + '/' + $MaxAttempts + ' failed: ' + $_.Exception.Message) -Level WARN
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    return $false
}

function Get-TargetFromUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $safe = Resolve-SafeDownloadUrl -Url $Url
    if (-not $safe) { throw 'The supplied URL is not an https URL on a Microsoft delivery host.' }
    $fileName = [IO.Path]::GetFileName(([Uri]$safe).AbsolutePath)
    $parsed = ConvertFrom-StoreFileName -FileName $fileName
    if ($null -eq $parsed) { throw ('Cannot parse the package identity from the file name: ' + $fileName) }
    return [pscustomobject]@{
        Identity     = $parsed.Identity
        Version      = $parsed.Version
        Architecture = $parsed.Architecture
        Extension    = $parsed.Extension
        FileName     = $fileName
        Url          = $safe
        LocalPath    = $null
    }
}

function Get-TargetFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('File not found: ' + $Path) }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $fileName = Split-Path -Leaf $resolved
    $parsed = ConvertFrom-StoreFileName -FileName $fileName
    if ($null -eq $parsed) { throw ('Cannot parse the package identity from the file name: ' + $fileName) }
    return [pscustomobject]@{
        Identity     = $parsed.Identity
        Version      = $parsed.Version
        Architecture = $parsed.Architecture
        Extension    = $parsed.Extension
        FileName     = $fileName
        Url          = $null
        LocalPath    = $resolved
    }
}

function Resolve-DependencyPackage {
    param(
        [string]$ProductId,
        [object[]]$Listing,
        [Parameter(Mandatory = $true)][string]$DependencyIdentity
    )
    if ($null -eq $Listing) {
        $Listing = Get-StoreCatalogListing -ProductId $ProductId
    }
    $target = Select-CatalogPackage -Listing $Listing -Identity $DependencyIdentity -Architecture @('x64', 'neutral') -Extension @('appx', 'msix')
    if ($null -eq $target) {
        throw ('The catalog has no deployable payload for the required framework ' + $DependencyIdentity + '.')
    }
    return $target
}

function Get-PackagePath {
    param([Parameter(Mandatory = $true)]$Target)
    if ($Target.LocalPath) { return $Target.LocalPath }
    if (-not (Test-Path -LiteralPath $script:DownloadDir)) {
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    }
    $destination = Join-Path $script:DownloadDir $Target.FileName
    if (Test-Path -LiteralPath $destination) {
        Write-Log -Message ('Using cached ' + $Target.FileName) -Level INFO
        return $destination
    }
    $ok = Save-PackageFile -Url $Target.Url -Destination $destination
    if (-not $ok) { throw ('Download failed for ' + $Target.Url) }
    return $destination
}

function Test-TargetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    $provenance = Test-PackageProvenance -Path $Path -ExpectedIdentity $Identity
    foreach ($check in $provenance.Checks) {
        $state = 'PASS'
        if (-not $check.Passed) { $state = 'FAIL' }
        Write-Log -Message ('  [' + $state + '] ' + $check.Name + ' -> ' + $check.Detail) -Level INFO
    }
    if (-not $provenance.Passed) {
        throw ('Provenance verification failed for ' + (Split-Path -Leaf $Path) + '. The package was not deployed.')
    }
}

function Install-TargetBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProductId,
        [object[]]$Listing,
        [switch]$RestartServices
    )

    $attempt = 0
    while ($attempt -lt 5) {
        $attempt++
        $result = Install-PackageFile -Path $Path -RestartGamingServices:$RestartServices
        if ($result.Success) { return $true }
        if ($result.Code -ne '0x80073CF3') { break }

        $dependency = Get-MissingDependency -Message $result.Message
        if ($null -eq $dependency) { break }
        if ($script:InstalledDependencies -contains $dependency.Identity) { break }

        Write-Log -Message ('Deployment requires framework ' + $dependency.Identity + ' ' + $dependency.MinVersion) -Level WARN
        $dependencyTarget = Resolve-DependencyPackage -ProductId $ProductId -Listing $Listing -DependencyIdentity $dependency.Identity
        Write-Log -Message ('Resolved framework ' + $dependencyTarget.Identity + ' ' + $dependencyTarget.Version) -Level STEP
        $dependencyPath = Get-PackagePath -Target $dependencyTarget
        Test-TargetPackage -Path $dependencyPath -Identity $dependencyTarget.Identity
        $dependencyResult = Install-PackageFile -Path $dependencyPath
        if (-not $dependencyResult.Success) {
            throw ('Framework deployment failed for ' + $dependencyTarget.FileName + ' (' + $dependencyResult.Code + '). ' + $dependencyResult.Guidance)
        }
        $script:InstalledDependencies += $dependency.Identity
    }

    throw ('Deployment failed for ' + (Split-Path -Leaf $Path) + '. Guidance: ' + (Get-DeploymentGuidance -Code $result.Code))
}

function Invoke-PackageUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$ProductId,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string]$LocalBundle,
        [string]$DirectUrl
    )

    Write-Log -Message ('--- ' + $Label + ' (' + $Identity + ') ---') -Level STEP
    $installed = Get-InstalledPackageVersion -Identity $Identity
    $installedText = 'not installed'
    if (-not [string]::IsNullOrEmpty($installed)) { $installedText = $installed }
    Write-Log -Message ('Installed: ' + $installedText) -Level INFO

    $listing = $null
    if (-not [string]::IsNullOrEmpty($LocalBundle)) {
        $target = Get-TargetFromFile -Path $LocalBundle
    } elseif (-not [string]::IsNullOrEmpty($DirectUrl)) {
        $target = Get-TargetFromUrl -Url $DirectUrl
    } else {
        $resolved = Get-CurrentPackageTarget -ProductId $ProductId -Identity $Identity
        $listing = $resolved.Listing
        $target = $resolved.Target
    }
    Write-Log -Message ('Available: ' + $target.Version + ' (' + $target.FileName + ')') -Level INFO

    if (-not $Force -and -not [string]::IsNullOrEmpty($installed)) {
        if ((Compare-PackageVersion -Left $target.Version -Right $installed) -le 0) {
            Write-Log -Message ('No action required: installed version is current.') -Level OK
            return [pscustomobject]@{ Label = $Label; Status = 'current'; From = $installed; To = $installed }
        }
    }

    if ($DryRun) {
        Write-Log -Message ('Dry run: would deploy ' + $target.FileName) -Level INFO
        return [pscustomobject]@{ Label = $Label; Status = 'planned'; From = $installedText; To = $target.Version }
    }

    $path = Get-PackagePath -Target $target
    Test-TargetPackage -Path $path -Identity $Identity
    $deployed = Install-TargetBundle -Path $path -ProductId $ProductId -Listing $listing -RestartServices:$StopServices

    $after = Get-InstalledPackageVersion -Identity $Identity
    $afterText = 'not installed'
    if (-not [string]::IsNullOrEmpty($after)) { $afterText = $after }
    Write-Log -Message ('Installed now: ' + $afterText) -Level OK
    return [pscustomobject]@{ Label = $Label; Status = 'updated'; From = $installedText; To = $afterText }
}

# ---------------------------------------------------------------- main

$exitCode = 0
$results = @()

try {
    Start-LogSession -Directory (Join-Path $CacheRoot 'logs') | Out-Null
    Enable-ModernTls

    $build = [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Log -Message ('OS build ' + $build + ' | PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' | architecture ' + (Get-HostArchitecture) + ' | elevated: ' + $elevated) -Level STEP
    Write-Log -Message ('Log file: ' + $script:LogPath) -Level INFO

    if ($build -lt 19041) {
        Write-Log -Message 'Windows 10 version 2004 (build 19041) or later is required.' -Level ERROR
        throw 'Unsupported operating system build.'
    }
    if ($StopServices -and -not $elevated) {
        throw '-StopServices requires an elevated PowerShell session.'
    }

    $results += Invoke-PackageUpdate -Label 'Gaming Services' -ProductId $GamingServicesProductId -Identity $GamingServicesIdentity -LocalBundle $GamingServicesBundle -DirectUrl $GamingServicesUrl
    if (-not $SkipXboxApp) {
        $results += Invoke-PackageUpdate -Label 'Xbox app' -ProductId $XboxAppProductId -Identity $XboxAppIdentity -LocalBundle $XboxAppBundle -DirectUrl $XboxAppUrl
    }
} catch {
    $exitCode = 1
    Write-Log -Message ('Failed: ' + $_.Exception.Message) -Level ERROR
    if ($_.Exception.Message -like '*Deployment failed*') { $exitCode = 6 }
}

Write-Log -Message '--- summary ---' -Level STEP
foreach ($item in $results) {
    Write-Log -Message ('  ' + $item.Label.PadRight(16) + ' ' + $item.From + ' -> ' + $item.To + '  [' + $item.Status + ']') -Level INFO
}
Write-Log -Message ('Exit code: ' + $exitCode) -Level INFO
exit $exitCode
