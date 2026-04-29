#!/usr/bin/env python3
"""
Patches TrueActionsLogic.lua to fix the fast-forward time getting stuck
after vanilla sleep ends. Safe to re-run -- idempotent.
"""
import sys

TARGET = (
    "/home/pzserver/serverfiles/steamapps/workshop/content/"
    "108600/2487022075/mods/TMC_TrueActions/media/lua/client/TrueActionsLogic.lua"
)

ANCHOR = "                end    \n            end\n"

FIX = """\
            -- FIX: detect when vanilla sleep ends but SitWOAnim is stuck
            if not TrueActions.wasSleeping then TrueActions.wasSleeping = {} end
            local isSleepingNow = playerObj:isSleeping()
            if TrueActions.wasSleeping[playerNum] == true and not isSleepingNow then
                if (playerObj:getVariableString("SitWOAnim") == "Sleep" or
                    playerObj:getVariableString("SitWOAnim") == "SleepReversoE" or
                    playerObj:getVariableString("SitWOAnim") == "SleepReversoS") then
                    TrueActions.standUp(playerObj)
                end
            end
            TrueActions.wasSleeping[playerNum] = isSleepingNow
"""

MARKER = "-- FIX: detect when vanilla sleep ends"

with open(TARGET, "r") as f:
    src = f.read()

if MARKER in src:
    print("Patch already applied, nothing to do.")
    sys.exit(0)

if ANCHOR not in src:
    print("ERROR: anchor string not found -- file may have changed, patch needs update.")
    sys.exit(1)

# Insert fix right before the GetUp block (after the SitWOAnim big-if closes)
patched = src.replace(ANCHOR, ANCHOR + FIX, 1)

with open(TARGET, "w") as f:
    f.write(patched)

print("Patch applied successfully.")
