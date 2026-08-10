-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS26-WEBHOOK-ROUND-GATE-V36
-- Pinned V33 replay base + click-through + V36 reliability + webhook lifecycle
-- gate + V35 one-shot end-screen input.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS26-WEBHOOK-ROUND-GATE-V36",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/4fb5a926cfdddbad99c8410908fd81765e0ee62e/patches/reliability_v36.lua",
    "XOMA V36 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/8c41ccb863060fdf7697f843539bb51933c315c2/patches/webhook_v36.lua",
    "XOMA V36 webhook"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/34d7ef500cf55fcdfe77b520f1b9740b7e5225b4/patches/endclick_v35.lua",
    "XOMA V35 end-click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS26-WEBHOOK-ROUND-GATE-V36"
end

print("[XOMA V36] cache-busted bootstrap loaded | webhook round gate")
return XOMA
