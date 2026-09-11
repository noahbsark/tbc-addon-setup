Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$UpdaterDirectory = Join-Path $PSScriptRoot '../source/Updater'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $UpdaterDirectory 'NightslayerRatingUpdater.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $node.Extent.Text }
}
$DefaultRealm = 'Nightslayer'
$SupportedRealms = @{ nightslayer = 'Nightslayer'; dreamscythe = 'Dreamscythe' }
$Region = 'US'
$SharedSnapshotMaxPlayers = 100000
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$UpdaterVersion = '1.4.0'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-history-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$CachePath = Join-Path $directory 'cache.json'
function Write-Log { param($Message) }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
try {
    $now = Get-UnixTime
    $cache = New-Cache
    $player = Get-PlayerRecord $cache 'Example' 'Nightslayer'
    $player.tracking = $true
    $player.exactFetchedAt = $now
    $player.exactBest['2'] = 2500
    Set-CurrentRating $player 2 2000 ($now - 6 * 86400)
    Set-CurrentRating $player 3 1900 ($now - 86400)
    $hash = Get-LookupHash 'Other' 'Nightslayer'
    $snapshot = @{
        version = 6; season = 3; previousSeason = 2; region = 'US'; keyAlgorithm = 'nsr-h4-v1'
        generated = $now; leaderboardUpdated = $now
        leaderboardUpdates = @{ '2' = $now; '3' = $now; '5' = $now }
        players = @{ $hash = @{ current = @{ '2' = 2100 }; bestSeen = @{ '2' = 2100 } } }
        counts = @{ Nightslayer = 1; Dreamscythe = 0 }
    }
    Assert (Import-SharedSnapshot $cache ($snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json)) 'Import failed'
    Assert ($player.current['2'] -eq 2000) 'Unlisted exact rating disappeared'
    Assert ($player.currentLastKnown['2'] -eq 1) 'Unlisted rating was presented as current'
    Assert ($player.currentUpdated['2'] -eq $now - 6 * 86400) 'Import falsely refreshed player source age'
    Assert ($player.history['2'].Count -eq 1) 'Missing row invented a history observation'

    $selfHash = Get-LookupHash 'Example' 'Nightslayer'
    $snapshot.players[$selfHash] = @{ current = @{ '2' = 2084 }; bestSeen = @{ '2' = 2500 } }
    [void](Import-SharedSnapshot $cache ($snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json))
    Assert ($player.current['2'] -eq 2084 -and -not $player.currentLastKnown.ContainsKey('2')) 'Returning player did not recover'
    Assert ($player.current['3'] -eq 1900 -and $player.currentLastKnown['3'] -eq 1) 'Missing bracket erased another known rating'
    Assert ($player.history['2'].Count -eq 2) 'Observed movement was not recorded'
    [void](Import-SharedSnapshot $cache ($snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json))
    Assert ($player.history['2'].Count -eq 2) 'Identical hourly snapshot grew history'
    Set-CurrentRating $player 2 1000 ($now - 86400)
    Set-CurrentRating $player 2 1000 0
    Assert ($player.current['2'] -eq 2084) 'Older/undated source overwrote a newer rating'

    # Direct fallback has the same retention semantics, and does not mark a
    # failed bracket as unlisted or freshly observed.
    $player.currentLastKnown = @{}
    function Get-Leaderboard {
        param($Season, $Bracket)
        if ($Bracket -eq 3) { throw 'HTTP 500' }
        return @{ updated = ((Get-UnixTime) * 1000); data = @(@{ name = 'Other'; server = 'Nightslayer'; rating = 2100 }) }
    }
    Assert (-not (Sync-LeaderboardSeason $cache 3 $true)) 'Partial fallback reported complete'
    Assert ($player.current['2'] -eq 2084 -and $player.currentLastKnown['2'] -eq 1) 'Fallback lost an unlisted rating'
    Assert (-not $player.currentLastKnown.ContainsKey('3')) 'Outage was mistaken for confirmed absence'

    Save-Cache $cache
    $loaded = Read-Cache
    $copy = Get-PlayerRecord $loaded 'Example' 'Nightslayer'
    Assert ($copy.currentUpdated['2'] -eq $now -and $copy.currentLastKnown['2'] -eq 1) 'Freshness did not survive disk round trip'
    Assert ($copy.history['2'].Count -eq 2 -and $copy.tracking) 'History or tracking did not survive disk round trip'
    [void](Write-LuaData $loaded $directory)
    $lua = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($lua.Contains('currentLastKnown = { [2] = 1 }')) 'Lua lost the last-known label'
    Assert ($lua.Contains('rating = 2084')) 'Lua lost history samples'

    # End-of-day samples are bounded, even after months of updates. Undated
    # legacy rows never receive synthetic historical dates.
    $copy.history = @{}
    $copy.currentUpdated = @{}
    foreach ($day in 60..1) { Set-CurrentRating $copy 2 (2000 + $day) ($now - $day * 86400) }
    Assert ($copy.history['2'].Count -le 31) 'History retention exceeded its bound'
    Assert ($copy.history['2'][0].at -ge $now - 31 * 86400) 'Expired history survived'
    $twin = Get-PlayerRecord $loaded 'Example' 'Dreamscythe'
    Assert ($twin.history.Count -eq 0) 'Same-name realm histories were mixed'
    Set-CacheSeason $loaded 4
    Assert ($copy.current.Count -eq 0 -and $copy.history.Count -eq 0 -and $copy.currentUpdated.Count -eq 0) 'Season rollover retained old current data/history'
    Assert ($copy.exactBest['2'] -eq 2500) 'Season rollover lost the lifetime peak'
    Write-Output 'Last-known retention, per-bracket freshness, history, disk export and rollover tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
