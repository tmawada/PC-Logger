@echo off
REM ============================================================
REM  Lab PC Logger — Restart Event
REM  Trigger: Task Scheduler → At Startup (runs after boot.bat)
REM
REM  On each boot, this script checks Event ID 1074 to determine
REM  if the previous session ended with a Restart rather than
REM  a normal Shutdown.
REM ============================================================

set SCRIPT_DIR=%~dp0
python "%SCRIPT_DIR%agent.py" --event Restart
