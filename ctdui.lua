-- CTDIG / XOMA strategy core
-- Host this file as raw GitHub content and load it from an autoexecute strategy.
--
-- Example:
-- local XOMA = loadstring(game:HttpGet("RAW_GITHUB/ctdui.lua"))()
-- XOMA:Map("Grassland")
-- XOMA:Deck({"Bandit", "Archer"})
-- local U1 = XOMA:Place("Bandit", Vector3.new(-17.865, 28.313, 2.641), 0)
-- XOMA:Upgrade(U1, 1, 1)
-- XOMA:Target(U1, "Strongest", 4)
-- XOMA:Sell(U1, 12)
-- XOMA:Run()

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)

local XOMA = {}
XOMA.__index = XOMA

local state = {
    map = nil,
    deck = {},
    actions = {},
    nextId = 1,
    running = false,
    stopped = false,
    runtime = {},
    debug = true,
}

local function log(...)
    if not state.debug then
        return
    end
    local values = { ... }
    for i = 1, #values do
        values[i] = tostring(values[i])
    end
    print("[XOMA] " .. table.concat(values, " "))
end

local function notify(title, text, duration)
    log(title .. ":", text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = tostring(title),
            Text = tostring(text),
            Duration = tonumber(duration) or 4,
        })
    end)
end

local ctdModule
local function getCTDModule()
    if ctdModule then
        return ctdModule
    end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local moduleScript = modules and modules:FindFirstChild("CTDModule")
    if not moduleScript then
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if ok and type(result) == "table" then
        ctdModule = result
        return result
    end

    return nil
end

local function getMap()
    return Workspace:FindFirstChild("Map")
end

local function getMapName()
    local map = getMap()
    local trueName = map and map:FindFirstChild("TrueName")
    if trueName and trueName:IsA("ValueBase") then
        return tostring(trueName.Value)
    end
    return map and map.Name or "Unknown"
end

local function getWave()
    local map = getMap()
    local config = map and map:FindFirstChild("Configuration")
    local wave = config and config:FindFirstChild("Wave")
    return wave and tonumber(wave.Value) or 0
end

local function isLobby()
    return Workspace:FindFirstChild("Elevators") ~= nil
        and Workspace:FindFirstChild("Towers") == nil
end

local function isMatch()
    local map = getMap()
    return Workspace:FindFirstChild("Towers") ~= nil
        and map ~= nil
        and map:FindFirstChild("Configuration") ~= nil
end

local function getOwner(tower)
    if not tower then
        return nil
    end

    local config = tower:FindFirstChild("Configuration")
    local owner = config and config:FindFirstChild("Owner")
    if owner then
        local value = owner.Value
        if typeof(value) == "Instance" then
            return value.Name
        end
        return tostring(value)
    end

    local attribute = tower:GetAttribute("Owner")
    return attribute and tostring(attribute) or nil
end

local function isMine(tower)
    return tower and tower.Parent and getOwner(tower) == player.Name
end

local function getLevel(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local level = config and config:FindFirstChild("Level")
    return level and tonumber(level.Value) or 0
end

local function getTarget(tower)
    if not tower then
        return nil
    end

    local config = tower:FindFirstChild("Configuration")
    local other = tower:FindFirstChild("OtherConfig")
        or (config and config:FindFirstChild("OtherConfig"))
    local targets = other and other:FindFirstChild("Targets")
    return targets and tostring(targets.Value) or nil
end

local function getRoot(object)
    if not object then
        return nil
    end
    if object:IsA("BasePart") then
        return object
    end
    if object:IsA("Model") and object.PrimaryPart then
        return object.PrimaryPart
    end
    local named = object:FindFirstChild("HumanoidRootPart", true)
        or object:FindFirstChild("RootPart", true)
        or object:FindFirstChild("Torso", true)
    if named and named:IsA("BasePart") then
        return named
    end
    return object:FindFirstChildWhichIsA("BasePart", true)
end

local function toVector3(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if typeof(value) == "CFrame" then
        return value.Position
    end
    if type(value) == "table" then
        return Vector3.new(
            tonumber(value.x or value.X or value[1]) or 0,
            tonumber(value.y or value.Y or value[2]) or 0,
            tonumber(value.z or value.Z or value[3]) or 0
        )
    end
    return Vector3.zero
end

local function normalizeRotation(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if type(value) == "table" then
        return Vector3.new(
            tonumber(value.x or value.X or value[1]) or 0,
            tonumber(value.y or value.Y or value[2]) or 0,
            tonumber(value.z or value.Z or value[3]) or 0
        )
    end
    return Vector3.zero
end

local function getDeckSnapshot()
    local data = player:FindFirstChild("PlayerData")
    local loadout = data and data:FindFirstChild("Loadout")
    if not loadout then
        return {}
    end

    local slots = {}
    for _, child in ipairs(loadout:GetChildren()) do
        if child:IsA("ValueBase") then
            local index = tonumber(child.Name:match("^Tower(%d+)$"))
            if index then
                slots[#slots + 1] = {
                    index = index,
                    value = tostring(child.Value),
                }
            end
        end
    end

    table.sort(slots, function(a, b)
        return a.index < b.index
    end)

    local result = {}
    for _, slot in ipairs(slots) do
        result[#result + 1] = slot.value
    end
    return result
end

local function compactDeck(deck)
    local result = {}
    for _, name in ipairs(deck or {}) do
        if name and name ~= "" and name ~= "None" then
            result[#result + 1] = tostring(name)
        end
    end
    return table.concat(result, ", ")
end

local function deckContains(deck, required)
    local have = {}
    for _, name in ipairs(deck or {}) do
        if name and name ~= "None" then
            have[tostring(name)] = true
        end
    end

    for _, name in ipairs(required or {}) do
        if not have[tostring(name)] then
            return false, tostring(name)
        end
    end

    return true
end

local function deckExact(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end
    for i = 1, #a do
        if tostring(a[i]) ~= tostring(b[i]) then
            return false
        end
    end
    return true
end

local function loadoutDeck(data)
    local towers = type(data) == "table" and data.Towers or nil
    if type(towers) ~= "table" then
        return {}
    end

    local slots = {}
    for key, value in pairs(towers) do
        local index = tonumber(tostring(key):match("^Tower(%d+)$"))
        if index then
            slots[#slots + 1] = {
                index = index,
                value = tostring(value),
            }
        end
    end

    table.sort(slots, function(a, b)
        return a.index < b.index
    end)

    local result = {}
    for _, slot in ipairs(slots) do
        result[#result + 1] = slot.value
    end
    return result
end

local function requiredUnits()
    local result = {}
    local seen = {}

    for _, name in ipairs(state.deck or {}) do
        name = tostring(name or "")
        if name ~= "" and name ~= "None" and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end

    if #result == 0 then
        for _, action in ipairs(state.actions) do
            if action.type == "place" and action.unit and not seen[action.unit] then
                seen[action.unit] = true
                result[#result + 1] = action.unit
            end
        end
    end

    return result
end

local function ensureDeckInLobby()
    local required = requiredUnits()
    if #required == 0 then
        return true
    end

    local data = player:WaitForChild("PlayerData", 20)
    local loadout = data and data:WaitForChild("Loadout", 20)
    if not loadout then
        return false, "PlayerData.Loadout not found"
    end

    local current = getDeckSnapshot()
    local alreadyOkay = deckContains(current, required)
    if alreadyOkay then
        log("Deck OK:", compactDeck(current))
        return true
    end

    local module = getCTDModule()
    if not module or type(module.PlayerLoadouts) ~= "function" then
        return false, "CTDModule.PlayerLoadouts unavailable"
    end

    if type(module.waitforload) == "function" then
        pcall(module.waitforload)
    end

    local ok, loadouts = pcall(module.PlayerLoadouts, player, "GetLoadouts")
    if not ok or type(loadouts) ~= "table" then
        return false, "GetLoadouts failed: " .. tostring(loadouts)
    end

    local exactCode
    local fallbackCode
    for code, loadoutData in pairs(loadouts) do
        local deck = loadoutDeck(loadoutData)
        local contains = deckContains(deck, required)
        if contains then
            fallbackCode = fallbackCode or code
            if #state.deck > 0 and deckExact(deck, state.deck) then
                exactCode = code
                break
            end
        end
    end

    local code = exactCode or fallbackCode
    if code == nil then
        return false, "No saved loadout contains: " .. table.concat(required, ", ")
    end

    log("Equipping loadout", code)
    local equipOk, equipResult = pcall(module.PlayerLoadouts, player, "EquipLoadout", {
        loadoutcode = tostring(code),
    })
    if not equipOk then
        return false, "EquipLoadout failed: " .. tostring(equipResult)
    end

    local started = os.clock()
    while os.clock() - started < 8 do
        local deck = getDeckSnapshot()
        if deckContains(deck, required) then
            notify("XOMA", "Deck equipped: " .. compactDeck(deck), 3)
            return true
        end
        task.wait(0.1)
    end

    return false, "Deck did not update. Current: " .. compactDeck(getDeckSnapshot())
end

local function isElevatorRoom(object)
    if not object or not (object:IsA("Folder") or object:IsA("Model")) then
        return false
    end

    return object:FindFirstChild("CurrentMap") ~= nil
        and object:FindFirstChild("RoomOwner") ~= nil
        and object:FindFirstChild("RoomEntryMode") ~= nil
        and object:FindFirstChild("Limit") ~= nil
        and object:FindFirstChild("MapMode") ~= nil
        and object:FindFirstChild("CurrentPlayers") ~= nil
        and object:FindFirstChild("baseplate", true) ~= nil
end

local function collectElevatorRooms()
    local root = Workspace:FindFirstChild("Elevators")
    local result = {}
    if not root then
        return result
    end

    for _, object in ipairs(root:GetDescendants()) do
        if isElevatorRoom(object) then
            result[#result + 1] = object
        end
    end

    table.sort(result, function(a, b)
        local ao = a:FindFirstChild("RoomOwner")
        local bo = b:FindFirstChild("RoomOwner")
        local aFree = not ao or tostring(ao.Value) == "" or tostring(ao.Value) == player.Name
        local bFree = not bo or tostring(bo.Value) == "" or tostring(bo.Value) == player.Name
        if aFree ~= bFree then
            return aFree
        end
        return a:GetFullName() < b:GetFullName()
    end)

    return result
end

local function playerInsideElevator(room)
    if not room then
        return false
    end

    local owner = room:FindFirstChild("RoomOwner")
    if owner and tostring(owner.Value) == player.Name then
        return true
    end

    local currentPlayers = room:FindFirstChild("CurrentPlayers")
    if currentPlayers then
        if currentPlayers:FindFirstChild(player.Name) then
            return true
        end
        for _, child in ipairs(currentPlayers:GetChildren()) do
            if child:IsA("ObjectValue") and child.Value == player then
                return true
            end
        end
    end

    return false
end

local function moveIntoElevator(room)
    local character = player.Character or player.CharacterAdded:Wait()
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Torso")
        or character.PrimaryPart
    local plate = room and room:FindFirstChild("baseplate", true)

    if not root or not plate or not plate:IsA("BasePart") then
        return false, "Elevator root/baseplate missing"
    end

    root.CFrame = plate.CFrame * CFrame.new(0, 3, 0)

    if typeof(firetouchinterest) == "function" then
        pcall(function()
            firetouchinterest(root, plate, 0)
            task.wait(0.05)
            firetouchinterest(root, plate, 1)
        end)
    end

    local started = os.clock()
    while os.clock() - started < 4 do
        if playerInsideElevator(room) then
            return true
        end
        task.wait(0.1)
    end

    -- The server can still accept OpenRoom even before RoomOwner replicates.
    return true
end

local function openMapFromLobby()
    if type(state.map) ~= "string" or state.map == "" then
        return false, "XOMA:Map(...) was not set"
    end

    local elevatorsRemote = remotes:FindFirstChild("Elevators")
    if not elevatorsRemote or not elevatorsRemote:IsA("RemoteFunction") then
        return false, "ReplicatedStorage.Remotes.Elevators missing"
    end

    local rooms = collectElevatorRooms()
    if #rooms == 0 then
        return false, "No elevator rooms found under workspace.Elevators"
    end

    local lastError = "No free elevator accepted OpenRoom"

    for index, room in ipairs(rooms) do
        local owner = room:FindFirstChild("RoomOwner")
        if not owner or tostring(owner.Value) == "" or tostring(owner.Value) == player.Name then
            log(string.format("Trying elevator %d/%d: %s", index, #rooms, room:GetFullName()))

            local moved, moveError = moveIntoElevator(room)
            if moved then
                local payload = {
                    Gamemode = "Classic",
                    CurrentMap = state.map,
                    Limit = 1,
                    RoomEntryMode = "FriendsOnly",
                    MapMode = "Classic",
                    MapModifiers = {},
                }

                local openOk, opened = pcall(function()
                    return elevatorsRemote:InvokeServer(room, "OpenRoom", payload)
                end)

                if openOk and opened == true then
                    notify("XOMA", "Room opened: " .. state.map .. " | FriendsOnly", 3)
                    task.wait(0.35)

                    local teleportOk, teleportResult = pcall(function()
                        return elevatorsRemote:InvokeServer(room, "Teleport")
                    end)

                    if teleportOk then
                        notify("XOMA", "Teleport requested: " .. state.map, 4)
                        return true
                    end

                    lastError = "Teleport failed: " .. tostring(teleportResult)
                else
                    lastError = openOk
                        and ("OpenRoom rejected elevator " .. tostring(index) .. " (" .. tostring(opened) .. ")")
                        or tostring(opened)
                end
            else
                lastError = tostring(moveError)
            end
        end
    end

    return false, lastError
end

local function canonicalUnitObject(unitName)
    local units = ReplicatedStorage:FindFirstChild("Units")
    local unitFolder = units and units:FindFirstChild(unitName)
    local levels = unitFolder and unitFolder:FindFirstChild("Levels")
    local levelZero = levels and levels:FindFirstChild("0")
    local objectFolder = levelZero and levelZero:FindFirstChild("Object")
    if not objectFolder then
        return nil
    end

    return objectFolder:FindFirstChild(unitName)
        or objectFolder:FindFirstChildWhichIsA("Model")
        or objectFolder:FindFirstChildWhichIsA("Folder")
end

local function unitTags(unitName)
    local units = ReplicatedStorage:FindFirstChild("Units")
    local folder = units and units:FindFirstChild(unitName)
    return folder and folder:FindFirstChild("Tags") or nil
end

local function makeRaycastParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = false

    local ignore = {}
    local towers = Workspace:FindFirstChild("Towers")
    if towers then
        ignore[#ignore + 1] = towers
    end

    local map = Workspace:FindFirstChild("Map")
    local enemies = map and map:FindFirstChild("Enemies")
    if enemies then
        ignore[#ignore + 1] = enemies
    end

    local projectiles = Workspace:FindFirstChild("Projectiles")
    if projectiles then
        ignore[#ignore + 1] = projectiles
    end

    local workspaceService = Workspace:FindFirstChild("WorkspaceScriptService")
    local objectValues = workspaceService and workspaceService:FindFirstChild("ObjectValues")
    local server = objectValues and objectValues:FindFirstChild("Server")
    local placeboxes = server and server:FindFirstChild("UnitPlaceboxes")
    if placeboxes then
        ignore[#ignore + 1] = placeboxes
    end

    params.FilterDescendantsInstances = ignore
    return params
end

local function validatePlacementSurface(unitName, surface, position)
    if not surface then
        return false
    end

    local module = getCTDModule()
    local tags = unitTags(unitName)
    if module and type(module.checkcanplace) == "function" and tags then
        local ok, valid = pcall(module.checkcanplace, player, surface, position, tags, {
            TowerName = unitName,
        })
        return ok and valid == true
    end

    return true
end

local function findPlacementSurface(unitName, position)
    local params = makeRaycastParams()
    local offsets = {
        Vector3.new(0, 0, 0),
        Vector3.new(0.35, 0, 0),
        Vector3.new(-0.35, 0, 0),
        Vector3.new(0, 0, 0.35),
        Vector3.new(0, 0, -0.35),
    }

    for _, offset in ipairs(offsets) do
        local origin = position + offset + Vector3.new(0, 40, 0)
        local result = Workspace:Raycast(origin, Vector3.new(0, -90, 0), params)
        if result then
            local candidatePosition = position
            if math.abs(result.Position.Y - position.Y) <= 8 then
                candidatePosition = Vector3.new(position.X, result.Position.Y, position.Z)
            end

            if validatePlacementSurface(unitName, result.Instance, candidatePosition) then
                return result.Instance, candidatePosition
            end
        end
    end

    local map = Workspace:FindFirstChild("Map")
    if map then
        local candidates = {}
        for _, object in ipairs(map:GetDescendants()) do
            if object:IsA("BasePart") then
                local distance = (object.Position - position).Magnitude
                if distance <= 80 then
                    candidates[#candidates + 1] = {
                        object = object,
                        distance = distance,
                    }
                end
            end
        end

        table.sort(candidates, function(a, b)
            return a.distance < b.distance
        end)

        local limit = math.min(#candidates, 80)
        for i = 1, limit do
            local object = candidates[i].object
            if validatePlacementSurface(unitName, object, position) then
                return object, position
            end
        end
    end

    return nil, position
end

local function getCash()
    local safe = player:FindFirstChild("LocalSafeData")
    local cash = safe and safe:FindFirstChild("CashREADONLY")
    return cash and tonumber(cash.Value) or nil
end

local function placementCost(unitName)
    local module = getCTDModule()
    if module and type(module.gettowerupgradecost) == "function" then
        local ok, value = pcall(module.gettowerupgradecost, unitName, player, {
            InputLevel = 0,
        })
        if ok then
            return tonumber(value)
        end
    end
    return nil
end

local function upgradeCost(tower)
    local info = tower and tower:FindFirstChild("AdditionalInfo")
    local value = info and info:FindFirstChild("NextUpgradeCost")
    return value and tonumber(value.Value) or nil
end

local function waitForMoney(cost)
    if not cost then
        return not state.stopped
    end

    while not state.stopped do
        local cash = getCash()
        if not cash or cash >= cost then
            return true
        end
        task.wait(0.05)
    end

    return false
end

local function towerNameMatches(tower, unitName)
    if tower.Name == unitName then
        return true
    end

    local config = tower:FindFirstChild("Configuration")
    local value = config and (config:FindFirstChild("TowerName") or config:FindFirstChild("Name"))
    return value and tostring(value.Value) == unitName or false
end

local function performPlace(action)
    local unit = canonicalUnitObject(action.unit)
    if not unit then
        return nil, "Unit object not found: " .. tostring(action.unit)
    end

    if not waitForMoney(placementCost(action.unit)) then
        return nil, "stopped"
    end

    local position = toVector3(action.position)
    local surface, finalPosition = findPlacementSurface(action.unit, position)
    if not surface then
        return nil, "No valid placement surface near " .. tostring(position)
    end

    local placeRemote = remotes:FindFirstChild("PlaceUnit")
    if not placeRemote or not placeRemote:IsA("RemoteFunction") then
        return nil, "Remotes.PlaceUnit missing"
    end

    local towers = Workspace:FindFirstChild("Towers")
    if not towers then
        return nil, "workspace.Towers missing"
    end

    local before = {}
    for _, tower in ipairs(towers:GetChildren()) do
        before[tower] = true
    end

    local ok, result = pcall(function()
        return placeRemote:InvokeServer(
            unit,
            finalPosition,
            normalizeRotation(action.rotation),
            true,
            surface
        )
    end)

    if not ok then
        return nil, tostring(result)
    end
    if result == nil then
        return nil, "Server rejected placement"
    end

    local started = os.clock()
    while not state.stopped and os.clock() - started < 3 do
        if typeof(result) == "Instance" and result.Parent == towers and isMine(result) then
            return result
        end

        local best
        local bestDistance = math.huge
        for _, tower in ipairs(towers:GetChildren()) do
            if not before[tower] and isMine(tower) and towerNameMatches(tower, action.unit) then
                local root = getRoot(tower)
                local distance = root and (root.Position - finalPosition).Magnitude or math.huge
                if distance < bestDistance then
                    bestDistance = distance
                    best = tower
                end
            end
        end

        if best and bestDistance <= 12 then
            return best
        end

        task.wait()
    end

    return nil, "Placement not confirmed in workspace.Towers"
end

local function performUpgrade(tower, desiredLevel)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    desiredLevel = tonumber(desiredLevel) or (getLevel(tower) + 1)
    if getLevel(tower) >= desiredLevel then
        return true
    end

    local upgradeRemote = remotes:FindFirstChild("UpgradeUnit")
    if not upgradeRemote or not upgradeRemote:IsA("RemoteEvent") then
        return false, "Remotes.UpgradeUnit missing"
    end

    while not state.stopped and tower.Parent and getLevel(tower) < desiredLevel do
        if not waitForMoney(upgradeCost(tower)) then
            return false, "stopped"
        end

        local before = getLevel(tower)
        local ok, err = pcall(function()
            upgradeRemote:FireServer(tower)
        end)
        if not ok then
            return false, tostring(err)
        end

        local started = os.clock()
        while not state.stopped and tower.Parent and os.clock() - started < 3 do
            if getLevel(tower) > before then
                break
            end
            task.wait()
        end

        if getLevel(tower) <= before then
            task.wait(0.15)
        end
    end

    return tower.Parent ~= nil and getLevel(tower) >= desiredLevel,
        "Server did not reach requested level"
end

local function performTarget(tower, mode)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    mode = tostring(mode)
    if getTarget(tower) == mode then
        return true
    end

    local targetRemote = remotes:FindFirstChild("TargetUnit")
    if not targetRemote or not targetRemote:IsA("RemoteFunction") then
        return false, "Remotes.TargetUnit missing"
    end

    for _ = 1, 32 do
        if state.stopped or not tower.Parent then
            return false, "stopped"
        end

        if getTarget(tower) == mode then
            return true
        end

        pcall(function()
            targetRemote:InvokeServer(tower)
        end)
        task.wait(0.06)
    end

    return getTarget(tower) == mode, "Target mode not reached: " .. mode
end

local function performAbility(tower, ability)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    ability = tostring(ability or "Ability1")
    local module = getCTDModule()
    local cooldown = tower:FindFirstChild(ability .. "Cooldown")
        or (tower:FindFirstChild("Configuration") and tower.Configuration:FindFirstChild(ability .. "Cooldown"))

    if cooldown and tonumber(cooldown.Value) and tonumber(cooldown.Value) > 0 then
        return false, "ability cooldown"
    end

    if module and type(module.DoTowerAbilities) == "function" then
        local ok = pcall(module.DoTowerAbilities, tower, "ActivateAbility", {
            abilitycode = ability,
        })
        if ok then
            return true
        end
    end

    local remote = remotes:FindFirstChild("CTDModuleActivateSkillServer")
    if remote and remote:IsA("RemoteEvent") then
        local ok, err = pcall(function()
            remote:FireServer(tower, "ActivateAbility", {
                abilitycode = ability,
            })
        end)
        return ok, ok and nil or tostring(err)
    end

    return false, "Ability handler missing"
end

local function performSell(tower)
    if not tower or not tower.Parent then
        return true
    end

    local removeRemote = remotes:FindFirstChild("RemoveUnit")
    if not removeRemote or not removeRemote:IsA("RemoteEvent") then
        return false, "Remotes.RemoveUnit missing"
    end

    local ok, err = pcall(function()
        removeRemote:FireServer(tower)
    end)
    if not ok then
        return false, tostring(err)
    end

    local started = os.clock()
    while tower.Parent and not state.stopped and os.clock() - started < 2.5 do
        task.wait()
    end

    return not tower.Parent, "Server rejected sell"
end

local function getNativeAutoSkipSetting()
    local data = player:FindFirstChild("PlayerData")
    local settings = data and data:FindFirstChild("Settings")
    return settings and settings:FindFirstChild("AutoSkip")
end

local function getSettingsRemote()
    local playerGui = player:FindFirstChild("PlayerGui")
    local buttons = playerGui and playerGui:FindFirstChild("Buttons")
    local settingsFrame = buttons and buttons:FindFirstChild("SettingsFrame")
    local mainFrame = settingsFrame and settingsFrame:FindFirstChild("MainFrame")
    local controller = mainFrame and mainFrame:FindFirstChild("LocalScript")
    local remote = controller and controller:FindFirstChild("RemoteEvent")
    if remote and remote:IsA("RemoteEvent") then
        return remote
    end
    return nil
end

local function setNativeAutoSkip(enabled)
    local setting = getNativeAutoSkipSetting()
    if not setting then
        return false, "PlayerData.Settings.AutoSkip missing"
    end

    if setting.Value == enabled then
        return true
    end

    local remote = getSettingsRemote()
    if not remote then
        return false, "Settings AutoSkip RemoteEvent missing"
    end

    local ok, err = pcall(function()
        remote:FireServer("AutoSkip")
    end)
    if not ok then
        return false, tostring(err)
    end

    local started = os.clock()
    while os.clock() - started < 2 do
        if setting.Value == enabled then
            return true
        end
        task.wait(0.05)
    end

    return setting.Value == enabled, "AutoSkip did not change"
end

local function performSkip()
    local gameVals = Workspace:FindFirstChild("GameVals")
    local able = gameVals and gameVals:FindFirstChild("AbleToSkip")
    local map = getMap()

    local started = os.clock()
    while not state.stopped and os.clock() - started < 45 do
        if (able and able.Value == true) or (map and map:FindFirstChild("CanSkip")) then
            break
        end
        task.wait(0.05)
    end

    if state.stopped then
        return false, "stopped"
    end

    local setting = getNativeAutoSkipSetting()
    local wasEnabled = setting and setting.Value == true or false
    local beforeWave = getWave()

    local ok, err = setNativeAutoSkip(true)
    if not ok then
        return false, err
    end

    started = os.clock()
    while not state.stopped and os.clock() - started < 8 do
        if getWave() ~= beforeWave then
            if not wasEnabled then
                setNativeAutoSkip(false)
            end
            return true
        end
        task.wait(0.05)
    end

    if not wasEnabled then
        setNativeAutoSkip(false)
    end

    return false, "Skip not confirmed"
end

local function waitForWave(targetWave, index, total, actionType)
    targetWave = math.max(0, math.floor(tonumber(targetWave) or 0))
    while not state.stopped do
        local current = getWave()
        if current >= targetWave then
            return true
        end
        log(string.format(
            "Action %d/%d waiting W%d (now W%d): %s",
            index or 0,
            total or 0,
            targetWave,
            current,
            tostring(actionType)
        ))
        task.wait(0.12)
    end
    return false
end

local function placeActionById(id)
    for _, action in ipairs(state.actions) do
        if action.type == "place" and action.id == id then
            return action
        end
    end
    return nil
end

local function ensureRuntime(id)
    local runtime = state.runtime[id]
    if runtime then
        return runtime
    end

    runtime = {
        tower = nil,
        level = 0,
        target = nil,
        sold = false,
    }
    state.runtime[id] = runtime
    return runtime
end

local function ensureTower(id)
    local runtime = ensureRuntime(id)
    if runtime.sold then
        return nil, "tower #" .. tostring(id) .. " was sold"
    end

    if runtime.tower and runtime.tower.Parent then
        return runtime.tower
    end

    local original = placeActionById(id)
    if not original then
        return nil, "Place action missing for tower #" .. tostring(id)
    end

    log("Restoring dead/missing tower #" .. tostring(id))
    local tower, err = performPlace(original)
    if not tower then
        return nil, err
    end

    runtime.tower = tower

    if runtime.level and runtime.level > 0 then
        local ok, upgradeError = performUpgrade(tower, runtime.level)
        if not ok then
            return nil, upgradeError
        end
    end

    if runtime.target and getTarget(tower) ~= runtime.target then
        local ok, targetError = performTarget(tower, runtime.target)
        if not ok then
            return nil, targetError
        end
    end

    return tower
end

local function executeMatch()
    if state.map and state.map ~= "" then
        local currentMap = getMapName()
        if currentMap ~= "Unknown" and currentMap ~= state.map then
            return false, "Map mismatch. Required " .. state.map .. ", current " .. currentMap
        end
    end

    local required = requiredUnits()
    if #required > 0 then
        local deck = getDeckSnapshot()
        local deckOk, missing = deckContains(deck, required)
        if not deckOk then
            return false, "Current match deck missing " .. tostring(missing)
                .. " | current: " .. compactDeck(deck)
        end
    end

    state.runtime = {}
    local total = #state.actions

    for index, action in ipairs(state.actions) do
        if state.stopped then
            return false, "stopped"
        end

        if not waitForWave(action.wave, index, total, action.type) then
            return false, "stopped"
        end

        log(string.format("%d/%d W%d %s", index, total, tonumber(action.wave) or 0, action.type))

        if action.type == "place" then
            local runtime = ensureRuntime(action.id)
            while not state.stopped do
                local tower, err = performPlace(action)
                if tower then
                    runtime.tower = tower
                    runtime.level = getLevel(tower)
                    runtime.target = getTarget(tower)
                    notify("XOMA", "Placed " .. action.unit .. " #" .. tostring(action.id), 2)
                    break
                end
                log("Place retry #" .. tostring(action.id) .. ":", err)
                task.wait(0.25)
            end

        elseif action.type == "upgrade" then
            local tower, restoreError = ensureTower(action.id)
            if not tower then
                return false, restoreError
            end

            local ok, err = performUpgrade(tower, action.level)
            if not ok then
                return false, err
            end
            local runtime = ensureRuntime(action.id)
            runtime.level = math.max(runtime.level or 0, tonumber(action.level) or getLevel(tower))

        elseif action.type == "target" then
            local tower, restoreError = ensureTower(action.id)
            if not tower then
                return false, restoreError
            end

            local ok, err = performTarget(tower, action.mode)
            if not ok then
                return false, err
            end
            ensureRuntime(action.id).target = action.mode

        elseif action.type == "ability" then
            local tower, restoreError = ensureTower(action.id)
            if not tower then
                return false, restoreError
            end

            while not state.stopped do
                local ok, err = performAbility(tower, action.ability)
                if ok then
                    break
                end
                if err ~= "ability cooldown" then
                    return false, err
                end
                task.wait(0.1)
            end

        elseif action.type == "sell" then
            local tower, restoreError = ensureTower(action.id)
            if not tower then
                return false, restoreError
            end

            local ok, err = performSell(tower)
            if not ok then
                return false, err
            end

            local runtime = ensureRuntime(action.id)
            runtime.sold = true
            runtime.tower = nil

        elseif action.type == "skip" then
            local ok, err = performSkip()
            if not ok then
                return false, err
            end
        else
            return false, "Unsupported action: " .. tostring(action.type)
        end
    end

    return true
end

function XOMA:Reset()
    state.map = nil
    state.deck = {}
    state.actions = {}
    state.nextId = 1
    state.running = false
    state.stopped = false
    state.runtime = {}
    return self
end

function XOMA:Debug(enabled)
    state.debug = enabled ~= false
    return self
end

function XOMA:Map(name)
    state.map = tostring(name or "")
    return self
end

function XOMA:Deck(deck)
    state.deck = {}
    if type(deck) == "table" then
        for _, name in ipairs(deck) do
            name = tostring(name or "")
            if name ~= "" then
                state.deck[#state.deck + 1] = name
            end
        end
    end
    return self
end

function XOMA:Place(unitName, position, wave, rotation)
    local id = state.nextId
    state.nextId = state.nextId + 1

    state.actions[#state.actions + 1] = {
        type = "place",
        id = id,
        unit = tostring(unitName),
        position = toVector3(position),
        rotation = normalizeRotation(rotation),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }

    return id
end

function XOMA:Upgrade(id, level, wave)
    state.actions[#state.actions + 1] = {
        type = "upgrade",
        id = tonumber(id),
        level = tonumber(level),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }
    return self
end

function XOMA:Target(id, mode, wave)
    state.actions[#state.actions + 1] = {
        type = "target",
        id = tonumber(id),
        mode = tostring(mode),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }
    return self
end

function XOMA:Ability(id, ability, wave)
    state.actions[#state.actions + 1] = {
        type = "ability",
        id = tonumber(id),
        ability = tostring(ability or "Ability1"),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }
    return self
end

function XOMA:Sell(id, wave)
    state.actions[#state.actions + 1] = {
        type = "sell",
        id = tonumber(id),
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }
    return self
end

function XOMA:Skip(wave)
    state.actions[#state.actions + 1] = {
        type = "skip",
        wave = math.max(0, math.floor(tonumber(wave) or 0)),
    }
    return self
end

function XOMA:Stop()
    state.stopped = true
    state.running = false
    return self
end

function XOMA:GetState()
    return state
end

function XOMA:Run()
    if state.running then
        return false, "XOMA already running"
    end

    state.running = true
    state.stopped = false

    local contextStarted = os.clock()
    while not state.stopped and os.clock() - contextStarted < 30 do
        if isLobby() then
            notify("XOMA", "Lobby detected | checking deck", 3)

            local deckOk, deckError = ensureDeckInLobby()
            if not deckOk then
                state.running = false
                notify("XOMA deck error", deckError, 8)
                return false, deckError
            end

            local lobbyOk, lobbyError = openMapFromLobby()
            state.running = false
            if not lobbyOk then
                notify("XOMA lobby error", lobbyError, 8)
                return false, lobbyError
            end

            -- Teleport changes place. The autoexecute strategy will run again
            -- and rebuild this same action list in the match server.
            return true
        end

        if isMatch() then
            notify("XOMA", "Match detected | replay starting", 3)
            local ok, err = executeMatch()
            state.running = false

            if ok then
                notify("XOMA", "Strategy completed", 5)
                return true
            end

            notify("XOMA replay error", err, 8)
            return false, err
        end

        log("Waiting for lobby/match context...")
        task.wait(0.25)
    end

    state.running = false
    return false, state.stopped and "stopped" or "Lobby/match detection timeout"
end

return setmetatable({}, XOMA)
