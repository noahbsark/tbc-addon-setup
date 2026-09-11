# Shared by the data updater and the explicitly launched Windows upgrade helper.
# Downloads are restricted to this project's main-branch release manifest/files.
function Get-NsrProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-NsrBytes {
    param([string]$Url, [int]$MaximumBytes)
    if (-not $Url.StartsWith('https://raw.githubusercontent.com/noahbsark/tbc-addon-setup/main/nightslayer-rating/')) {
        throw 'Unexpected release download location.'
    }
    $request = [Net.WebRequest]::Create($Url)
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'NightslayerRating/1.4.0 version check'
    $response = $null
    $stream = $null
    $memory = New-Object IO.MemoryStream
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt $MaximumBytes) { throw 'Invalid release response.' }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $MaximumBytes) { throw 'Release download exceeds its size limit.' }
            $memory.Write($buffer, 0, $read)
        }
        return ,$memory.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $memory.Dispose()
    }
}

function Convert-NsrRelease {
    param($Object)
    $version = [string](Get-NsrProperty $Object 'version')
    $sha = [string](Get-NsrProperty $Object 'sha256')
    $archive = [string](Get-NsrProperty $Object 'archive')
    if ($version -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or $sha -notmatch '^[a-fA-F0-9]{64}$' -or
        $archive -cne ('NightslayerRating-{0}-Windows.zip' -f $version)) { throw 'Invalid release manifest.' }
    return [pscustomobject]@{ version = $version; sha256 = $sha.ToLowerInvariant(); archive = $archive }
}

function Get-NsrRelease {
    $url = 'https://raw.githubusercontent.com/noahbsark/tbc-addon-setup/main/nightslayer-rating/latest.json'
    $bytes = Get-NsrBytes -Url $url -MaximumBytes 16384
    $object = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    return Convert-NsrRelease $object
}

function Assert-NsrArchiveHash {
    param([string]$ArchivePath, [string]$ExpectedHash)
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $actual -ne $ExpectedHash) {
        throw 'Downloaded upgrade failed its SHA256 check. Installed files have not been changed.'
    }
}

function Expand-NsrRelease {
    param([string]$ArchivePath, [string]$Destination, [string]$Version)
    if ($Version -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') { throw 'Invalid release version.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $rootName = 'NightslayerRating-' + $Version
    try {
        if ($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt 500) { throw 'Invalid archive file count.' }
        $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $parts = @($name.TrimEnd('/') -split '/')
            if ($name -notmatch '^[A-Za-z0-9 _./-]+$' -or $parts.Count -lt 2 -or
                $parts[0] -cne $rootName -or $parts -contains '..' -or $parts -contains '.' -or
                $parts -contains '' -or ($parts | Where-Object { $_.EndsWith('.') -or $_.EndsWith(' ') }) -or
                -not $seen.Add($name.TrimEnd('/')) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'Unsafe or duplicate archive path.'
            }
            $total += $entry.Length
            if ($entry.Length -gt 20971520 -or $total -gt 52428800) { throw 'Upgrade archive is too large.' }
        }
        foreach ($required in @('Install.ps1', 'Addon/NightslayerRating/NightslayerRating.toc', 'Updater/NightslayerRatingUpdater.ps1', 'Updater/Release.ps1')) {
            if (-not $seen.Contains($rootName + '/' + $required)) { throw ('Upgrade is missing ' + $required) }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
    $root = Join-Path $Destination $rootName
    $toc = Get-Content -LiteralPath (Join-Path $root 'Addon/NightslayerRating/NightslayerRating.toc') -Raw
    if ($toc -notmatch ('(?m)^## Version: ' + [regex]::Escape($Version) + '\s*$')) { throw 'Upgrade version does not match the manifest.' }
    return $root
}
