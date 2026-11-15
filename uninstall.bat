@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoBrightness.ps1" -Action uninstall
echo.
pause
