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
$ActiveProfileRefreshSeconds = 86400
$ActivePlayerSeconds = 3 * 86400
$UpdaterVersion = '1.4.1'
$RequestRetentionSeconds = 2592000
$ExactCacheRetentionSeconds = 7776000
$PriorityOffset = 2000000000
$UpdaterDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $UpdaterDirectory 'config.json'
$CachePath = Join-Path $UpdaterDirectory 'cache.json'
$BundledSnapshotPath = Join-Path $UpdaterDirectory 'BundledSnapshot.json.gz'
$LogPath = Join-Path $UpdaterDirectory 'updater.log'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $UpdaterDirectory 'Release.ps1')

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

function Convert-UpdateTimes {
    param($Object)
    $map = @{}
    $now = Get-UnixTime
    foreach ($bracket in @(2, 3, 5)) {
        $stamp = [int64]((Get-ObjectProperty $Object ([string]$bracket)) -as [int64])
        if ($stamp -gt 0 -and $stamp -le ($now + 3600)) { $map[[string]$bracket] = $stamp }
    }
    return $map
}

function Get-ProfileRefreshInterval {
    param($Request, [int64]$Now)
    $stamp = [int64]((Get-ObjectProperty $Request 'Stamp') -as [int64])
    if ([bool](Get-ObjectProperty $Request 'Priority') -and $stamp -le ($Now + 3600) -and
        $stamp -ge ($Now - $ActivePlayerSeconds)) { return $ActiveProfileRefreshSeconds }
    return $ProfileRefreshSeconds
}

function Convert-SourceTime {
    param($Value)
    $number = $Value -as [double]
    if ($null -eq $number) { return 0L }
    if ($number -gt 100000000000) { $number /= 1000 }
    if ($number -le 0 -or $number -gt ((Get-UnixTime) + 3600)) { return 0L }
    return [int64][Math]::Floor($number)
}

function Convert-RatingHistory {
    param($Object)
    $result = @{}
    $oldest = (Get-UnixTime) - 31 * 86400
    foreach ($bracket in @(2, 3, 5)) {
        $days = @{}
        foreach ($sample in @(Get-ObjectProperty $Object ([string]$bracket))) {
            $stamp = Convert-SourceTime (Get-ObjectProperty $sample 'at')
            $rating = (Get-ObjectProperty $sample 'rating') -as [int]
            if ($stamp -lt $oldest -or $rating -lt 1 -or $rating -gt 10000) { continue }
            $day = [string][Math]::Floor($stamp / 86400)
            if (-not $days.ContainsKey($day) -or $stamp -gt $days[$day].at) {
                $days[$day] = @{ at = $stamp; rating = $rating }
            }
        }
        $result[[string]$bracket] = @($days.Values | Sort-Object at | Select-Object -Last 32)
    }
    return $result
}

function Set-CurrentRating {
    param([hashtable]$Player, [int]$Bracket, [int]$Rating, [int64]$Updated)
    $key = [string]$Bracket
    $oldStamp = [int64]((Get-ObjectProperty $Player.currentUpdated $key) -as [int64])
    # Missing timestamps must never let an older/unknown source replace a dated row.
    if ($Rating -lt 1 -or $Rating -gt 10000 -or $Updated -lt $oldStamp) { return }
    $Player.current[$key] = $Rating
    $Player.currentUpdated[$key] = $Updated
    [void]$Player.currentLastKnown.Remove($key)
    if ($Player.tracking -and $Updated -gt 0) {
        $samples = @(Get-ObjectProperty $Player.history $key) | Where-Object { $null -ne $_ }
        $Player.history[$key] = @($samples) + @(@{ at = $Updated; rating = $Rating })
        $Player.history = Convert-RatingHistory $Player.history
    }
}

function Mark-CurrentRatingMissing {
    param([hashtable]$Player, [int]$Bracket, [int64]$Updated)
    $key = [string]$Bracket
    $oldStamp = [int64]((Get-ObjectProperty $Player.currentUpdated $key) -as [int64])
    if ($Player.current.ContainsKey($key) -and $Updated -ge $oldStamp) {
        $Player.currentLastKnown[$key] = 1
    }
}

function Sync-PlayerCurrentFromShared {
    param([hashtable]$Player, [hashtable]$SharedPlayers, [hashtable]$Updates)
    $hash = Get-LookupHash -Name $Player.name -Realm $Player.realm
    $row = Get-ObjectProperty $SharedPlayers $hash
    $ratings = Get-ObjectProperty $row 'current'
    foreach ($bracket in @(2, 3, 5)) {
        $stamp = [int64]((Get-ObjectProperty $Updates ([string]$bracket)) -as [int64])
        $rating = [int]((Get-ObjectProperty $ratings ([string]$bracket)) -as [int])
        if ($rating -gt 0) { Set-CurrentRating $Player $bracket $rating $stamp }
        else { Mark-CurrentRatingMissing $Player $bracket $stamp }
    }
}

function New-Cache {
    $cache = @{
        version = 6
        currentSeason = 3
        previousSeason = 2
        cutoffs = @{}
        syncedSeasons = @()
        lastLeaderboardUpdated = 0
        leaderboardUpdates = @{}
        status = @{ mode = 'bundled'; lastAttempt = 0; lastSuccess = 0; pendingProfiles = 0
            failedProfiles = 0; unavailableProfiles = 0; lastVersionCheck = 0; availableVersion = '' }
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
        foreach ($player in @($Cache.players.Values) + @($Cache.sharedPlayers.Values)) {
            $player.current = @{}
            $player.currentUpdated = @{}
            $player.currentLastKnown = @{}
            $player.history = @{}
            $player.previous = @{}
        }
        $Cache.syncedSeasons = @()
        $Cache.leaderboardUpdates = @{}
        $Cache.lastLeaderboardUpdated = 0
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
        $cache.leaderboardUpdates = Convert-UpdateTimes (Get-ObjectProperty $raw 'leaderboardUpdates')
        $savedStatus = Get-ObjectProperty $raw 'status'
        foreach ($key in @('lastAttempt', 'lastSuccess', 'lastVersionCheck', 'pendingProfiles', 'failedProfiles', 'unavailableProfiles')) {
            $cache.status[$key] = [Math]::Max(0, [int64]((Get-ObjectProperty $savedStatus $key) -as [int64]))
        }
        foreach ($key in @('mode', 'availableVersion')) {
            $value = [string](Get-ObjectProperty $savedStatus $key)
            if ($value.Length -le 32) { $cache.status[$key] = $value }
        }

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
                $record.currentUpdated = Convert-UpdateTimes (Get-ObjectProperty $value 'currentUpdated')
                $record.currentLastKnown = Convert-RatingMap (Get-ObjectProperty $value 'currentLastKnown')
                $record.history = Convert-RatingHistory (Get-ObjectProperty $value 'history')
                $record.tracking = (Get-ObjectProperty $value 'tracking') -eq $true
                $record.previous = Convert-SharedRatingMap (Get-ObjectProperty $value 'previous')
                $record.bestSeen = Convert-RatingMap (Get-ObjectProperty $value 'bestSeen')
                $record.exactBest = Convert-RatingMap (Get-ObjectProperty $value 'exactBest')
                $record.exactFetchedAt = [int64]((Get-ObjectProperty $value 'exactFetchedAt') -as [int64])
                $record.profileAttemptAt = [int64]((Get-ObjectProperty $value 'profileAttemptAt') -as [int64])
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
            currentUpdated = @{}
            currentLastKnown = @{}
            history = @{}
            tracking = $false
            previous = @{}
            bestSeen = @{}
            exactBest = @{}
            exactFetchedAt = 0
            profileAttemptAt = 0
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
                'User-Agent' = 'NightslayerRating/1.4.0 (local WoW addon updater; adaptive-rate cache)'
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

function Read-CompressedSnapshot {
    param([byte[]]$Bytes)

    if ($Bytes.Length -le 0 -or $Bytes.Length -gt $SharedSnapshotMaxCompressedBytes) {
        throw 'Snapshot exceeded the compressed-size limit.'
    }
    $memory = $null
    $gzip = $null
    $reader = $null
    try {
        $memory = New-Object IO.MemoryStream(,$Bytes)
        $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Decompress)
        $reader = New-Object IO.StreamReader($gzip, $Utf8NoBom)
        $jsonBuilder = New-Object Text.StringBuilder
        [char[]]$buffer = New-Object char[] 8192
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (($jsonBuilder.Length + $read) -gt $SharedSnapshotMaxJsonChars) {
                throw 'Snapshot exceeded the decompressed-size limit.'
            }
            [void]$jsonBuilder.Append($buffer, 0, $read)
        }
        return $jsonBuilder.ToString() | ConvertFrom-Json -ErrorAction Stop
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $gzip) { $gzip.Dispose() }
        if ($null -ne $memory) { $memory.Dispose() }
    }
}

function Initialize-BundledSnapshot {
    param([hashtable]$Cache)

    if (-not (Test-Path -LiteralPath $BundledSnapshotPath)) { return }
    try {
        if ((Get-Item -LiteralPath $BundledSnapshotPath).Length -gt $SharedSnapshotMaxCompressedBytes) {
            throw 'Bundled snapshot exceeded the size limit.'
        }
        $snapshot = Read-CompressedSnapshot ([IO.File]::ReadAllBytes($BundledSnapshotPath))
        if ([string](Get-ObjectProperty $snapshot 'region') -ne $Region -or
            [int](Get-ObjectProperty $snapshot 'version') -ne 6) { throw 'Invalid bundled snapshot format or region.' }
        # Upgrades can already have player rows but no cutoff metadata. Seed
        # missing cutoff tables without replacing those existing ratings.
        Merge-Cutoffs -Cache $Cache -Object (Get-ObjectProperty $snapshot 'cutoffs')
        if ($Cache.sharedPlayers.Count -gt 0) { return }
        [void](Import-SharedSnapshot -Cache $Cache -Snapshot $snapshot -SourceLabel 'Bundled snapshot')
    } catch {
        Write-Log ('Bundled snapshot unavailable; preserving existing data. ' + $_.Exception.Message)
    }
}

function Get-SharedSnapshot {
    $delays = @(1, 3, 8)

    for ($attempt = 0; $attempt -lt $delays.Count; $attempt++) {
        $request = $null
        $response = $null
        $responseStream = $null
        $download = $null
        try {
            $uri = $SharedSnapshotUrl + '?t=' + (Get-UnixTime)
            $request = [Net.HttpWebRequest]::Create($uri)
            $request.Method = 'GET'
            $request.Accept = 'application/gzip, application/octet-stream'
            $request.UserAgent = 'NightslayerRating/1.3.1 (shared snapshot client)'
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

            return Read-CompressedSnapshot $bytes
        } catch {
            if ($attempt -eq ($delays.Count - 1)) {
                Write-Log ('Shared snapshot unavailable; using direct IronForge fallback. ' + $_.Exception.Message)
                return $null
            }
            Start-Sleep -Seconds $delays[$attempt]
        } finally {
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
    $oldUpdated = $Cache.lastLeaderboardUpdated
    $worked = Import-SharedSnapshot -Cache $Cache -Snapshot $snapshot
    if ($worked) {
        $Cache.status.mode = $(if ([int64](Get-ObjectProperty $snapshot 'leaderboardUpdated') -lt $oldUpdated) { 'retained' } else { 'shared' })
        $Cache.status.lastSuccess = Get-UnixTime
    }
    return $worked
}

function Import-SharedSnapshot {
    param([hashtable]$Cache, $Snapshot, [string]$SourceLabel = 'Shared snapshot')

    if ($null -eq $snapshot) {
        return $false
    }

    $version = [int]((Get-ObjectProperty $snapshot 'version') -as [int])
    $season = [int]((Get-ObjectProperty $snapshot 'season') -as [int])
    $region = [string](Get-ObjectProperty $snapshot 'region')
    $keyAlgorithm = [string](Get-ObjectProperty $snapshot 'keyAlgorithm')
    $sharedPlayers = Get-ObjectProperty $snapshot 'players'
    if ($null -eq $sharedPlayers) {
        Write-Log ($SourceLabel + ' has no player table; retaining cached data.')
        return $false
    }
    $playerProperties = @($sharedPlayers.PSObject.Properties)
    $previousSeason = [int]((Get-ObjectProperty $snapshot 'previousSeason') -as [int])
    $legacy = $version -eq 4 -or $version -eq 5
    $generated = [int64]((Get-ObjectProperty $snapshot 'generated') -as [int64])
    $updated = [int64]((Get-ObjectProperty $snapshot 'leaderboardUpdated') -as [int64])
    $now = Get-UnixTime
    if (($version -ne 6 -and -not $legacy) -or $keyAlgorithm -ne 'nsr-h4-v1' -or
        $season -lt $Cache.currentSeason -or $season -gt 20 -or
        (-not $legacy -and $previousSeason -ne ($season - 1)) -or
        $generated -le 0 -or $generated -gt ($now + 3600) -or
        $updated -le 0 -or $updated -gt ($now + 3600) -or
        $region -ne $Region -or $playerProperties.Count -le 0 -or
        $playerProperties.Count -gt $SharedSnapshotMaxPlayers) {
        Write-Log ($SourceLabel + ' failed validation; retaining cached data and trying the fallback.')
        return $false
    }

    if ($season -eq $Cache.currentSeason -and $updated -lt $Cache.lastLeaderboardUpdated) {
        Write-Log ($SourceLabel + ' is older than the cached ratings; keeping the newer cache.')
        return $true
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
        $previous = @{}
        if (-not $legacy) {
            $previous = Convert-SharedRatingMap (Get-ObjectProperty $value 'previous')
        } elseif ($Cache.currentSeason -eq $season) {
            # v4/v5 has no previous-season field. Preserve the archive imported
            # from the bundle or a prior v6 snapshot instead of erasing it.
            $old = Get-ObjectProperty $Cache.sharedPlayers $hash
            $previous = Convert-SharedRatingMap (Get-ObjectProperty $old 'previous')
        }
        if ($current.Count -eq 0 -and $bestSeen.Count -eq 0 -and $previous.Count -eq 0) {
            continue
        }
        $newSharedPlayers[$hash] = @{ current = $current; bestSeen = $bestSeen; previous = $previous }
        $merged++
    }

    if ($merged -le 0) {
        Write-Log ($SourceLabel + ' contained no valid rating rows; keeping the existing cache.')
        return $false
    }
    if ($legacy -and $Cache.currentSeason -eq $season) {
        foreach ($hash in $Cache.sharedPlayers.Keys) {
            if ($newSharedPlayers.ContainsKey($hash)) { continue }
            $old = $Cache.sharedPlayers[$hash]
            # A player missing from an older format may still have an S2 row.
            # Only retain historical values; never imply a current rating.
            $previous = Convert-SharedRatingMap (Get-ObjectProperty $old 'previous')
            if ($previous.Count -gt 0) {
                $newSharedPlayers[$hash] = @{ current = @{}; previous = $previous
                    bestSeen = Convert-SharedRatingMap (Get-ObjectProperty $old 'bestSeen') }
            }
        }
    }

    # Version 2/3 caches stored thousands of bulk names locally. Keep only exact
    # profiles now that bulk ratings live in the pseudonymous shared table.
    foreach ($key in @($Cache.players.Keys)) {
        if (-not $Cache.players[$key].tracking -and [int64]$Cache.players[$key].exactFetchedAt -le 0 -and
            [int64]$Cache.players[$key].notFoundUntil -le $now) {
            [void]$Cache.players.Remove($key)
        }
    }

    # Preserve private exact highs while refreshing their current values from the
    # newer shared row when that character is present on a leaderboard.
    Set-CacheSeason -Cache $Cache -Season $season
    $updates = Convert-UpdateTimes (Get-ObjectProperty $snapshot 'leaderboardUpdates')
    foreach ($player in @($Cache.players.Values)) {
        Sync-PlayerCurrentFromShared $player $newSharedPlayers $updates
        if (-not $legacy) { $player.previous = @{} }
        $hash = Get-LookupHash -Name ([string]$player.name) -Realm ([string]$player.realm)
        if ($null -eq $hash -or -not $newSharedPlayers.ContainsKey($hash)) {
            continue
        }
        if (-not $legacy -or $newSharedPlayers[$hash].previous.Count -gt 0) {
            $player.previous = Convert-SharedRatingMap $newSharedPlayers[$hash].previous
        }
        foreach ($bracket in @(2, 3, 5)) {
            $key = [string]$bracket
            $player.bestSeen[$key] = [Math]::Max((Get-CachedRating $player.bestSeen $bracket),
                (Get-CachedRating $newSharedPlayers[$hash].bestSeen $bracket))
        }
    }

    $Cache.currentSeason = $season
    Merge-Cutoffs -Cache $Cache -Object (Get-ObjectProperty $snapshot 'cutoffs')
    $Cache.sharedPlayers = $newSharedPlayers
    $Cache.sharedGenerated = $generated
    $Cache.lastLeaderboardUpdated = $updated
    $Cache.leaderboardUpdates = $updates
    $snapshotCounts = Get-ObjectProperty $snapshot 'counts'
    foreach ($realm in @('Nightslayer', 'Dreamscythe')) {
        $count = 0
        if ([int]::TryParse([string](Get-ObjectProperty $snapshotCounts $realm), [ref]$count)) {
            $Cache.sharedCounts[$realm] = [Math]::Max(0, $count)
        }
    }
    if (-not $legacy) {
        $Cache.syncedSeasons = $(if ($season -gt 1) { @(1..($season - 1)) } else { @() })
    }
    Write-Log ('{0}: loaded {1} pseudonymous rows (format v{2}).' -f $SourceLabel, $merged, $version)
    return $true
}

function Test-LeaderboardPayload {
    param($Payload)

    if ($null -eq $Payload -or [bool](Get-ObjectProperty $Payload '__nsrTransientError')) { return $false }
    $rows = @(Get-ObjectProperty $Payload 'data' | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return $false }
    foreach ($row in $rows) {
        $rating = 0
        if (-not [int]::TryParse([string](Get-ObjectProperty $row 'rating'), [ref]$rating) -or
            $rating -lt 0 -or $rating -gt 10000 -or
            [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $row 'name')) -or
            [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $row 'server'))) { return $false }
    }
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
        try {
            $payload = Get-Leaderboard -Season $Season -Bracket $bracket
        } catch {
            Write-Log ('Season {0} {1}v{1} unavailable; keeping cached ratings. {2}' -f $Season, $bracket, $_.Exception.Message)
            $complete = $false
            continue
        }
        $rows = @(Get-ObjectProperty $payload 'data')
        if (-not (Test-LeaderboardPayload $payload)) {
            Write-Log ('Season {0} {1}v{1} returned no usable leaderboard; keeping cached ratings.' -f $Season, $bracket)
            $complete = $false
            continue
        }

        $stamp = Convert-SourceTime (Get-ObjectProperty $payload 'updated')
        if ($IsCurrent -and $stamp -lt [int64]$Cache.leaderboardUpdates[[string]$bracket]) {
            Write-Log ('Ignoring older {0}v{0} leaderboard.' -f $bracket)
            continue
        }
        if ($IsCurrent -or $Season -eq $Cache.previousSeason) {
            foreach ($cachedPlayer in $Cache.players.Values) {
                if ($null -ne (Resolve-SupportedRealm ([string]$cachedPlayer.realm))) {
                    if ($IsCurrent) { Mark-CurrentRatingMissing $cachedPlayer $bracket $stamp }
                    else { [void]$cachedPlayer.previous.Remove([string]$bracket) }
                }
            }
            foreach ($sharedPlayer in $Cache.sharedPlayers.Values) {
                $map = $(if ($IsCurrent) { $sharedPlayer.current } else { $sharedPlayer.previous })
                [void]$map.Remove([string]$bracket)
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
                Set-CurrentRating $player $bracket $rating $stamp
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
            $hash = Get-LookupHash -Name $name -Realm $canonicalRealm
            if ($null -ne $hash) {
                if (-not $Cache.sharedPlayers.ContainsKey($hash)) {
                    $Cache.sharedPlayers[$hash] = @{ current = @{}; bestSeen = @{}; previous = @{} }
                    $Cache.sharedCounts[$canonicalRealm]++
                }
                $shared = $Cache.sharedPlayers[$hash]
                if ($IsCurrent) { $shared.current[[string]$bracket] = $rating }
                elseif ($Season -eq $Cache.previousSeason) { $shared.previous[[string]$bracket] = $rating }
                $shared.bestSeen[[string]$bracket] = [Math]::Max($rating, (Get-CachedRating $shared.bestSeen $bracket))
            }
            $matched++
            $realmMatches[$canonicalRealm]++
        }

        if ($IsCurrent -and $stamp -gt 0) {
            $Cache.leaderboardUpdates[[string]$bracket] = $stamp
            $Cache.lastLeaderboardUpdated = [Math]::Max($Cache.lastLeaderboardUpdated, $stamp)
        }
        if ($IsCurrent) {
            $Cache.status.mode = 'partial'
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
        try {
            $probe = Get-Leaderboard -Season $nextSeason -Bracket 2 -Probe
        } catch {
            Write-Log ('Season discovery unavailable; keeping season {0}. {1}' -f $season, $_.Exception.Message)
            break
        }
        if (-not (Test-LeaderboardPayload $probe)) {
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
    $Cache.status.failedProfiles = 0
    $Cache.status.unavailableProfiles = 0

    foreach ($request in $requests) {
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm
        $player.tracking = $true
        Sync-PlayerCurrentFromShared $player $Cache.sharedPlayers $Cache.leaderboardUpdates
        $requestKey = (Normalize-Realm $request.Realm) + '|' + $request.Name.ToLowerInvariant()
        $queuedKeys[$requestKey] = $true
        $player.lastSeen = [Math]::Max([int64]$player.lastSeen, [int64]$request.Stamp)
        $notFoundUntil = [int64]$player.notFoundUntil
        $lastExact = [int64]$player.exactFetchedAt
        if ($notFoundUntil -gt $now) {
            $Cache.status.unavailableProfiles++
            continue
        }
        $interval = Get-ProfileRefreshInterval -Request $request -Now $now
        if ($lastExact -le 0 -or ($now - $lastExact) -ge $interval) {
            $candidates += $request
        }
    }

    Write-Log ('Exact profiles: {0} due now, {1} already cached or temporarily unavailable.' -f `
        $candidates.Count, ($requests.Count - $candidates.Count))

    # Missing peaks go first, then the longest-overdue refresh. A persistent
    # failing profile cannot monopolize the front of the 50-request batch.
    $candidates = @($candidates | Sort-Object -Property `
        @{ Expression = { (Get-PlayerRecord $Cache $_.Name $_.Realm).exactFetchedAt -gt 0 } }, `
        @{ Expression = { [int64]((Get-ObjectProperty (Get-PlayerRecord $Cache $_.Name $_.Realm) 'profileAttemptAt') -as [int64]) } })
    $processed = 0
    $missing = 0
    $transientErrors = 0
    foreach ($request in @($candidates | Select-Object -First $ProfileLimitPerRun)) {
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm
        $player.profileAttemptAt = $now
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
        foreach ($bracket in @(2, 3, 5)) {
            $bracketData = Get-ObjectProperty $seasonData ([string]$bracket)
            $ratingValue = Get-ObjectProperty $bracketData 'rating'
            $rating = 0
            if ([int]::TryParse([string]$ratingValue, [ref]$rating) -and
                $rating -ge 1 -and $rating -le 10000) {
                $stamp = Convert-SourceTime (Get-ObjectProperty $bracketData 'modified')
                Set-CurrentRating $player $bracket $rating $stamp
            } else {
                # A missing bracket is not evidence of a zero rating.
                Mark-CurrentRatingMissing $player $bracket $now
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
    $Cache.status.pendingProfiles = [Math]::Max(0, $candidates.Count - $processed - $missing)
    $Cache.status.failedProfiles = $transientErrors
    $Cache.status.unavailableProfiles += $missing

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

function Format-LuaRatingHistory {
    param([hashtable]$History)
    $parts = @()
    foreach ($bracket in @(2, 3, 5)) {
        $samples = @()
        foreach ($sample in @(Get-ObjectProperty $History ([string]$bracket))) {
            if ($null -ne $sample) {
                $samples += ('{{ at = {0}, rating = {1} }}' -f [int64]$sample.at, [int]$sample.rating)
            }
        }
        if ($samples.Count -gt 0) { $parts += ('[{0}] = {{ {1} }}' -f $bracket, ($samples -join ', ')) }
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
    [void]$builder.AppendLine(('        leaderboardUpdates = {0},' -f (Format-LuaRatingMap $Cache.leaderboardUpdates)))
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
        $hasData = $isExact -or $player.tracking
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
        $exactBrackets = @()
        $isExact = [int64]$player.exactFetchedAt -gt 0
        foreach ($bracket in @(2, 3, 5)) {
            $exactValue = Get-CachedRating -Map $player.exactBest -Bracket $bracket
            $observed = [Math]::Max((Get-CachedRating $player.bestSeen $bracket), (Get-CachedRating $player.current $bracket))
            $value = [Math]::Max($exactValue, $observed)
            if ($isExact -and $exactValue -gt 0 -and $exactValue -ge $observed) { $exactBrackets += ('[{0}] = true' -f $bracket) }
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
        [void]$builder.AppendLine(('            currentUpdated = {0},' -f (Format-LuaRatingMap $player.currentUpdated)))
        [void]$builder.AppendLine(('            currentLastKnown = {0},' -f (Format-LuaRatingMap $player.currentLastKnown)))
        [void]$builder.AppendLine(('            history = {0},' -f (Format-LuaRatingHistory $player.history)))
        [void]$builder.AppendLine(('            tracking = {0},' -f $(if ($player.tracking) { 'true' } else { 'false' })))
        [void]$builder.AppendLine(('            profileAttemptAt = {0},' -f [int64]$player.profileAttemptAt))
        [void]$builder.AppendLine(('            notFoundUntil = {0},' -f [int64]$player.notFoundUntil))
        [void]$builder.AppendLine(('            previous = {0},' -f (Format-LuaRatingMap $player.previous)))
        [void]$builder.AppendLine(('            best = {0},' -f (Format-LuaRatingMap $best)))
        [void]$builder.AppendLine(('            exact = {0},' -f $(if ($isExact) { 'true' } else { 'false' })))
        [void]$builder.AppendLine(('            exactBrackets = {{ {0} }},' -f ($exactBrackets -join ', ')))
        [void]$builder.AppendLine(('            exactFetchedAt = {0},' -f [int64]$player.exactFetchedAt))
        [void]$builder.AppendLine('        },')
    }

    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('}')

    Write-AtomicUtf8 -Path (Join-Path $AddonDirectory 'Data.lua') -Content $builder.ToString()
    return $outputPlayers.Count + $Cache.sharedPlayers.Count
}

function Sync-ReleaseVersion {
    param([hashtable]$Cache)
    $now = Get-UnixTime
    if ($Cache.status.lastVersionCheck -gt 0 -and ($now - $Cache.status.lastVersionCheck) -lt 86400) { return }
    try {
        $release = Get-NsrRelease
        $Cache.status.availableVersion = $release.version
    } catch {
        Write-Log 'Version check unavailable; rating updates will continue.'
    }
    $Cache.status.lastVersionCheck = $now
}

function Write-SyncStatus {
    param([hashtable]$Cache, [string]$AddonDirectory)
    $lines = @('-- Download status; read by WoW at login/reload.', 'NightslayerRatingSyncStatus = {')
    $lines += ('    installedVersion = "{0}",' -f $UpdaterVersion)
    foreach ($key in @('lastAttempt', 'lastSuccess', 'pendingProfiles', 'failedProfiles', 'unavailableProfiles')) {
        $lines += ('    {0} = {1},' -f $key, [Math]::Max(0, [int64]$Cache.status[$key]))
    }
    $mode = [string]$Cache.status.mode
    if ($mode -notin @('shared', 'direct', 'partial', 'cached', 'failed', 'bundled', 'retained')) { $mode = 'failed' }
    $lines += ('    mode = "{0}",' -f $mode)
    $version = [string]$Cache.status.availableVersion
    if ($version -match '^\d{1,3}\.\d{1,3}\.\d{1,3}$') { $lines += ('    availableVersion = "{0}",' -f $version) }
    $lines += '}'
    Write-AtomicUtf8 -Path (Join-Path $AddonDirectory 'SyncStatus.lua') -Content ($lines -join "`n")
}

function Update-RatingData {
    param([hashtable]$Cache, [string]$GamePath, [string]$AddonDirectory)
    $Cache.status.lastAttempt = Get-UnixTime
    $Cache.status.mode = 'cached'
    try {
        Initialize-BundledSnapshot -Cache $Cache
        $sharedWorked = Sync-SharedSnapshot -Cache $Cache
        if (-not $sharedWorked) {
            $currentSeason = Find-CurrentSeason -Cache $Cache
            Set-CacheSeason -Cache $Cache -Season $currentSeason
            if (Sync-LeaderboardSeason -Cache $Cache -Season $currentSeason -IsCurrent $true) {
                $Cache.status.mode = 'direct'
                $Cache.status.lastSuccess = Get-UnixTime
            }
            for ($season = 1; $season -lt $currentSeason; $season++) {
                if (@($Cache.syncedSeasons) -contains $season) { continue }
                if (Sync-LeaderboardSeason -Cache $Cache -Season $season -IsCurrent $false) {
                    $Cache.syncedSeasons = @($Cache.syncedSeasons) + $season
                }
            }
        }
        Sync-RatingCutoffs -Cache $Cache
        $profiles = Sync-QueuedProfiles -Cache $Cache -GamePath $GamePath
        Sync-ReleaseVersion -Cache $Cache
        Save-Cache -Cache $Cache
        $hasRatings = $Cache.sharedPlayers.Count -gt 0
        foreach ($player in $Cache.players.Values) {
            if ($player.current.Count -gt 0 -or $player.bestSeen.Count -gt 0 -or $player.exactBest.Count -gt 0) {
                $hasRatings = $true
                break
            }
        }
        if ($hasRatings) {
            $playersWritten = Write-LuaData -Cache $Cache -AddonDirectory $AddonDirectory
            Write-Log ('Sync complete ({0}): {1} cached players written, {2} exact profile lookups.' -f $Cache.status.mode, $playersWritten, $profiles)
        } else {
            Write-Log 'No rating data was available. Existing addon data was left unchanged; the next scheduled run will retry.'
        }
    } catch {
        $Cache.status.mode = 'failed'
        throw
    } finally {
        try { Save-Cache -Cache $Cache } catch { Write-Log ('Cache save failed: ' + $_.Exception.Message) }
        try { Write-SyncStatus -Cache $Cache -AddonDirectory $AddonDirectory } catch { Write-Log ('Status write failed: ' + $_.Exception.Message) }
    }
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
    Update-RatingData -Cache $cache -GamePath $WowPath -AddonDirectory $AddonPath
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
