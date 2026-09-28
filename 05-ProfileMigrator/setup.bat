@echo off
setlocal
chcp 65001 >nul
title Setup 05-ProfileMigrator
echo.
echo === Setup 05-ProfileMigrator ===
echo.
powershell -NoProfile -Command "exit ([int](-not ($PSVersionTable.PSVersion.Major -ge 5)))" >nul 2>&1
if errorlevel 1 ( echo [ERRORE] PowerShell 5.1+ richiesto. & pause & exit /b 1 )
echo [OK] PowerShell 5.1+
reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release >nul 2>&1
if errorlevel 1 ( echo [ERRORE] .NET Framework 4 non rilevato. & pause & exit /b 1 )
echo [OK] .NET Framework 4
echo.
echo [INFO] v1: solo export. Import in v2.
echo Output in cartella scelta dall'utente, mai sovrascrive senza conferma.
echo.
pause
endlocal
