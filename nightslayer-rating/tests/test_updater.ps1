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
$SharedSnapshotMaxCompressedBytes = 10485760
$SharedSnapshotMaxJsonChars = 52428800
$UpdaterVersion = '1.4.0'
$ProfileRefreshSeconds = 604800
$ActiveProfileRefreshSeconds = 86400
$ActivePlayerSeconds = 259200
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$CachePath = Join-Path $directory 'cache.json'
$BundledSnapshotPath = Join-Path $directory 'BundledSnapshot.json.gz'
$script:logs = @()
function Write-Log { param([string]$Message) $script:logs += $Message }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Get-NsrRelease { return [pscustomobject]@{ version = '1.4.0' } }
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
    Assert ($lua.Contains('exactBrackets = { [2] = true }')) 'Exact peak provenance missing'
    $player.current['3'] = 2400
    $player.bestSeen['3'] = 2400
    $player.exactBest['3'] = 2300
    [void](Write-LuaData $cache $directory)
    $lua = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($lua.Contains('best = { [2] = 2900, [3] = 2400 }')) 'Newly observed high was hidden by an older exact peak'
    Assert ($lua.Contains('exactBrackets = { [2] = true }')) 'Observed high was mislabeled as exact'
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

    # A missing future season returns an HTTP 500 marker in production. It
    # must not be mistaken for a one-row leaderboard and promote S3 to S20.
    $script:probes = 0
    function Get-Leaderboard {
        param($Season, $Bracket, [switch]$Probe)
        $script:probes++
        return [pscustomobject]@{ __nsrTransientError = $true; statusCode = 500 }
    }
    Assert ((Find-CurrentSeason $cache) -eq 3) 'HTTP 500 invented a future season'
    Assert ($script:probes -eq 1) 'Missing future season was probed repeatedly'
    Assert (-not (Test-LeaderboardPayload $null)) 'Null payload accepted'
    Assert (-not (Test-LeaderboardPayload @{ data = @($null) })) 'Null row accepted'
    Assert (-not (Test-LeaderboardPayload @{ data = @(@{ error = 'offline' }) })) 'Error row accepted'
    Assert (Test-LeaderboardPayload @{ data = @(@{ name = 'Twinname'; server = 'Nightslayer'; rating = 2000 }) }) 'A single valid row was rejected'

    # Seed the same compressed snapshot shipped in the Windows installer.
    $seed = @{
        version = 6; season = 3; previousSeason = 2; region = 'US'; keyAlgorithm = 'nsr-h4-v1'
        generated = ((Get-UnixTime) - 20); leaderboardUpdated = ((Get-UnixTime) - 20)
        counts = @{ Nightslayer = 1; Dreamscythe = 0 }; cutoffs = $cache.cutoffs
        players = @{ $hash = @{ current = @{ '2' = 2058; '3' = 2006; '5' = 2078 }
            bestSeen = @{ '2' = 2900 }; previous = @{ '2' = 2481 } } }
    }
    foreach ($entry in $seed.cutoffs['3'].Values) { $entry.checked = Get-UnixTime }
    $bytes = $Utf8NoBom.GetBytes(($seed | ConvertTo-Json -Depth 12))
    $stream = [IO.File]::Create($BundledSnapshotPath)
    $zip = New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Compress)
    $zip.Write($bytes, 0, $bytes.Length)
    $zip.Dispose()
    $stream.Dispose()
    Assert ((Read-CompressedSnapshot ([IO.File]::ReadAllBytes($BundledSnapshotPath))).version -eq 6) 'Bundled gzip did not decode'

    $upgrade = New-Cache
    $upgrade.sharedPlayers[$hash] = @{ current = @{ '2' = 2300 }; bestSeen = @{ '2' = 2900 }; previous = @{} }
    Initialize-BundledSnapshot $upgrade
    Assert ($upgrade.sharedPlayers[$hash].current['2'] -eq 2300) 'Bootstrap replaced existing upgrade ratings'
    Assert ($upgrade.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Legacy cache with players did not receive bundled current cutoffs'

    $legacy = @{
        version = 5; season = 3; region = 'US'; keyAlgorithm = 'nsr-h4-v1'
        generated = Get-UnixTime; leaderboardUpdated = Get-UnixTime
        counts = @{ Nightslayer = 1; Dreamscythe = 0 }
        players = @{ $hash = @{ current = @{ '2' = 2100 }; bestSeen = @{ '2' = 2900 } } }
    }
    $script:snapshot = $legacy
    $script:probes = 0
    $script:profilePasses = 0
    function Sync-QueuedProfiles { param($Cache, $GamePath) $script:profilePasses++; return 0 }
    $fresh = New-Cache
    Update-RatingData $fresh $directory $directory
    Assert ($script:probes -eq 0) 'Valid v5 snapshot triggered bulk fallback'
    Assert ($fresh.sharedPlayers[$hash].current['2'] -eq 2100) 'Legacy current ratings did not load'
    Assert ($fresh.sharedPlayers[$hash].previous['2'] -eq 2481) 'Legacy import erased bundled history'
    Assert ($fresh.cutoffs['3']['2'].thresholds[0] -eq 2199) 'Legacy import erased bundled cutoffs'
    $written = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($written.Contains('2100, 0, 0, 2900, 0, 0')) 'Legacy ratings were not written to Lua'
    Assert ($script:profilePasses -eq 1) 'Legacy import skipped exact profile lookups'
    Assert ($fresh.status.mode -eq 'shared') 'Successful legacy download has wrong status'
    Assert ($fresh.status.lastSuccess -gt 0) 'Successful download timestamp missing'

    $legacy.version = 4
    Assert (Import-SharedSnapshot $fresh ($legacy | ConvertTo-Json -Depth 12 | ConvertFrom-Json)) 'v4 compatibility failed'
    $legacy.players[$hash].current['2'] = 1900
    $legacy.leaderboardUpdated = 1
    Assert (Import-SharedSnapshot $fresh ($legacy | ConvertTo-Json -Depth 12 | ConvertFrom-Json)) 'Older snapshot was treated as an outage'
    Assert ($fresh.sharedPlayers[$hash].current['2'] -eq 2100) 'Older snapshot rolled back cached ratings'
    $legacy.leaderboardUpdated = Get-UnixTime
    $legacy.players = @{ 'bad-hash' = @{ current = @{ '2' = 2100 } } }
    Assert (-not (Import-SharedSnapshot $fresh ($legacy | ConvertTo-Json -Depth 12 | ConvertFrom-Json))) 'Zero valid rows were accepted'
    Assert ($fresh.sharedPlayers[$hash].current['2'] -eq 2100) 'Invalid shared data erased good rows'

    # First installation with both sources unavailable keeps the bundle usable.
    function Get-SharedSnapshot { return $null }
    function Get-Leaderboard { param($Season, $Bracket, [switch]$Probe) throw 'HTTP 500' }
    $offline = New-Cache
    Update-RatingData $offline $directory $directory
    Assert ($offline.currentSeason -eq 3) 'Offline run changed season'
    Assert ($offline.sharedPlayers[$hash].current['2'] -eq 2058) 'Offline run lost bundled data'
    $written = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($written.Contains('2058, 2006, 2078, 2900, 0, 0')) 'Offline install overwrote bundled ratings'
    Assert ($script:profilePasses -eq 2) 'Bulk failure aborted later update stages'
    Assert ($offline.status.mode -eq 'cached') 'Outage was advertised as a fresh download'
    Assert ($offline.status.lastSuccess -eq 0) 'Offline bootstrap was counted as a download'
    $status = Get-Content (Join-Path $directory 'SyncStatus.lua') -Raw
    Assert ($status.Contains('mode = "cached"')) 'Outage did not reach the addon'

    # One successful bracket must not erase the two failed brackets, and must
    # refresh the shared row that the addon actually prefers for non-exact data.
    function Get-Leaderboard {
        param($Season, $Bracket, [switch]$Probe)
        if ($Bracket -eq 2) { throw 'HTTP 500' }
        if ($Bracket -eq 5) { return @{ data = @() } }
        return @{ updated = ((Get-UnixTime) * 1000); data = @(@{ server = 'Nightslayer'; name = 'Twinname'; rating = 2200 }) }
    }
    Assert (-not (Sync-LeaderboardSeason $offline 3 $true)) 'Partial failure reported as complete'
    Assert ($offline.sharedPlayers[$hash].current['2'] -eq 2058) 'Failed 2v2 refresh erased its cache'
    Assert ($offline.sharedPlayers[$hash].current['3'] -eq 2200) 'Fresh fallback was masked by old shared 3v3'
    Assert ($offline.sharedPlayers[$hash].current['5'] -eq 2078) 'Empty 5v5 response erased its cache'
    Assert ($offline.status.mode -eq 'partial') 'Partial bracket failure has wrong status'
    Assert ($offline.leaderboardUpdates.ContainsKey('3')) 'Successful bracket source timestamp missing'
    Assert (-not $offline.leaderboardUpdates.ContainsKey('2')) 'Failed bracket was marked fresh'

    # An install without any bootstrap cache must not replace existing Data.lua
    # with an empty player table when every network request fails.
    $BundledSnapshotPath = Join-Path $directory 'missing.gz'
    function Get-Leaderboard { param($Season, $Bracket, [switch]$Probe) throw 'HTTP 500' }
    $empty = New-Cache
    $before = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Update-RatingData $empty $directory $directory
    Assert ((Get-Content (Join-Path $directory 'Data.lua') -Raw) -eq $before) 'Empty offline update replaced existing addon data'
    Assert ((Get-Content (Join-Path $directory 'SyncStatus.lua') -Raw).Contains('mode = "cached"')) 'Empty update did not write failure status separately'
    $now = Get-UnixTime
    Assert ((Get-ProfileRefreshInterval @{ Priority = $true; Stamp = $now } $now) -eq 86400) 'Active player is not refreshed daily'
    Assert ((Get-ProfileRefreshInterval @{ Priority = $true; Stamp = $now - 4 * 86400 } $now) -eq 604800) 'Inactive player should retain weekly caching'
    Assert ((Get-ProfileRefreshInterval @{ Priority = $false; Stamp = $now } $now) -eq 604800) 'Bulk leaderboard browsing should retain weekly caching'
    Write-Output 'Updater cutoff refresh, failure retention, cache migration, rendering and rollover tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
