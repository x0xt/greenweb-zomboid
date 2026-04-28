#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <workshop_id_or_url> <mod_id>"
    echo "Example: $0 2900671939 RealMetalworking"
    echo "Example: $0 'https://steamcommunity.com/sharedfiles/filedetails/?id=2900671939' RealMetalworking"
    exit 1
fi

INPUT="$1"
WORKSHOP_ID=$(echo "$INPUT" | grep -oP '(?<=id=)\d+' || echo "$INPUT")
MOD_ID="$2"
LGSM=/home/pzserver/pzserver
SERVER_INI=/home/pzserver/Zomboid/Server/Greenweb.ini

echo "==> Removing Workshop:$WORKSHOP_ID Mod:$MOD_ID"

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

items = [i for i in cp["ServerConfig"].get("WorkshopItems", "").split(";") if i != workshop_id]
mods  = [m for m in cp["ServerConfig"].get("Mods", "").split(";")          if m != mod_id]

cp["ServerConfig"]["WorkshopItems"] = ";".join(items)
cp["ServerConfig"]["Mods"]          = ";".join(mods)

with open(path, "w") as f:
    cp.write(f, space_around_delimiters=False)

print(f"    patched {path}")
PYEOF

echo "==> Sending warning..."
for i in {1..5}; do cd /home/pzserver && $LGSM send "servermsg \"[NOTICE] Brief restart to remove a mod. Back in under a minute.\"" & done
wait
sleep 10

echo "==> Stopping server..."
systemctl stop pzserver

echo "==> Starting server..."
systemctl start pzserver

echo "==> Done. Tell players to relog."
