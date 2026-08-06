@echo off
REM ============================================================
REM  Lab PC Logger — Boot Event
REM  Trigger: Task Scheduler → At Startup
REM ============================================================

set SCRIPT_DIR=%~dp0
python "%SCRIPT_DIR%agent.py" --event Boot
