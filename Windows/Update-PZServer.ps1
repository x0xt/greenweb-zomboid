<#
.SYNOPSIS
    Scheduled SteamCMD update + restart for a Project Zomboid dedicated server on Windows.

.DESCRIPTION
    Warns players over RCON, saves the world, shuts down cleanly, runs steamcmd,
    and starts the server again.

    THE ONE RULE: the start is unconditional and every early exit leaves the
    server RUNNING. A Linux sibling of this script once used `set -e`; steamcmd
    hit a transient Steam API timeout, the script died between the stop and the
    start, and the server was down for 19 hours. A skipped update is a
    non-event. A server down all day is not.

.PARAMETER ConfigPath
    Path to the .json config. Defaults to pzserver.json next to this script.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'pzserver.json'),
    [switch]$WhatIfNoStart   # testing only: do everything except start the server
)

$ErrorActionPreference = 'Continue'   # NEVER 'Stop' - see THE ONE RULE above.

# ---------------------------------------------------------------- config ----
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 64
}
try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Config is not valid JSON: $($_.Exception.Message)"
    exit 64
}

function Get-Cfg($name, $default) {
    $v = $cfg.PSObject.Properties[$name]
    if ($null -ne $v -and $null -ne $v.Value -and "$($v.Value)" -ne '') { return $v.Value }
    return $default
}

$InstallDir   = Get-Cfg 'InstallDir'   $null
$StartScript  = Get-Cfg 'StartScript'  'StartServer64.bat'
$SteamCmd     = Get-Cfg 'SteamCmd'     'C:\steamcmd\steamcmd.exe'
$AppId        = Get-Cfg 'AppId'        380870
$ServerIni    = Get-Cfg 'ServerIni'    $null
$RconHost     = Get-Cfg 'RconHost'     '127.0.0.1'
$RconPort     = Get-Cfg 'RconPort'     $null
$RconPassword = Get-Cfg 'RconPassword' $null
$StopTimeout  = [int](Get-Cfg 'StopTimeoutSeconds' 180)
$Validate     = [bool](Get-Cfg 'Validate' $true)
$LogPath      = Get-Cfg 'LogPath' (Join-Path $PSScriptRoot 'update-restart.log')
$Warnings     = Get-Cfg 'Warnings' @(
    @{ SecondsBefore = 300; Message = 'Server restarting for updates in 5 minutes.' },
    @{ SecondsBefore = 120; Message = 'Server restarting in 2 minutes. Find a safe spot.' },
    @{ SecondsBefore = 60;  Message = 'Server restarting in 1 minute. Log out safely if you can.' },
    @{ SecondsBefore = 10;  Message = 'Restarting now. Back in a few minutes.' }
)

if (-not $InstallDir) { Write-Error 'InstallDir is required in the config.'; exit 64 }

# ---------------------------------------------------------------- logging ---
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 } catch { }
}

# keep the log from growing forever
try {
    if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 5MB)) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
    }
} catch { }

Write-Log "=== run started (config: $ConfigPath) ==="

# ------------------------------------------------------- single instance ----
# A slow steamcmd must not overlap tomorrow's run.
$mutex = New-Object System.Threading.Mutex($false, 'Global\PZServerUpdateRestart')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'Another run is already in progress. Exiting without touching the server.' 'WARN'
    exit 0
}

# ------------------------------------------------------------------ RCON ----
# Source RCON protocol, implemented inline so there is no mcrcon.exe dependency.
function Invoke-Rcon {
    param(
        [string]$RHost, [int]$Port, [string]$Password,
        [string[]]$Commands, [int]$TimeoutMs = 5000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($RHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "connect timed out" }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout  = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        function Send-Packet($id, $type, $body) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($body)
            $ms = New-Object System.IO.MemoryStream
            $bw = New-Object System.IO.BinaryWriter($ms)
            $bw.Write([int]($bytes.Length + 10))   # size excludes itself
            $bw.Write([int]$id)
            $bw.Write([int]$type)
            $bw.Write($bytes)
            $bw.Write([byte]0)                      # body terminator
            $bw.Write([byte]0)                      # packet terminator
            $bw.Flush()
            $buf = $ms.ToArray()
            $stream.Write($buf, 0, $buf.Length)
            $stream.Flush()
        }

        function Read-Packet {
            $hdr = New-Object byte[] 4
            $read = 0
            while ($read -lt 4) {
                $n = $stream.Read($hdr, $read, 4 - $read)
                if ($n -le 0) { throw 'connection closed while reading size' }
                $read += $n
            }
            $size = [BitConverter]::ToInt32($hdr, 0)
            if ($size -lt 10 -or $size -gt 8192) { throw "bogus packet size $size" }
            $payload = New-Object byte[] $size
            $read = 0
            while ($read -lt $size) {
                $n = $stream.Read($payload, $read, $size - $read)
                if ($n -le 0) { throw 'connection closed while reading body' }
                $read += $n
            }
            [pscustomobject]@{
                Id   = [BitConverter]::ToInt32($payload, 0)
                Type = [BitConverter]::ToInt32($payload, 4)
                Body = [System.Text.Encoding]::ASCII.GetString($payload, 8, $size - 10)
            }
        }

        Send-Packet 1 3 $Password          # SERVERDATA_AUTH
        $resp = Read-Packet
        # Some servers send an empty RESPONSE_VALUE before the auth result.
        if ($resp.Type -eq 0) { $resp = Read-Packet }
        if ($resp.Id -eq -1) { throw 'RCON authentication failed (wrong password)' }

        $out = @()
        $i = 2
        foreach ($c in $Commands) {
            Send-Packet $i 2 $c            # SERVERDATA_EXECCOMMAND
            $r = Read-Packet
            $out += $r.Body
            $i++
        }
        return @{ Ok = $true; Output = $out }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

# Pull RCON settings out of the PZ .ini so the password lives in exactly one place.
if ($ServerIni -and (Test-Path -LiteralPath $ServerIni)) {
    foreach ($line in (Get-Content -LiteralPath $ServerIni)) {
        if ($line -match '^\s*RCONPort\s*=\s*(\d+)\s*$'     -and -not $RconPort)     { $RconPort = [int]$Matches[1] }
        if ($line -match '^\s*RCONPassword\s*=\s*(.+?)\s*$' -and -not $RconPassword) { $RconPassword = $Matches[1] }
    }
    Write-Log "Read RCON settings from $ServerIni (port $RconPort)"
} elseif ($ServerIni) {
    Write-Log "ServerIni not found: $ServerIni" 'WARN'
}
if (-not $RconPort) { $RconPort = 27015 }

$rconUsable = [bool]$RconPassword
if (-not $rconUsable) {
    Write-Log 'No RCON password - cannot warn players or shut down cleanly. Set RCONPassword in the server .ini.' 'WARN'
}

function Send-ServerMessage([string]$text) {
    if (-not $rconUsable) { return }
    $r = Invoke-Rcon -RHost $RconHost -Port $RconPort -Password $RconPassword -Commands @("servermsg `"$text`"")
    if (-not $r.Ok) { Write-Log "RCON servermsg failed: $($r.Error)" 'WARN' }
}

# ------------------------------------------------- find the running server ---
function Get-ServerProcess {
    $dir = (Resolve-Path -LiteralPath $InstallDir -ErrorAction SilentlyContinue).Path
    if (-not $dir) { return $null }
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            $p -and $p.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)
        }
}

$running = @(Get-ServerProcess)
if ($running.Count -eq 0) {
    Write-Log 'Server does not appear to be running. Updating, then starting it.'
} else {
    Write-Log ("Server running: {0}" -f (($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', '))

    # ------------------------------------------------------------ warnings ---
    $sorted = @($Warnings | Sort-Object -Property { [int]$_.SecondsBefore } -Descending)
    $prev = $null
    foreach ($w in $sorted) {
        $secs = [int]$w.SecondsBefore
        if ($null -ne $prev) {
            $wait = $prev - $secs
            if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        }
        Write-Log "Warning players (T-${secs}s): $($w.Message)"
        Send-ServerMessage $w.Message
        $prev = $secs
    }
    if ($null -ne $prev -and $prev -gt 0) { Start-Sleep -Seconds $prev }

    # ---------------------------------------------------- save + clean quit ---
    if ($rconUsable) {
        Write-Log 'Flushing world save (RCON: save)'
        $r = Invoke-Rcon -RHost $RconHost -Port $RconPort -Password $RconPassword -Commands @('save') -TimeoutMs 60000
        if ($r.Ok) { Start-Sleep -Seconds 15 } else { Write-Log "RCON save failed: $($r.Error)" 'WARN' }

        Write-Log 'Shutting down (RCON: quit)'
        $r = Invoke-Rcon -RHost $RconHost -Port $RconPort -Password $RconPassword -Commands @('quit') -TimeoutMs 15000
        if (-not $r.Ok) { Write-Log "RCON quit failed: $($r.Error)" 'WARN' }
    }

    $deadline = (Get-Date).AddSeconds($StopTimeout)
    while ((Get-Date) -lt $deadline -and (@(Get-ServerProcess).Count -gt 0)) { Start-Sleep -Seconds 2 }

    $still = @(Get-ServerProcess)
    if ($still.Count -gt 0) {
        # Do NOT kill it. Killing PZ mid-write is how save corruption happens, and
        # patching files under a live server is worse than skipping the update.
        Write-Log "Server still running after ${StopTimeout}s. Skipping the update and LEAVING IT UP." 'ERROR'
        $mutex.ReleaseMutex()
        exit 0
    }
    Write-Log 'Server stopped cleanly.'
}

# ---------------------------------------------------------------- update ----
$manifest = Join-Path $InstallDir "steamapps\appmanifest_$AppId.acf"
function Get-LocalBuildId {
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    foreach ($l in (Get-Content -LiteralPath $manifest)) {
        if ($l -match '"buildid"\s+"(\d+)"') { return $Matches[1] }
    }
    return $null
}
$before = Get-LocalBuildId

if (Test-Path -LiteralPath $SteamCmd) {
    $scArgs = @('+force_install_dir', $InstallDir, '+login', 'anonymous', '+app_update', "$AppId")
    if ($Validate) { $scArgs += 'validate' }
    $scArgs += '+quit'
    Write-Log "Running steamcmd for app $AppId"
    try {
        $p = Start-Process -FilePath $SteamCmd -ArgumentList $scArgs -NoNewWindow -Wait -PassThru
        $rc = $p.ExitCode
    } catch {
        $rc = -1
        Write-Log "steamcmd could not be launched: $($_.Exception.Message)" 'ERROR'
    }
    if ($rc -ne 0) {
        Write-Log "steamcmd FAILED (exit $rc) - starting the server on existing files anyway." 'ERROR'
    } else {
        $after = Get-LocalBuildId
        if ($before -ne $after) { Write-Log "Updated buildid $before -> $after" }
        else { Write-Log "No build change (buildid $after)" }
    }
} else {
    Write-Log "steamcmd not found at $SteamCmd - skipping update, still restarting." 'ERROR'
}

# ----------------------------------------------------------------- start ----
# Unconditional. Every path above reaches here or exits with the server up.
$bat = Join-Path $InstallDir $StartScript
if ($WhatIfNoStart) {
    Write-Log "-WhatIfNoStart set: would have started $bat"
    $mutex.ReleaseMutex()
    exit 0
}
if (-not (Test-Path -LiteralPath $bat)) {
    Write-Log "START SCRIPT MISSING: $bat - THE SERVER IS DOWN." 'ERROR'
    $mutex.ReleaseMutex()
    exit 1
}
Write-Log "Starting server: $bat"
try {
    Start-Process -FilePath $bat -WorkingDirectory $InstallDir -WindowStyle Minimized | Out-Null
} catch {
    Write-Log "FAILED TO START THE SERVER: $($_.Exception.Message)" 'ERROR'
    $mutex.ReleaseMutex()
    exit 1
}

Start-Sleep -Seconds 20
if (@(Get-ServerProcess).Count -gt 0) { Write-Log 'Server process is up.' }
else { Write-Log 'Server process not visible 20s after launch - check the server console.' 'WARN' }

Write-Log '=== run finished ==='
$mutex.ReleaseMutex()
exit 0
