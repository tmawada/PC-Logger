param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Boot", "Shutdown", "Restart")]
    [string]$EventType,

    [switch]$Wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'config.json'

if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    exit 1
}

try {
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse config file: $configPath"
    exit 1
}

$apiUrl = $config.api_url
$timeoutSeconds = if ($config.timeout) { [int]$config.timeout } else { 5 }
$retryCount = if ($config.retry) { [int]$config.retry } else { 2 }

$hostname = $env:COMPUTERNAME
if (-not $hostname) {
    $hostname = [System.Net.Dns]::GetHostName()
}

function Get-EventMessage {
    param([string]$EventType)

    switch ($EventType) {
        'Boot' { return 'Operating System Started' }
        'Shutdown' { return 'Normal Shutdown' }
        'Restart' {
            try {
                $event = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074 } -MaxEvents 1 -ErrorAction Stop
                if ($event -and $event.Message) {
                    return ($event.Message.Trim().Split([Environment]::NewLine)[0])
                }
            } catch {
                Write-Warning "Could not read restart event: $($_.Exception.Message)"
            }
            return 'Restart'
        }
        default { return $EventType }
    }
}

function Resolve-EventData {
    param([string]$EventType)

    switch ($EventType) {
        'Boot' {
            return @{ Type = 'Boot'; Message = 'Operating System Started' }
        }
        'Shutdown' {
            return @{ Type = 'Shutdown'; Message = 'Normal Shutdown' }
        }
        'Restart' {
            try {
                $event = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074 } -MaxEvents 1 -ErrorAction Stop
                if ($event -and $event.Message) {
                    $message = $event.Message.Trim().Split([Environment]::NewLine)[0]
                    $resolvedType = if ($message -match 'initiated the restart') {
                        'Restart'
                    } elseif ($message -match 'initiated the shutdown') {
                        'Shutdown'
                    } elseif ($message -match 'restart') {
                        'Restart'
                    } elseif ($message -match 'shutdown') {
                        'Shutdown'
                    } else {
                        'Restart'
                    }
                    return @{ Type = $resolvedType; Message = $message }
                }
            } catch {
                Write-Warning "Could not read 1074 event: $($_.Exception.Message)"
            }
            return @{ Type = 'Restart'; Message = 'Restart Initiated' }
        }
        default {
            return @{ Type = $EventType; Message = $EventType }
        }
    }
}

$eventData = Resolve-EventData -EventType $EventType

$message = $eventData.Message


$createdAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')

$payload = @{
    hostname = $hostname
    event_type = $eventData.Type
    message = $message
    created_at = $createdAt
}

$jsonPayload = $payload | ConvertTo-Json -Compress

Write-Host "Sending $EventType event for $hostname to $apiUrl"

# Only apply jitter for scheduled tasks (not -Wait), to spread 41 PCs
if (-not $Wait) {
    $jitter = Get-Random -Minimum 0 -Maximum 30000
    Write-Host "Jitter: $jitter ms"
    Start-Sleep -Milliseconds $jitter
}

# Synchronous send with full retry (used for Boot only)
function Send-Synchronous {
    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
        try {
            Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec $timeoutSeconds | Out-Null
            Write-Host "Event sent successfully: $($eventData.Type)"
            return $true
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Attempt $attempt/$retryCount failed: $errorMessage"
            if ($attempt -lt $retryCount) { Start-Sleep -Seconds 2 }
        }
    }
    return $false
}

# Fire-and-forget async (used for Shutdown/Restart from scheduled tasks)
function Send-Async {
    Start-Job -ScriptBlock {
        param($url, $payload, $timeout)
        try {
            Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec $timeout -ErrorAction SilentlyContinue
        } catch { }
    } -ArgumentList $apiUrl, $jsonPayload, $timeoutSeconds | Out-Null
    Write-Host "$EventType event dispatched (async)"
    Start-Sleep -Milliseconds 500
}

if ($EventType -eq 'Boot') {
    # Boot: always synchronous with full retry
    $success = Send-Synchronous
    exit (if ($success) { 0 } else { 1 })
}
elseif ($EventType -eq 'Shutdown') {
    if ($Wait) {
        # Manual wrapper: synchronous with SHORT timeout (admin waiting), 1 retry max
        for ($attempt = 1; $attempt -le 1; $attempt++) {
            try {
                Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec 3 | Out-Null
                Write-Host "Shutdown event sent successfully"
                exit 0
            } catch {
                Write-Warning "Shutdown log failed: $($_.Exception.Message)"
            }
        }
        exit 0  # Continue shutdown even if log fails
    } else {
        # Group Policy / scheduled: async fire-and-forget
        Send-Async
        exit 0
    }
}
elseif ($EventType -eq 'Restart') {
    if ($Wait) {
        # Manual wrapper: synchronous with SHORT timeout (admin waiting), 1 retry max
        for ($attempt = 1; $attempt -le 1; $attempt++) {
            try {
                Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec 3 | Out-Null
                Write-Host "Restart event sent successfully"
                exit 0
            } catch {
                Write-Warning "Restart log failed: $($_.Exception.Message)"
            }
        }
        exit 0  # Continue restart even if log fails
    } else {
        # Event 1074 trigger: synchronous with short timeout (fires at initiation)
        for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
            try {
                Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec 3 | Out-Null
                Write-Host "Restart event sent successfully"
                exit 0
            } catch {
                if ($attempt -lt $retryCount) { Start-Sleep -Milliseconds 500 }
            }
        }
        Write-Warning "Restart event failed after $retryCount attempts"
        exit 0
    }
}

Write-Error "Unknown event type"
exit 1