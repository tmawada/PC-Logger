@echo off
setlocal
rem ============================================================
rem  PCLogger clean uninstaller (wrapper)
rem  Runs from ANY drive / folder. Self-elevates to admin.
rem
rem  Usage: uninstall.bat [/quiet]
rem    /quiet  - accepted for backwards compat, behaves the same (never pauses)
rem
rem  Bulk example (from admin PC, after copying this folder):
rem    psexec \\LAB-601-01 -s -c uninstall.bat
rem ============================================================

set "QUIET=0"
if /i "%~1"=="/quiet" set "QUIET=1"
if /i "%~1"=="-quiet" set "QUIET=1"

rem --- Self-elevate (preserve /quiet) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    if "%QUIET%"=="1" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '/quiet'"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    )
    exit /b 0
)

rem --- Run the real uninstaller living next to this bat (%~dp0 = own folder, any volume) ---
if "%QUIET%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Quiet
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
)
set "EC=%errorlevel%"

echo.
if "%EC%"=="0" (
    echo [DONE] Uninstall clean, exit 0
    exit /b 0
) else (
    echo [DONE] Uninstall finished with leftovers, exit %EC%
    exit /b %EC%
)
