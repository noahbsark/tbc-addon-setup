@echo off
setlocal
title Nightslayer Rating - Process entire queue
set "UPDATER=%LOCALAPPDATA%\NightslayerRating\NightslayerRatingUpdater.ps1"
if not exist "%UPDATER%" (
  echo Nightslayer Rating is not installed. Run Install.cmd first.
  pause
  exit /b 1
)
echo Type /reload in WoW before starting to save any newly queued names.
echo Processing all due profiles in batches. Press Q to save and stop between requests.
echo You can leave WoW open. Afterward, /reload and use /nsr status.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%" -ProcessQueue
set "QUEUE_EXIT=%ERRORLEVEL%"
echo.
if not "%QUEUE_EXIT%"=="0" echo Processing stopped with an error. See %%LOCALAPPDATA%%\NightslayerRating\updater.log
echo Review the summary above. Run this shortcut again to continue unfinished profiles.
pause
exit /b %QUEUE_EXIT%
