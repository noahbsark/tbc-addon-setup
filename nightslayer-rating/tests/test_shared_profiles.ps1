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
$ProfileRefreshSeconds = 604800; $ActiveProfileRefreshSeconds = 86400; $ActivePlayerSeconds = 259200
$ExactCacheRetentionSeconds = 7776000
$ProfileLimitPerRun = 50; $ProfileSuccessDelayMilliseconds = 500; $ProfileErrorDelayMilliseconds = 3000
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$UpdaterVersion = '1.5.0'
function Write-Log { param($Message) }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-QueuedRequests { param($GamePath, $Cache) return $script:requests }
$script:now = Get-UnixTime
$script:fetched = @()
function Invoke-IronForgeJson {
    param($Path, [switch]$AllowNotFound, [switch]$AllowServerError)
    $script:fetched += $Path
    return @{ bracket_best = @{ '2' = 2500 }; season3 = @{ '2' = @{ rating = 2200; modified = $script:now * 1000 } } }
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-shared-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$CachePath = Join-Path $directory 'cache.json'
try {
    $cache = New-Cache
    $hash = Get-LookupHash 'Cached' 'Nightslayer'
    $snapshot = @{ version = 6; keyAlgorithm = 'nsr-h4-v1'; region = 'US'; season = 3; previousSeason = 2
        generated = $script:now; leaderboardUpdated = $script:now; leaderboardUpdates = @{ '2' = $script:now }
        players = @{ $hash = @{ current = @{ '2' = 2100 }; bestSeen = @{ '2' = 2200 }; previous = @{}
            exactBest = @{ '2' = 2400 }; exactFetchedAt = $script:now - 600 } } }
    Assert (Import-SharedSnapshot $cache ($snapshot | ConvertTo-Json -Depth 8 | ConvertFrom-Json)) 'Shared peak snapshot rejected'
    $script:requests = @(@{ Name = 'Cached'; Realm = 'Nightslayer'; Priority = $true; Stamp = $script:now })
    Assert ((Sync-QueuedProfiles $cache 'unused') -eq 0) 'Fresh shared profile was fetched locally'
    $cached = Get-PlayerRecord $cache 'Cached' 'Nightslayer'
    Assert ($cached.exactBest['2'] -eq 2400 -and $cached.exactSource -eq 'shared') 'Shared peak was not copied into the local player'
    Assert ($cache.status.sharedPeakHits -eq 1 -and $cache.status.currentCachedProfiles -eq 1 -and $cache.status.pendingProfiles -eq 0) 'Coverage counts confuse cached ratings with pending profiles'
    Assert ((Get-PlayerRecord $cache 'Cached' 'Dreamscythe').exactFetchedAt -eq 0) 'Same-name character on another realm inherited a peak'
    Save-Cache $cache
    $cache = Read-Cache
    Assert ($cache.sharedPlayers[$hash].exactBest['2'] -eq 2400) 'Shared peaks did not survive saving the cache'
    Assert ((Get-PlayerRecord $cache 'Cached' 'Nightslayer').exactSource -eq 'shared') 'Shared provenance was lost'
    [void](Write-LuaData $cache $directory)
    $lua = Get-Content (Join-Path $directory 'Data.lua') -Raw
    Assert ($lua.Contains('exactBest = { [2] = 2400 }') -and $lua.Contains('sharedProfiles = 1')) 'Shared peak fields were omitted from addon data'
    Assert ((Convert-SharedProfile @{ exactBest = @{ '2' = 3000 }; exactFetchedAt = $script:now + 7200 }).exactFetchedAt -eq 0) 'Future-dated exact peak accepted'
    Assert ((Convert-SharedProfile @{ exactBest = @{ '2' = 'invalid' }; exactFetchedAt = $script:now }).exactFetchedAt -eq 0) 'Malformed exact peak accepted'

    # Never downgrade a newer local peak or erase shared peaks on a legacy payload.
    $cached = Get-PlayerRecord $cache 'Cached' 'Nightslayer'
    $cached.exactBest['2'] = 3000; $cached.exactFetchedAt = $script:now; $cached.exactSource = 'local'
    Sync-PlayerPeaksFromShared $cached $cache.sharedPlayers
    Assert ($cached.exactBest['2'] -eq 3000 -and $cached.exactFetchedAt -eq $script:now) 'Shared result downgraded a newer local peak'
    $snapshot.players[$hash].Remove('exactBest'); $snapshot.players[$hash].Remove('exactFetchedAt')
    Assert (Import-SharedSnapshot $cache ($snapshot | ConvertTo-Json -Depth 8 | ConvertFrom-Json)) 'Legacy payload rejected'
    Assert ($cache.sharedPlayers[$hash].exactBest['2'] -eq 2400) 'Legacy payload erased shared peaks'

    # A fresh shared peak alone must not suppress a missing-current lookup.
    $cache = New-Cache
    $cache.sharedPlayers[$hash] = @{ current = @{}; previous = @{}; bestSeen = @{}
        exactBest = @{ '2' = 2400 }; exactFetchedAt = $script:now }
    $script:fetched = @()
    Assert ((Sync-QueuedProfiles $cache 'unused') -eq 1) 'Shared peak suppressed an off-ladder current-rating lookup'
    Assert ((Get-PlayerRecord $cache 'Cached' 'Nightslayer').current['2'] -eq 2200) 'Off-ladder profile current rating was not imported'
    Assert ((Sync-QueuedProfiles $cache 'unused') -eq 0) 'Off-ladder profile was fetched again immediately'

    # Missing current data first among untried players; retries cannot starve peers.
    $cache = New-Cache
    $script:requests = @(
        @{ Name = 'Hascurrent'; Realm = 'Nightslayer'; Priority = $true; Stamp = $script:now },
        @{ Name = 'Missing'; Realm = 'Nightslayer'; Priority = $true; Stamp = $script:now })
    Set-CurrentRating (Get-PlayerRecord $cache 'Hascurrent' 'Nightslayer') 2 2100 $script:now
    $ProfileLimitPerRun = 1
    $script:fetched = @()
    [void](Sync-QueuedProfiles $cache 'unused')
    Assert ($script:fetched[0] -like '*/Missing') 'Player missing current data was not prioritized'
    Assert ($cache.status.queuedPlayers -eq 2 -and $cache.status.cachedPeakProfiles -eq 1) 'Queue coverage did not update after a fetched profile'
    Write-Output 'Shared peak reuse, realm isolation, persistence, validation, coverage and missing-current priority tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
