@echo off
setlocal
set "SCRIPT=%~dp0scripts\Invoke-XboxOfflineUpdate.ps1"

if not exist "%SCRIPT%" (
    echo Cannot find scripts\Invoke-XboxOfflineUpdate.ps1
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"

echo.
if "%~1"=="" pause
exit /b %CODE%
