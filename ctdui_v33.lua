-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS23-NONBLOCKING-SKIP-V33

local source = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui.lua?build=PASS23-NONBLOCKING-SKIP-V33"
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
