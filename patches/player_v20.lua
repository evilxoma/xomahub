-- XOMA unified Player patch
-- Build: PASS10-UNIFIED-PLAYER-V20
-- Makes the Replay button execute the same recorder-generated XOMA strategy
-- format that autoexecute uses, while table-backed internal replay calls still
-- go directly to the original replay engine.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.replayMacro) ~= "function"
    or type(session.XOMA) ~= "table"
then
    error("XOMA V20 Player patch: CTDIG session is unavailable")
end

if session.unifiedPlayerV20Installed == true then
    return session.XOMA
end

local originalReplayMacro = session.recorder.replayMacro
local MACRO_FILE = "ctdig.lua"

local function isXomaStrategySource(source)
    return type(source) == "string"
        and source:find("XOMA:Run", 1, true) ~= nil
        and source:find("XOMA:Place", 1, true) ~= nil
end

local function executeStrategyFile()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then
        return originalReplayMacro()
    end

    if not isfile(MACRO_FILE) then
        return originalReplayMacro()
    end

    local readOk, source = pcall(readfile, MACRO_FILE)
    if not readOk or type(source) ~= "string" then
        error("Replay ctdig.lua read failed: " .. tostring(source), 2)
    end

    -- Keep legacy table-format files working through the old loader. Only the
    -- recorder-generated XOMA strategy format is executed directly here.
    if not isXomaStrategySource(source) then
        return originalReplayMacro()
    end

    local compileOk, chunk, compileError = pcall(loadstring, source)
    if not compileOk then
        error("Replay ctdig.lua compile failed: " .. tostring(chunk), 2)
    end
    if type(chunk) ~= "function" then
        error("Replay ctdig.lua compile failed: " .. tostring(compileError), 2)
    end

    -- The strategy itself calls ctdui.lua. PASS10 ctdui detects this live
    -- session, resets only the strategy builder, and returns this same XOMA
    -- object instead of cleaning/reloading the hub.
    local runOk, runResult = xpcall(chunk, function(err)
        if debug and type(debug.traceback) == "function" then
            return debug.traceback(tostring(err), 2)
        end
        return tostring(err)
    end)

    if not runOk then
        error("Replay ctdig.lua runtime failed: " .. tostring(runResult), 2)
    end

    return runResult
end

session.recorder.replayMacro = function(overrideMacro)
    if type(overrideMacro) == "table" and type(overrideMacro.actions) == "table" then
        return originalReplayMacro(overrideMacro)
    end

    return executeStrategyFile()
end

session.unifiedPlayerV20Installed = true
session.replayBuild = "PASS10-UNIFIED-PLAYER-V20"
session.autoBuild = "PASS10-UNIFIED-PLAYER-V20"

return session.XOMA
