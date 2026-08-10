-- XOMA Wave 0 real-placement readiness patch
-- Build: PASS39-W0-PLACEMENT-READY-V39
-- Scope: Wave 0 replay start only. Restart/webhook/recorder/action code untouched.
--
-- Why PASS38 could still miss W0:
-- Voting.Start is not a sufficient placement-ready signal. The replay can be
-- released while the recorded surface/cash/checkcanplace state is not ready, or
-- waitForMatchReady can spend time on recorder source binding that placement does
-- not need. For strategies containing W0 actions, start the replay from the real
-- placement conditions used by the core itself: Wave==0, recorded surface hit,
-- enough cash (when cost is exposed), CTDModule.checkcanplace==true, PlaceUnit
-- present, map/deck valid. Non-W0 strategies keep the existing run path exactly.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA W0 V32 patch: CTDIG session is unavailable")
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
        local wave = math.max(0, math.floor(tonumber(action and action.wave) or 0))
        if wave == 0 and action.type == "place" then
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

local function getCTDModule()
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local moduleScript = modules and modules:FindFirstChild("CTDModule")
    if not moduleScript or not moduleScript:IsA("ModuleScript") then
        return nil
    end
    local ok, module = pcall(require, moduleScript)
    if ok and type(module) == "table" then
        return module
    end
    return nil
end

local function getTags(unitName)
    local units = ReplicatedStorage:FindFirstChild("Units")
    local folder = units and units:FindFirstChild(tostring(unitName or ""))
    return folder and folder:FindFirstChild("Tags") or nil
end

local function addIgnore(list, object)
    if typeof(object) == "Instance" and not table.find(list, object) then
        list[#list + 1] = object
    end
end

local function resolveRecordedSurface(action, module, tags)
    local position = toVector3(action.position)
    if position == Vector3.zero then
        return nil, position, "recorded position is zero"
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}

    local towers = Workspace:FindFirstChild("Towers")
    local map = Workspace:FindFirstChild("Map")
    local enemies = map and map:FindFirstChild("Enemies")
    local projectiles = Workspace:FindFirstChild("Projectiles")

    addIgnore(ignore, towers)
    addIgnore(ignore, enemies)
    addIgnore(ignore, projectiles)
    addIgnore(ignore, player.Character)

    if module and type(module.getplacementmouseignores) == "function" and tags then
        local ok, nativeIgnores = pcall(module.getplacementmouseignores)
        if ok and type(nativeIgnores) == "table" then
            local nativeList = tags:FindFirstChild("Path") and nativeIgnores.Path or nativeIgnores.Normal
            if type(nativeList) == "table" then
                for _, object in ipairs(nativeList) do
                    addIgnore(ignore, object)
                end
            end
        end
    end

    params.FilterDescendantsInstances = ignore

    local hit = Workspace:Raycast(
        position + Vector3.new(0, 12, 0),
        Vector3.new(0, -30, 0),
        params
    )

    if not hit then
        return nil, position, "recorded surface raycast not ready"
    end

    return hit.Instance, hit.Position, nil
end

local function enoughCash(action, module)
    if not module or type(module.gettowerupgradecost) ~= "function" then
        return true, nil, nil
    end

    local okCost, cost = pcall(module.gettowerupgradecost, action.unit, player, { InputLevel = 0 })
    cost = okCost and tonumber(cost) or nil
    if not cost or cost <= 0 then
        return true, cost, nil
    end

    local safe = player:FindFirstChild("LocalSafeData")
    local cashValue = safe and safe:FindFirstChild("CashREADONLY")
    local cash = cashValue and tonumber(cashValue.Value) or nil
    if cash == nil then
        return false, cost, nil
    end

    return cash >= cost, cost, cash
end

local function placementReady(action)
    local placeUnit = ReplicatedStorage:FindFirstChild("Remotes")
    placeUnit = placeUnit and placeUnit:FindFirstChild("PlaceUnit")
    if not placeUnit or not placeUnit:IsA("RemoteFunction") then
        return false, "PlaceUnit not ready"
    end

    if not Workspace:FindFirstChild("Towers") or not Workspace:FindFirstChild("Map") then
        return false, "Map/Towers not ready"
    end

    local module = getCTDModule()
    if not module then
        return false, "CTDModule not ready"
    end

    local tags = getTags(action.unit)
    if not tags then
        return false, "Tags not ready for " .. tostring(action.unit)
    end

    local cashOk, cost, cash = enoughCash(action, module)
    if not cashOk then
        return false, "cash " .. tostring(cash) .. "/" .. tostring(cost)
    end

    local surface, position, surfaceError = resolveRecordedSurface(action, module, tags)
    if not surface then
        return false, surfaceError
    end

    if type(module.checkcanplace) == "function" then
        local checked, valid = pcall(
            module.checkcanplace,
            player,
            surface,
            position,
            tags,
            { TowerName = tostring(action.unit or "") }
        )
        if not checked then
            return false, "checkcanplace error: " .. tostring(valid)
        end
        if valid ~= true then
            return false, "checkcanplace=false"
        end
    end

    return true, surface:GetFullName()
end

local function waitForWaveZeroPlacement(macro, timeout)
    local action = firstWaveZeroPlace(macro)
    if not action then
        return true
    end

    local deadline = os.clock() + (tonumber(timeout) or 35)
    local lastReason
    local lastLog = 0

    while session.alive and os.clock() < deadline do
        local wave = currentWave()

        if wave and wave > 0 then
            warn("[XOMA W0] W0 gate was missed | current W" .. tostring(wave) .. " | last=" .. tostring(lastReason))
            return true
        end

        if wave == 0 then
            local ready, detail = placementReady(action)
            if ready then
                print("[XOMA W0] REAL placement ready on W0 | " .. tostring(action.unit) .. " | " .. tostring(detail))
                return true
            end
            lastReason = detail
        else
            lastReason = "Wave value not ready"
        end

        if os.clock() - lastLog >= 1 then
            print("[XOMA W0] waiting real W0 placement | " .. tostring(lastReason))
            lastLog = os.clock()
        end
        task.wait(0.03)
    end

    return false, lastReason or "W0 placement readiness timed out"
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

    -- Validate the map as soon as it is replicated, without waiting for recorder
    -- source binding. replayMacro has its own deck/map checks as a second guard.
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

    local w0Ok, w0Error = waitForWaveZeroPlacement(macro, 35)
    if not w0Ok then
        return false, "W0 gate: " .. tostring(w0Error)
    end

    print("[XOMA W0] starting replay immediately from real W0 placement-ready state")

    local ok, replayError = xpcall(function()
        session.recorder.replayMacro(macro)
    end, tracebackError)

    if not ok then
        return false, tostring(replayError)
    end

    return true
end

session.w0Build = "PASS39-W0-PLACEMENT-READY-V39"
print("[XOMA W0] real-placement gate installed | W0 starts on actual place-ready state")

return session.XOMA
