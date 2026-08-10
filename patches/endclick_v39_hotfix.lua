-- XOMA Auto Retry injector-API-only hotfix
-- Build: PASS36-AUTORETRY-INJECTOR-API-V39
-- Scope: Auto Retry only. Recorder/place/upgrade/skip/ready/difficulty untouched.
--
-- No VirtualInputManager. No coordinate clicks. No physical mouse movement.
-- The exact live PlayerGui.EndFrame.RoundFrame.Restart button is activated only
-- through executor/injector APIs (getconnections/firesignal/keypress aliases).

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" then
    error("XOMA V39 Auto Retry injector hotfix: CTDIG session unavailable")
end

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local player = Players.LocalPlayer

-- Kill every older end-screen watcher. PASS36 is the only Restart owner.
session.endClickWatcherSerialV39 = (tonumber(session.endClickWatcherSerialV39) or 0) + 1
session.endClickHotfixSerialV39 = (tonumber(session.endClickHotfixSerialV39) or 0) + 1
session.endClickInjectorSerialV39 = (tonumber(session.endClickInjectorSerialV39) or 0) + 1
local watcherSerial = session.endClickInjectorSerialV39

local POLL = 0.10
local RETRY_DELAY = 0.90
local CONFIRM_WINDOW = 0.75
local NEW_ROUND_RESET = 2.0

local control = session.endClickInjectorV39
if type(control) ~= "table" then
    control = {}
    session.endClickInjectorV39 = control
end

local function resetControl()
    control.endFrame = nil
    control.restart = nil
    control.beforeText = ""
    control.attempts = 0
    control.nextAttempt = 0
    control.accepted = false
    control.acceptedAt = 0
    control.replayStopped = false
end

resetControl()

local function executorFunction(names)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
        local value = rawget(environment, name) or rawget(_G, name)
        if type(value) == "function" then
            return value, name
        end
    end
    return nil, nil
end

local function buttonText(button)
    if not button then return "" end
    local parts = {}
    if button:IsA("TextButton") then
        local text = tostring(button.Text or "")
        if text ~= "" then parts[#parts + 1] = text end
    end
    for _, object in ipairs(button:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") then
            local text = tostring(object.Text or "")
            if text ~= "" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " | ")
end

local function voteCount(text)
    local votes, required = tostring(text or ""):match("%((%d+)%s*/%s*(%d+)%)")
    return tonumber(votes), tonumber(required)
end

local function getLiveRestart()
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return nil end

    local endFrame = playerGui:FindFirstChild("EndFrame")
    if not endFrame or not endFrame:IsA("LayerCollector") or endFrame.Enabled ~= true then
        return nil
    end

    local roundFrame = endFrame:FindFirstChild("RoundFrame")
    local restart = roundFrame and roundFrame:FindFirstChild("Restart")
    if not restart or not restart:IsA("GuiButton") then
        return nil
    end

    -- The supplied game save sets these only when Restart is actually ready.
    if restart.Visible ~= true or restart.Active ~= true then
        return nil
    end

    return endFrame, restart
end

local function accepted(endFrame, restart, beforeText)
    if not endFrame or not endFrame.Parent then
        return true, "EndFrame disappeared"
    end

    if endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end

    if not restart or not restart.Parent then
        return true, "Restart disappeared"
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

    return false
end

local function stopReplayOnce()
    if control.replayStopped then return end
    control.replayStopped = true
    if type(session.stopReplayForEndScreen) == "function" then
        local ok, err = pcall(session.stopReplayForEndScreen, "Restart ready")
        if not ok then
            warn("[XOMA V39] replay-stop hook failed | " .. tostring(err))
        end
    end
end

local function invokeConnection(connection, activated)
    if not connection then return false end

    if type(connection.Fire) == "function" then
        if activated then
            if pcall(connection.Fire, connection, nil, 1) then return true end
        end
        if pcall(connection.Fire, connection) then return true end
    end

    if type(connection.Function) == "function" then
        if activated then
            if pcall(connection.Function, nil, 1) then return true end
        end
        if pcall(connection.Function) then return true end
    end

    return false
end

local function viaConnections(restart)
    local getConnections, apiName = executorFunction({
        "getconnections",
        "get_signal_cons",
        "get_signal_connections",
    })
    if not getConnections then
        return false, "getconnections unavailable"
    end

    local signalList = {
        { name = "MouseButton1Click", signal = restart.MouseButton1Click, activated = false },
        { name = "Activated", signal = restart.Activated, activated = true },
    }

    local total = 0
    local details = {}

    for _, item in ipairs(signalList) do
        local ok, connections = pcall(getConnections, item.signal)
        local fired = 0
        if ok and type(connections) == "table" then
            for _, connection in ipairs(connections) do
                if invokeConnection(connection, item.activated) then
                    fired = fired + 1
                end
            end
        end
        total = total + fired
        details[#details + 1] = item.name .. "=" .. tostring(fired)
    end

    return total > 0, tostring(apiName) .. " | " .. table.concat(details, ",")
end

local function viaFireSignal(restart)
    local fireSignal, apiName = executorFunction({ "firesignal", "fire_signal" })
    if not fireSignal then
        return false, "firesignal unavailable"
    end

    local fired = 0
    local ok1 = pcall(fireSignal, restart.MouseButton1Click)
    if ok1 then fired = fired + 1 end

    local ok2 = pcall(fireSignal, restart.Activated, nil, 1)
    if not ok2 then
        ok2 = pcall(fireSignal, restart.Activated)
    end
    if ok2 then fired = fired + 1 end

    return fired > 0, tostring(apiName) .. " | signals=" .. tostring(fired)
end

local function viaKeypress(restart)
    local keypress, pressName = executorFunction({ "keypress", "key_press" })
    local keyrelease, releaseName = executorFunction({ "keyrelease", "key_release" })
    if not keypress then
        return false, "keypress unavailable"
    end

    local previous
    pcall(function()
        previous = GuiService.SelectedObject
        GuiService.SelectedObject = restart
    end)

    -- VK_RETURN = 0x0D. This is executor input API, not VirtualInputManager.
    local ok, err = pcall(keypress, 0x0D)
    if keyrelease then
        task.wait(0.04)
        pcall(keyrelease, 0x0D)
    end

    task.defer(function()
        task.wait(0.15)
        pcall(function()
            if GuiService.SelectedObject == restart then
                GuiService.SelectedObject = previous
            end
        end)
    end)

    if not ok then
        return false, tostring(pressName) .. " failed: " .. tostring(err)
    end

    return true, tostring(pressName) .. "/" .. tostring(releaseName or "no-release") .. " VK_RETURN"
end

local function injectorClick(endFrame, restart)
    control.attempts = (tonumber(control.attempts) or 0) + 1
    control.beforeText = buttonText(restart)

    local methods = {
        { name = "connections", fn = viaConnections },
        { name = "firesignal", fn = viaFireSignal },
        { name = "keypress", fn = viaKeypress },
    }

    for _, method in ipairs(methods) do
        local ok, detail = method.fn(restart)
        print(string.format(
            "[XOMA V39] Injector Auto Retry attempt %d | %s | %s",
            control.attempts,
            method.name,
            tostring(detail)
        ))

        if ok then
            local deadline = os.clock() + CONFIRM_WINDOW
            repeat
                local done, why = accepted(endFrame, restart, control.beforeText)
                if done then
                    control.accepted = true
                    control.acceptedAt = os.clock()
                    print("[XOMA V39] Injector Auto Retry confirmed | " .. tostring(why))
                    return true
                end
                task.wait(0.04)
            until os.clock() >= deadline
        end
    end

    control.nextAttempt = os.clock() + RETRY_DELAY
    return false
end

task.spawn(function()
    while session.alive and session.endClickInjectorSerialV39 == watcherSerial do
        task.wait(POLL)

        if session.forceAutoRetry ~= true then
            resetControl()
            continue
        end

        local endFrame, restart = getLiveRestart()
        if not endFrame then
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
            print("[XOMA V39] Injector Auto Retry armed | Restart=" .. buttonText(restart))
        end

        if control.accepted then continue end

        local done, why = accepted(endFrame, restart, control.beforeText or "")
        if done and control.attempts > 0 then
            control.accepted = true
            control.acceptedAt = os.clock()
            print("[XOMA V39] Injector Auto Retry confirmed | " .. tostring(why))
            continue
        end

        if os.clock() >= (control.nextAttempt or 0) then
            injectorClick(endFrame, restart)
        end
    end
end)

session.endClickBuild = "PASS36-AUTORETRY-INJECTOR-API-V39"
print("[XOMA V39] Auto Retry injector-API-only watcher installed")

return session.XOMA
