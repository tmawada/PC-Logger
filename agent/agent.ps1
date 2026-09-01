param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Boot", "Shutdown", "Restart")]
    [string]$EventType
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

function Wait-NetworkReady {
    param(
        [string]$BaseUrl,
        [int]$MaxWaitSeconds = 30
    )
    $healthUrl = $BaseUrl.Replace('/api/log', '/api/status')
    for ($i = 1; $i -le $MaxWaitSeconds; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
            if ($resp.success) { return $true }
        } catch { }
        Start-Sleep -Seconds 1
    }
    return $false
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

if (-not (Wait-NetworkReady -BaseUrl $apiUrl -MaxWaitSeconds 30)) {
    Write-Error "Network not ready after 30 seconds"
    exit 1
}

$jitter = Get-Random -Minimum 0 -Maximum 5000
Start-Sleep -Milliseconds $jitter

if ($EventType -eq 'Shutdown' -or $EventType -eq 'Restart') {
    $job = Start-Job -ScriptBlock {
        param($url, $payload, $timeout, $retry)
        for ($a = 1; $a -le $retry; $a++) {
            try {
                Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec $timeout | Out-Null
                break
            } catch {
                if ($a -lt $retry) { Start-Sleep -Seconds 1 }
            }
        }
    } -ArgumentList $apiUrl, $jsonPayload, $timeoutSeconds, $retryCount
    Write-Host "$EventType event queued for async delivery"
    exit 0
}

for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
    try {
        Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec $timeoutSeconds | Out-Null
        Write-Host "Event sent successfully: $($eventData.Type)"
        exit 0
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Warning "Attempt $attempt/$retryCount failed: $errorMessage"

        if ($attempt -lt $retryCount) {
            Start-Sleep -Seconds 2
        }
    }
}

Write-Error "Failed to send event after $retryCount attempts."
exit 1