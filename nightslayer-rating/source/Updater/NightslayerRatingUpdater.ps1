[CmdletBinding()]
param(
    [string]$WowPath,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$DefaultRealm = 'Nightslayer'
$SupportedRealms = @{
    nightslayer = 'Nightslayer'
    dreamscythe = 'Dreamscythe'
}
$Region = 'US'
$ApiBase = 'https://ironforge.pro/api'
$SharedSnapshotUrl = 'https://github.com/noahbsark/tbc-addon-setup/releases/download/ratings-data/shared-cache.json.gz'
$SharedSnapshotMaxCompressedBytes = 10485760
$SharedSnapshotMaxJsonChars = 52428800
$SharedSnapshotMaxPlayers = 100000
$ProfileLimitPerRun = 50
$ProfileSuccessDelayMilliseconds = 500
$ProfileErrorDelayMilliseconds = 3000
$ProfileRefreshSeconds = 604800
$RequestRetentionSeconds = 2592000
$ExactCacheRetentionSeconds = 7776000
$PriorityOffset = 2000000000
$UpdaterDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $UpdaterDirectory 'config.json'
$CachePath = Join-Path $UpdaterDirectory 'cache.json'
$LogPath = Join-Path $UpdaterDirectory 'updater.log'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-UnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Write-Log {
    param([string]$Message)

    $line = '{0:u} {1}' -f [DateTime]::UtcNow, $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1048576) {
            [IO.File]::WriteAllText($LogPath, '', $Utf8NoBom)
        }
        [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $Utf8NoBom)
    } catch {
        # Logging must never prevent an update.
    }

    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Write-AtomicUtf8 {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, $Content, $Utf8NoBom)

    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporaryPath, $Path, $null)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    } catch {
        [IO.File]::Copy($temporaryPath, $Path, $true)
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-SharedUtf8 {
    param([string]$Path)

    # WoW may keep SavedVariables open while the game is running. Open with
    # ReadWrite/Delete sharing so the updater can inspect the last flushed copy.
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $reader = New-Object IO.StreamReader($stream, $Utf8NoBom, $true)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-ObjectProperty {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-RatingMap {
    param($Object)

    $map = @{}
    if ($null -eq $Object) {
        return $map
    }

    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $value = 0
            if ([int]::TryParse([string]$Object[$key], [ref]$value)) {
                $map[[string]$key] = $value
            }
        }
        return $map
    }

    foreach ($property in $Object.PSObject.Properties) {
        $value = 0
        if ([int]::TryParse([string]$property.Value, [ref]$value)) {
            $map[[string]$property.Name] = $value
        }
    }

    return $map
}

function Convert-SharedRatingMap {
    param($Object)

    $raw = Convert-RatingMap $Object
    $map = @{}
    foreach ($bracket in @(2, 3, 5)) {
        $key = [string]$bracket
        if (-not $raw.ContainsKey($key)) {
            continue
        }
        $rating = [int]$raw[$key]
        if ($rating -ge 1 -and $rating -le 10000) {
            $map[$key] = $rating
        }
    }
    return $map
}

function New-Cache {
    $cache = @{
        version = 6
        currentSeason = 3
        previousSeason = 2
        cutoffs = @{}
        syncedSeasons = @()
        lastLeaderboardUpdated = 0
        sharedGenerated = 0
        sharedCounts = @{ Nightslayer = 0; Dreamscythe = 0 }
        sharedPlayers = @{}
        players = @{}
    }
    $frozen = Get-Content -LiteralPath (Join-Path $UpdaterDirectory 'Season2Cutoffs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Merge-Cutoffs -Cache $cache -Object $frozen -Frozen
    return $cache
}

function Convert-CutoffEntry {
    param($Object)

    $values = @(Get-ObjectProperty $Object 'thresholds')
    if ($values.Count -ne 5) { return $null }
    $thresholds = @()
    $previous = 10000
    foreach ($value in $values) {
        $rating = 0
        if (-not [int]::TryParse([string]$value, [ref]$rating) -or
            $rating -lt 1 -or $rating -gt $previous) { return $null }
        $thresholds += $rating
        $previous = $rating
    }
    $updated = 0L
    if (-not [int64]::TryParse([string](Get-ObjectProperty $Object 'updated'), [ref]$updated) -or
        $updated -le 0 -or $updated -gt ((Get-UnixTime) + 3600)) { return $null }
    $checked = 0L
    [void][int64]::TryParse([string](Get-ObjectProperty $Object 'checked'), [ref]$checked)
    if ($checked -lt 0 -or $checked -gt ((Get-UnixTime) + 3600)) { return $null }
    return @{ updated = $updated; checked = $checked; thresholds = $thresholds }
}

function Merge-Cutoffs {
    param([hashtable]$Cache, $Object, [switch]$Frozen)

    foreach ($season in 1..20) {
        if ($season -eq 2 -and -not $Frozen) { continue }
        $brackets = Get-ObjectProperty $Object ([string]$season)
        if ($null -eq $brackets) { continue }
        foreach ($bracket in @(2, 3, 5)) {
            $entry = Convert-CutoffEntry (Get-ObjectProperty $brackets ([string]$bracket))
            if ($null -eq $entry) { continue }
            $key = [string]$season
            if (-not $Cache.cutoffs.ContainsKey($key)) { $Cache.cutoffs[$key] = @{} }
            $old = Get-ObjectProperty $Cache.cutoffs[$key] ([string]$bracket)
            if ($null -eq $old -or $entry.updated -ge $old.updated) {
                $Cache.cutoffs[$key][[string]$bracket] = $entry
            }
        }
    }
}

function Set-CacheSeason {
    param([hashtable]$Cache, [int]$Season)

    if ($Season -ne $Cache.currentSeason) {
        foreach ($player in $Cache.players.Values) {
            $player.current = @{}
            $player.previous = @{}
        }
        $Cache.syncedSeasons = @()
    }
    $Cache.currentSeason = $Season
    $Cache.previousSeason = [Math]::Max(0, $Season - 1)
}

function Sync-RatingCutoffs {
    param([hashtable]$Cache)

    foreach ($season in @($Cache.currentSeason, $Cache.previousSeason)) {
        if ($season -le 0 -or $season -eq 2) { continue }
        foreach ($bracket in @(2, 3, 5)) {
            $old = Get-ObjectProperty (Get-ObjectProperty $Cache.cutoffs ([string]$season)) ([string]$bracket)
            # Fresh shared snapshots supply these. Direct fallback checks daily.
            if ($null -ne $old -and ((Get-UnixTime) - $old.checked) -lt 86400) { continue }
            try {
                $payload = Invoke-IronForgeJson -Path ('anniversary/cutoffs/{0}/{1}/{2}/' -f $season, $Region, $bracket)
                $rows = @(Get-ObjectProperty $payload 'cutoff')
                if ($rows.Count -ne 5) { throw 'Expected all five cutoff tiers.' }
                $thresholds = @()
                $labels = @('Rank One', 'Gladiator', 'Duelist', 'Rival', 'Challenger')
                for ($i = 0; $i -lt 5; $i++) {
                    $row = @($rows[$i])
                    if ($row.Count -lt 2 -or
                        ($i -eq 0 -and [string]$row[1] -notmatch '^.+ Gladiator$') -or
                        ($i -gt 0 -and [string]$row[1] -ne $labels[$i])) {
                        throw 'Unexpected cutoff tier order.'
                    }
                    $thresholds += $row[0]
                }
                $stamp = [DateTimeOffset]::Parse([string](Get-ObjectProperty $payload 'updated'), [Globalization.CultureInfo]::InvariantCulture)
                $entry = Convert-CutoffEntry @{
                    updated = $stamp.ToUnixTimeSeconds()
                    checked = Get-UnixTime
                    thresholds = $thresholds
                }
                if ($null -eq $entry) { throw 'Invalid cutoff values or timestamp.' }
                Merge-Cutoffs -Cache $Cache -Object @{ ([string]$season) = @{ ([string]$bracket) = $entry } }
            } catch {
                Write-Log ('US S{0} {1}v{1} cutoffs unavailable; retaining last valid values. {2}' -f $season, $bracket, $_.Exception.Message)
            }
        }
    }
}

function Read-Cache {
    $cache = New-Cache
    if (-not (Test-Path -LiteralPath $CachePath)) {
        return $cache
    }

    try {
        $raw = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $season = Get-ObjectProperty $raw 'currentSeason'
        if ($null -ne $season) {
            Set-CacheSeason -Cache $cache -Season ([int]$season)
        }
        Merge-Cutoffs -Cache $cache -Object (Get-ObjectProperty $raw 'cutoffs')

        $lastUpdated = Get-ObjectProperty $raw 'lastLeaderboardUpdated'
        if ($null -ne $lastUpdated) {
            $cache.lastLeaderboardUpdated = [int64]$lastUpdated
        }

        $rawVersion = [int]((Get-ObjectProperty $raw 'version') -as [int])
        $synced = Get-ObjectProperty $raw 'syncedSeasons'
        if ($rawVersion -ge 6 -and $null -ne $synced) {
            $cache.syncedSeasons = @($synced | ForEach-Object { [int]$_ })
        }

        $sharedGenerated = Get-ObjectProperty $raw 'sharedGenerated'
        if ($null -ne $sharedGenerated) {
            $cache.sharedGenerated = [int64]$sharedGenerated
        }

        $players = Get-ObjectProperty $raw 'players'
        if ($null -ne $players) {
            foreach ($property in $players.PSObject.Properties) {
                $value = $property.Value
                $name = [string](Get-ObjectProperty $value 'name')
                $realm = [string](Get-ObjectProperty $value 'realm')
                $keyParts = @(([string]$property.Name) -split '\|', 2)
                if ([string]::IsNullOrWhiteSpace($realm)) {
                    $realm = $(if ($keyParts.Count -eq 2) { $keyParts[0] } else { $DefaultRealm })
                }
                if ([string]::IsNullOrWhiteSpace($name) -and $keyParts.Count -eq 2) {
                    $name = $keyParts[1]
                }
                if ([string]::IsNullOrWhiteSpace($name) -or $null -eq (Resolve-SupportedRealm $realm)) {
                    continue
                }

                $record = Get-PlayerRecord -Cache $cache -Name $name -Realm $realm
                $record.current = Convert-RatingMap (Get-ObjectProperty $value 'current')
                $record.previous = Convert-SharedRatingMap (Get-ObjectProperty $value 'previous')
                $record.bestSeen = Convert-RatingMap (Get-ObjectProperty $value 'bestSeen')
                $record.exactBest = Convert-RatingMap (Get-ObjectProperty $value 'exactBest')
                $record.exactFetchedAt = [int64]((Get-ObjectProperty $value 'exactFetchedAt') -as [int64])
                $record.lastSeen = [int64]((Get-ObjectProperty $value 'lastSeen') -as [int64])
                $record.notFoundUntil = [int64]((Get-ObjectProperty $value 'notFoundUntil') -as [int64])
            }
        }

        if ($rawVersion -ge 4) {
            $sharedPlayers = Get-ObjectProperty $raw 'sharedPlayers'
            if ($null -ne $sharedPlayers) {
                foreach ($property in $sharedPlayers.PSObject.Properties) {
                    $hash = ([string]$property.Name).ToLowerInvariant()
                    if ($hash -notmatch '^[0-9a-f]{16}$') {
                        continue
                    }
                    $value = $property.Value
                    $cache.sharedPlayers[$hash] = @{
                        current = Convert-RatingMap (Get-ObjectProperty $value 'current')
                        bestSeen = Convert-RatingMap (Get-ObjectProperty $value 'bestSeen')
                        previous = Convert-SharedRatingMap (Get-ObjectProperty $value 'previous')
                    }
                }
            }

            $sharedCounts = Get-ObjectProperty $raw 'sharedCounts'
            foreach ($realm in @('Nightslayer', 'Dreamscythe')) {
                $count = 0
                if ([int]::TryParse([string](Get-ObjectProperty $sharedCounts $realm), [ref]$count)) {
                    $cache.sharedCounts[$realm] = [Math]::Max(0, $count)
                }
            }
        }
    } catch {
        Write-Log ('Cache could not be read; rebuilding it. ' + $_.Exception.Message)
        return New-Cache
    }

    return $cache
}

function Save-Cache {
    param([hashtable]$Cache)

    $json = $Cache | ConvertTo-Json -Depth 8
    Write-AtomicUtf8 -Path $CachePath -Content $json
}

function Normalize-Realm {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return ($Value -replace "[\s\-']", '').ToLowerInvariant()
}

function Resolve-SupportedRealm {
    param([string]$Value)

    $normalized = Normalize-Realm $Value
    if ($SupportedRealms.ContainsKey($normalized)) {
        return $SupportedRealms[$normalized]
    }
    return $null
}

function Convert-AsciiLower {
    param([string]$Value)

    $builder = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 65 -and $code -le 90) {
            [void]$builder.Append([char]($code + 32))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-LookupHash {
    param(
        [string]$Name,
        [string]$Realm
    )

    $canonicalRealm = Resolve-SupportedRealm $Realm
    if ($null -eq $canonicalRealm) {
        return $null
    }

    $text = (Normalize-Realm $canonicalRealm) + '|' + (Convert-AsciiLower $Name)
    [byte[]]$bytes = [Text.Encoding]::UTF8.GetBytes($text)
    [int64[]]$values = @(0, 0, 0, 0)
    [int[]]$bases = @(131, 137, 139, 149)
    [int[]]$moduli = @(65521, 65519, 65497, 65479)
    foreach ($value in $bytes) {
        for ($index = 0; $index -lt 4; $index++) {
            $values[$index] = (($values[$index] * $bases[$index]) + [int]$value) % $moduli[$index]
        }
    }
    return ('{0:x4}{1:x4}{2:x4}{3:x4}' -f $values[0], $values[1], $values[2], $values[3])
}

function Get-PlayerRecord {
    param(
        [hashtable]$Cache,
        [string]$Name,
        [string]$Realm = $DefaultRealm
    )

    $canonicalRealm = Resolve-SupportedRealm $Realm
    if ($null -eq $canonicalRealm) {
        throw ('Unsupported realm: ' + $Realm)
    }

    $key = (Normalize-Realm $canonicalRealm) + '|' + $Name.ToLowerInvariant()
    if (-not $Cache.players.ContainsKey($key)) {
        $Cache.players[$key] = @{
            name = $Name
            realm = $canonicalRealm
            current = @{}
            previous = @{}
            bestSeen = @{}
            exactBest = @{}
            exactFetchedAt = 0
            lastSeen = 0
            notFoundUntil = 0
        }
    } elseif ([string]::IsNullOrWhiteSpace([string]$Cache.players[$key].name)) {
        $Cache.players[$key].name = $Name
    }

    $Cache.players[$key].realm = $canonicalRealm

    return $Cache.players[$key]
}

function Invoke-IronForgeJson {
    param(
        [string]$Path,
        [switch]$AllowNotFound,
        [switch]$AllowServerError
    )

    $uri = $ApiBase.TrimEnd('/') + '/' + $Path.TrimStart('/')
    $delays = @(2, 5, 10)

    for ($attempt = 0; $attempt -lt $delays.Count; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 45 -Headers @{
                'Accept' = 'application/json'
                'User-Agent' = 'NightslayerRating/1.3.0 (local WoW addon updater; adaptive-rate cache)'
            }
        } catch {
            $statusCode = $null
            if ($null -ne $_.Exception.Response) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                } catch {
                    $statusCode = $null
                }
            }

            if ($AllowNotFound -and $statusCode -eq 404) {
                return $null
            }
            if ($AllowServerError -and $statusCode -ge 500 -and $statusCode -le 599) {
                return [pscustomobject]@{
                    __nsrTransientError = $true
                    statusCode = $statusCode
                }
            }

            if ($attempt -eq ($delays.Count - 1)) {
                throw
            }

            Start-Sleep -Seconds $delays[$attempt]
        }
    }

    return $null
}

function Get-SharedSnapshot {
    $delays = @(1, 3, 8)

    for ($attempt = 0; $attempt -lt $delays.Count; $attempt++) {
        $request = $null
        $response = $null
        $responseStream = $null
        $download = $null
        $memory = $null
        $gzip = $null
        $reader = $null
        try {
            $uri = $SharedSnapshotUrl + '?t=' + (Get-UnixTime)
            $request = [Net.HttpWebRequest]::Create($uri)
            $request.Method = 'GET'
            $request.Accept = 'application/gzip, application/octet-stream'
            $request.UserAgent = 'NightslayerRating/1.3.0 (shared snapshot client)'
            $request.Timeout = 45000
            $request.ReadWriteTimeout = 45000
            $response = $request.GetResponse()
            if ($response.ContentLength -gt $SharedSnapshotMaxCompressedBytes) {
                throw ('Shared snapshot advertised an invalid compressed size: ' + $response.ContentLength)
            }

            $responseStream = $response.GetResponseStream()
            $download = New-Object IO.MemoryStream
            [byte[]]$downloadBuffer = New-Object byte[] 8192
            while (($read = $responseStream.Read($downloadBuffer, 0, $downloadBuffer.Length)) -gt 0) {
                if (($download.Length + $read) -gt $SharedSnapshotMaxCompressedBytes) {
                    throw 'Shared snapshot exceeded the compressed-size limit.'
                }
                $download.Write($downloadBuffer, 0, $read)
            }
            [byte[]]$bytes = $download.ToArray()
            if ($bytes.Length -le 0 -or $bytes.Length -gt $SharedSnapshotMaxCompressedBytes) {
                throw ('Shared snapshot had an invalid compressed size: ' + $bytes.Length)
            }

            $memory = New-Object IO.MemoryStream(,$bytes)
            $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Decompress)
            $reader = New-Object IO.StreamReader($gzip, $Utf8NoBom)
            $jsonBuilder = New-Object Text.StringBuilder
            [char[]]$jsonBuffer = New-Object char[] 8192
            while (($charsRead = $reader.Read($jsonBuffer, 0, $jsonBuffer.Length)) -gt 0) {
                if (($jsonBuilder.Length + $charsRead) -gt $SharedSnapshotMaxJsonChars) {
                    throw 'Shared snapshot exceeded the decompressed-size limit.'
                }
                [void]$jsonBuilder.Append($jsonBuffer, 0, $charsRead)
            }
            $json = $jsonBuilder.ToString()
            if ([string]::IsNullOrWhiteSpace($json)) {
                throw ('Shared snapshot had an invalid JSON size: ' + $json.Length)
            }

            return $json | ConvertFrom-Json -ErrorAction Stop
        } catch {
            if ($attempt -eq ($delays.Count - 1)) {
                Write-Log ('Shared snapshot unavailable; using direct IronForge fallback. ' + $_.Exception.Message)
                return $null
            }
            Start-Sleep -Seconds $delays[$attempt]
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $gzip) { $gzip.Dispose() }
            if ($null -ne $memory) { $memory.Dispose() }
            if ($null -ne $download) { $download.Dispose() }
            if ($null -ne $responseStream) { $responseStream.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            if ($null -ne $request) { $request.Abort() }
        }
    }

    return $null
}

function Sync-SharedSnapshot {
    param([hashtable]$Cache)

    $snapshot = Get-SharedSnapshot
    if ($null -eq $snapshot) {
        return $false
    }

    $version = [int]((Get-ObjectProperty $snapshot 'version') -as [int])
    $season = [int]((Get-ObjectProperty $snapshot 'season') -as [int])
    $region = [string](Get-ObjectProperty $snapshot 'region')
    $keyAlgorithm = [string](Get-ObjectProperty $snapshot 'keyAlgorithm')
    $sharedPlayers = Get-ObjectProperty $snapshot 'players'
    if ($null -eq $sharedPlayers) {
        Write-Log 'Shared snapshot has no player table; using direct IronForge fallback.'
        return $false
    }
    $playerProperties = @($sharedPlayers.PSObject.Properties)
    $previousSeason = [int]((Get-ObjectProperty $snapshot 'previousSeason') -as [int])
    if ($version -lt 6 -or $keyAlgorithm -ne 'nsr-h4-v1' -or $season -lt $Cache.currentSeason -or $season -gt 20 -or
        $previousSeason -ne ($season - 1) -or
        $region -ne $Region -or $playerProperties.Count -le 0 -or
        $playerProperties.Count -gt $SharedSnapshotMaxPlayers) {
        Write-Log 'Shared snapshot failed validation; using direct IronForge fallback.'
        return $false
    }

    $newSharedPlayers = @{}
    $merged = 0
    foreach ($property in $playerProperties) {
        $hash = ([string]$property.Name).ToLowerInvariant()
        if ($hash -notmatch '^[0-9a-f]{16}$') {
            continue
        }
        $value = $property.Value
        $current = Convert-SharedRatingMap (Get-ObjectProperty $value 'current')
        $bestSeen = Convert-SharedRatingMap (Get-ObjectProperty $value 'bestSeen')
        $previous = Convert-SharedRatingMap (Get-ObjectProperty $value 'previous')
        if ($current.Count -eq 0 -and $bestSeen.Count -eq 0 -and $previous.Count -eq 0) {
            continue
        }
        $newSharedPlayers[$hash] = @{ current = $current; bestSeen = $bestSeen; previous = $previous }
        $merged++
    }

    # Version 2/3 caches stored thousands of bulk names locally. Keep only exact
    # profiles now that bulk ratings live in the pseudonymous shared table.
    $now = Get-UnixTime
    foreach ($key in @($Cache.players.Keys)) {
        if ([int64]$Cache.players[$key].exactFetchedAt -le 0 -and
            [int64]$Cache.players[$key].notFoundUntil -le $now) {
            [void]$Cache.players.Remove($key)
        }
    }

    # Preserve private exact highs while refreshing their current values from the
    # newer shared row when that character is present on a leaderboard.
    Set-CacheSeason -Cache $Cache -Season $season
    foreach ($player in @($Cache.players.Values)) {
        $player.current = @{}
        $player.previous = @{}
        $hash = Get-LookupHash -Name ([string]$player.name) -Realm ([string]$player.realm)
        if ($null -eq $hash -or -not $newSharedPlayers.ContainsKey($hash)) {
            continue
        }
        $sharedCurrent = $newSharedPlayers[$hash].current
        $player.previous = Convert-SharedRatingMap $newSharedPlayers[$hash].previous
        foreach ($bracket in @(2, 3, 5)) {
            $key = [string]$bracket
            if ($sharedCurrent.ContainsKey($key)) {
                $player.current[$key] = [int]$sharedCurrent[$key]
            }
        }
    }

    $Cache.currentSeason = $season
    Merge-Cutoffs -Cache $Cache -Object (Get-ObjectProperty $snapshot 'cutoffs')
    $Cache.sharedPlayers = $newSharedPlayers
    $Cache.sharedGenerated = [int64]((Get-ObjectProperty $snapshot 'generated') -as [int64])
    $Cache.lastLeaderboardUpdated = [int64]((Get-ObjectProperty $snapshot 'leaderboardUpdated') -as [int64])
    $snapshotCounts = Get-ObjectProperty $snapshot 'counts'
    foreach ($realm in @('Nightslayer', 'Dreamscythe')) {
        $count = 0
        if ([int]::TryParse([string](Get-ObjectProperty $snapshotCounts $realm), [ref]$count)) {
            $Cache.sharedCounts[$realm] = [Math]::Max(0, $count)
        }
    }
    $Cache.syncedSeasons = $(if ($season -gt 1) { @(1..($season - 1)) } else { @() })
    Write-Log ('Shared snapshot: loaded {0} pseudonymous Nightslayer and Dreamscythe rows.' -f $merged)
    return $true
}

function Get-Leaderboard {
    param(
        [int]$Season,
        [int]$Bracket,
        [switch]$Probe
    )

    return Invoke-IronForgeJson -Path ('anniversary/leaderboards/{0}/{1}/{2}/' -f $Season, $Region, $Bracket) -AllowNotFound -AllowServerError:$Probe
}

function Sync-LeaderboardSeason {
    param(
        [hashtable]$Cache,
        [int]$Season,
        [bool]$IsCurrent
    )

    $now = Get-UnixTime
    $complete = $true

    foreach ($bracket in @(2, 3, 5)) {
        $payload = Get-Leaderboard -Season $Season -Bracket $bracket
        $rows = @(Get-ObjectProperty $payload 'data')
        if ($null -eq $payload -or $rows.Count -eq 0) {
            $complete = $false
            continue
        }

        if ($IsCurrent -or $Season -eq $Cache.previousSeason) {
            foreach ($cachedPlayer in $Cache.players.Values) {
                if ($null -ne (Resolve-SupportedRealm ([string]$cachedPlayer.realm))) {
                    $map = $(if ($IsCurrent) { $cachedPlayer.current } else { $cachedPlayer.previous })
                    [void]$map.Remove([string]$bracket)
                }
            }
        }

        $matched = 0
        $realmMatches = @{ Nightslayer = 0; Dreamscythe = 0 }
        foreach ($row in $rows) {
            $server = [string](Get-ObjectProperty $row 'server')
            $canonicalRealm = Resolve-SupportedRealm $server
            if ($null -eq $canonicalRealm) {
                continue
            }

            $name = [string](Get-ObjectProperty $row 'name')
            $ratingValue = Get-ObjectProperty $row 'rating'
            $rating = 0
            if ([string]::IsNullOrWhiteSpace($name) -or
                -not [int]::TryParse([string]$ratingValue, [ref]$rating) -or
                $rating -lt 1 -or $rating -gt 10000) {
                continue
            }

            $player = Get-PlayerRecord -Cache $Cache -Name $name -Realm $canonicalRealm
            $player.name = $name
            $player.lastSeen = $now
            if ($IsCurrent) {
                $player.current[[string]$bracket] = $rating
            } elseif ($Season -eq $Cache.previousSeason) {
                $player.previous[[string]$bracket] = $rating
            }

            $previousBest = 0
            if ($player.bestSeen.ContainsKey([string]$bracket)) {
                $previousBest = [int]$player.bestSeen[[string]$bracket]
            }
            if ($rating -gt $previousBest) {
                $player.bestSeen[[string]$bracket] = $rating
            }
            $matched++
            $realmMatches[$canonicalRealm]++
        }

        $payloadUpdated = Get-ObjectProperty $payload 'updated'
        if ($IsCurrent -and $null -ne $payloadUpdated) {
            $milliseconds = [double]$payloadUpdated
            $Cache.lastLeaderboardUpdated = [int64][Math]::Floor($milliseconds / 1000)
        }

        Write-Log ('Season {0} {1}v{1}: cached {2} players ({3} Nightslayer, {4} Dreamscythe)' -f $Season, $bracket, $matched, $realmMatches.Nightslayer, $realmMatches.Dreamscythe)
        Start-Sleep -Milliseconds 350
    }

    return $complete
}

function Find-CurrentSeason {
    param([hashtable]$Cache)

    $season = [Math]::Max(1, [int]$Cache.currentSeason)
    while ($season -lt 20) {
        $nextSeason = $season + 1
        $probe = Get-Leaderboard -Season $nextSeason -Bracket 2 -Probe
        $rows = @(Get-ObjectProperty $probe 'data')
        if ($null -eq $probe -or $rows.Count -eq 0) {
            break
        }
        $season = $nextSeason
        Start-Sleep -Milliseconds 350
    }

    return $season
}

function Get-QueuedRequests {
    param(
        [string]$GamePath,
        [hashtable]$Cache
    )

    $requests = @{}
    $now = Get-UnixTime
    $accountRoot = Join-Path $GamePath 'WTF\Account'
    if (Test-Path -LiteralPath $accountRoot) {
        foreach ($accountDirectory in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
            # Character folders are available even before WoW flushes SavedVariables.
            foreach ($realmDirectory in @(Get-ChildItem -LiteralPath $accountDirectory.FullName -Directory -ErrorAction SilentlyContinue)) {
                $realm = Resolve-SupportedRealm $realmDirectory.Name
                if ($null -eq $realm) {
                    continue
                }
                foreach ($characterDirectory in @(Get-ChildItem -LiteralPath $realmDirectory.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $name = [string]$characterDirectory.Name
                    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 24 -or
                        $name -notmatch '^[^"|\\]+$') {
                        continue
                    }
                    $key = (Normalize-Realm $realm) + '|' + $name.ToLowerInvariant()
                    if (-not $requests.ContainsKey($key)) {
                        $requests[$key] = [pscustomobject]@{
                            Name = $name
                            Realm = $realm
                            Stamp = $now
                            Priority = $true
                        }
                    }
                }
            }

            $savedVariables = Join-Path $accountDirectory.FullName 'SavedVariables\NightslayerRating.lua'
            if (-not (Test-Path -LiteralPath $savedVariables)) {
                continue
            }

            try {
                $text = Read-SharedUtf8 -Path $savedVariables
                if ([string]::IsNullOrWhiteSpace($text)) {
                    continue
                }
                $pattern = '\["(?<realm>Nightslayer|Dreamscythe)\|(?<name>[^"\\]+)"\]\s*=\s*(?<stamp>\d+)'
                foreach ($match in [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    $name = $match.Groups['name'].Value
                    $realm = Resolve-SupportedRealm $match.Groups['realm'].Value
                    $stamp = [int64]$match.Groups['stamp'].Value
                    if ($null -eq $realm) {
                        continue
                    }
                    $priority = $stamp -gt ($now + ($PriorityOffset / 2))
                    if ($priority) {
                        $stamp -= $PriorityOffset
                    }
                    if ($stamp -le 0 -or ($now - $stamp) -gt $RequestRetentionSeconds) {
                        continue
                    }
                    $key = (Normalize-Realm $realm) + '|' + $name.ToLowerInvariant()
                    $existing = $(if ($requests.ContainsKey($key)) { $requests[$key] } else { $null })
                    $existingPriority = [bool](Get-ObjectProperty $existing 'Priority')
                    $existingStamp = [int64]((Get-ObjectProperty $existing 'Stamp') -as [int64])
                    if ($null -eq $existing -or $priority -and -not $existingPriority -or
                        $priority -eq $existingPriority -and $stamp -gt $existingStamp) {
                        $requests[$key] = [pscustomobject]@{
                            Name = $name
                            Realm = $realm
                            Stamp = $stamp
                            Priority = $priority
                        }
                    }
                }
            } catch {
                Write-Log ('Could not inspect {0}: {1}' -f $savedVariables, $_.Exception.Message)
            }
        }
    }

    Write-Log ('Exact-profile queue: found {0} unique character request(s).' -f $requests.Count)
    return @($requests.Values | Sort-Object -Property `
        @{ Expression = 'Priority'; Descending = $true }, `
        @{ Expression = 'Stamp'; Descending = $true })
}

function Sync-QueuedProfiles {
    param(
        [hashtable]$Cache,
        [string]$GamePath
    )

    $now = Get-UnixTime
    $candidates = @()
    $requests = @(Get-QueuedRequests -GamePath $GamePath -Cache $Cache)
    $queuedKeys = @{}

    foreach ($request in $requests) {
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm
        $requestKey = (Normalize-Realm $request.Realm) + '|' + $request.Name.ToLowerInvariant()
        $queuedKeys[$requestKey] = $true
        $player.lastSeen = [Math]::Max([int64]$player.lastSeen, [int64]$request.Stamp)
        $notFoundUntil = [int64]$player.notFoundUntil
        $lastExact = [int64]$player.exactFetchedAt
        if ($notFoundUntil -gt $now) {
            continue
        }
        if ($lastExact -le 0 -or ($now - $lastExact) -ge $ProfileRefreshSeconds) {
            $candidates += $request
        }
    }

    Write-Log ('Exact profiles: {0} due now, {1} already cached or temporarily unavailable.' -f `
        $candidates.Count, ($requests.Count - $candidates.Count))

    $processed = 0
    $missing = 0
    $transientErrors = 0
    foreach ($request in @($candidates | Select-Object -First $ProfileLimitPerRun)) {
        $encodedRealm = [Uri]::EscapeDataString([string]$request.Realm)
        $encodedName = [Uri]::EscapeDataString([string]$request.Name)
        try {
            $profile = Invoke-IronForgeJson -Path ('anniversary/player/{0}/{1}' -f $encodedRealm, $encodedName) -AllowNotFound -AllowServerError
        } catch {
            $transientErrors++
            Write-Log ('Skipped temporarily unavailable profile {0}-{1}: {2}' -f
                $request.Name, $request.Realm, $_.Exception.Message)
            Start-Sleep -Milliseconds $ProfileErrorDelayMilliseconds
            continue
        }
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm

        if ([bool](Get-ObjectProperty $profile '__nsrTransientError')) {
            $transientErrors++
            $statusCode = [int](Get-ObjectProperty $profile 'statusCode')
            Write-Log ('Skipped temporarily unavailable profile {0}-{1}: HTTP {2}' -f
                $request.Name, $request.Realm, $statusCode)
            Start-Sleep -Milliseconds $ProfileErrorDelayMilliseconds
            continue
        }

        if ($null -eq $profile) {
            $player.notFoundUntil = $now + 604800
            $missing++
            Write-Log ('No IronForge profile found for ' + $request.Name + '-' + $request.Realm)
            Start-Sleep -Milliseconds $ProfileSuccessDelayMilliseconds
            continue
        }

        $profileInfo = Get-ObjectProperty $profile 'info'
        $canonicalName = [string](Get-ObjectProperty $profileInfo 'name')
        if (-not [string]::IsNullOrWhiteSpace($canonicalName)) {
            $player.name = $canonicalName
        }

        $bracketBest = Get-ObjectProperty $profile 'bracket_best'
        foreach ($bracket in @(2, 3, 5)) {
            $bestValue = Get-ObjectProperty $bracketBest ([string]$bracket)
            $best = 0
            if ([int]::TryParse([string]$bestValue, [ref]$best) -and
                $best -ge 1 -and $best -le 10000) {
                $player.exactBest[[string]$bracket] = $best
                $seen = 0
                if ($player.bestSeen.ContainsKey([string]$bracket)) {
                    $seen = [int]$player.bestSeen[[string]$bracket]
                }
                if ($best -gt $seen) {
                    $player.bestSeen[[string]$bracket] = $best
                }
            }
        }

        $seasonData = Get-ObjectProperty $profile ('season' + [string]$Cache.currentSeason)
        $player.current = @{}
        foreach ($bracket in @(2, 3, 5)) {
            $bracketData = Get-ObjectProperty $seasonData ([string]$bracket)
            $ratingValue = Get-ObjectProperty $bracketData 'rating'
            $rating = 0
            if ([int]::TryParse([string]$ratingValue, [ref]$rating) -and
                $rating -ge 1 -and $rating -le 10000) {
                $player.current[[string]$bracket] = $rating
            }
        }

        $player.exactFetchedAt = $now
        $player.notFoundUntil = 0
        $processed++
        Write-Log ('Fetched exact lifetime highs for ' + $player.name + '-' + $player.realm)
        Start-Sleep -Milliseconds $ProfileSuccessDelayMilliseconds
    }

    Write-Log ('Exact-profile batch: fetched {0}, not found {1}, transient errors {2}.' -f
        $processed, $missing, $transientErrors)

    $exactCutoff = $now - $ExactCacheRetentionSeconds
    foreach ($key in @($Cache.players.Keys)) {
        $player = $Cache.players[$key]
        if ($queuedKeys.ContainsKey($key)) {
            continue
        }
        $lastUsed = [Math]::Max([int64]$player.lastSeen, [int64]$player.exactFetchedAt)
        if ($lastUsed -gt 0 -and $lastUsed -lt $exactCutoff) {
            [void]$Cache.players.Remove($key)
        }
    }

    return $processed
}

function Escape-LuaString {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function Get-CachedRating {
    param(
        [hashtable]$Map,
        [int]$Bracket
    )

    if ($Map.ContainsKey([string]$Bracket)) {
        return [int]$Map[[string]$Bracket]
    }
    return 0
}

function Format-LuaRatingMap {
    param([hashtable]$Map)

    $parts = @()
    foreach ($bracket in @(2, 3, 5)) {
        $rating = Get-CachedRating -Map $Map -Bracket $bracket
        if ($rating -gt 0) {
            $parts += ('[{0}] = {1}' -f $bracket, $rating)
        }
    }
    return '{ ' + ($parts -join ', ') + ' }'
}

function Format-LuaSharedPlayer {
    param($Player)

    $ratings = @()
    foreach ($mapName in @('current', 'bestSeen', 'previous')) {
        $map = Get-ObjectProperty $Player $mapName
        foreach ($bracket in @(2, 3, 5)) {
            $ratings += Get-CachedRating -Map $map -Bracket $bracket
        }
    }
    return '{ ' + ($ratings -join ', ') + ' }'
}

function Write-LuaData {
    param(
        [hashtable]$Cache,
        [string]$AddonDirectory
    )

    $now = Get-UnixTime
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('-- Generated automatically. Do not edit while the updater is installed.')
    [void]$builder.AppendLine('NightslayerRatingData = {')
    [void]$builder.AppendLine('    meta = {')
    [void]$builder.AppendLine(('        realm = "{0}",' -f (Escape-LuaString $DefaultRealm)))
    [void]$builder.AppendLine('        realms = { "Nightslayer", "Dreamscythe" },')
    [void]$builder.AppendLine(('        region = "{0}",' -f (Escape-LuaString $Region)))
    [void]$builder.AppendLine(('        season = {0},' -f [int]$Cache.currentSeason))
    [void]$builder.AppendLine(('        previousSeason = {0},' -f [int]$Cache.previousSeason))
    [void]$builder.AppendLine(('        generated = {0},' -f $now))
    [void]$builder.AppendLine(('        leaderboardUpdated = {0},' -f [int64]$Cache.lastLeaderboardUpdated))
    [void]$builder.AppendLine(('        sharedGenerated = {0},' -f [int64]$Cache.sharedGenerated))
    [void]$builder.AppendLine('        profileLookup = true,')
    [void]$builder.AppendLine('        counts = {')
    [void]$builder.AppendLine(('            Nightslayer = {0},' -f [int]$Cache.sharedCounts.Nightslayer))
    [void]$builder.AppendLine(('            Dreamscythe = {0},' -f [int]$Cache.sharedCounts.Dreamscythe))
    [void]$builder.AppendLine('        },')
    [void]$builder.AppendLine('        source = "ironforge.pro via shared snapshot and local lookups",')
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    cutoffs = {')
    foreach ($season in @($Cache.cutoffs.Keys | Sort-Object { [int]$_ })) {
        [void]$builder.AppendLine(('        [{0}] = {{' -f [int]$season))
        foreach ($bracket in @(2, 3, 5)) {
            $entry = Get-ObjectProperty $Cache.cutoffs[$season] ([string]$bracket)
            if ($null -eq $entry) { continue }
            [void]$builder.AppendLine(('            [{0}] = {{ updated = {1}, thresholds = {{ {2} }} }},' -f
                $bracket, [int64]$entry.updated, ($entry.thresholds -join ', ')))
        }
        [void]$builder.AppendLine('        },')
    }
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    sharedPlayers = {')
    foreach ($hash in @($Cache.sharedPlayers.Keys | Sort-Object)) {
        $sharedPlayer = $Cache.sharedPlayers[$hash]
        [void]$builder.Append('        ["')
        [void]$builder.Append($hash)
        [void]$builder.Append('"] = ')
        [void]$builder.AppendLine((Format-LuaSharedPlayer $sharedPlayer) + ',')
    }
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    players = {')

    $outputPlayers = @()
    foreach ($player in $Cache.players.Values) {
        $isExact = [int64]$player.exactFetchedAt -gt 0
        $hasData = $isExact
        foreach ($bracket in @(2, 3, 5)) {
            if ((Get-CachedRating -Map $player.current -Bracket $bracket) -gt 0 -or
                (Get-CachedRating -Map $player.previous -Bracket $bracket) -gt 0 -or
                (Get-CachedRating -Map $player.bestSeen -Bracket $bracket) -gt 0 -or
                (Get-CachedRating -Map $player.exactBest -Bracket $bracket) -gt 0) {
                $hasData = $true
                break
            }
        }

        if ($hasData -and -not [string]::IsNullOrWhiteSpace([string]$player.name)) {
            $outputPlayers += $player
        }
    }

    foreach ($player in @($outputPlayers | Sort-Object { ([string]$_.realm) + '|' + ([string]$_.name) })) {
        $best = @{}
        $isExact = [int64]$player.exactFetchedAt -gt 0
        foreach ($bracket in @(2, 3, 5)) {
            $value = 0
            if ($isExact -and $player.exactBest.ContainsKey([string]$bracket)) {
                $value = Get-CachedRating -Map $player.exactBest -Bracket $bracket
            } else {
                $value = Get-CachedRating -Map $player.bestSeen -Bracket $bracket
            }
            if ($value -gt 0) {
                $best[[string]$bracket] = $value
            }
        }

        $escapedName = Escape-LuaString ([string]$player.name)
        $escapedRealm = Escape-LuaString ([string]$player.realm)
        $escapedKey = $escapedRealm + '|' + $escapedName
        [void]$builder.AppendLine(('        ["{0}"] = {{' -f $escapedKey))
        [void]$builder.AppendLine(('            name = "{0}",' -f $escapedName))
        [void]$builder.AppendLine(('            realm = "{0}",' -f $escapedRealm))
        [void]$builder.AppendLine(('            current = {0},' -f (Format-LuaRatingMap $player.current)))
        [void]$builder.AppendLine(('            previous = {0},' -f (Format-LuaRatingMap $player.previous)))
        [void]$builder.AppendLine(('            best = {0},' -f (Format-LuaRatingMap $best)))
        [void]$builder.AppendLine(('            exact = {0},' -f $(if ($isExact) { 'true' } else { 'false' })))
        [void]$builder.AppendLine('        },')
    }

    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('}')

    Write-AtomicUtf8 -Path (Join-Path $AddonDirectory 'Data.lua') -Content $builder.ToString()
    return $outputPlayers.Count + $Cache.sharedPlayers.Count
}

if ([string]::IsNullOrWhiteSpace($WowPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw 'No WoW path is configured. Run Install.cmd again.'
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $WowPath = [string]$config.WowPath
}

$WowPath = [IO.Path]::GetFullPath($WowPath.Trim().TrimEnd('\'))
$AddonPath = Join-Path $WowPath 'Interface\AddOns\NightslayerRating'
if (-not (Test-Path -LiteralPath $AddonPath)) {
    throw ('The addon folder was not found: ' + $AddonPath)
}

$mutex = New-Object Threading.Mutex($false, 'Local\NightslayerRatingUpdater')
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-Log 'Another updater instance is already running.'
        exit 0
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log 'Starting shared IronForge rating sync.'

    $cache = Read-Cache
    $sharedWorked = Sync-SharedSnapshot -Cache $cache
    if (-not $sharedWorked) {
        # Do not let an older shared row mask the fresher direct fallback below.
        if ($cache.sharedPlayers.Count -gt 0) { $cache.syncedSeasons = @() }
        $cache.sharedPlayers = @{}
        $cache.sharedCounts = @{ Nightslayer = 0; Dreamscythe = 0 }
        $cache.sharedGenerated = 0
        $currentSeason = Find-CurrentSeason -Cache $cache
        Set-CacheSeason -Cache $cache -Season $currentSeason

        [void](Sync-LeaderboardSeason -Cache $cache -Season $currentSeason -IsCurrent $true)

        for ($season = 1; $season -lt $currentSeason; $season++) {
            if (@($cache.syncedSeasons) -contains $season) {
                continue
            }

            $complete = Sync-LeaderboardSeason -Cache $cache -Season $season -IsCurrent $false
            if ($complete) {
                $cache.syncedSeasons = @($cache.syncedSeasons) + $season
            }
        }
    }

    Sync-RatingCutoffs -Cache $cache
    $profiles = Sync-QueuedProfiles -Cache $cache -GamePath $WowPath
    Save-Cache -Cache $cache
    $playersWritten = Write-LuaData -Cache $cache -AddonDirectory $AddonPath

    Write-Log ('Sync complete: {0} players written, {1} exact profile lookups.' -f $playersWritten, $profiles)
} catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    if (-not $Quiet) {
        Write-Error $_
    }
    exit 1
} finally {
    if ($hasMutex) {
        [void]$mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
