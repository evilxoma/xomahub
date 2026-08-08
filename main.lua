--// XomaHub / CTD Macro
--// One-file hub + recorder + strategy runtime.
--// Strategies are saved locally as ctdcool.lua via writefile/readfile.
--// Strategy playback is sequential: no automatic action timestamps.

local GENV = type(getgenv) == "function" and getgenv() or _G
if type(GENV.XomaHub) == "table" then
    return GENV.XomaHub
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local CTD2Module = require(Modules:WaitForChild("CTD2Module"))
pcall(function()
    if CTD2Module.waitforload then CTD2Module.waitforload() end
end)

local MAIN_URL = "https://raw.githubusercontent.com/evilxoma/xomahub/main/main.lua"
local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"
local MACRO_FILE = "ctdcool.lua"
local CONFIG_FILE = "ctd_macro_config.json"

local HAS_READFILE = type(readfile) == "function"
local HAS_WRITEFILE = type(writefile) == "function"
local HAS_ISFILE = type(isfile) == "function"
local HAS_HOOK = type(hookmetamethod) == "function"
    and type(getnamecallmethod) == "function"
    and type(newcclosure) == "function"
local HAS_CHECKCALLER = type(checkcaller) == "function"

local WindUI = loadstring(game:HttpGet(WINDUI_URL))()

local State = {
    Recording = false,
    PlaceTiming = 0.15,
    Actions = {},
    NextActionSeq = 0,
    NextUnitId = 0,
    TowerToId = setmetatable({}, { __mode = "k" }),
    Units = {},
    MacroMeta = nil,
    Logs = {},
    LogSessionActive = false,
    InternalCall = false,

    RecordPlacement = true,
    RecordUpgrade = true,
    RecordSell = true,
    RecordTarget = true,
    RecordMove = true,

    AutoSummon = false,
    SummonLoopId = 0,
    SummonBanner = "Basic Summon",
    SummonPullCode = "10Summon",
    SummonDelay = 0.50,

    Webhook = "",
    WebhookEnabled = false,
    LegendaryNotify = true,
    MythicNotify = true,
}

local Runtime = {
    Running = false,
    Units = {},
    Strategy = nil,
    Logs = {},
    DeathWatcherToken = 0,
    MatchEnded = false,
    ResultConnection = nil,
}

local function readConfig()
    if not (HAS_READFILE and HAS_ISFILE and isfile(CONFIG_FILE)) then return end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)
    if not ok or type(decoded) ~= "table" then return end

    if type(decoded.PlaceTiming) == "number" then State.PlaceTiming = decoded.PlaceTiming end
    if type(decoded.SummonBanner) == "string" then State.SummonBanner = decoded.SummonBanner end
    if type(decoded.SummonPullCode) == "string" then State.SummonPullCode = decoded.SummonPullCode end
    if type(decoded.SummonDelay) == "number" then State.SummonDelay = decoded.SummonDelay end
    if type(decoded.Webhook) == "string" then State.Webhook = decoded.Webhook end
    if type(decoded.WebhookEnabled) == "boolean" then State.WebhookEnabled = decoded.WebhookEnabled end
    if type(decoded.LegendaryNotify) == "boolean" then State.LegendaryNotify = decoded.LegendaryNotify end
    if type(decoded.MythicNotify) == "boolean" then State.MythicNotify = decoded.MythicNotify end
end

local function saveConfig()
    if not HAS_WRITEFILE then return end
    local payload = HttpService:JSONEncode({
        PlaceTiming = State.PlaceTiming,
        SummonBanner = State.SummonBanner,
        SummonPullCode = State.SummonPullCode,
        SummonDelay = State.SummonDelay,
        Webhook = State.Webhook,
        WebhookEnabled = State.WebhookEnabled,
        LegendaryNotify = State.LegendaryNotify,
        MythicNotify = State.MythicNotify,
    })
    pcall(writefile, CONFIG_FILE, payload)
end

readConfig()

local Window = WindUI:CreateWindow({
    Title = "CTD Macro",
    Author = "xomahub",
    Icon = "bot",
    Theme = "Dark",
    Size = UDim2.fromOffset(690, 500),
    MinSize = Vector2.new(580, 370),
    ToggleKey = Enum.KeyCode.RightShift,
    Resizable = true,
    AutoScale = true,
    NewElements = true,
    HideSearchBar = true,
    Topbar = { Height = 44, ButtonsType = "Mac" },
})

local MacroTab = Window:Tab({ Title = "Macro", Icon = "clapperboard" })
local LoggerTab = Window:Tab({ Title = "Logger", Icon = "terminal" })
local SummonTab = Window:Tab({ Title = "Auto Summon", Icon = "sparkles" })
local WebhookTab = Window:Tab({ Title = "Webhook", Icon = "webhook" })

local StatusParagraph = MacroTab:Paragraph({
    Title = "Recorder Status",
    Desc = "IDLE",
    Image = "circle",
    ImageSize = 16,
})

local MapParagraph = MacroTab:Paragraph({
    Title = "Recorded Map",
    Desc = "Waiting for recorder...",
    Image = "map",
    ImageSize = 16,
})

LoggerTab:Paragraph({
    Title = "Macro Logger",
    Desc = "Recorder and replay actions are shown below.",
    Image = "terminal",
    ImageSize = 18,
})
LoggerTab:Divider()

local LoggerOutput = LoggerTab:Paragraph({
    Title = "Live Output",
    Desc = "No logs yet.",
    Image = "list",
    ImageSize = 15,
})

local function refreshLogger()
    if #State.Logs == 0 then
        pcall(function() LoggerOutput:SetDesc("No logs yet.") end)
        return
    end
    local lines = {}
    local first = math.max(1, #State.Logs - 15)
    for i = first, #State.Logs do
        lines[#lines + 1] = State.Logs[i]
    end
    pcall(function() LoggerOutput:SetDesc(table.concat(lines, "\n")) end)
end

local function AddLog(text, force)
    text = tostring(text)
    print("[XOMAHUB]", text)
    if not force and not State.LogSessionActive then
        return
    end
    State.Logs[#State.Logs + 1] = text
    if #State.Logs > 250 then table.remove(State.Logs, 1) end
    refreshLogger()
end

local function BeginLogSession(title)
    State.Logs = {}
    State.LogSessionActive = true
    refreshLogger()
    if title and title ~= "" then
        AddLog(title)
    end
end

local function EndLogSession()
    State.LogSessionActive = false
end

local function SetStatus(text)
    pcall(function() StatusParagraph:SetDesc(tostring(text)) end)
end

LoggerTab:Button({
    Title = "Clear Logger",
    Icon = "trash-2",
    Callback = function()
        State.Logs = {}
        refreshLogger()
    end,
})

local function valueOf(parent, name, fallback)
    if not parent then return fallback end
    local obj = parent:FindFirstChild(name)
    if not obj then return fallback end
    local ok, value = pcall(function() return obj.Value end)
    return ok and value or fallback
end

local function captureMapMeta()
    local map = Workspace:FindFirstChild("Map")
    local gameVals = Workspace:FindFirstChild("GameVals")
    local mapInfo = gameVals and gameVals:FindFirstChild("MapInformation")
    return {
        MapName = tostring(valueOf(map, "TrueName", map and map.Name or "None") or "None"),
        MapDifficultyMode = tostring(valueOf(Workspace, "Difficulty", "Normal") or "Normal"),
        Campaign = tostring(valueOf(mapInfo, "CurrentCampaign", "None") or "None"),
        Gamemode = tostring(valueOf(mapInfo, "CurrentGamemode", "Standard") or "Standard"),
        Conquest_MapRoute = tostring(valueOf(mapInfo, "Conquest_CurrentRoute", "No Route") or "No Route"),
        Conquest_LegendModeGearChoice = tostring(valueOf(mapInfo, "Conquest_LegendModeGearChoice", "None") or "None"),
    }
end

local function pathOf(inst)
    if typeof(inst) ~= "Instance" then return nil end
    local parts = {}
    local cursor = inst
    while cursor and cursor ~= game do
        table.insert(parts, 1, cursor.Name)
        cursor = cursor.Parent
    end
    return cursor == game and parts or nil
end

local function resolvePath(parts)
    if type(parts) ~= "table" then return nil end
    local cursor = game
    for _, name in ipairs(parts) do
        cursor = cursor and cursor:FindFirstChild(name)
        if not cursor then return nil end
    end
    return cursor
end

local function towerRoot(tower)
    if typeof(tower) ~= "Instance" or not tower.Parent then return nil end
    if tower:IsA("BasePart") then return tower end
    return tower:FindFirstChild("HumanoidRootPart")
        or tower.PrimaryPart
        or tower:FindFirstChildWhichIsA("BasePart", true)
end

local function towerPosition(tower)
    local root = towerRoot(tower)
    if root then return root.Position end
    if typeof(tower) == "Instance" and tower:IsA("Model") then
        return tower:GetPivot().Position
    end
    return nil
end

local function isOwnedTower(tower)
    if typeof(tower) ~= "Instance" then return false end
    local config = tower:FindFirstChild("Configuration")
    local owner = config and config:FindFirstChild("Owner")
    if not owner then return false end
    local ok, value = pcall(function() return owner.Value end)
    return ok and (value == LocalPlayer.Name or value == LocalPlayer)
end

local function readTowerLevel(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local level = config and config:FindFirstChild("Level")
    if not level then return nil end
    local ok, value = pcall(function() return tonumber(level.Value) end)
    return ok and value or nil
end

local function readTargetMode(tower)
    local dumps = tower and tower:FindFirstChild("Dumps")
    local target = dumps and dumps:FindFirstChild("TowerTargeting")
    if not target then return nil end
    local ok, value = pcall(function() return target.Value end)
    return ok and value or nil
end

local function targetPartFromTower(tower)
    local config = tower and tower:FindFirstChild("Configuration")
    local targetPart = config and config:FindFirstChild("TargetPart")
    if targetPart and targetPart:IsA("ObjectValue") then return targetPart.Value end
    return nil
end

local function nextUnitId()
    State.NextUnitId = State.NextUnitId + 1
    return string.format("U%03d", State.NextUnitId)
end

local function reserveActionSeq()
    State.NextActionSeq = State.NextActionSeq + 1
    return State.NextActionSeq
end

local function recordActionWithSeq(seq, action, logText)
    if not State.Recording then return end
    action.Seq = tonumber(seq) or reserveActionSeq()
    State.Actions[#State.Actions + 1] = action
    AddLog(logText)
end

local function recordAction(action, logText)
    recordActionWithSeq(reserveActionSeq(), action, logText)
end

local function findPendingIdForTower(tower)
    local pos = towerPosition(tower)
    if not pos then return nil end
    local bestId, bestDistance
    for id, info in pairs(State.Units) do
        local live = info.Instance
        if (not live or not live.Parent) and info.Name == tower.Name and info.Pos then
            local p = Vector3.new(info.Pos[1], info.Pos[2], info.Pos[3])
            local distance = (p - pos).Magnitude
            if distance <= 12 and (not bestDistance or distance < bestDistance) then
                bestId, bestDistance = id, distance
            end
        end
    end
    return bestId
end

local function assignTowerId(tower, forcedId)
    if typeof(tower) ~= "Instance" then return forcedId end
    if State.TowerToId[tower] then return State.TowerToId[tower] end

    local id = forcedId or findPendingIdForTower(tower) or nextUnitId()
    State.TowerToId[tower] = id
    local info = State.Units[id] or {}
    local pos = towerPosition(tower)
    info.Name = info.Name or tower.Name
    info.Instance = tower
    if pos then info.Pos = { pos.X, pos.Y, pos.Z } end
    info.Level = readTowerLevel(tower) or info.Level
    info.TargetMode = readTargetMode(tower) or info.TargetMode
    State.Units[id] = info
    return id
end

local function waitForTowerNear(name, pos, timeout)
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return nil end
    local deadline = os.clock() + (timeout or 2)
    repeat
        local best, bestDistance
        for _, tower in ipairs(towers:GetChildren()) do
            if tower.Name == name and isOwnedTower(tower) then
                local p = towerPosition(tower)
                if p then
                    local distance = (p - pos).Magnitude
                    if distance <= 14 and (not bestDistance or distance < bestDistance) then
                        best, bestDistance = tower, distance
                    end
                end
            end
        end
        if best then return best end
        task.wait(0.03)
    until os.clock() >= deadline
    return nil
end

local function adoptExistingTowers()
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return end
    for _, tower in ipairs(towers:GetChildren()) do
        if isOwnedTower(tower) then
            local pos = towerPosition(tower)
            if pos then
                local id = assignTowerId(tower)
                local tp = targetPartFromTower(tower)
                State.Units[id].TargetPath = pathOf(tp)
                State.Units[id].Pos = { pos.X, pos.Y, pos.Z }
                State.Units[id].RecordedPlace = true
                recordAction({
                    Type = "Place",
                    Id = id,
                    Name = tower.Name,
                    Pos = { pos.X, pos.Y, pos.Z },
                    TargetPath = pathOf(tp),
                }, string.format("PLACE %s -> %s @ %.2f, %.2f, %.2f [existing]", id, tower.Name, pos.X, pos.Y, pos.Z))

                local level = readTowerLevel(tower)
                if level and level > 0 then
                    recordAction({ Type = "Upgrade", Id = id, Level = level, InitialState = true }, "LEVEL " .. id .. " -> " .. level)
                end

                local mode = readTargetMode(tower)
                if mode ~= nil then
                    recordAction({ Type = "Target", Id = id, Mode = mode, InitialState = true }, "TARGET " .. id .. " -> " .. tostring(mode))
                end
            end
        end
    end
end

local function capturePlace(args, seq)
    if not State.RecordPlacement then return end
    local name = args[1]
    local info = args[2]
    if type(name) ~= "string" or type(info) ~= "table" or typeof(info.Pos) ~= "Vector3" then return end

    local pos = info.Pos
    local id = nextUnitId()
    State.Units[id] = {
        Name = name,
        Pos = { pos.X, pos.Y, pos.Z },
        TargetPath = pathOf(info.TargetPart),
        Sold = false,
        RecordedPlace = true,
    }
    recordActionWithSeq(seq, {
        Type = "Place",
        Id = id,
        Name = name,
        Pos = { pos.X, pos.Y, pos.Z },
        TargetPath = pathOf(info.TargetPart),
    }, string.format("PLACE %s -> %s @ %.2f, %.2f, %.2f", id, name, pos.X, pos.Y, pos.Z))

    task.spawn(function()
        local tower = waitForTowerNear(name, pos, 2.5)
        if tower then
            assignTowerId(tower, id)
        else
            AddLog("WARN: tower instance not linked for " .. id)
        end
    end)
end

local function idForActionTower(tower)
    if State.TowerToId[tower] then return State.TowerToId[tower] end
    if not isOwnedTower(tower) then return nil end
    local id = assignTowerId(tower)
    local pos = towerPosition(tower)
    if pos and State.Recording and not State.Units[id].RecordedPlace then
        local tp = targetPartFromTower(tower)
        State.Units[id].TargetPath = pathOf(tp)
        State.Units[id].Pos = { pos.X, pos.Y, pos.Z }
        State.Units[id].RecordedPlace = true
        recordAction({
            Type = "Place",
            Id = id,
            Name = tower.Name,
            Pos = { pos.X, pos.Y, pos.Z },
            TargetPath = pathOf(tp),
        }, string.format("PLACE %s -> %s @ %.2f, %.2f, %.2f [existing]", id, tower.Name, pos.X, pos.Y, pos.Z))
    end
    return id
end

local PlaceUnit = Remotes:WaitForChild("PlaceUnit")
local UpgradeRemote = Remotes:WaitForChild("UpgradeUnitRemoteFunc")
local RemoveUnit = Remotes:WaitForChild("RemoveUnit")
local TargetUnit = Remotes:WaitForChild("TargetUnit")
local SkillRemote = Remotes:WaitForChild("CTDModuleActivateSkillServer")

if HAS_HOOK then
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = table.pack(...)
        local fromHub = State.InternalCall or (HAS_CHECKCALLER and checkcaller())
        local shouldRecord = State.Recording and not fromHub

        if shouldRecord and self == PlaceUnit and method == "InvokeServer" then
            local seq = reserveActionSeq()
            local result = table.pack(oldNamecall(self, ...))
            task.defer(function() capturePlace(args, seq) end)
            return table.unpack(result, 1, result.n)
        end

        if shouldRecord and self == UpgradeRemote and method == "InvokeServer" and State.RecordUpgrade then
            local tower = args[1]
            local id, before, seq
            pcall(function()
                id = idForActionTower(tower)
                before = readTowerLevel(tower)
                seq = reserveActionSeq()
            end)

            -- Let the game's own upgrade call run even if recorder-side inspection fails.
            local result = table.pack(oldNamecall(self, ...))

            if id and result[1] ~= false then
                task.defer(function()
                    local deadline = os.clock() + 2.5
                    local now = readTowerLevel(tower)
                    while now == before and os.clock() < deadline do
                        task.wait(0.04)
                        now = readTowerLevel(tower)
                    end
                    if now ~= nil and (before == nil or now ~= before) and State.Units[id] then
                        State.Units[id].Level = now
                        recordActionWithSeq(seq, { Type = "Upgrade", Id = id, Level = now }, "UPGRADE " .. id .. " -> " .. tostring(now))
                    end
                end)
            end
            return table.unpack(result, 1, result.n)
        end

        if shouldRecord and self == RemoveUnit and method == "FireServer" and State.RecordSell then
            local tower = args[1]
            local id = idForActionTower(tower)
            local seq = reserveActionSeq()
            local result = table.pack(oldNamecall(self, ...))
            if id then
                State.Units[id].Sold = true
                recordActionWithSeq(seq, { Type = "Sell", Id = id }, "SELL " .. id)
            end
            return table.unpack(result, 1, result.n)
        end

        if shouldRecord and self == TargetUnit and method == "InvokeServer" and State.RecordTarget then
            local tower = args[1]
            local id = idForActionTower(tower)
            local before = readTargetMode(tower)
            local seq = reserveActionSeq()
            local result = table.pack(oldNamecall(self, ...))
            task.spawn(function()
                local deadline = os.clock() + 1.3
                local now = readTargetMode(tower)
                while now == before and os.clock() < deadline do
                    task.wait(0.04)
                    now = readTargetMode(tower)
                end
                if id and now ~= nil then
                    State.Units[id].TargetMode = now
                    recordActionWithSeq(seq, { Type = "Target", Id = id, Mode = now }, "TARGET " .. id .. " -> " .. tostring(now))
                end
            end)
            return table.unpack(result, 1, result.n)
        end

        if shouldRecord and self == SkillRemote and method == "FireServer" and State.RecordMove then
            local tower = args[1]
            local command = args[2]
            local info = args[3]
            if command == "ActivateSkill" and type(info) == "table" and info.SkillName == "Reposition" and type(info.successinfo) == "table" then
                local success = info.successinfo
                local cf = success.TargetCF
                local mousePos = success.MousePos
                if typeof(cf) == "CFrame" and typeof(mousePos) == "Vector3" then
                    local id = idForActionTower(tower)
                    local seq = reserveActionSeq()
                    local targetPath = pathOf(success.MouseTargetPart)
                    local result = table.pack(oldNamecall(self, ...))
                    if id then
                        State.Units[id].Pos = { cf.Position.X, cf.Position.Y, cf.Position.Z }
                        State.Units[id].TargetPath = targetPath
                        recordActionWithSeq(seq, {
                            Type = "Move",
                            Id = id,
                            SkillName = info.SkillName or "Reposition",
                            TargetCF = { cf:GetComponents() },
                            MousePos = { mousePos.X, mousePos.Y, mousePos.Z },
                            TargetPath = targetPath,
                        }, string.format("MOVE %s -> %.2f, %.2f, %.2f", id, cf.Position.X, cf.Position.Y, cf.Position.Z))
                    end
                    return table.unpack(result, 1, result.n)
                end
            end
        end

        return oldNamecall(self, ...)
    end))
else
    AddLog("WARNING: recorder hook unavailable in this executor")
end

local function quoteString(value)
    return string.format("%q", tostring(value))
end

local function toLua(value)
    local kind = typeof(value)
    if kind == "nil" then return "nil" end
    if kind == "string" then return quoteString(value) end
    if kind == "number" then
        if value ~= value then return "0/0" end
        if value == math.huge then return "math.huge" end
        if value == -math.huge then return "-math.huge" end
        return string.format("%.17g", value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    if kind ~= "table" then return "nil" end

    local maxIndex, count, array = 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            array = false
            break
        end
        if key > maxIndex then maxIndex = key end
    end
    if array and maxIndex ~= count then array = false end

    local out = { "{" }
    if array then
        for i = 1, maxIndex do out[#out + 1] = toLua(value[i]) .. "," end
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
            local lhs
            if type(key) == "string" and key:match("^[%a_][%w_]*$") then
                lhs = key
            else
                lhs = "[" .. toLua(key) .. "]"
            end
            out[#out + 1] = lhs .. "=" .. toLua(value[key]) .. ","
        end
    end
    out[#out + 1] = "}"
    return table.concat(out)
end

local function orderedActions(actions)
    local list = {}
    for index, action in ipairs(actions or {}) do
        list[#list + 1] = { Action = action, Index = index }
    end
    table.sort(list, function(a, b)
        local sa = tonumber(a.Action.Seq) or a.Index
        local sb = tonumber(b.Action.Seq) or b.Index
        if sa == sb then return a.Index < b.Index end
        return sa < sb
    end)
    return list
end

local function exportActions()
    local out = {}
    for _, item in ipairs(orderedActions(State.Actions)) do
        local copy = {}
        for key, value in pairs(item.Action) do
            if key ~= "Seq" then copy[key] = value end
        end
        out[#out + 1] = copy
    end
    return out
end

local function buildMacroSource()
    local strategy = {
        Meta = State.MacroMeta or captureMapMeta(),
        PlaceTiming = State.PlaceTiming,
        Actions = exportActions(),
    }
    return table.concat({
        "--// ctdcool.lua",
        "--// Generated by XomaHub. Put this file in autoexec.",
        "--// Actions run in recorded order. No automatic action timestamps are stored.",
        "",
        "local GENV = type(getgenv) == \"function\" and getgenv() or _G",
        "local CTD2 = GENV.XomaHub",
        "if not CTD2 then",
        "    CTD2 = loadstring(game:HttpGet(" .. quoteString(MAIN_URL) .. "))()",
        "end",
        "return CTD2:Run(" .. toLua(strategy) .. ")",
        "",
    }, "\n")
end

local function saveMacroFile()
    if not HAS_WRITEFILE then
        AddLog("ERROR: writefile unavailable")
        return false, "writefile unavailable"
    end
    local source = buildMacroSource()
    local ok, err = pcall(writefile, MACRO_FILE, source)
    if not ok then
        AddLog("ERROR writing " .. MACRO_FILE .. " -> " .. tostring(err))
        return false, err
    end
    if HAS_READFILE then
        local verifyOk, content = pcall(readfile, MACRO_FILE)
        if verifyOk and type(content) == "string" and #content > 50 then
            AddLog(string.format("Saved %s (%d bytes)", MACRO_FILE, #content))
        else
            AddLog("WARNING: readfile verification failed")
        end
    else
        AddLog("Saved " .. MACRO_FILE)
    end
    return true
end

local function startRecording()
    if State.Recording then
        WindUI:Notify({ Title = "Recorder", Content = "Already recording.", Icon = "triangle-alert", Duration = 2 })
        return
    end
    if not HAS_HOOK then
        WindUI:Notify({ Title = "Recorder", Content = "Recorder hook is unavailable.", Icon = "triangle-alert", Duration = 4 })
        return
    end

    State.Actions = {}
    State.NextActionSeq = 0
    State.NextUnitId = 0
    State.TowerToId = setmetatable({}, { __mode = "k" })
    State.Units = {}
    State.MacroMeta = captureMapMeta()
    State.Recording = true
    BeginLogSession("RECORDING STARTED")
    adoptExistingTowers()

    SetStatus("RECORDING")
    pcall(function()
        MapParagraph:SetDesc(string.format("%s / %s / %s / %s", State.MacroMeta.MapName, State.MacroMeta.MapDifficultyMode, State.MacroMeta.Campaign, State.MacroMeta.Gamemode))
    end)
    WindUI:Notify({ Title = "Recorder", Content = "Strategy recording started.", Icon = "circle-dot", Duration = 3 })
end

local function stopRecording()
    if not State.Recording then
        WindUI:Notify({ Title = "Recorder", Content = "Recorder is not running.", Icon = "triangle-alert", Duration = 2 })
        return
    end
    State.Recording = false
    SetStatus("SAVING")
    AddLog("RECORDING STOPPED")
    local ok, err = saveMacroFile()
    if ok then
        SetStatus("SAVED -> " .. MACRO_FILE)
        WindUI:Notify({ Title = "Macro Saved", Content = MACRO_FILE .. " is ready for autoexec.", Icon = "save", Duration = 5 })
    else
        SetStatus("SAVE FAILED")
        WindUI:Notify({ Title = "Save Failed", Content = tostring(err), Icon = "triangle-alert", Duration = 5 })
    end
    EndLogSession()
end

local function validTower(tower)
    return typeof(tower) == "Instance" and tower.Parent ~= nil and tower:IsDescendantOf(Workspace)
end

local function readTowerMaxLevel(tower)
    local maxLevel = tower and tower:FindFirstChild("MaxLevel")
    if not maxLevel then return nil end
    local ok, value = pcall(function() return tonumber(maxLevel.Value) end)
    return ok and value or nil
end

local function fallbackTargetPart(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {}
    if LocalPlayer.Character then exclude[#exclude + 1] = LocalPlayer.Character end
    local towers = Workspace:FindFirstChild("Towers")
    if towers then exclude[#exclude + 1] = towers end
    params.FilterDescendantsInstances = exclude
    local result = Workspace:Raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
    return result and result.Instance or nil
end

local function findRuntimeTower(name, pos, timeout)
    local towers = Workspace:FindFirstChild("Towers")
    if not towers then return nil end
    local deadline = os.clock() + (timeout or 3)
    repeat
        local best, bestDistance
        for _, tower in ipairs(towers:GetChildren()) do
            if tower.Name == name and isOwnedTower(tower) then
                local p = towerPosition(tower)
                if p then
                    local distance = (p - pos).Magnitude
                    if distance <= 18 and (not bestDistance or distance < bestDistance) then
                        best, bestDistance = tower, distance
                    end
                end
            end
        end
        if best then return best end
        task.wait(0.04)
    until os.clock() >= deadline
    return nil
end

local function invokePlace(name, pos, targetPath)
    local targetPart = resolvePath(targetPath) or fallbackTargetPart(pos)
    local attempt = 0
    while not Runtime.MatchEnded do
        attempt = attempt + 1
        State.InternalCall = true
        local ok, result = pcall(function()
            return PlaceUnit:InvokeServer(name, { Pos = pos, TargetPart = targetPart })
        end)
        State.InternalCall = false

        if ok and result ~= nil and result ~= false then
            local tower = typeof(result) == "Instance" and result or findRuntimeTower(name, pos, 2)
            if tower then return tower end
        end
        local replicated = findRuntimeTower(name, pos, 0.08)
        if replicated then return replicated end
        if attempt % 40 == 0 then
            AddLog(string.format("PLACE WAIT -> %s @ %.2f, %.2f, %.2f", name, pos.X, pos.Y, pos.Z))
        end
        task.wait(0.25)
        targetPart = targetPart or fallbackTargetPart(pos)
    end
    return nil
end

local function upgradeTo(state, targetLevel)
    if not validTower(state.Instance) then return false end
    targetLevel = tonumber(targetLevel)
    if targetLevel == nil then return true end

    local attempts = 0
    while validTower(state.Instance) and not Runtime.MatchEnded do
        local current = readTowerLevel(state.Instance)
        if current ~= nil and current >= targetLevel then
            return true
        end

        local maxLevel = readTowerMaxLevel(state.Instance)
        if maxLevel ~= nil and targetLevel > maxLevel then
            AddLog(string.format("UPGRADE IMPOSSIBLE -> target %s / max %s", tostring(targetLevel), tostring(maxLevel)))
            return false
        end

        attempts = attempts + 1
        State.InternalCall = true
        local callOk, accepted, serverMessage = pcall(function()
            return UpgradeRemote:InvokeServer(state.Instance)
        end)
        State.InternalCall = false

        if callOk and accepted == true then
            local old = current
            local deadline = os.clock() + 2.5
            repeat
                task.wait(0.05)
                current = readTowerLevel(state.Instance)
            until Runtime.MatchEnded or not validTower(state.Instance) or current ~= old or os.clock() >= deadline
        else
            -- With no automatic timestamps, an upgrade action waits until the game accepts it
            -- (for example, until the player has enough money).
            if attempts % 40 == 0 then
                AddLog("UPGRADE WAIT -> " .. tostring(state.Name or "unit") .. " to Lv." .. tostring(targetLevel)
                    .. (serverMessage and (" | " .. tostring(serverMessage)) or ""))
            end
            task.wait(0.25)
        end
    end
    return false
end

local function targetTo(state, desired)
    if not validTower(state.Instance) or desired == nil then return false end
    for _ = 1, 20 do
        if not validTower(state.Instance) then return false end
        if readTargetMode(state.Instance) == desired then return true end
        State.InternalCall = true
        pcall(function() TargetUnit:InvokeServer(state.Instance) end)
        State.InternalCall = false
        task.wait(0.08)
    end
    return readTargetMode(state.Instance) == desired
end

local API = {}

function API:EnsureUnit(id)
    local state = Runtime.Units[id]
    if not state or state.Sold then return nil end
    if validTower(state.Instance) then return state.Instance end
    if state.Restoring then
        local deadline = os.clock() + 35
        repeat
            task.wait(0.05)
        until not state.Restoring or validTower(state.Instance) or os.clock() >= deadline
        return validTower(state.Instance) and state.Instance or nil
    end
    if not state.Name or not state.Pos then return nil end

    state.Restoring = true
    AddLog("RESPAWN " .. id .. " / " .. state.Name)
    local tower = invokePlace(state.Name, state.Pos, state.TargetPath)
    state.Instance = tower
    if tower then
        upgradeTo(state, state.DesiredLevel)
        targetTo(state, state.TargetMode)
        AddLog("RESTORED " .. id)
    else
        AddLog("RESTORE FAILED " .. id)
    end
    state.Restoring = false
    return tower
end

function API:Place(id, name, pos, targetPath)
    local state = Runtime.Units[id] or {}
    Runtime.Units[id] = state
    state.Name = name
    state.Pos = pos
    state.TargetPath = targetPath
    state.Sold = false
    state.WasPlaced = true

    if validTower(state.Instance) then return state.Instance end
    state.Restoring = true
    local tower = invokePlace(name, pos, targetPath)
    state.Instance = tower
    state.Restoring = false
    if tower then
        AddLog(string.format("PLACE %s -> %s @ %.2f, %.2f, %.2f", id, name, pos.X, pos.Y, pos.Z))
        local placeTiming = Runtime.Strategy and tonumber(Runtime.Strategy.PlaceTiming) or State.PlaceTiming
        task.wait(math.max(0, placeTiming or 0))
    else
        AddLog("PLACE FAILED -> " .. id .. " / " .. name)
    end
    return tower
end

function API:Upgrade(id, level)
    local state = Runtime.Units[id]
    if not state then return false end
    state.DesiredLevel = level
    if not self:EnsureUnit(id) then return false end
    local ok = upgradeTo(state, level)
    AddLog("UPGRADE " .. id .. " -> " .. tostring(level) .. " | " .. tostring(ok))
    return ok
end

function API:Target(id, mode)
    local state = Runtime.Units[id]
    if not state then return false end
    state.TargetMode = mode
    if not self:EnsureUnit(id) then return false end
    local ok = targetTo(state, mode)
    AddLog("TARGET " .. id .. " -> " .. tostring(mode) .. " | " .. tostring(ok))
    return ok
end

function API:Move(id, skillName, targetCF, mousePos, targetPath)
    local state = Runtime.Units[id]
    if not state then return false end
    local tower = self:EnsureUnit(id)
    if not tower then return false end
    local targetPart = resolvePath(targetPath) or fallbackTargetPart(mousePos or targetCF.Position)
    local payload = {
        SkillName = skillName or "Reposition",
        successinfo = {
            TargetCF = targetCF,
            MousePos = mousePos or targetCF.Position,
            MouseTargetPart = targetPart,
        },
    }
    State.InternalCall = true
    pcall(function() SkillRemote:FireServer(tower, "ActivateSkill", payload) end)
    State.InternalCall = false
    state.Pos = targetCF.Position
    state.TargetPath = targetPath
    AddLog(string.format("MOVE %s -> %.2f, %.2f, %.2f", id, targetCF.Position.X, targetCF.Position.Y, targetCF.Position.Z))
    return true
end

function API:Sell(id)
    local state = Runtime.Units[id]
    if not state then return false end
    state.Sold = true
    if validTower(state.Instance) then
        State.InternalCall = true
        pcall(function() RemoveUnit:FireServer(state.Instance) end)
        State.InternalCall = false
    end
    AddLog("SELL " .. id)
    return true
end

function API:StartDeathWatcher()
    Runtime.DeathWatcherToken = Runtime.DeathWatcherToken + 1
    local token = Runtime.DeathWatcherToken
    task.spawn(function()
        while Runtime.Running and Runtime.DeathWatcherToken == token do
            for id, state in pairs(Runtime.Units) do
                if state.WasPlaced and not state.Sold and not validTower(state.Instance) and not state.Restoring then
                    task.spawn(function() self:EnsureUnit(id) end)
                end
            end
            task.wait(0.25)
        end
    end)
end

function API:IsLobby()
    local ok, result = pcall(function() return CTD2Module.seeiflobby() end)
    if ok then return result == true end
    return not Workspace:FindFirstChild("Towers")
end

local function requiredUnitsFrom(actions)
    local set, list = {}, {}
    for _, action in ipairs(actions or {}) do
        if action.Type == "Place" and action.Name and not set[action.Name] then
            set[action.Name] = true
            list[#list + 1] = action.Name
        end
    end
    table.sort(list)
    return list
end

local function mainLoadoutSlots()
    local playerData = LocalPlayer:WaitForChild("PlayerData")
    local loadout = playerData:WaitForChild("Loadout")
    local slots = {}
    for _, child in ipairs(loadout:GetChildren()) do
        local n = child.Name:match("^Tower(%d+)$")
        if n and tonumber(n) ~= 6 then slots[#slots + 1] = child end
    end
    table.sort(slots, function(a, b)
        return tonumber(a.Name:match("%d+")) < tonumber(b.Name:match("%d+"))
    end)
    return slots
end

function API:EnsureDeck(strategy)
    SetStatus("Checking deck")
    local required = requiredUnitsFrom(strategy.Actions)
    local playerData = LocalPlayer:WaitForChild("PlayerData")
    local inventory = playerData:WaitForChild("Inventory")
    local slots = mainLoadoutSlots()
    if #required > #slots then
        error("Strategy requires more unique units than available loadout slots")
    end

    for _, name in ipairs(required) do
        local item = inventory:FindFirstChild(name)
        local count = item and item:FindFirstChild("Count")
        if not count or (tonumber(count.Value) or 0) <= 0 then
            error("Required unit is not owned: " .. name)
        end
    end

    local present = {}
    for _, slot in ipairs(slots) do present[slot.Value] = slot end
    local requiredSet = {}
    for _, name in ipairs(required) do requiredSet[name] = true end

    for _, name in ipairs(required) do
        if not present[name] then
            local targetSlot
            for _, slot in ipairs(slots) do
                if slot.Value == "None" or not requiredSet[slot.Value] then
                    targetSlot = slot
                    break
                end
            end
            if not targetSlot then error("No free loadout slot for " .. name) end

            AddLog("EQUIP " .. name .. " -> " .. targetSlot.Name)
            State.InternalCall = true
            Remotes:WaitForChild("PlayerDataJob"):FireServer("EquipUnequipTower", {
                TowerName = name,
                EquipToSlotCode = targetSlot.Name,
            })
            State.InternalCall = false

            local deadline = os.clock() + 8
            repeat task.wait(0.05) until targetSlot.Value == name or os.clock() >= deadline
            if targetSlot.Value ~= name then error("Equip timeout: " .. name) end
            present[name] = targetSlot
        end
    end
    SetStatus("Deck ready")
    return true
end

local function charRoot()
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    return character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Torso")
        or character:WaitForChild("HumanoidRootPart", 5)
end

local function elevatorTargetCF(elevator)
    local base = elevator:FindFirstChild("baseplate") or elevator:FindFirstChildWhichIsA("BasePart", true)
    if base then return base.CFrame * CFrame.new(0, 3, 0) end
    if elevator:IsA("Model") then return elevator:GetPivot() * CFrame.new(0, 3, 0) end
    return nil
end

local function chooseElevator()
    local root = charRoot()
    local candidates = {}
    for _, elevator in ipairs(CollectionService:GetTagged("LobbyElevator")) do
        if elevator:FindFirstChild("ThisElevatorRemote") and elevator:FindFirstChild("RoomSystem") then
            local cf = elevatorTargetCF(elevator)
            if cf then
                local roomOwner = elevator:FindFirstChild("RoomOwner")
                local owner = roomOwner and roomOwner.Value or "None"
                candidates[#candidates + 1] = {
                    Obj = elevator,
                    Empty = owner == "None" or owner == LocalPlayer.Name,
                    Distance = root and (root.Position - cf.Position).Magnitude or 0,
                }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.Empty ~= b.Empty then return a.Empty end
        return a.Distance < b.Distance
    end)
    return candidates[1] and candidates[1].Obj or nil
end

function API:EnterElevator(elevator)
    SetStatus("Moving to elevator")
    local root = charRoot()
    local target = elevatorTargetCF(elevator)
    if not root or not target then return false end

    local distance = (root.Position - target.Position).Magnitude
    local duration = math.clamp(distance / 85, 0.15, 7)
    local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = target })
    tween:Play()
    tween.Completed:Wait()

    local isInElevator = LocalPlayer:FindFirstChild("IsInElevator")
    local deadline = os.clock() + 5
    repeat task.wait(0.05) until (isInElevator and isInElevator.Value == elevator) or os.clock() >= deadline
    if not isInElevator or isInElevator.Value ~= elevator then
        root.CFrame = target
        deadline = os.clock() + 4
        repeat task.wait(0.05) until (isInElevator and isInElevator.Value == elevator) or os.clock() >= deadline
    end
    return isInElevator and isInElevator.Value == elevator
end

function API:PrepareLobby(strategy)
    local ok, err = pcall(function()
        self:EnsureDeck(strategy)
        local elevator = chooseElevator()
        if not elevator then error("No LobbyElevator found") end
        if not self:EnterElevator(elevator) then error("Could not enter elevator") end

        local meta = strategy.Meta or {}
        SetStatus("Creating Friends Only room")
        local remote = elevator:WaitForChild("ThisElevatorRemote")
        State.InternalCall = true
        local result = remote:InvokeServer("OpenRoom", {
            ElevatorInfs = {
                MapName = meta.MapName,
                MapDifficultyMode = meta.MapDifficultyMode,
                Campaign = meta.Campaign,
                Gamemode = meta.Gamemode,
                PlayerLimit = 1,
                RoomEntryMode = "Friends Only",
                MapModifiers = {},
                Conquest_MapRoute = meta.Conquest_MapRoute or "No Route",
                Conquest_LegendModeGearChoice = meta.Conquest_LegendModeGearChoice or "None",
            },
        })
        State.InternalCall = false
        if result ~= true then error("OpenRoom returned " .. tostring(result)) end
        SetStatus("Teleporting to recorded map")
        task.wait(0.6)
        State.InternalCall = true
        remote:InvokeServer("Teleport")
        State.InternalCall = false
    end)

    if not ok then
        SetStatus("Lobby error")
        AddLog("LOBBY ERROR -> " .. tostring(err))
        WindUI:Notify({ Title = "CTD Macro", Content = tostring(err), Icon = "triangle-alert", Duration = 7 })
    end
end

local function cfFromArray(parts)
    if type(parts) ~= "table" or #parts < 12 then return CFrame.new() end
    return CFrame.new(table.unpack(parts, 1, 12))
end

local function vecFromArray(parts)
    if type(parts) ~= "table" then return Vector3.zero end
    return Vector3.new(tonumber(parts[1]) or 0, tonumber(parts[2]) or 0, tonumber(parts[3]) or 0)
end

local function formatEndRewards(payload)
    payload = type(payload) == "table" and payload or {}
    local result = tostring(payload.Result or "Unknown")
    local resultLabel = result == "Triumph" and "WIN" or (result == "Defeat" and "LOSS" or result:upper())
    local details = type(payload.CalculateRewardsDetails) == "table" and payload.CalculateRewardsDetails or {}
    local rewards = type(details.FinalRewardArray) == "table" and details.FinalRewardArray or {}
    local parts = {}

    for _, reward in pairs(rewards) do
        if type(reward) == "table" then
            local name = reward.CurrencyName
            local amount = tonumber(reward.CurrencyAmt)
            if name ~= nil and amount ~= nil then
                parts[#parts + 1] = tostring(name) .. " +" .. tostring(amount)
                    .. (reward.IsFirstTimeReward == true and " [First Time]" or "")
            end
        end
    end

    local exp = tonumber(payload.ExpReward)
    if exp ~= nil then
        parts[#parts + 1] = "EXP +" .. tostring(exp)
    end
    if #parts == 0 then
        parts[1] = "No rewards"
    end
    return resultLabel, table.concat(parts, " | ")
end

local function attachEndFrameWatcher()
    if Runtime.ResultConnection then
        pcall(function() Runtime.ResultConnection:Disconnect() end)
        Runtime.ResultConnection = nil
    end

    local map = Workspace:FindFirstChild("Map") or Workspace:WaitForChild("Map", 15)
    local endRemote = map and (map:FindFirstChild("EndFrameRemote") or map:WaitForChild("EndFrameRemote", 15))
    if not endRemote or not endRemote:IsA("RemoteEvent") then
        AddLog("RESULT WATCHER -> EndFrameRemote not found")
        return
    end

    Runtime.ResultConnection = endRemote.OnClientEvent:Connect(function(payload)
        if Runtime.MatchEnded then return end
        Runtime.MatchEnded = true

        local resultLabel, rewardsText = formatEndRewards(payload)
        AddLog("RESULT -> " .. resultLabel)
        AddLog("REWARDS -> " .. rewardsText)

        WindUI:Notify({
            Title = resultLabel == "WIN" and "Strategy Win" or "Strategy Result",
            Content = resultLabel .. " | " .. rewardsText,
            Icon = resultLabel == "WIN" and "trophy" or "flag",
            Duration = 8,
        })

        Runtime.Running = false
        Runtime.DeathWatcherToken = Runtime.DeathWatcherToken + 1
        task.defer(EndLogSession)
    end)
end

function API:RunActions(strategy)
    if Runtime.Running then return end
    Runtime.Running = true
    Runtime.MatchEnded = false
    Runtime.Strategy = strategy
    Runtime.Units = {}
    SetStatus("Replaying strategy")
    attachEndFrameWatcher()
    self:StartDeathWatcher()

    local ok, err = pcall(function()
        for _, action in ipairs(strategy.Actions or {}) do
            if action.Type == "Place" then
                self:Place(action.Id, action.Name, vecFromArray(action.Pos), action.TargetPath)
            elseif action.Type == "Upgrade" then
                self:Upgrade(action.Id, action.Level)
            elseif action.Type == "Target" then
                self:Target(action.Id, action.Mode)
            elseif action.Type == "Move" then
                self:Move(action.Id, action.SkillName or "Reposition", cfFromArray(action.TargetCF), vecFromArray(action.MousePos), action.TargetPath)
            elseif action.Type == "Sell" then
                self:Sell(action.Id)
            elseif action.Type == "Wait" then
                task.wait(math.max(0, tonumber(action.Seconds) or 0))
            end
        end
    end)

    if ok then
        SetStatus("Actions finished / recovery active")
        AddLog("Strategy actions completed; dead-unit recovery remains active")
    else
        Runtime.Running = false
        SetStatus("Strategy error")
        AddLog("STRATEGY ERROR -> " .. tostring(err))
        EndLogSession()
    end
end

function API:Run(strategy)
    if type(strategy) ~= "table" or type(strategy.Actions) ~= "table" then
        error("CTD2:Run expects a strategy table with Actions")
    end
    Runtime.Strategy = strategy

    local key = "__XOMAHUB_RUN_" .. tostring(game.JobId) .. "_" .. tostring(game.PlaceId)
    if GENV[key] then
        print("[XOMAHUB] Strategy already started in this server")
        return API
    end
    GENV[key] = true

    BeginLogSession((self:IsLobby() and "REPLAY PREP -> " or "REPLAY START -> ")
        .. tostring(#strategy.Actions) .. " actions / no automatic timestamps")

    if self:IsLobby() then
        task.spawn(function() self:PrepareLobby(strategy) end)
    else
        task.spawn(function()
            local deadline = os.clock() + 25
            repeat task.wait(0.1) until (Workspace:FindFirstChild("Towers") and Workspace:FindFirstChild("Map")) or os.clock() >= deadline
            self:RunActions(strategy)
        end)
    end
    return API
end

local function requestFunction()
    if type(request) == "function" then return request end
    if type(http_request) == "function" then return http_request end
    if syn and type(syn.request) == "function" then return syn.request end
    if http and type(http.request) == "function" then return http.request end
    return nil
end

local function sendWebhook(title, description, force)
    if not force and not State.WebhookEnabled then return false, "disabled" end
    if State.Webhook == "" then return false, "empty webhook" end
    local req = requestFunction()
    if not req then return false, "request API unavailable" end
    local body = HttpService:JSONEncode({
        username = "CTD Macro",
        embeds = {{
            title = title,
            description = description,
            footer = { text = "CTD Auto Summon" },
        }},
    })
    local ok, result = pcall(function()
        return req({
            Url = State.Webhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body,
        })
    end)
    return ok, result
end

local function inventorySnapshot()
    local out = {}
    local playerData = LocalPlayer:FindFirstChild("PlayerData")
    local inventory = playerData and playerData:FindFirstChild("Inventory")
    if not inventory then return out end
    for _, item in ipairs(inventory:GetChildren()) do
        local count = item:FindFirstChild("Count")
        if count then out[item.Name] = tonumber(count.Value) or 0 end
    end
    return out
end

local function processSummonDiff(before, after)
    for name, amount in pairs(after) do
        local delta = amount - (before[name] or 0)
        if delta > 0 then
            local rarity
            pcall(function()
                local towerTable = CTD2Module.GetTowerTable(name)
                rarity = towerTable and towerTable.Rarity
            end)
            if rarity == "Legendary" or rarity == "Mythic" then
                AddLog(string.format("SUMMON DROP -> %s | %s x%d", rarity, name, delta))
                local notify = rarity == "Legendary" and State.LegendaryNotify or State.MythicNotify
                if notify then
                    WindUI:Notify({
                        Title = rarity .. "!",
                        Content = name .. " x" .. tostring(delta),
                        Icon = rarity == "Mythic" and "sparkles" or "star",
                        Duration = 5,
                    })
                    local ok, result = sendWebhook(
                        rarity .. " obtained!",
                        string.format("**%s** x%d\nBanner: `%s`", name, delta, State.SummonBanner),
                        false
                    )
                    AddLog("WEBHOOK " .. rarity .. " -> " .. tostring(ok) .. (ok and "" or (" / " .. tostring(result))))
                end
            end
        end
    end
end

local function setAutoSummon(enabled)
    State.AutoSummon = enabled == true
    State.SummonLoopId = State.SummonLoopId + 1
    local loopId = State.SummonLoopId
    AddLog("Auto Summon -> " .. tostring(State.AutoSummon))
    if not State.AutoSummon then return end

    task.spawn(function()
        while State.AutoSummon and State.SummonLoopId == loopId do
            local before = inventorySnapshot()
            local oldDone = LocalPlayer:GetAttribute("SummonDone") or 0
            State.InternalCall = true
            pcall(function()
                Remotes:WaitForChild("DoBannerSummon"):FireServer(State.SummonBanner, State.SummonPullCode)
            end)
            State.InternalCall = false

            local deadline = os.clock() + 6
            repeat task.wait(0.05) until not State.AutoSummon
                or State.SummonLoopId ~= loopId
                or (LocalPlayer:GetAttribute("SummonDone") or 0) ~= oldDone
                or os.clock() >= deadline
            processSummonDiff(before, inventorySnapshot())
            task.wait(math.max(0.1, tonumber(State.SummonDelay) or 0.5))
        end
    end)
end

MacroTab:Section({ Title = "Recorder", TextSize = 20 })
MacroTab:Button({
    Title = "Recorder",
    Desc = "Start recording placements, upgrades, sells, targeting and reposition actions.",
    Icon = "circle-dot",
    Callback = startRecording,
})
MacroTab:Button({
    Title = "Stop Recording",
    Desc = "Stop and write compact ctdcool.lua via writefile.",
    Icon = "square",
    Callback = stopRecording,
})
MacroTab:Divider()
MacroTab:Slider({
    Title = "Place Timing",
    Desc = "User-set settling delay after each replayed placement. No click timestamps are recorded.",
    Step = 0.05,
    Value = { Min = 0, Max = 3, Default = State.PlaceTiming },
    Callback = function(value)
        State.PlaceTiming = tonumber(value) or 0.15
        saveConfig()
    end,
})
MacroTab:Toggle({ Title = "Record Unit Placement", Value = State.RecordPlacement, Callback = function(v) State.RecordPlacement = v end })
MacroTab:Toggle({ Title = "Record Upgrades", Value = State.RecordUpgrade, Callback = function(v) State.RecordUpgrade = v end })
MacroTab:Toggle({ Title = "Record Sell", Value = State.RecordSell, Callback = function(v) State.RecordSell = v end })
MacroTab:Toggle({ Title = "Record Targeting", Value = State.RecordTarget, Callback = function(v) State.RecordTarget = v end })
MacroTab:Toggle({ Title = "Record Unit Movement", Value = State.RecordMove, Callback = function(v) State.RecordMove = v end })
MacroTab:Divider()

SummonTab:Section({ Title = "Auto Summon", TextSize = 20 })
SummonTab:Input({
    Title = "Banner",
    Value = State.SummonBanner,
    Callback = function(value)
        State.SummonBanner = value ~= "" and value or "Basic Summon"
        saveConfig()
    end,
})
SummonTab:Input({
    Title = "Pull Code",
    Desc = "1Summon or 10Summon",
    Value = State.SummonPullCode,
    Callback = function(value)
        State.SummonPullCode = value ~= "" and value or "10Summon"
        saveConfig()
    end,
})
SummonTab:Slider({
    Title = "Summon Delay",
    Step = 0.1,
    Value = { Min = 0.1, Max = 5, Default = State.SummonDelay },
    Callback = function(value)
        State.SummonDelay = tonumber(value) or 0.5
        saveConfig()
    end,
})
SummonTab:Toggle({
    Title = "Enable Auto Summon",
    Value = false,
    Callback = setAutoSummon,
})
SummonTab:Divider()
SummonTab:Toggle({
    Title = "Legendary Notification",
    Value = State.LegendaryNotify,
    Callback = function(value) State.LegendaryNotify = value; saveConfig() end,
})
SummonTab:Toggle({
    Title = "Mythic Notification",
    Value = State.MythicNotify,
    Callback = function(value) State.MythicNotify = value; saveConfig() end,
})

WebhookTab:Section({ Title = "Discord Webhook", TextSize = 20 })
WebhookTab:Input({
    Title = "Webhook URL",
    Value = State.Webhook,
    Callback = function(value) State.Webhook = value or ""; saveConfig() end,
})
WebhookTab:Toggle({
    Title = "Enable Webhook",
    Value = State.WebhookEnabled,
    Callback = function(value)
        State.WebhookEnabled = value
        saveConfig()
        AddLog("Webhook enabled -> " .. tostring(value))
    end,
})
WebhookTab:Button({
    Title = "Test Webhook",
    Icon = "send",
    Callback = function()
        local ok, result = sendWebhook("CTD Macro test", "Webhook is working.", true)
        AddLog("WEBHOOK TEST -> " .. tostring(ok) .. (ok and "" or (" / " .. tostring(result))))
        WindUI:Notify({
            Title = "Webhook",
            Content = ok and "Test sent." or tostring(result),
            Icon = ok and "check" or "triangle-alert",
            Duration = 4,
        })
    end,
})

API.State = State
API.Runtime = Runtime
API.StartRecording = startRecording
API.StopRecording = stopRecording
API.SaveMacro = saveMacroFile
API.BuildMacroSource = buildMacroSource
API.AddLog = AddLog
API.SetStatus = SetStatus

GENV.XomaHub = API
GENV.CTDMacroHub = API

print("[XOMAHUB] XomaHub loaded")
print("[XOMAHUB] Recorder hook ->", HAS_HOOK)
print("[XOMAHUB] readfile/writefile ->", HAS_READFILE, HAS_WRITEFILE)
WindUI:Notify({
    Title = "CTD Macro",
    Content = "XomaHub ready. Strategy playback has no automatic action timestamps.",
    Icon = "check",
    Duration = 4,
})

return API
