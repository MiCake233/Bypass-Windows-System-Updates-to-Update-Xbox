<#
.SYNOPSIS
    Offline test suite: parser checks and unit tests for pure functions.

.DESCRIPTION
    No network access, no package deployment, no service changes. Safe to run on any host.

.EXAMPLE
    .\tests\Run-Tests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Get-ChildItem -Path (Join-Path $repoRoot 'scripts\lib') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

$script:Passed = 0
$script:Failed = 0

function Write-Result {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $script:Passed++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        $message = '  FAIL  ' + $Name
        if (-not [string]::IsNullOrEmpty($Detail)) { $message = $message + ' :: ' + $Detail }
        Write-Host $message -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $ok = ($Expected -eq $Actual)
    $detail = 'expected [' + $Expected + '] got [' + $Actual + ']'
    Write-Result -Name $Name -Condition $ok -Detail $detail
}

Write-Host 'parser checks'

$scriptFiles = @()
$scriptFiles += Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse
$scriptFiles += Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -Recurse

foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart('\')
    if ($null -eq $errors -or $errors.Count -eq 0) {
        Write-Result -Name ('parses: ' + $relative) -Condition $true
    } else {
        $detail = ($errors | ForEach-Object { $_.Message + ' @line ' + $_.Extent.StartLineNumber }) -join '; '
        Write-Result -Name ('parses: ' + $relative) -Condition $false -Detail $detail
    }
}

Write-Host ''
Write-Host 'file name parsing'

$bundle = ConvertFrom-StoreFileName -FileName 'Microsoft.GamingServices_39.118.21002.0_neutral_~_8wekyb3d8bbwe.appxbundle'
Assert-Equal 'bundle identity' 'Microsoft.GamingServices' $bundle.Identity
Assert-Equal 'bundle version' '39.118.21002.0' $bundle.Version
Assert-Equal 'bundle architecture' 'neutral' $bundle.Architecture
Assert-Equal 'bundle extension' 'appxbundle' $bundle.Extension

$app = ConvertFrom-StoreFileName -FileName 'Microsoft.GamingApp_2610.1001.20.0_neutral_~_8wekyb3d8bbwe.msixbundle'
Assert-Equal 'app extension' 'msixbundle' $app.Extension
Assert-Equal 'app version' '2610.1001.20.0' $app.Version

$framework = ConvertFrom-StoreFileName -FileName 'Microsoft.WindowsAppRuntime.2_2.6.4.0_x64__8wekyb3d8bbwe.msix'
Assert-Equal 'framework architecture' 'x64' $framework.Architecture

$rejected = ConvertFrom-StoreFileName -FileName 'Microsoft.GamingServices_39.118.21002.0_neutral_~_8wekyb3d8bbwe.BlockMap'
Assert-Equal 'blockmap rejected' '' ([string]$rejected.Identity)

Write-Host ''
Write-Host 'version comparison'

Write-Result -Name 'older version sorts lower' -Condition ((Compare-PackageVersion -Left '34.111.20001.0' -Right '39.118.21002.0') -lt 0)
Write-Result -Name 'newer version sorts higher' -Condition ((Compare-PackageVersion -Left '2610.1001.20.0' -Right '2604.1001.9.0') -gt 0)
Write-Result -Name 'equal versions compare equal' -Condition ((Compare-PackageVersion -Left '2.6.4.0' -Right '2.6.4.0') -eq 0)
Write-Result -Name 'shorter version is padded' -Condition ((Compare-PackageVersion -Left '2.6' -Right '2.6.0.1') -lt 0)

Write-Host ''
Write-Host 'download URL validation'

$upgraded = Resolve-SafeDownloadUrl -Url 'http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc?P1=1&amp;P2=404'
Write-Result -Name 'http is upgraded to https' -Condition ($upgraded -like 'https://tlu.dl.delivery.mp.microsoft.com/*')
Write-Result -Name 'html entity is decoded' -Condition ($upgraded -like '*&P2=404*')

$foreign = Resolve-SafeDownloadUrl -Url 'https://mirror.example.com/files/pkg.appxbundle'
Write-Result -Name 'foreign host is rejected' -Condition ($null -eq $foreign)

$suffixAttack = Resolve-SafeDownloadUrl -Url 'https://dl.delivery.mp.microsoft.com.evil.example/pkg.appxbundle'
Write-Result -Name 'suffix attack is rejected' -Condition ($null -eq $suffixAttack)

Write-Host ''
Write-Host 'catalog selection'

$fixturePath = Join-Path $PSScriptRoot 'fixtures\catalog-response.html'
$fixtureHtml = [IO.File]::ReadAllText($fixturePath)
$listing = ConvertFrom-CatalogHtml -Html $fixtureHtml
Assert-Equal 'fixture entries parsed' 7 $listing.Count

$selected = Select-CatalogPackage -Listing $listing -Identity 'Microsoft.GamingServices'
Assert-Equal 'newest version selected' '39.118.21002.0' $selected.Version
Write-Result -Name 'foreign host not selected' -Condition ($selected.Url -like 'https://tlu.dl.delivery.mp.microsoft.com/*')

$appSelected = Select-CatalogPackage -Listing $listing -Identity 'Microsoft.GamingApp'
Assert-Equal 'xbox app bundle selected' '2610.1001.20.0' $appSelected.Version

$frameworkSelected = Select-CatalogPackage -Listing $listing -Identity 'Microsoft.WindowsAppRuntime.2' -Architecture @('x64', 'neutral') -Extension @('appx', 'msix')
Assert-Equal 'framework selected' '2.6.4.0' $frameworkSelected.Version

Write-Host ''
Write-Host 'error handling'

Assert-Equal 'hresult extracted' '0x80073CF3' (Get-DeployErrorCode -Message 'Deployment failed with HRESULT: 0x80073cf3, package could not be validated.')
Assert-Equal 'no hresult' '' ([string](Get-DeployErrorCode -Message 'no code here'))

$englishMessage = 'Windows cannot install package Microsoft.GamingApp because it depends on a framework that could not be found. Provide the framework "Microsoft.WindowsAppRuntime.2" published by "CN=Microsoft Corporation" with neutral or x64 processor architecture and minimum version 2.1.1.0, along with the package.'
$dependency = Get-MissingDependency -Message $englishMessage
Assert-Equal 'english dependency identity' 'Microsoft.WindowsAppRuntime.2' $dependency.Identity
Assert-Equal 'english dependency version' '2.1.1.0' $dependency.MinVersion

$frameworkWord = [string][char]0x6846 + [string][char]0x67B6
$minimumWord = [string][char]0x6700 + [string][char]0x4F4E + [string][char]0x7248 + [string][char]0x672C
$localisedMessage = 'HRESULT: 0x80073CF3. ' + $frameworkWord + '"Microsoft.WindowsAppRuntime.2" ' + $minimumWord + '2.1.1.0'
$localisedDependency = Get-MissingDependency -Message $localisedMessage
Assert-Equal 'localised dependency identity' 'Microsoft.WindowsAppRuntime.2' $localisedDependency.Identity
Assert-Equal 'localised dependency version' '2.1.1.0' $localisedDependency.MinVersion

Write-Result -Name 'unknown hresult has guidance' -Condition (-not [string]::IsNullOrEmpty((Get-DeploymentGuidance -Code '0xDEADBEEF')))

Write-Host ''
Write-Host 'download policy'

$fileScheme = Resolve-SafeDownloadUrl -Url 'file://tlu.dl.delivery.mp.microsoft.com/pkg.appxbundle'
Write-Result -Name 'file scheme is rejected' -Condition ($null -eq $fileScheme)

$userInfo = Resolve-SafeDownloadUrl -Url 'https://user:pass@tlu.dl.delivery.mp.microsoft.com/pkg.appxbundle'
Write-Result -Name 'userinfo is rejected' -Condition ($null -eq $userInfo)

$finalHttps = Test-AllowedDeliveryUri -Url 'https://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc'
Write-Result -Name 'final https delivery uri is allowed' -Condition ($finalHttps)
$finalHttp = Test-AllowedDeliveryUri -Url 'http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc'
Write-Result -Name 'final http uri is rejected' -Condition (-not $finalHttp)
$finalForeign = Test-AllowedDeliveryUri -Url 'https://evil.example/pkg.appxbundle'
Write-Result -Name 'final foreign uri is rejected' -Condition (-not $finalForeign)

$redacted = Get-RedactedUrl -Url 'https://user:pass@tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc?P1=1&P4=secret-token'
Write-Result -Name 'redacted url drops the query' -Condition ($redacted -notlike '*secret-token*' -and $redacted -notlike '*P4=*')
Write-Result -Name 'redacted url drops userinfo' -Condition ($redacted -notlike '*pass*')
$redactedLog = Get-RedactedLogText -Message 'failed https://tlu.dl.delivery.mp.microsoft.com/files/abc?P4=secret-token' -Url 'https://tlu.dl.delivery.mp.microsoft.com/files/abc?P4=secret-token'
Write-Result -Name 'log text drops signed query' -Condition ($redactedLog -notlike '*secret-token*')

$guidUrl = 'http://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/ad8ac804-8729-4079-baba-289992b47f64?P1=1&amp;P2=404'
$directTarget = Get-TargetFromUrl -Url $guidUrl
Assert-Equal 'delivery url is upgraded' $true ($directTarget.Url.StartsWith('https://'))
Write-Result -Name 'guid delivery url has no advertised version' -Condition ([string]::IsNullOrEmpty($directTarget.Version))
Write-Result -Name 'guid delivery url uses a safe cache name' -Condition ($directTarget.FileName -match '^direct-[0-9a-f]{32}\.pkg$')
$namedUrl = 'https://tlu.dl.delivery.mp.microsoft.com/Microsoft.GamingServices_39.118.21002.0_neutral_~_8wekyb3d8bbwe.appxbundle'
$namedTarget = Get-TargetFromUrl -Url $namedUrl
Assert-Equal 'named url keeps the advertised version' '39.118.21002.0' $namedTarget.Version

$savedArchitecture = $env:PROCESSOR_ARCHITECTURE
$savedWow = $env:PROCESSOR_ARCHITEW6432
try {
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
    Assert-Equal 'native arm64 host' 'arm64' (Get-HostArchitecture)
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    Assert-Equal 'wow64 arm64 host' 'arm64' (Get-HostArchitecture)
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
    Assert-Equal 'amd64 host' 'x64' (Get-HostArchitecture)
} finally {
    $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
    if ([string]::IsNullOrEmpty($savedWow)) {
        Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
    } else {
        $env:PROCESSOR_ARCHITEW6432 = $savedWow
    }
}

Write-Host ''
Write-Host 'version policy and architecture selection'

$match = Test-PackageVersionPolicy -ManifestVersion '39.118.21002.0' -AdvertisedVersion '39.118.21002.0' -InstalledVersion '34.111.20001.0' -ManifestArchitecture '' -AdvertisedArchitecture 'neutral' -HostArchitecture 'x64'
Write-Result -Name 'newer matching manifest is accepted' -Condition $match.Passed

$downgrade = Test-PackageVersionPolicy -ManifestVersion '34.111.20001.0' -AdvertisedVersion '39.118.21002.0' -InstalledVersion '34.111.20001.0'
Write-Result -Name 'spoofed file name is rejected' -Condition (-not $downgrade.Passed)

$notNewer = Test-PackageVersionPolicy -ManifestVersion '34.111.20001.0' -AdvertisedVersion '34.111.20001.0' -InstalledVersion '39.118.21002.0'
Write-Result -Name 'older manifest is rejected' -Condition (-not $notNewer.Passed)

$forced = Test-PackageVersionPolicy -ManifestVersion '34.111.20001.0' -AdvertisedVersion '34.111.20001.0' -InstalledVersion '39.118.21002.0' -Force
Write-Result -Name 'force allows an older matching manifest' -Condition $forced.Passed

$belowMin = Test-PackageVersionPolicy -ManifestVersion '2.1.0.0' -AdvertisedVersion '2.1.0.0' -MinimumVersion '2.6.4.0'
Write-Result -Name 'framework below minimum is rejected' -Condition (-not $belowMin.Passed)

$wrongArch = Test-PackageVersionPolicy -ManifestVersion '14.0.33519.0' -AdvertisedVersion '14.0.33519.0' -ManifestArchitecture 'x64' -AdvertisedArchitecture 'x64' -HostArchitecture 'arm64'
Write-Result -Name 'wrong architecture is rejected' -Condition (-not $wrongArch.Passed)

$archListing = @(
    [pscustomobject]@{ FileName = 'Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe.appx'; Url = 'https://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/x64' }
    [pscustomobject]@{ FileName = 'Microsoft.VCLibs.140.00_99.0.0.0_arm64__8wekyb3d8bbwe.appx'; Url = 'https://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/arm64' }
    [pscustomobject]@{ FileName = 'Microsoft.VCLibs.140.00_14.0.30000.0_arm64__8wekyb3d8bbwe.appx'; Url = 'https://tlu.dl.delivery.mp.microsoft.com/filestreamingservice/files/old-arm64' }
)
$env:PROCESSOR_ARCHITECTURE = 'ARM64'
Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
$armSelection = Resolve-DependencyPackage -Listing $archListing -DependencyIdentity 'Microsoft.VCLibs.140.00' -MinimumVersion '14.0.33519.0'
Assert-Equal 'arm64 framework selected' 'arm64' $armSelection.Architecture
Assert-Equal 'arm64 framework meets minimum' '99.0.0.0' $armSelection.Version
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$x64Selection = Resolve-DependencyPackage -Listing $archListing -DependencyIdentity 'Microsoft.VCLibs.140.00' -MinimumVersion '14.0.33519.0'
Assert-Equal 'x64 host does not select arm64' 'x64' $x64Selection.Architecture
$tooNew = $false
try {
    Resolve-DependencyPackage -Listing $archListing -DependencyIdentity 'Microsoft.VCLibs.140.00' -MinimumVersion '100.0.0.0' | Out-Null
} catch {
    $tooNew = $true
}
Write-Result -Name 'missing minimum version fails' -Condition $tooNew
if ([string]::IsNullOrEmpty($savedArchitecture)) {
    Remove-Item Env:PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue
} else {
    $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
}

Assert-Equal 'already installed disposition' 'present' (Get-DeploymentDisposition -Success $false -Code '0x80073CFB')
Assert-Equal 'dependency disposition' 'dependency' (Get-DeploymentDisposition -Success $false -Code '0x80073CF3')
Assert-Equal 'success disposition' 'installed' (Get-DeploymentDisposition -Success $true -Code $null)

Write-Host ''
Write-Host 'package inspection'

Initialize-ZipSupport
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ('xbox-offline-update-tests-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $fixtureDir | Out-Null
try {
    $manifestXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Microsoft.NET.Native.Runtime.2.2" ProcessorArchitecture="x64" Publisher="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" Version="2.2.28604.0" />
</Package>
"@
    $packagePath = Join-Path $fixtureDir 'runtime.appx'
    $package = [IO.Compression.ZipFile]::Open($packagePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $package.CreateEntry('AppxManifest.xml')
        $entryStream = $entry.Open()
        try {
            $body = [Text.Encoding]::UTF8.GetBytes($manifestXml)
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            $entryStream.Write($bom, 0, $bom.Length)
            $entryStream.Write($body, 0, $body.Length)
        } finally {
            $entryStream.Dispose()
        }
    } finally {
        $package.Dispose()
    }
    $identity = Get-PackageIdentity -Path $packagePath
    Assert-Equal 'namespaced manifest name' 'Microsoft.NET.Native.Runtime.2.2' $identity.Name
    Assert-Equal 'namespaced manifest version' '2.2.28604.0' $identity.Version
    Assert-Equal 'namespaced manifest architecture' 'x64' $identity.Architecture

    $dtdXml = '<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY xxe "Microsoft.GamingServices">]><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="&xxe;" Version="1.0.0.0" Publisher="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" /></Package>'
    $dtdPath = Join-Path $fixtureDir 'dtd.appx'
    $dtdPackage = [IO.Compression.ZipFile]::Open($dtdPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $dtdEntry = $dtdPackage.CreateEntry('AppxManifest.xml')
        $dtdStream = $dtdEntry.Open()
        try {
            $dtdBytes = [Text.Encoding]::UTF8.GetBytes($dtdXml)
            $dtdStream.Write($dtdBytes, 0, $dtdBytes.Length)
        } finally {
            $dtdStream.Dispose()
        }
    } finally {
        $dtdPackage.Dispose()
    }
    $dtdProvenance = Test-PackageProvenance -Path $dtdPath -ExpectedIdentity 'Microsoft.GamingServices'
    Write-Result -Name 'dtd manifest is rejected' -Condition (-not $dtdProvenance.Passed)
    $dtdDetail = ($dtdProvenance.Checks | ForEach-Object { $_.Detail }) -join ' '
    Write-Result -Name 'dtd entity is not accepted as the identity' -Condition ($dtdDetail -notlike '*Microsoft.GamingServices 1.0.0.0*')

    $oversizedPath = Join-Path $fixtureDir 'large.appx'
    $oversized = [IO.Compression.ZipFile]::Open($oversizedPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $largeEntry = $oversized.CreateEntry('AppxManifest.xml')
        $largeStream = $largeEntry.Open()
        try {
            $block = New-Object byte[] 1048576
            for ($i = 0; $i -lt 5; $i++) { $largeStream.Write($block, 0, $block.Length) }
        } finally {
            $largeStream.Dispose()
        }
    } finally {
        $oversized.Dispose()
    }
    $oversizedRejected = $false
    try {
        Get-PackageIdentity -Path $oversizedPath | Out-Null
    } catch {
        $oversizedRejected = $_.Exception.Message -like '*exceeds the allowed size*'
    }
    Write-Result -Name 'oversized manifest is rejected' -Condition $oversizedRejected

    $htmlPath = Join-Path $fixtureDir 'error.html'
    [IO.File]::WriteAllText($htmlPath, ('<html>' + ('x' * 200000) + '</html>'))
    $htmlError = Test-ZipPackageFile -Path $htmlPath
    Write-Result -Name 'html payload is rejected' -Condition ($htmlError -like '*not a zip package*')

    $smallZip = Join-Path $fixtureDir 'small.zip'
    $smallArchive = [IO.Compression.ZipFile]::Open($smallZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $smallEntry = $smallArchive.CreateEntry('AppxManifest.xml', [IO.Compression.CompressionLevel]::NoCompression)
        $smallStream = $smallEntry.Open()
        try {
            $padding = New-Object byte[] 40000
            $smallStream.Write($padding, 0, $padding.Length)
        } finally {
            $smallStream.Dispose()
        }
    } finally {
        $smallArchive.Dispose()
    }
    Write-Result -Name 'sub-megabyte zip is accepted' -Condition ($null -eq (Test-ZipPackageFile -Path $smallZip))

    $cacheRoot = Join-Path $fixtureDir 'cache'
    New-Item -ItemType Directory -Path $cacheRoot | Out-Null
    $cached = Join-Path $cacheRoot 'cached.pkg'
    $outside = Join-Path $fixtureDir 'keep.pkg'
    [IO.File]::WriteAllText($cached, 'stale')
    [IO.File]::WriteAllText($outside, 'keep')
    Remove-CachedDownload -Path $cached -CacheDirectory $cacheRoot
    Remove-CachedDownload -Path $outside -CacheDirectory $cacheRoot
    Write-Result -Name 'failed cache file is removed' -Condition (-not (Test-Path -LiteralPath $cached))
    Write-Result -Name 'file outside the cache is kept' -Condition (Test-Path -LiteralPath $outside)
} finally {
    if (Test-Path -LiteralPath $fixtureDir) { Remove-Item -LiteralPath $fixtureDir -Recurse -Force }
}

Write-Host ''
Write-Host ('passed: ' + $script:Passed + '  failed: ' + $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
