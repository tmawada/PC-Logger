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
$timeoutSeconds = if ($config.timeout) { [int]$config.timeout } else { 10 }
$retryCount = if ($config.retry) { [int]$config.retry } else { 3 }

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