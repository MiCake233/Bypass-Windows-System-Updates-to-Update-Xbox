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

# Accepts only https URLs on Microsoft delivery hosts. Returns $null otherwise.
function Resolve-SafeDownloadUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $candidate = $Url.Replace('&amp;', '&').Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri)) { return $null }
    $hostName = $uri.Host.ToLowerInvariant()
    if (-not $hostName.EndsWith($script:AllowedDownloadSuffix)) { return $null }
    $builder = New-Object System.UriBuilder($uri)
    $builder.Scheme = 'https'
    $builder.Port = 443
    return $builder.Uri.AbsoluteUri
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
