-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS29-LIVE-ENDSCREEN-AUTORESTART-V39
-- Pinned V33 replay base + click-through + V39 reliability + live EndFrame
-- webhook gate + authoritative visible Restart VIM click.

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua?build=PASS29-LIVE-ENDSCREEN-AUTORESTART-V39",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/9f96bbb77f5205536ad8bfda48be0afe2d18de84/patches/reliability_v39.lua",
    "XOMA V39 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/5962551b4ff1a27898aeeaf20f2be00539b4bbf0/patches/webhook_v39.lua",
    "XOMA V39 webhook"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/2f4f637e1231a51853ab15699969dc4714c2560a/patches/endclick_v39.lua",
    "XOMA V39 end-click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS29-LIVE-ENDSCREEN-AUTORESTART-V39"
end

print("[XOMA V39] cache-busted bootstrap loaded | live EndFrame Auto Restart")
return XOMA
