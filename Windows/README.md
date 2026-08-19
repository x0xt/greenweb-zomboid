# Windows — update watcher, restarter, backups

Windows 11 equivalent of the Linux `weekly-reboot.sh` + `/etc/cron.d` setup in the
repo root, driving `StartServer64.bat` directly. No LinuxGSM.

| File | What it is |
|---|---|
| `Update-PZServer.ps1` | the worker: watch / restart / back up |
| `Register-PZUpdateTask.ps1` | registers both scheduled tasks on fixed **UTC** times |
| `pzserver.json.example` | config — copy to `pzserver.json` and edit |

## What it does

Two scheduled tasks share one script:

- **PZ Server Update Watcher** — every **15 minutes**, asks Steam for the current
  build id and compares it to the installed one. Restarts **only** if a new build
  landed. Costs one lightweight Steam call; does nothing else the other 95 times a
  day. Also acts as a **crash watchdog** — see Gotchas.
- **PZ Server Daily Restart** — the once-a-day restart, **skipped** if a restart
  already happened in the last `MinHoursBetweenRestarts` (default 20). So an update
  restart at 13:50 doesn't get followed by a pointless one at 14:00.

A restart cycle is always: **warn players over RCON → `save` → clean `quit` →
back up the world → SteamCMD update → start.**

### Why 15 minutes

PZ builds don't drop often, so this is mostly about *latency* once one does. When
the server updates, players' clients auto-update through Steam and then **can't
join the old-version server** — so the window between "build published" and
"server restarted" is a window where the server is effectively down for anyone who
restarted Steam. 15 minutes bounds that without hammering Steam. Anything under
~5 minutes is just more API calls for no benefit; an hour means an hour of players
being unable to join. Change it with `-CheckIntervalMinutes`.

## The two rules

1. **The start is unconditional and every early exit leaves the server running.**
   The Linux sibling of this script used `set -e`. SteamCMD hit a transient Steam
   API timeout, the script died between the stop and the start, and the server was
   down for 19 hours. A skipped update is a non-event. A server down all day is not.
2. **Check mode fails *closed*.** If the remote build id can't be read, that counts
   as "no update". Failing open there would restart the server every 15 minutes.
   Every other path fails open toward updating.

## Setup

**0. Install PowerShell 7.** Windows ships *Windows PowerShell 5.1* as `powershell.exe`,
which is a different, older interpreter.

```powershell
winget install --id Microsoft.PowerShell -e
```

The scripts run on 5.1 too, but 7 is the supported target — and
`Register-PZUpdateTask.ps1` auto-detects `pwsh.exe` and points the scheduled tasks
at it, so install this **before** registering the tasks. Override with
`-PowerShellExe`.

⚠️ **`$PSScriptRoot` is empty inside `param()` defaults on 5.1** and populated on 7.
That difference broke the first release of this script (it couldn't find its own
config). It's fixed — the script folder is now resolved in the body — but it is the
canonical example of why "it works on PowerShell" means nothing without a version.

**1. Standalone SteamCMD** — <https://developer.valvesoftware.com/wiki/SteamCMD>.
Unzip to `C:\steamcmd\`, run once so it self-updates.

**2. Enable RCON.** In `C:\Users\<you>\Zomboid\Server\<servername>.ini`:

```ini
RCONPort=27015
RCONPassword=pick-something-long
```

Without it there is **no way to warn players or shut down cleanly** — the script
would have to kill the process, risking a corrupt save. It refuses; it skips the
update and leaves the server up instead. Don't port-forward 27015.

**3. Configure.** Copy `pzserver.json.example` → `pzserver.json`. Set `InstallDir`,
`ServerIni`, `SteamCmd`, `SaveDir`, `BackupDir`. Leave `RconPort`/`RconPassword`
`null` — they're read from the .ini so the password lives in exactly one place.

**4. Test by hand, server stopped:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-PZServer.ps1 -Mode Now -WhatIfNoStart
```

`-WhatIfNoStart` does everything except launch the server. Check
`update-restart.log` and confirm a zip appeared in `BackupDir`. Then drop the
switch and run it for real.

**5. Schedule** (9:00 AM Eastern Standard Time = 14:00 UTC):

```powershell
.\Register-PZUpdateTask.ps1 -UtcTime "14:00" -CheckIntervalMinutes 15
```

Any UTC time works. `-Local` schedules in local time instead.

## Backups

Taken **with the server stopped**, which is the only moment the save is guaranteed
consistent — a backup of a running PZ server can catch a half-written chunk.

- `BackupDir` — where zips go. A synced folder (OneDrive/Dropbox) or a second
  physical disk is worth it; same-disk backups don't survive the failure that
  actually kills servers.
- `BackupKeep` — how many to retain (default 14). Older ones are pruned.
- `BackupExtraPaths` — also archived; the example includes the `Server` config dir
  so sandbox settings and the mod list come back too, not just the map.
- `BackupMode` — `zip` (default) or `copy`. **Switch to `copy` if the save is more
  than a few GB** — `Compress-Archive` gets slow and memory-hungry on large trees,
  and that time is downtime.
- A backup failure is logged and the restart continues. Never leave the server down
  over a failed backup.

## Gotchas — these will bite

- **Run the tasks as the account that normally starts the server.** PZ keeps the
  world under `C:\Users\<user>\Zomboid`. As SYSTEM that resolves to
  `C:\Windows\System32\config\systemprofile\Zomboid` — **a different, empty world.**
  The registration script defaults to the current user for this reason. Don't
  "fix" it by switching to SYSTEM.
- **`C:\Program Files (x86)` is UAC-protected**, so tasks run `HighestAvailable`.
  SteamCMD permission errors mean that isn't taking effect.
- **Don't let the Steam client update the server too.** The install sits in a Steam
  library folder, so the client thinks it owns it. Set the app to update-on-launch
  only, or move the server out of the library folder.
- **UTC means the local clock time shifts.** 14:00 UTC is 9 AM Eastern in winter and
  10 AM in summer (Eastern is UTC-4 under DST). That's the tradeoff for a schedule
  that never drifts. Use `-Local` for a fixed wall-clock time instead.
- **Crash recovery is the watchdog, not a service wrapper.** `StartServer64.bat` has
  no supervisor. Rather than add one, the 15-minute watcher doubles as a watchdog:
  if no update is pending and the server process is gone, it starts it. Worst case
  downtime is one poll interval. Set `RestartIfDown: false` to disable.
  **Stopping the server by hand will therefore bring it back within 15 minutes** —
  create the `maintenance.flag` file (path configurable) to hold it down, delete it
  to resume.
  If a real service wrapper is ever wanted, use [Shawl](https://github.com/mtkennerly/shawl)
  (actively released) — **not NSSM**, whose last stable is 2014 and whose own
  download page tells Windows 10 Creators Update and later to run a 2017
  pre-release or services fail to start.

## What was tested

Run against a PowerShell container with a simulated SteamCMD, a mock RCON server,
and a fake save tree:

- RCON on a real socket: correct packet framing, quoted `servermsg` intact, wrong
  password and refused connection both fail in under a second instead of hanging.
- Build-id parser picks the `public` branch and ignores `unstable`.
- Check mode with matching builds → no restart. With a newer build → full cycle.
  With SteamCMD failing → **fails closed, no restart.**
- Daily mode skips when a restart was recent, runs when the state is 25h old.
- SteamCMD exiting non-zero → **server still started.**
- Missing config, malformed config, SteamCMD absent → all handled.
- Backups: valid zip, correct contents, retention prunes to `BackupKeep`.
- Watchdog: restarts a downed server, respects `maintenance.flag`, obeys
  `RestartIfDown: false`, and doesn't interfere with the update path.
- Both generated Task Scheduler XMLs parse, with the right UTC boundary,
  `PT15M` repetition, and `-Mode` arguments.

**Tested on PowerShell 7 only** (Linux container). Windows PowerShell 5.1 is *supported
but unverified* — the one 5.1 difference found so far, `$PSScriptRoot` in `param()`
defaults, was found by a user, not by these tests. Task Scheduler registration, the
`Global\` mutex, and process detection by install path also need one live run.
