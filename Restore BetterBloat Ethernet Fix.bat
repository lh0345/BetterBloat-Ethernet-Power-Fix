@echo off
setlocal
title BetterBloat - Restore Ethernet Power Settings
cd /d "%~dp0"

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting Administrator privileges...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo BetterBloat - Restore Ethernet Power Settings
echo ==============================================
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-BetterBloat-EthernetPower.ps1"
set "EXITCODE=%errorlevel%"

echo.
if not "%EXITCODE%"=="0" (
    echo The restore script reported one or more failures. Review the output above.
) else (
    echo Restore finished successfully.
)
echo.
pause
exit /b %EXITCODE%
