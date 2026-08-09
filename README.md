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

V19 routes `XOMA:Run()` by place automatically:

- In lobby: verify/equip the recorded deck, enter a free room-system elevator, open the recorded map with `FriendsOnly`, `Limit = 1`, `Classic`, then request teleport.
- In the match pre-game: press the game's real `Ready Up` GUI, select the recorded difficulty, wait until the voting/countdown phase is finished, and only then start Replay.
- Replay does not send a W0 Place while `Game Begins in ...` is still active.
- New Recorder strategies store difficulty before the loader so voting can start while the core is downloading.
- Old strategies without a stored difficulty stay compatible and default to the current/Normal difficulty.

## Strategy API

```lua
XOMA:Map("Map Name")
XOMA:Deck({ "Bandit" })
XOMA:Difficulty("Normal")
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

Current build: `PASS9-PREGAME-READY-V19`.