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
$ProfileRefreshSeconds = 604800
$ActiveProfileRefreshSeconds = 86400
$ActivePlayerSeconds = 259200
$ExactCacheRetentionSeconds = 7776000
$ProfileLimitPerRun = 50
$ProfileSuccessDelayMilliseconds = 500
$ProfileErrorDelayMilliseconds = 3000
function Write-Log { param($Message) }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$now = Get-UnixTime
$cache = New-Cache
$script:requests = @(
    @{ Name = 'Active'; Realm = 'Nightslayer'; Priority = $true; Stamp = $now },
    @{ Name = 'Inactive'; Realm = 'Nightslayer'; Priority = $true; Stamp = $now - 4 * 86400 },
    @{ Name = 'Bulk'; Realm = 'Nightslayer'; Priority = $false; Stamp = $now }
)
foreach ($request in $script:requests) {
    $player = Get-PlayerRecord $cache $request.Name $request.Realm
    $player.exactFetchedAt = $now - 2 * 86400
    $player.exactBest['2'] = 2000
}
function Get-QueuedRequests { param($GamePath, $Cache) return $script:requests }
$script:fetched = @()
function Invoke-IronForgeJson {
    param($Path, [switch]$AllowNotFound, [switch]$AllowServerError)
    $script:fetched += $Path
    return @{ bracket_best = @{ '2' = 2200 }; season3 = @{ '2' = @{ rating = 2100 } } }
}
Assert ((Sync-QueuedProfiles $cache 'unused') -eq 1) 'Daily refresh did not select only the active player'
Assert ($script:fetched[0] -like '*/Active') 'Wrong player received a daily refresh'
Assert ((Get-PlayerRecord $cache 'Active' 'Nightslayer').exactBest['2'] -eq 2200) 'New peak was not retained'
Assert ((Sync-QueuedProfiles $cache 'unused') -eq 0) 'Fresh peak was fetched again immediately'

# Keep the hard request budget and rotate persistent failures behind untried names.
$cache = New-Cache
$script:requests = @(1..70 | ForEach-Object { @{ Name = ('Example' + $_); Realm = 'Nightslayer'; Priority = $true; Stamp = $now } })
$script:fetched = @()
function Invoke-IronForgeJson {
    param($Path, [switch]$AllowNotFound, [switch]$AllowServerError)
    $script:fetched += $Path
    return [pscustomobject]@{ __nsrTransientError = $true; statusCode = 500 }
}
[void](Sync-QueuedProfiles $cache 'unused')
Assert ($script:fetched.Count -eq 50) 'Per-run profile budget changed'
Assert ($cache.status.pendingProfiles -eq 70 -and $cache.status.failedProfiles -eq 50) 'Pending/error counts are inaccurate'
$firstBatch = @($script:fetched)
$script:fetched = @()
[void](Sync-QueuedProfiles $cache 'unused')
Assert ($script:fetched.Count -eq 50) 'Retry pass exceeded request budget'
Assert ($firstBatch -notcontains $script:fetched[0]) 'Failures starved untried profiles'
Write-Output 'Active-player refresh, rate limit and failure-queue fairness tests passed'
