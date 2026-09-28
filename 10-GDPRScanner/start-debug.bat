@echo off
setlocal
cd /d "%~dp0"
title 10-GDPRScanner [DEBUG]
echo === Modalita' DEBUG ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Main.ps1"
echo.
echo === Tool terminato. ===
pause >nul
endlocal
