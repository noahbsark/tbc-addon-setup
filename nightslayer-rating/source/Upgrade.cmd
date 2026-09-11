@echo off
setlocal
title Nightslayer Rating Upgrade
set "NSR_UPGRADE=%LOCALAPPDATA%\NightslayerRating\Upgrade.ps1"
if not exist "%NSR_UPGRADE%" (
  echo Run Install.cmd from the extracted 1.4.0 Windows bundle first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%NSR_UPGRADE%"
set "NSR_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %NSR_RESULT%
