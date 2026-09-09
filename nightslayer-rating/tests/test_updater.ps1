$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$UpdaterPath = Join-Path $RepoRoot 'nightslayer-rating/source/Updater/NightslayerRatingUpdater.ps1'
$TestRoot = Join-Path $RepoRoot ('.nsr-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $TestRoot)

function Assert-Equal($Actual, $Expected, [string]$Because) {
    if ($Actual -cne $Expected) { throw ('{0}: expected [{1}], got [{2}]' -f $Because, $Expected, $Actual) }
}

try {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($UpdaterPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    # Load the actual definitions without the installer/network entry point.
    $source = Get-Content -LiteralPath $UpdaterPath -Raw
    $entry = $source.IndexOf('if ([string]::IsNullOrWhiteSpace($WowPath))')
    if ($entry -lt 0) { throw 'Updater entry point not found' }
    $definitions = $source.Substring(0, $entry).Replace(
        '$UpdaterDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path',
        '$UpdaterDirectory = $TestRoot'
    )
    . ([scriptblock]::Create($definitions))
    function Start-Sleep { param($Milliseconds) }

    $old = @{
        version = 5; currentSeason = 3; syncedSeasons = @(1, 2)
        players = @{'nightslayer|example' = @{
            name = 'Example'; realm = 'Nightslayer'; current = @{'2'=1800}
            bestSeen = @{'2'=2500}; exactBest = @{'2'=2900}; exactFetchedAt = (Get-UnixTime)
        }}
    }
    $old | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $CachePath -Encoding UTF8
    $cache = Read-Cache
    $player = Get-PlayerRecord $cache 'Example' 'Nightslayer'
    Assert-Equal $player.season2.Count 0 'Legacy observed highs must not become S2 finals'
    Assert-Equal $player.season2Best.Count 0 'Legacy lifetime records must not become S2 peaks'
    Assert-Equal $player.season2Fetched $false 'Old exact profiles need one season-history refresh'
    Assert-Equal (@($cache.syncedSeasons) -contains 2) $false 'Fallback must backfill S2 after migration'

    $hash = Get-LookupHash -Name 'Example' -Realm 'Nightslayer'
    Assert-Equal (Get-LookupHash -Name 'Reefey' -Realm 'Nightslayer') 'ec31af45054a44db' 'Hash agrees with Python/Lua'
    $script:Snapshot = (@{
        version=6; season=3; region='US'; keyAlgorithm='nsr-h4-v1'; generated=123; leaderboardUpdated=120
        counts=@{Nightslayer=1;Dreamscythe=0}
        players=@{$hash=@{current=@{'2'=1900};bestSeen=@{'2'=2500};season2=@{'2'=2026;'3'=1869;'5'=1971}}}
    } | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    function Get-SharedSnapshot { return $script:Snapshot }
    Assert-Equal (Sync-SharedSnapshot $cache) $true 'Shared snapshot imported'
    Assert-Equal $player.current['2'] 1900 'Shared current refreshed'
    Assert-Equal $player.exactBest['2'] 2900 'Shared snapshot preserved lifetime record'
    Assert-Equal $player.season2['2'] 2026 'Shared final merged into existing exact row'
    Assert-Equal $player.season2Best.Count 0 'Shared final did not become a peak'

    function Get-QueuedRequests {
        param($GamePath, $Cache)
        foreach ($name in @('Temporary', 'Gone', 'Example')) {
            [pscustomobject]@{Name=$name;Realm='Nightslayer';Stamp=(Get-UnixTime);Priority=1}
        }
    }
    $script:ProfileCalls = 0
    function Invoke-IronForgeJson {
        param($Path, [switch]$AllowNotFound, [switch]$AllowServerError)
        $script:ProfileCalls++
        if ($Path.EndsWith('/Temporary')) { return @{__nsrTransientError=$true;statusCode=500} }
        if ($Path.EndsWith('/Gone')) { return $null }
        return @{
            info=@{name='Example'}; bracket_best=@{'2'=2900}
            season2=@{'2'=@{rating=2026;top=2175};'3'=@{rating=1869;top=2065};'5'=@{rating=1971;top=2048}}
            season3=@{'2'=@{rating=1800}}
        }
    }
    Assert-Equal (Sync-QueuedProfiles $cache $TestRoot) 1 'Batch continued past HTTP 500 and 404'
    Assert-Equal $script:ProfileCalls 3 'Every due profile attempted'
    Assert-Equal $player.season2Best['2'] 2175 'Season peak comes from top'
    Assert-Equal $player.season2Best['3'] 2065 '3v3 season peak'
    Assert-Equal $player.season2Best['5'] 2048 '5v5 season peak'
    Assert-Equal $player.exactBest['2'] 2900 'All-time record remains distinct'
    Assert-Equal $player.current['2'] 1800 'Current season remains distinct'
    Assert-Equal $player.season2Fetched $true 'Migration refresh completes'
    Assert-Equal $cache.players['nightslayer|temporary'].exactFetchedAt 0 'Transient error is retryable'
    Assert-Equal ($cache.players['nightslayer|gone'].notFoundUntil -gt (Get-UnixTime)) $true '404 uses negative cache'

    [void](Sync-QueuedProfiles $cache $TestRoot)
    Assert-Equal $script:ProfileCalls 4 'Second run retries transient only; success and 404 are cached'
    Save-Cache $cache
    $cache = Read-Cache
    $player = Get-PlayerRecord $cache 'Example' 'Nightslayer'
    Assert-Equal $player.season2Best['2'] 2175 'Season peak survives disk round trip'
    Assert-Equal $player.season2Fetched $true 'Refresh marker survives disk round trip'
    [void](Write-LuaData $cache $TestRoot)
    $lua = Get-Content -LiteralPath (Join-Path $TestRoot 'Data.lua') -Raw
    if (-not $lua.Contains('season2Best = { [2] = 2175, [3] = 2065, [5] = 2048 }')) { throw 'Lua missing season peaks' }
    if (-not $lua.Contains('exactBest = { [2] = 2900 }')) { throw 'Lua missing per-bracket exactness' }
    if (-not $lua.Contains('{ 1900, 0, 0, 2500, 0, 0, 2026, 1869, 1971 }')) { throw 'Lua shared slots changed' }

    # Historical leaderboard fallback also preserves S2 without inventing peaks.
    function Get-Leaderboard { param($Season,$Bracket) return @{ data=@(@{name='Fallback';server='Dreamscythe';rating=2000});updated=120000 } }
    $fallback = New-Cache
    Assert-Equal (Sync-LeaderboardSeason $fallback 2 $false) $true 'Direct S2 fallback succeeds'
    $row = Get-PlayerRecord $fallback 'Fallback' 'Dreamscythe'
    Assert-Equal $row.season2['2'] 2000 'Direct fallback preserves season'
    Assert-Equal $row.season2Best.Count 0 'Fallback does not invent a peak'
    Write-Host 'Updater functional tests passed: migration, season isolation, merge, retries, cache round trip, Lua output, direct fallback.'
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
