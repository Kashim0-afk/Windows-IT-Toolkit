@echo off
setlocal
chcp 65001 >nul
title Setup 01-DriverUpdater

echo.
echo === Setup 01-DriverUpdater ===
echo.

powershell -NoProfile -Command "exit ([int](-not ($PSVersionTable.PSVersion.Major -ge 5)))" >nul 2>&1
if errorlevel 1 (
    echo [ERRORE] PowerShell 5.1 o superiore richiesto.
    echo Aggiorna Windows o installa Windows Management Framework 5.1.
    echo.
    pause
    exit /b 1
)
echo [OK] PowerShell 5.1+

reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release >nul 2>&1
if errorlevel 1 (
    echo [ERRORE] .NET Framework 4 non rilevato.
    pause
    exit /b 1
)
echo [OK] .NET Framework 4

echo.
echo Setup completato.
echo Lancia start.bat per avviare il tool.
echo.
pause
endlocal
