-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS27-AUTORESTART-RESULT-FALLBACK-V37
-- Pinned V33 replay base + click-through + V37 reliability + fresh-round webhook
-- gate + V37 authoritative Auto Restart.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS27-AUTORESTART-RESULT-FALLBACK-V37",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/b3d8edf4e1d3ca06ecfe269fde4b6296ffb55ed3/patches/reliability_v37.lua",
    "XOMA V37 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/fe47810f6257484fdb388ec399a3f2cffa16f01a/patches/webhook_v36.lua",
    "XOMA V36 fresh-round webhook gate"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/4fc62492d46505d5dba0906f7c0fb346a0a863ea/patches/endclick_v37.lua",
    "XOMA V37 end-click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS27-AUTORESTART-RESULT-FALLBACK-V37"
end

print("[XOMA V37] cache-busted bootstrap loaded | authoritative Auto Restart")
return XOMA
