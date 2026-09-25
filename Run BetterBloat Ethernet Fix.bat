@echo off
setlocal
title BetterBloat - Ethernet Power Saving Fix
cd /d "%~dp0"

fltmc >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting Administrator privileges...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo BetterBloat - Ethernet Power Saving Fix
echo =========================================
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BetterBloat-EthernetPower.ps1"
set "EXITCODE=%errorlevel%"

echo.
if not "%EXITCODE%"=="0" (
    echo The script reported one or more failures. Review the output above.
) else (
    echo Finished successfully.
)
echo.
pause
exit /b %EXITCODE%
