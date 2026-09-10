<#
.SYNOPSIS
  PCLogger Agent clean uninstaller. Drive-independent: uses absolute
  paths only ($env:ProgramData / $env:WINDIR), so it runs from any
  volume, any working directory, or via WinRM/PsExec.

.USAGE
  Double-click uninstall.bat, or:
    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-Quiet]

  Bulk (41 PCs):
    Invoke-Command -ComputerName (Get-Content pcs.txt) -FilePath .\uninstall.ps1
  or copy this folder to each PC and run: uninstall.bat /quiet

.NOTES
  Idempotent: safe to run twice. Never throws on missing items.
  Covers every artifact the installers create:
    - Scheduled tasks: PCLoggerAgent-Boot, PCLoggerAgent-Restart, PCLoggerEventMonitor
    - Service: PCLoggerService (vestigial, removed if present)
    - GPO shutdown script files (both historic names)
    - GPO registry keys (both hives, targeted at our entries only)
    - Agent dir: agent.ps1, config.json, event-monitor.ps1, gpo-send.ps1,
      wrappers, cache\, logs\
    - UWF file exclusion
#>

param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$exitCode = 0

function Write-Step([string]$Msg) { Write-Host "`n== $Msg ==" -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Skip([string]$Msg) { Write-Host "[SKIP] $Msg" -ForegroundColor DarkYellow }
function Write-Warn([string]$Msg) { Write-Host "[WARN] $Msg" -ForegroundColor Yellow }

# --- 0. Admin check (uninstall touches HKLM + tasks + service) ---
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn "Not running as Administrator. Re-run via uninstall.bat (self-elevates) or an elevated shell."
    exit 2
}

# --- Absolute target paths (never relative, never $PSScriptRoot for targets) ---
$agentDir = Join-Path $env:ProgramData 'PCLoggerAgent'
if (-not (Test-Path $agentDir) -and (Test-Path 'C:\ProgramData\PCLoggerAgent')) {
    $agentDir = 'C:\ProgramData\PCLoggerAgent'
}
$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'

Write-Host "PCLogger clean uninstall" -ForegroundColor Cyan
Write-Host "Agent dir : $agentDir"
Write-Host "GPO dir   : $shutdownDir"

# --- 1. Scheduled tasks ---
Write-Step "Scheduled tasks"
@('PCLoggerAgent-Boot', 'PCLoggerAgent-Restart', 'PCLoggerEventMonitor') | ForEach-Object {
    $name = $_
    try {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Ok "Task removed: $name"
    } catch {
        # Fallback for systems where the Task module behaves differently
        schtasks /delete /tn $name /f 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Task removed via schtasks: $name" }
        else { Write-Skip "Task not present: $name" }
    }
}

# --- 2. Windows service (vestigial PCLoggerService; nothing installs it, remove if found) ---
Write-Step "Windows service"
try {
    $svc = Get-Service -Name 'PCLoggerService' -ErrorAction Stop
    try { Stop-Service -Name 'PCLoggerService' -Force -ErrorAction SilentlyContinue } catch {}
    sc.exe delete PCLoggerService 2>$null | Out-Null
    Write-Ok "Service removed: PCLoggerService"
} catch {
    sc.exe delete PCLoggerService 2>$null | Out-Null
    Write-Skip "Service not present: PCLoggerService"
}

# --- 3. GPO shutdown script files (current + historic name) ---
Write-Step "GPO shutdown script files"
@('PCLogger-Shutdown.cmd', 'lab-agent-shutdown.cmd') | ForEach-Object {
    $p = Join-Path $shutdownDir $_
    if (Test-Path -LiteralPath $p) {
        try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Write-Ok "Removed $p" }
        catch { Write-Warn "Could not remove $p : $($_.Exception.Message)"; $script:exitCode = 1 }
    } else {
        Write-Skip "Not present: $p"
    }
}

# --- 4. GPO registry entries (targeted: only subkeys that reference our scripts) ---
Write-Step "GPO registry entries"
$ourScripts = @('PCLogger-Shutdown.cmd', 'lab-agent-shutdown.cmd')
$gpoRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Shutdown'
)
foreach ($root in $gpoRoots) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Skip "Not present: $root"; continue }
    $removedAny = $false
    try {
        $children = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            $removeThis = $false
            # Check Script value on the child and on grand-children (\0\0 layout)
            $toInspect = @($child.PSPath) + @(
                Get-ChildItem -LiteralPath $child.PSPath -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty PSPath
            )
            foreach ($p in $toInspect) {
                try {
                    $v = (Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue).Script
                    if ($v -and ($ourScripts | Where-Object { $v -like "*$_*" })) { $removeThis = $true; break }
                } catch {}
            }
            if ($removeThis) {
                Remove-Item -LiteralPath $child.PSPath -Recurse -Force -ErrorAction Stop
                Write-Ok "Removed $($child.PSPath)"
                $removedAny = $true
            }
        }
    } catch { Write-Warn "Could not inspect ${root}: $($_.Exception.Message)"; $script:exitCode = 1; continue }
    if (-not $removedAny) {
        # No PCLogger entries found under this root: check legacy flat layout
        # (old installer wrote Script directly on ...\Shutdown\0). Only touch
        # it when it is ours, otherwise leave other admins' scripts alone.
        try {
            $flat = Join-Path $root '0'
            if (Test-Path -LiteralPath $flat) {
                $v = (Get-ItemProperty -LiteralPath $flat -ErrorAction SilentlyContinue).Script
                if ($v -and ($ourScripts | Where-Object { $v -like "*$_*" })) {
                    Remove-Item -LiteralPath $flat -Recurse -Force -ErrorAction Stop
                    Write-Ok "Removed legacy key $flat"
                    $removedAny = $true
                }
            }
        } catch { Write-Warn "Could not clean legacy key under ${root}: $($_.Exception.Message)" }
    }
    if (-not $removedAny) { Write-Skip "No PCLogger entries under $root (left untouched)" }
}

# --- 5. Agent directory ---
Write-Step "Agent directory"
if (Test-Path -LiteralPath $agentDir) {
    # Keep a config backup in TEMP so reinstall can reuse the backend IP
    try {
        $cfg = Join-Path $agentDir 'config.json'
        if (Test-Path -LiteralPath $cfg) {
            Copy-Item -LiteralPath $cfg -Destination (Join-Path $env:TEMP 'PCLogger-config-backup.json') -Force -ErrorAction SilentlyContinue
            Write-Host "  config.json backed up to $env:TEMP\PCLogger-config-backup.json" -ForegroundColor DarkYellow
        }
    } catch {}
    try {
        Remove-Item -LiteralPath $agentDir -Recurse -Force -ErrorAction Stop
        Write-Ok "Removed $agentDir"
    } catch { Write-Warn "Could not remove ${agentDir}: $($_.Exception.Message)"; $script:exitCode = 1 }
} else {
    Write-Skip "Not present: $agentDir"
}

# --- 6. UWF exclusion (harmless when uwfmgr absent / UWF off) ---
Write-Step "UWF exclusion"
try {
    $uwf = Get-Command uwfmgr.exe -ErrorAction Stop
    & uwfmgr.exe file remove-exclusion $agentDir 2>$null | Out-Null
    Write-Ok "UWF exclusion removed for $agentDir (takes effect after reboot)"
} catch {
    Write-Skip "uwfmgr not available, nothing to remove"
}

# --- 7. Verify ---
Write-Step "Verify"
$problems = @()
foreach ($t in @('PCLoggerAgent-Boot', 'PCLoggerAgent-Restart', 'PCLoggerEventMonitor')) {
    schtasks /query /tn $t 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $problems += "Task still exists: $t" }
}
if (Test-Path -LiteralPath $agentDir) { $problems += "Dir still exists: $agentDir" }
foreach ($f in @('PCLogger-Shutdown.cmd', 'lab-agent-shutdown.cmd')) {
    if (Test-Path -LiteralPath (Join-Path $shutdownDir $f)) { $problems += "GPO file still exists: $f" }
}
if ($problems.Count -eq 0 -and $exitCode -eq 0) {
    Write-Host "`nUninstall complete: everything gone." -ForegroundColor Green
} else {
    $problems | ForEach-Object { Write-Warn $_ }
    Write-Host "`nUninstall finished with leftovers (exit 1)." -ForegroundColor Yellow
    $exitCode = 1
}

Write-Host "`nNOTE (UWF labs): if the filter is ON, deletions sit in the overlay and reappear after reboot." -ForegroundColor DarkYellow
Write-Host "For a permanent uninstall: uwfmgr filter disable -> reboot -> uninstall -> reboot." -ForegroundColor DarkYellow

exit $exitCode
