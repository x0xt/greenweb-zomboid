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
  day.
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
- **No crash recovery.** `StartServer64.bat` has no supervisor — a 3 AM crash stays
  down until the watcher next finds an update, which could be days. If that matters,
  wrap the .bat in a service with [NSSM](https://nssm.cc/); that's the real
  equivalent of `Restart=on-failure` in the Linux unit. Not built here.

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
- Both generated Task Scheduler XMLs parse, with the right UTC boundary,
  `PT15M` repetition, and `-Mode` arguments.

**Not tested on real Windows against a live server.** Task Scheduler registration,
the `Global\` mutex, and process detection by install path need one live run.
