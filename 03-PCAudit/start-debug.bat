@echo off
setlocal
cd /d "%~dp0"
title 03-PCAudit [DEBUG]
echo === Modalita' DEBUG: console PowerShell visibile ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Main.ps1"
echo.
echo === Tool terminato. Premi un tasto per chiudere la console. ===
pause >nul
endlocal
