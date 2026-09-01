param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installDir = 'C:\ProgramData\LabAgent'
$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'
$shutdownScriptPath = Join-Path $shutdownDir 'lab-agent-shutdown.cmd'
$shutdownWrapperPath = Join-Path $installDir 'PCLogger-Shutdown.cmd'
$restartWrapperPath = Join-Path $installDir 'PCLogger-Restart.cmd'

Unregister-ScheduledTask -TaskName 'PCLoggerAgent-Boot' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'PCLoggerAgent-Restart' -Confirm:$false -ErrorAction SilentlyContinue

if (Test-Path $shutdownScriptPath) {
    Remove-Item -Path $shutdownScriptPath -Force
}

if (Test-Path $shutdownWrapperPath) {
    Remove-Item -Path $shutdownWrapperPath -Force
}

if (Test-Path $restartWrapperPath) {
    Remove-Item -Path $restartWrapperPath -Force
}

if (Test-Path $installDir) {
    Remove-Item -Path $installDir -Recurse -Force
}

Write-Host 'Uninstallation completed.'
