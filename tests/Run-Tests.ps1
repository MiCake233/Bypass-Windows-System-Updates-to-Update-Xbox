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
Write-Host ('passed: ' + $script:Passed + '  failed: ' + $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
