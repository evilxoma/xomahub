-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS24-AUTORETRY-RECONNECT-V34
-- Base V33 is pinned to an immutable commit so executor/raw caches cannot roll
-- the player back. Reliability V34 is loaded from its brand-new patch URL.

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

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/reliability_v34.lua",
    "XOMA V34 reliability"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS24-AUTORETRY-RECONNECT-V34"
end

print("[XOMA V34] cache-busted bootstrap loaded")
return XOMA
