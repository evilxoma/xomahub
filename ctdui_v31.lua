-- XOMA / CTDIG bootstrap
-- Build: PASS21-ENDSCREEN-GATE-V31

local environment = typeof(getgenv) == "function" and getgenv() or _G

local function runPatch(url, label)
    local source = game:HttpGet(url)
    local chunk, err = loadstring(source)
    if not chunk then
        error(label .. " compile failed: " .. tostring(err))
    end
    return chunk()
end

local existingSession = environment.CTDIG_SESSION
if type(existingSession) == "table"
    and existingSession.alive == true
    and existingSession.dataModel == game
    and type(existingSession.XOMA) == "table"
    and type(existingSession.XOMA.Run) == "function"
then
    existingSession.XOMA._macro = {
        version = 1,
        map = "Unknown",
        deck = {},
        config = {},
        actions = {},
    }
    existingSession.XOMA._nextId = 0

    runPatch(
        "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/w0_v30.lua",
        "XOMA V30"
    )
    runPatch(
        "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/endaction_v31.lua",
        "XOMA V31"
    )

    existingSession.bootstrapBuild = "PASS21-ENDSCREEN-GATE-V31"
    return existingSession.XOMA
end

local source = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui.lua"
)
local chunk, err = loadstring(source)
if not chunk then
    error("XOMA V31 bootstrap compile failed: " .. tostring(err))
end
local XOMA = chunk()

-- Force the cache-busted patches even if the inner ctdui.lua response was stale.
runPatch(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/w0_v30.lua",
    "XOMA V30"
)
runPatch(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/endaction_v31.lua",
    "XOMA V31"
)

local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS21-ENDSCREEN-GATE-V31"
end

print("[XOMA V31] cache-busted bootstrap loaded")
return XOMA
