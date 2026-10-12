param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Boot", "Shutdown", "Restart")]
    [string]$EventType,

    [string]$Source = '',

    [string]$MessageOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'config.json'
$cacheDir = Join-Path $scriptDir 'cache'
$logDir = Join-Path $scriptDir 'logs'
$logFile = Join-Path $logDir 'agent.log'

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
$startupDelay = if ($config.startup_delay) { [int]$config.startup_delay } else { 5 }

$hostname = $env:COMPUTERNAME
if (-not $hostname) {
    $hostname = [System.Net.Dns]::GetHostName()
}

function Get-EventMessage {
    param([string]$Type)

    if ($MessageOverride) {
        return @{ Type = $Type; Message = $MessageOverride }
    }

    switch ($Type) {
        'Boot' { return @{ Type = 'Boot'; Message = 'Operating System Started' } }
        'Shutdown' { return @{ Type = 'Shutdown'; Message = 'Normal Shutdown' } }
        'Restart' {
            try {
                $event = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074 } -MaxEvents 1 -ErrorAction Stop
                if ($event -and $event.Message) {
                    $message = $event.Message.Trim().Split([Environment]::NewLine)[0]
                    $resolvedType = if ($message -match 'initiated the restart') { 'Restart' }
                                   elseif ($message -match 'initiated the shutdown') { 'Shutdown' }
                                   elseif ($message -match 'power off') { 'Shutdown' }
                                   elseif ($message -match 'restart') { 'Restart' }
                                   elseif ($message -match 'shutdown') { 'Shutdown' }
                                   else { 'Restart' }
                    return @{ Type = $resolvedType; Message = $message }
                }
            } catch { }
            return @{ Type = 'Restart'; Message = 'Restart Initiated' }
        }
        default { return @{ Type = $Type; Message = $Type } }
    }
}

$eventData = Get-EventMessage -Type $EventType
$message = $eventData.Message
if ($Source) {
    $message = "[$Source] $message"
}
$createdAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')

$payload = @{
    hostname = $hostname
    event_type = $eventData.Type
    message = $message
    created_at = $createdAt
}

$jsonPayload = $payload | ConvertTo-Json -Compress

function Write-Log {
    param([string]$Level, [string]$Text)
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} [{1}] {2}' -f ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')), $Level, $Text
        $line | Out-File -LiteralPath $logFile -Append -Encoding ascii
        if ((Get-Item -LiteralPath $logFile -ErrorAction Stop).Length -gt 256KB) {
            Get-Content -LiteralPath $logFile -Tail 250 |
                Out-File -LiteralPath $logFile -Encoding ascii
        }
    } catch {}
}

function Send-WithCache {
    param([string]$Url, [string]$Payload, [int]$Timeout, [string]$EventTypeForLog)

    try {
        Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $Payload -TimeoutSec $Timeout | Out-Null
        Write-Log 'INFO' "$EventTypeForLog event sent successfully"
        return $true
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Log 'WARN' "$EventTypeForLog failed: $errorMsg"

        # Cache failed event
        try {
            if (-not (Test-Path $cacheDir)) {
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            }
            $name = 'failed-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
            $Payload | Out-File -LiteralPath (Join-Path $cacheDir $name) -Encoding ascii
            Write-Log 'WARN' "Event cached to $name for later retry"
        } catch {
            Write-Log 'WARN' "Failed to write cache: $($_.Exception.Message)"
        }
        return $false
    }
}

Write-Log 'INFO' "Processing $EventType event for host=$hostname source='$Source'"

if ($EventType -eq 'Boot') {
    # Boot: Flush cache first, then send with retries
    if (Test-Path $cacheDir) {
        $cachedFiles = Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -ErrorAction SilentlyContinue
        if ($cachedFiles) {
            foreach ($cacheFile in $cachedFiles) {
                try {
                    $cachedPayload = Get-Content -LiteralPath $cacheFile.FullName -Raw
                    if (Send-WithCache -Url $apiUrl -Payload $cachedPayload -Timeout $timeoutSeconds -EventTypeForLog "Cached Boot") {
                        Remove-Item -LiteralPath $cacheFile.FullName -Force
                    }
                } catch {
                    Write-Log 'WARN' "Failed to process cached file $($cacheFile.Name): $($_.Exception.Message)"
                }
            }
        }
    }

    # Send current event with retries
    $success = $false
    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
        if (Send-WithCache -Url $apiUrl -Payload $jsonPayload -Timeout $timeoutSeconds -EventTypeForLog "Boot attempt $attempt") {
            $success = $true
            break
        }
        if ($attempt -lt $retryCount) {
            $backoff = [Math]::Pow(2, $attempt) * 500
            Start-Sleep -Milliseconds $backoff
        }
    }

    exit (if ($success) { 0 } else { 1 })
}
elseif ($EventType -eq 'Shutdown' -or $EventType -eq 'Restart') {
    # Shutdown/Restart: Send once quickly, cache on failure, don't block
    Send-WithCache -Url $apiUrl -Payload $jsonPayload -Timeout 1 -EventTypeForLog $EventType
    exit 0
}
else {
    Write-Log 'ERROR' "Unknown event type: $EventType"
    exit 1
}