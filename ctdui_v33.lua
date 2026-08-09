-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS23-NONBLOCKING-SKIP-V33

-- Immutable commit URL: this cannot resolve to a stale older ctdui build.
local source = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/be5bdb4c68e59796ecba8bad836cbea945b77c02/ctdui.lua"
)
local chunk, err = loadstring(source)
if not chunk then
    error("XOMA V33 bootstrap compile failed: " .. tostring(err))
end

local XOMA = chunk()
local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS23-NONBLOCKING-SKIP-V33"
end

print("[XOMA V33] cache-busted bootstrap loaded")
return XOMA
