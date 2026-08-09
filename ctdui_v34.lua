-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS24B-AUTORETRY-RECONNECT-RECORDER-V34
-- Base V33 and reliability V34 are pinned to immutable commits so executor/raw
-- caches cannot roll the player or recorder output back.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/35285be3dcfe34cc85b5dbab1f6dc4ee57be9485/patches/reliability_v34.lua",
    "XOMA V34 reliability"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS24B-AUTORETRY-RECONNECT-RECORDER-V34"
end

print("[XOMA V34] cache-busted bootstrap loaded | recorder -> V34")
return XOMA
