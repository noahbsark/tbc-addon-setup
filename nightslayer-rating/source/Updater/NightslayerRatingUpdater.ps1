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
$ProfileLimitPerRun = 20
$ProfileRefreshSeconds = 86400
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

function New-Cache {
    return @{
        version = 4
        currentSeason = 3
        cutoffSeason = 3
        cutoffs = @{
            '2' = @{ rank = 2020; gladiator = 1876; duelist = 1781; rival = 1657; challenger = 1503 }
            '3' = @{ rank = 1902; gladiator = 1754; duelist = 1714; rival = 1636; challenger = 1505 }
            '5' = @{ rank = 2180; gladiator = 1987; duelist = 1842; rival = 1683; challenger = 1510 }
        }
        syncedSeasons = @()
        lastLeaderboardUpdated = 0
        sharedGenerated = 0
        sharedCounts = @{ Nightslayer = 0; Dreamscythe = 0 }
        sharedPlayers = @{}
        players = @{}
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
            $cache.currentSeason = [int]$season
        }

        $cutoffSeason = Get-ObjectProperty $raw 'cutoffSeason'
        if ($null -ne $cutoffSeason) {
            $cache.cutoffSeason = [int]$cutoffSeason
        }

        $cutoffs = Get-ObjectProperty $raw 'cutoffs'
        if ($null -ne $cutoffs) {
            foreach ($bracket in @(2, 3, 5)) {
                $bracketCutoffs = Convert-RatingMap (Get-ObjectProperty $cutoffs ([string]$bracket))
                if ($bracketCutoffs.Count -gt 0) {
                    $cache.cutoffs[[string]$bracket] = $bracketCutoffs
                }
            }
        }

        $lastUpdated = Get-ObjectProperty $raw 'lastLeaderboardUpdated'
        if ($null -ne $lastUpdated) {
            $cache.lastLeaderboardUpdated = [int64]$lastUpdated
        }

        $rawVersion = [int]((Get-ObjectProperty $raw 'version') -as [int])
        $synced = Get-ObjectProperty $raw 'syncedSeasons'
        if ($rawVersion -ge 3 -and $null -ne $synced) {
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
                'User-Agent' = 'NightslayerRating/1.1.0 (local WoW addon updater; low-rate cache)'
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
            if ($AllowServerError -and $statusCode -eq 500) {
                return $null
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
        $client = $null
        $memory = $null
        $gzip = $null
        $reader = $null
        try {
            $client = New-Object Net.WebClient
            $client.Headers.Add('Accept', 'application/gzip, application/octet-stream')
            $client.Headers.Add('User-Agent', 'NightslayerRating/1.1.0 (shared snapshot client)')
            $uri = $SharedSnapshotUrl + '?t=' + (Get-UnixTime)
            [byte[]]$bytes = $client.DownloadData($uri)
            if ($bytes.Length -le 0 -or $bytes.Length -gt $SharedSnapshotMaxCompressedBytes) {
                throw ('Shared snapshot had an invalid compressed size: ' + $bytes.Length)
            }

            $memory = New-Object IO.MemoryStream(,$bytes)
            $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Decompress)
            $reader = New-Object IO.StreamReader($gzip, $Utf8NoBom)
            $json = $reader.ReadToEnd()
            if ([string]::IsNullOrWhiteSpace($json) -or $json.Length -gt $SharedSnapshotMaxJsonChars) {
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
            if ($null -ne $client) { $client.Dispose() }
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
    if ($version -lt 4 -or $keyAlgorithm -ne 'nsr-h4-v1' -or $season -le 0 -or
        $region -ne $Region -or $playerProperties.Count -le 0) {
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
        $current = Convert-RatingMap (Get-ObjectProperty $value 'current')
        $bestSeen = Convert-RatingMap (Get-ObjectProperty $value 'bestSeen')
        if ($current.Count -eq 0 -and $bestSeen.Count -eq 0) {
            continue
        }
        $newSharedPlayers[$hash] = @{ current = $current; bestSeen = $bestSeen }
        $merged++
    }

    # Version 2/3 caches stored thousands of bulk names locally. Keep only exact
    # profiles now that bulk ratings live in the pseudonymous shared table.
    foreach ($key in @($Cache.players.Keys)) {
        if ([int64]$Cache.players[$key].exactFetchedAt -le 0) {
            [void]$Cache.players.Remove($key)
        }
    }

    # Preserve private exact highs while refreshing their current values from the
    # newer shared row when that character is present on a leaderboard.
    foreach ($player in @($Cache.players.Values)) {
        $hash = Get-LookupHash -Name ([string]$player.name) -Realm ([string]$player.realm)
        if ($null -eq $hash -or -not $newSharedPlayers.ContainsKey($hash)) {
            continue
        }
        $sharedCurrent = $newSharedPlayers[$hash].current
        $player.current = @{}
        foreach ($bracket in @(2, 3, 5)) {
            $key = [string]$bracket
            if ($sharedCurrent.ContainsKey($key)) {
                $player.current[$key] = [int]$sharedCurrent[$key]
            }
        }
    }

    $snapshotCutoffs = Get-ObjectProperty $snapshot 'cutoffs'
    $newCutoffs = @{}
    foreach ($bracket in @(2, 3, 5)) {
        $map = Convert-RatingMap (Get-ObjectProperty $snapshotCutoffs ([string]$bracket))
        if ($map.Count -ge 5) {
            $newCutoffs[[string]$bracket] = $map
        }
    }
    if ($newCutoffs.Count -eq 3) {
        $Cache.cutoffs = $newCutoffs
        $Cache.cutoffSeason = [int]((Get-ObjectProperty $snapshot 'cutoffSeason') -as [int])
    }

    $Cache.currentSeason = $season
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

function Get-CutoffPayload {
    param(
        [int]$Season,
        [int]$Bracket
    )

    return Invoke-IronForgeJson -Path ('anniversary/cutoffs/{0}/{1}/{2}/' -f $Season, $Region, $Bracket) -AllowNotFound -AllowServerError
}

function Convert-CutoffRows {
    param($Rows)

    $map = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or @($row).Count -lt 2) {
            continue
        }

        $rating = 0
        if (-not [int]::TryParse([string]$row[0], [ref]$rating) -or $rating -le 0) {
            continue
        }

        $title = [string]$row[1]
        $tier = $null
        if ($title -eq 'Gladiator') {
            $tier = 'gladiator'
        } elseif ($title -eq 'Duelist') {
            $tier = 'duelist'
        } elseif ($title -eq 'Rival') {
            $tier = 'rival'
        } elseif ($title -eq 'Challenger') {
            $tier = 'challenger'
        } elseif ($title -match 'Gladiator$' -or $title -eq 'Rank One') {
            $tier = 'rank'
        }

        if ($null -ne $tier) {
            $map[$tier] = $rating
        }
    }

    return $map
}

function Sync-CurrentCutoffs {
    param(
        [hashtable]$Cache,
        [int]$Season
    )

    $newCutoffs = @{}
    $complete = $true
    foreach ($bracket in @(2, 3, 5)) {
        $payload = Get-CutoffPayload -Season $Season -Bracket $bracket
        $rows = $null
        if ($null -ne $payload) {
            $cutoffProperty = $payload.PSObject.Properties['cutoff']
            if ($null -ne $cutoffProperty) {
                $rows = $cutoffProperty.Value
            }
        }
        $map = Convert-CutoffRows -Rows $rows
        if ($map.Count -lt 5) {
            $complete = $false
            Write-Log ('Season {0} {1}v{1}: IronForge cutoff data unavailable' -f $Season, $bracket)
        } else {
            $newCutoffs[[string]$bracket] = $map
            Write-Log ('Season {0} {1}v{1}: refreshed rating color cutoffs' -f $Season, $bracket)
        }
        Start-Sleep -Milliseconds 350
    }

    if ($complete) {
        $Cache.cutoffs = $newCutoffs
        $Cache.cutoffSeason = $Season
    } elseif ([int]$Cache.cutoffSeason -ne $Season) {
        $Cache.cutoffs = @{}
        $Cache.cutoffSeason = 0
    }

    return $complete
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

        if ($IsCurrent) {
            foreach ($cachedPlayer in $Cache.players.Values) {
                if ($null -ne (Resolve-SupportedRealm ([string]$cachedPlayer.realm))) {
                    [void]$cachedPlayer.current.Remove([string]$bracket)
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
                -not [int]::TryParse([string]$ratingValue, [ref]$rating)) {
                continue
            }

            $player = Get-PlayerRecord -Cache $Cache -Name $name -Realm $canonicalRealm
            $player.name = $name
            $player.lastSeen = $now
            if ($IsCurrent) {
                $player.current[[string]$bracket] = $rating
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
    $accountRoot = Join-Path $GamePath 'WTF\Account'
    if (Test-Path -LiteralPath $accountRoot) {
        foreach ($accountDirectory in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
            $savedVariables = Join-Path $accountDirectory.FullName 'SavedVariables\NightslayerRating.lua'
            if (-not (Test-Path -LiteralPath $savedVariables)) {
                continue
            }

            try {
                $text = Get-Content -LiteralPath $savedVariables -Raw -Encoding UTF8
                $pattern = '\["(?<realm>Nightslayer|Dreamscythe)\|(?<name>[^"\\]+)"\]\s*=\s*(?<stamp>\d+)'
                foreach ($match in [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    $name = $match.Groups['name'].Value
                    $realm = Resolve-SupportedRealm $match.Groups['realm'].Value
                    $stamp = [int64]$match.Groups['stamp'].Value
                    if ($null -eq $realm) {
                        continue
                    }
                    $key = (Normalize-Realm $realm) + '|' + $name.ToLowerInvariant()
                    if (-not $requests.ContainsKey($key) -or $stamp -gt $requests[$key].Stamp) {
                        $requests[$key] = [pscustomobject]@{ Name = $name; Realm = $realm; Stamp = $stamp }
                    }
                }
            } catch {
                Write-Log ('Could not inspect ' + $savedVariables)
            }
        }
    }

    return @($requests.Values | Sort-Object Stamp -Descending)
}

function Sync-QueuedProfiles {
    param(
        [hashtable]$Cache,
        [string]$GamePath
    )

    $now = Get-UnixTime
    $candidates = @()

    foreach ($request in @(Get-QueuedRequests -GamePath $GamePath -Cache $Cache)) {
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm
        $notFoundUntil = [int64]$player.notFoundUntil
        $lastExact = [int64]$player.exactFetchedAt
        if ($notFoundUntil -gt $now) {
            continue
        }
        if ($lastExact -le 0 -or ($now - $lastExact) -ge $ProfileRefreshSeconds) {
            $candidates += $request
        }
    }

    $processed = 0
    foreach ($request in @($candidates | Select-Object -First $ProfileLimitPerRun)) {
        $encodedRealm = [Uri]::EscapeDataString([string]$request.Realm)
        $encodedName = [Uri]::EscapeDataString([string]$request.Name)
        $profile = Invoke-IronForgeJson -Path ('anniversary/player/{0}/{1}' -f $encodedRealm, $encodedName) -AllowNotFound
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name -Realm $request.Realm

        if ($null -eq $profile) {
            $player.notFoundUntil = $now + 604800
            Write-Log ('No IronForge profile found for ' + $request.Name + '-' + $request.Realm)
            Start-Sleep -Milliseconds 750
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
            if ([int]::TryParse([string]$bestValue, [ref]$best)) {
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
            if ([int]::TryParse([string]$ratingValue, [ref]$rating) -and $rating -gt 0) {
                $player.current[[string]$bracket] = $rating
            }
        }

        $player.exactFetchedAt = $now
        $player.notFoundUntil = 0
        $processed++
        Write-Log ('Fetched exact lifetime highs for ' + $player.name + '-' + $player.realm)
        Start-Sleep -Milliseconds 1500
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

function Format-LuaCutoffMap {
    param([hashtable]$Map)

    $parts = @()
    foreach ($tier in @('rank', 'gladiator', 'duelist', 'rival', 'challenger')) {
        if ($null -ne $Map -and $Map.ContainsKey($tier)) {
            $rating = [int]$Map[$tier]
            if ($rating -gt 0) {
                $parts += ('{0} = {1}' -f $tier, $rating)
            }
        }
    }
    return '{ ' + ($parts -join ', ') + ' }'
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
    [void]$builder.AppendLine(('        generated = {0},' -f $now))
    [void]$builder.AppendLine(('        leaderboardUpdated = {0},' -f [int64]$Cache.lastLeaderboardUpdated))
    [void]$builder.AppendLine(('        sharedGenerated = {0},' -f [int64]$Cache.sharedGenerated))
    [void]$builder.AppendLine('        counts = {')
    [void]$builder.AppendLine(('            Nightslayer = {0},' -f [int]$Cache.sharedCounts.Nightslayer))
    [void]$builder.AppendLine(('            Dreamscythe = {0},' -f [int]$Cache.sharedCounts.Dreamscythe))
    [void]$builder.AppendLine('        },')
    [void]$builder.AppendLine('        source = "ironforge.pro via shared snapshot and local lookups",')
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine(('    cutoffSeason = {0},' -f [int]$Cache.cutoffSeason))
    [void]$builder.AppendLine('    cutoffs = {')
    foreach ($bracket in @(2, 3, 5)) {
        $bracketCutoffs = @{}
        if ($Cache.cutoffs.ContainsKey([string]$bracket)) {
            $bracketCutoffs = $Cache.cutoffs[[string]$bracket]
        }
        [void]$builder.AppendLine(('        [{0}] = {1},' -f $bracket, (Format-LuaCutoffMap $bracketCutoffs)))
    }
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    sharedPlayers = {')
    foreach ($hash in @($Cache.sharedPlayers.Keys | Sort-Object)) {
        $sharedPlayer = $Cache.sharedPlayers[$hash]
        [void]$builder.AppendLine(('        ["{0}"] = {{' -f $hash))
        [void]$builder.AppendLine(('            current = {0},' -f (Format-LuaRatingMap $sharedPlayer.current)))
        [void]$builder.AppendLine(('            best = {0},' -f (Format-LuaRatingMap $sharedPlayer.bestSeen)))
        [void]$builder.AppendLine('            exact = false,')
        [void]$builder.AppendLine('        },')
    }
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    players = {')

    $outputPlayers = @()
    foreach ($player in $Cache.players.Values) {
        $isExact = [int64]$player.exactFetchedAt -gt 0
        $hasData = $isExact
        foreach ($bracket in @(2, 3, 5)) {
            if ((Get-CachedRating -Map $player.current -Bracket $bracket) -gt 0 -or
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
        $cache.sharedPlayers = @{}
        $cache.sharedCounts = @{ Nightslayer = 0; Dreamscythe = 0 }
        $cache.sharedGenerated = 0
        $currentSeason = Find-CurrentSeason -Cache $cache
        $cache.currentSeason = $currentSeason

        [void](Sync-CurrentCutoffs -Cache $cache -Season $currentSeason)
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
