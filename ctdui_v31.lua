-- XOMA / CTDIG bootstrap
-- Build: PASS21-ENDSCREEN-GATE-V31

local environment = typeof(getgenv) == "function" and getgenv() or _G
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

    local patchOk, patchResult = pcall(function()
        local source = game:HttpGet(
            "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/endaction_v31.lua"
        )
        local chunk, err = loadstring(source)
        if not chunk then
            error(err)
        end
        return chunk()
    end)
    if not patchOk then
        warn("[XOMA V31] end-action refresh failed: " .. tostring(patchResult))
    end

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

local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS21-ENDSCREEN-GATE-V31"
end

return XOMA
