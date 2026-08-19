<#
.SYNOPSIS
    SteamCMD update watcher, restarter and backup for a Project Zomboid
    dedicated server on Windows.

.DESCRIPTION
    -Mode Check    Poll Steam for a new build. Restart ONLY if one landed.
                   Cheap; meant to run every 15 minutes.
    -Mode Daily    Scheduled restart, skipped if a restart already happened
                   within MinHoursBetweenRestarts (so an update restart at
                   13:50 doesn't get followed by a pointless one at 14:00).
    -Mode Now      Restart immediately, no questions.

    A restart cycle is: warn players over RCON -> save -> clean quit ->
    back up the world -> steamcmd update -> start.

    THE ONE RULE: the start is unconditional and every early exit leaves the
    server RUNNING. A Linux sibling of this script once used `set -e`; steamcmd
    hit a transient Steam API timeout, the script died between the stop and the
    start, and the server was down for 19 hours. A skipped update is a
    non-event. A server down all day is not.

    THE SECOND RULE: in -Mode Check, an *unknown* remote build must NEVER count
    as "new". Failing open there would restart the server every 15 minutes.
    Check mode fails CLOSED; every other path fails open toward updating.

.PARAMETER ConfigPath
    Path to the .json config. Defaults to pzserver.json next to this script.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Daily','Now')]
    [string]$Mode = 'Check',
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
$BackupDir    = Get-Cfg 'BackupDir'    $null
$SaveDir      = Get-Cfg 'SaveDir'      $null
$BackupExtra  = Get-Cfg 'BackupExtraPaths' @()
$BackupKeep   = [int](Get-Cfg 'BackupKeep' 14)
$BackupMode   = Get-Cfg 'BackupMode'   'zip'      # zip | copy
$StateFile    = Get-Cfg 'StateFile' (Join-Path $PSScriptRoot 'pzserver.state.json')
$MinHours     = [double](Get-Cfg 'MinHoursBetweenRestarts' 20)
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


# ------------------------------------------------------------- build ids ----
$manifest = Join-Path $InstallDir "steamapps\appmanifest_$AppId.acf"

function Get-LocalBuildId {
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    foreach ($l in (Get-Content -LiteralPath $manifest)) {
        if ($l -match '"buildid"\s+"(\d+)"') { return $Matches[1] }
    }
    return $null
}

# Latest public build, per Steam. Returns $null if it cannot be determined -
# callers in Check mode MUST treat $null as "no update" (see THE SECOND RULE).
function Get-RemoteBuildId {
    if (-not (Test-Path -LiteralPath $SteamCmd)) { return $null }
    try {
        $out = & $SteamCmd +login anonymous +app_info_update 1 +app_info_print "$AppId" +quit 2>&1 | Out-String
    } catch { return $null }
    # Walk into "branches" -> "public" -> "buildid"
    $inBranches = $false; $inPublic = $false; $depth = 0
    foreach ($line in ($out -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $inBranches) { if ($t -eq '"branches"') { $inBranches = $true }; continue }
        if (-not $inPublic) {
            if ($t -eq '"public"') { $inPublic = $true; $depth = 0 }
            continue
        }
        if ($t -eq '{') { $depth++; continue }
        if ($t -eq '}') { if (--$depth -le 0) { break }; continue }
        if ($t -match '^"buildid"\s+"(\d+)"$') { return $Matches[1] }
    }
    return $null
}

# ----------------------------------------------------------------- state ----
function Get-State {
    if (Test-Path -LiteralPath $StateFile) {
        try { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ LastRestartUtc = $null; LastBuildId = $null }
}
function Set-State($buildId) {
    try {
        [pscustomobject]@{
            LastRestartUtc = (Get-Date).ToUniversalTime().ToString('o')
            LastBuildId    = $buildId
        } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding utf8
    } catch { Write-Log "Could not write state file: $($_.Exception.Message)" 'WARN' }
}

# ------------------------------------------------------------- mode gate ----
$state       = Get-State
$localBuild  = Get-LocalBuildId
$updateFound = $false

switch ($Mode) {
    'Check' {
        $remote = Get-RemoteBuildId
        if (-not $remote) {
            # FAIL CLOSED. Unknown != new, or we would restart every poll.
            Write-Log "Could not read the remote build id; treating as no update." 'WARN'
            $mutex.ReleaseMutex(); exit 0
        }
        if (-not $localBuild) {
            Write-Log "No local appmanifest yet - treating as an update." 
            $updateFound = $true
        } elseif ($remote -ne $localBuild) {
            Write-Log "UPDATE FOUND: local $localBuild -> Steam $remote"
            $updateFound = $true
        } else {
            Write-Log "Up to date (build $localBuild). Nothing to do."
            $mutex.ReleaseMutex(); exit 0
        }
    }
    'Daily' {
        if ($state.LastRestartUtc) {
            $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($state.LastRestartUtc).ToUniversalTime()).TotalHours
            if ($age -lt $MinHours) {
                Write-Log ("Last restart was {0:N1}h ago (< {1}h). Skipping the daily restart." -f $age, $MinHours)
                $mutex.ReleaseMutex(); exit 0
            }
        }
        Write-Log 'Daily scheduled restart.'
    }
    'Now' { Write-Log 'Manual restart requested.' }
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


# ---------------------------------------------------------------- backup ----
# Runs with the server STOPPED, which is the only point the save is guaranteed
# consistent. A backup failure must not stop the restart.
function Invoke-Backup {
    if (-not $BackupDir) { Write-Log 'No BackupDir configured - skipping backup.' 'WARN'; return }
    if (-not $SaveDir)   { Write-Log 'No SaveDir configured - skipping backup.'   'WARN'; return }
    if (-not (Test-Path -LiteralPath $SaveDir)) { Write-Log "SaveDir not found: $SaveDir" 'WARN'; return }
    try {
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        }
        $stamp   = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $sources = @($SaveDir) + @($BackupExtra | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

        if ($BackupMode -eq 'copy') {
            $dest = Join-Path $BackupDir "pz-$stamp"
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            foreach ($src in $sources) {
                Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force -ErrorAction Stop
            }
            $size = (Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object Length -Sum).Sum
            Write-Log ("Backup written: {0} ({1:N0} MB)" -f $dest, ($size / 1MB))
        } else {
            $zip = Join-Path $BackupDir "pz-$stamp.zip"
            Compress-Archive -Path $sources -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
            Write-Log ("Backup written: {0} ({1:N0} MB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1MB))
        }

        # retention
        if ($BackupKeep -gt 0) {
            $old = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'pz-*' |
                     Sort-Object LastWriteTime -Descending | Select-Object -Skip $BackupKeep)
            foreach ($o in $old) {
                Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Pruned old backup: $($o.Name)"
            }
        }
    } catch {
        Write-Log "BACKUP FAILED: $($_.Exception.Message) - continuing with the restart anyway." 'ERROR'
    }
}

Invoke-Backup

# ---------------------------------------------------------------- update ----
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

# The restart cycle is done at this point; record it before the start so that a
# start failure (or -WhatIfNoStart) can't make Daily mode forget it happened.
Set-State (Get-LocalBuildId)

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
