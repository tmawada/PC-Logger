@echo off
REM ============================================================
REM  Lab PC Logger — Shutdown Event
REM  Trigger: Group Policy → Shutdown Script
REM    Computer Configuration > Windows Settings > Scripts > Shutdown
REM ============================================================

set SCRIPT_DIR=%~dp0
python "%SCRIPT_DIR%agent.py" --event Shutdown
