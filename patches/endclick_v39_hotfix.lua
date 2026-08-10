-- XOMA Auto Retry real-button hotfix
-- Build: PASS35-AUTORETRY-DIRECT-SIGNAL-V39
-- Scope: Auto Retry only. Recorder/place/upgrade/skip/ready/difficulty untouched.
--
-- PASS34 proved that the real PlayerGui.EndFrame.RoundFrame.Restart is found and
-- that VIM input is sent, but a successful SendMouseButtonEvent only means the
-- input packet was emitted. CoreGui (notably the developer console) can sit above
-- PlayerGui and consume that click. PASS35 therefore drives the Restart button's
-- own live RBXScriptSignal connections FIRST. Coordinate input is only a fallback.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" then
    error("XOMA V39 Auto Retry hotfix: CTDIG session unavailable")
end

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

-- Stop all older end-click owners. Only this watcher may drive Restart.
session.endClickWatcherSerialV39 = (tonumber(session.endClickWatcherSerialV39) or 0) + 1
session.endClickHotfixSerialV39 = (tonumber(session.endClickHotfixSerialV39) or 0) + 1
local watcherSerial = session.endClickHotfixSerialV39

local POLL = 0.10
local METHOD_CONFIRM_WAIT = 1.15
local NO_METHOD_DELAY = 0.15
local METHOD_CYCLE_DELAY = 1.50
local NEW_ROUND_RESET = 2.50

local control = session.endClickRealV39
if type(control) ~= "table" then
    control = {}
    session.endClickRealV39 = control
end

local function resetControl()
    control.endFrame = nil
    control.restart = nil
    control.beforeText = nil
    control.sent = false
    control.accepted = false
    control.acceptedAt = 0
    control.nextAttempt = 0
    control.attempts = 0
    control.methodIndex = 1
    control.replayStopped = false
end

resetControl()

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function hierarchyVisible(object, stopAt)
    local current = object
    while current and current ~= stopAt do
        if current:IsA("GuiObject") and current.Visible == false then
            return false
        end
        if current:IsA("LayerCollector") and current.Enabled == false then
            return false
        end
        current = current.Parent
    end
    return current == stopAt
end

local function buttonText(button)
    if not button then return "" end
    local parts = {}
    if button:IsA("TextButton") then
        local text = tostring(button.Text or "")
        if text ~= "" then parts[#parts + 1] = text end
    end
    for _, descendant in ipairs(button:GetDescendants()) do
        if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
            local text = tostring(descendant.Text or "")
            if text ~= "" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " | ")
end

local function voteCount(text)
    local votes, required = tostring(text or ""):match("%((%d+)%s*/%s*(%d+)%)")
    return tonumber(votes), tonumber(required)
end

local function geometry(button)
    local camera = Workspace.CurrentCamera
    if not button or not button.Parent or not camera then
        return false, nil
    end

    local ok, position, size, viewport = pcall(function()
        return button.AbsolutePosition, button.AbsoluteSize, camera.ViewportSize
    end)
    if not ok
        or typeof(position) ~= "Vector2"
        or typeof(size) ~= "Vector2"
        or typeof(viewport) ~= "Vector2"
        or size.X <= 1 or size.Y <= 1
        or viewport.X <= 1 or viewport.Y <= 1
    then
        return false, nil
    end

    local center = position + size / 2
    local centerOnScreen = center.X >= 0
        and center.Y >= 0
        and center.X < viewport.X
        and center.Y < viewport.Y

    return centerOnScreen, center
end

local function getLiveRestart()
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return nil end

    -- Exact hierarchy verified from the supplied game save.
    local endFrame = playerGui:FindFirstChild("EndFrame")
    if not endFrame or not endFrame:IsA("LayerCollector") or endFrame.Enabled ~= true then
        return nil
    end

    local roundFrame = endFrame:FindFirstChild("RoundFrame")
    local restart = roundFrame and roundFrame:FindFirstChild("Restart")
    if not restart or not restart:IsA("GuiButton") then return nil end
    if restart.Visible ~= true or restart.Active ~= true then return nil end
    if not hierarchyVisible(restart, playerGui) then return nil end

    local onScreen, center = geometry(restart)
    if not onScreen then return nil end

    return endFrame, restart, center
end

local function stopReplayOnce()
    if control.replayStopped then return end
    control.replayStopped = true
    if type(session.stopReplayForEndScreen) == "function" then
        local ok, err = pcall(session.stopReplayForEndScreen, "real Restart button ready")
        if not ok then
            warn("[XOMA V39] Auto Retry replay-stop hook failed | " .. tostring(err))
        end
    end
end

local function accepted(endFrame, restart, beforeText)
    if not endFrame or not endFrame.Parent then
        return true, "EndFrame disappeared"
    end
    if endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end
    if not restart or not restart.Parent then
        return true, "Restart button disappeared"
    end

    local currentText = buttonText(restart)
    local beforeVotes = voteCount(beforeText)
    local currentVotes, required = voteCount(currentText)
    if beforeVotes and currentVotes and currentVotes > beforeVotes then
        return true, "restart vote=" .. tostring(currentVotes) .. "/" .. tostring(required)
    end

    if beforeText ~= "" and currentText ~= "" and currentText ~= beforeText then
        return true, "Restart text changed"
    end

    if restart.Active == false then
        return true, "Restart became inactive"
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui and not hierarchyVisible(endFrame, playerGui) then
        return true, "EndFrame hidden"
    end

    return false
end

local function fireConnectionObject(connection)
    if not connection then return false end
    if type(connection.Fire) == "function" and pcall(connection.Fire, connection) then
        return true
    end
    if type(connection.Function) == "function" and pcall(connection.Function) then
        return true
    end
    return false
end

local function sendConnections(signal, signalName)
    local getConnections = executorFunction("getconnections")
    if not getConnections then return false, signalName .. ": getconnections unavailable" end

    local ok, connections = pcall(getConnections, signal)
    if not ok or type(connections) ~= "table" then
        return false, signalName .. ": getconnections failed"
    end

    local fired = 0
    for _, connection in ipairs(connections) do
        if fireConnectionObject(connection) then fired = fired + 1 end
    end
    if fired <= 0 then
        return false, signalName .. ": connections=0"
    end
    return true, signalName .. ": connections=" .. tostring(fired)
end

local function sendFireSignal(signal, signalName)
    local fireSignal = executorFunction("firesignal")
    if not fireSignal then return false, signalName .. ": firesignal unavailable" end
    local ok, err = pcall(fireSignal, signal)
    if not ok then return false, signalName .. ": " .. tostring(err) end
    return true, signalName .. ": firesignal"
end

local function hideDevConsoleForFallback()
    -- This is intentionally best-effort. If F9/DevConsole is covering the game,
    -- coordinate input otherwise lands on CoreGui instead of the Restart button.
    local ok = pcall(function()
        StarterGui:SetCore("DevConsoleVisible", false)
    end)
    if ok then task.wait(0.12) end
    return ok
end

local function sendSelectedObject(restart)
    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then return false, "SelectedObject: VIM unavailable" end

    hideDevConsoleForFallback()

    local previous
    pcall(function()
        previous = GuiService.SelectedObject
        GuiService.SelectedObject = restart
    end)

    local ok, err = pcall(function()
        vim:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait(0.045)
        vim:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
    end)

    task.defer(function()
        task.wait(0.2)
        pcall(function()
            if GuiService.SelectedObject == restart then
                GuiService.SelectedObject = previous
            end
        end)
    end)

    if not ok then return false, "SelectedObject Return failed: " .. tostring(err) end
    return true, "SelectedObject + Return"
end

local function sendVIM(restart, center)
    local heldOk, held = pcall(
        UserInputService.IsMouseButtonPressed,
        UserInputService,
        Enum.UserInputType.MouseButton1
    )
    if heldOk and held == true then
        return false, "VIM: physical Mouse1 held"
    end

    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then return false, "VIM unavailable" end

    hideDevConsoleForFallback()

    local oldZ
    pcall(function()
        oldZ = restart.ZIndex
        restart.ZIndex = 10000
    end)

    local onScreen, currentCenter = geometry(restart)
    center = currentCenter or center
    if not onScreen or typeof(center) ~= "Vector2" then
        if oldZ ~= nil then pcall(function() restart.ZIndex = oldZ end) end
        return false, "VIM: Restart left viewport"
    end

    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.045)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    if oldZ ~= nil then
        task.defer(function()
            task.wait(0.1)
            pcall(function()
                if restart and restart.Parent then restart.ZIndex = oldZ end
            end)
        end)
    end

    if not ok then
        pcall(function()
            vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        end)
        return false, "VIM failed: " .. tostring(err)
    end
    return true, "VIM real button click"
end

local function methodTable(restart, center)
    return {
        {
            name = "MouseButton1Click:getconnections",
            send = function() return sendConnections(restart.MouseButton1Click, "MouseButton1Click") end,
        },
        {
            name = "Activated:getconnections",
            send = function() return sendConnections(restart.Activated, "Activated") end,
        },
        {
            name = "MouseButton1Click:firesignal",
            send = function() return sendFireSignal(restart.MouseButton1Click, "MouseButton1Click") end,
        },
        {
            name = "Activated:firesignal",
            send = function() return sendFireSignal(restart.Activated, "Activated") end,
        },
        {
            name = "SelectedObject+Return",
            send = function() return sendSelectedObject(restart) end,
        },
        {
            name = "VIM",
            send = function() return sendVIM(restart, center) end,
        },
    }
end

local function tryNextMethod(endFrame, restart, center)
    local methods = methodTable(restart, center)
    if control.methodIndex > #methods then
        control.methodIndex = 1
        control.nextAttempt = os.clock() + METHOD_CYCLE_DELAY
        print("[XOMA V39] Auto Retry methods exhausted | cycling")
        return false
    end

    local method = methods[control.methodIndex]
    control.methodIndex = control.methodIndex + 1
    control.attempts = (tonumber(control.attempts) or 0) + 1

    -- Snapshot BEFORE signal dispatch. Some handlers update vote text synchronously.
    local beforeText = buttonText(restart)
    control.beforeText = beforeText

    local ok, detail = method.send()
    print(string.format(
        "[XOMA V39] Auto Retry method %d | %s | %s",
        control.attempts,
        method.name,
        tostring(detail)
    ))

    if not ok then
        control.nextAttempt = os.clock() + NO_METHOD_DELAY
        return false
    end

    control.sent = true
    control.nextAttempt = os.clock() + METHOD_CONFIRM_WAIT

    local deadline = os.clock() + METHOD_CONFIRM_WAIT
    repeat
        local done, why = accepted(endFrame, restart, beforeText)
        if done then
            control.accepted = true
            control.acceptedAt = os.clock()
            print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
            return true
        end
        task.wait(0.04)
    until os.clock() >= deadline

    return false
end

task.spawn(function()
    while session.alive and session.endClickHotfixSerialV39 == watcherSerial do
        task.wait(POLL)

        if session.forceAutoRetry ~= true then
            resetControl()
            continue
        end

        local endFrame, restart, center = getLiveRestart()
        if not endFrame then
            if control.sent and not control.accepted then
                local done, why = accepted(control.endFrame, control.restart, control.beforeText or "")
                if done then
                    control.accepted = true
                    control.acceptedAt = os.clock()
                    print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
                end
            end

            if control.accepted and os.clock() - (control.acceptedAt or 0) >= NEW_ROUND_RESET then
                resetControl()
            elseif not control.accepted and control.endFrame ~= nil then
                resetControl()
            end
            continue
        end

        if control.endFrame ~= endFrame or control.restart ~= restart then
            resetControl()
            control.endFrame = endFrame
            control.restart = restart
            stopReplayOnce()
            print("[XOMA V39] Real Restart ready | " .. buttonText(restart))
        end

        if control.accepted then continue end

        if control.sent then
            local done, why = accepted(endFrame, restart, control.beforeText or "")
            if done then
                control.accepted = true
                control.acceptedAt = os.clock()
                print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
                continue
            end
        end

        if os.clock() < (control.nextAttempt or 0) then continue end

        local stillOnScreen, currentCenter = geometry(restart)
        if stillOnScreen and restart.Active == true then
            tryNextMethod(endFrame, restart, currentCenter or center)
        end
    end
end)

session.endClickBuild = "PASS35-AUTORETRY-DIRECT-SIGNAL-V39"
print("[XOMA V39] Auto Retry direct-signal hotfix installed")

return session.XOMA
