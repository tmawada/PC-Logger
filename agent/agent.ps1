param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Boot", "Shutdown", "Restart")]
    [string]$EventType,

    [switch]$Wait,

    # Source tag folded into the message, e.g. AdminBulk, Watcher, GPO,
    # Wrapper, BootTask, Task1074. The backend has no `source` column,
    # so this keeps bulk admin actions identifiable in message text.
    [string]$Source = '',

    # Skip the slow Get-WinEvent lookup and use this message directly.
    # Used by the watcher / GPO sender which already parsed Event ID 1074.
    [string]$MessageOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'config.json'
$cacheDir = Join-Path $scriptDir 'cache'

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
$timeoutSeconds = if ($config.timeout) { [int]$config.timeout } else { 15 }
$retryCount = if ($config.retry) { [int]$config.retry } else { 3 }
$startupDelay = if ($config.startup_delay) { [int]$config.startup_delay } else { 10 }

$hostname = $env:COMPUTERNAME
if (-not $hostname) {
    $hostname = [System.Net.Dns]::GetHostName()
}

function Resolve-EventData {
    param([string]$Type)

    # Caller already knows the message (watcher/GPO parsed 1074).
    # Send immediately - no Event Log lookup on the shutdown path.
    if ($MessageOverride) {
        return @{ Type = $Type; Message = $MessageOverride }
    }

    switch ($Type) {
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
                    $resolvedType = if ($message -match 'initiated the restart') { 'Restart' }
                                   elseif ($message -match 'initiated the shutdown') { 'Shutdown' }
                                   elseif ($message -match 'power off') { 'Shutdown' }
                                   elseif ($message -match 'restart') { 'Restart' }
                                   elseif ($message -match 'shutdown') { 'Shutdown' }
                                   else { 'Restart' }
                    return @{ Type = $resolvedType; Message = $message }
                }
            } catch {
                Write-Warning "Could not read 1074 event: $($_.Exception.Message)"
            }
            return @{ Type = 'Restart'; Message = 'Restart Initiated' }
        }
        default { return @{ Type = $Type; Message = $Type } }
    }
}

$eventData = Resolve-EventData -Type $EventType
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

Write-Host "Sending $($eventData.Type) event for $hostname to $apiUrl"

# Outbox: failed shutdown-time sends are cached here and flushed on next
# Boot. Requires a UWF file exclusion on this folder (see install.ps1),
# otherwise the cache is wiped before Boot can flush it.
function Write-Cache {
    try {
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        $name = 'failed-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'),
            ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $jsonPayload | Out-File -LiteralPath (Join-Path $cacheDir $name) -Encoding ascii
        Write-Warning "Send failed, cached to $name for flush on next Boot"
    } catch {
        Write-Warning "Cache write failed: $($_.Exception.Message)"
    }
}

function Flush-Cache {
    if (-not (Test-Path $cacheDir)) { return }
    $files = Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $timeoutSeconds | Out-Null
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Host "Flushed cached event: $($f.Name)"
        } catch {
            Write-Warning "Flush failed for $($f.Name), keeping for next Boot"
        }
    }
}

# ===== Synchronous send with exponential backoff (Boot path) =====
function Send-Synchronous {
    for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
        try {
            Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec $timeoutSeconds | Out-Null
            Write-Host "Event sent successfully: $($eventData.Type)"
            return $true
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Attempt $attempt/$retryCount failed: $errorMessage"
            if ($attempt -lt $retryCount) {
                $backoff = [Math]::Pow(2, $attempt) * 1000 + (Get-Random -Minimum 0 -Maximum 500)
                Write-Host "Retrying in $backoff ms..."
                Start-Sleep -Milliseconds $backoff
            }
        }
    }
    return $false
}

# ===== Fast single-shot send (shutdown paths): 3s timeout, cache on failure =====
function Send-Quick {
    try {
        Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec 3 | Out-Null
        Write-Host "$($eventData.Type) event sent successfully"
    } catch {
        Write-Cache
    }
}

if ($EventType -eq 'Boot') {
    # Wait for the backend to be reachable (fresh boot). TCP probe, NOT
    # ICMP ping: ping is commonly firewalled while HTTP works, and a
    # failed Test-Connection would burn the whole startup_delay (10s)
    # on EVERY boot before even trying the POST.
    $uri = [Uri]$apiUrl
    $targetHost = $uri.Host
    $targetPort = if ($uri.Port -eq -1) { 80 } else { $uri.Port }
    $deadline = (Get-Date).AddSeconds($startupDelay)
    $connected = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $client = New-Object Net.Sockets.TcpClient
            $iar = $client.BeginConnect($targetHost, $targetPort, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000)) {
                $client.EndConnect($iar)
                $connected = $true
                $client.Close()
                break
            }
            $client.Close()
        } catch {}
        Start-Sleep -Milliseconds 1000
    }
    if (-not $connected) {
        Write-Warning "Backend $targetHost`:$targetPort not reachable after ${startupDelay}s, trying POST anyway"
    }

    # No jitter: the backend (replicas + PgBouncer) absorbs whole-room
    # boot bursts fine, and retry/backoff covers transient failures.
    Flush-Cache
    $success = Send-Synchronous
    exit (if ($success) { 0 } else { 1 })
}
elseif ($EventType -eq 'Shutdown' -or $EventType -eq 'Restart') {
    if ($Wait) {
        # Wrapper path (admin waiting, shutdown -t 30 window): one short attempt.
        try {
            Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec 5 | Out-Null
            Write-Host "$($eventData.Type) event sent successfully"
        } catch {
            Write-Warning "$($eventData.Type) log failed: $($_.Exception.Message)"
            Write-Cache
        }
        exit 0  # never block shutdown/restart
    } else {
        # Shutdown-time path (1074 task / GPO): NO jitter, send immediately.
        Send-Quick
        exit 0
    }
}

Write-Error "Unknown event type"
exit 1
