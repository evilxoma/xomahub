-- XOMA / CTDIG reliability patch
-- Build: PASS24-AUTORETRY-RECONNECT-V34
-- Auto Retry is built in and cannot be disabled by SaveManager/autoload or by
-- a strategy Config table. Network/disconnect error prompts trigger a rejoin
-- loop; failed teleport attempts are retried until the connection recovers.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.XOMA) ~= "table"
    or type(session.XOMA.Config) ~= "function"
then
    error("XOMA V34 reliability patch: CTDIG/XOMA session is unavailable")
end

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local player = Players.LocalPlayer

session.forceAutoRetry = true

-- Keep the original closure because it owns the core-local Toggles table. By
-- calling it with AutoRetry=true we update the real CTDIGAutoRetry toggle even
-- though SaveManager/Toggles themselves are not exported from the core chunk.
if type(session.reliabilityOriginalConfig) ~= "function" then
    session.reliabilityOriginalConfig = session.XOMA.Config
end

local originalConfig = session.reliabilityOriginalConfig

local function copyConfig(config)
    local copied = {}
    if type(config) == "table" then
        for key, value in pairs(config) do
            copied[key] = value
        end
    end
    copied.AutoRetry = true
    return copied
end

local function forceAutoRetry()
    if not session.alive or type(session.XOMA) ~= "table" then
        return false
    end

    local config = copyConfig(session.XOMA._macro and session.XOMA._macro.config)
    local ok = pcall(originalConfig, session.XOMA, config)
    if ok and type(session.XOMA._macro) == "table" then
        session.XOMA._macro.config = config
    end
    return ok
end

if session.reliabilityConfigWrapped ~= true then
    session.XOMA.Config = function(self, config)
        return originalConfig(self, copyConfig(config))
    end
    session.reliabilityConfigWrapped = true
end

-- Force immediately, then keep enforcing it. This deliberately wins over an
-- autoload config that restores CTDIGAutoRetry=false a moment later.
forceAutoRetry()
task.spawn(function()
    while session.alive do
        task.wait(1.0)
        forceAutoRetry()
    end
end)

session.reconnectV34 = session.reconnectV34 or {
    active = false,
    attempts = 0,
    reason = nil,
}

local reconnect = session.reconnectV34

local function normalized(text)
    return tostring(text or ""):lower()
end

local function looksLikeNetworkFailure(text)
    text = normalized(text)
    if text == "" then
        return false
    end

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

local function collectPromptText(root)
    if not root then
        return ""
    end

    local parts = {}
    if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
        parts[#parts + 1] = tostring(root.Text or "")
    end

    for _, object in ipairs(root:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local text = tostring(object.Text or "")
            if text ~= "" then
                parts[#parts + 1] = text
            end
        end
    end

    return table.concat(parts, " | ")
end

local function startReconnect(reason)
    if reconnect.active or not session.alive then
        return
    end

    reconnect.active = true
    reconnect.reason = tostring(reason or "network error")
    reconnect.attempts = 0

    warn("[XOMA V34] Network disconnect detected | rejoin armed | " .. reconnect.reason)

    task.spawn(function()
        task.wait(1.0)

        while session.alive and reconnect.active do
            reconnect.attempts = reconnect.attempts + 1
            print("[XOMA V34] Rejoin attempt " .. tostring(reconnect.attempts))

            local ok, err = pcall(function()
                -- Teleport() is used here intentionally: this patch runs on the
                -- client and TeleportAsync is server-only for normal experiences.
                TeleportService:Teleport(game.PlaceId, player)
            end)

            if not ok then
                warn("[XOMA V34] Rejoin request failed: " .. tostring(err))
            end

            -- If the request succeeded the old DataModel will disappear. If it
            -- failed because the network is still down, remain here and retry.
            task.wait(math.min(10, 2 + reconnect.attempts))
        end
    end)
end

session.autoReconnect = startReconnect

if session.reconnectWatchersInstalled ~= true then
    session.reconnectWatchersInstalled = true

    -- Roblox's own error message signal when available in this client build.
    pcall(function()
        local GuiService = game:GetService("GuiService")
        GuiService.ErrorMessageChanged:Connect(function(message)
            if looksLikeNetworkFailure(message) then
                startReconnect(message)
            end
        end)
    end)

    -- Fallback used by the desktop client: inspect only RobloxPromptGui, never
    -- PlayerGui/Obsidian, so normal CTDIG UI text cannot trigger a reconnect.
    pcall(function()
        local CoreGui = game:GetService("CoreGui")

        local function inspect(object)
            task.defer(function()
                task.wait(0.1)
                if not object or not object.Parent then
                    return
                end
                local text = collectPromptText(object)
                if looksLikeNetworkFailure(text) then
                    startReconnect(text)
                end
            end)
        end

        local function bindPromptGui(promptGui)
            if not promptGui then
                return
            end
            inspect(promptGui)
            promptGui.DescendantAdded:Connect(inspect)
        end

        local promptGui = CoreGui:FindFirstChild("RobloxPromptGui")
        if promptGui then
            bindPromptGui(promptGui)
        end

        CoreGui.ChildAdded:Connect(function(child)
            if child.Name == "RobloxPromptGui" then
                bindPromptGui(child)
            end
        end)
    end)

    -- If a reconnect teleport itself fails to initialize due to the network,
    -- keep the same retry loop alive instead of giving up after one attempt.
    pcall(function()
        TeleportService.TeleportInitFailed:Connect(function(failedPlayer, _, errorMessage)
            if failedPlayer == player and (reconnect.active or looksLikeNetworkFailure(errorMessage)) then
                startReconnect(errorMessage)
            end
        end)
    end)
end

session.reliabilityBuild = "PASS24-AUTORETRY-RECONNECT-V34"
print("[XOMA V34] Auto Retry forced ON | network reconnect installed")

return session.XOMA
