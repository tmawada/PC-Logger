@echo off
cmd /c "docker compose down"
cmd /c "docker volume rm backend_prometheus_data"
cmd /c "docker compose up --build -d"
echo.
echo Proses selesai!
pause
