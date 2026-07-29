@echo off
setlocal

set "SCRIPT=%~dp0Unraid_Appdata_Backup_Copy.ps1"

where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)

exit /b %ERRORLEVEL%
