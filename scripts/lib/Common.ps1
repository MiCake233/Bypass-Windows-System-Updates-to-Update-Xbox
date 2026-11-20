# Shared constants, logging and small helpers.
# Compatible with Windows PowerShell 5.1 and PowerShell 7.x.
# Do not add functions that mutate Windows Update state: this module has no such code path.

$script:ExpectedPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$script:CatalogEndpoint = 'https://store.rg-adguard.net/api/GetFiles'
$script:AllowedDownloadSuffix = '.delivery.mp.microsoft.com'
$script:LogPath = $null

function Enable-ModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function Start-LogSession {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $script:LogPath = Join-Path $Directory ('update-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log')
    return $script:LogPath
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = (Get-Date).ToString('HH:mm:ss') + ' [' + $Level.PadRight(5) + '] ' + $Message
    switch ($Level) {
        'STEP' { Write-Host $line -ForegroundColor Cyan }
        'OK' { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    if ($script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

function ConvertTo-VersionParts {
    param([string]$Version)
    $parts = @(0, 0, 0, 0)
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $tokens = $Version.Trim().Split('.')
        for ($i = 0; $i -lt 4 -and $i -lt $tokens.Count; $i++) {
            $n = 0
            if ([int]::TryParse($tokens[$i], [ref]$n)) { $parts[$i] = $n }
        }
    }
    return , $parts
}

function Compare-PackageVersion {
    param([string]$Left, [string]$Right)
    $a = ConvertTo-VersionParts $Left
    $b = ConvertTo-VersionParts $Right
    for ($i = 0; $i -lt 4; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

# Parses a Microsoft Store payload file name:
#   <Identity>_<Version>_<Architecture>_<ResourceId>_<PublisherId>.<Extension>
# Returns $null when the name does not follow the scheme.
function ConvertFrom-StoreFileName {
    param([Parameter(Mandatory = $true)][string]$FileName)
    $pattern = '^(?<identity>[A-Za-z0-9.]+)_(?<version>[0-9]+(\.[0-9]+){1,3})_(?<arch>[A-Za-z0-9~]+)_(?<resource>[A-Za-z0-9~]*)_(?<publisher>[a-z0-9]{8,16})\.(?<extension>appxbundle|msixbundle|appx|msix)$'
    $m = [regex]::Match($FileName, $pattern, 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{
        FileName    = $FileName
        Identity    = $m.Groups['identity'].Value
        Version     = $m.Groups['version'].Value
        Architecture = $m.Groups['arch'].Value
        PublisherId = $m.Groups['publisher'].Value
        Extension   = $m.Groups['extension'].Value.ToLowerInvariant()
    }
}

# Accepts an absolute http or https URL on a Microsoft delivery host.
# http is rewritten to https before it is returned. Any other scheme, embedded
# userinfo, or a host outside the allow list returns $null.
function Resolve-SafeDownloadUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $candidate = $Url.Replace('&amp;', '&').Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) { return $null }
    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') { return $null }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $null }
    $hostName = $uri.Host.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName.EndsWith('.')) { return $null }
    if (-not $hostName.EndsWith($script:AllowedDownloadSuffix)) { return $null }
    $builder = New-Object System.UriBuilder($uri)
    $builder.Scheme = 'https'
    $builder.Port = 443
    return $builder.Uri.AbsoluteUri
}

# True only for an https URL that already landed on an allowed delivery host.
# Used for the final response URI, where rewriting the scheme would hide a downgrade.
function Test-AllowedDeliveryUri {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
    if ($uri.Port -ne 443) { return $false }
    $hostName = $uri.Host.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName.EndsWith('.')) { return $false }
    return $hostName.EndsWith($script:AllowedDownloadSuffix)
}

function Get-WebResponseFinalUri {
    param($Response)
    if ($null -eq $Response -or $null -eq $Response.BaseResponse) { return $null }
    $base = $Response.BaseResponse
    $responseUri = $base.PSObject.Properties['ResponseUri']
    if ($responseUri -and $responseUri.Value) { return [string]$responseUri.Value.AbsoluteUri }
    $requestMessage = $base.PSObject.Properties['RequestMessage']
    if ($requestMessage -and $requestMessage.Value -and $requestMessage.Value.RequestUri) {
        return [string]$requestMessage.Value.RequestUri.AbsoluteUri
    }
    return $null
}

function Get-RedactedUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return '<unparsed url>' }
    $builder = New-Object System.UriBuilder($uri)
    $builder.UserName = ''
    $builder.Password = ''
    $builder.Query = ''
    $builder.Fragment = ''
    $text = $builder.Uri.AbsoluteUri
    if ($text.EndsWith('?')) { $text = $text.TrimEnd('?') }
    return $text
}

function Get-RedactedLogText {
    param([string]$Message, [string]$Url)
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    if (-not [string]::IsNullOrEmpty($Url)) {
        $redacted = Get-RedactedUrl -Url $Url
        if (-not [string]::IsNullOrEmpty($redacted)) { $Message = $Message.Replace($Url, $redacted) }
    }
    return [regex]::Replace($Message, '(https?://[^?\s''"]+)\?[^\s''"]*', '$1')
}

# Appx architecture of this process, accounting for 32-bit PowerShell on 64-bit Windows.
function Get-HostArchitecture {
    $reported = $env:PROCESSOR_ARCHITECTURE
    if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $reported = $env:PROCESSOR_ARCHITEW6432
    }
    switch -Regex ([string]$reported) {
        '^ARM64$' { return 'arm64' }
        '^ARM$' { return 'arm' }
        '^AMD64$' { return 'x64' }
        '^X86$' { return 'x86' }
        default { return 'x64' }
    }
}

function Get-CompatibleArchitectures {
    $hostArchitecture = Get-HostArchitecture
    $architectures = @('neutral', $hostArchitecture)
    $unique = @()
    foreach ($architecture in $architectures) {
        if ($unique -notcontains $architecture) { $unique += $architecture }
    }
    return $unique
}

function Get-DirectDownloadFileName {
    param([Parameter(Mandatory = $true)][string]$Url)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url))
    } finally {
        $sha.Dispose()
    }
    $hash = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    return ('direct-' + $hash.Substring(0, 32) + '.pkg')
}

# The catalog file name is not signed. Deployment decisions use the manifest.
function Test-PackageVersionPolicy {
    param(
        [string]$ManifestVersion,
        [string]$AdvertisedVersion,
        [string]$InstalledVersion,
        [string]$MinimumVersion,
        [string]$ManifestArchitecture,
        [string]$AdvertisedArchitecture,
        [string]$HostArchitecture,
        [switch]$Force
    )
    $versionPattern = '^[0-9]+(\.[0-9]+){1,3}$'
    if ($ManifestVersion -notmatch $versionPattern) {
        return [pscustomobject]@{ Passed = $false; Reason = 'The package manifest version is missing or not numeric.' }
    }
    if (-not [string]::IsNullOrWhiteSpace($AdvertisedVersion)) {
        if ($AdvertisedVersion -notmatch $versionPattern -or (Compare-PackageVersion -Left $ManifestVersion -Right $AdvertisedVersion) -ne 0) {
            return [pscustomobject]@{ Passed = $false; Reason = 'The package manifest version does not match the version in the file name.' }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) {
        if ((Compare-PackageVersion -Left $ManifestVersion -Right $MinimumVersion) -lt 0) {
            return [pscustomobject]@{ Passed = $false; Reason = ('The package version is below the required minimum ' + $MinimumVersion + '.') }
        }
    }
    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
        if ((Compare-PackageVersion -Left $ManifestVersion -Right $InstalledVersion) -le 0) {
            return [pscustomobject]@{ Passed = $false; Reason = 'The package version is not newer than the installed version.' }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ManifestArchitecture) -and $ManifestArchitecture -ne 'neutral') {
        if (-not [string]::IsNullOrWhiteSpace($AdvertisedArchitecture) -and $AdvertisedArchitecture -ne 'neutral' -and $ManifestArchitecture -ne $AdvertisedArchitecture) {
            return [pscustomobject]@{ Passed = $false; Reason = 'The package architecture does not match the file name.' }
        }
        if (-not [string]::IsNullOrWhiteSpace($HostArchitecture) -and $ManifestArchitecture -ne $HostArchitecture) {
            return [pscustomobject]@{ Passed = $false; Reason = 'The package architecture is not compatible with this PC.' }
        }
    }
    return [pscustomobject]@{ Passed = $true; Reason = '' }
}

function Remove-CachedDownload {
    param(
        [string]$Path,
        [string]$CacheDirectory
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($CacheDirectory)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $root = [IO.Path]::GetFullPath($CacheDirectory)
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not $root.EndsWith($separator)) { $root = $root + $separator }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
}

function Get-InstalledPackageVersion {
    param([Parameter(Mandatory = $true)][string]$Identity)
    $pkg = Get-AppxPackage -Name $Identity -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pkg) { return $null }
    return [string]$pkg.Version
}

function Get-InstalledPackageInfo {
    param([Parameter(Mandatory = $true)][string]$Identity)
    $pkg = Get-AppxPackage -Name $Identity -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pkg) { return $null }
    return [pscustomobject]@{
        Identity        = [string]$pkg.Name
        Version         = [string]$pkg.Version
        Architecture    = [string]$pkg.Architecture
        PackageFullName = [string]$pkg.PackageFullName
        InstallLocation = [string]$pkg.InstallLocation
    }
}
