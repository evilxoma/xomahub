-- XOMA / CTDIG reliability patch
-- Build: PASS27-AUTORETRY-RECONNECT-RECORDER-V37
-- Auto Retry is authoritative, network disconnects rejoin the same place, and
-- recorder output is normalized to the V37 cache-busted bootstrap.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.XOMA) ~= "table"
    or type(session.XOMA.Config) ~= "function"
then
    error("XOMA V37 reliability patch: CTDIG/XOMA session unavailable")
end

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local player = Players.LocalPlayer
local MACRO_FILE = "ctdig.lua"
local BOOTSTRAP_URL = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui_v37.lua"

session.forceAutoRetry = true

if type(session.reliabilityOriginalConfig) ~= "function" then
    session.reliabilityOriginalConfig = session.XOMA.Config
end
local originalConfig = session.reliabilityOriginalConfig

local function forcedConfig(config)
    local result = {}
    if type(config) == "table" then
        for key, value in pairs(config) do
            result[key] = value
        end
    end
    result.AutoRetry = true
    return result
end

local function forceAutoRetry()
    if not session.alive or type(session.XOMA) ~= "table" then
        return false
    end
    local config = forcedConfig(session.XOMA._macro and session.XOMA._macro.config)
    local ok = pcall(originalConfig, session.XOMA, config)
    if ok and type(session.XOMA._macro) == "table" then
        session.XOMA._macro.config = config
    end
    return ok
end

session.XOMA.Config = function(self, config)
    return originalConfig(self, forcedConfig(config))
end

local function upgradeSavedMacro()
    if typeof(isfile) ~= "function"
        or typeof(readfile) ~= "function"
        or typeof(writefile) ~= "function"
        or not isfile(MACRO_FILE)
    then
        return false
    end

    local ok, source = pcall(readfile, MACRO_FILE)
    if not ok or type(source) ~= "string"
        or source:find("CTDIG / XOMA AUTOEXEC STRATEGY", 1, true) == nil
    then
        return false
    end

    local updated = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/ctdui[_%w%-]*%.lua",
        BOOTSTRAP_URL
    )

    if updated == source then
        return source:find(BOOTSTRAP_URL, 1, true) ~= nil
    end

    local wrote, err = pcall(writefile, MACRO_FILE, updated)
    if not wrote then
        warn("[XOMA V37] macro bootstrap update failed: " .. tostring(err))
        return false
    end

    print("[XOMA V37] Saved macro bootstrap upgraded -> ctdui_v37.lua")
    return true
end

session.upgradeSavedMacroBootstrapV37 = upgradeSavedMacro
forceAutoRetry()
upgradeSavedMacro()

if session.reliabilityMonitorV37Installed ~= true then
    session.reliabilityMonitorV37Installed = true
    task.spawn(function()
        while session.alive do
            task.wait(0.5)
            forceAutoRetry()
            upgradeSavedMacro()
        end
    end)
end

session.reconnectV37 = session.reconnectV37 or {
    active = false,
    attempts = 0,
    reason = nil,
}
local reconnect = session.reconnectV37

local function networkFailure(text)
    text = tostring(text or ""):lower()
    if text == "" then return false end
    return text:find("error code: 277", 1, true) ~= nil
        or text:find("error code: 279", 1, true) ~= nil
        or text:find("error code: 266", 1, true) ~= nil
        or text:find("disconnected", 1, true) ~= nil
        or text:find("connection lost", 1, true) ~= nil
        or text:find("connection timed out", 1, true) ~= nil
        or text:find("failed to connect", 1, true) ~= nil
        or text:find("internet connection", 1, true) ~= nil
        or text:find("соединен", 1, true) ~= nil
        or text:find("соединение", 1, true) ~= nil
        or text:find("интернет", 1, true) ~= nil
        or text:find("подключ", 1, true) ~= nil
end

local function promptText(root)
    if not root then return "" end
    local parts = {}
    if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
        parts[#parts + 1] = tostring(root.Text or "")
    end
    for _, object in ipairs(root:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local text = tostring(object.Text or "")
            if text ~= "" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " | ")
end

local function startReconnect(reason)
    if reconnect.active or not session.alive then return end
    reconnect.active = true
    reconnect.reason = tostring(reason or "network error")
    reconnect.attempts = 0
    warn("[XOMA V37] Network disconnect detected | rejoin armed | " .. reconnect.reason)

    task.spawn(function()
        task.wait(1)
        while session.alive and reconnect.active do
            reconnect.attempts = reconnect.attempts + 1
            print("[XOMA V37] Rejoin attempt " .. tostring(reconnect.attempts))
            local ok, err = pcall(function()
                TeleportService:Teleport(game.PlaceId, player)
            end)
            if not ok then
                warn("[XOMA V37] Rejoin request failed: " .. tostring(err))
            end
            task.wait(math.min(10, 2 + reconnect.attempts))
        end
    end)
end

session.autoReconnect = startReconnect

if session.reconnectWatchersV37Installed ~= true then
    session.reconnectWatchersV37Installed = true

    pcall(function()
        local GuiService = game:GetService("GuiService")
        GuiService.ErrorMessageChanged:Connect(function(message)
            if networkFailure(message) then startReconnect(message) end
        end)
    end)

    pcall(function()
        local CoreGui = game:GetService("CoreGui")
        local function inspect(object)
            task.defer(function()
                task.wait(0.1)
                if object and object.Parent then
                    local text = promptText(object)
                    if networkFailure(text) then startReconnect(text) end
                end
            end)
        end
        local function bind(root)
            if not root then return end
            inspect(root)
            root.DescendantAdded:Connect(inspect)
        end
        bind(CoreGui:FindFirstChild("RobloxPromptGui"))
        CoreGui.ChildAdded:Connect(function(child)
            if child.Name == "RobloxPromptGui" then bind(child) end
        end)
    end)

    pcall(function()
        TeleportService.TeleportInitFailed:Connect(function(failedPlayer, _, message)
            if failedPlayer == player and (reconnect.active or networkFailure(message)) then
                if not reconnect.active then startReconnect(message) end
            end
        end)
    end)
end

session.reliabilityBuild = "PASS27-AUTORETRY-RECONNECT-RECORDER-V37"
print("[XOMA V37] Auto Retry forced ON | reconnect installed | recorder -> V37")
return session.XOMA
