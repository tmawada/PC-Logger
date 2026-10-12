@echo off
title PCLogger Agent + Service Installer
cls
echo.
echo ==========================================
echo   PCLogger Agent + Service Installer
echo ==========================================
echo.
echo Installing PCLogger Agent...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %errorlevel% equ 0 (
    echo.
    echo [SUCCESS] Agent installed.
) else (
    echo.
    echo [FAILED] Agent installation failed.
    echo Please check install.ps1 for errors.
    echo Run this window as Administrator.
    pause
    exit /b 1
)
echo.
echo.
echo Installing PCLogger Event Monitor...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-service.ps1"
if %errorlevel% equ 0 (
    echo.
    echo [SUCCESS] Event monitor installed.
) else (
    echo.
    echo [FAILED] Event monitor installation failed.
    echo Please check install-service.ps1 for errors.
    pause
    exit /b 1
)
echo.
echo.
echo ==========================================
echo   Installation Complete
echo ==========================================
echo.
echo PCLogger Agent: Installed and running
echo PCLogger Event Monitor: Installed and running
echo.
echo The agent will now capture:
echo - Boot events (scheduled task at startup)
echo - Restart/Shutdown from Start menu, hotkeys, GPO (Event ID 1074 watcher)
echo - Restart/Shutdown from manual wrappers (PCLogger-*.cmd)
echo.
echo NOTE: reboot once so scheduled tasks take effect.
echo.
echo To verify the event monitor is running:
echo   schtasks /query /tn PCLoggerEventMonitor
echo.
echo To test immediately:
echo   shutdown -r -f -t 0  (then check backend logs)
echo.
rem Success: close automatically.
exit /b 0
