# Resolution of current Microsoft Store payloads for a given product id.
#
# The Windows Update delivery stack is not used or contacted. The catalog helper below
# answers with Microsoft delivery URLs; every URL is re-validated against an allow list
# before it is accepted, and every downloaded package is checked again before deployment.

function ConvertFrom-CatalogHtml {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Html)
    $pattern = '<a href="(?<url>[^"]+)"[^>]*>(?<name>[^<]+)</a>'
    $items = @()
    foreach ($match in [regex]::Matches($Html, $pattern)) {
        $items += [pscustomobject]@{
            FileName = $match.Groups['name'].Value.Trim()
            Url      = $match.Groups['url'].Value.Trim()
        }
    }
    return $items
}

function Get-StoreCatalogListing {
    param(
        [Parameter(Mandatory = $true)][string]$ProductId,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSec = 90
    )

    $body = @{
        type = 'ProductId'
        url  = $ProductId
        ring = 'Retail'
        lang = 'en-US'
    }
    $headers = @{
        'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
        'Referer'         = 'https://store.rg-adguard.net/'
        'Origin'          = 'https://store.rg-adguard.net'
        'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language' = 'en-US,en;q=0.9'
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $script:CatalogEndpoint -Body $body -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec
            $html = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($html) -or $html.Length -lt 200) {
                throw 'Empty catalog response.'
            }
            $items = ConvertFrom-CatalogHtml -Html $html
            if ($items.Count -eq 0) { throw 'Catalog response contained no file entries.' }
            Write-Log -Message ('Catalog ' + $ProductId + ': ' + $items.Count + ' entries.') -Level INFO
            return $items
        } catch {
            $lastError = $_.Exception.Message
            Write-Log -Message ('Catalog request ' + $attempt + '/' + $MaxAttempts + ' failed: ' + $lastError) -Level WARN
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    throw ('Unable to query the store catalog for ' + $ProductId + '. Last error: ' + $lastError)
}

function Select-CatalogPackage {
    param(
        [object[]]$Listing,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string[]]$Architecture = @('neutral', 'x64', 'arm64'),
        [string[]]$Extension = @('appxbundle', 'msixbundle'),
        [string]$MinimumVersion
    )

    $best = $null
    foreach ($item in $Listing) {
        $parsed = ConvertFrom-StoreFileName -FileName $item.FileName
        if ($null -eq $parsed) { continue }
        if ($parsed.Identity -ne $Identity) { continue }
        if ($Extension -notcontains $parsed.Extension) { continue }
        if ($Architecture -notcontains $parsed.Architecture) { continue }
        if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) {
            if ((Compare-PackageVersion -Left $parsed.Version -Right $MinimumVersion) -lt 0) { continue }
        }

        $url = Resolve-SafeDownloadUrl -Url $item.Url
        if (-not $url) {
            Write-Log -Message ('Ignored non-Microsoft URL for ' + $item.FileName) -Level WARN
            continue
        }

        $isBetter = $false
        if ($null -eq $best) {
            $isBetter = $true
        } elseif ((Compare-PackageVersion -Left $parsed.Version -Right $best.Version) -gt 0) {
            $isBetter = $true
        }
        if ($isBetter) {
            $best = [pscustomobject]@{
                Identity     = $parsed.Identity
                Version      = $parsed.Version
                Architecture = $parsed.Architecture
                Extension    = $parsed.Extension
                FileName     = $parsed.FileName
                Url          = $url
            }
        }
    }
    return $best
}

function Resolve-DependencyPackage {
    param(
        [string]$ProductId,
        [object[]]$Listing,
        [Parameter(Mandatory = $true)][string]$DependencyIdentity,
        [string]$MinimumVersion
    )
    if ($null -eq $Listing) {
        $Listing = Get-StoreCatalogListing -ProductId $ProductId
    }
    $architectures = @(Get-HostArchitecture)
    if ($architectures -notcontains 'neutral') { $architectures += 'neutral' }
    $target = Select-CatalogPackage -Listing $Listing -Identity $DependencyIdentity -Architecture $architectures -Extension @('appx', 'msix') -MinimumVersion $MinimumVersion
    if ($null -eq $target) {
        $requirement = $DependencyIdentity
        if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) { $requirement = $requirement + ' at or above ' + $MinimumVersion }
        throw ('The catalog has no deployable payload for the required framework ' + $requirement + '.')
    }
    return $target
}

function Get-CurrentPackageTarget {
    param(
        [Parameter(Mandatory = $true)][string]$ProductId,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string[]]$Architecture,
        [string[]]$Extension = @('appxbundle', 'msixbundle')
    )

    if ($null -eq $Architecture -or $Architecture.Count -eq 0) {
        $Architecture = Get-CompatibleArchitectures
    }
    $listing = Get-StoreCatalogListing -ProductId $ProductId
    $target = Select-CatalogPackage -Listing $listing -Identity $Identity -Architecture $Architecture -Extension $Extension
    if ($null -eq $target) {
        throw ('No deployable bundle for ' + $Identity + ' was found in the catalog listing.')
    }
    return [pscustomobject]@{
        Target  = $target
        Listing = $listing
    }
}

function Get-TargetFromUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $safe = Resolve-SafeDownloadUrl -Url $Url
    if (-not $safe) { throw 'The supplied URL is not an https URL on a Microsoft delivery host.' }
    $fileName = [IO.Path]::GetFileName(([Uri]$safe).AbsolutePath)
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($fileName)) {
        $parsed = ConvertFrom-StoreFileName -FileName $fileName
    }
    # Real delivery URLs end in a file id, not the package name. The manifest
    # supplies identity and version after the download.
    if ($null -eq $parsed) {
        return [pscustomobject]@{
            Identity     = $null
            Version      = $null
            Architecture = $null
            Extension    = $null
            FileName     = (Get-DirectDownloadFileName -Url $safe)
            Url          = $safe
            LocalPath    = $null
        }
    }
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

function Save-PackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MaxAttempts = 3
    )
    $partial = $Destination + '.partial'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $redirectRejected = $false
        try {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            $saved = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                $params = @{
                    Uri             = $Url
                    OutFile         = $partial
                    UseBasicParsing = $true
                    TimeoutSec      = 1800
                }
                $webCommand = Get-Command -Name Invoke-WebRequest
                if ($webCommand.Parameters.ContainsKey('PassThru')) { $params.PassThru = $true }
                $response = Invoke-WebRequest @params
            } finally {
                $ProgressPreference = $saved
            }
            $finalUri = Get-WebResponseFinalUri -Response $response
            if (-not (Test-AllowedDeliveryUri -Url $finalUri)) {
                $redirectRejected = $true
                throw 'The download was redirected away from the allowed Microsoft delivery hosts.'
            }
            $payloadError = Test-ZipPackageFile -Path $partial
            if ($payloadError) { throw $payloadError }
            $length = (Get-Item -LiteralPath $partial).Length
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            Write-Log -Message ('Downloaded ' + (Split-Path -Leaf $Destination) + ' (' + [math]::Round($length / 1MB, 1) + ' MB)') -Level OK
            return $true
        } catch {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            $safeError = Get-RedactedLogText -Message $_.Exception.Message -Url $Url
            if ($redirectRejected) {
                Write-Log -Message ('Download rejected: ' + $safeError) -Level ERROR
                throw $safeError
            }
            Write-Log -Message ('Download attempt ' + $attempt + '/' + $MaxAttempts + ' failed: ' + $safeError) -Level WARN
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (3 * $attempt) }
        }
    }
    return $false
}
