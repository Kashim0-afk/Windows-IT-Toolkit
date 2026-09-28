@echo off
setlocal
chcp 65001 >nul
title Setup 03-PCAudit

echo.
echo === Setup 03-PCAudit ===
echo.

powershell -NoProfile -Command "exit ([int](-not ($PSVersionTable.PSVersion.Major -ge 5)))" >nul 2>&1
if errorlevel 1 (
    echo [ERRORE] PowerShell 5.1 o superiore richiesto.
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
echo [INFO] Alcune informazioni (BitLocker recovery key, SMART avanzato) richiedono
echo        l'esecuzione come amministratore. Senza admin saranno marcate come
echo        "non disponibile - richiede admin".
echo.
echo Setup completato. Lancia start.bat per avviare il tool.
echo.
pause
endlocal
