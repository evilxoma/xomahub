-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS25-ENDSCREEN-VIM-V35
-- Pinned V33 replay base + refreshed click-through + V35 reliability +
-- authoritative end-screen VIM click handling.

local function runSource(url, label)
    local source = game:HttpGet(url)
    local chunk, err = loadstring(source)
    if not chunk then
        error(label .. " compile failed: " .. tostring(err))
    end
    return chunk()
end

local XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/be5bdb4c68e59796ecba8bad836cbea945b77c02/ctdui.lua",
    "XOMA V33 base"
)

-- Refresh the Obsidian click-through on a cache-distinct URL even if the pinned
-- base executor cached an older response for patches/input_v32.lua.
XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS25-ENDSCREEN-VIM-V35",
    "XOMA V32 click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/18838067f80c39ea34093abfccc869497f5eb4bc/patches/reliability_v35.lua",
    "XOMA V35 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/c518dd6e9c55fd8b083c7bc90a5aa9e84423e4c6/patches/endclick_v35.lua",
    "XOMA V35 end-click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS25-ENDSCREEN-VIM-V35"
end

print("[XOMA V35] cache-busted bootstrap loaded")
return XOMA
