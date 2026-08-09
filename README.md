# XOMA Hub

CTDIG / XOMA macro core for the Roblox tower-defense project.

## Loader

```lua
local XOMA = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui.lua"
))()
```

`ctdui.lua` returns the XOMA strategy API, so recorder-generated strategies keep the existing syntax.

## AutoExec

Put the generated strategy file (for example `ctdig.lua`) into your executor's `autoexec` / `autoexecute` folder.

V17 routes `XOMA:Run()` by place automatically:

- In lobby: wait for lobby data, verify the exact recorded deck, equip the matching saved loadout if needed, enter a free room-system elevator, open the recorded map with `FriendsOnly`, `Limit = 1`, `Classic`, then request teleport.
- After Roblox teleports: the executor runs the same strategy from autoexec again. XOMA detects the match, waits for `Towers`, `Map.Configuration`, `PlayerData.Loadout`, map name and deck replication, binds match sources, then starts Replay.
- Wrong map or wrong deck does not silently run the strategy.

The lobby flow mirrors the game's `PlayerLoadouts(..., "EquipLoadout")` and `Remotes.Elevators:InvokeServer(room, "OpenRoom", payload)` / `"Teleport"` paths.

## Strategy API

```lua
XOMA:Map("Map Name")
XOMA:Deck({ "Bandit" })
XOMA:Config({ AutoRetry = true, AutoBackToLobby = false })

local U1 = XOMA:Place("Bandit", Vector3.new(0, 0, 0), 1, Vector3.new(0, 0, 0))
XOMA:Upgrade(U1, 1, 1)
XOMA:Target(U1, "First", 1)
XOMA:Ability(U1, "Ability1", 2)
XOMA:Sell(U1, 10)
XOMA:Skip(3)
XOMA:Run()
```

## Webhook Session Summary

The webhook reports per-run Coins, Coins/hour, EXP, EXP/hour, plus cumulative session runs, wins/losses, win rate, total Coins/EXP, session Coins/hour and EXP/hour, runtime, and average run duration.

Current build: `PASS7-AUTOEXEC-V17`.
