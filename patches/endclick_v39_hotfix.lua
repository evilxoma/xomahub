-- XOMA Auto Retry real-button hotfix
-- Build: PASS34-AUTORETRY-REAL-RESTART-V39
-- Scope: Auto Retry only. Do not touch recorder/place/upgrade/skip/ready/difficulty.
--
-- The saved game moves EndFrame.RoundFrame.Restart far off-screen first and only
-- later makes it Active/Selectable and tweens it into view. The previous cascade
-- could spend many seconds trying synthetic RBXScriptSignals before reaching a
-- real input click. This watcher waits for the exact live PlayerGui button and
-- sends a virtual click at its CURRENT center first. It never moves the physical
-- OS cursor and never falls back to Return/Back to Lobby while Auto Retry owns it.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" then
    error("XOMA V39 Auto Retry hotfix: CTDIG session unavailable")
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

-- Stop the PASS33 watcher so there is exactly one owner of Restart clicks.
session.endClickWatcherSerialV39 = (tonumber(session.endClickWatcherSerialV39) or 0) + 1
session.endClickHotfixSerialV39 = (tonumber(session.endClickHotfixSerialV39) or 0) + 1
local watcherSerial = session.endClickHotfixSerialV39

local POLL = 0.10
local RETRY_DELAY = 0.85
local POST_CLICK_CONFIRM = 0.70
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
    control.replayStopped = false
end

resetControl()

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

    -- Use the exact hierarchy from the game save. Do not scan StarterGui clones.
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

local function sendVIM(center)
    local heldOk, held = pcall(
        UserInputService.IsMouseButtonPressed,
        UserInputService,
        Enum.UserInputType.MouseButton1
    )
    if heldOk and held == true then
        return false, "physical Mouse1 held"
    end

    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then
        return false, "VIM unavailable"
    end

    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.045)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)
    if not ok then
        pcall(function()
            vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        end)
        return false, tostring(err)
    end
    return true, "VIM real button click"
end

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function signalFallback(restart)
    local getConnections = executorFunction("getconnections")
    if getConnections then
        for _, signal in ipairs({ restart.MouseButton1Click, restart.Activated }) do
            local ok, connections = pcall(getConnections, signal)
            if ok and type(connections) == "table" then
                local fired = 0
                for _, connection in ipairs(connections) do
                    if type(connection.Fire) == "function" and pcall(connection.Fire, connection) then
                        fired = fired + 1
                    elseif type(connection.Function) == "function" and pcall(connection.Function) then
                        fired = fired + 1
                    end
                end
                if fired > 0 then
                    return true, "connections=" .. tostring(fired)
                end
            end
        end
    end

    local fireSignal = executorFunction("firesignal")
    if fireSignal then
        local ok, err = pcall(fireSignal, restart.MouseButton1Click)
        if ok then return true, "firesignal MouseButton1Click" end
        return false, tostring(err)
    end

    return false, "no click fallback available"
end

local function clickRestart(endFrame, restart, center)
    -- Snapshot BEFORE sending input. This fixes the old race where a synchronous
    -- vote text update could happen before beforeText was captured.
    local beforeText = buttonText(restart)
    control.beforeText = beforeText
    control.attempts = (tonumber(control.attempts) or 0) + 1

    local ok, detail = sendVIM(center)
    if not ok then
        ok, detail = signalFallback(restart)
    end

    control.sent = ok
    control.nextAttempt = os.clock() + RETRY_DELAY

    print(string.format(
        "[XOMA V39] Auto Retry Restart attempt %d | %s",
        control.attempts,
        tostring(detail)
    ))

    if not ok then return false end

    local deadline = os.clock() + POST_CLICK_CONFIRM
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
            clickRestart(endFrame, restart, currentCenter or center)
        end
    end
end)

session.endClickBuild = "PASS34-AUTORETRY-REAL-RESTART-V39"
print("[XOMA V39] Auto Retry real-Restart hotfix installed")

return session.XOMA
