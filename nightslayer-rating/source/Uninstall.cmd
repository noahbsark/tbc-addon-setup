@echo off
setlocal
title Nightslayer Rating Uninstaller
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
set "UNINSTALL_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %UNINSTALL_EXIT%
