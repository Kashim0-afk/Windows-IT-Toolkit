@echo off
setlocal
cd /d "%~dp0"
title 07-SpoolerDoctor [DEBUG]
echo === Modalita' DEBUG ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Main.ps1"
echo.
echo === Tool terminato. ===
pause >nul
endlocal
