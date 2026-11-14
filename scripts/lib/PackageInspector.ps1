# Package inspection performed before deployment.
#
# These checks are a pre-flight gate, not a substitute for the operating system's own
# signature validation. Add-AppxPackage always validates the package signature chain and
# the publisher identity encoded in the package family name; a package that is not signed
# by Microsoft Corporation cannot be registered for these identities.

# Manifests and signature blocks are small. A larger entry is rejected so a hostile
# archive cannot expand without bound while it is being inspected.
$script:MaxZipEntryBytes = 4MB

function Initialize-ZipSupport {
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    }
}

function Get-ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    $entry = $Archive.GetEntry($EntryName)
    if ($null -eq $entry) { return $null }
    if ($entry.Length -gt $script:MaxZipEntryBytes) {
        throw ('Zip entry ' + $EntryName + ' exceeds the allowed size.')
    }
    $stream = $entry.Open()
    $buffer = $null
    try {
        $buffer = New-Object System.IO.MemoryStream
        $chunk = New-Object byte[] 8192
        $total = 0
        while (($read = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
            $total += $read
            if ($total -gt $script:MaxZipEntryBytes) {
                throw ('Zip entry ' + $EntryName + ' exceeds the allowed size.')
            }
            $buffer.Write($chunk, 0, $read)
        }
        return , $buffer.ToArray()
    } finally {
        if ($null -ne $buffer) { $buffer.Dispose() }
        $stream.Dispose()
    }
}

# Real Store packages are often far smaller than 1 MB (VCLibs and .NET Native
# Runtime are hundreds of kilobytes). The floor only rejects empty responses;
# the zip header rejects HTML error pages of any size.
function Test-ZipPackageFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 32KB) {
        return ('Downloaded file is too small (' + $item.Length + ' bytes).')
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $header = New-Object byte[] 4
        $read = $stream.Read($header, 0, 4)
    } finally {
        $stream.Dispose()
    }
    if ($read -lt 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B -or $header[2] -ne 0x03 -or $header[3] -ne 0x04) {
        return 'Downloaded file is not a zip package.'
    }
    return $null
}

function Read-PackageManifestXml {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if (-not [string]::IsNullOrEmpty($Text) -and [int][char]$Text[0] -eq 0xFEFF) {
        $Text = $Text.Substring(1)
    }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = $script:MaxZipEntryBytes
    $stringReader = $null
    $reader = $null
    try {
        $stringReader = New-Object System.IO.StringReader $Text
        $reader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
        return $xml
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
}

function Get-PackageIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-ZipSupport
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entryName = $null
        foreach ($candidate in 'AppxMetadata/AppxBundleManifest.xml', 'AppxManifest.xml') {
            if ($null -ne $archive.GetEntry($candidate)) { $entryName = $candidate; break }
        }
        if ($null -eq $entryName) {
            throw 'No package manifest found in ' + (Split-Path -Leaf $Path) + '.'
        }
        $bytes = Get-ZipEntryBytes -Archive $archive -EntryName $entryName
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $xml = Read-PackageManifestXml -Text $text
        # Store manifests declare a default namespace. XPath without a namespace
        # manager does not see those elements, so match on LocalName instead.
        $rootName = $null
        if ($null -ne $xml.DocumentElement) { $rootName = $xml.DocumentElement.LocalName }
        if ($rootName -ne 'Bundle' -and $rootName -ne 'Package') {
            throw 'Package manifest root is not Bundle or Package.'
        }
        $identityNode = $null
        foreach ($child in $xml.DocumentElement.ChildNodes) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq 'Identity') {
                $identityNode = $child
                break
            }
        }
        if ($null -eq $identityNode) {
            throw 'Identity element missing from ' + $entryName + '.'
        }
        return [pscustomobject]@{
            Name         = [string]$identityNode.GetAttribute('Name')
            Version      = [string]$identityNode.GetAttribute('Version')
            Publisher    = [string]$identityNode.GetAttribute('Publisher')
            Architecture = [string]$identityNode.GetAttribute('ProcessorArchitecture')
            Manifest     = $entryName
        }
    } finally {
        $archive.Dispose()
    }
}

# AppxSignature.p7x stores a 4-byte PKCX magic followed by a DER encoded PKCS#7 blob.
function Get-PackageSignature {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-ZipSupport
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $bytes = Get-ZipEntryBytes -Archive $archive -EntryName 'AppxSignature.p7x'
    } finally {
        $archive.Dispose()
    }
    if ($null -eq $bytes -or $bytes.Length -lt 16) { return $null }
    $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    $offset = 0
    if ($magic -eq 'PKCX') { $offset = 4 }
    $blob = New-Object byte[] ($bytes.Length - $offset)
    [Array]::Copy($bytes, $offset, $blob, 0, $blob.Length)
    try {
        $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
        $cms.Decode($blob)
        $signer = $null
        if ($cms.SignerInfos.Count -gt 0) { $signer = $cms.SignerInfos[0].Certificate }
        $chain = @()
        foreach ($certificate in $cms.Certificates) { $chain += [string]$certificate.Subject }
        $signerSubject = $null
        $issuer = $null
        $notAfter = $null
        if ($null -ne $signer) {
            $signerSubject = [string]$signer.Subject
            $issuer = [string]$signer.Issuer
            $notAfter = [string]$signer.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        return [pscustomobject]@{
            SignerSubject = $signerSubject
            Issuer        = $issuer
            NotAfter      = $notAfter
            Chain         = $chain
        }
    } catch {
        return [pscustomobject]@{
            SignerSubject = $null
            Issuer        = $null
            NotAfter      = $null
            Chain         = @()
            Error         = $_.Exception.Message
        }
    }
}

function Test-PackageProvenance {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedIdentity,
        [string]$ExpectedPublisher = $script:ExpectedPublisher
    )

    $checks = @()
    $identity = $null
    $signature = $null

    try {
        $identity = Get-PackageIdentity -Path $Path
        $checks += [pscustomobject]@{ Name = 'Package manifest is readable'; Passed = $true; Detail = $identity.Manifest }
    } catch {
        $checks += [pscustomobject]@{ Name = 'Package manifest is readable'; Passed = $false; Detail = $_.Exception.Message }
        return [pscustomobject]@{ Passed = $false; Identity = $null; Signature = $null; Checks = $checks }
    }

    $identityMatch = ($identity.Name -eq $ExpectedIdentity)
    $checks += [pscustomobject]@{
        Name   = 'Identity matches ' + $ExpectedIdentity
        Passed = $identityMatch
        Detail = $identity.Name + ' ' + $identity.Version
    }

    $publisherMatch = ($identity.Publisher -eq $ExpectedPublisher)
    $checks += [pscustomobject]@{
        Name   = 'Publisher is Microsoft Corporation'
        Passed = $publisherMatch
        Detail = $identity.Publisher
    }

    $signature = Get-PackageSignature -Path $Path
    if ($null -eq $signature -or [string]::IsNullOrEmpty($signature.SignerSubject)) {
        $detail = 'signature block could not be decoded'
        if ($null -ne $signature -and $signature.PSObject.Properties['Error']) { $detail = $signature.Error }
        $checks += [pscustomobject]@{ Name = 'Signature block decodes'; Passed = $false; Detail = $detail }
    } else {
        $checks += [pscustomobject]@{ Name = 'Signature block decodes'; Passed = $true; Detail = $signature.SignerSubject }
        $signerMatch = ($signature.SignerSubject -eq $ExpectedPublisher)
        $checks += [pscustomobject]@{
            Name   = 'Signer subject is Microsoft Corporation'
            Passed = $signerMatch
            Detail = $signature.SignerSubject
        }
    }

    $passed = $true
    foreach ($check in $checks) { if (-not $check.Passed) { $passed = $false } }

    return [pscustomobject]@{
        Passed    = $passed
        Identity  = $identity
        Signature = $signature
        Checks    = $checks
    }
}
