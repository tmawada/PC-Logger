param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Requires admin (tasks + HKLM) ---
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Requires administrator privileges. Right-click -> Run as administrator."
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Backend URL comes from the kit config - never hardcoded below.
$kitConfig = Get-Content -Path (Join-Path $scriptDir 'config.json') -Raw | ConvertFrom-Json
$apiUrl = $kitConfig.api_url
Write-Host "Backend API: $apiUrl"

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
    $sourcePath = Join-Path $scriptDir $file
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $installDir -Force
    }
}

$agentPath = Join-Path $installDir 'agent.ps1'
$shutdownWrapperPath = Join-Path $installDir 'PCLogger-Shutdown.cmd'
$restartWrapperPath = Join-Path $installDir 'PCLogger-Restart.cmd'

# Boot task
$bootArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -EventType Boot -Source BootTask' -f $agentPath
$bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $bootArguments
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$bootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'PCLoggerAgent-Boot' -Action $bootAction -Trigger $bootTrigger -Principal $bootPrincipal -Settings $bootSettings -Force | Out-Null
Write-Host "[OK] Task PCLoggerAgent-Boot registered"

# Restart task (Event ID 1074). Backup path in case the persistent
# PCLoggerEventMonitor task is not running; tagged Task1074 so a
# duplicate pair (watcher + task) is identifiable in message text.
$restartArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -EventType Restart -Source Task1074' -f $agentPath
$restartAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $restartArguments
$eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$restartTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
$restartTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[(Provider[@Name=''User32''] and EventID=1074)]]</Select></Query></QueryList>'
$restartTrigger.Enabled = $true
$restartPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$restartSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'PCLoggerAgent-Restart' -Action $restartAction -Trigger $restartTrigger -Principal $restartPrincipal -Settings $restartSettings -Description 'Detects restart events and forwards them to the backend.' -Force | Out-Null
Write-Host "[OK] Task PCLoggerAgent-Restart registered"

# --- GPO shutdown sender (type-aware, fast, cache fallback) ---
# A .cmd that calls a generated gpo-send.ps1: avoids quoting hell and
# lets us read Event ID 1074 to report Restart vs Shutdown correctly.
$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'
New-Item -ItemType Directory -Path $shutdownDir -Force | Out-Null

$gpoSendPath = Join-Path $installDir 'gpo-send.ps1'
$gl = @()
$gl += 'Set-StrictMode -Version Latest'
$gl += '$ErrorActionPreference = "Continue"'
$gl += ''
$gl += '$ApiUrl = "' + $apiUrl + '"'
$gl += '$CacheDir = "' + $cacheDir + '"'
$gl += '$Hostname = $env:COMPUTERNAME'
$gl += ''
$gl += '$eventType = "Shutdown"'
$gl += '$message = "GPO Shutdown Script"'
$gl += 'try {'
$gl += '    $e = Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1074 } -MaxEvents 1 -ErrorAction Stop'
$gl += '    if ($e -and $e.Message) {'
$gl += '        $message = $e.Message.Trim().Split([Environment]::NewLine)[0]'
$gl += '        if ($message -match "restart") { $eventType = "Restart" }'
$gl += '    }'
$gl += '} catch {}'
$gl += ''
$gl += '$payload = @{ hostname = $Hostname; event_type = $eventType; message = "[GPO] " + $message; created_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff") }'
$gl += '$json = $payload | ConvertTo-Json -Compress'
$gl += ''
$gl += '# Single fast attempt with 1s timeout - fail fast for shutdown -t 0 scenarios'
$gl += 'try {'
$gl += '    Invoke-RestMethod -Uri $ApiUrl -Method Post -ContentType "application/json" -Body $json -TimeoutSec 1 | Out-Null'
$gl += '} catch {'
$gl += '    # Cache on failure - will be flushed on next boot'
$gl += '    try {'
$gl += '        if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }'
$gl += '        $json | Out-File -LiteralPath (Join-Path $CacheDir ("gpo-" + (Get-Date -Format "yyyyMMddHHmmss") + ".json")) -Encoding ascii'
$gl += '    } catch {}'
$gl += '}'
$gl | Out-File -FilePath $gpoSendPath -Encoding UTF8
Write-Host "[OK] GPO sender script created: $gpoSendPath"

$shutdownScriptPath = Join-Path $shutdownDir 'PCLogger-Shutdown.cmd'
$cmdLines = @()
$cmdLines += '@echo off'
$cmdLines += 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $gpoSendPath + '"'
$cmdLines | Out-File -FilePath $shutdownScriptPath -Encoding ascii
Write-Host "[OK] GPO shutdown script written: $shutdownScriptPath"

# Register GPO shutdown script. Correct layout is ...\Shutdown\0\0
# (slot key holds GPO metadata, child key holds Script/Parameters).
# NOTE: the Policies hive is intentionally left alone - domain GPO owns it.
$gpoSlot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown\0'
$gpoEntry = Join-Path $gpoSlot '0'
New-Item -Path $gpoSlot -Force | Out-Null
Set-ItemProperty -Path $gpoSlot -Name 'GPO-ID' -Value 'LocalGPO'
Set-ItemProperty -Path $gpoSlot -Name 'SOM-ID' -Value 'Local'
Set-ItemProperty -Path $gpoSlot -Name 'FileSysPath' -Value (Join-Path $env:WINDIR 'System32\GroupPolicy\Machine')
Set-ItemProperty -Path $gpoSlot -Name 'DisplayName' -Value 'Local Group Policy'
Set-ItemProperty -Path $gpoSlot -Name 'GPOName' -Value 'Local Group Policy'
New-Item -Path $gpoEntry -Force | Out-Null
Set-ItemProperty -Path $gpoEntry -Name 'Script' -Value $shutdownScriptPath
Set-ItemProperty -Path $gpoEntry -Name 'Parameters' -Value ''
Set-ItemProperty -Path $gpoEntry -Name 'IsPowershell' -Value 0
Set-ItemProperty -Path $gpoEntry -Name 'ExecTime' -Value '0'

# Remove stale flat-layout values from the old installer (it wrote Script
# directly on ...\Shutdown\0 instead of ...\Shutdown\0\0) - but only when
# they are ours, so other admins' scripts are never touched.
try {
    $oldScript = (Get-ItemProperty -LiteralPath $gpoSlot -Name 'Script' -ErrorAction Stop).Script
    if ($oldScript -like '*PCLogger-Shutdown.cmd*' -or $oldScript -like '*lab-agent-shutdown.cmd*') {
        foreach ($stale in @('Script', 'Parameters', 'IsPowershell', 'ExecTime')) {
            try { Remove-ItemProperty -LiteralPath $gpoSlot -Name $stale -Force -ErrorAction Stop } catch {}
        }
        Write-Host "[OK] Removed stale flat-layout GPO values"
    }
} catch {}

Write-Host "[OK] GPO Shutdown script registered"

$shutdownWrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -EventType Shutdown -Wait -Source Wrapper
if %errorlevel% neq 0 (
    echo Agent failed to send log, but continuing with shutdown...
)
shutdown -s -f -t 5
"@
Set-Content -Path $shutdownWrapperPath -Value $shutdownWrapperContent -Encoding ASCII

$restartWrapperContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -EventType Restart -Wait -Source Wrapper
if %errorlevel% neq 0 (
    echo Agent failed to send log, but continuing with restart...
)
shutdown -r -f -t 5
"@
Set-Content -Path $restartWrapperPath -Value $restartWrapperContent -Encoding ASCII

Write-Host ""
Write-Host "=== Agent installation complete ===" -ForegroundColor Green
Write-Host "Reboot once so scheduled tasks take effect."
