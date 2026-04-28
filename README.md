# greenweb-zomboid

Project Zomboid dedicated server setup for the Greenweb server.

## Stack

- [LinuxGSM](https://linuxgsm.com/servers/pzserver/) — server management
- systemd — process supervision, auto-restart on crash, starts on boot
- Zero trust networking — game server has no public ports exposed

## Setup

### 1. Install dependencies

```bash
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y lib32gcc-s1 curl wget tar bzip2 gzip unzip \
    bsdmainutils python3 util-linux ca-certificates binutils bc jq tmux \
    netcat-openbsd file
```

### 2. Create server user and install LinuxGSM

```bash
sudo useradd -m -s /bin/bash pzserver
sudo -u pzserver bash -c '
  cd /home/pzserver
  wget -q https://linuxgsm.sh -O linuxgsm.sh
  chmod +x linuxgsm.sh
  bash linuxgsm.sh pzserver
  ./pzserver auto-install
'
```

### 3. Configure

```bash
cp .env.example .env
# fill in .env with your passwords and settings
chmod 600 .env
bash configure.sh
```

### 4. Start

```bash
sudo systemctl start pzserver
sudo systemctl status pzserver
```

### First boot

The first start downloads all Workshop mods. The server is ready when you see:

```
LuaNet: Initialization [DONE]
```

Watch logs live:
```bash
sudo tail -f /home/pzserver/Zomboid/Logs/$(sudo ls -t /home/pzserver/Zomboid/Logs/ | head -1)
```

## Ports

| Port  | Protocol | Purpose              |
|-------|----------|----------------------|
| 16261 | UDP      | Game (required)      |
| 16262 | UDP      | Game aux (required)  |
| 27015 | TCP      | RCON (optional)      |

All ports are closed on the game server itself. Open them on your public gateway and forward via nftables (see `gateway/pz-forward.nft.template`). Fill in your gateway's interface and your game server's private IP in `.env`.

## Adding / removing mods

Pass either a raw workshop ID or a full Steam Workshop URL:

```bash
# add
sudo /home/pzserver/add-mod.sh 'https://steamcommunity.com/sharedfiles/filedetails/?id=2900671939' RealMetalworking

# remove
sudo /home/pzserver/remove-mod.sh 'https://steamcommunity.com/sharedfiles/filedetails/?id=2900671939' RealMetalworking
```

Scripts handle warning players, stopping the server, downloading/removing the mod, and restarting. Minimal downtime.

## Nightly maintenance

Every night at 4am the server:
1. Warns players in chat at 3:58 and 3:59
2. Stops at 4:00
3. Updates all mods
4. Restarts

## Useful commands

```bash
sudo systemctl restart pzserver                          # restart
sudo systemctl stop pzserver                             # stop
sudo -u pzserver /home/pzserver/pzserver details         # server info
sudo -u pzserver /home/pzserver/pzserver backup          # backup save
sudo tail -f /home/pzserver/Zomboid/Logs/$(sudo ls -t /home/pzserver/Zomboid/Logs/ | head -1)  # live logs
```

## Performance tuning

Applied automatically by `configure.sh`:

- JVM heap pre-allocated (`-Xms8g -Xmx20g`) — no heap resizing under load
- Network buffers bumped to 8MB — reduces Steam networking lock contention
- CPU governor set to `performance` — no frequency scaling delays
- NVMe I/O scheduler set to `none` — optimal for NVMe
- File descriptor limit raised to 65536 for the pzserver user
