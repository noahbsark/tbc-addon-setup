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
$UpdaterVersion = '1.4.2'
$ProfileRefreshSeconds = 604800
$ActiveProfileRefreshSeconds = 86400
$ActivePlayerSeconds = 259200
$ExactCacheRetentionSeconds = 7776000
$ProfileLimitPerRun = 50
$ProfileSuccessDelayMilliseconds = 500
$ProfileErrorDelayMilliseconds = 3000
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-queue-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$CachePath = Join-Path $directory 'cache.json'
function Write-Log { param($Message) }
function Write-Progress { param($Activity, $PercentComplete, $Status, [switch]$Completed) }
function Start-Sleep {
    param($Milliseconds, $Seconds)
    if ($Milliseconds -gt 0) { $script:profileWaits += $Milliseconds }
    if ($Seconds -gt 0) { $script:batchWaits += $Seconds }
}
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-QueuedRequests { param($GamePath, $Cache) return $script:requests }
function Test-QueueCancellation { return $script:stopAfter -ge 0 -and $script:fetched.Count -ge $script:stopAfter }
$script:saveCheckpoint = (Get-Item Function:Save-QueueCheckpoint).ScriptBlock
function Save-QueueCheckpoint {
    param($Cache, $AddonDirectory)
    $script:checkpoints += $Cache.status.queueAttempted
    & $script:saveCheckpoint $Cache $AddonDirectory
}
function Reset-Fixture {
    param([int]$Count)
    $script:sourceTime = Get-UnixTime
    $script:requests = @(1..$Count | ForEach-Object {
        @{ Name = ('Example' + $_); Realm = 'Nightslayer'; Priority = $true; Stamp = $script:sourceTime }
    })
    if ($Count -eq 0) { $script:requests = @() }
    $script:fetched = @(); $script:checkpoints = @(); $script:profileWaits = @(); $script:batchWaits = @()
    $script:stopAfter = -1; $script:mode = 'success'
    return New-Cache
}
function Invoke-IronForgeJson {
    param($Path, [switch]$AllowNotFound, [switch]$AllowServerError)
    $script:fetched += $Path
    if ($script:mode -eq 'offline') { return @{ __nsrTransientError = $true; statusCode = 500 } }
    if ($script:mode -eq 'throttled') { return @{ __nsrTransientError = $true; statusCode = 429 } }
    if ($script:mode -eq 'invalid') { return @{ error = 'invalid response' } }
    if ($script:mode -eq 'mixed') {
        if ($Path -match '/Example1$') { return $null }
        if ($Path -match '/Example2$') { return @{ __nsrTransientError = $true; statusCode = 500 } }
    }
    return @{ bracket_best = @{ '2' = 2200 }; season3 = @{ '2' = @{ rating = 2100; modified = $script:sourceTime * 1000 } } }
}
try {
    # The user's full backlog: one pass, no duplicate requests, 17 saved batches.
    $cache = Reset-Fixture 850
    Assert ((Sync-QueuedProfiles $cache 'unused' -DrainQueue -AddonDirectory $directory) -eq 850) 'Full queue did not fetch 850 profiles'
    Assert ($script:fetched.Count -eq 850 -and @($script:fetched | Select-Object -Unique).Count -eq 850) 'A profile was skipped or requested twice'
    Assert ($script:checkpoints.Count -eq 17 -and $script:checkpoints[-1] -eq 850) 'Queue was not saved every 50 attempts'
    Assert (@($script:profileWaits | Where-Object { $_ -lt 1000 }).Count -eq 0) 'Full queue bypassed request pacing'
    Assert ($script:batchWaits.Count -eq 80) 'Inter-batch pause was skipped'
    Assert ($cache.status.queueState -eq 'complete' -and $cache.status.pendingProfiles -eq 0) 'Completed pass has incorrect status'
    $loaded = Read-Cache
    Assert ($loaded.players.Count -eq 850 -and $loaded.status.queueFetched -eq 850) 'Saved queue results did not survive reload'
    Assert ((Get-Content (Join-Path $directory 'SyncStatus.lua') -Raw).Contains('queueAttempted = 850')) 'Progress did not reach WoW'
    Assert ((Get-Content (Join-Path $directory 'Data.lua') -Raw).Contains('Example850')) 'Last batch was not exported'
    $script:fetched = @()
    Assert ((Sync-QueuedProfiles $loaded 'unused' -DrainQueue -AddonDirectory $directory) -eq 0) 'Immediate repeat fetched fresh profiles again'
    Assert ($script:fetched.Count -eq 0 -and $loaded.status.queueTotal -eq 0) 'Empty due queue was not handled'

    # Q checkpoints a partial batch; a subsequent run skips completed profiles.
    $cache = Reset-Fixture 120
    $script:stopAfter = 70
    Assert ((Sync-QueuedProfiles $cache 'unused' -DrainQueue -AddonDirectory $directory) -eq 70) 'Q did not stop between requests'
    Assert ($cache.status.queueState -eq 'cancelled' -and $cache.status.pendingProfiles -eq 50) 'Cancelled queue status is inaccurate'
    Assert (($script:checkpoints -join ',') -eq '50,70') 'Q lost the partial batch'
    $done = @($script:fetched)
    $loaded = Read-Cache
    $script:stopAfter = -1; $script:fetched = @()
    Assert ((Sync-QueuedProfiles $loaded 'unused' -DrainQueue -AddonDirectory $directory) -eq 50) 'Resume did not finish remaining profiles'
    Assert (@($script:fetched | Where-Object { $done -contains $_ }).Count -eq 0) 'Resume refetched completed profiles'

    # Missing and failing profiles are each attempted once, not retried forever.
    $cache = Reset-Fixture 60
    $script:mode = 'mixed'
    Assert ((Sync-QueuedProfiles $cache 'unused' -DrainQueue -AddonDirectory $directory) -eq 58) 'Mixed queue lost successful results'
    Assert ($script:fetched.Count -eq 60) 'Failed profile was retried within the same pass'
    Assert ($cache.status.queueMissing -eq 1 -and $cache.status.queueFailed -eq 1 -and $cache.status.pendingProfiles -eq 1) 'Unavailable and retry counts were confused'
    Assert ($cache.status.queueState -eq 'complete') 'Attempted-all pass was not completed'

    foreach ($scenario in @('offline', 'throttled', 'invalid')) {
        $cache = Reset-Fixture 850
        $script:mode = $scenario
        [void](Sync-QueuedProfiles $cache 'unused' -DrainQueue -AddonDirectory $directory)
        $expected = $(if ($scenario -eq 'throttled') { 1 } else { 5 })
        Assert ($script:fetched.Count -eq $expected) ('Did not stop promptly for ' + $scenario)
        Assert ($cache.status.queueState -eq 'paused' -and $cache.status.pendingProfiles -eq 850) 'Source outage lost queued work'
        Assert (@($cache.players.Values | Where-Object { $_.exactFetchedAt -gt 0 }).Count -eq 0) 'Invalid or failed response became an exact profile'
    }
    # A hard close leaves its last checkpoint useful and marked interrupted.
    $cache.status.queueState = 'running'
    Save-Cache $cache
    Assert ((Read-Cache).status.queueState -eq 'interrupted') 'Interrupted run was reported as still running'

    $cache = Reset-Fixture 850
    Assert ((Sync-QueuedProfiles $cache 'unused') -eq 50) 'Normal hourly run exceeded 50 profiles'
    Assert ($cache.status.pendingProfiles -eq 800 -and $script:checkpoints.Count -eq 0) 'Normal run was converted into an unlimited job'
    # The public updater mode downloads bulk data/cutoffs just once before
    # draining, rather than rerunning the entire updater for every batch.
    $cache = Reset-Fixture 90
    $script:bulkCalls = 0; $script:cutoffCalls = 0
    function Initialize-BundledSnapshot { param($Cache) }
    function Sync-SharedSnapshot { param($Cache) $script:bulkCalls++; return $true }
    function Sync-RatingCutoffs { param($Cache) $script:cutoffCalls++ }
    function Sync-ReleaseVersion { param($Cache) }
    Update-RatingData $cache 'unused' $directory -DrainQueue
    Assert ($script:fetched.Count -eq 90 -and $script:bulkCalls -eq 1 -and $script:cutoffCalls -eq 1) 'Queue mode repeated bulk downloads or stopped after one batch'
    Write-Output '850-player drain, paced checkpoints, cancellation/resume, outage limits and hourly budget tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
