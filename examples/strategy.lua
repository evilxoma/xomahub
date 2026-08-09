-- Example XOMA strategy.
-- CTDIG Recorder generates the same XOMA:Method(...) format.

local XOMA = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui.lua"
))()

XOMA:Map("YOUR_MAP_NAME")

XOMA:Deck({
    "Bandit",
})

XOMA:Config({
    AutoRetry = true,
    AutoBackToLobby = false,
})

-- WAVE 1
local U1 = XOMA:Place(
    "Bandit",
    Vector3.new(0, 0, 0),
    1,
    Vector3.new(0, 0, 0)
)

XOMA:Upgrade(U1, 1, 1)
XOMA:Target(U1, "First", 1)

-- WAVE 2
XOMA:Ability(U1, "Ability1", 2)

XOMA:Run()
