[CmdletBinding()]
param([string]$WowPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$TaskName = 'NightslayerRating Updater'
$RunValueName = 'NightslayerRatingUpdater'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-AnniversaryPath {
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $Candidate = [Environment]::ExpandEnvironmentVariables($Candidate.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $Candidate -PathType Container)) {
        return $null
    }

    $Candidate = [IO.Path]::GetFullPath($Candidate.TrimEnd('\'))
    $nested = Join-Path $Candidate '_anniversary_'
    if (Test-Path -LiteralPath $nested -PathType Container) {
        $Candidate = $nested
    }

    if ((Split-Path -Leaf $Candidate) -ne '_anniversary_') {
        return $null
    }

    return $Candidate
}

function Find-AnniversaryPath {
    $candidates = New-Object Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($WowPath)) {
        $candidates.Add($WowPath)
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'World of Warcraft\_anniversary_'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'World of Warcraft\_anniversary_'))
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $candidates.Add((Join-Path $drive.Root 'World of Warcraft\_anniversary_'))
        $candidates.Add((Join-Path $drive.Root 'Games\World of Warcraft\_anniversary_'))
    }

    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
        'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft',
        'HKCU:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
    )) {
        try {
            $installPath = [string](Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction Stop).InstallPath
            $candidates.Add($installPath)
            $candidates.Add((Join-Path (Split-Path -Parent $installPath.TrimEnd('\')) '_anniversary_'))
        } catch {
            # This registry location is optional.
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $resolved = Resolve-AnniversaryPath $candidate
        if ($null -ne $resolved) {
            return $resolved
        }
    }

    return $null
}

function Ask-ForAnniversaryPath {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the World of Warcraft\_anniversary_ folder (or its World of Warcraft parent folder).'
    $dialog.ShowNewFolderButton = $false

    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return Resolve-AnniversaryPath $dialog.SelectedPath
}

function Register-AutomaticUpdater {
    param([string]$VbsPath)

    $registered = $false
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $action = New-ScheduledTaskAction -Execute $wscript -Argument ('"{0}"' -f $VbsPath)
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1)
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($repeatTrigger, $logonTrigger) -Settings $settings -Description 'Refreshes the Nightslayer and Dreamscythe arena-rating cache.' -Force | Out-Null
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $runKey) {
            Remove-ItemProperty -LiteralPath $runKey -Name $RunValueName -ErrorAction SilentlyContinue
        }
        $registered = $true
    } catch {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        } catch {
            # A partially configured task is harmless and may not exist.
        }
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path -LiteralPath $runKey)) {
            New-Item -Path $runKey -Force | Out-Null
        }
        $runCommand = 'wscript.exe "{0}"' -f $VbsPath
        Set-ItemProperty -LiteralPath $runKey -Name $RunValueName -Value $runCommand -Force
        Write-Warning 'Windows blocked the hourly scheduled task. Updates will still run automatically when you sign in to Windows.'
    }

    return $registered
}

Write-Host ''
Write-Host 'Nightslayer Rating installer' -ForegroundColor Yellow
Write-Host 'Finding the TBC Anniversary installation...'

$resolvedWowPath = Find-AnniversaryPath
if ($null -eq $resolvedWowPath) {
    $resolvedWowPath = Ask-ForAnniversaryPath
}
if ($null -eq $resolvedWowPath) {
    throw 'TBC Anniversary was not found. In Battle.net, use the cog beside Play > Show in Explorer, then run this installer again.'
}

$addonSource = Join-Path $PSScriptRoot 'Addon\NightslayerRating'
$updaterSource = Join-Path $PSScriptRoot 'Updater'
if (-not (Test-Path -LiteralPath (Join-Path $addonSource 'NightslayerRating.toc'))) {
    throw 'The package is incomplete: the addon source files are missing.'
}

$addonTarget = Join-Path $resolvedWowPath 'Interface\AddOns\NightslayerRating'
$updaterTarget = Join-Path $env:LOCALAPPDATA 'NightslayerRating'
[void][IO.Directory]::CreateDirectory($addonTarget)
[void][IO.Directory]::CreateDirectory($updaterTarget)

foreach ($item in @(Get-ChildItem -LiteralPath $addonSource -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $addonTarget -Recurse -Force
}
foreach ($name in @('NightslayerRatingUpdater.ps1', 'RunUpdater.vbs')) {
    Copy-Item -LiteralPath (Join-Path $updaterSource $name) -Destination (Join-Path $updaterTarget $name) -Force
}

$config = @{
    WowPath = $resolvedWowPath
    Realm = 'Nightslayer'
    Realms = @('Nightslayer', 'Dreamscythe')
    Region = 'US'
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $updaterTarget 'config.json'), $config, $Utf8NoBom)

Write-Host ('Installed addon to: ' + $addonTarget) -ForegroundColor Green
Write-Host 'Downloading the shared Nightslayer and Dreamscythe rating cache...'

$updaterScript = Join-Path $updaterTarget 'NightslayerRatingUpdater.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updaterScript -WowPath $resolvedWowPath
$initialUpdateWorked = $LASTEXITCODE -eq 0
if (-not $initialUpdateWorked) {
    Write-Warning 'The initial download failed. The automatic updater will retry; the included two-realm cache remains available.'
}

$scheduled = Register-AutomaticUpdater -VbsPath (Join-Path $updaterTarget 'RunUpdater.vbs')

Write-Host ''
Write-Host 'Installation complete.' -ForegroundColor Green
if ($scheduled) {
    Write-Host 'Ratings will refresh automatically every hour and at Windows sign-in.'
} else {
    Write-Host 'Ratings will refresh automatically at Windows sign-in.'
}
Write-Host 'Start or restart TBC Anniversary, then hover a Group Finder name.'
