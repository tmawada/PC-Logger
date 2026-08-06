param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installDir = 'C:\ProgramData\LabAgent'
$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'
$shutdownScriptPath = Join-Path $shutdownDir 'lab-agent-shutdown.cmd'

Unregister-ScheduledTask -TaskName 'LabAgent-Boot' -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'LabAgent-Restart' -Confirm:$false -ErrorAction SilentlyContinue

if (Test-Path $shutdownScriptPath) {
    Remove-Item -Path $shutdownScriptPath -Force
}

if (Test-Path $installDir) {
    Remove-Item -Path $installDir -Recurse -Force
}

Write-Host 'Uninstallation completed.'
