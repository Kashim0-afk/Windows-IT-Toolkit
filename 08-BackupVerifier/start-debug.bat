@echo off
setlocal
cd /d "%~dp0"
title 08-BackupVerifier [DEBUG]
echo === Modalita' DEBUG ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Main.ps1"
echo.
pause >nul
endlocal
