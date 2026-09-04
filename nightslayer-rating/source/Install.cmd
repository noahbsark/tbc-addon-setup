@echo off
setlocal
title Nightslayer Rating Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set "INSTALL_EXIT=%ERRORLEVEL%"
echo.
if not "%INSTALL_EXIT%"=="0" echo Installation did not finish successfully.
pause
exit /b %INSTALL_EXIT%
