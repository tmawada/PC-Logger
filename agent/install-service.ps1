<#
.SYNOPSIS
Installs PCLogger event monitor as a Scheduled Task (runs at startup, monitors Event ID 1074).

.DESCRIPTION
Persistent watcher that is already running BEFORE a student hits Restart /
Shutdown, so it can POST immediately with a short timeout instead of
cold-starting PowerShell while Windows is tearing down.

Watcher events are tagged [Watcher]; the PCLoggerAgent-Restart 1074 task
from install.ps1 is tagged [Task1074] - if both fire for one restart the
pair is identifiable in message text.
#>

param(
    [string]$TaskName = "PCLoggerEventMonitor"
)

$ErrorActionPreference = 'Stop'

$groups = (whoami /groups).Split() | Where-Object { $_ -match 'S-1-5-32-544' }
if ($groups.Count -eq 0) {
    Write-Error "Requires administrator privileges."
    exit 1
}

$agentDir = "C:\ProgramData\PCLoggerAgent"
$configPath = Join-Path $agentDir "config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "Config not found at $configPath (run install.ps1 first)"
    exit 1
}

$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
$apiUrl = $config.api_url
$cacheDir = Join-Path $agentDir "cache"

Write-Host "=== PCLogger Event Monitor Installer ==="
Write-Host "Task Name: $TaskName"
Write-Host "API URL: $apiUrl"
Write-Host ""

# Write event-monitor.ps1 line by line to avoid here-string escaping issues
$monitorScriptPath = Join-Path $agentDir "event-monitor.ps1"
$lines = @()
$lines += 'Set-StrictMode -Version Latest'
$lines += '$ErrorActionPreference = "Continue"'
$lines += ''
$lines += '$ApiUrl = "' + $apiUrl + '"'
$lines += '$CacheDir = "' + $cacheDir + '"'
$lines += '$Hostname = $env:COMPUTERNAME'
$lines += ''
$lines += 'function Send-Event {'
$lines += '    param([string]$EventType, [string]$Message)'
$lines += '    $payload = @{'
$lines += '        hostname = $Hostname'
$lines += '        event_type = $EventType'
$lines += '        message = "[Watcher] " + $Message'
$lines += '        created_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff")'
$lines += '    }'
$lines += '    $json = $payload | ConvertTo-Json -Compress'
$lines += '    try {'
$lines += '        Invoke-RestMethod -Uri $ApiUrl -Method Post -ContentType "application/json" -Body $json -TimeoutSec 3 | Out-Null'
$lines += '    } catch {'
$lines += '        try {'
$lines += '            if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }'
$lines += '            $json | Out-File -LiteralPath (Join-Path $CacheDir ("mon-" + (Get-Date -Format "yyyyMMddHHmmss") + ".json")) -Encoding ascii'
$lines += '        } catch {}'
$lines += '    }'
$lines += '}'
$lines += ''
$lines += '# XPath-filtered query: the watcher only wakes for Event ID 1074.'
$lines += '$eventQuery = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery -ArgumentList "System", ([System.Diagnostics.Eventing.Reader.PathType]::LogName), "*[System[(EventID=1074)]]"'
$lines += '$watcher = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher -ArgumentList $eventQuery'
$lines += '$watcher.add_EventRecordWritten({'
$lines += '    param($sender, $e)'
$lines += '    try {'
$lines += '        $record = $e.EventRecord'
$lines += '        if ($record -eq $null) { return }'
$lines += '        $msg = $null'
$lines += '        try { $msg = $record.FormatDescription($null) } catch { return }'
$lines += '        if ([string]::IsNullOrWhiteSpace($msg)) { return }'
$lines += '        $short = $msg.Trim().Split([Environment]::NewLine)[0]'
$lines += '        if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }'
$lines += '        if ($msg -match "restart") { Send-Event -EventType "Restart" -Message ("Event 1074: " + $short) }'
$lines += '        elseif ($msg -match "shutdown" -or $msg -match "power off") { Send-Event -EventType "Shutdown" -Message ("Event 1074: " + $short) }'
$lines += '    } catch {}'
$lines += '})'
$lines += '$watcher.Enabled = $true'
$lines += ''
$lines += '# Opportunistic flush: cached shutdown/restart events are normally'
$lines += '# flushed by the Boot task, but if the network was not up yet at'
$lines += '# boot, this delivers them within minutes instead of waiting a'
$lines += '# whole power cycle for the next Boot.'
$lines += 'function Flush-Cache {'
$lines += '    try {'
$lines += '        if (-not (Test-Path $CacheDir)) { return }'
$lines += '        $files = Get-ChildItem -LiteralPath $CacheDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name'
$lines += '        foreach ($f in $files) {'
$lines += '            try {'
$lines += '                $body = Get-Content -LiteralPath $f.FullName -Raw'
$lines += '                Invoke-RestMethod -Uri $ApiUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5 | Out-Null'
$lines += '                Remove-Item -LiteralPath $f.FullName -Force'
$lines += '            } catch {}'
$lines += '        }'
$lines += '    } catch {}'
$lines += '}'
$lines += 'Flush-Cache'
$lines += ''
$lines += '$ticks = 0'
$lines += 'while ($true) {'
$lines += '    Start-Sleep -Seconds 30'
$lines += '    $ticks++'
$lines += '    if ($ticks -ge 10) { $ticks = 0; Flush-Cache }'
$lines += '}'

$lines | Out-File -FilePath $monitorScriptPath -Encoding UTF8
Write-Host "[OK] Event monitor script created: $monitorScriptPath"

# Remove old task (ignore error if it doesn't exist)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
schtasks /delete /tn $TaskName /f | Out-Null
$ErrorActionPreference = $prevEAP

# Create scheduled task
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorScriptPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "PCLogger - Monitors Event ID 1074 for shutdown/restart events" -Force | Out-Null

Write-Host "[OK] Scheduled task '$TaskName' registered"

Start-ScheduledTask -TaskName $TaskName
Write-Host "[OK] Task started"

Write-Host ""
Write-Host "=== Installation Complete ==="
Write-Host "Task '$TaskName' will start automatically at boot."
Write-Host "It monitors Event ID 1074 (Start menu, hotkeys, GPO shutdowns/restarts)."
Write-Host ""
Write-Host "Manage:"
Write-Host "  schtasks /query /tn $TaskName"
Write-Host "  schtasks /run /tn $TaskName"
Write-Host "  schtasks /end /tn $TaskName"
Write-Host "  schtasks /delete /tn $TaskName /f"
