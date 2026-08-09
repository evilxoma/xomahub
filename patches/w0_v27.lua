-- XOMA Wave 0 / executable Vector3 compatibility patch
-- Build: PASS20-VECTOR3-STRATEGY-V30
-- Recorder strategies call XOMA:Place with real Vector3.new(...) values. The
-- legacy core toVector3 helper only accepted serialized {x,y,z} tables, which
-- collapsed executable strategy positions/rotations to Vector3.zero. Override
-- XOMA:Place here so existing ctdig.lua files keep their recorded coordinates.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA V30 patch: CTDIG session is unavailable")
end

local Workspace = game:GetService("Workspace")

local function encodeVector3(value)
    if typeof(value) == "Vector3" then
        return {
            x = math.round(value.X * 1000) / 1000,
            y = math.round(value.Y * 1000) / 1000,
            z = math.round(value.Z * 1000) / 1000,
        }
    end

    if type(value) == "table" then
        local x = tonumber(value.x or value.X) or 0
        local y = tonumber(value.y or value.Y) or 0
        local z = tonumber(value.z or value.Z) or 0
        return {
            x = math.round(x * 1000) / 1000,
            y = math.round(y * 1000) / 1000,
            z = math.round(z * 1000) / 1000,
        }
    end

    return { x = 0, y = 0, z = 0 }
end

function session.XOMA:Place(unitName, position, wave, rotation)
    self._nextId = self._nextId + 1
    local id = self._nextId

    self._macro.actions[#self._macro.actions + 1] = {
        type = "place",
        id = id,
        unit = tostring(unitName or ""),
        position = encodeVector3(position),
        rotation = encodeVector3(rotation or Vector3.zero),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }

    return {
        __xomaId = id,
        unit = tostring(unitName or ""),
    }
end

function session.auto.waitForPregameFinished(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA V30] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    print("[XOMA V30] Ready + difficulty confirmed | starting W0 replay during pre-game")
    return true
end

session.w0Build = "PASS20-VECTOR3-STRATEGY-V30"
session.positionBuild = "PASS20-VECTOR3-STRATEGY-V30"
return session.XOMA
