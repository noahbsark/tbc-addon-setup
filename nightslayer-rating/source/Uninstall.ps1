[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$TaskName = 'NightslayerRating Updater'
$RunValueName = 'NightslayerRatingUpdater'
$UpdaterDirectory = Join-Path $env:LOCALAPPDATA 'NightslayerRating'
$ConfigPath = Join-Path $UpdaterDirectory 'config.json'

$wowPath = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $wowPath = [string]$config.WowPath
    } catch {
        $wowPath = $null
    }
}

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
} catch {
    # The task may not exist or ScheduledTasks may be unavailable.
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -LiteralPath $runKey -Name $RunValueName -ErrorAction SilentlyContinue
}

if (-not [string]::IsNullOrWhiteSpace($wowPath)) {
    $addonPath = Join-Path $wowPath 'Interface\AddOns\NightslayerRating'
    if ((Split-Path -Leaf $addonPath) -eq 'NightslayerRating' -and (Test-Path -LiteralPath $addonPath)) {
        Remove-Item -LiteralPath $addonPath -Recurse -Force
        Write-Host ('Removed addon: ' + $addonPath)
    }
}

if ((Split-Path -Leaf $UpdaterDirectory) -eq 'NightslayerRating' -and (Test-Path -LiteralPath $UpdaterDirectory)) {
    Remove-Item -LiteralPath $UpdaterDirectory -Recurse -Force
    Write-Host 'Removed the updater and its local rating cache.'
}

Write-Host 'Nightslayer Rating has been uninstalled.' -ForegroundColor Green
