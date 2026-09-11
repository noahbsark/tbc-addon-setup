Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../source'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
foreach ($path in @(Get-ChildItem -LiteralPath $source -Filter '*.ps1' -Recurse)) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
. (Join-Path $source 'Updater/Release.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'Install.ps1'), [ref]$tokens, [ref]$errors)
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { Invoke-Expression $node.Extent.Text }
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nsr-upgrade-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    $release = Convert-NsrRelease @{ version = '1.4.0'; archive = 'NightslayerRating-1.4.0-Windows.zip'; sha256 = ('a' * 64) }
    Assert ($release.version -eq '1.4.0') 'Valid manifest rejected'
    foreach ($bad in @(
        @{ version = '1.4.0'; archive = '../other.zip'; sha256 = ('a' * 64) },
        @{ version = '1.4.0; bad'; archive = 'other.zip'; sha256 = ('a' * 64) },
        @{ version = '1.4.0'; archive = 'NightslayerRating-1.4.0-Windows.zip'; sha256 = 'wrong' }
    )) {
        $rejected = $false
        try { [void](Convert-NsrRelease $bad) } catch { $rejected = $true }
        Assert $rejected 'Invalid manifest accepted'
    }
    $payload = Join-Path $directory 'payload.zip'
    [IO.File]::WriteAllText($payload, 'test')
    Assert-NsrArchiveHash $payload (Get-FileHash $payload -Algorithm SHA256).Hash
    $rejected = $false
    try { Assert-NsrArchiveHash $payload ('a' * 64) } catch { $rejected = $true }
    Assert $rejected 'Modified download accepted'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-FixtureZip {
        param([string]$Path, [hashtable]$Entries)
        $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($key in $Entries.Keys) {
                $writer = New-Object IO.StreamWriter($zip.CreateEntry($key).Open())
                try { $writer.Write([string]$Entries[$key]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
    }
    $entries = @{
        'NightslayerRating-1.4.0/Install.ps1' = '# installer'
        'NightslayerRating-1.4.0/Addon/NightslayerRating/NightslayerRating.toc' = '## Version: 1.4.0'
        'NightslayerRating-1.4.0/Updater/NightslayerRatingUpdater.ps1' = '# updater'
        'NightslayerRating-1.4.0/Updater/Release.ps1' = '# helper'
    }
    $valid = Join-Path $directory 'valid.zip'
    New-FixtureZip $valid $entries
    $expanded = Expand-NsrRelease $valid (Join-Path $directory 'valid') '1.4.0'
    Assert (Test-Path (Join-Path $expanded 'Install.ps1')) 'Valid archive did not extract'
    foreach ($name in @('NightslayerRating-1.4.0/../../escape.ps1', 'NightslayerRating-1.4.0/Updater/Release.ps1.')) {
        $badZip = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.zip')
        $badEntries = $entries.Clone(); $badEntries[$name] = 'bad'
        New-FixtureZip $badZip $badEntries
        $rejected = $false
        try { [void](Expand-NsrRelease $badZip (Join-Path $directory ([guid]::NewGuid().ToString('N'))) '1.4.0') } catch { $rejected = $true }
        Assert $rejected 'Unsafe archive path accepted'
    }
    $game = Join-Path $directory '_anniversary_'
    $updaterTarget = Join-Path $directory 'companion'
    $addonTarget = Join-Path $game 'Interface/AddOns/NightslayerRating'
    [void][IO.Directory]::CreateDirectory($addonTarget)
    [void][IO.Directory]::CreateDirectory($updaterTarget)
    [IO.File]::WriteAllText((Join-Path $addonTarget 'Core.lua'), 'old code')
    [IO.File]::WriteAllText((Join-Path $addonTarget 'Data.lua'), 'newer existing data')
    [IO.File]::WriteAllText((Join-Path $updaterTarget 'cache.json'), 'existing exact peaks')
    $backupRoot = Join-Path $directory 'backups'
    [void](Install-NsrPackage $source $game $updaterTarget $backupRoot)
    Assert ((Get-Content (Join-Path $addonTarget 'Data.lua') -Raw) -eq 'newer existing data') 'Upgrade replaced newer data'
    Assert ((Get-Content (Join-Path $updaterTarget 'cache.json') -Raw) -eq 'existing exact peaks') 'Upgrade erased cache'
    Assert (@(Get-ChildItem $backupRoot -Directory).Count -eq 1) 'Upgrade backup missing'
    Assert (Test-Path (Join-Path $updaterTarget 'Upgrade.cmd')) 'Upgrade launcher not installed'
    $before = Get-Content (Join-Path $addonTarget 'Core.lua') -Raw
    # Fail a copy only after backup and an earlier file replacement succeeded.
    function Copy-Item {
        param($LiteralPath, $Destination, [switch]$Recurse, [switch]$Force)
        if ($LiteralPath -eq (Resolve-Path (Join-Path $source 'Updater/Release.ps1')).Path) { throw 'Simulated disk write failure' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    $failed = $false
    try { [void](Install-NsrPackage $source $game $updaterTarget $backupRoot) } catch { $failed = $true }
    Assert $failed 'Copy failure was ignored'
    Assert ((Get-Content (Join-Path $addonTarget 'Core.lua') -Raw) -eq $before) 'Rollback did not restore code'
    Assert ((Get-Content (Join-Path $updaterTarget 'cache.json') -Raw) -eq 'existing exact peaks') 'Rollback lost cache'
    Write-Output 'Manifest, checksum, archive validation, cache preservation and installer rollback tests passed'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
