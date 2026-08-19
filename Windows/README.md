# Windows — nightly update + restart

Windows 11 equivalent of the Linux `weekly-reboot.sh` + `/etc/cron.d` setup in the
repo root. Same job: warn players, save the world, shut down cleanly, update via
SteamCMD, start again.

Nothing here needs LinuxGSM. It drives `StartServer64.bat` directly.

| File | What it is |
|---|---|
| `Update-PZServer.ps1` | the update/restart script |
| `Register-PZUpdateTask.ps1` | registers it in Task Scheduler on a fixed **UTC** time |
| `pzserver.json.example` | config — copy to `pzserver.json` and edit |

## The one rule

**The start is unconditional, and every early exit leaves the server running.**
The Linux sibling of this script used `set -e`. SteamCMD hit a transient Steam API
timeout, the script died between the stop and the start, and the server was down
for 19 hours. A skipped update is a non-event. A server down all day is not.

## Setup

**1. Get standalone SteamCMD** — <https://developer.valvesoftware.com/wiki/SteamCMD>
Unzip to `C:\steamcmd\`, run it once so it self-updates.

**2. Enable RCON.** In `C:\Users\<you>\Zomboid\Server\<servername>.ini`:

```ini
RCONPort=27015
RCONPassword=pick-something-long
```

Without it there is **no way to warn players or shut down cleanly** — the script
would have to kill the process, which risks corrupting the save. It refuses to do
that; it will skip the update and leave the server up instead. Don't port-forward
27015.

**3. Configure.** Copy `pzserver.json.example` to `pzserver.json`, set `InstallDir`,
`ServerIni`, and `SteamCmd`. `RconPort`/`RconPassword` are read from the .ini
automatically — leave them `null` so the password lives in one place only.

**4. Test by hand, with the server stopped:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-PZServer.ps1 -WhatIfNoStart
```

`-WhatIfNoStart` does everything except launch the server. Then run it for real.
Check `update-restart.log`.

**5. Schedule it** (9:00 AM Eastern Standard Time = 14:00 UTC):

```powershell
.\Register-PZUpdateTask.ps1 -UtcTime "14:00"
```

Any UTC time works: `-UtcTime "07:30"`. Add `-Local` to schedule in local time instead.

## Gotchas — read these, they will bite

- **Run the task as the account that normally starts the server.** PZ stores the
  world under `C:\Users\<user>\Zomboid`. If the task runs as SYSTEM it resolves to
  `C:\Windows\System32\config\systemprofile\Zomboid` — **a different, empty world.**
  The registration script defaults to the current user for this reason. Don't
  "fix" it by switching to SYSTEM.
- **The task needs the account password** and "run whether logged on or not". This
  is normal; Windows stores it in the credential vault.
- **`C:\Program Files (x86)` is UAC-protected**, so the task runs elevated
  (`HighestAvailable`). If SteamCMD reports permission errors, that's why.
- **Don't let the Steam client update the server at the same time.** The install
  lives inside a Steam library folder, so the client also thinks it owns it. Either
  set the app to "only update when I launch it" in Steam, or move the server out of
  the library folder entirely.
- **UTC means the local clock time shifts.** 14:00 UTC is 9 AM Eastern in winter and
  10 AM in summer, because Eastern is UTC-4 under daylight saving. That's the
  tradeoff for a schedule that never drifts. Use `-Local` if you'd rather it always
  be 9 AM on his wall clock.
- **No crash recovery.** `StartServer64.bat` has no supervisor, so if the server
  crashes at 3 AM it stays down until this runs. If that matters, wrap the .bat in
  a Windows service with [NSSM](https://nssm.cc/) — that's the real equivalent of
  the `Restart=on-failure` the Linux unit has.

## What was tested

RCON verified against a real socket (correct packet framing, quoted `servermsg`
passes through intact, wrong password and refused connection both fail fast rather
than hang). Script paths verified: missing config, malformed config, SteamCMD
missing, SteamCMD exiting non-zero — in both SteamCMD failure cases the server is
still started.

**Not yet tested on real Windows against a live server.** The Task Scheduler
registration, the `Global\` mutex, and process detection by install path are the
parts that need a real run to confirm.
