<#
.SYNOPSIS
    Registers the nightly PZ update/restart as a Scheduled Task that fires on a
    fixed UTC time, immune to daylight saving.

.DESCRIPTION
    Task Scheduler's PowerShell cmdlets build triggers in LOCAL time, which drift
    by an hour twice a year. This registers the task from raw XML with a
    StartBoundary carrying a 'Z' suffix, which Task Scheduler treats as UTC and
    keeps synchronised across time zones.

.PARAMETER UtcTime
    24h UTC time, "HH:mm". Default 14:00 UTC = 9:00 AM Eastern Standard Time.
    NOTE: Eastern is UTC-4 during daylight saving (Mar-Nov), so 14:00 UTC lands
    at 10:00 AM local for most of the year. That is what "always UTC" means -
    the clock time in the UK is fixed, the local time shifts. If he would rather
    it always be 9 AM *local*, drop the -Utc switch below.

.EXAMPLE
    .\Register-PZUpdateTask.ps1 -UtcTime "14:00"
    .\Register-PZUpdateTask.ps1 -UtcTime "07:30" -RunAsUser "DESKTOP-ABC\Steve"
#>
[CmdletBinding()]
param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$UtcTime   = '14:00',
    [int]$CheckIntervalMinutes = 15,
    [string]$TaskName  = 'PZ Server Daily Restart',
    [string]$CheckTaskName = 'PZ Server Update Watcher',
    [string]$ScriptPath,
    [string]$ConfigPath,
    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME",
    [string]$PowerShellExe,
    [switch]$Local     # register in local time instead of UTC
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside param() defaults on Windows PowerShell 5.1.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $ScriptPath) { $ScriptPath = Join-Path $ScriptDir 'Update-PZServer.ps1' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'pzserver.json' }

# Prefer PowerShell 7 (pwsh.exe) when it is installed; fall back to Windows
# PowerShell 5.1. The scripts run on both, but 7 is the better host.
if (-not $PowerShellExe) {
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { $PowerShellExe = 'pwsh.exe' }
    else { $PowerShellExe = 'powershell.exe' }
}
Write-Host "Tasks will run under: $PowerShellExe"
if ($PowerShellExe -eq 'powershell.exe') {
    Write-Host "  (PowerShell 7 not found. Install with: winget install --id Microsoft.PowerShell -e)"
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }

$h, $m = $UtcTime.Split(':')
if ($Local) {
    $boundary = (Get-Date -Hour $h -Minute $m -Second 0).ToString('yyyy-MM-ddTHH:mm:ss')
    $desc = "$UtcTime local"
} else {
    $boundary = ([datetime]::UtcNow.Date.AddHours([int]$h).AddMinutes([int]$m)).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'
    $desc = "$UtcTime UTC"
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Project Zomboid dedicated server: warn players, save, update via SteamCMD, restart. Runs at $desc.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$boundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$RunAsUser</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PowerShellExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" -ConfigPath "$ConfigPath" -Mode Daily</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$checkXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Project Zomboid: poll Steam every $CheckIntervalMinutes minutes and restart only if a new build has been published.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$boundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT${CheckIntervalMinutes}M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$RunAsUser</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PowerShellExe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" -ConfigPath "$ConfigPath" -Mode Check</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Write-Host "Registering '$TaskName' to run daily at $desc as $RunAsUser"
Write-Host "You will be prompted for that account's Windows password."
Write-Host ""

$pw = Read-Host -Prompt "Windows password for $RunAsUser" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))

Register-ScheduledTask -TaskName $TaskName      -Xml $xml      -User $RunAsUser -Password $plain -Force | Out-Null
Register-ScheduledTask -TaskName $CheckTaskName -Xml $checkXml -User $RunAsUser -Password $plain -Force | Out-Null
$plain = $null

Write-Host ""
Write-Host "Done."
Write-Host ("  {0,-28} next: {1}" -f $TaskName,      (Get-ScheduledTask -TaskName $TaskName      | Get-ScheduledTaskInfo).NextRunTime)
Write-Host ("  {0,-28} next: {1}  (every $CheckIntervalMinutes min)" -f $CheckTaskName, (Get-ScheduledTask -TaskName $CheckTaskName | Get-ScheduledTaskInfo).NextRunTime)
Write-Host ""
Write-Host "Test now:  Start-ScheduledTask -TaskName '$CheckTaskName'"
