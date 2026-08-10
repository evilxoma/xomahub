-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS28-WEBHOOK-HIERARCHY-AUTORESTART-V38
-- Pinned V33 replay base + click-through + V38 reliability + hierarchy-aware
-- fresh-round gate + V37 authoritative Restart VIM.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS28-WEBHOOK-HIERARCHY-AUTORESTART-V38",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/4b609f8f00e2eb9ded451ba42ef48fd33d6db1d6/patches/reliability_v38.lua",
    "XOMA V38 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/45c4e23ffae05aae4305e51471484588c53e0b47/patches/webhook_v38.lua",
    "XOMA V38 webhook gate"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/4fc62492d46505d5dba0906f7c0fb346a0a863ea/patches/endclick_v37.lua",
    "XOMA V37 end-click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS28-WEBHOOK-HIERARCHY-AUTORESTART-V38"
end

print("[XOMA V38] cache-busted bootstrap loaded | hierarchy Auto Restart")
return XOMA
