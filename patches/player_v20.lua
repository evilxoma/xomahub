-- XOMA unified Player patch
-- Build: PASS13-UNIFIED-PLAYER-READY-V23
-- Makes Replay use the recorder-generated XOMA strategy format and installs the
-- exact Ready callback patch before replay can enter the pre-game gate.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.replayMacro) ~= "function"
    or type(session.XOMA) ~= "table"
then
    error("XOMA V20 Player patch: CTDIG session is unavailable")
end

-- Separate chunk: does not increase the already-large core chunk's top-level
-- local/register count.
local readySource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/ready_v21.lua"
)
local readyChunk, readyError = loadstring(readySource)
if not readyChunk then
    error("XOMA Ready patch compile failed: " .. tostring(readyError))
end
readyChunk()

if session.unifiedPlayerV20Installed == true then
    session.replayBuild = "PASS13-UNIFIED-PLAYER-READY-V23"
    session.autoBuild = "PASS13-UNIFIED-PLAYER-READY-V23"
    return session.XOMA
end

local originalReplayMacro = session.recorder.replayMacro
local MACRO_FILE = "ctdig.lua"

local function isXomaStrategySource(source)
    return type(source) == "string"
        and source:find("CTDIG / XOMA AUTOEXEC STRATEGY", 1, true) ~= nil
        and source:find("XOMA:Run", 1, true) ~= nil
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

    -- The strategy itself calls ctdui.lua. ctdui detects this live session,
    -- resets only the strategy builder, and returns the same XOMA object.
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
session.replayBuild = "PASS13-UNIFIED-PLAYER-READY-V23"
session.autoBuild = "PASS13-UNIFIED-PLAYER-READY-V23"

return session.XOMA
