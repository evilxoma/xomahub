-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS30-AUTORETRY-VIEWPORT-V39
-- Pinned V33 replay base + click-through + safe V39 reliability + live EndFrame
-- webhook gate + real end-screen Restart watcher.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS30-AUTORETRY-VIEWPORT-V39",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/1b5a27d14eb5e3c5e56834e22a9f0dee0867458c/patches/reliability_v39.lua",
    "XOMA V39 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/5962551b4ff1a27898aeeaf20f2be00539b4bbf0/patches/webhook_v39.lua",
    "XOMA V39 webhook"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/0a2ed0fb8fe74243930e145f95aa5e35ca22702b/patches/endclick_v39.lua",
    "XOMA V39 real end-screen click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS30-AUTORETRY-VIEWPORT-V39"
end

print("[XOMA V39] cache-busted bootstrap loaded | viewport-safe Auto Retry")
return XOMA
