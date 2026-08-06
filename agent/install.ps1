param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = 'C:\ProgramData\LabAgent'
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

$bootAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File \"$installDir\agent.ps1\" -EventType Boot"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$bootSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'LabAgent-Boot' -Action $bootAction -Trigger $bootTrigger -Principal $bootPrincipal -Settings $bootSettings -Force | Out-Null

$restartTaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>LabAgent</Author>
    <Description>Detects restart events and forwards them to the backend.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[(Provider[@Name='User32'] and EventID=1074)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$installDir\agent.ps1" -EventType Restart</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName 'LabAgent-Restart' -Xml $restartTaskXml -Force | Out-Null

$shutdownDir = Join-Path $env:WINDIR 'System32\GroupPolicy\Machine\Scripts\Shutdown'
New-Item -ItemType Directory -Path $shutdownDir -Force | Out-Null
$shutdownScriptPath = Join-Path $shutdownDir 'lab-agent-shutdown.cmd'
$shutdownScriptContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$installDir\agent.ps1" -EventType Shutdown
"@
Set-Content -Path $shutdownScriptPath -Value $shutdownScriptContent -Encoding ASCII

Write-Host 'Installation completed successfully.'
Write-Host "Agent installed to $installDir"
Write-Host 'Boot and restart tasks were registered.'
Write-Host "Shutdown wrapper created at $shutdownScriptPath"
