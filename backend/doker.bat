@echo off
cmd /c "docker compose down"
@REM cmd /c "docker volume rm backend_prometheus_data"
cmd /c "docker compose up --build -d"
echo.
echo Proses selesai!
pause
