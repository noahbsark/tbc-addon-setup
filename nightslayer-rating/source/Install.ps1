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

function Install-NsrPackage {
    param([string]$SourcePath, [string]$GamePath, [string]$UpdaterTarget, [string]$BackupRoot)
    $addonSource = Join-Path $SourcePath 'Addon\NightslayerRating'
    $updaterSource = Join-Path $SourcePath 'Updater'
    $addonTarget = Join-Path $GamePath 'Interface\AddOns\NightslayerRating'
    foreach ($required in @('NightslayerRating.toc', 'Core.lua', 'Options.lua', 'TitleTracker.lua', 'Status.lua')) {
        if (-not (Test-Path -LiteralPath (Join-Path $addonSource $required))) { throw ('Package is missing ' + $required) }
    }
    foreach ($required in @('NightslayerRatingUpdater.ps1', 'RunUpdater.vbs', 'Release.ps1', 'Upgrade.ps1', 'Season2Cutoffs.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $updaterSource $required))) { throw ('Package is missing ' + $required) }
    }
    $mutex = New-Object Threading.Mutex($false, 'Local\NightslayerRatingUpdater')
    $locked = $false
    $copyStarted = $false
    $addonExisted = Test-Path -LiteralPath $addonTarget
    $updaterExisted = Test-Path -LiteralPath $UpdaterTarget
    $backup = Join-Path $BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        $locked = $mutex.WaitOne(0)
        if (-not $locked) { throw 'The rating updater is running. Let it finish, then run the installer again.' }
        if ($addonExisted -or $updaterExisted) {
            [void][IO.Directory]::CreateDirectory($backup)
            if ($addonExisted) { Copy-Item -LiteralPath $addonTarget -Destination (Join-Path $backup 'Addon') -Recurse -Force }
            if ($updaterExisted) { Copy-Item -LiteralPath $UpdaterTarget -Destination (Join-Path $backup 'Updater') -Recurse -Force }
            Write-Host ('Previous installation backed up to: ' + $backup)
        }
        $copyStarted = $true
        [void][IO.Directory]::CreateDirectory($addonTarget)
        [void][IO.Directory]::CreateDirectory($UpdaterTarget)
        foreach ($item in @(Get-ChildItem -LiteralPath $addonSource -Force)) {
            # These generated files may already be newer than the bundled data.
            if ($item.Name -in @('Data.lua', 'SyncStatus.lua') -and (Test-Path -LiteralPath (Join-Path $addonTarget $item.Name))) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $addonTarget -Recurse -Force
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $updaterSource -File)) {
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $UpdaterTarget $item.Name) -Force
        }
        foreach ($name in @('Upgrade.cmd', 'Update Now.cmd')) {
            Copy-Item -LiteralPath (Join-Path $SourcePath $name) -Destination (Join-Path $UpdaterTarget $name) -Force
        }
        $config = @{ WowPath = $GamePath; Realm = 'Nightslayer'; Realms = @('Nightslayer', 'Dreamscythe'); Region = 'US' } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $UpdaterTarget 'config.json'), $config, $Utf8NoBom)
    } catch {
        $originalError = $_
        if ($copyStarted) {
            try {
                if (Test-Path -LiteralPath $addonTarget) { Remove-Item -LiteralPath $addonTarget -Recurse -Force }
                if (Test-Path -LiteralPath $UpdaterTarget) { Remove-Item -LiteralPath $UpdaterTarget -Recurse -Force }
                if ($addonExisted) { Copy-Item -LiteralPath (Join-Path $backup 'Addon') -Destination $addonTarget -Recurse -Force }
                if ($updaterExisted) { Copy-Item -LiteralPath (Join-Path $backup 'Updater') -Destination $UpdaterTarget -Recurse -Force }
                Write-Warning 'Installation failed; the previous installation was restored.'
            } catch { Write-Warning ('Automatic restore failed. Your backup is at: ' + $backup) }
        }
        throw $originalError
    } finally {
        if ($locked) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return $addonTarget
}

function Install-NsrShortcuts {
    param([string]$UpdaterTarget)
    try {
        $folder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Nightslayer Rating'
        [void][IO.Directory]::CreateDirectory($folder)
        $shell = New-Object -ComObject WScript.Shell
        foreach ($name in @('Upgrade', 'Update Now')) {
            $shortcut = $shell.CreateShortcut((Join-Path $folder ($name + '.lnk')))
            $shortcut.TargetPath = Join-Path $UpdaterTarget ($name + '.cmd')
            $shortcut.WorkingDirectory = $UpdaterTarget
            $shortcut.Save()
        }
    } catch { Write-Warning 'Start menu shortcuts were unavailable. Upgrade.cmd and Update Now.cmd still work from the extracted bundle.' }
}

Write-Host ''
Write-Host 'Nightslayer Rating installer' -ForegroundColor Yellow
Write-Host 'Finding the TBC Anniversary installation...'
if (@(Get-Process -Name Wow, WowClassic, WowClassicT, WowT -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close World of Warcraft before running Install.cmd.'
}

$resolvedWowPath = Find-AnniversaryPath
if ($null -eq $resolvedWowPath) {
    $resolvedWowPath = Ask-ForAnniversaryPath
}
if ($null -eq $resolvedWowPath) {
    throw 'TBC Anniversary was not found. In Battle.net, use the cog beside Play > Show in Explorer, then run this installer again.'
}

$updaterTarget = Join-Path $env:LOCALAPPDATA 'NightslayerRating'
$backupRoot = Join-Path $env:LOCALAPPDATA 'NightslayerRatingBackups'
$addonTarget = Install-NsrPackage -SourcePath $PSScriptRoot -GamePath $resolvedWowPath -UpdaterTarget $updaterTarget -BackupRoot $backupRoot
Install-NsrShortcuts -UpdaterTarget $updaterTarget

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
Write-Host 'Use /nsr options for display settings and /nsr status for data age.'
Write-Host 'Future addon versions: close WoW, then choose Nightslayer Rating > Upgrade in the Start menu.'
