@echo off
setlocal
title Nightslayer Rating Updater
set "UPDATER=%LOCALAPPDATA%\NightslayerRating\NightslayerRatingUpdater.ps1"
if not exist "%UPDATER%" (
  echo Nightslayer Rating is not installed. Run Install.cmd first.
  echo.
  pause
  exit /b 1
)
:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%"
set "UPDATE_EXIT=%ERRORLEVEL%"
echo.
if "%UPDATE_EXIT%"=="0" (
  echo Update attempt finished. Type /reload, then /nsr status to see the result and data age.
) else (
  echo Update failed. See %%LOCALAPPDATA%%\NightslayerRating\updater.log
)
echo.
echo Press any key to run another update, or close this window to exit.
pause >nul
echo.
goto run
