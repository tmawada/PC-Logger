@echo off
title PCLogger Deployment Check
cls
echo.
echo ==========================================
echo   PCLogger Deployment Check
echo ==========================================
echo.
setlocal enabledelayedexpansion

set "AGENT_DIR=C:\ProgramData\PCLoggerAgent"

rem --- Backend URL comes from the deployed config, not hardcoded ---
set "API_URL="
set "CONFIG_FILE=%AGENT_DIR%\config.json"
if not exist "%CONFIG_FILE%" set "CONFIG_FILE=%~dp0config.json"
if exist "%CONFIG_FILE%" (
    for /f "delims=" %%U in ('powershell -NoProfile -Command "(Get-Content -LiteralPath '%CONFIG_FILE%' -Raw | ConvertFrom-Json).api_url" 2^>nul') do set "API_URL=%%U"
)


set "PASS=0"
set "FAIL=0"

echo Backend: %API_URL%
echo.

echo 1. Checking Agent Directory...
if exist "%AGENT_DIR%" (
    echo   [OK] Agent directory exists
    set /a PASS+=1
) else (
    echo   [MISSING] Agent directory not found
    set /a FAIL+=1
)

echo.
echo 2. Checking Agent Files...
set "MISSING="
for %%F in (agent.ps1 config.json install.ps1 uninstall.ps1 gpo-send.ps1) do (
    if not exist "%AGENT_DIR%\%%F" set "MISSING=!MISSING! %%F"
)
if defined MISSING (
    echo   [MISSING] Files not found:!MISSING!
    set /a FAIL+=1
) else (
    echo   [OK] All 5 files present
    set /a PASS+=1
)

echo.
echo 3. Checking Config.json...
if exist "%AGENT_DIR%\config.json" (
    echo   [OK] config.json exists
    set /a PASS+=1
) else (
    echo   [MISSING] config.json not found
    set /a FAIL+=1
)

echo.
echo 4. Checking Scheduled Tasks...
for %%T in (PCLoggerAgent-Boot PCLoggerAgent-Restart PCLoggerEventMonitor) do (
    schtasks /query /tn "%%T" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK] %%T EXISTS
        set /a PASS+=1
    ) else (
        echo   [MISSING] %%T not found
        set /a FAIL+=1
    )
)

echo.
echo 5. Checking Event Monitor Script...
if exist "%AGENT_DIR%\event-monitor.ps1" (
    echo   [OK] event-monitor.ps1 exists
    set /a PASS+=1
) else (
    echo   [MISSING] event-monitor.ps1 not found
    set /a FAIL+=1
)

echo.
echo 6. Checking GPO Shutdown Script...
if exist "%WINDIR%\System32\GroupPolicy\Machine\Scripts\Shutdown\PCLogger-Shutdown.cmd" (
    echo   [OK] GPO shutdown script exists
    set /a PASS+=1
) else (
    echo   [MISSING] GPO shutdown script not found
    set /a FAIL+=1
)

echo.
echo 7. Testing API Connectivity...
echo   Sending test log to %API_URL% ...
powershell -NoProfile -Command "$ok=$false; try { $r = Invoke-RestMethod -Uri '%API_URL%' -Method Post -ContentType 'application/json' -Body ('{\"hostname\":\"' + $env:COMPUTERNAME + '\",\"event_type\":\"Boot\",\"message\":\"Check\",\"created_at\":\"' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff') + '\"}') -TimeoutSec 5; $ok=$true } catch {}; if ($ok) { exit 0 } else { exit 1 }"
if !errorlevel! equ 0 (
    echo   [OK] API reachable
    set /a PASS+=1
) else (
    echo   [MISSING] API unreachable
    set /a FAIL+=1
)

echo.
echo ==========================================
echo             SUMMARY
echo ==========================================
echo   Passed: %PASS%
echo   Failed: %FAIL%
echo.
if %FAIL% gtr 0 (
    echo   To fix, run as Administrator:
    echo     main.bat  - from this kit folder
)
echo.
if %FAIL% equ 0 (
    echo [DONE] All 9 checks passed.
    endlocal & exit /b 0
) else (
    echo [DONE] Some checks failed - see above.
    endlocal & exit /b 1
)
