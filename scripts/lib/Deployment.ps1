# Deployment of Microsoft Store package bundles through the AppX deployment service.
#
# Only two kinds of operation are performed here:
#   * Add-AppxPackage on a package file that already passed the provenance checks;
#   * optional stop/start of the Gaming Services service pair, and only when explicitly
#     requested with -StopServices.
# No Windows Update service, Delivery Optimization service or update policy is modified.

$script:DeploymentGuidance = @{
    '0x80073CF3' = 'The package depends on a framework that is not installed. The updater resolves missing frameworks automatically; re-run with -Verbose to see the dependency it selected.'
    '0x80073D02' = 'The package is in use. Close the Xbox app, Microsoft Store and any running game, then re-run.'
    '0x80073D0A' = 'Another deployment is in progress. Wait for it to finish and re-run.'
    '0x80073CFB' = 'The package is already installed with the same or a higher version. Nothing to do.'
    '0x80073CF9' = 'The AppX deployment service rejected the package. Restart AppXSvc (or reboot) and re-run.'
    '0x80073CF6' = 'The package could not be registered. Remove the existing registration for this identity and re-run.'
    '0x80073D05' = 'The package is held open by a running process. Close all Xbox related processes and re-run.'
    '0x80070005' = 'Access denied. Start PowerShell as administrator and re-run.'
    '0x80073CF0' = 'The package archive is invalid or incomplete. Delete the cached file and re-run to download it again.'
    '0x80D05001' = 'The AppX deployment service could not download content. This updater never uses that path; check that the cached file exists.'
}

function Get-DeployErrorCode {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $null }
    $match = [regex]::Match($Message, '0x[0-9A-Fa-f]{8}')
    if ($match.Success) { return $match.Value.ToUpperInvariant() }
    return $null
}

# Recognises the framework identity and minimum version in a 0x80073CF3 message.
# Messages are localised, so both the English and the Simplified Chinese forms are handled.
function Get-MissingDependency {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $null }

    $identity = $null
    $minVersion = $null

    # U+6846 U+67B6 and U+6700 U+4F4E U+7248 U+672C are kept as code points so this file stays ASCII.
    $frameworkWord = [string][char]0x6846 + [string][char]0x67B6
    $minimumVersionWord = [string][char]0x6700 + [string][char]0x4F4E + [string][char]0x7248 + [string][char]0x672C

    # A package identity always contains at least one dot; requiring it keeps filler words such as
    # "the framework that could not be found" from being captured as an identity.
    $nameExpression = '(?<name>[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+)'
    $versionExpression = '(?<version>[0-9]+(\.[0-9]+){1,3})'

    $identityPatterns = @(
        ('framework\s+"?' + $nameExpression)
        ($frameworkWord + '"\s*' + $nameExpression)
    )
    foreach ($pattern in $identityPatterns) {
        $match = [regex]::Match($Message, $pattern)
        if ($match.Success) { $identity = $match.Groups['name'].Value; break }
    }
    if ([string]::IsNullOrEmpty($identity)) { return $null }

    $versionPatterns = @(
        ('minimum\s+version\s+' + $versionExpression)
        ($minimumVersionWord + '\s*' + $versionExpression)
    )
    foreach ($pattern in $versionPatterns) {
        $match = [regex]::Match($Message, $pattern)
        if ($match.Success) { $minVersion = $match.Groups['version'].Value; break }
    }

    return [pscustomobject]@{
        Identity   = $identity
        MinVersion = $minVersion
    }
}

function Get-DeploymentGuidance {
    param([string]$Code)
    if ([string]::IsNullOrEmpty($Code)) { return 'No HRESULT was reported. Inspect the deployment log with Get-AppxLog.' }
    if ($script:DeploymentGuidance.ContainsKey($Code)) { return $script:DeploymentGuidance[$Code] }
    return 'Unknown HRESULT. Inspect the deployment log with Get-AppxLog -ActivityId <id>, where the id is printed in the error message.'
}

function Install-PackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RestartGamingServices
    )

    $result = [pscustomobject]@{
        Path    = $Path
        Success = $false
        Code    = $null
        Message = $null
        Guidance = $null
    }

    if ($RestartGamingServices) {
        foreach ($name in 'GamingServices', 'GamingServicesNet') {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -eq 'Running') {
                try {
                    Stop-Service -Name $name -Force -ErrorAction Stop
                    Write-Log -Message ('Stopped service ' + $name) -Level INFO
                } catch {
                    Write-Log -Message ('Could not stop ' + $name + ': ' + $_.Exception.Message) -Level WARN
                }
            }
        }
        Start-Sleep -Seconds 2
    }

    try {
        Add-AppxPackage -Path $Path -ForceApplicationShutdown -ErrorAction Stop
        $result.Success = $true
        Write-Log -Message ('Deployed ' + (Split-Path -Leaf $Path)) -Level OK
    } catch {
        $message = $_.Exception.Message
        $inner = $_.Exception.InnerException
        while ($null -ne $inner) {
            $message = $message + ' ' + $inner.Message
            $inner = $inner.InnerException
        }
        $result.Message = $message
        $result.Code = Get-DeployErrorCode -Message $message
        $result.Guidance = Get-DeploymentGuidance -Code $result.Code
        Write-Log -Message ('Deployment failed: ' + $result.Code + ' ' + $message) -Level ERROR
    }

    if ($RestartGamingServices) {
        foreach ($name in 'GamingServices', 'GamingServicesNet') {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $service -and $service.Status -ne 'Running') {
                try {
                    Start-Service -Name $name -ErrorAction Stop
                    Write-Log -Message ('Started service ' + $name) -Level INFO
                } catch {
                    Write-Log -Message ('Could not start ' + $name + ': ' + $_.Exception.Message) -Level WARN
                }
            }
        }
    }

    return $result
}
