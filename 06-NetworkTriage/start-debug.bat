@echo off
setlocal
cd /d "%~dp0"
title 06-NetworkTriage [DEBUG]
echo === Modalita' DEBUG ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Main.ps1"
echo.
echo === Tool terminato. Premi un tasto. ===
pause >nul
endlocal
