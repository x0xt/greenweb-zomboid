#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <workshop_id_or_url> <mod_id>"
    echo "Example: $0 2900671939 RealMetalworking"
    echo "Example: $0 'https://steamcommunity.com/sharedfiles/filedetails/?id=2900671939' RealMetalworking"
    exit 1
fi

# parse workshop ID from URL or raw ID
INPUT="$1"
WORKSHOP_ID=$(echo "$INPUT" | grep -oP '(?<=id=)\d+' || echo "$INPUT")
MOD_ID="$2"
LGSM=/home/pzserver/pzserver
SERVER_INI=/home/pzserver/Zomboid/Server/Greenweb.ini

echo "==> Adding Workshop:$WORKSHOP_ID Mod:$MOD_ID"

python3 - "$SERVER_INI" "$WORKSHOP_ID" "$MOD_ID" << 'PYEOF'
import sys
from configparser import RawConfigParser

path, workshop_id, mod_id = sys.argv[1:]

with open(path, "r") as f:
    raw = f.read()

if not raw.startswith("[ServerConfig]"):
    raw = "[ServerConfig]\n" + raw

cp = RawConfigParser()
cp.optionxform = lambda o: o
cp.read_string(raw)

items = cp["ServerConfig"].get("WorkshopItems", "")
mods  = cp["ServerConfig"].get("Mods", "")

if workshop_id in items.split(";"):
    print(f"Workshop ID {workshop_id} already present, skipping.")
    sys.exit(0)

cp["ServerConfig"]["WorkshopItems"] = items + ";" + workshop_id if items else workshop_id
cp["ServerConfig"]["Mods"]          = mods  + ";" + mod_id      if mods  else mod_id

with open(path, "w") as f:
    cp.write(f, space_around_delimiters=False)

print(f"    patched {path}")
PYEOF

echo "==> Sending warning..."
for i in {1..5}; do cd /home/pzserver && $LGSM send "servermsg \"[NOTICE] Brief restart to load a new mod. Back in under a minute.\"" & done
wait
sleep 10

echo "==> Stopping server..."
systemctl stop pzserver

echo "==> Downloading mod via SteamCMD..."
sudo -u pzserver /home/pzserver/steamcmd/steamcmd.sh \
    +force_install_dir /home/pzserver/serverfiles \
    +login anonymous \
    +workshop_download_item 108600 "$WORKSHOP_ID" \
    +quit

echo "==> Starting server..."
systemctl start pzserver

echo "==> Done. Tell players to relog."
