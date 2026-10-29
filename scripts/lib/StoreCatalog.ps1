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
        [string[]]$Extension = @('appxbundle', 'msixbundle')
    )

    $best = $null
    foreach ($item in $Listing) {
        $parsed = ConvertFrom-StoreFileName -FileName $item.FileName
        if ($null -eq $parsed) { continue }
        if ($parsed.Identity -ne $Identity) { continue }
        if ($Extension -notcontains $parsed.Extension) { continue }
        if ($Architecture -notcontains $parsed.Architecture) { continue }

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

function Get-CurrentPackageTarget {
    param(
        [Parameter(Mandatory = $true)][string]$ProductId,
        [Parameter(Mandatory = $true)][string]$Identity,
        [string[]]$Architecture = @('neutral', 'x64', 'arm64'),
        [string[]]$Extension = @('appxbundle', 'msixbundle')
    )

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
