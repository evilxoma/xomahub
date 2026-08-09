local CTDIG_BUILD_AUTORUN = false
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local environment = typeof(getgenv) == "function" and getgenv() or _G
local previousSession = environment.CTDIG_SESSION
local previousStacker = environment.CTDIG_STACKER

if type(previousSession) == "table" and type(previousSession.cleanup) == "function" then
    local cleaned, cleanupError = pcall(previousSession.cleanup)
    if not cleaned then
        warn("[CTDIG] Previous session cleanup failed: " .. tostring(cleanupError))
    end
end

if type(previousStacker) == "table" then
    if type(previousStacker.cleanup) == "function" then
        local cleaned, cleanupError = pcall(previousStacker.cleanup)
        if not cleaned then
            warn("[CTDIG] Previous Stacker cleanup failed: " .. tostring(cleanupError))
        end
    end

    -- Idempotent fallback for an interrupted reinjection. It only touches the
    -- exact wrapper owned by the previous CTDIG session.
    if type(previousStacker.module) == "table"
        and type(previousStacker.original) == "function"
        and previousStacker.module.CheckTowerOverlaps == previousStacker.wrapper then
        previousStacker.module.CheckTowerOverlaps = previousStacker.original
    end

    if type(previousStacker.module) == "table"
        and type(previousStacker.originalMouseIgnores) == "function"
        and previousStacker.module.getplacementmouseignores == previousStacker.mouseWrapper then
        previousStacker.module.getplacementmouseignores = previousStacker.originalMouseIgnores
    end
end
environment.CTDIG_STACKER = nil

local session = { alive = true }
environment.CTDIG_SESSION = session

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 15)
local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)

if not playerGui or not remotes then
    error("CTDIG: PlayerGui or ReplicatedStorage.Remotes was not available after 15 seconds")
end

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
local Options = Library.Options
local Toggles = Library.Toggles

session.cleanup = function()
    if not session.alive then
        return
    end

    session.alive = false
    if Library and type(Library.Unload) == "function" then
        pcall(function()
            Library:Unload()
        end)
    end
    if environment.CTDIG_SESSION == session then
        environment.CTDIG_SESSION = nil
    end
end

local Window = Library:CreateWindow({
    Title = "CTDIG",
    Footer = "Macro Recorder",
    NotifySide = "Right",
    AutoShow = true,
})

local MacroTab = Window:AddTab("Macro", "circle-play")
local LoggerTab = Window:AddTab("Logger", "logs")
local ToolsTab = Window:AddTab("Tools", "wrench")
local RecorderBox = MacroTab:AddLeftGroupbox("Recorder")
local ReplayBox = MacroTab:AddRightGroupbox("Replay")
local LoggerBox = LoggerTab:AddLeftGroupbox("Actions")
local PlacementBox = ToolsTab:AddLeftGroupbox("Placement")
local CombatBox = ToolsTab:AddRightGroupbox("Combat Visuals")

local statusLabel = RecorderBox:AddLabel("CTDIGStatus", {
    Text = "Status: Idle",
    DoesWrap = true,
})

local loggerLabel = LoggerBox:AddLabel("CTDIGLog", {
    Text = "Logger inactive. Start Recorder.",
    DoesWrap = true,
})

local replayStatusLabel = ReplayBox:AddLabel("CTDIGReplayStatus", {
    Text = "Replay: idle",
    DoesWrap = true,
})

local nativeAutoSkipSetting = player:FindFirstChild("PlayerData")
    and player.PlayerData:FindFirstChild("Settings")
    and player.PlayerData.Settings:FindFirstChild("AutoSkip")

RecorderBox:AddToggle("CTDIGAutoSkip", {
    Text = "Auto Skip",
    Default = nativeAutoSkipSetting and nativeAutoSkipSetting.Value == true or false,
    Tooltip = "Uses the game native AutoSkip setting.",
})

PlacementBox:AddToggle("CTDIGStacker", {
    Text = "Stacker",
    Default = false,
    Tooltip = "Uses the game native placement pipeline, but ignores tower models in the mouse ray and tower-vs-tower UnitPlacebox overlap. Path, NoPlace, obstacles and Ground/Cliff rules stay native.",
})

PlacementBox:AddToggle("CTDIGRangePreview", {
    Text = "Range Preview",
    Default = true,
    Tooltip = "Shows the real base/upgrade ranges for the unit you are placing.",
})

local rangeInfoLabel = PlacementBox:AddLabel("CTDIGRangeInfo", {
    Text = "Range Preview: select a unit",
    DoesWrap = true,
})

ReplayBox:AddToggle("CTDIGAutoRetry", {
    Text = "Auto Retry",
    Default = false,
    Tooltip = "After Triumph/Defeat, automatically presses the game's real Restart button.",
})

ReplayBox:AddToggle("CTDIGAutoBackLobby", {
    Text = "Auto Back to Lobby",
    Default = false,
    Tooltip = "After Triumph/Defeat, automatically presses the game's real Exit to Lobby button.",
})

local endActionLabel = ReplayBox:AddLabel("CTDIGEndAction", {
    Text = "End action: OFF",
    DoesWrap = true,
})

CombatBox:AddToggle("CTDIGTowerDPS", {
    Text = "Tower DPS",
    Default = true,
    Tooltip = "Shows calculated DPS above placed towers.",
})

CombatBox:AddToggle("CTDIGKillPreview", {
    Text = "Kill Preview",
    Default = true,
    Tooltip = "Shows current enemy HP and predicts discrete shots before enemies leave all of your towers' ranges. Green = safe, red = predicted leak.",
})

local killInfoLabel = CombatBox:AddLabel("CTDIGKillInfo", {
    Text = "Kill Preview: waiting for enemies",
    DoesWrap = true,
})

local combatDiagLabel = CombatBox:AddLabel("CTDIGCombatDiag", {
    Text = "Combat: DPS waiting | Predict waiting",
    DoesWrap = true,
})

local recording = false
local replaying = false
local replayTaskRunning = false
local actions = {}
local ids = {}
local nextId = 1
local macroMap = ""
local macroDeck = {}
local towerState = {}
local baselineTowers = setmetatable({}, { __mode = "k" })
local placementAttempt
local recentPlacement
local connections = {}
local towerConnections = {}
local logLines = {}
local logHead = 1
local logCount = 0
local ctdModule
local stackerState = {
    enabled = false,
    module = nil,

    -- Legacy names are kept so reinjection from older CTDIG Stacker builds
    -- can still restore CheckTowerOverlaps safely.
    original = nil,
    wrapper = nil,

    originalMouseIgnores = nil,
    mouseWrapper = nil,
}
environment.CTDIG_STACKER = stackerState
local resolvedUnits = {}
local recorderState = "idle"
local lastRecorderStatusText
local lastReplayStatusText
local replayStopRequested = false
local recordedSkipWaves = {}
local pendingSkipWave
local pendingSkipAt = 0
local lastSkipConfirmationWave
local lastSkipConfirmationAt = 0
local placementConfiguration
local placementRecorderBound = false
local placementRecorderBinding = false
local autoSkipChanging = false
local endActionChanging = false
local stackerToggleChanging = false
session.endAction = {
    key = nil,
    attempts = 0,
    nextAttempt = 0,
    startedAt = 0,
    busy = false,
    confirmed = false,
}
session.placementQueue = {}
session.pendingTowerRecords = setmetatable({}, { __mode = "k" })
session.pendingTowerActions = setmetatable({}, { __mode = "k" })

local MACRO_FILE = "ctdig.lua"
local MACRO_BACKUP_FILE = "ctdig.backup.lua"
local MACRO_TEMP_FILE = "ctdig.__writing.lua"

session.sourceBindings = {
    towerFolders = setmetatable({}, { __mode = "k" }),
    detects = setmetatable({}, { __mode = "k" }),
    skipping = setmetatable({}, { __mode = "k" }),
    gameVals = setmetatable({}, { __mode = "k" }),
    waves = setmetatable({}, { __mode = "k" }),
    sellButtons = setmetatable({}, { __mode = "k" }),
    sellGuis = setmetatable({}, { __mode = "k" }),
    upgradeButtons = setmetatable({}, { __mode = "k" }),
    actionGuis = setmetatable({}, { __mode = "k" }),
    hotkeysBound = false,
}
local rangePreviewGui
local rangePreviewAdornee
local rangePreviewFolder
local rangePreviewBoundValues = setmetatable({}, { __mode = "k" })
local rangePreviewBindingStarted = false
local rangeNativeOriginals = setmetatable({}, { __mode = "k" })
local dpsGuis = setmetatable({}, { __mode = "k" })
local dpsSamples = setmetatable({}, { __mode = "k" })
local killHighlights = setmetatable({}, { __mode = "k" })
local killLabels = setmetatable({}, { __mode = "k" })
local enemyMotion = setmetatable({}, { __mode = "k" })
local lastKillPreviewUpdate = 0
local lastRangePreviewRefresh = 0
local lastRecorderRecoveryScan = 0
local lastDpsVisualErrorAt = 0
local lastKillVisualErrorAt = 0
local combatDiagDps = "DPS waiting"
local combatDiagPredict = "Predict waiting"


local LOGGER_LIMIT = 25

local function recorderWave()
    local map = Workspace:FindFirstChild("Map")
    local config = map and map:FindFirstChild("Configuration")
    local wave = config and config:FindFirstChild("Wave")
    return wave and tonumber(wave.Value) or 0
end

local function setLabelText(label, optionName, text)
    if label and type(label.SetText) == "function" then
        label:SetText(text)
        return true
    end

    local option = Options and Options[optionName]
    if option and type(option.SetText) == "function" then
        option:SetText(text)
        return true
    end

    return false
end

local function refreshCombatDiag()
    local textValue = "Combat: " .. tostring(combatDiagDps) .. " | " .. tostring(combatDiagPredict)
    if combatDiagLabel and type(combatDiagLabel.SetText) == "function" then
        combatDiagLabel:SetText(textValue)
    elseif Options and Options.CTDIGCombatDiag and type(Options.CTDIGCombatDiag.SetText) == "function" then
        Options.CTDIGCombatDiag:SetText(textValue)
    end
end

local function setCombatDiagDps(textValue)
    combatDiagDps = tostring(textValue)
    refreshCombatDiag()
end

local function setCombatDiagPredict(textValue)
    combatDiagPredict = tostring(textValue)
    refreshCombatDiag()
end

local function refreshRecorderStatus()
    local text

    if recorderState == "recording" then
        text = string.format("Recording | Actions: %d | Wave: %d", #actions, recorderWave())
    elseif recorderState == "saving" then
        text = "Saving"
    elseif recorderState == "saved" then
        text = string.format("Saved | Actions: %d", #actions)
    elseif recorderState == "save_failed" then
        text = "Save failed"
    elseif recorderState == "replaying" then
        text = "Replaying"
    elseif recorderState == "replay_stopped" then
        text = "Replay stopped"
    elseif recorderState == "replay_finished" then
        text = "Replay finished"
    elseif recorderState == "error" then
        text = "Error"
    else
        text = "Idle"
    end

    local fullText = "Status: " .. text
    if fullText ~= lastRecorderStatusText then
        lastRecorderStatusText = fullText
        setLabelText(statusLabel, "CTDIGStatus", fullText)
    end
end

local function setRecorderState(state)
    recorderState = state
    refreshRecorderStatus()
end

local function setReplayStatus(text)
    local fullText = "Replay: " .. tostring(text)
    if fullText ~= lastReplayStatusText then
        lastReplayStatusText = fullText
        setLabelText(replayStatusLabel, "CTDIGReplayStatus", fullText)
    end
end

local function notify(title, text, time)
    local ok = pcall(function()
        Library:Notify({
            Title = tostring(title),
            Description = tostring(text or ""),
            Time = time or 3,
        })
    end)

    if not ok then
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = tostring(title),
                Text = tostring(text or ""),
                Duration = time or 3,
            })
        end)
    end
end

local function renderLogger()
    if logCount == 0 then
        setLabelText(loggerLabel, "CTDIGLog", "Recorder active. Waiting for actions.")
        return
    end

    local visible = {}
    for offset = 0, logCount - 1 do
        local index = ((logHead + offset - 1) % LOGGER_LIMIT) + 1
        visible[#visible + 1] = logLines[index]
    end

    setLabelText(loggerLabel, "CTDIGLog", table.concat(visible, "\n"))
end

local function resetLogger(active)
    table.clear(logLines)
    logHead = 1
    logCount = 0
    setLabelText(
        loggerLabel,
        "CTDIGLog",
        active and "Recorder active. Waiting for actions." or "Logger inactive. Start Recorder."
    )
end

local function freezeLogger()
    if logCount == 0 then
        setLabelText(loggerLabel, "CTDIGLog", "No recorder actions in last session.")
    end
end

local function logRecorderAction(text)
    if not recording then
        return
    end

    text = tostring(text)
    print("[CTDIG] " .. text)

    if logCount < LOGGER_LIMIT then
        local index = ((logHead + logCount - 1) % LOGGER_LIMIT) + 1
        logLines[index] = text
        logCount = logCount + 1
    else
        logLines[logHead] = text
        logHead = (logHead % LOGGER_LIMIT) + 1
    end

    renderLogger()
end

local function debugLog(text)
    print("[CTDIG] " .. tostring(text))
end

local function tracebackError(err)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
    return connection
end

local function disconnectTower(tower)
    local list = towerConnections[tower]
    if not list then
        return
    end

    for _, connection in pairs(list) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    towerConnections[tower] = nil
    towerState[tower] = nil
    ids[tower] = nil
end

local function towerConnect(tower, signal, callback, key)
    towerConnections[tower] = towerConnections[tower] or {}

    if key and towerConnections[tower][key] then
        pcall(function()
            towerConnections[tower][key]:Disconnect()
        end)
    end

    local connection = signal:Connect(callback)
    if key then
        towerConnections[tower][key] = connection
    else
        towerConnections[tower][#towerConnections[tower] + 1] = connection
    end
    return connection
end

local function findPlacementConfiguration()
    if placementConfiguration
        and placementConfiguration:IsDescendantOf(playerGui)
        and placementConfiguration:FindFirstChild("UnitChoosed") then
        return placementConfiguration
    end

    local direct = playerGui:FindFirstChild("Configuration")
    if direct and direct:FindFirstChild("UnitChoosed") then
        placementConfiguration = direct
        return placementConfiguration
    end

    local main = playerGui:FindFirstChild("Main")
    local mainConfig = main and main:FindFirstChild("Configuration")
    if mainConfig and mainConfig:FindFirstChild("UnitChoosed") then
        placementConfiguration = mainConfig
        return placementConfiguration
    end

    local unitsGui = playerGui:FindFirstChild("UnitsListGui")
    local unitsConfig = unitsGui and unitsGui:FindFirstChild("Configuration")
    if unitsConfig and unitsConfig:FindFirstChild("UnitChoosed") then
        placementConfiguration = unitsConfig
        return placementConfiguration
    end

    for _, object in ipairs(playerGui:GetDescendants()) do
        if object.Name == "Configuration" and object:FindFirstChild("UnitChoosed") then
            placementConfiguration = object
            return placementConfiguration
        end
    end
end

local function getMapName()
    local map = Workspace:FindFirstChild("Map")
    local trueName = map and map:FindFirstChild("TrueName")
    return trueName and tostring(trueName.Value) or (map and map.Name or "Unknown")
end

local function getWave()
    local map = Workspace:FindFirstChild("Map")
    local config = map and map:FindFirstChild("Configuration")
    local wave = config and config:FindFirstChild("Wave")
    return wave and tonumber(wave.Value) or 0
end

function session.getDeckSnapshot()
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
                slots[#slots + 1] = { index = index, value = tostring(child.Value) }
            end
        end
    end

    table.sort(slots, function(a, b)
        return a.index < b.index
    end)

    local deck = {}
    for _, slot in ipairs(slots) do
        deck[#deck + 1] = slot.value
    end
    return deck
end

function session.compactDeckText(deck)
    local out = {}
    for _, name in ipairs(deck or {}) do
        if name and name ~= "" and name ~= "None" then
            out[#out + 1] = tostring(name)
        end
    end
    return #out > 0 and table.concat(out, ", ") or "empty"
end

local function getTowers()
    return Workspace:FindFirstChild("Towers")
end

local function getGameVals()
    return Workspace:FindFirstChild("GameVals")
end

local function getNativeAutoSkipSetting()
    local data = player:FindFirstChild("PlayerData")
    local settings = data and data:FindFirstChild("Settings")
    return settings and settings:FindFirstChild("AutoSkip")
end

local function getSettingsRemote()
    local buttons = playerGui:FindFirstChild("Buttons")
    local settingsFrame = buttons and buttons:FindFirstChild("SettingsFrame")
    local mainFrame = settingsFrame and settingsFrame:FindFirstChild("MainFrame")
    local controller = mainFrame and mainFrame:FindFirstChild("LocalScript")
    local remote = controller and controller:FindFirstChild("RemoteEvent")

    if remote and remote:IsA("RemoteEvent") then
        return remote
    end

    if mainFrame then
        for _, object in ipairs(mainFrame:GetDescendants()) do
            if object:IsA("RemoteEvent") and object.Parent and object.Parent:IsA("LocalScript") then
                return object
            end
        end
    end
end

local function setNativeAutoSkip(enabled)
    enabled = enabled == true
    local setting = getNativeAutoSkipSetting()
    if not setting then
        return false, "PlayerData.Settings.AutoSkip is missing"
    end

    if setting.Value == enabled then
        return true
    end

    local remote = getSettingsRemote()
    if not remote then
        return false, "native settings RemoteEvent is missing"
    end

    local ok, err = pcall(function()
        remote:FireServer("AutoSkip")
    end)
    if not ok then
        return false, tostring(err)
    end

    local started = os.clock()
    while session.alive and os.clock() - started < 2 do
        if setting.Value == enabled then
            return true
        end
        task.wait(0.05)
    end

    return setting.Value == enabled, "server did not change AutoSkip"
end

local function getDetects()
    local service = Workspace:FindFirstChild("WorkspaceScriptService")
    local storage = service and service:FindFirstChild("DetectStorage")
    return storage and storage:FindFirstChild("EverythingDetects")
end

local function getOwner(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local owner = config and config:FindFirstChild("Owner")

    if owner then
        if typeof(owner.Value) == "Instance" then
            return owner.Value.Name
        end
        return tostring(owner.Value)
    end

    local attribute = tower and tower:GetAttribute("Owner")
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

    -- game2 keeps OtherConfig inside Configuration, not at tower root.
    -- Keep the root fallback only for compatibility with unusual/special towers.
    local config = tower:FindFirstChild("Configuration")
    local other = config and config:FindFirstChild("OtherConfig")
        or tower:FindFirstChild("OtherConfig")
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

    -- Runtime tower/enemy containers are not guaranteed to be Models.
    -- Some game objects are Folders that directly own HumanoidRootPart and
    -- replicated Configuration/health values.  Never discard them by class.
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

local function vec(v)
    return {
        x = math.round(v.X * 1000) / 1000,
        y = math.round(v.Y * 1000) / 1000,
        z = math.round(v.Z * 1000) / 1000,
    }
end

local function toVector3(v)
    if type(v) ~= "table" then
        return Vector3.zero
    end
    return Vector3.new(tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0)
end

local function pathUnder(root, object)
    if not root or not object or object == root or not object:IsDescendantOf(root) then
        return nil
    end

    local path = {}
    local current = object

    while current and current ~= root do
        local parent = current.Parent
        if not parent then
            return nil
        end

        local index = 0
        for _, sibling in ipairs(parent:GetChildren()) do
            if sibling.Name == current.Name and sibling.ClassName == current.ClassName then
                index = index + 1
                if sibling == current then
                    break
                end
            end
        end

        table.insert(path, 1, {
            name = current.Name,
            class = current.ClassName,
            index = index,
        })
        current = parent
    end

    return path
end

local function resolvePath(root, path)
    if not root or type(path) ~= "table" then
        return nil
    end

    local current = root
    for _, step in ipairs(path) do
        if type(step) == "string" then
            current = current and current:FindFirstChild(step)
        elseif type(step) == "table" and current then
            local wantedIndex = tonumber(step.index) or 1
            local foundIndex = 0
            local found

            for _, child in ipairs(current:GetChildren()) do
                if child.Name == step.name and (not step.class or child.ClassName == step.class) then
                    foundIndex = foundIndex + 1
                    if foundIndex == wantedIndex then
                        found = child
                        break
                    end
                end
            end

            current = found
        else
            current = nil
        end

        if not current then
            return nil
        end
    end

    return current
end

local function sourceFor(object)
    if typeof(object) ~= "Instance" then
        return nil
    end

    if object:IsDescendantOf(playerGui) then
        return { root = "PlayerGui", path = pathUnder(playerGui, object) }
    end

    if object:IsDescendantOf(player) then
        return { root = "Player", path = pathUnder(player, object) }
    end

    if object:IsDescendantOf(ReplicatedStorage) then
        return { root = "ReplicatedStorage", path = pathUnder(ReplicatedStorage, object) }
    end
end

local function resolveSource(source)
    if type(source) ~= "table" then
        return nil
    end

    local root
    if source.root == "PlayerGui" then
        root = playerGui
    elseif source.root == "Player" then
        root = player
    elseif source.root == "ReplicatedStorage" then
        root = ReplicatedStorage
    end

    return resolvePath(root, source.path)
end

local function getCTDModule()
    if ctdModule ~= nil then
        return ctdModule or nil
    end

    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local moduleScript = modules and modules:FindFirstChild("CTDModule")
    if not moduleScript then
        ctdModule = false
        return nil
    end

    local ok, module = pcall(require, moduleScript)
    if not ok then
        warn("[CTDIG] CTDModule require failed: " .. tostring(module))
    end
    ctdModule = ok and module or false
    return ctdModule or nil
end

local function stackerDebug(text)
    debugLog("[STACKER] " .. tostring(text))
end

local function listContains(list, object)
    for _, value in ipairs(list) do
        if value == object then
            return true
        end
    end
    return false
end

local function stackerIgnoreList(nativeList)
    if type(nativeList) ~= "table" then
        return nativeList
    end

    local result = {}
    for index, value in ipairs(nativeList) do
        result[index] = value
    end

    -- Native getplacementmouseignores already excludes UnitPlaceboxes.Normal
    -- and .Path, but it does not exclude the actual models in workspace.Towers.
    -- Without this, the ray can hit a tower model and checkcanplace rejects the
    -- hit before CheckTowerOverlaps is even reached.
    local towers = getTowers()
    if towers and not listContains(result, towers) then
        result[#result + 1] = towers
    end

    return result
end

local function restoreStackerPatch()
    local module = stackerState.module
    local restored = true
    local errors = {}

    if module then
        if stackerState.original and stackerState.wrapper then
            if module.CheckTowerOverlaps == stackerState.wrapper then
                local ok, err = pcall(function()
                    module.CheckTowerOverlaps = stackerState.original
                end)
                if not ok then
                    restored = false
                    errors[#errors + 1] = "CheckTowerOverlaps: " .. tostring(err)
                end
            elseif module.CheckTowerOverlaps ~= stackerState.original then
                restored = false
                errors[#errors + 1] = "CheckTowerOverlaps was replaced by another script"
            end
        end

        if stackerState.originalMouseIgnores and stackerState.mouseWrapper then
            if module.getplacementmouseignores == stackerState.mouseWrapper then
                local ok, err = pcall(function()
                    module.getplacementmouseignores = stackerState.originalMouseIgnores
                end)
                if not ok then
                    restored = false
                    errors[#errors + 1] = "getplacementmouseignores: " .. tostring(err)
                end
            elseif module.getplacementmouseignores ~= stackerState.originalMouseIgnores then
                restored = false
                errors[#errors + 1] = "getplacementmouseignores was replaced by another script"
            end
        end
    end

    stackerState.enabled = false
    return restored, #errors > 0 and table.concat(errors, " | ") or nil
end

local function enableStackerPatch()
    local module = getCTDModule()
    if not module then
        return false, "ReplicatedStorage.Modules.CTDModule could not be required"
    end
    if type(module.CheckTowerOverlaps) ~= "function" then
        return false, "CTDModule.CheckTowerOverlaps is missing"
    end
    if type(module.getplacementmouseignores) ~= "function" then
        return false, "CTDModule.getplacementmouseignores is missing"
    end

    if stackerState.module and stackerState.module ~= module then
        restoreStackerPatch()
        stackerState.module = nil
        stackerState.original = nil
        stackerState.wrapper = nil
        stackerState.originalMouseIgnores = nil
        stackerState.mouseWrapper = nil
    end

    if not stackerState.module then
        stackerState.module = module
        stackerState.original = module.CheckTowerOverlaps
        stackerState.originalMouseIgnores = module.getplacementmouseignores
    end

    if module.CheckTowerOverlaps ~= stackerState.original
        and module.CheckTowerOverlaps ~= stackerState.wrapper then
        return false, "CheckTowerOverlaps is already patched by another script"
    end
    if module.getplacementmouseignores ~= stackerState.originalMouseIgnores
        and module.getplacementmouseignores ~= stackerState.mouseWrapper then
        return false, "getplacementmouseignores is already patched by another script"
    end

    if not stackerState.wrapper then
        stackerState.wrapper = function(playerObject, towerName, position, options)
            -- This is an existing option used by the game's own
            -- CheckTowerOverlaps. It skips UnitPlaceboxServer overlap only.
            -- PathModel collision is checked afterwards by the original
            -- function and therefore stays enabled.
            local patchedOptions = type(options) == "table" and table.clone(options) or {}
            patchedOptions.IgnorePlacementBox = true
            return stackerState.original(playerObject, towerName, position, patchedOptions)
        end
    end

    if not stackerState.mouseWrapper then
        stackerState.mouseWrapper = function(...)
            local result = stackerState.originalMouseIgnores(...)

            -- getplacementmouseignores() has two real return shapes in the
            -- saved client: with no placement type it returns
            -- {Normal = list, Path = list}; with a type it returns one list.
            if type(result) ~= "table" then
                return result
            end

            if type(result.Normal) == "table" or type(result.Path) == "table" then
                local copy = {}
                for key, value in pairs(result) do
                    if (key == "Normal" or key == "Path") and type(value) == "table" then
                        copy[key] = stackerIgnoreList(value)
                    else
                        copy[key] = value
                    end
                end
                return copy
            end

            return stackerIgnoreList(result)
        end
    end

    module.CheckTowerOverlaps = stackerState.wrapper
    module.getplacementmouseignores = stackerState.mouseWrapper
    stackerState.enabled = true
    return true
end

stackerState.cleanup = function()
    restoreStackerPatch()
    if environment.CTDIG_STACKER == stackerState then
        environment.CTDIG_STACKER = nil
    end
end

do
local function readNumberValue(root, name, recursive)
    if not root then
        return nil
    end

    local value = root:FindFirstChild(name, recursive == true)
    if value and value:IsA("ValueBase") then
        return tonumber(value.Value)
    end
end

local function formatCompactNumber(value)
    value = tonumber(value) or 0
    local abs = math.abs(value)

    if abs >= 1000000000 then
        return string.format("%.1fB", value / 1000000000)
    elseif abs >= 1000000 then
        return string.format("%.1fM", value / 1000000)
    elseif abs >= 1000 then
        return string.format("%.1fK", value / 1000)
    elseif abs >= 100 then
        return string.format("%.0f", value)
    elseif abs >= 10 then
        return string.format("%.1f", value)
    end

    return string.format("%.2f", value)
end

local function setRangeInfo(text)
    if rangeInfoLabel and type(rangeInfoLabel.SetText) == "function" then
        rangeInfoLabel:SetText(text)
    elseif Options.CTDIGRangeInfo and type(Options.CTDIGRangeInfo.SetText) == "function" then
        Options.CTDIGRangeInfo:SetText(text)
    end
end

local function unitLevelRanges(unitName)
    local units = ReplicatedStorage:FindFirstChild("Units")
    local unitFolder = units and units:FindFirstChild(unitName)
    local levels = unitFolder and unitFolder:FindFirstChild("Levels")
    if not levels then
        return {}
    end

    local entries = {}
    for _, levelFolder in ipairs(levels:GetChildren()) do
        local level = tonumber(levelFolder.Name)
        if level ~= nil then
            local settings = levelFolder:FindFirstChild("Settings")
            local range = readNumberValue(settings, "Range")
            local range2 = readNumberValue(settings, "Range2")

            if not range then
                local objects = levelFolder:FindFirstChild("Object")
                local object = objects and (objects:FindFirstChild(unitName)
                    or objects:FindFirstChildWhichIsA("Model")
                    or objects:FindFirstChildWhichIsA("BasePart"))
                local config = object and object:FindFirstChild("Configuration")
                range = readNumberValue(config, "Range") or readNumberValue(object, "Range", true)
            end

            if range and range > 0 then
                entries[#entries + 1] = {
                    sourceLevel = level,
                    range = range,
                    range2 = range2 and range2 > 0 and range2 or nil,
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        return a.sourceLevel < b.sourceLevel
    end)

    while #entries > 8 do
        table.remove(entries)
    end

    return entries
end

local RANGE_COLORS = {
    Color3.fromRGB(69, 215, 255),
    Color3.fromRGB(99, 235, 169),
    Color3.fromRGB(255, 216, 96),
    Color3.fromRGB(255, 142, 78),
    Color3.fromRGB(194, 126, 255),
    Color3.fromRGB(255, 112, 178),
    Color3.fromRGB(255, 102, 102),
    Color3.fromRGB(225, 235, 245),
}

local function restoreNativeRangeParts()
    for part, value in pairs(rangeNativeOriginals) do
        if part and part.Parent then
            pcall(function()
                part.LocalTransparencyModifier = value
            end)
        end
        rangeNativeOriginals[part] = nil
    end
end

local function hideNativeRangeParts(preview)
    -- UnitManager creates the main circle with CTDModule.makeunitrangeviewpart.
    -- We replace only that primary circle. RangeViewPart2 is a real secondary
    -- attack radius and remains visible instead of being accidentally hidden.
    for _, name in ipairs({ "RangeViewPart" }) do
        local part = preview and preview:FindFirstChild(name, true)
        if part and part:IsA("BasePart") then
            if rangeNativeOriginals[part] == nil then
                rangeNativeOriginals[part] = part.LocalTransparencyModifier
            end
            part.LocalTransparencyModifier = 1
        end
    end
end

local function destroyRangePreview()
    if rangePreviewGui then
        pcall(function()
            rangePreviewGui:Destroy()
        end)
    end
    if rangePreviewFolder then
        pcall(function()
            rangePreviewFolder:Destroy()
        end)
    end
    restoreNativeRangeParts()
    rangePreviewGui = nil
    rangePreviewAdornee = nil
    rangePreviewFolder = nil
end

local function rangeColor(index)
    return RANGE_COLORS[math.clamp(index, 1, #RANGE_COLORS)]
end

local function makeRangeLabel(parent, anchor, color, level, range, base)
    local gui = Instance.new("BillboardGui")
    gui.Name = "CTDIG_RangeLabel_L" .. tostring(level)
    gui.Adornee = anchor
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.MaxDistance = 240
    gui.Size = UDim2.fromOffset(138, 34)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 0.42, 0)
    gui.Parent = parent

    local label = Instance.new("TextLabel")
    label.BackgroundColor3 = Color3.fromRGB(9, 11, 15)
    label.BackgroundTransparency = base and 0.08 or 0.18
    label.BorderSizePixel = 0
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.Text = string.format("LVL %d  •  %s\n%s RANGE", level, base and "BASE" or "UPGRADE", formatCompactNumber(range))
    label.TextColor3 = Color3.fromRGB(248, 250, 252)
    label.TextSize = 11
    label.TextWrapped = true
    label.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = label

    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Transparency = base and 0 or 0.18
    stroke.Thickness = base and 1.8 or 1.1
    stroke.Parent = label
end

local function makeRangeRing(folder, preview, root, radius, level, visualIndex, planeYOffset)
    local base = visualIndex == 1
    local yOffset = (planeYOffset or (-(root.Size.Y * 0.5) + 0.06)) + ((visualIndex - 1) * 0.025)
    local color = rangeColor(visualIndex)
    local rangePart
    local module = getCTDModule()

    if module and type(module.makeunitrangeviewpart) == "function"
        and preview:IsA("Model") and preview.PrimaryPart
        and preview:FindFirstChild("HumanoidRootPart") then
        local ok, result = pcall(
            module.makeunitrangeviewpart,
            base and "main" or "special",
            preview,
            radius * 2
        )
        if ok and typeof(result) == "Instance" and result:IsA("BasePart") then
            rangePart = result
            rangePart.Name = "CTDIG_Range_L" .. tostring(level)
            rangePart.Color = color
            rangePart.Transparency = base and 0.72 or 0.84
            rangePart.CanCollide = false
            rangePart.CanQuery = false
            rangePart.CanTouch = false
            rangePart.CastShadow = false
            rangePart:SetAttribute("CTDIGRange", radius)
            rangePart:SetAttribute("CTDIGLevel", level)
            rangePart.Parent = folder
        end
    end

    if not rangePart then
        -- Exact CTDModule API is the primary path. This compact fallback keeps
        -- the preview usable if a runtime update temporarily removes that API.
        local segments = base and 28 or 18
        local step = (2 * math.pi) / segments
        local arc = (2 * math.pi * radius) / segments
        local dashLength = arc * (base and 0.88 or 0.58)
        local thickness = base and math.clamp(radius * 0.012, 0.11, 0.21)
            or math.clamp(radius * 0.007, 0.07, 0.13)

        for i = 0, segments - 1 do
            local angle = i * step
            local segment = Instance.new("Part")
            segment.Name = "CTDIG_RangeRing_L" .. tostring(level)
            segment.Anchored = false
            segment.CanCollide = false
            segment.CanQuery = false
            segment.CanTouch = false
            segment.CastShadow = false
            segment.Massless = true
            segment.Material = Enum.Material.Neon
            segment.Color = color
            segment.Transparency = base and 0.03 or 0.19
            segment.Size = Vector3.new(dashLength, base and 0.052 or 0.032, thickness)
            segment.CFrame = root.CFrame * CFrame.Angles(0, angle, 0) * CFrame.new(0, yOffset, -radius)
            segment.Parent = folder

            local weld = Instance.new("WeldConstraint")
            weld.Part0 = root
            weld.Part1 = segment
            weld.Parent = segment
        end
    end

    local angles = { -110, -40, 30, 100, 170 }
    local angle = math.rad(angles[visualIndex] or ((visualIndex - 1) * 72 - 110))
    local anchor = Instance.new("Part")
    anchor.Name = "CTDIG_RangeLabelAnchor_L" .. tostring(level)
    anchor.Anchored = false
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.CastShadow = false
    anchor.Massless = true
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.1, 0.1, 0.1)
    anchor.CFrame = root.CFrame * CFrame.Angles(0, angle, 0) * CFrame.new(0, yOffset + 0.15, -(radius + 0.2))
    anchor.Parent = folder

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = root
    weld.Part1 = anchor
    weld.Parent = anchor

    makeRangeLabel(anchor, anchor, color, level, radius, base)
end

local function makeRangeSummary(root, entries)
    local gui = Instance.new("BillboardGui")
    gui.Name = "CTDIG_RangeSummary"
    gui.Adornee = root
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.MaxDistance = 180
    gui.Size = UDim2.fromOffset(230, 42)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
    gui.Parent = playerGui

    local base = entries[1]
    local max = entries[#entries]
    local label = Instance.new("TextLabel")
    label.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
    label.BackgroundTransparency = 0.12
    label.BorderSizePixel = 0
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    local secondary = base.range2 and ("   •   R2  " .. formatCompactNumber(base.range2)) or ""
    label.Text = string.format(
        "BASE  %s   →   MAX  %s%s",
        formatCompactNumber(base.range),
        formatCompactNumber(max.range),
        secondary
    )
    label.TextColor3 = Color3.fromRGB(248, 250, 252)
    label.TextSize = 12
    label.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = label

    local stroke = Instance.new("UIStroke")
    stroke.Color = RANGE_COLORS[1]
    stroke.Transparency = 0.2
    stroke.Thickness = 1.2
    stroke.Parent = label

    rangePreviewGui = gui
end

local function refreshRangePreview()
    if not (Toggles.CTDIGRangePreview and Toggles.CTDIGRangePreview.Value) then
        destroyRangePreview()
        setRangeInfo("Range Preview: OFF")
        return
    end

    local config = findPlacementConfiguration()
    local editing = config and config:FindFirstChild("UnitEditor")
    local chosen = config and config:FindFirstChild("UnitChoosed")
    local current = config and config:FindFirstChild("CurrentUnitPlacingObject")
    local unit = chosen and chosen.Value
    local preview = current and current.Value

    if not editing or editing.Value ~= true or typeof(unit) ~= "Instance" or typeof(preview) ~= "Instance" then
        destroyRangePreview()
        setRangeInfo("Range Preview: select/place a unit")
        return
    end

    local root = getRoot(preview)
    if not root then
        destroyRangePreview()
        setRangeInfo("Range Preview: preview root missing")
        return
    end

    local entries = unitLevelRanges(unit.Name)
    if #entries == 0 then
        local configRange = readNumberValue(preview:FindFirstChild("Configuration"), "Range")
        local native = preview:FindFirstChild("RangeViewPart", true)
        local nativeRadius
        if native and native:IsA("BasePart") then
            if native:IsA("MeshPart") then
                nativeRadius = math.max(native.Size.X, native.Size.Z) * 0.5
            else
                nativeRadius = math.max(native.Size.Y, native.Size.Z) * 0.5
            end
        end
        local fallback = configRange or nativeRadius
        if fallback and fallback > 0 then
            entries[1] = { sourceLevel = 0, range = fallback }
        end
    end

    if #entries == 0 then
        destroyRangePreview()
        setRangeInfo("Range Preview: no range data for " .. unit.Name)
        return
    end

    local signatureParts = { unit.Name }
    for i, entry in ipairs(entries) do
        signatureParts[#signatureParts + 1] = tostring(entry.sourceLevel)
            .. "=" .. string.format("%.4f", entry.range)
            .. "/" .. string.format("%.4f", entry.range2 or 0)
    end
    local signature = table.concat(signatureParts, ":")
    local rebuild = not rangePreviewFolder
        or not rangePreviewFolder.Parent
        or rangePreviewFolder.Parent ~= preview
        or rangePreviewAdornee ~= root
        or rangePreviewFolder:GetAttribute("Signature") ~= signature

    hideNativeRangeParts(preview)
    local secondaryInfo = entries[1].range2
        and ("  |  R2: " .. formatCompactNumber(entries[1].range2)) or ""
    setRangeInfo(string.format("%s  |  LVL %d: %s  |  LVL %d: %s%s", unit.Name,
        entries[1].sourceLevel, formatCompactNumber(entries[1].range),
        entries[#entries].sourceLevel, formatCompactNumber(entries[#entries].range), secondaryInfo))

    if not rebuild then
        return
    end

    destroyRangePreview()
    hideNativeRangeParts(preview)

    local folder = Instance.new("Folder")
    folder.Name = "CTDIG_RangePreview"
    folder:SetAttribute("Signature", signature)
    folder.Parent = preview
    rangePreviewFolder = folder
    rangePreviewAdornee = root

    local planeYOffset = -(root.Size.Y * 0.5) + 0.06
    local native = preview:FindFirstChild("RangeViewPart", true)
    if native and native:IsA("BasePart") then
        planeYOffset = root.CFrame:PointToObjectSpace(native.Position).Y + 0.035
    end

    local renderedRanges = {}
    local visualIndex = 0
    for _, entry in ipairs(entries) do
        local rangeKey = string.format("%.4f", entry.range)
        if not renderedRanges[rangeKey] then
            renderedRanges[rangeKey] = true
            visualIndex = visualIndex + 1
            makeRangeRing(folder, preview, root, entry.range, entry.sourceLevel, visualIndex, planeYOffset)
        end
    end
    makeRangeSummary(root, entries)
end

local function towerBuffs(tower)
    local module = getCTDModule()
    if module and type(module.calculatetowerbuffs) == "function" then
        local ok, buffs = pcall(module.calculatetowerbuffs, tower)
        if ok and type(buffs) == "table" then
            return buffs
        end
    end
    return {
        damage = 0,
        firerate = 0,
        range = 0,
    }
end

local function towerSetting(tower, name)
    local config = tower and tower:FindFirstChild("Configuration")

    -- Runtime Configuration is authoritative after placement/upgrade in this
    -- game. Prefer the direct stat because upgrade replaces Configuration
    -- with the current level's real settings.
    local direct = readNumberValue(config, name)
    if direct ~= nil then
        return direct
    end

    -- A few special towers can nest a stat container. Keep this as a narrow
    -- fallback, then finally fall back to ReplicatedStorage level settings.
    local nested = readNumberValue(config, name, true)
    if nested ~= nil then
        return nested
    end

    local units = ReplicatedStorage:FindFirstChild("Units")
    local unit = tower and units and units:FindFirstChild(tower.Name)
    local levels = unit and unit:FindFirstChild("Levels")
    local level = levels and levels:FindFirstChild(tostring(getLevel(tower)))
    local settings = level and level:FindFirstChild("Settings")
    return readNumberValue(settings, name)
end

local function towerRange(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local other = tower and tower:FindFirstChild("OtherConfig")
        or (config and config:FindFirstChild("OtherConfig"))
    local real = readNumberValue(other, "RealRange") or readNumberValue(other, "RealRange", true)
    if real and real > 0 then
        return real
    end

    local base = towerSetting(tower, "Range") or 0
    local buffs = towerBuffs(tower)
    return math.max(0, base * math.max(0, (tonumber(buffs.range) or 0) + 1))
end

local function towerCombatStats(tower)
    if not tower or not tower.Parent then
        return nil
    end

    local config = tower:FindFirstChild("Configuration")
    local baseDamage = readNumberValue(config, "Damage")
        or tonumber(towerSetting(tower, "Damage"))
        or 0
    local baseReload = readNumberValue(config, "ReloadTime")
        or readNumberValue(config, "FireRate")
        or tonumber(towerSetting(tower, "ReloadTime"))
        or tonumber(towerSetting(tower, "FireRate"))
        or tonumber(towerSetting(tower, "AttackRate"))

    if baseDamage <= 0 or not baseReload or baseReload <= 0 then
        return nil
    end

    local buffs = towerBuffs(tower)
    local damageMultiplier = math.max(0, (tonumber(buffs.damage) or 0) + 1)
    local speedMultiplier = math.max(0.05, (tonumber(buffs.firerate) or 0) + 1)

    local damage = math.max(0, baseDamage * damageMultiplier)
    local interval = math.max(0.015, baseReload / speedMultiplier)
    local range = towerRange(tower)

    return {
        damage = damage,
        interval = interval,
        dps = interval > 0 and damage / interval or 0,
        range = range,
        baseDamage = baseDamage,
        baseReload = baseReload,
        damageMultiplier = damageMultiplier,
        speedMultiplier = speedMultiplier,
    }
end

local function sampleTowerLiveDPS(tower, now)
    now = now or os.clock()
    local total = readNumberValue(tower, "TotalDMG")
    if total == nil then
        return nil
    end

    local state = dpsSamples[tower]
    if not state then
        state = {
            lastTotal = total,
            lastTime = now,
            live = 0,
            recentDamageAt = 0,
        }
        dpsSamples[tower] = state
        return 0
    end

    local dt = now - (state.lastTime or now)
    if dt >= 0.18 then
        local delta = total - (state.lastTotal or total)
        if delta < 0 then
            delta = 0
        end

        local instant = delta / math.max(dt, 0.001)
        if delta > 0 then
            state.recentDamageAt = now
            if state.live and state.live > 0 then
                state.live = state.live * 0.58 + instant * 0.42
            else
                state.live = instant
            end
        elseif now - (state.recentDamageAt or 0) > 1.5 then
            state.live = (state.live or 0) * 0.72
            if state.live < 0.01 then
                state.live = 0
            end
        end

        state.lastTotal = total
        state.lastTime = now
    end

    return math.max(0, tonumber(state.live) or 0)
end

local function towerDamage(tower)
    local stats = towerCombatStats(tower)
    return stats and stats.damage or 0
end

local function towerAttackInterval(tower)
    local stats = towerCombatStats(tower)
    return stats and stats.interval or nil
end

local function towerDPS(tower)
    local stats = towerCombatStats(tower)
    return stats and stats.dps or nil
end

local function ensureDpsGui(tower)
    if not tower or not tower.Parent then
        return
    end

    local root = getRoot(tower)
    if not root then
        return
    end

    local data = dpsGuis[tower]
    if data and data.gui and data.gui.Parent and data.gui.Adornee == root then
        return data
    end

    if data and data.gui then
        pcall(function()
            data.gui:Destroy()
        end)
    end

    local gui = Instance.new("BillboardGui")
    gui.Name = "CTDIG_DPS"
    gui.Adornee = root
    gui.AlwaysOnTop = true
    gui.Enabled = true
    gui.LightInfluence = 0
    gui.MaxDistance = 10000
    gui.Size = UDim2.fromOffset(176, 44)

    local offsetY = 3.5
    if tower:IsA("Model") then
        local ok, boxCFrame, boxSize = pcall(tower.GetBoundingBox, tower)
        if ok and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3" then
            offsetY = math.max(2.7, boxCFrame.Position.Y + boxSize.Y * 0.5 - root.Position.Y + 1.45)
        end
    end
    gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
    -- Keep the BillboardGui in PlayerGui and point Adornee at the tower part.
    -- This stays fully local and avoids executor/client cleanup of GUI children
    -- that are inserted into replicated tower instances.
    gui.Parent = root

    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
    label.BackgroundTransparency = 0.12
    label.BorderSizePixel = 0
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextColor3 = Color3.fromRGB(248, 249, 252)
    label.TextSize = 12
    label.TextWrapped = true
    label.Text = "DPS —"
    label.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = label

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(215, 160, 82)
    stroke.Transparency = 0.24
    stroke.Thickness = 1.2
    stroke.Parent = label

    data = { gui = gui, label = label }
    dpsGuis[tower] = data
    return data
end

local function clearDpsGuis()
    for tower, data in pairs(dpsGuis) do
        if data.gui then
            pcall(function()
                data.gui:Destroy()
            end)
        end
        dpsGuis[tower] = nil
        dpsSamples[tower] = nil
    end
end

local function valueMeansActive(valueObject)
    if not valueObject then
        return false
    end
    if valueObject:IsA("BoolValue") then
        return valueObject.Value == true
    end
    if valueObject:IsA("NumberValue") or valueObject:IsA("IntValue") then
        return tonumber(valueObject.Value) and tonumber(valueObject.Value) > 0 or false
    end
    if valueObject:IsA("StringValue") then
        local value = string.lower(tostring(valueObject.Value or ""))
        return value ~= "" and value ~= "false" and value ~= "0" and value ~= "none"
    end
    return true
end

local function enemyHealthData(enemy)
    if not enemy then
        return nil
    end

    local config = enemy:FindFirstChild("Configuration")
    local totalLife = readNumberValue(enemy, "TotalLife")

    -- game2 native enemy UI writes CurrentHPText from TotalLife.Value.
    -- Prefer the exact replicated current life used by the game UI.
    if totalLife ~= nil then
        return {
            current = math.max(0, totalLife),
            source = "TotalLife",
            totalLife = totalLife,
            health = nil,
            health2 = readNumberValue(enemy, "Health2") or 0,
            shield = readNumberValue(config, "Shield") or 0,
            superShield = readNumberValue(config, "SuperShield") or 0,
            maxHealth = nil,
            invulnerable = valueMeansActive(enemy:FindFirstChild("Invulnerable"))
                or valueMeansActive(enemy:FindFirstChild("HPInvulnerable")),
        }
    end

    -- Fallback for unusual enemies before TotalLife replicates.
    local humanoidObject = enemy:FindFirstChild("Humanoid")
    local health
    local maxHealth
    if humanoidObject then
        if humanoidObject:IsA("Humanoid") then
            health = tonumber(humanoidObject.Health)
            maxHealth = tonumber(humanoidObject.MaxHealth)
        else
            health = readNumberValue(humanoidObject, "Health")
            maxHealth = readNumberValue(humanoidObject, "MaxHealth")
        end
    end

    if health == nil then
        health = readNumberValue(config, "Health") or readNumberValue(enemy, "Health")
    end
    if health == nil then
        return nil
    end

    local health2 = math.max(0, readNumberValue(enemy, "Health2") or 0)
    local shield = math.max(0, readNumberValue(config, "Shield") or 0)
    local superShield = math.max(0, readNumberValue(config, "SuperShield") or 0)
    return {
        current = math.max(0, health) + health2 + shield + superShield,
        source = "Health fallback",
        totalLife = nil,
        health = health,
        health2 = health2,
        shield = shield,
        superShield = superShield,
        maxHealth = maxHealth,
        invulnerable = valueMeansActive(enemy:FindFirstChild("Invulnerable"))
            or valueMeansActive(enemy:FindFirstChild("HPInvulnerable")),
    }
end
local function enemyHealth(enemy)
    local data = enemyHealthData(enemy)
    return data and data.current or nil
end

local function setKillInfo(text)
    if killInfoLabel and type(killInfoLabel.SetText) == "function" then
        killInfoLabel:SetText(text)
    elseif Options.CTDIGKillInfo and type(Options.CTDIGKillInfo.SetText) == "function" then
        Options.CTDIGKillInfo:SetText(text)
    end
end

local function removeKillHighlight(enemy)
    local highlight = killHighlights[enemy]
    if highlight then
        pcall(function()
            highlight:Destroy()
        end)
        killHighlights[enemy] = nil
    end

    local label = killLabels[enemy]
    if label then
        pcall(function()
            label:Destroy()
        end)
        killLabels[enemy] = nil
    end
end

local function clearKillHighlights()
    local enemies = {}
    for enemy in pairs(killHighlights) do
        enemies[#enemies + 1] = enemy
    end
    for enemy in pairs(killLabels) do
        if not killHighlights[enemy] then
            enemies[#enemies + 1] = enemy
        end
    end
    for _, enemy in ipairs(enemies) do
        removeKillHighlight(enemy)
    end
    table.clear(enemyMotion)
end

local function ensureEnemyPredictLabel(enemy)
    local root = getRoot(enemy)
    if not root then
        return nil
    end

    local gui = killLabels[enemy]
    if gui and gui.Parent and gui.Adornee == root then
        return gui
    end

    if gui then
        pcall(function()
            gui:Destroy()
        end)
    end

    gui = Instance.new("BillboardGui")
    gui.Name = "CTDIG_EnemyPredict"
    gui.Adornee = root
    gui.AlwaysOnTop = true
    gui.Enabled = true
    gui.LightInfluence = 0
    gui.MaxDistance = 650
    gui.Size = UDim2.fromOffset(168, 34)

    local offsetY = 3.2
    if enemy:IsA("Model") then
        local ok, boxCFrame, boxSize = pcall(enemy.GetBoundingBox, enemy)
        if ok and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3" then
            offsetY = math.max(
                2.8,
                boxCFrame.Position.Y + boxSize.Y * 0.5 - root.Position.Y + 0.65
            )
        end
    end
    gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)

    -- Keep the visual in PlayerGui so the game's enemy cleanup/UI scripts do
    -- not remove our local BillboardGui from the replicated enemy model.
    gui.Parent = playerGui or root

    local back = Instance.new("Frame")
    back.Name = "Back"
    back.BorderSizePixel = 0
    back.BackgroundColor3 = Color3.fromRGB(12, 13, 16)
    back.BackgroundTransparency = 0.12
    back.Size = UDim2.fromScale(1, 1)
    back.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = back

    local gradient = Instance.new("UIGradient")
    gradient.Name = "DarkGradient"
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(32, 34, 40)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(15, 16, 20)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 5, 7)),
    })
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.08),
        NumberSequenceKeypoint.new(0.5, 0.18),
        NumberSequenceKeypoint.new(1, 0.34),
    })
    gradient.Rotation = 90
    gradient.Parent = back

    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Size = UDim2.new(1, -10, 1, -4)
    label.Position = UDim2.fromOffset(5, 2)
    label.Font = Enum.Font.GothamBold
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextSize = 11
    label.TextWrapped = false
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Text = "HP —  •  DPS —"
    label.Parent = back

    local textStroke = Instance.new("UIStroke")
    textStroke.Name = "TextStroke"
    textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    textStroke.Color = Color3.fromRGB(0, 0, 0)
    textStroke.Thickness = 1.35
    textStroke.Transparency = 0.05
    textStroke.Parent = label

    killLabels[enemy] = gui
    return gui
end

local function setEnemyKillColor(enemy, lethal, currentHealth, predictedRemaining, potentialDps)
    local highlight = killHighlights[enemy]
    if not highlight or not highlight.Parent then
        local visualAdornee = enemy
        if not (enemy:IsA("Model") or enemy:IsA("BasePart")) then
            visualAdornee = enemy:FindFirstChildWhichIsA("Model", true) or getRoot(enemy) or enemy
        end

        highlight = Instance.new("Highlight")
        highlight.Name = "CTDIG_KillPreview"
        highlight.Adornee = visualAdornee
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = visualAdornee
        killHighlights[enemy] = highlight
    end

    if lethal then
        highlight.FillColor = Color3.fromRGB(50, 220, 112)
        highlight.OutlineColor = Color3.fromRGB(125, 255, 170)
        highlight.FillTransparency = 0.72
        highlight.OutlineTransparency = 0.06
    else
        highlight.FillColor = Color3.fromRGB(236, 58, 66)
        highlight.OutlineColor = Color3.fromRGB(255, 112, 118)
        highlight.FillTransparency = 0.54
        highlight.OutlineTransparency = 0.02
    end

    local gui = ensureEnemyPredictLabel(enemy)
    local back = gui and gui:FindFirstChild("Back")
    local label = back and back:FindFirstChild("Text")
    if label and label:IsA("TextLabel") then
        local hp = math.max(0, tonumber(currentHealth) or 0)
        local dps = math.max(0, tonumber(potentialDps) or 0)

        -- User-facing text stays white. Safe/leak state is communicated by
        -- the green/red Highlight on the enemy itself.
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        label.Text = string.format(
            "HP %s  •  DPS %s  •  %s",
            formatCompactNumber(hp),
            formatCompactNumber(dps),
            lethal and "SAFE" or "LEAK"
        )
    end
end

local function horizontal(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end

local function sampleEnemyVelocity(enemy, now)
    local root = getRoot(enemy)
    if not root then
        return Vector3.zero
    end

    local position = root.Position
    local state = enemyMotion[enemy]
    if not state then
        state = {
            position = position,
            time = now,
            velocity = horizontal(root.AssemblyLinearVelocity),
        }
        enemyMotion[enemy] = state
    else
        local dt = now - (state.time or now)
        if dt >= 0.08 then
            local measured = horizontal(position - state.position) / dt
            if measured.Magnitude > 0.04 then
                if state.velocity and state.velocity.Magnitude > 0.04 then
                    state.velocity = state.velocity:Lerp(measured, 0.55)
                else
                    state.velocity = measured
                end
            end
            state.position = position
            state.time = now
        end
    end

    local velocity = state.velocity or Vector3.zero
    if velocity.Magnitude <= 0.04 then
        local assembly = horizontal(root.AssemblyLinearVelocity)
        if assembly.Magnitude > 0.04 then
            velocity = assembly
        else
            local baseSpeed = readNumberValue(enemy, "BaseSpeed") or 0
            local look = horizontal(root.CFrame.LookVector)
            if baseSpeed > 0 and look.Magnitude > 0.01 then
                velocity = look.Unit * baseSpeed
            end
        end
    end

    return velocity
end

local function coverageInterval(enemyPosition, velocity, towerPosition, range, horizon)
    local relative = horizontal(enemyPosition - towerPosition)
    local v = horizontal(velocity)
    local radius = math.max(0, range)
    local a = v:Dot(v)
    local c = relative:Dot(relative) - radius * radius

    if a < 0.0025 then
        if c <= 0 then
            return 0, horizon
        end
        return nil
    end

    local b = 2 * relative:Dot(v)
    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then
        if c <= 0 then
            return 0, horizon
        end
        return nil
    end

    local rootDisc = math.sqrt(discriminant)
    local t1 = (-b - rootDisc) / (2 * a)
    local t2 = (-b + rootDisc) / (2 * a)
    if t1 > t2 then
        t1, t2 = t2, t1
    end

    local enter = math.max(0, t1)
    local leave = math.min(horizon, t2)
    if c <= 0 then
        enter = 0
    end

    if leave < 0 or enter > horizon or leave < enter then
        return nil
    end
    return enter, leave
end

local function pathNodePosition(object, reverse)
    if typeof(object) ~= "Instance" then
        return nil
    end
    if object:IsA("Attachment") then
        return object.WorldPosition
    end
    if object:IsA("BasePart") then
        local node = object:FindFirstChild(reverse and "ReverseNode" or "Node")
            or object:FindFirstChild("Node")
        if node and node:IsA("Attachment") then
            return node.WorldPosition
        end
        return object.Position
    end
    local root = getRoot(object)
    return root and root.Position or nil
end

local function enemyPathPoints(enemy, position, velocity)
    local config = enemy:FindFirstChild("Configuration")
    local currentValue = config and config:FindFirstChild("CurrentPathObject")
    local maximumValue = config and config:FindFirstChild("MaximumPathObject")
    local currentObject = currentValue and currentValue.Value
    local maximumObject = maximumValue and maximumValue.Value
    local truePathValue = enemy:FindFirstChild("TruePath")
    local container = truePathValue and truePathValue:IsA("ObjectValue") and truePathValue.Value
        or (typeof(currentObject) == "Instance" and currentObject.Parent)
    local currentIndex = math.floor(readNumberValue(config, "CurrentPath") or 0)
    local maximumIndex = math.floor(readNumberValue(config, "MaximumPath") or 0)

    if typeof(currentObject) == "Instance" and tonumber(currentObject.Name) then
        currentIndex = math.floor(tonumber(currentObject.Name))
    end
    if typeof(maximumObject) == "Instance" and tonumber(maximumObject.Name) then
        maximumIndex = math.floor(tonumber(maximumObject.Name))
    end
    local reverse = maximumIndex > 0 and maximumIndex < currentIndex
    local step = reverse and -1 or 1

    local points = {}
    local lastObject
    local function append(object)
        local point = pathNodePosition(object, reverse)
        if not point then
            return
        end
        local delta = horizontal(point - position)
        if #points == 0 and velocity.Magnitude > 0.04 and delta.Magnitude > 0.05
            and delta:Dot(velocity) < -0.02 then
            return
        end
        if #points == 0 or horizontal(point - points[#points]).Magnitude > 0.03 then
            points[#points + 1] = point
            lastObject = object
        end
    end

    append(currentObject)
    if typeof(container) == "Instance" then
        local stopIndex = maximumIndex > 0 and maximumIndex or (currentIndex + step * 64)
        stopIndex = reverse and math.max(stopIndex, currentIndex - 128)
            or math.min(stopIndex, currentIndex + 128)
        for index = currentIndex + step, stopIndex, step do
            append(container:FindFirstChild(tostring(index)))
        end
    end
    if typeof(maximumObject) == "Instance" and maximumObject ~= lastObject then
        append(maximumObject)
    end

    local complete = typeof(maximumObject) == "Instance" and lastObject == maximumObject
        or maximumIndex > 0 and lastObject and tonumber(lastObject.Name) == maximumIndex
    return points, complete == true
end

local function buildEnemyTrajectory(enemy, position, velocity, horizon)
    local points, complete = enemyPathPoints(enemy, position, velocity)
    local config = enemy:FindFirstChild("Configuration")
    local speed = readNumberValue(config, "Speed") or velocity.Magnitude
    if not speed or speed <= 0.04 then
        speed = readNumberValue(enemy, "BaseSpeed") or velocity.Magnitude
    end
    speed = math.max(0.05, tonumber(speed) or 0.05)

    local segments = {}
    local from = position
    local time = 0
    for _, point in ipairs(points) do
        local delta = horizontal(point - from)
        local distance = delta.Magnitude
        if distance > 0.03 then
            local duration = distance / speed
            local finish = math.min(horizon, time + duration)
            local ratio = math.clamp((finish - time) / duration, 0, 1)
            local to = from:Lerp(point, ratio)
            segments[#segments + 1] = {
                from = from,
                velocity = delta.Unit * speed,
                start = time,
                finish = finish,
            }
            from = to
            time = finish
            if finish >= horizon then
                complete = false
                break
            end
        end
    end

    if #segments == 0 and not complete then
        local enemyRoot = getRoot(enemy)
        local look = enemyRoot and horizontal(enemyRoot.CFrame.LookVector) or Vector3.zero
        local direction = velocity.Magnitude > 0.04 and velocity.Unit
            or (look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1))
        segments[1] = {
            from = position,
            velocity = direction * speed,
            start = 0,
            finish = horizon,
        }
        time = horizon
    elseif time < horizon and not complete then
        local direction = velocity.Magnitude > 0.04 and velocity.Unit
            or segments[#segments].velocity.Unit
        segments[#segments + 1] = {
            from = from,
            velocity = direction * speed,
            start = time,
            finish = horizon,
        }
        time = horizon
    end

    return {
        segments = segments,
        exitTime = complete and time or horizon,
    }
end

local function trajectoryCoverage(trajectory, tower)
    local intervals = {}
    for _, segment in ipairs(trajectory.segments) do
        local duration = segment.finish - segment.start
        if duration > 0 then
            local enter, leave = coverageInterval(
                segment.from,
                segment.velocity,
                tower.position,
                tower.range,
                duration
            )
            if enter then
                enter = enter + segment.start
                leave = math.min(leave + segment.start, trajectory.exitTime)
                local previous = intervals[#intervals]
                if previous and enter <= previous.leave + 0.025 then
                    previous.leave = math.max(previous.leave, leave)
                else
                    intervals[#intervals + 1] = { enter = enter, leave = leave }
                end
            end
        end
    end
    return intervals
end

local function intervalAtOrAfter(intervals, time)
    for _, interval in ipairs(intervals) do
        if time >= interval.enter - 1e-4 and time <= interval.leave - 0.015 then
            return interval, true
        end
        if interval.enter > time then
            return interval, false
        end
    end
end

local function looksLikeRuntimeEnemy(object)
    if not object or object == Workspace or object == Workspace:FindFirstChild("Map") then
        return false
    end

    -- Do not require Model. In this game a replicated enemy container may be
    -- a Folder with the same direct runtime values/scripts/parts.
    local totalLife = object:FindFirstChild("TotalLife")
    local health2 = object:FindFirstChild("Health2")
    local humanoidObject = object:FindFirstChild("Humanoid")
    local config = object:FindFirstChild("Configuration")

    local hasHealth = totalLife ~= nil or health2 ~= nil or humanoidObject ~= nil
    if not hasHealth then
        return false
    end

    -- CurrentPath/BaseSpeed/OriginEnemyName make accidental matches extremely
    -- unlikely, while TotalLife alone is already authoritative for normal mobs.
    local enemySignature = object:FindFirstChild("BaseSpeed") ~= nil
        or object:FindFirstChild("OriginEnemyName") ~= nil
        or (config and config:FindFirstChild("CurrentPath") ~= nil)
        or totalLife ~= nil

    return enemySignature and getRoot(object) ~= nil
end

local function getEnemyModels(enemiesFolder)
    local enemies = {}
    if not enemiesFolder then
        return enemies
    end

    local seen = {}
    local function add(object)
        if object and not seen[object] and looksLikeRuntimeEnemy(object) then
            -- If a parent runtime container already qualified, do not also add
            -- an inner visual Model as a second copy of the same enemy.
            local ancestor = object.Parent
            while ancestor and ancestor ~= enemiesFolder do
                if seen[ancestor] then
                    return
                end
                ancestor = ancestor.Parent
            end
            seen[object] = true
            enemies[#enemies + 1] = object
        end
    end

    -- Native path: live enemies are direct children of Map.Enemies.
    for _, child in ipairs(enemiesFolder:GetChildren()) do
        add(child)
    end

    -- Wrapped/special enemies: accept Folder/Model containers at any depth.
    if #enemies == 0 then
        for _, object in ipairs(enemiesFolder:GetDescendants()) do
            add(object)
        end
    end

    return enemies
end

local function towerBelongsToLocalPlayer(tower)
    local owner = getOwner(tower)
    if owner ~= nil then
        return owner == player.Name or owner == tostring(player.UserId)
    end

    -- Some freshly replicated towers receive Configuration.Owner a frame
    -- after the model itself. Do not permanently lose them from visuals.
    local config = tower and tower:FindFirstChild("Configuration")
    return config ~= nil and config:FindFirstChild("Owner") == nil
end

local function trajectoryPositionAt(trajectory, time)
    if type(trajectory) ~= "table" or type(trajectory.segments) ~= "table" then
        return nil
    end

    local lastPosition
    for _, segment in ipairs(trajectory.segments) do
        local duration = math.max(0, (segment.finish or 0) - (segment.start or 0))
        if duration > 0 then
            if time >= (segment.start or 0) and time <= (segment.finish or 0) then
                local localTime = time - (segment.start or 0)
                return segment.from + segment.velocity * localTime
            end
            lastPosition = segment.from + segment.velocity * duration
        end
    end

    return lastPosition
end

local function normalizeTargetMode(mode)
    mode = string.lower(tostring(mode or "First"))
    mode = mode:gsub("[%s_%-]", "")
    return mode
end

local function predictTargetBetter(tower, candidate, best, shotTime)
    if not best then
        return true
    end

    local mode = tower.targetMode
    if mode:find("strong") then
        if candidate.remaining ~= best.remaining then
            return candidate.remaining > best.remaining
        end
    elseif mode:find("weak") then
        if candidate.remaining ~= best.remaining then
            return candidate.remaining < best.remaining
        end
    elseif mode:find("last") then
        local candidateExit = candidate.trajectory.exitTime or 60
        local bestExit = best.trajectory.exitTime or 60
        if candidateExit ~= bestExit then
            return candidateExit > bestExit
        end
    elseif mode:find("close") or mode:find("near") then
        local candidatePosition = trajectoryPositionAt(candidate.trajectory, shotTime)
        local bestPosition = trajectoryPositionAt(best.trajectory, shotTime)
        if candidatePosition and bestPosition then
            local candidateDistance = horizontal(candidatePosition - tower.position).Magnitude
            local bestDistance = horizontal(bestPosition - tower.position).Magnitude
            if math.abs(candidateDistance - bestDistance) > 0.01 then
                return candidateDistance < bestDistance
            end
        end
    elseif mode:find("far") then
        local candidatePosition = trajectoryPositionAt(candidate.trajectory, shotTime)
        local bestPosition = trajectoryPositionAt(best.trajectory, shotTime)
        if candidatePosition and bestPosition then
            local candidateDistance = horizontal(candidatePosition - tower.position).Magnitude
            local bestDistance = horizontal(bestPosition - tower.position).Magnitude
            if math.abs(candidateDistance - bestDistance) > 0.01 then
                return candidateDistance > bestDistance
            end
        end
    else
        -- "First" and unknown modes: prefer the enemy that reaches the end
        -- sooner. This mirrors the useful meaning of First without depending
        -- on a fragile guessed Progress scale.
        local candidateExit = candidate.trajectory.exitTime or 60
        local bestExit = best.trajectory.exitTime or 60
        if candidateExit ~= bestExit then
            return candidateExit < bestExit
        end
    end

    if candidate.progress ~= best.progress then
        return candidate.progress > best.progress
    end
    return candidate.index < best.index
end

local function updateKillPreview()
    if not (Toggles.CTDIGKillPreview and Toggles.CTDIGKillPreview.Value) then
        clearKillHighlights()
        setKillInfo("Kill Preview: OFF")
        setCombatDiagPredict("Predict OFF")
        return
    end

    local now = os.clock()
    if now - lastKillPreviewUpdate < 0.22 then
        return
    end
    lastKillPreviewUpdate = now

    local map = Workspace:FindFirstChild("Map")
    local enemiesFolder = map and map:FindFirstChild("Enemies")
    local towersFolder = getTowers()
    if not enemiesFolder or not towersFolder then
        clearKillHighlights()
        setKillInfo("Kill Preview: waiting for map")
        setCombatDiagPredict("Predict map/enemies missing")
        return
    end

    -- Short local prediction is intentionally used instead of guessing the
    -- complete map spline.  It is recalculated ~5x/sec, so turns are corrected
    -- as soon as the enemy actually changes direction.
    local horizon = 24
    local enemies = {}
    local seen = {}
    local healthMisses = 0

    for _, enemyModel in ipairs(getEnemyModels(enemiesFolder)) do
        if not seen[enemyModel] then
            local healthData = enemyHealthData(enemyModel)
            local root = getRoot(enemyModel)
            if healthData and healthData.current > 0 and root then
                local velocity = sampleEnemyVelocity(enemyModel, now)
                local config = enemyModel:FindFirstChild("Configuration")
                enemies[#enemies + 1] = {
                    index = #enemies + 1,
                    model = enemyModel,
                    root = root,
                    position = root.Position,
                    velocity = velocity,
                    health = healthData.current,
                    remaining = healthData.current,
                    healthData = healthData,
                    progress = readNumberValue(enemyModel, "BaseProgress")
                        or readNumberValue(enemyModel, "Progress")
                        or readNumberValue(config, "CurrentPath")
                        or 0,
                    potentialDps = 0,
                    covered = false,
                }
                seen[enemyModel] = true
            else
                healthMisses = healthMisses + 1
            end
        end
    end

    if #enemies == 0 then
        local stale = {}
        for enemy in pairs(killHighlights) do
            stale[#stale + 1] = enemy
        end
        for enemy in pairs(killLabels) do
            if not killHighlights[enemy] then
                stale[#stale + 1] = enemy
            end
        end
        for _, enemy in ipairs(stale) do
            removeKillHighlight(enemy)
        end
        setKillInfo("Kill Preview: no live enemies")
        setCombatDiagPredict(string.format(
            "Predict enemies=0 raw=%d descendants=%d healthMiss=%d",
            #enemiesFolder:GetChildren(),
            #enemiesFolder:GetDescendants(),
            healthMisses
        ))
        return
    end

    local towers = {}
    local towerStatMisses = 0
    for _, towerModel in ipairs(towersFolder:GetChildren()) do
        if getRoot(towerModel)
            and towerBelongsToLocalPlayer(towerModel) then
            local root = getRoot(towerModel)
            local stats = towerCombatStats(towerModel)
            if root and stats and stats.damage > 0 and stats.interval > 0 and stats.range > 0 then
                local tower = {
                    model = towerModel,
                    position = root.Position,
                    damage = stats.damage,
                    interval = stats.interval,
                    dps = stats.dps,
                    range = stats.range,
                    readyAt = stats.interval, -- conservative: first shot after one reload
                    targetMode = normalizeTargetMode(getTarget(towerModel)),
                    coverage = {},
                }

                for enemyIndex, enemy in ipairs(enemies) do
                    local enter, leave = coverageInterval(
                        enemy.position,
                        enemy.velocity,
                        tower.position,
                        tower.range,
                        horizon
                    )
                    if enter ~= nil and leave ~= nil and leave >= enter then
                        tower.coverage[enemyIndex] = { enter = enter, leave = leave }
                        enemy.covered = true
                        enemy.potentialDps = enemy.potentialDps + tower.dps
                    end
                end
                towers[#towers + 1] = tower
            else
                towerStatMisses = towerStatMisses + 1
            end
        end
    end

    if #towers == 0 then
        for _, enemy in ipairs(enemies) do
            setEnemyKillColor(enemy.model, false, enemy.health, enemy.health, 0)
        end
        setKillInfo(string.format("Predict: %d enemies | no usable towers", #enemies))
        setCombatDiagPredict(string.format(
            "Predict enemies=%d towers=0 statMiss=%d healthMiss=%d",
            #enemies,
            towerStatMisses,
            healthMisses
        ))
        return
    end

    local function positionAt(enemy, time)
        return enemy.position + enemy.velocity * time
    end

    local function targetBetter(tower, candidate, best, shotTime)
        if not best then
            return true
        end
        local mode = tower.targetMode or "first"
        if mode:find("strong") then
            if candidate.remaining ~= best.remaining then
                return candidate.remaining > best.remaining
            end
        elseif mode:find("weak") then
            if candidate.remaining ~= best.remaining then
                return candidate.remaining < best.remaining
            end
        elseif mode:find("last") then
            if candidate.progress ~= best.progress then
                return candidate.progress < best.progress
            end
        elseif mode:find("close") or mode:find("near") then
            local a = horizontal(positionAt(candidate, shotTime) - tower.position).Magnitude
            local b = horizontal(positionAt(best, shotTime) - tower.position).Magnitude
            if math.abs(a - b) > 0.01 then
                return a < b
            end
        elseif mode:find("far") then
            local a = horizontal(positionAt(candidate, shotTime) - tower.position).Magnitude
            local b = horizontal(positionAt(best, shotTime) - tower.position).Magnitude
            if math.abs(a - b) > 0.01 then
                return a > b
            end
        else
            -- First: higher replicated progress means farther along the path.
            if candidate.progress ~= best.progress then
                return candidate.progress > best.progress
            end
        end
        return candidate.index < best.index
    end

    -- Shared discrete-shot simulation: one tower cannot donate its full DPS to
    -- every zombie simultaneously. Each attack consumes one real reload slot.
    local totalHealth = 0
    local smallestDamage = math.huge
    for _, enemy in ipairs(enemies) do
        totalHealth = totalHealth + enemy.health
    end
    for _, tower in ipairs(towers) do
        smallestDamage = math.min(smallestDamage, tower.damage)
    end
    local usefulShots = smallestDamage < math.huge
        and math.ceil(totalHealth / math.max(0.001, smallestDamage)) or 0
    local maxEvents = math.clamp(usefulShots * 4 + #towers * 20 + #enemies * 12, 300, 9000)

    local shots = 0
    for _ = 1, maxEvents do
        local activeTower
        for _, tower in ipairs(towers) do
            if tower.readyAt <= horizon
                and (not activeTower or tower.readyAt < activeTower.readyAt) then
                activeTower = tower
            end
        end
        if not activeTower then
            break
        end

        local shotTime = activeTower.readyAt
        local bestEnemy
        local nextEnter
        for enemyIndex, enemy in ipairs(enemies) do
            if enemy.remaining > 0 and not enemy.healthData.invulnerable then
                local window = activeTower.coverage[enemyIndex]
                if window then
                    if shotTime >= window.enter - 1e-4 and shotTime <= window.leave - 0.01 then
                        if targetBetter(activeTower, enemy, bestEnemy, shotTime) then
                            bestEnemy = enemy
                        end
                    elseif window.enter > shotTime and window.enter <= horizon then
                        if not nextEnter or window.enter < nextEnter then
                            nextEnter = window.enter
                        end
                    end
                end
            end
        end

        if bestEnemy then
            bestEnemy.remaining = math.max(0, bestEnemy.remaining - activeTower.damage)
            shots = shots + 1
            activeTower.readyAt = shotTime + activeTower.interval
        elseif nextEnter then
            -- Tower can sit ready and fire as soon as the first future enemy
            -- actually enters its range.
            activeTower.readyAt = math.max(shotTime + 0.001, nextEnter)
        else
            activeTower.readyAt = math.huge
        end
    end

    local safe, leaks, uncovered = 0, 0, 0
    for _, enemy in ipairs(enemies) do
        local lethal = enemy.remaining <= 0 and not enemy.healthData.invulnerable
        if lethal then
            safe = safe + 1
        else
            leaks = leaks + 1
            if not enemy.covered then
                uncovered = uncovered + 1
            end
        end
        setEnemyKillColor(
            enemy.model,
            lethal,
            enemy.health,
            enemy.remaining,
            enemy.potentialDps
        )
    end

    local stale = {}
    for enemy in pairs(killHighlights) do
        if not seen[enemy] then
            stale[#stale + 1] = enemy
        end
    end
    for enemy in pairs(killLabels) do
        if not seen[enemy] and not killHighlights[enemy] then
            stale[#stale + 1] = enemy
        end
    end
    for _, enemy in ipairs(stale) do
        removeKillHighlight(enemy)
    end

    setKillInfo(string.format(
        "Predict: %d SAFE | %d LEAK | %d enemies | %d towers%s",
        safe,
        leaks,
        #enemies,
        #towers,
        uncovered > 0 and (" | " .. uncovered .. " uncovered") or ""
    ))
    setCombatDiagPredict(string.format(
        "Predict enemies=%d towers=%d shots=%d statMiss=%d healthMiss=%d",
        #enemies,
        #towers,
        shots,
        towerStatMisses,
        healthMisses
    ))
end

session.visuals = {
    destroyRangePreview = destroyRangePreview,
    refreshRangePreview = refreshRangePreview,
    formatCompactNumber = formatCompactNumber,
    towerDPS = towerDPS,
    towerCombatStats = towerCombatStats,
    sampleTowerLiveDPS = sampleTowerLiveDPS,
    ensureDpsGui = ensureDpsGui,
    clearDpsGuis = clearDpsGuis,
    clearKillHighlights = clearKillHighlights,
    updateKillPreview = updateKillPreview,
    setKillInfo = setKillInfo,
}
end

do
local function describeSurface(surface, worldPosition)
    if typeof(surface) ~= "Instance" then
        return nil
    end

    if surface == Workspace.Terrain then
        return {
            root = "Terrain",
            name = surface.Name,
            class = surface.ClassName,
            worldPosition = vec(worldPosition),
        }
    end

    local map = Workspace:FindFirstChild("Map")
    local root = Workspace
    local rootName = "Workspace"

    if map and (surface == map or surface:IsDescendantOf(map)) then
        root = map
        rootName = "Map"
    elseif not surface:IsDescendantOf(Workspace) then
        return nil
    end

    local description = {
        root = rootName,
        path = surface == root and {} or pathUnder(root, surface),
        name = surface.Name,
        class = surface.ClassName,
        worldPosition = vec(worldPosition),
    }

    if surface:IsA("BasePart") then
        description.localPosition = vec(surface.CFrame:PointToObjectSpace(worldPosition))
    end

    return description
end

local function resolveSurface(description, fallbackPosition)
    if type(description) ~= "table" then
        return nil, fallbackPosition
    end

    if description.root == "Terrain" then
        return Workspace.Terrain, fallbackPosition
    end

    local root
    if description.root == "Map" then
        root = Workspace:FindFirstChild("Map")
    elseif description.root == "Workspace" then
        root = Workspace
    end

    if not root then
        return nil, fallbackPosition
    end

    local surface = resolvePath(root, description.path)
    if surface and description.class and surface.ClassName ~= description.class then
        surface = nil
    end

    if not surface then
        local referencePosition = toVector3(description.worldPosition or vec(fallbackPosition))
        local bestDistance = math.huge

        for _, candidate in ipairs(root:GetDescendants()) do
            if candidate:IsA("BasePart")
                and (not description.name or candidate.Name == description.name)
                and (not description.class or candidate.ClassName == description.class) then
                local candidatePosition = candidate.Position
                if description.localPosition then
                    candidatePosition = candidate.CFrame:PointToWorldSpace(toVector3(description.localPosition))
                end

                local distance = (candidatePosition - referencePosition).Magnitude
                if distance < bestDistance then
                    surface = candidate
                    bestDistance = distance
                end
            end
        end
    end

    if not surface then
        return nil, fallbackPosition
    end

    if surface:IsA("BasePart") and description.localPosition then
        return surface, surface.CFrame:PointToWorldSpace(toVector3(description.localPosition))
    end

    return surface, fallbackPosition
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
end

local function resolveUnit(unitName, source)
    local cached = resolvedUnits[unitName]
    if cached and cached.Parent then
        return cached
    end

    local saved = resolveSource(source)
    if saved and saved.Name == unitName then
        resolvedUnits[unitName] = saved
        return saved
    end

    -- game2 itself uses ReplicatedStorage.Units[name].Levels["0"].Object[name]
    -- as a valid UnitChoosed/placeUnitHint object, so this is the stable replay path.
    local canonical = canonicalUnitObject(unitName)
    if canonical then
        resolvedUnits[unitName] = canonical
        return canonical
    end

    local config = findPlacementConfiguration()
    local chosen = config and config:FindFirstChild("UnitChoosed")
    if chosen and typeof(chosen.Value) == "Instance" and chosen.Value.Name == unitName then
        resolvedUnits[unitName] = chosen.Value
        return chosen.Value
    end

    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("ObjectValue") and object.Name == "Unit"
            and typeof(object.Value) == "Instance" and object.Value.Name == unitName then
            resolvedUnits[unitName] = object.Value
            return object.Value
        end
    end

    return nil
end

local function rawPlacementPosition(tower)
    local root = getRoot(tower)
    if not root then
        return nil
    end

    if tower:IsA("Model") then
        return root.Position - Vector3.new(
            root.Size.X / 2 - 0.5,
            root.Size.Y / 1.6 + 1,
            root.Size.Z / 2
        )
    end

    return root.Position - Vector3.new(
        root.Size.X / 2 - 0.5,
        root.Size.Y / 2 + 1,
        root.Size.Z / 2
    )
end

local function findPlacementSurface(tower, position)
    local placedOnPart = tower and tower:FindFirstChild("PlacedOnPart")
    if placedOnPart and placedOnPart:IsA("ObjectValue") and placedOnPart.Value then
        return placedOnPart.Value
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local towers = getTowers()
    if towers then
        ignore[#ignore + 1] = towers
    end
    if player.Character then
        ignore[#ignore + 1] = player.Character
    end
    params.FilterDescendantsInstances = ignore

    local result = Workspace:Raycast(position + Vector3.new(0, 12, 0), Vector3.new(0, -30, 0), params)
    return result and result.Instance or nil
end

local function recorderLine(action)
    local wave = tonumber(action.wave) or 0

    if action.type == "place" then
        return string.format("[WAVE %d] PLACE %s #%d", wave, tostring(action.unit), action.id)
    elseif action.type == "upgrade" then
        return string.format("[WAVE %d] UPGRADE %s #%d -> LVL %d", wave, tostring(action.unit), action.id, action.level)
    elseif action.type == "target" then
        return string.format("[WAVE %d] TARGET #%d -> %s", wave, action.id, tostring(action.mode))
    elseif action.type == "ability" then
        return string.format("[WAVE %d] ABILITY #%d -> %s", wave, action.id, tostring(action.ability))
    elseif action.type == "sell" then
        return string.format("[WAVE %d] SELL #%d", wave, action.id)
    elseif action.type == "skip" then
        return string.format("[WAVE %d] SKIP", wave)
    end

    return string.format("[WAVE %d] %s", wave, string.upper(tostring(action.type)))
end

local function addAction(action)
    if not recording or replaying or type(action) ~= "table" then
        return false
    end

    action.wave = tonumber(action.wave) or getWave()
    actions[#actions + 1] = action
    refreshRecorderStatus()
    logRecorderAction(recorderLine(action))

    if action.type == "place" then
        notify("Unit placed", string.format("%s #%d", action.unit, action.id), 3)
    elseif action.type == "upgrade" then
        notify("Unit upgraded", string.format("%s #%d -> LVL %d", action.unit, action.id, action.level), 3)
    elseif action.type == "target" then
        notify("Target changed", string.format("#%d -> %s", action.id, action.mode), 2)
    elseif action.type == "ability" then
        notify("Ability used", string.format("#%d -> %s", action.id, action.ability), 2)
    elseif action.type == "sell" then
        notify("Unit sold", string.format("#%d", action.id), 2)
    elseif action.type == "skip" then
        notify("Wave skipped", "Wave " .. tostring(action.wave), 2)
    end

    return true
end

local function ensureTowerState(tower)
    local state = towerState[tower]
    if not state then
        local level = getLevel(tower)
        state = {
            recordedLevel = level,
            target = getTarget(tower),
            cooldowns = {},
            boundCooldowns = {},
            lastAbilityRecordedAt = {},
            sold = false,
            ownedByRecorderPlayer = isMine(tower),
        }
        towerState[tower] = state
    elseif isMine(tower) then
        state.ownedByRecorderPlayer = true
    end
    return state
end

local function queueTowerAction(tower, action)
    if not recording or replaying or not tower or baselineTowers[tower] or type(action) ~= "table" then
        return false
    end

    local id = ids[tower]
    if id then
        action.id = id
        return addAction(action)
    end

    action.wave = tonumber(action.wave) or getWave()
    action.queuedAt = os.clock()
    local pending = session.pendingTowerActions[tower]
    if not pending then
        pending = {}
        session.pendingTowerActions[tower] = pending
    end

    -- Avoid duplicate queued target/sell states caused by replication rebinding.
    local previous = pending[#pending]
    if previous and previous.type == action.type then
        if action.type == "target" and previous.mode == action.mode then
            return true
        elseif action.type == "sell" then
            return true
        elseif action.type == "upgrade" and tonumber(previous.level) == tonumber(action.level) then
            return true
        elseif action.type == "ability" and previous.ability == action.ability then
            return true
        end
    end

    pending[#pending + 1] = action
    debugLog("queued recorder action until Place confirms: " .. tostring(action.type) .. " | " .. tostring(tower.Name))
    return true
end

local function flushTowerActions(tower)
    local id = ids[tower]
    local pending = session.pendingTowerActions[tower]
    if not id or not pending then
        return 0
    end

    session.pendingTowerActions[tower] = nil
    local flushed = 0
    for _, action in ipairs(pending) do
        action.id = id
        action.queuedAt = nil
        if addAction(action) then
            flushed = flushed + 1
        end
    end
    return flushed
end

local function recordPlace(tower, placement)
    if not recording or replaying or baselineTowers[tower]
        or ids[tower] or not isMine(tower) then
        return false
    end

    if placement and (placement.claimed or placement.unitName ~= tower.Name) then
        placement = nil
    end

    local position = rawPlacementPosition(tower)
    local root = getRoot(tower)
    if not position and root then
        position = root.Position
    end
    if not position and placement and type(placement.position) == "table" then
        position = toVector3(placement.position)
    end
    if not position then
        debugLog("confirmed placement has no usable position for " .. tower:GetFullName())
        return false
    end

    local surface = findPlacementSurface(tower, position)
    local surfaceDescription = surface and describeSurface(surface, position) or nil
    if not surfaceDescription and placement then
        surfaceDescription = placement.surface
    end
    if not surfaceDescription then
        debugLog("confirmed placement has no serializable surface for " .. tower:GetFullName())
        return false
    end

    local rotation
    local source
    local wave
    if placement then
        rotation = placement.rotation
        source = placement.source
        wave = placement.wave
        placement.claimed = true
    else
        rotation = root and vec(root.Orientation) or vec(Vector3.zero)
        local canonical = canonicalUnitObject(tower.Name)
        source = canonical and sourceFor(canonical) or nil
        wave = getWave()
    end

    if not source then
        local canonical = canonicalUnitObject(tower.Name)
        source = canonical and sourceFor(canonical) or nil
    end

    local id = nextId
    nextId = nextId + 1
    ids[tower] = id

    local state = ensureTowerState(tower)

    -- TowerInitialLevelSet is created by the game when a tower genuinely starts
    -- above level 0. Using the live Level here can accidentally bake an upgrade
    -- into PLACE if replication was slow and the player upgraded immediately.
    local initialLevelMarker = tower:FindFirstChild("TowerInitialLevelSet")
    local initialLevel = initialLevelMarker and tonumber(initialLevelMarker.Value) or 0
    local canonical = canonicalUnitObject(tower.Name)
    local initialTarget = canonical and getTarget(canonical) or nil
    if initialTarget == nil then
        initialTarget = state.target or getTarget(tower)
    end

    state.recordedLevel = initialLevel
    state.target = getTarget(tower)
    state.sold = false

    local placed = addAction({
        type = "place",
        unit = tower.Name,
        id = id,
        source = source,
        position = vec(position),
        rotation = rotation or vec(Vector3.zero),
        surface = surfaceDescription,
        initialLevel = initialLevel,
        initialTarget = initialTarget,
        wave = wave or getWave(),
    })

    if not placed then
        ids[tower] = nil
        nextId = math.max(1, nextId - 1)
        return false
    end

    flushTowerActions(tower)

    -- Final reconciliation repairs an upgrade/target change that happened before
    -- its observer finished binding, without relying on remote interception.
    local liveLevel = getLevel(tower)
    if liveLevel > (tonumber(state.recordedLevel) or 0) then
        state.recordedLevel = liveLevel
        local last = actions[#actions]
        if not (last and last.type == "upgrade" and last.id == id and tonumber(last.level) == liveLevel) then
            addAction({
                type = "upgrade",
                unit = tower.Name,
                id = id,
                level = liveLevel,
            })
        end
    end

    local liveTarget = getTarget(tower)
    if liveTarget and initialTarget and liveTarget ~= initialTarget then
        local last = actions[#actions]
        if not (last and last.type == "target" and last.id == id and last.mode == liveTarget) then
            addAction({
                type = "target",
                id = id,
                mode = liveTarget,
            })
        end
        state.target = liveTarget
    end

    return true
end

local function recordUpgrade(tower, hintedLevel)
    if not recording or replaying or not tower or baselineTowers[tower] then
        return false
    end

    local state = ensureTowerState(tower)
    if not state.ownedByRecorderPlayer and not isMine(tower) then
        return false
    end

    local newLevel = tonumber(hintedLevel) or getLevel(tower)
    if newLevel <= (tonumber(state.recordedLevel) or 0) then
        return false
    end

    state.recordedLevel = newLevel
    return queueTowerAction(tower, {
        type = "upgrade",
        unit = tower.Name,
        level = newLevel,
    })
end

local function bindLevel(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local level = config and config:FindFirstChild("Level")
    if not level or not level:IsA("ValueBase") then
        return
    end

    local state = ensureTowerState(tower)
    local existing = towerConnections[tower] and towerConnections[tower].level
    if state.boundLevel == level and existing and existing.Connected then
        return
    end
    state.boundLevel = level

    towerConnect(tower, level.Changed, function(value)
        local current = tonumber(value) or getLevel(tower)
        recordUpgrade(tower, current)
    end, "level")
end

local function bindTarget(tower)
    if not tower then
        return
    end

    local config = tower:FindFirstChild("Configuration")
    local other = config and config:FindFirstChild("OtherConfig")
        or tower:FindFirstChild("OtherConfig")
    if not other then
        return
    end

    local state = ensureTowerState(tower)

    -- OtherConfig and Targets can replicate a little later than Configuration.
    -- Listen to the nested container itself so a quick target click is not lost.
    local otherWatcher = towerConnections[tower] and towerConnections[tower].target_container
    if state.boundOtherConfig ~= other or not (otherWatcher and otherWatcher.Connected) then
        state.boundOtherConfig = other
        towerConnect(tower, other.ChildAdded, function(child)
            if child.Name == "Targets" then
                task.defer(function()
                    if session.alive and tower.Parent then
                        bindTarget(tower)
                    end
                end)
            end
        end, "target_container")
    end

    local targets = other:FindFirstChild("Targets")
    if not targets or not targets:IsA("ValueBase") then
        return
    end

    local existing = towerConnections[tower] and towerConnections[tower].target
    if state.boundTarget == targets and existing and existing.Connected then
        return
    end
    state.boundTarget = targets
    state.target = tostring(targets.Value)

    towerConnect(tower, targets.Changed, function(value)
        local mode = tostring(value)
        local previous = state.target
        state.target = mode

        if recording and not replaying and state.ownedByRecorderPlayer
            and previous ~= nil and mode ~= previous then
            queueTowerAction(tower, {
                type = "target",
                mode = mode,
            })
        end
    end, "target")
end

local function bindCooldown(tower, cooldown)
    if not cooldown or not cooldown:IsA("ValueBase") then
        return
    end

    local abilityNumber = cooldown.Name:match("^Ability(%d+)Cooldown$")
    if not abilityNumber then
        return
    end

    local state = ensureTowerState(tower)
    local ability = "Ability" .. abilityNumber
    local key = "cooldown_" .. ability
    local existing = towerConnections[tower] and towerConnections[tower][key]
    if state.boundCooldowns[ability] == cooldown and existing and existing.Connected then
        return
    end
    state.boundCooldowns[ability] = cooldown
    state.cooldowns[ability] = tonumber(cooldown.Value) or 0

    towerConnect(tower, cooldown.Changed, function(value)
        local current = tonumber(value) or 0
        local previous = tonumber(state.cooldowns[ability]) or 0
        state.cooldowns[ability] = current

        if recording and not replaying and state.ownedByRecorderPlayer
            and previous <= 0 and current > 0 then
            state.lastAbilityRecordedAt = state.lastAbilityRecordedAt or {}
            state.lastAbilityRecordedAt[ability] = os.clock()
            queueTowerAction(tower, {
                type = "ability",
                ability = ability,
            })
        end
    end, key)
end

local function capturePlacementAttempt()
    if not recording or replaying then
        return
    end

    local config = findPlacementConfiguration()
    local chosen = config and config:FindFirstChild("UnitChoosed")
    local orientation = config and config:FindFirstChild("UnitOrientation")
    local current = config and config:FindFirstChild("CurrentUnitPlacingObject")
    local unit = chosen and chosen.Value

    if typeof(unit) ~= "Instance" then
        placementAttempt = nil
        return
    end

    local preview = current and current.Value
    local position = typeof(preview) == "Instance" and rawPlacementPosition(preview) or nil
    local surface = position and findPlacementSurface(preview, position) or nil
    placementAttempt = {
        unitName = unit.Name,
        source = sourceFor(unit),
        rotation = orientation and vec(orientation.Value) or vec(Vector3.zero),
        position = position and vec(position) or nil,
        surface = surface and describeSurface(surface, position) or nil,
        wave = getWave(),
        startedAt = os.clock(),
        claimed = false,
    }
    session.placementQueue[#session.placementQueue + 1] = placementAttempt
    while #session.placementQueue > 24 do
        table.remove(session.placementQueue, 1)
    end
end

local function manualPlacementFor(unitName)
    local now = os.clock()

    local function matches(placement)
        return placement
            and not placement.claimed
            and placement.unitName == unitName
            and now - placement.startedAt <= 10
    end

    for index = #session.placementQueue, 1, -1 do
        local queued = session.placementQueue[index]
        if queued.claimed or now - queued.startedAt > 15 then
            table.remove(session.placementQueue, index)
        end
    end

    for _, queued in ipairs(session.placementQueue) do
        if matches(queued) then
            return queued
        end
    end

    if matches(recentPlacement) then
        return recentPlacement
    end
    if matches(placementAttempt) then
        return placementAttempt
    end
end

local function rememberSelection()
    if placementRecorderBound then
        return true
    end

    local config = findPlacementConfiguration()
    local commencing = config and config:FindFirstChild("CommencingPlace")
    if not commencing or not commencing:IsA("BoolValue") then
        return false
    end

    placementConfiguration = config
    placementRecorderBound = true
    connect(commencing.Changed, function(value)
        if not session.alive or commencing.Parent ~= placementConfiguration then
            placementRecorderBound = false
            return
        end
        if value == true then
            capturePlacementAttempt()
        end
        if value ~= true and placementAttempt then
            -- Keep the attempt briefly as metadata only. A real tower appearing in
            -- workspace.Towers is the actual success confirmation.
            if recording and not placementAttempt.claimed then
                recentPlacement = placementAttempt
            end
            placementAttempt = nil
        end
    end)

    return true
end

local function ensurePlacementRecorder()
    if rememberSelection() then
        return true
    end

    if placementRecorderBinding then
        return false
    end

    placementRecorderBinding = true
    task.spawn(function()
        local started = os.clock()
        while session.alive and not placementRecorderBound and os.clock() - started < 30 do
            if rememberSelection() then
                break
            end
            task.wait(0.1)
        end
        placementRecorderBinding = false
    end)

    return false
end

local function skipDetected(wave, source)
    if not recording or replaying then
        return false
    end

    local now = os.clock()
    local hasPendingVote = pendingSkipWave ~= nil and now - pendingSkipAt <= 60
    local nativeAutoSkip = getNativeAutoSkipSetting()
    if not hasPendingVote and not (nativeAutoSkip and nativeAutoSkip.Value == true) then
        return false
    end

    if hasPendingVote then
        wave = pendingSkipWave
    else
        wave = tonumber(wave) or getWave()
    end

    wave = math.max(0, math.floor(tonumber(wave) or 0))

    -- WaveTimeSkipped and AutoSkippedWaves describe the same successful skip
    -- and can replicate on opposite sides of the Wave increment.
    if lastSkipConfirmationWave
        and now - lastSkipConfirmationAt <= 0.75
        and math.abs(wave - lastSkipConfirmationWave) <= 1 then
        return false
    end

    if recordedSkipWaves[wave] then
        return false
    end

    recordedSkipWaves[wave] = source or true
    lastSkipConfirmationWave = wave
    lastSkipConfirmationAt = now
    pendingSkipWave = nil
    pendingSkipAt = 0
    return addAction({
        type = "skip",
        wave = wave,
    })
end

local function resolveSellTowerFromButton(button)
    if not button or not button:IsA("GuiButton") then
        return nil
    end

    -- The game's real RemoveButton LocalScript uses:
    -- script.Parent.Parent.Parent.Data.Object.Value
    -- Walk a few ancestors instead of hardcoding one UI branch so the recorder
    -- survives harmless GUI nesting changes.
    local node = button.Parent
    for _ = 1, 6 do
        if not node then
            break
        end
        local data = node:FindFirstChild("Data")
        local object = data and data:FindFirstChild("Object")
        if object and object:IsA("ObjectValue") and object.Value then
            return object.Value
        end
        node = node.Parent
    end
    return nil
end

local function recordSellIntent(tower, source)
    if not recording or replaying or not tower or not tower.Parent then
        return false
    end
    if not isMine(tower) or baselineTowers[tower] then
        return false
    end

    local state = ensureTowerState(tower)
    if state.sold then
        return true
    end

    -- If the tower was placed only moments ago, confirm its Place before the
    -- server removes it. Otherwise a SELL could become an orphan pending action.
    if not ids[tower] then
        local placement = manualPlacementFor(tower.Name)
        recordPlace(tower, placement)
        if placement == recentPlacement and ids[tower] then
            recentPlacement = nil
        end
    end

    state.sold = true
    state.sellSeenAt = os.clock()
    state.sellSource = source or "unknown"

    local ok = queueTowerAction(tower, {
        type = "sell",
    })
    if ok then
        debugLog("sell detected via " .. tostring(state.sellSource) .. " | " .. tostring(tower.Name))
    end
    return ok
end

local function bindSellButton(button)
    if not button or button.Name ~= "RemoveButton" or not button:IsA("GuiButton") then
        return
    end

    local bindings = session.sourceBindings
    if bindings.sellButtons[button] then
        return
    end
    bindings.sellButtons[button] = true

    -- MouseButton1Down fires before the game's MouseButton1Click handler calls
    -- RemoveUnit:FireServer(), so the tower still exists and its recorder id is
    -- available. Activated covers touch/gamepad. recordSellIntent deduplicates.
    connect(button.MouseButton1Down, function()
        local tower = resolveSellTowerFromButton(button)
        if tower then
            recordSellIntent(tower, "RemoveButton.MouseButton1Down")
        end
    end)

    connect(button.Activated, function()
        local tower = resolveSellTowerFromButton(button)
        if tower then
            recordSellIntent(tower, "RemoveButton.Activated")
        end
    end)
end

local function bindSellUi()
    local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
    if not playerGui then
        return
    end

    for _, descendant in ipairs(playerGui:GetDescendants()) do
        bindSellButton(descendant)
    end

    local bindings = session.sourceBindings
    if not bindings.sellGuis[playerGui] then
        bindings.sellGuis[playerGui] = true
        connect(playerGui.DescendantAdded, function(descendant)
            if session.alive then
                bindSellButton(descendant)
            end
        end)
    end
end


-- Recorder input support ------------------------------------------------------
-- The game itself uses PlayerData.Settings hotkeys.  We only OBSERVE those
-- inputs; we never consume them, change input state, or intercept remotes.

local function guiTreeEnabled(object)
    local node = object
    while node and node ~= playerGui do
        if node:IsA("ScreenGui") and node.Enabled == false then
            return false
        end
        if node:IsA("GuiObject") and node.Visible == false then
            return false
        end
        node = node.Parent
    end
    return true
end

local function towerFromDataContainer(container)
    if not container then
        return nil
    end
    local data = container:FindFirstChild("Data")
    local object = data and data:FindFirstChild("Object")
    local tower = object and object:IsA("ObjectValue") and object.Value or nil
    local towers = getTowers()
    if tower and towers and tower.Parent == towers and isMine(tower) then
        return tower
    end
    return nil
end

local function selectedTowerFromGui()
    local towers = getTowers()
    if not towers or not playerGui then
        return nil
    end

    -- Prefer the two real management GUIs used by the saved game.
    for _, name in ipairs({ "TowerManageGui", "UpgradeGui" }) do
        local gui = playerGui:FindFirstChild(name)
        if gui and guiTreeEnabled(gui) then
            local direct = towerFromDataContainer(gui)
            if direct then
                return direct
            end
        end
    end

    -- Some game variants wrap the management frame differently.  Resolve the
    -- same Data.Object pattern without guessing one exact nesting path.
    local fallback
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("ObjectValue") and object.Name == "Object" then
            local tower = object.Value
            if tower and tower.Parent == towers and isMine(tower) then
                if guiTreeEnabled(object) then
                    return tower
                end
                fallback = fallback or tower
            end
        end
    end
    return fallback
end

local function resolveTowerFromActionButton(button)
    if not button or not button:IsA("GuiButton") then
        return nil
    end
    local node = button.Parent
    for _ = 1, 7 do
        if not node then
            break
        end
        local tower = towerFromDataContainer(node)
        if tower then
            return tower
        end
        node = node.Parent
    end
    return selectedTowerFromGui()
end

local function recorderSettings()
    local data = player:FindFirstChild("PlayerData")
    return data and data:FindFirstChild("Settings")
end

local function hotkeyText(input)
    if not input then
        return ""
    end
    local ok, text = pcall(UserInputService.GetStringForKeyCode, UserInputService, input.KeyCode)
    if ok and type(text) == "string" and text ~= "" then
        return text:upper()
    end
    return tostring(input.KeyCode.Name or ""):upper()
end

local function settingMatchesHotkey(settings, settingName, keyText)
    local value = settings and settings:FindFirstChild(settingName)
    if not value then
        return false
    end
    local wanted = tostring(value.Value or "")
    return wanted ~= "" and wanted:upper() == keyText
end

local function recordUpgradeIntent(tower, source)
    if not recording or replaying or not tower or not tower.Parent or not isMine(tower) then
        return
    end
    bindLevel(tower)
    local before = getLevel(tower)
    task.spawn(function()
        local started = os.clock()
        while session.alive and recording and tower.Parent and os.clock() - started < 1.25 do
            local current = getLevel(tower)
            if current > before then
                recordUpgrade(tower, current)
                debugLog("upgrade confirmed via " .. tostring(source) .. " | " .. tower.Name .. " -> " .. tostring(current))
                return
            end
            task.wait(0.035)
        end
    end)
end

local function recordTargetHotkeyIntent(tower, source)
    if not recording or replaying or not tower or not tower.Parent or not isMine(tower) then
        return
    end
    bindTarget(tower)
    local state = ensureTowerState(tower)
    local before = getTarget(tower) or state.target
    task.spawn(function()
        local started = os.clock()
        while session.alive and recording and tower.Parent and os.clock() - started < 0.8 do
            local mode = getTarget(tower)
            if mode and mode ~= before then
                -- bindTarget normally records first. If replication replaced the
                -- target Value before its Changed connection fired, recover here.
                if state.target ~= mode then
                    state.target = mode
                    queueTowerAction(tower, {
                        type = "target",
                        mode = mode,
                    })
                    debugLog("target confirmed via " .. tostring(source) .. " | " .. tower.Name .. " -> " .. mode)
                end
                return
            end
            task.wait(0.025)
        end
    end)
end

local function recordAbilityHotkeyIntent(tower, ability, source)
    if not recording or replaying or not tower or not tower.Parent or not isMine(tower) then
        return
    end
    local cooldown = tower:FindFirstChild(ability .. "Cooldown")
    if not cooldown or not cooldown:IsA("ValueBase") then
        return
    end
    bindCooldown(tower, cooldown)
    local before = tonumber(cooldown.Value) or 0
    if before > 0 then
        return -- key press while still cooling down is not a successful ability
    end

    local state = ensureTowerState(tower)
    task.spawn(function()
        local started = os.clock()
        while session.alive and recording and tower.Parent and os.clock() - started < 0.8 do
            local current = tonumber(cooldown.Value) or 0
            if current > 0 then
                local last = state.lastAbilityRecordedAt and state.lastAbilityRecordedAt[ability] or 0
                if os.clock() - last > 0.2 then
                    state.lastAbilityRecordedAt = state.lastAbilityRecordedAt or {}
                    state.lastAbilityRecordedAt[ability] = os.clock()
                    queueTowerAction(tower, {
                        type = "ability",
                        ability = ability,
                    })
                    debugLog("ability confirmed via " .. tostring(source) .. " | " .. tower.Name .. " -> " .. ability)
                end
                return
            end
            task.wait(0.025)
        end
    end)
end

local function bindUpgradeButton(button)
    if not button or button.Name ~= "UpgradeButton" or not button:IsA("GuiButton") then
        return
    end
    local bindings = session.sourceBindings
    if bindings.upgradeButtons[button] then
        return
    end
    bindings.upgradeButtons[button] = true

    local function onIntent(source)
        local tower = resolveTowerFromActionButton(button)
        if tower then
            recordUpgradeIntent(tower, source)
        end
    end

    connect(button.MouseButton1Down, function()
        onIntent("UpgradeButton.MouseButton1Down")
    end)
    connect(button.Activated, function()
        onIntent("UpgradeButton.Activated")
    end)
end

local function bindRecorderActionUi()
    if not playerGui then
        return
    end

    for _, descendant in ipairs(playerGui:GetDescendants()) do
        bindSellButton(descendant)
        bindUpgradeButton(descendant)
    end

    local bindings = session.sourceBindings
    if not bindings.actionGuis[playerGui] then
        bindings.actionGuis[playerGui] = true
        connect(playerGui.DescendantAdded, function(descendant)
            if session.alive then
                bindSellButton(descendant)
                bindUpgradeButton(descendant)
            end
        end)
    end
end

local function bindRecorderHotkeys()
    local bindings = session.sourceBindings
    if bindings.hotkeysBound then
        return
    end
    bindings.hotkeysBound = true

    connect(UserInputService.InputBegan, function(input, gameProcessed)
        if not session.alive or not recording or replaying then
            return
        end
        -- Do not turn typing in a TextBox into macro actions.
        if UserInputService:GetFocusedTextBox() then
            return
        end

        local settings = recorderSettings()
        local tower = selectedTowerFromGui()
        if not settings or not tower then
            return
        end

        local key = hotkeyText(input)
        if key == "" then
            return
        end

        -- Sell is executed by the game through RemoveUnit directly from the
        -- hotkey, so record the intent before the tower disappears.
        if settingMatchesHotkey(settings, "SellHotkey", key)
            or input.KeyCode == Enum.KeyCode.ButtonY then
            recordSellIntent(tower, "SellHotkey:" .. key)
            return
        end

        -- Upgrade is supported BOTH from the real hotkey and UpgradeButton,
        -- but only recorded after Configuration.Level actually increases.
        if settingMatchesHotkey(settings, "UpgradeHotkey", key)
            or input.KeyCode == Enum.KeyCode.ButtonA then
            recordUpgradeIntent(tower, "UpgradeHotkey:" .. key)
            return
        end

        if settingMatchesHotkey(settings, "TargetingHotkey", key) then
            recordTargetHotkeyIntent(tower, "TargetingHotkey:" .. key)
            return
        end

        -- Ability hotkeys are dynamic in Settings. Confirm success from the
        -- cooldown transition so pressing a key while on cooldown is not saved.
        for abilityIndex = 1, 9 do
            local settingName = "Ability" .. abilityIndex .. "Hotkey"
            if settingMatchesHotkey(settings, settingName, key) then
                recordAbilityHotkeyIntent(
                    tower,
                    "Ability" .. abilityIndex,
                    settingName .. ":" .. key
                )
                return
            end
        end
    end)
end

local function bindTower(tower)
    if not tower or not tower.Parent or not isMine(tower) then
        return
    end

    local firstBind = towerConnections[tower] == nil
    towerConnections[tower] = towerConnections[tower] or {}
    ensureTowerState(tower)

    bindLevel(tower)
    bindTarget(tower)

    for _, child in ipairs(tower:GetChildren()) do
        if child:IsA("ValueBase") and child.Name:match("^Ability%d+Cooldown$") then
            bindCooldown(tower, child)
        end
    end

    if not firstBind then
        return
    end

    towerConnect(tower, tower.ChildAdded, function(child)
        if child.Name == "BeingUpgradedddd" then
            task.defer(function()
                if not session.alive or not tower.Parent then
                    return
                end
                bindLevel(tower)
                bindTarget(tower)
                recordUpgrade(tower)
            end)
        elseif child.Name == "Configuration" then
            task.defer(function()
                if not session.alive or not tower.Parent then
                    return
                end
                bindLevel(tower)
                bindTarget(tower)
                recordUpgrade(tower)
            end)
        elseif child.Name == "OtherConfig" then
            task.defer(function()
                if session.alive and tower.Parent then
                    bindTarget(tower)
                end
            end)
        elseif child.Name:match("^Ability%d+Cooldown$") then
            bindCooldown(tower, child)
        end
    end, "children")

    local function observeSellMarker()
        local state = towerState[tower]
        if state and state.ownedByRecorderPlayer
            and tower:GetAttribute("AlreadyBeingSold") == true then
            recordSellIntent(tower, "AlreadyBeingSold")
        end
    end

    towerConnect(tower, tower:GetAttributeChangedSignal("AlreadyBeingSold"), observeSellMarker, "sold")
    -- The marker only exists for about 0.1s in game2. If binding happened in
    -- the middle of that window, read the current attribute immediately too.
    observeSellMarker()

    towerConnect(tower, tower.AncestryChanged, function()
        task.defer(function()
            if tower.Parent ~= getTowers() then
                disconnectTower(tower)
            end
        end)
    end, "ancestry")
end

local function onTowerPlaced(tower)
    if not tower or session.pendingTowerRecords[tower] then
        return
    end

    session.pendingTowerRecords[tower] = true
    task.spawn(function()
        local ok, err = xpcall(function()
            local towers = getTowers()
            if not towers then
                return
            end

            -- game2 can create TowerPlaced before the tower, Owner and
            -- PlacedOnPart finish replicating. Wait for the authoritative
            -- workspace.Towers instance instead of serializing a partial clone.
            local started = os.clock()
            while session.alive and os.clock() - started < 5 do
                local placedOnPart = tower:FindFirstChild("PlacedOnPart")
                local surfaceReady = placedOnPart and placedOnPart:IsA("ObjectValue")
                    and placedOnPart.Value ~= nil
                local coreReady = tower.Parent == towers and getOwner(tower) and getRoot(tower)
                if coreReady and (not recording or surfaceReady or os.clock() - started >= 1.25) then
                    break
                end
                task.wait()
            end

            if not session.alive or tower.Parent ~= towers or not isMine(tower) then
                return
            end

            bindTower(tower)

            if recording and not replaying and not baselineTowers[tower] and not ids[tower] then
                local placement = manualPlacementFor(tower.Name)
                if recordPlace(tower, placement) and placement == recentPlacement then
                    recentPlacement = nil
                end
            end
        end, tracebackError)

        session.pendingTowerRecords[tower] = nil
        if not ok and session.alive then
            warn("[CTDIG] Tower recorder recovery error:\n" .. tostring(err))
        end
    end)
end

local function bindGameSources()
    local bindings = session.sourceBindings
    local towers = getTowers()
    if not towers and next(bindings.towerFolders) == nil then
        towers = Workspace:WaitForChild("Towers", 15)
    end
    if not towers then
        return false, "workspace.Towers was not found"
    end

    local detects = getDetects()
    bindSellUi() -- legacy/button fallback
    bindRecorderActionUi()
    bindRecorderHotkeys()

    for _, tower in ipairs(towers:GetChildren()) do
        if isMine(tower) then
            bindTower(tower)
        end
    end

    if not bindings.towerFolders[towers] then
        bindings.towerFolders[towers] = true
        connect(towers.ChildAdded, function(tower)
            if session.alive then
                onTowerPlaced(tower)
            end
        end)

        connect(towers.ChildRemoved, function(tower)
            task.defer(function()
                if tower.Parent ~= towers then
                    disconnectTower(tower)
                end
            end)
        end)
    end

    if detects and not bindings.detects[detects] then
        bindings.detects[detects] = true
        connect(detects.ChildAdded, function(event)
            task.defer(function()
                if not session.alive or not event:IsA("ObjectValue") then
                    return
                end

                local tower = event.Value
                if not tower then
                    return
                end

                if event.Name == "TowerPlaced" then
                    onTowerPlaced(tower)
                else
                    local level = event.Name:match("^TowerUpgraded(%d+)$")
                    if not level then
                        return
                    end

                    bindTower(tower)
                    recordUpgrade(tower, tonumber(level))
                end
            end)
        end)
    elseif not detects then
        debugLog("EverythingDetects not found; using confirmed tower/config fallback events")
    end

    local gameVals = getGameVals()
    local skipping = Workspace:FindFirstChild("Skipping")

    if skipping and not bindings.skipping[skipping] then
        bindings.skipping[skipping] = true
        connect(skipping.ChildAdded, function(entry)
            if recording and not replaying and entry.Name == player.Name then
                pendingSkipWave = getWave()
                pendingSkipAt = os.clock()
            end
        end)

        connect(skipping.ChildRemoved, function(entry)
            if entry.Name ~= player.Name or pendingSkipWave == nil then
                return
            end

            local pending = pendingSkipWave
            task.delay(1, function()
                if session.alive and pendingSkipWave == pending and not recordedSkipWaves[pending] then
                    pendingSkipWave = nil
                    pendingSkipAt = 0
                end
            end)
        end)
    end

    if gameVals and not bindings.gameVals[gameVals] then
        bindings.gameVals[gameVals] = true
        local waveTimeSkipped = gameVals:FindFirstChild("WaveTimeSkipped")
        if waveTimeSkipped and waveTimeSkipped:IsA("ValueBase") then
            local previous = tonumber(waveTimeSkipped.Value) or 0
            connect(waveTimeSkipped.Changed, function(value)
                local current = tonumber(value) or 0
                if current > previous then
                    skipDetected(getWave(), "WaveTimeSkipped")
                end
                previous = current
            end)
        end

        local autoSkippedWaves = gameVals:FindFirstChild("AutoSkippedWaves")
        if autoSkippedWaves and autoSkippedWaves:IsA("ValueBase") then
            local previous = tonumber(autoSkippedWaves.Value) or 0
            connect(autoSkippedWaves.Changed, function(value)
                local current = tonumber(value) or 0
                if current > previous then
                    skipDetected(getWave(), "AutoSkippedWaves")
                end
                previous = current
            end)
        end
    end

    local map = Workspace:FindFirstChild("Map")
    local mapConfig = map and map:FindFirstChild("Configuration")
    local wave = mapConfig and mapConfig:FindFirstChild("Wave")
    if wave and wave:IsA("ValueBase") and not bindings.waves[wave] then
        bindings.waves[wave] = true
        connect(wave.Changed, function()
            if recording then
                refreshRecorderStatus()
            end
        end)
    end

    return true
end

local LUA_RESERVED_KEYS = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local function finiteMacroNumber(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return value
end

local function serializeValue(value, indent, seen)
    indent = indent or 0
    seen = seen or {}
    local kind = type(value)

    if kind == "string" then
        return string.format("%q", value)
    elseif kind == "number" then
        local numberValue = finiteMacroNumber(value)
        -- tostring() is valid for every finite Lua number and avoids
        -- executor-specific %g differences.
        return tostring(numberValue)
    elseif kind == "boolean" then
        return value and "true" or "false"
    elseif kind ~= "table" then
        return "nil"
    end

    if seen[value] then
        -- Recorder action data is not supposed to be cyclic. Keeping the
        -- generated macro valid is more important than serializing a bad cycle.
        return "nil"
    end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" then
            keys[#keys + 1] = key
        end
    end

    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            if type(a) == "number" then
                return finiteMacroNumber(a) < finiteMacroNumber(b)
            end
            return tostring(a) < tostring(b)
        end
        return type(a) < type(b)
    end)

    if #keys == 0 then
        seen[value] = nil
        return "{}"
    end

    local pad = string.rep("    ", indent)
    local childPad = string.rep("    ", indent + 1)
    local lines = { "{" }

    for _, key in ipairs(keys) do
        local prefix
        if type(key) == "number" then
            prefix = "[" .. tostring(finiteMacroNumber(key)) .. "]"
        else
            local keyString = tostring(key)
            if keyString:match("^[%a_][%w_]*$") and not LUA_RESERVED_KEYS[keyString] then
                prefix = keyString
            else
                prefix = "[" .. string.format("%q", keyString) .. "]"
            end
        end

        lines[#lines + 1] = childPad
            .. prefix
            .. " = "
            .. serializeValue(value[key], indent + 1, seen)
            .. ","
    end

    lines[#lines + 1] = pad .. "}"
    seen[value] = nil
    return table.concat(lines, "\n")
end

local function saveMacro()
    if typeof(writefile) ~= "function" then
        notify("Save error", "writefile is unavailable", 4)
        return false
    end

    local RAW_CORE_URL = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui.lua"

    local function macroNumber(value)
        local number = tonumber(value) or 0
        if number ~= number or number == math.huge or number == -math.huge then
            number = 0
        end
        if math.abs(number) < 0.0000005 then
            number = 0
        end
        local text = string.format("%.6f", number)
        text = text:gsub("0+$", ""):gsub("%.$", "")
        if text == "-0" or text == "" then
            text = "0"
        end
        return text
    end

    local function vec3Source(value)
        value = type(value) == "table" and value or {}
        return string.format(
            "Vector3.new(%s, %s, %s)",
            macroNumber(value.x or value.X or value[1]),
            macroNumber(value.y or value.Y or value[2]),
            macroNumber(value.z or value.Z or value[3])
        )
    end

    local function unitVar(id)
        local numeric = tonumber(id)
        if numeric then
            return "U" .. tostring(math.max(0, math.floor(numeric)))
        end
        return "U_" .. tostring(id):gsub("[^%w_]", "_")
    end

    local lines = {
        "-- CTDIG / XOMA AUTOEXEC STRATEGY",
        "-- Generated by CTDIG Recorder.",
        "-- Put this ctdig.lua directly into your executor autoexecute folder.",
        "",
        "local XOMA = loadstring(game:HttpGet(" .. string.format("%q", RAW_CORE_URL) .. "))()",
        "",
        "XOMA:Map(" .. string.format("%q", tostring(macroMap or "Unknown")) .. ")",
        "XOMA:Deck({",
    }

    for _, unitName in ipairs(macroDeck or {}) do
        if tostring(unitName or "") ~= "" and tostring(unitName) ~= "None" then
            lines[#lines + 1] = "    " .. string.format("%q", tostring(unitName)) .. ","
        end
    end
    lines[#lines + 1] = "})"

    local previousWave = nil
    for _, action in ipairs(actions) do
        local wave = math.max(0, math.floor(tonumber(action.wave) or 0))
        if previousWave ~= wave then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "-- WAVE " .. tostring(wave)
            previousWave = wave
        end

        if action.type == "place" then
            local var = unitVar(action.id)
            local rotation = action.rotation or { x = 0, y = 0, z = 0 }
            lines[#lines + 1] = string.format(
                "local %s = XOMA:Place(%q, %s, %d, %s)",
                var,
                tostring(action.unit or ""),
                vec3Source(action.position),
                wave,
                vec3Source(rotation)
            )
        elseif action.type == "upgrade" then
            lines[#lines + 1] = string.format(
                "XOMA:Upgrade(%s, %s, %d)",
                unitVar(action.id),
                macroNumber(action.level),
                wave
            )
        elseif action.type == "target" then
            lines[#lines + 1] = string.format(
                "XOMA:Target(%s, %q, %d)",
                unitVar(action.id),
                tostring(action.mode or "First"),
                wave
            )
        elseif action.type == "ability" then
            lines[#lines + 1] = string.format(
                "XOMA:Ability(%s, %q, %d)",
                unitVar(action.id),
                tostring(action.ability or "Ability1"),
                wave
            )
        elseif action.type == "sell" then
            lines[#lines + 1] = string.format(
                "XOMA:Sell(%s, %d)",
                unitVar(action.id),
                wave
            )
        elseif action.type == "skip" then
            lines[#lines + 1] = string.format("XOMA:Skip(%d)", wave)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "XOMA:Run()"

    local content = table.concat(lines, "\n")

    if typeof(loadstring) == "function" then
        local callOk, chunk, compileError = pcall(loadstring, content)
        if not callOk or type(chunk) ~= "function" then
            local message = callOk
                and tostring(compileError or "loadstring returned nil without a compiler message")
                or tostring(chunk)
            pcall(function()
                writefile("ctdig.compile_failed.lua", content)
            end)
            notify(
                "Save error",
                "XOMA strategy compile failed: " .. message .. " | dumped ctdig.compile_failed.lua",
                8
            )
            return false
        end
    end

    local function writeAndVerify(path, data)
        local ok, err = pcall(writefile, path, data)
        if not ok then
            return false, tostring(err)
        end
        if typeof(readfile) == "function" then
            local readOk, saved = pcall(readfile, path)
            if not readOk then
                return false, "read-back failed for " .. path .. ": " .. tostring(saved)
            end
            if saved ~= data then
                return false, "read-back mismatch for " .. path
            end
        end
        return true
    end

    local oldContent
    if typeof(isfile) == "function" and typeof(readfile) == "function" and isfile(MACRO_FILE) then
        local oldOk, old = pcall(readfile, MACRO_FILE)
        if not oldOk then
            notify("Save error", "Existing " .. MACRO_FILE .. " could not be read: " .. tostring(old), 6)
            return false
        end
        oldContent = old
        local backupOk, backupError = writeAndVerify(MACRO_BACKUP_FILE, oldContent)
        if not backupOk then
            notify("Save warning", "Could not verify backup: " .. tostring(backupError), 5)
        end
    end

    local tempOk, tempError = writeAndVerify(MACRO_TEMP_FILE, content)
    if not tempOk then
        notify("Save error", "Temporary write failed: " .. tostring(tempError), 6)
        return false
    end

    if typeof(isfile) == "function" and typeof(delfile) == "function" and isfile(MACRO_FILE) then
        local deleteOk, deleteError = pcall(delfile, MACRO_FILE)
        if not deleteOk then
            notify("Save error", "Could not replace old " .. MACRO_FILE .. ": " .. tostring(deleteError), 6)
            return false
        end
    end

    local finalOk, finalError = writeAndVerify(MACRO_FILE, content)
    if not finalOk then
        if oldContent ~= nil then
            pcall(writefile, MACRO_FILE, oldContent)
        end
        notify("Save error", "Final overwrite failed: " .. tostring(finalError), 6)
        return false
    end

    pcall(function()
        if typeof(delfile) == "function" and typeof(isfile) == "function" and isfile(MACRO_TEMP_FILE) then
            delfile(MACRO_TEMP_FILE)
        end
    end)

    notify(
        "Macro saved",
        string.format("workspace/%s -> XOMA autoexec | %d actions | %d bytes", MACRO_FILE, #actions, #content),
        5
    )
    return true
end

local function loadMacro()
    if typeof(readfile) ~= "function" or typeof(isfile) ~= "function" or not isfile(MACRO_FILE) then
        return nil, MACRO_FILE .. " was not found"
    end

    local ok, result = pcall(function()
        return loadstring(readfile(MACRO_FILE))()
    end)

    if not ok or type(result) ~= "table" or type(result.actions) ~= "table" then
        return nil, ok and "invalid macro format" or tostring(result)
    end

    local supported = {
        place = true,
        upgrade = true,
        target = true,
        ability = true,
        sell = true,
        skip = true,
    }
    local placeIds = {}
    for index, action in ipairs(result.actions) do
        if type(action) ~= "table" or not supported[action.type] then
            return nil, "invalid action #" .. tostring(index)
        end
        if action.type ~= "skip" and action.id == nil then
            return nil, "action #" .. tostring(index) .. " has no tower id"
        end
        if action.type == "place" then
            if type(action.unit) ~= "string" or type(action.position) ~= "table" then
                return nil, "place action #" .. tostring(index) .. " is incomplete"
            end
            if placeIds[action.id] then
                return nil, "duplicate place id " .. tostring(action.id)
            end
            placeIds[action.id] = true
        end
    end

    return result
end

session.auto = session.auto or {}

function session.auto.requiredUnitsFromMacro(macro)
    local required = {}
    local seen = {}

    local sourceDeck = type(macro) == "table" and macro.deck or nil
    if type(sourceDeck) == "table" then
        for _, unitName in ipairs(sourceDeck) do
            unitName = tostring(unitName or "")
            if unitName ~= "" and unitName ~= "None" and not seen[unitName] then
                seen[unitName] = true
                required[#required + 1] = unitName
            end
        end
    end

    if #required == 0 and type(macro) == "table" and type(macro.actions) == "table" then
        for _, action in ipairs(macro.actions) do
            if action.type == "place" and type(action.unit) == "string" and not seen[action.unit] then
                seen[action.unit] = true
                required[#required + 1] = action.unit
            end
        end
    end

    return required
end

function session.auto.deckContainsRequired(deck, required)
    local have = {}
    for _, unitName in ipairs(deck or {}) do
        if unitName and unitName ~= "None" then
            have[tostring(unitName)] = true
        end
    end
    for _, unitName in ipairs(required or {}) do
        if not have[tostring(unitName)] then
            return false, tostring(unitName)
        end
    end
    return true
end

function session.auto.deckExactMatches(a, b)
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

function session.auto.loadoutDataDeck(data)
    local towers = type(data) == "table" and data.Towers or nil
    if type(towers) ~= "table" then
        return {}
    end

    local slots = {}
    for key, value in pairs(towers) do
        local index = tonumber(tostring(key):match("^Tower(%d+)$"))
        if index then
            slots[#slots + 1] = { index = index, value = tostring(value) }
        end
    end
    table.sort(slots, function(a, b) return a.index < b.index end)

    local deck = {}
    for _, slot in ipairs(slots) do
        deck[#deck + 1] = slot.value
    end
    return deck
end

function session.auto.verifyCurrentMacroDeck(macro)
    local required = session.auto.requiredUnitsFromMacro(macro)
    if #required == 0 then
        return true
    end

    local current = session.getDeckSnapshot()
    if #current == 0 then
        return false, "PlayerData.Loadout is empty/unavailable"
    end

    local ok, missing = session.auto.deckContainsRequired(current, required)
    if ok then
        return true
    end

    return false, "missing " .. tostring(missing) .. " | current: " .. session.compactDeckText(current)
end

function session.auto.ensureMacroDeckInLobby(macro)
    local required = session.auto.requiredUnitsFromMacro(macro)
    if #required == 0 then
        return true
    end

    local data = player:WaitForChild("PlayerData", 20)
    local loadout = data and data:WaitForChild("Loadout", 20)
    if not loadout then
        return false, "PlayerData.Loadout was not found"
    end

    local current = session.getDeckSnapshot()
    local contains = session.auto.deckContainsRequired(current, required)
    if contains then
        return true
    end

    local module = getCTDModule()
    if not module or type(module.PlayerLoadouts) ~= "function" then
        return false, "CTDModule.PlayerLoadouts is unavailable"
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
    local wantedDeck = type(macro.deck) == "table" and macro.deck or nil

    for code, loadoutData in pairs(loadouts) do
        local deck = session.auto.loadoutDataDeck(loadoutData)
        local deckOk = session.auto.deckContainsRequired(deck, required)
        if deckOk then
            fallbackCode = fallbackCode or code
            if wantedDeck and #wantedDeck > 0 and session.auto.deckExactMatches(deck, wantedDeck) then
                exactCode = code
                break
            end
        end
    end

    local code = exactCode or fallbackCode
    if code == nil then
        return false, "no saved loadout contains: " .. table.concat(required, ", ")
    end

    setReplayStatus("Lobby | equipping deck " .. tostring(code))
    local equipOk, equipResult = pcall(module.PlayerLoadouts, player, "EquipLoadout", {
        loadoutcode = tostring(code),
    })
    if not equipOk then
        return false, "EquipLoadout failed: " .. tostring(equipResult)
    end

    local started = os.clock()
    while session.alive and os.clock() - started < 8 do
        local deck = session.getDeckSnapshot()
        if session.auto.deckContainsRequired(deck, required) then
            notify("AutoExecute", "Deck equipped: " .. session.compactDeckText(deck), 3)
            return true
        end
        task.wait(0.1)
    end

    return false, "deck did not update after EquipLoadout | current: " .. session.compactDeckText(session.getDeckSnapshot())
end

function session.auto.isElevatorRoomCandidate(object)
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

function session.auto.collectElevatorRooms()
    local root = Workspace:FindFirstChild("Elevators")
    local rooms = {}
    if not root then
        return rooms
    end

    for _, object in ipairs(root:GetDescendants()) do
        if session.auto.isElevatorRoomCandidate(object) then
            rooms[#rooms + 1] = object
        end
    end

    table.sort(rooms, function(a, b)
        local ao = a:FindFirstChild("RoomOwner")
        local bo = b:FindFirstChild("RoomOwner")
        local aFree = not ao or tostring(ao.Value) == "" or tostring(ao.Value) == player.Name
        local bFree = not bo or tostring(bo.Value) == "" or tostring(bo.Value) == player.Name
        if aFree ~= bFree then
            return aFree
        end
        return a:GetFullName() < b:GetFullName()
    end)
    return rooms
end

function session.auto.playerInsideElevator(room)
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
        for _, entry in ipairs(currentPlayers:GetChildren()) do
            if entry:IsA("ObjectValue") and entry.Value == player then
                return true
            end
        end
    end
    return false
end

function session.auto.moveIntoElevator(room)
    local character = player.Character or player.CharacterAdded:Wait()
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Torso")
        or character.PrimaryPart
    local plate = room and room:FindFirstChild("baseplate", true)
    if not root or not plate or not plate:IsA("BasePart") then
        return false, "elevator root/baseplate missing"
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
    while session.alive and os.clock() - started < 3.5 do
        if session.auto.playerInsideElevator(room) then
            return true
        end
        task.wait(0.1)
    end

    -- Some lobby builds invoke EnterElevator on the client before RoomOwner is
    -- replicated. OpenRoom below remains the authoritative confirmation.
    return true
end

function session.auto.openMacroMapFromLobby(macro)
    local elevators = remotes:FindFirstChild("Elevators")
    if not elevators or not elevators:IsA("RemoteFunction") then
        return false, "Remotes.Elevators is missing"
    end
    if type(macro.map) ~= "string" or macro.map == "" or macro.map == "Unknown" then
        return false, "macro has no valid map name"
    end

    local rooms = session.auto.collectElevatorRooms()
    if #rooms == 0 then
        return false, "no elevator rooms were found"
    end

    local lastError = "no free elevator accepted OpenRoom"
    for index, room in ipairs(rooms) do
        if not session.alive then
            return false, "stopped"
        end

        local owner = room:FindFirstChild("RoomOwner")
        if not owner or tostring(owner.Value) == "" or tostring(owner.Value) == player.Name then
            setReplayStatus(string.format("Lobby | elevator %d/%d", index, #rooms))
            local moved, moveError = session.auto.moveIntoElevator(room)
            if moved then
                local currentMap = room:FindFirstChild("CurrentMap")
                local limit = room:FindFirstChild("Limit")
                local entry = room:FindFirstChild("RoomEntryMode")
                local mapMode = room:FindFirstChild("MapMode")
                pcall(function() currentMap.Value = macro.map end)
                pcall(function() limit.Value = 1 end)
                pcall(function() entry.Value = "FriendsOnly" end)
                pcall(function() mapMode.Value = "Classic" end)

                local payload = {
                    Gamemode = "Classic",
                    CurrentMap = macro.map,
                    Limit = 1,
                    RoomEntryMode = "FriendsOnly",
                    MapMode = "Classic",
                    MapModifiers = {},
                }

                local callOk, opened = pcall(function()
                    return elevators:InvokeServer(room, "OpenRoom", payload)
                end)
                if callOk and opened == true then
                    notify("AutoExecute", "Room opened: " .. macro.map .. " | FriendsOnly", 3)
                    setReplayStatus("Lobby | teleporting to " .. macro.map)
                    task.wait(0.35)
                    local tpOk, tpError = pcall(function()
                        return elevators:InvokeServer(room, "Teleport")
                    end)
                    if tpOk then
                        notify("AutoExecute", "Teleport requested: " .. macro.map, 4)
                        return true
                    end
                    lastError = "Teleport failed: " .. tostring(tpError)
                else
                    lastError = callOk and "OpenRoom rejected elevator " .. tostring(index) or tostring(opened)
                end
            else
                lastError = moveError or lastError
            end
        end
    end

    return false, lastError
end

function session.auto.waitForReplayWave(action, index, total)
    local target = math.max(0, math.floor(tonumber(action and action.wave) or 0))
    while replaying and session.alive do
        local current = getWave()
        if current >= target then
            return true
        end
        setReplayStatus(string.format(
            "%d/%d | waiting wave %d (now %d) | %s",
            tonumber(index) or 0,
            tonumber(total) or 0,
            target,
            current,
            tostring(action and action.type or "action")
        ))
        task.wait(0.1)
    end
    return false
end

local function getCash()
    local safe = player:FindFirstChild("LocalSafeData")
    local cash = safe and safe:FindFirstChild("CashREADONLY")
    return cash and tonumber(cash.Value) or nil
end

local function placementCost(unitName)
    local module = getCTDModule()
    if module and type(module.gettowerupgradecost) == "function" then
        local ok, cost = pcall(module.gettowerupgradecost, unitName, player, { InputLevel = 0 })
        if ok then
            return tonumber(cost)
        end
    end
end

local function upgradeCost(tower)
    local info = tower and tower:FindFirstChild("AdditionalInfo")
    local value = info and info:FindFirstChild("NextUpgradeCost")
    return value and tonumber(value.Value) or nil
end

local function waitForMoney(cost)
    if not cost then
        return replaying
    end

    while replaying do
        local cash = getCash()
        if not cash or cash >= cost then
            return true
        end
        task.wait(0.05)
    end

    return false
end

local function performPlace(action)
    local unit = resolveUnit(action.unit, action.source)
    if not unit then
        return nil, "unit " .. tostring(action.unit) .. " was not found in saved UnitChoosed/current loadout UI"
    end

    if not waitForMoney(placementCost(action.unit)) then
        return nil, "stopped"
    end

    local position = toVector3(action.position)
    local surface
    surface, position = resolveSurface(action.surface, position)

    if not surface then
        return nil, "placement surface for " .. tostring(action.unit) .. " was not found"
    end

    local placeUnit = remotes:FindFirstChild("PlaceUnit")
    if not placeUnit or not placeUnit:IsA("RemoteFunction") then
        return nil, "Remotes.PlaceUnit is missing"
    end

    local towers = getTowers()
    if not towers then
        return nil, "workspace.Towers is missing"
    end

    local before = {}
    for _, tower in ipairs(towers:GetChildren()) do
        before[tower] = true
    end

    local placeable = true
    local module = getCTDModule()
    local units = ReplicatedStorage:FindFirstChild("Units")
    local unitFolder = units and units:FindFirstChild(action.unit)
    local tags = unitFolder and unitFolder:FindFirstChild("Tags")

    if module and type(module.checkcanplace) == "function" and tags then
        local checked, valid = pcall(module.checkcanplace, player, surface, position, tags, {
            TowerName = action.unit,
        })
        if not checked then
            return nil, "placement validation failed: " .. tostring(valid)
        end
        placeable = valid == true
    end

    if stackerState.enabled then
        stackerDebug("Macro checkcanplace = " .. tostring(placeable))
    end

    if not placeable then
        return nil, "placement currently invalid"
    end

    if stackerState.enabled then
        stackerDebug("PlaceUnit called = yes (Macro Replay)")
    end

    local ok, result = pcall(function()
        return placeUnit:InvokeServer(
            unit,
            position,
            toVector3(action.rotation),
            placeable,
            surface
        )
    end)

    if not ok then
        if stackerState.enabled then
            stackerDebug("PlaceUnit result = error: " .. tostring(result))
        end
        return nil, tostring(result)
    end

    -- game2 treats nil as a rejected placement. A non-nil response still has
    -- to be confirmed by the newly-created owned tower.
    if result == nil then
        if stackerState.enabled then
            stackerDebug("Macro PlaceUnit = nil/rejected (possible server-side validation)")
        end
        return nil, "server rejected placement"
    end

    if stackerState.enabled then
        stackerDebug("PlaceUnit result = non-nil (" .. typeof(result) .. ")")
    end

    local started = os.clock()
    while replaying and os.clock() - started < 2.5 do
        if typeof(result) == "Instance"
            and result.Parent == towers
            and isMine(result) then
            if stackerState.enabled then
                stackerDebug("tower appeared in workspace.Towers = yes")
            end
            return result
        end

        local best
        local bestDistance = math.huge
        for _, tower in ipairs(towers:GetChildren()) do
            if not before[tower] and tower.Name == action.unit and isMine(tower) then
                local placedAt = rawPlacementPosition(tower)
                local distance = placedAt and (placedAt - position).Magnitude or math.huge
                if distance < bestDistance then
                    bestDistance = distance
                    best = tower
                end
            end
        end

        if best and bestDistance <= 8 then
            if stackerState.enabled then
                stackerDebug("tower appeared in workspace.Towers = yes")
            end
            return best
        end

        task.wait()
    end

    if stackerState.enabled then
        stackerDebug("tower appeared in workspace.Towers = no")
    end
    return nil, "placement was not confirmed in workspace.Towers"
end

local function performUpgrade(tower, desiredLevel)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    desiredLevel = tonumber(desiredLevel) or (getLevel(tower) + 1)
    if getLevel(tower) >= desiredLevel then
        return true
    end

    if not waitForMoney(upgradeCost(tower)) then
        return false, "stopped"
    end

    local before = getLevel(tower)

    local function waitChanged(seconds)
        local started = os.clock()
        while replaying and tower.Parent and os.clock() - started < seconds do
            if getLevel(tower) > before then
                return true
            end
            task.wait()
        end
        return getLevel(tower) > before
    end

    -- This is the upgrade path used by the active Hover LocalScript in game2.rbxlx.
    local old = remotes:FindFirstChild("UpgradeUnit")
    if old and old:IsA("RemoteEvent") then
        local ok, err = pcall(function()
            old:FireServer(tower)
        end)
        if not ok then
            return false, tostring(err)
        end

        return waitChanged(3), "server rejected upgrade"
    end

    -- Compatibility fallback only when the active game2 RemoteEvent is absent.
    local v2 = remotes:FindFirstChild("UpgradeUnitV2")
    if v2 and v2:IsA("RemoteFunction") then
        local ok, success = pcall(function()
            return v2:InvokeServer(tower)
        end)
        if ok and success == true and waitChanged(3) then
            return true
        end
        return false, ok and "server rejected upgrade" or tostring(success)
    end

    local module = getCTDModule()
    if module and type(module.locallyprocesspurchasetowerupgrade) == "function" then
        local ok, success = pcall(module.locallyprocesspurchasetowerupgrade, tower)
        if ok and success == true and waitChanged(1.25) then
            return true
        end
    end

    return getLevel(tower) >= desiredLevel, "server rejected upgrade"
end

local function performTarget(tower, mode)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    if getTarget(tower) == mode then
        return true
    end

    local remote = remotes:FindFirstChild("TargetUnit")
    if not remote or not remote:IsA("RemoteFunction") then
        return false, "Remotes.TargetUnit is missing"
    end

    for _ = 1, 24 do
        if not replaying or not tower.Parent then
            return false, "stopped"
        end

        if getTarget(tower) == mode then
            return true
        end

        pcall(function()
            remote:InvokeServer(tower)
        end)
        task.wait(0.05)
    end

    return getTarget(tower) == mode, "target mode was not reached"
end

local function performAbility(tower, ability)
    if not tower or not tower.Parent then
        return false, "tower missing"
    end

    local module = getCTDModule()
    local cooldown = tower:FindFirstChild(ability .. "Cooldown")

    if not cooldown and module and type(module.DoTowerAbilities) == "function" then
        pcall(module.DoTowerAbilities, tower, "Initialize", {})
        cooldown = tower:FindFirstChild(ability .. "Cooldown")
    end

    if cooldown and tonumber(cooldown.Value) and cooldown.Value > 0 then
        return false, "ability cooldown"
    end

    local before = cooldown and tonumber(cooldown.Value) or 0
    local fired = false

    if module and type(module.DoTowerAbilities) == "function" then
        fired = pcall(module.DoTowerAbilities, tower, "ActivateAbility", {
            abilitycode = ability,
        })
    else
        local remote = remotes:FindFirstChild("CTDModuleActivateSkillServer")
        if remote and remote:IsA("RemoteEvent") then
            remote:FireServer(tower, "ActivateAbility", {
                abilitycode = ability,
            })
            fired = true
        end
    end

    if not fired then
        return false, "ability handler is missing"
    end

    if not cooldown then
        return true
    end

    local started = os.clock()
    while tower.Parent and os.clock() - started < 0.8 do
        if tonumber(cooldown.Value) and cooldown.Value > before then
            return true
        end
        task.wait()
    end

    return false, "ability not ready"
end

local function performSell(tower)
    if not tower or not tower.Parent then
        return true
    end

    local remote = remotes:FindFirstChild("RemoveUnit")
    if not remote or not remote:IsA("RemoteEvent") then
        return false, "Remotes.RemoveUnit is missing"
    end

    local ok, err = pcall(function()
        remote:FireServer(tower)
    end)
    if not ok then
        return false, tostring(err)
    end

    local started = os.clock()
    while tower.Parent and os.clock() - started < 2 do
        task.wait()
    end

    return not tower.Parent, "server rejected sell"
end

local function performSkip()
    local gameVals = getGameVals()
    local able = gameVals and gameVals:FindFirstChild("AbleToSkip")
    local waveTimeSkipped = gameVals and gameVals:FindFirstChild("WaveTimeSkipped")
    local map = Workspace:FindFirstChild("Map")

    local started = os.clock()
    while replaying and os.clock() - started < 45 do
        if (able and able.Value == true) or (map and map:FindFirstChild("CanSkip")) then
            break
        end
        task.wait(0.05)
    end

    if not replaying then
        return false, "stopped"
    end

    if not ((able and able.Value == true) or (map and map:FindFirstChild("CanSkip"))) then
        return false, "skip never became available"
    end

    local setting = getNativeAutoSkipSetting()
    local wasEnabled = setting and setting.Value == true or false
    local keepEnabled = Toggles.CTDIGAutoSkip and Toggles.CTDIGAutoSkip.Value == true or false
    local beforeWave = getWave()
    local beforeSkipped = waveTimeSkipped and tonumber(waveTimeSkipped.Value) or nil

    local ok, err = setNativeAutoSkip(true)
    if not ok then
        return false, err
    end

    local confirmed = false
    started = os.clock()
    while replaying and os.clock() - started < 8 do
        if getWave() ~= beforeWave then
            confirmed = true
            break
        end

        if beforeSkipped and waveTimeSkipped and tonumber(waveTimeSkipped.Value) > beforeSkipped then
            confirmed = true
            break
        end

        task.wait(0.05)
    end

    if not wasEnabled and not keepEnabled then
        setNativeAutoSkip(false)
    end

    return confirmed, confirmed and nil or "skip was not confirmed"
end

local function setEndActionStatus(text)
    if endActionLabel and type(endActionLabel.SetText) == "function" then
        endActionLabel:SetText(text)
    elseif Options.CTDIGEndAction and type(Options.CTDIGEndAction.SetText) == "function" then
        Options.CTDIGEndAction:SetText(text)
    end
end

local function findEndScreenButton(name)
    local endFrame = playerGui:FindFirstChild("EndFrame")
    local roundFrame = endFrame and endFrame:FindFirstChild("RoundFrame")
    local exact = roundFrame and roundFrame:FindFirstChild(name)
    if exact and exact:IsA("GuiButton") then
        return exact
    end

    for _, descendant in ipairs(playerGui:GetDescendants()) do
        if descendant:IsA("GuiButton") and descendant.Name == name
            and descendant:FindFirstAncestor("EndFrame") then
            return descendant
        end
    end
end

local function fireGuiButton(button)
    if not button or not button.Parent then
        return false, "button missing"
    end

    local env = getfenv and getfenv() or _G
    local fire = rawget(env, "firesignal") or firesignal
    if type(fire) ~= "function" then
        return false, "firesignal unavailable"
    end

    local getConnections = rawget(env, "getconnections") or getconnections
    local candidates = {
        { name = "MouseButton1Click", signal = button.MouseButton1Click },
        { name = "Activated", signal = button.Activated },
        { name = "MouseButton1Down", signal = button.MouseButton1Down },
        { name = "MouseButton1Up", signal = button.MouseButton1Up },
    }
    local selected = candidates[((math.max(1, session.endAction.attempts) - 1) % #candidates) + 1]
    if type(getConnections) == "function" then
        for _, candidate in ipairs(candidates) do
            local okConnections, signalConnections = pcall(getConnections, candidate.signal)
            if okConnections and type(signalConnections) == "table" and #signalConnections > 0 then
                selected = candidate
                break
            end
        end
    end

    local ok, err = pcall(function()
        -- Use the button's real local signal. The save does not expose a
        -- trustworthy server remote for these end-screen actions.
        fire(selected.signal)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, selected.name
end

local function handleEndAction()
    local control = session.endAction
    if control.busy or not session.alive then
        return
    end

    local autoRetry = Toggles.CTDIGAutoRetry and Toggles.CTDIGAutoRetry.Value == true
    local autoLobby = Toggles.CTDIGAutoBackLobby and Toggles.CTDIGAutoBackLobby.Value == true
    if not autoRetry and not autoLobby then
        control.key = nil
        control.confirmed = false
        return
    end

    local resultValue = player:FindFirstChild("PlayerGameResult")
    local result = resultValue and tostring(resultValue.Value) or ""
    if result ~= "Defeat" and result ~= "Triumph" then
        -- A new round has started / result was cleared. Allow the next end
        -- screen to be handled again.
        control.key = nil
        control.confirmed = false
        return
    end

    local actionName = autoRetry and "Restart" or "Return"
    local key = result .. ":" .. actionName
    local now = os.clock()
    if control.key ~= key then
        control.key = key
        control.attempts = 0
        control.nextAttempt = 0
        control.startedAt = now
        control.confirmed = false
    end

    local endFrame = playerGui:FindFirstChild("EndFrame")
    local markerName = autoRetry and "Restarted" or "Teleported"
    if endFrame and endFrame:FindFirstChild(markerName) then
        control.confirmed = true
        setEndActionStatus((autoRetry and "Auto Retry" or "Auto Lobby") .. ": confirmed")
        return
    end
    if control.confirmed or now < control.nextAttempt then
        return
    end

    local button = findEndScreenButton(actionName)
    if not button or not button.Visible or not button.Active then
        setEndActionStatus((autoRetry and "Auto Retry" or "Auto Lobby") .. ": waiting for result button")
        return
    end

    control.busy = true
    control.attempts = control.attempts + 1
    local attempt = control.attempts
    control.nextAttempt = now + (attempt <= 6 and 0.8 or math.min(4, 1.25 + attempt * 0.12))
    task.spawn(function()
        if replaying then
            replayStopRequested = true
            replaying = false
        end

        setEndActionStatus((autoRetry and "Auto Retry" or "Auto Lobby") .. ": activating")
        local ok, detail = fireGuiButton(button)
        if ok then
            if attempt == 1 then
                notify(
                    autoRetry and "Auto Retry" or "Auto Lobby",
                    autoRetry and "Restart requested" or "Exit to Lobby requested",
                    3
                )
            end
            setEndActionStatus(string.format(
                "%s: request %d via %s",
                autoRetry and "Auto Retry" or "Auto Lobby",
                attempt,
                tostring(detail)
            ))
        else
            if autoLobby then
                -- The game already has a native BanishmentTimer teleport. If the
                -- executor cannot fire the real Return button, leave that native
                -- teleport intact rather than inventing a remote.
                setEndActionStatus("Auto Lobby: " .. tostring(detail) .. " | native teleport remains")
            else
                setEndActionStatus("Auto Retry: " .. tostring(detail))
            end
        end
        control.busy = false
    end)
end

local function isFatalReplayError(err)
    err = tostring(err or "")
    return err:find("was not found", 1, true)
        or err:find("surface for", 1, true)
        or err:find(" is missing", 1, true)
        or err:find("handler is missing", 1, true)
        or err:find("unsupported action", 1, true)
end

local function replayBackoff(retries)
    retries = math.max(1, tonumber(retries) or 1)
    return math.min(1.5, 0.1 * (1.18 ^ math.min(retries, 18)))
end

local function replayMacro()
    if replaying or replayTaskRunning then
        return
    end

    if recording then
        notify("Replay error", "Stop and save the active recording first", 4)
        return
    end

    local macro, err = loadMacro()
    if not macro then
        notify("Replay error", err, 5)
        setReplayStatus("Error: " .. tostring(err))
        return
    end

    local currentMap = getMapName()
    if macro.map and macro.map ~= "" and macro.map ~= "Unknown" and currentMap ~= macro.map then
        notify("Wrong map", "Macro: " .. macro.map .. " | Current: " .. currentMap, 6)
        setReplayStatus("Wrong map")
        return
    end

    local deckOk, deckError = session.auto.verifyCurrentMacroDeck(macro)
    if not deckOk then
        notify("Wrong deck", deckError, 7)
        setReplayStatus("Wrong deck: " .. tostring(deckError))
        return
    end

    local placeById = {}
    for _, action in ipairs(macro.actions) do
        if action.type == "place" and action.id then
            placeById[action.id] = action
        end
    end

    resolvedUnits = {}
    local runtime = {}
    replayStopRequested = false
    replayTaskRunning = true
    replaying = true
    setRecorderState("replaying")
    setReplayStatus(string.format("Starting | 0/%d", #macro.actions))
    notify("Replay started", tostring(#macro.actions) .. " actions", 3)

    local replayError
    local processed = 0

    local function stopWithError(message, duration)
        replaying = false
        if replayStopRequested or not session.alive then
            return
        end

        replayError = tostring(message)
        notify("Replay error", replayError, duration or 5)
    end

    local function restore(id)
        local state = runtime[id]
        if state and state.tower and state.tower.Parent then
            return state.tower
        end

        if state and state.sold then
            return nil, "unit #" .. id .. " was already sold"
        end

        local place = placeById[id]
        if not place then
            return nil, "place action for #" .. id .. " is missing"
        end

        state = state or {
            level = tonumber(place.initialLevel) or 0,
            target = place.initialTarget,
        }
        runtime[id] = state

        while replaying and session.alive do
            local tower, placeError = performPlace(place)
            if tower then
                state.tower = tower
                break
            end

            if isFatalReplayError(placeError) then
                return nil, placeError
            end

            state.placeRetries = (state.placeRetries or 0) + 1
            setReplayStatus(string.format("Auto-retry %d | place %s #%s", state.placeRetries, place.unit, tostring(id)))
            task.wait(replayBackoff(state.placeRetries))
        end

        if not replaying or not state.tower then
            return nil, "stopped"
        end

        local targetLevel = tonumber(state.level) or getLevel(state.tower)
        while replaying and session.alive and getLevel(state.tower) < targetLevel do
            local ok = performUpgrade(state.tower, getLevel(state.tower) + 1)
            if not ok then
                state.upgradeRetries = (state.upgradeRetries or 0) + 1
                setReplayStatus(string.format("Auto-retry %d | upgrade #%s", state.upgradeRetries, tostring(id)))
                task.wait(replayBackoff(state.upgradeRetries))
            end
        end

        if state.target and replaying then
            performTarget(state.tower, state.target)
        end

        return state.tower
    end

    for index, action in ipairs(macro.actions) do
        if not replaying or not session.alive then
            break
        end

        if not session.auto.waitForReplayWave(action, index, #macro.actions) then
            break
        end

        setReplayStatus(string.format("%d/%d | W%d | %s", index, #macro.actions, tonumber(action.wave) or 0, tostring(action.type)))

        if action.type == "place" then
            local state = runtime[action.id] or {
                level = tonumber(action.initialLevel) or 0,
                target = action.initialTarget,
                sold = false,
            }
            runtime[action.id] = state

            while replaying and session.alive do
                local tower, placeError = performPlace(action)
                if tower then
                    state.tower = tower
                    state.level = getLevel(tower)
                    if state.target and getTarget(tower) ~= state.target then
                        performTarget(tower, state.target)
                    end
                    notify("Replay", "Placed " .. action.unit .. " #" .. action.id, 2)
                    break
                end

                if isFatalReplayError(placeError) then
                    stopWithError(placeError, 6)
                    break
                end

                state.placeRetries = (state.placeRetries or 0) + 1
                setReplayStatus(string.format("Auto-retry %d | place %s #%s", state.placeRetries, action.unit, tostring(action.id)))
                task.wait(replayBackoff(state.placeRetries))
            end

        elseif action.type == "upgrade" then
            local tower, restoreError = restore(action.id)
            if not tower then
                stopWithError(restoreError, 6)
                break
            end

            while replaying and session.alive and getLevel(tower) < (tonumber(action.level) or getLevel(tower) + 1) do
                local ok = performUpgrade(tower, action.level)
                if ok and getLevel(tower) >= (tonumber(action.level) or getLevel(tower)) then
                    break
                end
                if not ok then
                    local state = runtime[action.id]
                    state.upgradeRetries = (state.upgradeRetries or 0) + 1
                    setReplayStatus(string.format("Auto-retry %d | upgrade #%s", state.upgradeRetries, tostring(action.id)))
                    task.wait(replayBackoff(state.upgradeRetries))
                end
            end

            if replaying then
                runtime[action.id].level = math.max(runtime[action.id].level or 0, tonumber(action.level) or getLevel(tower))
            end

        elseif action.type == "target" then
            local tower, restoreError = restore(action.id)
            if not tower then
                stopWithError(restoreError, 6)
                break
            end

            local targetRetries = 0
            while replaying and session.alive do
                local ok, targetError = performTarget(tower, action.mode)
                if ok then
                    runtime[action.id].target = action.mode
                    break
                end
                if isFatalReplayError(targetError) and targetError ~= "tower missing" then
                    stopWithError(targetError, 5)
                    break
                end
                if not tower.Parent then
                    tower, targetError = restore(action.id)
                    if not tower then
                        stopWithError(targetError, 5)
                        break
                    end
                end
                targetRetries = targetRetries + 1
                setReplayStatus(string.format("Auto-retry %d | target #%s -> %s", targetRetries, tostring(action.id), tostring(action.mode)))
                task.wait(replayBackoff(targetRetries))
            end

        elseif action.type == "ability" then
            local tower, restoreError = restore(action.id)
            if not tower then
                stopWithError(restoreError, 6)
                break
            end

            while replaying and session.alive do
                local ok, abilityError = performAbility(tower, action.ability)
                if ok then
                    break
                end

                if abilityError == "ability handler is missing" or abilityError == "tower missing" then
                    stopWithError(abilityError, 5)
                    break
                end

                local state = runtime[action.id]
                state.abilityRetries = (state.abilityRetries or 0) + 1
                setReplayStatus(string.format("Auto-retry %d | %s on #%s", state.abilityRetries, tostring(action.ability), tostring(action.id)))
                task.wait(replayBackoff(state.abilityRetries))
            end

        elseif action.type == "skip" then
            local ok, skipError = performSkip()
            if not ok then
                stopWithError(skipError, 5)
                break
            end
            notify("Replay", "Skipped wave " .. tostring(action.wave or getWave()), 2)

        elseif action.type == "sell" then
            local tower, restoreError = restore(action.id)
            if not tower then
                stopWithError(restoreError, 6)
                break
            end

            local ok, sellError = performSell(tower)
            if not ok then
                stopWithError(sellError, 5)
                break
            end

            runtime[action.id].sold = true
            runtime[action.id].tower = nil
        else
            stopWithError("unsupported action: " .. tostring(action.type), 5)
            break
        end

        if replaying then
            processed = index
        end
    end

    local finished = replaying and session.alive and not replayStopRequested and not replayError
    replaying = false
    replayTaskRunning = false

    if not session.alive then
        return
    end

    if finished then
        notify("Replay finished", "All actions completed", 4)
        setRecorderState("replay_finished")
        setReplayStatus(string.format("Finished | %d/%d", processed, #macro.actions))
    else
        setRecorderState("replay_stopped")
        if replayError then
            setReplayStatus("Stopped: " .. tostring(replayError))
        else
            setReplayStatus(string.format("Stopped | %d/%d", processed, #macro.actions))
        end
    end
end

local function startRecording()
    if recording then
        return
    end

    if replaying or replayTaskRunning then
        notify("Recorder error", "Wait for Replay to stop before starting Recorder", 4)
        return
    end

    local towers = getTowers()
    if not towers then
        notify("Recorder error", "workspace.Towers was not found", 5)
        return
    end

    local bound, bindError = bindGameSources()
    if not bound then
        notify("Recorder error", bindError, 5)
        return
    end
    ensurePlacementRecorder()

    actions = {}
    ids = {}
    baselineTowers = setmetatable({}, { __mode = "k" })
    nextId = 1
    macroMap = getMapName()
    macroDeck = session.getDeckSnapshot()
    placementAttempt = nil
    recentPlacement = nil
    table.clear(session.placementQueue)
    session.pendingTowerActions = setmetatable({}, { __mode = "k" })
    recordedSkipWaves = {}
    pendingSkipWave = nil
    pendingSkipAt = 0
    lastSkipConfirmationWave = nil
    lastSkipConfirmationAt = 0
    recording = true
    resetLogger(true)

    for tower, state in pairs(towerState) do
        if tower.Parent == towers then
            state.recordedLevel = getLevel(tower)
            state.target = getTarget(tower)
            state.cooldowns = {}
            state.sold = false
        end
    end

    -- Existing towers are only a baseline. Recording starts from this click;
    -- we do not retroactively serialize towers that were already on the map.
    for _, tower in ipairs(towers:GetChildren()) do
        if isMine(tower) then
            baselineTowers[tower] = true
            bindTower(tower)
        end
    end

    setRecorderState("recording")
    notify("Recording started", "Map: " .. macroMap .. " | Deck: " .. session.compactDeckText(macroDeck), 4)
end

local function stopRecording()
    if not recording then
        notify("Macro recorder", "Recording is not running", 3)
        return
    end

    setRecorderState("saving")

    -- One final authoritative pass before freezing the recorder. This repairs a
    -- TowerPlaced/Configuration replication race instead of silently saving a
    -- half-recorded macro.
    local towers = getTowers()
    if towers then
        for _, tower in ipairs(towers:GetChildren()) do
            if tower:IsA("Model") and isMine(tower) then
                bindTower(tower)
                if not baselineTowers[tower] and not ids[tower] then
                    onTowerPlaced(tower)
                end
            end
        end
    end

    local drainStarted = os.clock()
    while session.alive and os.clock() - drainStarted < 5.25 do
        local pending = false

        for tower in pairs(session.pendingTowerRecords) do
            if tower then
                pending = true
                break
            end
        end

        if not pending then
            for tower, queued in pairs(session.pendingTowerActions) do
                if queued and #queued > 0 and not ids[tower] and tower and tower.Parent == getTowers() then
                    pending = true
                    onTowerPlaced(tower)
                    break
                end
            end
        end

        if not pending then
            break
        end
        task.wait(0.04)
    end

    -- Flush everything whose Place was confirmed during the drain window.
    local unresolved = 0
    for tower, queued in pairs(session.pendingTowerActions) do
        if ids[tower] then
            flushTowerActions(tower)
        elseif queued and #queued > 0 then
            unresolved = unresolved + #queued
        end
    end

    recording = false
    placementAttempt = nil
    recentPlacement = nil
    table.clear(session.placementQueue)
    freezeLogger()

    if unresolved > 0 then
        notify(
            "Recorder warning",
            tostring(unresolved) .. " action(s) could not be attached to a confirmed Place and were not serialized",
            6
        )
    end

    if saveMacro() then
        setRecorderState("saved")
    else
        setRecorderState("save_failed")
    end
end

local function selfCheck()
    local config = findPlacementConfiguration()
    local towers = getTowers()
    local detects = getDetects()
    local units = ReplicatedStorage:FindFirstChild("Units")
    local module = ReplicatedStorage:FindFirstChild("Modules")
        and ReplicatedStorage.Modules:FindFirstChild("CTDModule")
    local safe = player:FindFirstChild("LocalSafeData")
    local cash = safe and safe:FindFirstChild("CashREADONLY")
    local gameVals = getGameVals()
    local nativeAutoSkip = getNativeAutoSkipSetting()
    local settingsRemote = getSettingsRemote()

    local checks = {
        { "PlayerGui.Configuration", config ~= nil },
        { "UnitChoosed", config and config:FindFirstChild("UnitChoosed") ~= nil },
        { "UnitOrientation", config and config:FindFirstChild("UnitOrientation") ~= nil },
        { "CommencingPlace", config and config:FindFirstChild("CommencingPlace") ~= nil },
        { "workspace.Towers", towers ~= nil },
        { "EverythingDetects", detects ~= nil },
        { "ReplicatedStorage.Units", units ~= nil },
        { "Remotes.PlaceUnit", remotes:FindFirstChild("PlaceUnit") ~= nil },
        { "Remotes.UpgradeUnit", remotes:FindFirstChild("UpgradeUnit") ~= nil },
        { "Remotes.TargetUnit", remotes:FindFirstChild("TargetUnit") ~= nil },
        { "Remotes.RemoveUnit", remotes:FindFirstChild("RemoveUnit") ~= nil },
        { "Modules.CTDModule", module ~= nil },
        { "CashREADONLY", cash ~= nil },
        { "GameVals.AbleToSkip", gameVals and gameVals:FindFirstChild("AbleToSkip") ~= nil },
        { "GameVals.WaveTimeSkipped", gameVals and gameVals:FindFirstChild("WaveTimeSkipped") ~= nil },
        { "PlayerData.Settings.AutoSkip", nativeAutoSkip ~= nil },
        { "Settings AutoSkip RemoteEvent", settingsRemote ~= nil },
    }

    local lines = { "Map: " .. getMapName(), "Wave: " .. tostring(getWave()) }
    local allGood = true
    for _, check in ipairs(checks) do
        local good = check[2] == true
        allGood = allGood and good
        lines[#lines + 1] = (good and "OK  " or "MISS ") .. check[1]
    end

    local text = table.concat(lines, "\n")
    debugLog(text)
    notify(allGood and "CTDIG self-check OK" or "CTDIG self-check FAILED", text, 8)
    return allGood
end

session.recorder = {
    bindGameSources = bindGameSources,
    ensurePlacementRecorder = ensurePlacementRecorder,
    handleEndAction = handleEndAction,
    onTowerPlaced = onTowerPlaced,
    replayMacro = replayMacro,
    selfCheck = selfCheck,
    startRecording = startRecording,
    stopRecording = stopRecording,
}
end

RecorderBox:AddButton({
    Text = "Record",
    Func = session.recorder.startRecording,
})

RecorderBox:AddButton({
    Text = "Stop & Save",
    Func = session.recorder.stopRecording,
})

RecorderBox:AddButton({
    Text = "Clear",
    Func = function()
        actions = {}
        ids = {}
        baselineTowers = setmetatable({}, { __mode = "k" })
        nextId = 1
        macroDeck = {}
        recording = false
        placementAttempt = nil
        recentPlacement = nil
        table.clear(session.placementQueue)
        recordedSkipWaves = {}
        pendingSkipWave = nil
        pendingSkipAt = 0
        lastSkipConfirmationWave = nil
        lastSkipConfirmationAt = 0
        resetLogger(false)
        if not replaying and not replayTaskRunning then
            setRecorderState("idle")
        end
        notify("Macro recorder", "Recording cleared", 2)
    end,
})

RecorderBox:AddButton({
    Text = "Self-check",
    Func = session.recorder.selfCheck,
})

ReplayBox:AddButton({
    Text = "Replay ctdig.lua",
    Func = function()
        task.spawn(function()
            local ok, err = xpcall(session.recorder.replayMacro, tracebackError)
            if not ok then
                replaying = false
                replayTaskRunning = false
                warn("[CTDIG] Replay runtime error:\n" .. tostring(err))
                if session.alive then
                    setRecorderState("replay_stopped")
                    setReplayStatus("Stopped: runtime error")
                    notify("Replay error", tostring(err), 6)
                end
            end
        end)
    end,
})

ReplayBox:AddButton({
    Text = "Stop Replay",
    Func = function()
        if replaying then
            replayStopRequested = true
            replaying = false
            setRecorderState("replay_stopped")
            setReplayStatus("Stopped by user")
            notify("Replay", "Stopped", 2)
        end
    end,
})

if Toggles.CTDIGAutoSkip then
    Toggles.CTDIGAutoSkip:OnChanged(function()
        if autoSkipChanging then
            return
        end

        autoSkipChanging = true
        task.spawn(function()
            if not session.alive then
                autoSkipChanging = false
                return
            end

            local wanted = Toggles.CTDIGAutoSkip.Value == true
            local ok, err = setNativeAutoSkip(wanted)
            if not session.alive then
                autoSkipChanging = false
                return
            end

            if ok then
                notify("Auto Skip", wanted and "Enabled" or "Disabled", 2)
            else
                notify("Auto Skip error", err, 5)
                local setting = getNativeAutoSkipSetting()
                if setting and Toggles.CTDIGAutoSkip.Value ~= setting.Value then
                    Toggles.CTDIGAutoSkip:SetValue(setting.Value)
                end
            end
            autoSkipChanging = false
        end)
    end)
end

local liveAutoSkip = getNativeAutoSkipSetting()
if liveAutoSkip then
    connect(liveAutoSkip.Changed, function(value)
        if Toggles.CTDIGAutoSkip and Toggles.CTDIGAutoSkip.Value ~= (value == true) then
            autoSkipChanging = true
            Toggles.CTDIGAutoSkip:SetValue(value == true)
            autoSkipChanging = false
        end
    end)
end

session.recorder.ensurePlacementRecorder()

connect(playerGui.DescendantAdded, function(descendant)
    if descendant.Name == "Configuration" or descendant.Name == "CommencingPlace" then
        if descendant.Name == "Configuration" and descendant ~= placementConfiguration then
            placementRecorderBound = false
        elseif descendant.Name == "CommencingPlace" and descendant.Parent ~= placementConfiguration then
            placementRecorderBound = false
        end
        task.defer(function()
            if session.alive then
                session.recorder.ensurePlacementRecorder()
            end
        end)
    end
end)

local function bindRangePreviewValue(value)
    if not value or not value:IsA("ValueBase") or rangePreviewBoundValues[value] then
        return
    end

    rangePreviewBoundValues[value] = true
    connect(value.Changed, function()
        task.defer(function()
            if session.alive then
                session.visuals.refreshRangePreview()
            end
        end)
    end)
end

local function ensureRangePreviewBindings()
    local config = findPlacementConfiguration()
    if not config then
        return false
    end

    for _, name in ipairs({ "UnitChoosed", "UnitEditor", "CurrentUnitPlacingObject" }) do
        bindRangePreviewValue(config:FindFirstChild(name))
    end

    session.visuals.refreshRangePreview()
    return true
end

local function startRangePreviewBinding()
    if rangePreviewBindingStarted then
        return
    end
    rangePreviewBindingStarted = true

    ensureRangePreviewBindings()

    -- Configuration may be created after the hub. Rebind when the game's
    -- placement values appear instead of giving up forever after one miss.
    connect(playerGui.DescendantAdded, function(descendant)
        if descendant.Name == "Configuration"
            or descendant.Name == "UnitChoosed"
            or descendant.Name == "UnitEditor"
            or descendant.Name == "CurrentUnitPlacingObject"
        then
            task.defer(function()
                if session.alive then
                    ensureRangePreviewBindings()
                end
            end)
        end
    end)
end

startRangePreviewBinding()

if Toggles.CTDIGAutoRetry then
    Toggles.CTDIGAutoRetry:OnChanged(function()
        if endActionChanging then
            return
        end
        endActionChanging = true
        if Toggles.CTDIGAutoRetry.Value and Toggles.CTDIGAutoBackLobby and Toggles.CTDIGAutoBackLobby.Value then
            Toggles.CTDIGAutoBackLobby:SetValue(false)
        end
        session.endAction.key = nil
        session.endAction.confirmed = false
        session.endAction.attempts = 0
        session.endAction.nextAttempt = 0
        setEndActionStatus(Toggles.CTDIGAutoRetry.Value and "End action: AUTO RETRY" or "End action: OFF")
        endActionChanging = false
    end)
end

if Toggles.CTDIGAutoBackLobby then
    Toggles.CTDIGAutoBackLobby:OnChanged(function()
        if endActionChanging then
            return
        end
        endActionChanging = true
        if Toggles.CTDIGAutoBackLobby.Value and Toggles.CTDIGAutoRetry and Toggles.CTDIGAutoRetry.Value then
            Toggles.CTDIGAutoRetry:SetValue(false)
        end
        session.endAction.key = nil
        session.endAction.confirmed = false
        session.endAction.attempts = 0
        session.endAction.nextAttempt = 0
        setEndActionStatus(Toggles.CTDIGAutoBackLobby.Value and "End action: AUTO LOBBY" or "End action: OFF")
        endActionChanging = false
    end)
end

if Toggles.CTDIGRangePreview then
    Toggles.CTDIGRangePreview:OnChanged(function()
        ensureRangePreviewBindings()
        session.visuals.refreshRangePreview()
    end)
end

if Toggles.CTDIGStacker then
    Toggles.CTDIGStacker:OnChanged(function()
        if stackerToggleChanging then
            return
        end

        local wanted = Toggles.CTDIGStacker.Value == true
        if wanted then
            local ok, err = enableStackerPatch()
            if ok then
                stackerDebug("enabled | native ray ignores Towers | IgnorePlacementBox=true")
                notify("Stacker", "Enabled: native placement, tower overlap ignored", 4)
            else
                stackerDebug("enable failed = " .. tostring(err))
                notify("Stacker error", err, 6)
                stackerToggleChanging = true
                Toggles.CTDIGStacker:SetValue(false)
                stackerToggleChanging = false
            end
        else
            local ok, err = restoreStackerPatch()
            stackerDebug(ok and "disabled | original restored" or "disable warning = " .. tostring(err))
            notify("Stacker", ok and "Disabled: original placement restored" or tostring(err), ok and 3 or 6)
        end
    end)
end

if Toggles.CTDIGTowerDPS then
    Toggles.CTDIGTowerDPS:OnChanged(function()
        if not Toggles.CTDIGTowerDPS.Value then
            session.visuals.clearDpsGuis()
        end
    end)
end

if Toggles.CTDIGKillPreview then
    Toggles.CTDIGKillPreview:OnChanged(function()
        if not Toggles.CTDIGKillPreview.Value then
            session.visuals.clearKillHighlights()
        end
    end)
end

local function cleanup()
    if not session.alive then
        return
    end

    session.alive = false
    recording = false
    replaying = false
    replayTaskRunning = false
    replayStopRequested = true

    restoreStackerPatch()

    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(connections)

    local boundTowers = {}
    for tower in pairs(towerConnections) do
        boundTowers[#boundTowers + 1] = tower
    end
    for _, tower in ipairs(boundTowers) do
        disconnectTower(tower)
    end

    session.visuals.destroyRangePreview()
    session.visuals.clearDpsGuis()
    session.visuals.clearKillHighlights()

    if Library and type(Library.Unload) == "function" then
        pcall(function()
            Library:Unload()
        end)
    end

    if environment.CTDIG_SESSION == session then
        environment.CTDIG_SESSION = nil
    end
    if environment.CTDIG_STACKER == stackerState then
        environment.CTDIG_STACKER = nil
    end
end

session.cleanup = cleanup

local function updateDpsVisuals()
    if not (Toggles.CTDIGTowerDPS and Toggles.CTDIGTowerDPS.Value) then
        clearDpsGuis()
        setCombatDiagDps("DPS OFF")
        return
    end

    local towersFolder = getTowers()
    local alive = {}
    local now = os.clock()
    local scanned = 0
    local guiCount = 0
    local statCount = 0
    local liveCount = 0

    if towersFolder then
        for _, tower in ipairs(towersFolder:GetChildren()) do
            if getRoot(tower) then
                scanned = scanned + 1
                alive[tower] = true

                local guiOk, data = pcall(session.visuals.ensureDpsGui, tower)
                if guiOk and data then
                    guiCount = guiCount + 1

                    local statsOk, stats = pcall(session.visuals.towerCombatStats, tower)
                    local liveOk, live = pcall(session.visuals.sampleTowerLiveDPS, tower, now)
                    local textValue

                    if statsOk and stats then
                        statCount = statCount + 1
                        local displayDps = stats.dps
                        local suffix = "CALC"

                        if liveOk and live and live > 0.01 then
                            liveCount = liveCount + 1
                            displayDps = live
                            suffix = "LIVE"
                        end

                        textValue = string.format(
                            "LVL %d  •  DPS %s %s\\n%s DMG / %ss",
                            getLevel(tower),
                            session.visuals.formatCompactNumber(displayDps),
                            suffix,
                            session.visuals.formatCompactNumber(stats.damage),
                            session.visuals.formatCompactNumber(stats.interval)
                        )
                    else
                        local config = tower:FindFirstChild("Configuration")
                        local damage = readNumberValue(config, "Damage")
                        local reload = readNumberValue(config, "ReloadTime")
                        local total = readNumberValue(tower, "TotalDMG")

                        if liveOk and live and live > 0.01 then
                            liveCount = liveCount + 1
                            textValue = string.format(
                                "LVL %d  •  DPS %s LIVE\\nDMG %s | RATE %s",
                                getLevel(tower),
                                session.visuals.formatCompactNumber(live),
                                damage ~= nil and session.visuals.formatCompactNumber(damage) or "?",
                                reload ~= nil and session.visuals.formatCompactNumber(reload) or "?"
                            )
                        else
                            textValue = string.format(
                                "LVL %d  •  DPS —\\nDMG %s | RATE %s | Total %s",
                                getLevel(tower),
                                damage ~= nil and session.visuals.formatCompactNumber(damage) or "missing",
                                reload ~= nil and session.visuals.formatCompactNumber(reload) or "missing",
                                total ~= nil and session.visuals.formatCompactNumber(total) or "missing"
                            )
                        end
                    end

                    if data.lastText ~= textValue then
                        data.lastText = textValue
                        data.label.Text = textValue
                    end
                end
            end
        end
    end

    for tower, data in pairs(dpsGuis) do
        if not alive[tower] or not tower.Parent then
            if data.gui then
                pcall(function()
                    data.gui:Destroy()
                end)
            end
            dpsGuis[tower] = nil
            dpsSamples[tower] = nil
        end
    end

    setCombatDiagDps(string.format(
        "DPS towers=%d gui=%d stats=%d live=%d",
        scanned,
        guiCount,
        statCount,
        liveCount
    ))
end

task.spawn(function()
    while session.alive do
        local dpsOk, dpsError = xpcall(updateDpsVisuals, tracebackError)
        if not dpsOk then
            setCombatDiagDps("DPS ERROR: " .. tostring(dpsError))
            if os.clock() - lastDpsVisualErrorAt >= 5 then
                lastDpsVisualErrorAt = os.clock()
                warn("[CTDIG DPS] " .. tostring(dpsError))
            end
        end

        local killOk, killError = xpcall(session.visuals.updateKillPreview, tracebackError)
        if not killOk then
            setCombatDiagPredict("Predict ERROR: " .. tostring(killError))
            session.visuals.setKillInfo("Kill Preview error; see Combat diagnostics")
            if os.clock() - lastKillVisualErrorAt >= 5 then
                lastKillVisualErrorAt = os.clock()
                warn("[CTDIG Kill Preview] " .. tostring(killError))
            end
        end

        pcall(session.recorder.handleEndAction)

        local now = os.clock()

        -- Low-frequency recovery pass while recording. The normal event
        -- observers are still the primary path; this only repairs missed
        -- ChildAdded/ownership/config replication races without scanning every
        -- frame. A confirmed tower in workspace.Towers is authoritative.
        if recording and now - lastRecorderRecoveryScan >= 0.7 then
            lastRecorderRecoveryScan = now
            pcall(function()
                session.recorder.bindGameSources()
                session.recorder.ensurePlacementRecorder()

                local towers = getTowers()
                if towers then
                    for _, tower in ipairs(towers:GetChildren()) do
                        if tower:IsA("Model") and isMine(tower) then
                            bindTower(tower)
                            if not baselineTowers[tower] and not ids[tower] then
                                session.recorder.onTowerPlaced(tower)
                            elseif ids[tower] and session.pendingTowerActions[tower] then
                                flushTowerActions(tower)
                            end
                        end
                    end
                end
            end)
        end

        if now - lastRangePreviewRefresh >= 0.45 then
            lastRangePreviewRefresh = now
            pcall(session.visuals.refreshRangePreview)
        end

        task.wait(0.2)
    end
end)

function session.auto.runRecordedMacro()
    if not CTDIG_BUILD_AUTORUN or not session.alive then
        return
    end

    local macro, macroError = loadMacro()
    if not macro then
        setReplayStatus("AutoExecute error: " .. tostring(macroError))
        notify("AutoExecute error", macroError, 6)
        return
    end

    local started = os.clock()
    while session.alive and os.clock() - started < 30 do
        local lobbyContext = Workspace:FindFirstChild("Elevators") ~= nil
            and Workspace:FindFirstChild("Towers") == nil
        local map = Workspace:FindFirstChild("Map")
        local matchContext = Workspace:FindFirstChild("Towers") ~= nil
            and map ~= nil
            and map:FindFirstChild("Configuration") ~= nil

        if lobbyContext then
            setRecorderState("idle")
            setReplayStatus("Lobby | checking deck")
            local deckOk, deckError = session.auto.ensureMacroDeckInLobby(macro)
            if not deckOk then
                setReplayStatus("Lobby deck error: " .. tostring(deckError))
                notify("AutoExecute deck error", deckError, 8)
                return
            end

            setReplayStatus("Lobby | deck OK | finding elevator")
            local roomOk, roomError = session.auto.openMacroMapFromLobby(macro)
            if not roomOk then
                setReplayStatus("Lobby error: " .. tostring(roomError))
                notify("AutoExecute lobby error", roomError, 8)
            end
            return
        elseif matchContext then
            setReplayStatus("Match detected | waiting map data")
            local mapStarted = os.clock()
            while session.alive and os.clock() - mapStarted < 20 do
                if getMapName() ~= "Unknown" and player:FindFirstChild("PlayerData") then
                    break
                end
                task.wait(0.1)
            end

            if not session.sourceBound then
                session.sourceBound, session.sourceError = session.recorder.bindGameSources()
            end
            if not session.sourceBound then
                setReplayStatus("Match bind error: " .. tostring(session.sourceError))
                notify("AutoExecute error", session.sourceError or "match sources unavailable", 7)
                return
            end

            task.wait(0.25)
            local ok, replayError = xpcall(session.recorder.replayMacro, tracebackError)
            if not ok and session.alive then
                replaying = false
                replayTaskRunning = false
                setRecorderState("replay_stopped")
                setReplayStatus("AutoExecute runtime error")
                notify("AutoExecute replay error", tostring(replayError), 8)
            end
            return
        end

        setReplayStatus("AutoExecute | waiting for lobby/match")
        task.wait(0.25)
    end

    if session.alive then
        setReplayStatus("AutoExecute timeout: lobby/match not detected")
    end
end

local lobbyContextAtStartup = Workspace:FindFirstChild("Elevators") ~= nil
    and Workspace:FindFirstChild("Towers") == nil

if lobbyContextAtStartup then
    session.sourceBound = false
    session.sourceError = nil
    setRecorderState("idle")
    setReplayStatus(CTDIG_BUILD_AUTORUN and "AutoExecute lobby starting" or "Lobby detected")
else
    session.sourceBound, session.sourceError = session.recorder.bindGameSources()
    if session.sourceBound then
        setRecorderState("idle")
        setReplayStatus("idle")
    else
        setRecorderState("error")
        debugLog(session.sourceError)
        notify("CTDIG error", session.sourceError, 6)
    end
end

if CTDIG_BUILD_AUTORUN then
    task.spawn(session.auto.runRecordedMacro)
end
