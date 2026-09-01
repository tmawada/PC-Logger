param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = 'C:\ProgramData\PCLoggerAgent'
$logsDir = Join-Path $installDir 'logs'
$cacheDir = Join-Path $installDir 'cache'

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

$filesToCopy = @(
    'agent.ps1',
    'install.ps1',
    'uninstall.ps1',
    'config.json'
)

foreach ($file in $filesToCopy) {
    $sourcePath = Join-Path $sourceDir $file
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $installDir -Force
    }
}

$agentPath = Join-Path $installDir 'agent.ps1'
$shutdownWrapperPath = Join-Path $installDir 'PCLogger-Shutdown.cmd'
$restartWrapperPath = Join-Path $installDir 'PCLogger-Restart.cmd'

$bootArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -EventType Boot' -f $agentPath

$bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $bootArguments

$bootTrigger = New-ScheduledTaskTrigger -AtStartup

$bootPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$bootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
<<<<<<< HEAD
$bootSettings.NetworkSettings = New-ScheduledTaskNetworkSettings -RunOnlyIfNetworkAvailable
=======
>>>>>>> 9742b7cce034720922b6e065cd83f4f6e05d17e2

Register-ScheduledTask -TaskName 'PCLoggerAgent-Boot' -Action $bootAction -Trigger $bootTrigger -Principal $bootPrincipal -Settings $bootSettings -Force | Out-Null

$restartArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -EventType Restart' -f $agentPath

$restartAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $restartArguments

$eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$restartTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
$restartTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[(Provider[@Name=''User32''] and EventID=1074)]]</Select></Query></QueryList>'
$restartTrigger.Enabled = $true

$restartPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$restartSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
<<<<<<< HEAD
$restartSettings.NetworkSettings = New-ScheduledTaskNetworkSettings -RunOnlyIfNetworkAvailable
=======
>>>>>>> 9742b7cce034720922b6e065cd83f4f6e05d17e2

Register-ScheduledTask -TaskName 'PCLoggerAgent-Restart' -Action $restartAction -Trigger $restartTrigger -Principal $restartPrincipal -Settings $restartSettings -Description 'Detects restart events and forwards them to the backend.' -Force | Out-Null

$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'
New-Item -ItemType Directory -Path $shutdownDir -Force | Out-Null
$shutdownScriptPath = Join-Path $shutdownDir 'lab-agent-shutdown.cmd'
$shutdownScriptContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -EventType Shutdown
"@
Set-Content -Path $shutdownScriptPath -Value $shutdownScriptContent -Encoding ASCII

$shutdownWrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -EventType Shutdown
<<<<<<< HEAD
timeout /t 5 /nobreak >nul
=======
timeout /t 15 /nobreak >nul
>>>>>>> 9742b7cce034720922b6e065cd83f4f6e05d17e2
shutdown -s -f -t 0
"@
Set-Content -Path $shutdownWrapperPath -Value $shutdownWrapperContent -Encoding ASCII

$restartWrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -EventType Restart
<<<<<<< HEAD
timeout /t 5 /nobreak >nul
=======
timeout /t 15 /nobreak >nul
>>>>>>> 9742b7cce034720922b6e065cd83f4f6e05d17e2
shutdown -r -f -t 0
"@
Set-Content -Path $restartWrapperPath -Value $restartWrapperContent -Encoding ASCII

<<<<<<< HEAD
function Test-AgentConfig {
    $configPath = Join-Path $installDir 'config.json'
    if (-not (Test-Path $configPath)) {
        throw "Config file not found: $configPath"
    }
    try {
        $cfg = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    } catch {
        throw "Config file is not valid JSON: $configPath"
    }
    if ([string]::IsNullOrWhiteSpace($cfg.api_url)) {
        throw 'config.json must define api_url'
    }
    if ($cfg.timeout -and [int]$cfg.timeout -le 0) {
        throw 'config.json timeout must be a positive integer'
    }
    if ($cfg.retry -and [int]$cfg.retry -le 0) {
        throw 'config.json retry must be a positive integer'
    }
    Write-Host "Config OK: api_url=$($cfg.api_url) timeout=$($cfg.timeout) retry=$($cfg.retry)"
}

try {
    Test-AgentConfig
} catch {
    Write-Error "Configuration validation failed: $($_.Exception.Message)"
    exit 1
}

=======
>>>>>>> 9742b7cce034720922b6e065cd83f4f6e05d17e2
Write-Host 'Installation completed successfully.'
Write-Host "Agent installed to $installDir"
Write-Host 'Boot and restart tasks were registered.'
Write-Host "Shutdown wrapper created at $shutdownScriptPath"
Write-Host "Manual shutdown wrapper created at $shutdownWrapperPath"
Write-Host "Manual restart wrapper created at $restartWrapperPath"