param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Boot", "Shutdown", "Restart")]
    [string]$EventType,
    [string]$Source = '', # Asal logging dari mana ada dari Watcher sm GPO
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
$timeoutSeconds = if ($config.timeout) { [int]$config.timeout } else { 15 }
# Enforce minimum 1-second timeout for fail-fast behavior
$timeoutSeconds = if ($timeoutSeconds -lt 1) { 1 } else { $timeoutSeconds }
$retryCount = if ($config.retry) { [int]$config.retry } else { 3 }
$startupDelay = if ($config.startup_delay) { [int]$config.startup_delay } else { 10 }

# Quick timeout for shutdown/restart paths - fail fast
$quickTimeout = 1
# Slightly longer timeout for cache flush operations
$flushTimeout = [int]($timeoutSeconds * 1.5)
if ($flushTimeout -lt 2) { $flushTimeout = 2 }

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

# Local diagnostics log: task-history warnings vanish, this file survives
# on disk (under the UWF-excluded agent dir) so a missing backend row can
# be traced on the PC itself. Failures are logged, successes are quiet
# except cache flush summaries.
function Write-AgentLog {
    param([string]$Level, [string]$Text)
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = '{0} [{1}] {2}' -f ((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')), $Level, $Text
        $line | Out-File -LiteralPath $logFile -Append -Encoding ascii
        if ((Get-Item -LiteralPath $logFile -ErrorAction Stop).Length -gt 512KB) {
            Get-Content -LiteralPath $logFile -Tail 500 |
                Out-File -LiteralPath $logFile -Encoding ascii
        }
    } catch {}
}

function Handle-SendError {
    param([System.Exception]$Error, [string]$EventType)
    $errorMsg = $Error.Exception.Message

    if ($errorMsg -match "timeout|The operation has timed out") {
        Write-AgentLog 'WARN' "$EventType log timed out (backend slow/unavailable after $quickTimeout sec)"
        Write-Warning "$EventType log timed out (backend slow/unavailable after $quickTimeout sec)"
    } elseif ($errorMsg -match "Could not resolve proxy|Could not resolve host") {
        Write-AgentLog 'WARN' "$EventType log failed: DNS/Proxy resolution issue"
        Write-Warning "$EventType log failed: DNS/Proxy resolution issue"
    } elseif ($errorMsg -match "400|404|403|401") {
        Write-AgentLog 'WARN' "$EventType log failed: Client error $errorMsg - checking payload/endpoint"
        Write-Warning "$EventType log failed: Client error $errorMsg - checking payload/endpoint"
    } elseif ($errorMsg -match "500|502|503|504") {
        Write-AgentLog 'WARN' "$EventType log failed: Server error $errorMsg - backend issue"
        Write-Warning "$EventType log failed: Server error $errorMsg - backend issue"
    } else {
        Write-AgentLog 'WARN' "$EventType log failed: $errorMsg"
        Write-Warning "$EventType log failed: $errorMsg"
    }
}

function Handle-FlushError {
    param([System.Exception]$Error, [string]$FileName)
    $errorMsg = $Error.Exception.Message

    if ($errorMsg -match "timeout|The operation has timed out") {
        Write-AgentLog 'WARN' "Flush timed out for $($FileName), will retry on next boot"
        Write-Warning "Flush timed out for $($FileName), will retry on next boot"
    } elseif ($errorMsg -match "400|404|403|401") {
        Write-AgentLog 'WARN' "Flush failed with client error for $($FileName): $errorMsg - removing to prevent repeat failures"
        Write-Warning "Flush failed with client error for $($FileName): $errorMsg - removing to prevent repeat failures"
        try { Remove-Item -LiteralPath (Join-Path $cacheDir $FileName) -Force } catch {}
    } elseif ($errorMsg -match "500|502|503|504") {
        Write-AgentLog 'WARN' "Flush failed with server error for $($FileName): $errorMsg, keeping for next Boot"
        Write-Warning "Flush failed with server error for $($FileName): $errorMsg, keeping for next Boot"
    } else {
        Write-AgentLog 'WARN' "Flush failed for $($FileName): $errorMsg, keeping for next Boot"
        Write-Warning "Flush failed for $($FileName): $errorMsg, keeping for next Boot"
    }
}

Write-AgentLog 'INFO' "$($eventData.Type) event start host=$hostname src=$Source"

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
        Write-AgentLog 'WARN' "Send failed, cached to $name for flush on next Boot"
        Write-Warning "Send failed, cached to $name for flush on next Boot"
    } catch {
        Write-AgentLog 'WARN' "Cache write failed: $($_.Exception.Message)"
        Write-Warning "Cache write failed: $($_.Exception.Message)"
    }
}

function Flush-Cache {
    if (-not (Test-Path $cacheDir)) { return }
    $files = Get-ChildItem -LiteralPath $cacheDir -Filter '*.json' -ErrorAction SilentlyContinue
    if (-not $files) { return }

    # Process in random order to avoid thundering herd
    $files = $files | Sort-Object { Get-Random }

    $ok = 0
    $fail = 0
    foreach ($f in $files) {
        # Staggered delay: 50-200ms between each flush attempt
        $staggerDelay = Get-Random -Minimum 50 -Maximum 200
        Start-Sleep -Milliseconds $staggerDelay

        try {
            $body = Get-Content -LiteralPath $f.FullName -Raw
            Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $flushTimeout | Out-Null
            Remove-Item -LiteralPath $f.FullName -Force
            $ok++
            Write-AgentLog 'INFO' "Flushed cached event: $($f.Name)"
            Write-Host "Flushed cached event: $($f.Name)"
        } catch {
            $fail++
            $errorMsg = $_.Exception.Message
            if ($errorMsg -match "timeout|The operation has timed out") {
                Write-AgentLog 'WARN' "Flush timed out for $($f.Name), will retry on next boot"
                Write-Warning "Flush timed out for $($f.Name), will retry on next boot"
            } elseif ($errorMsg -match "400|404|403|401") {
                Write-AgentLog 'WARN' "Flush failed with client error for $($f.Name): $errorMsg - removing to prevent repeat failures"
                Write-Warning "Flush failed with client error for $($f.Name): $errorMsg - removing to prevent repeat failures"
                try { Remove-Item -LiteralPath $f.FullName -Force } catch {}
            } elseif ($errorMsg -match "500|502|503|504") {
                Write-AgentLog 'WARN' "Flush failed with server error for $($f.Name): $errorMsg, keeping for next Boot"
                Write-Warning "Flush failed with server error for $($f.Name): $errorMsg, keeping for next Boot"
            } else {
                Write-AgentLog 'WARN' "Flush failed for $($f.Name): $errorMsg, keeping for next Boot"
                Write-Warning "Flush failed for $($f.Name): $errorMsg, keeping for next Boot"
            }
        }
    }
    Write-AgentLog 'INFO' "Flush done ok=$ok fail=$fail"
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
            Write-AgentLog 'WARN' "Boot send attempt $attempt/$retryCount failed: $errorMessage"
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

# ===== Fast send (shutdown paths): 1 attempt with 1s timeout, cache on failure =====
# At shutdown the NIC may already be going down - fail fast to avoid blocking shutdown.
function Send-Quick {
    try {
        Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec $quickTimeout | Out-Null
        Write-Host "$($eventData.Type) event sent successfully"
    } catch {
        Handle-SendError -Error $_ -EventType $eventData.Type
        Write-Cache
    }
}

if ($EventType -eq 'Boot') {
    # Removed TCP probing loop - go straight to cache flush and POST for immediate response
    Flush-Cache
    $success = Send-Synchronous
    Write-AgentLog 'INFO' "Boot send success=$success"
    exit (if ($success) { 0 } else { 1 })
}
elseif ($EventType -eq 'Shutdown' -or $EventType -eq 'Restart') {
    try {
        Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json' -Body $jsonPayload -TimeoutSec $quickTimeout | Out-Null
        Write-Host "$($eventData.Type) event sent successfully"
    } catch {
        Handle-SendError -Error $_ -EventType $eventData.Type
        Write-Cache
    }
    exit 0  # never block shutdown/restart
}

Write-Error "Unknown event type"
exit 1
