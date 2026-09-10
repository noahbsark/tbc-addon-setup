Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$UpdaterDirectory = Join-Path $PSScriptRoot '../source/Updater'
$updater = Join-Path $UpdaterDirectory 'NightslayerRatingUpdater.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $updater), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load function definitions only; never run the installer, scheduler, or network.
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $node.Extent.Text
    }
}
$DefaultRealm = 'Nightslayer'
$SupportedRealms = @{ nightslayer = 'Nightslayer'; dreamscythe = 'Dreamscythe' }
$Region = 'US'
$SharedSnapshotMaxPlayers = 100000
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$CachePath = Join-Path $directory 'cache.json'
$script:logs = @()
function Write-Log { param([string]$Message) $script:logs += $Message }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }

try {
    $cache = New-Cache
    Assert (($cache.cutoffs['2']['2'].thresholds -join ',') -eq '2803,2481,1944,1629,1458') 'Frozen 2v2 differs'
    Assert (($cache.cutoffs['2']['3'].thresholds -join ',') -eq '2493,2269,1913,1662,1482') 'Frozen 3v3 differs'
    Assert (($cache.cutoffs['2']['5'].thresholds -join ',') -eq '2340,2166,1854,1640,1466') 'Frozen 5v5 differs'
    $script:calls = 0
    $script:fail = $false
    function Invoke-IronForgeJson {
        param($Path)
        $script:calls++
        if ($script:fail) { return @{ cutoff = @() } }
        return @{
            updated = [DateTimeOffset]::UtcNow.ToString('r')
            cutoff = @(@(2199, 'Vengeful Gladiator', ''), @(2058, 'Gladiator', ''),
                @(1863, 'Duelist', ''), @(1676, 'Rival', ''), @(1498, 'Challenger', ''))
        }
    }
    Sync-RatingCutoffs $cache
    Assert ($script:calls -eq 3) 'Should request only current-season brackets'
    Assert ($cache.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Live endpoint parsing failed'
    Sync-RatingCutoffs $cache
    Assert ($script:calls -eq 3) 'Fresh cutoffs should not be fetched again'
    $cache.cutoffs['3']['2'].checked = 0
    $script:fail = $true
    Sync-RatingCutoffs $cache
    Assert ($cache.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Failure overwrote valid cutoffs'
    Assert ($script:logs[-1] -like '*retaining last valid*') 'Failure not reported'
    $bad = @{ updated = Get-UnixTime; thresholds = @(100,200,300,400,500) }
    Assert ($null -eq (Convert-CutoffEntry $bad)) 'Misordered cutoffs accepted'
    $bad.thresholds = @(2400, 2100, 1800, 1500, '-')
    Assert ($null -eq (Convert-CutoffEntry $bad)) 'Missing cutoff accepted'
    $valid = @{ updated = Get-UnixTime; thresholds = @(3000,2500,2000,1800,1500) }
    Merge-Cutoffs $cache @{ '2' = @{ '2' = $valid } }
    Assert ($cache.cutoffs['2']['2'].thresholds[0] -eq 2803) 'Shared data changed frozen S2'
    $valid.updated = 1
    Merge-Cutoffs $cache @{ '3' = @{ '2' = $valid } }
    Assert ($cache.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Older snapshot replaced newer cutoffs'

    $player = Get-PlayerRecord $cache 'Twinname' 'Nightslayer'
    $player.exactBest['2'] = 2900
    $player.exactFetchedAt = Get-UnixTime
    $cache.version = 5
    $cache.syncedSeasons = @(1, 2)
    Save-Cache $cache
    $cache = Read-Cache
    Assert ($cache.version -eq 6) 'Cache version migration failed'
    Assert ($cache.syncedSeasons.Count -eq 0) 'Migration must fetch historical season data'
    $player = Get-PlayerRecord $cache 'Twinname' 'Nightslayer'
    Assert ($player.exactBest['2'] -eq 2900) 'Migration lost exact record'
    Assert ($player.previous.Count -eq 0) 'Migration relabeled lifetime record as S2'

    $hash = Get-LookupHash 'Twinname' 'Nightslayer'
    $script:snapshot = @{
        version = 6; season = 3; previousSeason = 2; region = 'US'; keyAlgorithm = 'nsr-h4-v1'
        generated = Get-UnixTime; leaderboardUpdated = Get-UnixTime
        counts = @{ Nightslayer = 1; Dreamscythe = 0 }
        cutoffs = $cache.cutoffs
        players = @{ $hash = @{ current = @{ '2' = 2058 }; bestSeen = @{ '2' = 2900 }; previous = @{ '2' = 2481 } } }
    }
    function Get-SharedSnapshot { return ($script:snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }
    Assert (Sync-SharedSnapshot $cache) 'Shared snapshot failed'
    Assert ($player.current['2'] -eq 2058) 'Exact row did not refresh current rating'
    Assert ($player.previous['2'] -eq 2481) 'Exact row did not receive S2 rating'
    Assert ($player.exactBest['2'] -eq 2900) 'Exact lifetime record was changed'
    [void](Write-LuaData $cache $directory)
    $lua = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($lua.Contains('previousSeason = 2')) 'Previous season metadata missing'
    Assert ($lua.Contains('2058, 0, 0, 2900, 0, 0, 2481, 0, 0')) 'Nine-value shared row missing'
    Assert ($lua.Contains('previous = { [2] = 2481 }')) 'Named previous rating missing'
    Assert ($lua.Contains('2803, 2481, 1944, 1629, 1458')) 'Frozen Lua cutoffs missing'
    Save-Cache $cache
    $roundtrip = Read-Cache
    Assert ($roundtrip.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Cutoffs lost on disk'
    Assert ($roundtrip.sharedPlayers[$hash].previous['2'] -eq 2481) 'Previous ratings lost on disk'

    $script:snapshot.season = 4
    $script:snapshot.previousSeason = 3
    $script:snapshot.players[$hash].previous['2'] = 2058
    Assert (Sync-SharedSnapshot $cache) 'Rollover failed'
    Assert ($cache.previousSeason -eq 3 -and $player.previous['2'] -eq 2058) 'S4 reused S2 history'
    Assert ($cache.cutoffs['2']['2'].thresholds[0] -eq 2803) 'Rollover changed S2 archive'
    $script:snapshot.season = 3
    $script:snapshot.previousSeason = 2
    Assert (-not (Sync-SharedSnapshot $cache)) 'Stale snapshot rolled season backward'

    # The direct leaderboard fallback must also populate the previous season.
    Set-CacheSeason $cache 3
    function Get-Leaderboard {
        param($Season, $Bracket)
        return @{ updated = 1789060881000; data = @(@{ server = 'Nightslayer'; name = 'Twinname'; rating = 2400 + $Bracket }) }
    }
    Assert (Sync-LeaderboardSeason $cache 2 $false) 'Archive fallback failed'
    Assert ($player.previous['3'] -eq 2403) 'Archive fallback did not populate previous rating'
    Assert ($player.current.Count -eq 0) 'Archive fallback overwrote current season'
    Write-Output 'Updater cutoff refresh, failure retention, cache migration, rendering and rollover tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
