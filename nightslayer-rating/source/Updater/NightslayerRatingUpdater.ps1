[CmdletBinding()]
param(
    [string]$WowPath,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Realm = 'Nightslayer'
$Region = 'US'
$ApiBase = 'https://ironforge.pro/api'
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
        version = 1
        currentSeason = 3
        syncedSeasons = @()
        lastLeaderboardUpdated = 0
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

        $lastUpdated = Get-ObjectProperty $raw 'lastLeaderboardUpdated'
        if ($null -ne $lastUpdated) {
            $cache.lastLeaderboardUpdated = [int64]$lastUpdated
        }

        $synced = Get-ObjectProperty $raw 'syncedSeasons'
        if ($null -ne $synced) {
            $cache.syncedSeasons = @($synced | ForEach-Object { [int]$_ })
        }

        $players = Get-ObjectProperty $raw 'players'
        if ($null -ne $players) {
            foreach ($property in $players.PSObject.Properties) {
                $value = $property.Value
                $cache.players[[string]$property.Name] = @{
                    name = [string](Get-ObjectProperty $value 'name')
                    current = Convert-RatingMap (Get-ObjectProperty $value 'current')
                    bestSeen = Convert-RatingMap (Get-ObjectProperty $value 'bestSeen')
                    exactBest = Convert-RatingMap (Get-ObjectProperty $value 'exactBest')
                    exactFetchedAt = [int64]((Get-ObjectProperty $value 'exactFetchedAt') -as [int64])
                    lastSeen = [int64]((Get-ObjectProperty $value 'lastSeen') -as [int64])
                    notFoundUntil = [int64]((Get-ObjectProperty $value 'notFoundUntil') -as [int64])
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

function Get-PlayerRecord {
    param(
        [hashtable]$Cache,
        [string]$Name
    )

    $key = $Name.ToLowerInvariant()
    if (-not $Cache.players.ContainsKey($key)) {
        $Cache.players[$key] = @{
            name = $Name
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
                'User-Agent' = 'NightslayerRating/1.0.1 (local WoW addon updater; low-rate cache)'
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

        if ($IsCurrent) {
            foreach ($cachedPlayer in $Cache.players.Values) {
                [void]$cachedPlayer.current.Remove([string]$bracket)
            }
        }

        $matched = 0
        foreach ($row in $rows) {
            $server = [string](Get-ObjectProperty $row 'server')
            if ((Normalize-Realm $server) -ne (Normalize-Realm $Realm)) {
                continue
            }

            $name = [string](Get-ObjectProperty $row 'name')
            $ratingValue = Get-ObjectProperty $row 'rating'
            $rating = 0
            if ([string]::IsNullOrWhiteSpace($name) -or
                -not [int]::TryParse([string]$ratingValue, [ref]$rating)) {
                continue
            }

            $player = Get-PlayerRecord -Cache $Cache -Name $name
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
        }

        $payloadUpdated = Get-ObjectProperty $payload 'updated'
        if ($IsCurrent -and $null -ne $payloadUpdated) {
            $milliseconds = [double]$payloadUpdated
            $Cache.lastLeaderboardUpdated = [int64][Math]::Floor($milliseconds / 1000)
        }

        Write-Log ('Season {0} {1}v{1}: cached {2} Nightslayer players' -f $Season, $bracket, $matched)
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
                $pattern = '\["Nightslayer\|(?<name>[^"\\]+)"\]\s*=\s*(?<stamp>\d+)'
                foreach ($match in [regex]::Matches($text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    $name = $match.Groups['name'].Value
                    $stamp = [int64]$match.Groups['stamp'].Value
                    $key = $name.ToLowerInvariant()
                    if (-not $requests.ContainsKey($key) -or $stamp -gt $requests[$key].Stamp) {
                        $requests[$key] = [pscustomobject]@{ Name = $name; Stamp = $stamp }
                    }
                }
            } catch {
                Write-Log ('Could not inspect ' + $savedVariables)
            }
        }
    }

    $bootstrapNames = @(
        'Reefey',
        ('T' + [char]0x00F3 + 'ti'),
        'Getblinded',
        'Polar',
        ('Ko' + [char]0x00DF + 'e'),
        'Gundolff',
        'Coachcream',
        'Totemholic',
        ('B' + [char]0x00F4 + 'ned')
    )
    foreach ($name in $bootstrapNames) {
        $key = $name.ToLowerInvariant()
        $player = Get-PlayerRecord -Cache $Cache -Name $name
        if ([int64]$player.exactFetchedAt -le 0 -and -not $requests.ContainsKey($key)) {
            $requests[$key] = [pscustomobject]@{ Name = $name; Stamp = 4000000000 }
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
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name
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
        $encodedRealm = [Uri]::EscapeDataString($Realm)
        $encodedName = [Uri]::EscapeDataString([string]$request.Name)
        $profile = Invoke-IronForgeJson -Path ('anniversary/player/{0}/{1}' -f $encodedRealm, $encodedName) -AllowNotFound
        $player = Get-PlayerRecord -Cache $Cache -Name $request.Name

        if ($null -eq $profile) {
            $player.notFoundUntil = $now + 604800
            Write-Log ('No IronForge profile found for ' + $request.Name)
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
        Write-Log ('Fetched exact lifetime highs for ' + $player.name)
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
    [void]$builder.AppendLine(('        realm = "{0}",' -f (Escape-LuaString $Realm)))
    [void]$builder.AppendLine(('        region = "{0}",' -f (Escape-LuaString $Region)))
    [void]$builder.AppendLine(('        season = {0},' -f [int]$Cache.currentSeason))
    [void]$builder.AppendLine(('        generated = {0},' -f $now))
    [void]$builder.AppendLine(('        leaderboardUpdated = {0},' -f [int64]$Cache.lastLeaderboardUpdated))
    [void]$builder.AppendLine('        source = "ironforge.pro",')
    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('    players = {')

    $outputPlayers = @()
    foreach ($player in $Cache.players.Values) {
        $isExact = [int64]$player.exactFetchedAt -gt 0
        $hasData = $isExact
        foreach ($bracket in @(2, 3, 5)) {
            if ((Get-CachedRating -Map $player.current -Bracket $bracket) -gt 0 -or
                ($isExact -and (Get-CachedRating -Map $player.exactBest -Bracket $bracket) -gt 0)) {
                $hasData = $true
                break
            }
        }

        if ($hasData -and -not [string]::IsNullOrWhiteSpace([string]$player.name)) {
            $outputPlayers += $player
        }
    }

    foreach ($player in @($outputPlayers | Sort-Object { $_.name })) {
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
        [void]$builder.AppendLine(('        ["{0}"] = {{' -f $escapedName))
        [void]$builder.AppendLine(('            name = "{0}",' -f $escapedName))
        [void]$builder.AppendLine(('            current = {0},' -f (Format-LuaRatingMap $player.current)))
        [void]$builder.AppendLine(('            best = {0},' -f (Format-LuaRatingMap $best)))
        [void]$builder.AppendLine(('            exact = {0},' -f $(if ($isExact) { 'true' } else { 'false' })))
        [void]$builder.AppendLine('        },')
    }

    [void]$builder.AppendLine('    },')
    [void]$builder.AppendLine('}')

    Write-AtomicUtf8 -Path (Join-Path $AddonDirectory 'Data.lua') -Content $builder.ToString()
    return $outputPlayers.Count
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
    Write-Log 'Starting IronForge rating sync.'

    $cache = Read-Cache
    $currentSeason = Find-CurrentSeason -Cache $cache
    $cache.currentSeason = $currentSeason

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
