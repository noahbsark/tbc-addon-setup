[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$staging = $null
try {
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    $wowPath = [string]$config.WowPath
    if ((Split-Path -Leaf $wowPath.TrimEnd('\')) -ne '_anniversary_') { throw 'Run Install.cmd to configure the TBC Anniversary folder.' }
    $tocPath = Join-Path $wowPath 'Interface/AddOns/NightslayerRating/NightslayerRating.toc'
    $toc = Get-Content -LiteralPath $tocPath -Raw
    if ($toc -notmatch '(?m)^## Version: (\d+\.\d+\.\d+)\s*$') { throw 'Installed addon version could not be read.' }
    $installed = [version]$Matches[1]
    Write-Host 'Checking for a Nightslayer Rating upgrade...'
    $release = Get-NsrRelease
    if ([version]$release.version -le $installed) {
        Write-Host ('Already up to date: ' + $installed) -ForegroundColor Green
        exit 0
    }
    if (@(Get-Process -Name Wow, WowClassic, WowClassicT, WowT -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Close World of Warcraft, then run Upgrade.cmd again.'
    }
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('NightslayerRating-upgrade-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $zipPath = Join-Path $staging $release.archive
    $url = 'https://raw.githubusercontent.com/noahbsark/tbc-addon-setup/main/nightslayer-rating/downloads/' + $release.archive
    [IO.File]::WriteAllBytes($zipPath, (Get-NsrBytes -Url $url -MaximumBytes 20971520))
    Assert-NsrArchiveHash $zipPath $release.sha256
    $package = Expand-NsrRelease $zipPath (Join-Path $staging 'extracted') $release.version
    & (Join-Path $package 'Install.ps1') -WowPath $wowPath
    Write-Host ('Upgraded to ' + $release.version + '. Start WoW to load it.') -ForegroundColor Green
} catch {
    Write-Host ('Upgrade failed: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
