-- XOMA Wave 0 safe early-replay gate
-- Build: PASS41-W0-NO-REQUIRE-V39
-- Scope: Wave 0 startup only. Restart/webhook/recorder/action logic untouched.
--
-- PASS40 incorrectly required CTDModule from this hotfix chunk. On Potassium
-- that call can execute under a RobloxScript context and fail with:
--   Cannot require a non-RobloxScript module from a RobloxScript
-- The core already owns/caches CTDModule and performPlace remains authoritative.
-- This gate therefore checks only state that is safe to inspect here: W0, map,
-- Towers, PlaceUnit, recorded surface replication, Ready and Difficulty.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA W0 V33 patch: CTDIG session is unavailable")
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

local originalRunMacroInMatch = session.auto.runMacroInMatch

local function toVector3(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if type(value) == "table" then
        return Vector3.new(
            tonumber(value.x or value.X) or 0,
            tonumber(value.y or value.Y) or 0,
            tonumber(value.z or value.Z) or 0
        )
    end
    return Vector3.zero
end

local function currentWave()
    local map = Workspace:FindFirstChild("Map")
    local config = map and map:FindFirstChild("Configuration")
    local wave = config and config:FindFirstChild("Wave")
    return wave and tonumber(wave.Value) or nil
end

local function currentMapName()
    local map = Workspace:FindFirstChild("Map")
    if not map then
        return "Unknown"
    end
    local trueName = map:FindFirstChild("TrueName")
    return trueName and tostring(trueName.Value) or tostring(map.Name)
end

local function firstWaveZeroPlace(macro)
    if type(macro) ~= "table" or type(macro.actions) ~= "table" then
        return nil
    end
    for _, action in ipairs(macro.actions) do
        if action and action.type == "place"
            and math.max(0, math.floor(tonumber(action.wave) or 0)) == 0
        then
            return action
        end
    end
    return nil
end

local function hasWaveZeroAction(macro)
    if type(macro) ~= "table" or type(macro.actions) ~= "table" then
        return false
    end
    for _, action in ipairs(macro.actions) do
        if math.max(0, math.floor(tonumber(action and action.wave) or 0)) == 0 then
            return true
        end
    end
    return false
end

local function addIgnore(list, object)
    if typeof(object) == "Instance" and not table.find(list, object) then
        list[#list + 1] = object
    end
end

local function safeRecordedSurface(action)
    local map = Workspace:FindFirstChild("Map")
    local towers = Workspace:FindFirstChild("Towers")
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local placeUnit = remotes and remotes:FindFirstChild("PlaceUnit")

    if not map then
        return false, "Map not ready"
    end
    if not towers then
        return false, "Towers not ready"
    end
    if not placeUnit or not placeUnit:IsA("RemoteFunction") then
        return false, "PlaceUnit not ready"
    end

    local position = toVector3(action and action.position)
    if position == Vector3.zero then
        return false, "recorded position unavailable"
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    addIgnore(ignore, towers)
    addIgnore(ignore, map:FindFirstChild("Enemies"))
    addIgnore(ignore, Workspace:FindFirstChild("Projectiles"))
    addIgnore(ignore, player and player.Character)
    params.FilterDescendantsInstances = ignore

    local hit = Workspace:Raycast(
        position + Vector3.new(0, 12, 0),
        Vector3.new(0, -30, 0),
        params
    )

    if not hit or not hit.Instance then
        return false, "recorded surface not replicated"
    end

    return true, hit.Instance:GetFullName()
end

local function waitForSafeW0Start(macro, timeout)
    local action = firstWaveZeroPlace(macro)
    if not action then
        return true
    end

    local deadline = os.clock() + (tonumber(timeout) or 35)
    local lastReason = "waiting"
    local lastLog = 0
    local stable = 0

    while session.alive and os.clock() < deadline do
        local wave = currentWave()

        -- If a slow client already crossed into W1, do not freeze the whole macro.
        -- Let the core replay its recorded W0 action late instead of aborting.
        if wave and wave > 0 then
            warn("[XOMA W0] W0 startup window missed; releasing replay on W" .. tostring(wave))
            return true
        end

        if wave == 0 then
            local ready, detail = safeRecordedSurface(action)
            lastReason = detail or lastReason
            if ready then
                stable = stable + 1
                if stable >= 2 then
                    print("[XOMA W0] safe W0 start ready | " .. tostring(action.unit) .. " | " .. tostring(detail))
                    return true
                end
            else
                stable = 0
            end
        else
            stable = 0
            lastReason = "Wave value not ready"
        end

        if os.clock() - lastLog >= 1 then
            print("[XOMA W0] waiting W0 surface | " .. tostring(lastReason))
            lastLog = os.clock()
        end

        task.wait(0.05)
    end

    return false, lastReason
end

local function tracebackError(err)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

function session.auto.runMacroInMatch(macro)
    if not hasWaveZeroAction(macro) then
        return originalRunMacroInMatch(macro)
    end

    -- Keep the existing Ready/Difficulty flow. Do NOT require CTDModule here.
    local mapDeadline = os.clock() + 20
    while session.alive and os.clock() < mapDeadline do
        local name = currentMapName()
        if name ~= "Unknown" then
            if macro.map and macro.map ~= "" and macro.map ~= "Unknown" and name ~= macro.map then
                return false, "wrong map | macro: " .. tostring(macro.map) .. " | current: " .. tostring(name)
            end
            break
        end
        task.wait(0.05)
    end

    if type(session.auto.verifyCurrentMacroDeck) == "function" then
        local deckDeadline = os.clock() + 15
        local deckOk, deckError
        repeat
            deckOk, deckError = session.auto.verifyCurrentMacroDeck(macro)
            if deckOk then
                break
            end
            task.wait(0.08)
        until not session.alive or os.clock() >= deckDeadline
        if not deckOk then
            return false, "deck: " .. tostring(deckError)
        end
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA W0] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    local w0Ok, w0Error = waitForSafeW0Start(macro, 35)
    if not w0Ok then
        return false, "W0 gate: " .. tostring(w0Error)
    end

    print("[XOMA W0] starting replay on W0 | core placement remains authoritative")

    local ok, replayError = xpcall(function()
        session.recorder.replayMacro(macro)
    end, tracebackError)

    if not ok then
        return false, tostring(replayError)
    end

    return true
end

session.w0Build = "PASS41-W0-NO-REQUIRE-V39"
print("[XOMA W0] safe gate installed | no CTDModule require | Restart untouched")

return session.XOMA
