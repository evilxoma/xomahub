-- XOMA Auto Retry authoritative end-screen watcher
-- Build: PASS32-AUTORETRY-DIRECT-CLICK-V39
-- Only a live, active, on-screen Restart + Return pair from the same RoundFrame
-- is allowed to arm Auto Retry. Once armed, click the actual GuiButton signal
-- directly instead of sending screen-coordinate mouse input.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
then
    error("XOMA V39 end-click patch: CTDIG end-action API unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

if type(session.endClickOriginalHandleV39) ~= "function" then
    session.endClickOriginalHandleV39 = session.recorder.handleEndAction
end
local originalHandle = session.endClickOriginalHandleV39

local CLICK_INTERVAL = 2.5
local MAX_ATTEMPTS = 4
local NEW_MATCH_RESET_DELAY = 3
local OFFSCREEN_LOG_INTERVAL = 4
local lastOffscreenLog = -math.huge

local control = session.endClickV39
if type(control) ~= "table" then
    control = {}
    session.endClickV39 = control
end

local function resetControl()
    control.endFrame = nil
    control.container = nil
    control.restart = nil
    control.returnButton = nil
    control.attempts = 0
    control.lastAttempt = 0
    control.busy = false
    control.confirmed = false
    control.beforeText = nil
    control.missingSince = 0
    control.exhaustedLogged = false
    control.replayStopped = false
    control.sentAtLeastOnce = false
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
    for _, object in ipairs(button:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") then
            local text = tostring(object.Text or "")
            if text ~= "" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " | ")
end

local function readButtonGeometry(button)
    local camera = Workspace.CurrentCamera
    if not button or not button.Parent or not camera then
        return false, false, nil, nil, nil, nil
    end

    local ok, position, size, viewport = pcall(function()
        return button.AbsolutePosition, button.AbsoluteSize, camera.ViewportSize
    end)
    if not ok
        or typeof(position) ~= "Vector2"
        or typeof(size) ~= "Vector2"
        or typeof(viewport) ~= "Vector2"
        or size.X <= 1
        or size.Y <= 1
        or viewport.X <= 1
        or viewport.Y <= 1
    then
        return false, false, position, size, viewport, nil
    end

    local right = position.X + size.X
    local bottom = position.Y + size.Y
    local intersects = right > 0
        and bottom > 0
        and position.X < viewport.X
        and position.Y < viewport.Y

    local center = position + size / 2
    local centerOnScreen = center.X >= 0
        and center.Y >= 0
        and center.X < viewport.X
        and center.Y < viewport.Y

    return intersects, centerOnScreen, position, size, viewport, center
end

local function geometryText(position, size, viewport)
    if typeof(position) ~= "Vector2"
        or typeof(size) ~= "Vector2"
        or typeof(viewport) ~= "Vector2"
    then
        return "pos=? | size=? | viewport=?"
    end
    return string.format(
        "pos=%.0f,%.0f | size=%.0f,%.0f | viewport=%.0f,%.0f",
        position.X,
        position.Y,
        size.X,
        size.Y,
        viewport.X,
        viewport.Y
    )
end

local function baseButtonState(button, playerGui)
    if not button
        or not button:IsA("GuiButton")
        or button.Visible ~= true
        or not hierarchyVisible(button, playerGui)
    then
        return false, false, false
    end

    local intersects = readButtonGeometry(button)
    return true, button.Active == true, intersects
end

local function looksLikeRestart(button)
    if not button or not button:IsA("GuiButton") then return false end
    if button.Name == "Restart" then return true end
    return string.lower(buttonText(button)):find("restart", 1, true) ~= nil
end

local function looksLikeReturn(button)
    if not button or not button:IsA("GuiButton") then return false end
    if button.Name == "Return" then return true end
    local text = string.lower(buttonText(button))
    return text:find("exit to lobby", 1, true) ~= nil
        or text:find("return to lobby", 1, true) ~= nil
        or text:find("back to lobby", 1, true) ~= nil
end

local function findEndFrame(object)
    local current = object and object.Parent
    while current do
        if current.Name == "EndFrame" then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function findActionContainer(button, endFrame)
    local current = button and button.Parent
    local fallback = current
    while current and current ~= endFrame do
        if current.Name == "RoundFrame" and current:IsA("GuiObject") then
            return current
        end
        current = current.Parent
    end
    return fallback
end

local function findLiveEndActions(playerGui)
    if not playerGui then return nil, nil, nil, nil, nil end

    local byContainer = {}
    local ignoredRestart

    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") and (looksLikeRestart(object) or looksLikeReturn(object)) then
            local endFrame = findEndFrame(object)
            if endFrame and hierarchyVisible(endFrame, playerGui) then
                local baseOk, active, onScreen = baseButtonState(object, playerGui)
                if baseOk then
                    local container = findActionContainer(object, endFrame)
                    if container and hierarchyVisible(container, playerGui) then
                        local entry = byContainer[container]
                        if not entry then
                            entry = {
                                endFrame = endFrame,
                                restart = nil,
                                restartActive = false,
                                restartOnScreen = false,
                                returnButton = nil,
                                returnActive = false,
                                returnOnScreen = false,
                            }
                            byContainer[container] = entry
                        end

                        if entry.endFrame == endFrame then
                            if looksLikeRestart(object) then
                                entry.restart = object
                                entry.restartActive = active
                                entry.restartOnScreen = onScreen
                                if not onScreen then
                                    ignoredRestart = object
                                end
                            elseif looksLikeReturn(object) then
                                entry.returnButton = object
                                entry.returnActive = active
                                entry.returnOnScreen = onScreen
                            end
                        end
                    end
                end
            end
        end
    end

    for container, entry in pairs(byContainer) do
        if entry.restart
            and entry.returnButton
            and entry.restartActive
            and entry.returnActive
            and entry.restartOnScreen
            and entry.returnOnScreen
        then
            return entry.endFrame, container, entry.restart, entry.returnButton, ignoredRestart
        end
    end

    return nil, nil, nil, nil, ignoredRestart
end

local function readResult()
    local playerResult = player and player:FindFirstChild("PlayerGameResult")
    local playerText = playerResult and tostring(playerResult.Value) or ""
    if playerText == "Triumph" or playerText == "Defeat" then
        return playerText
    end

    local service = Workspace:FindFirstChild("WorkspaceScriptService")
    local rewards = service and service:FindFirstChild("Rewards")
    local rewardResult = rewards and rewards:FindFirstChild("Result")
    local rewardText = rewardResult and tostring(rewardResult.Value) or ""
    if rewardText == "Triumph" or rewardText == "Defeat" then
        return rewardText
    end
    return nil
end

local function voteCount(text)
    local votes, required = tostring(text or ""):match("%((%d+)%s*/%s*(%d+)%)")
    return tonumber(votes), tonumber(required)
end

local function accepted(endFrame, container, button, beforeText)
    if not endFrame or not endFrame.Parent then
        return true, "EndFrame disappeared"
    end
    if endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end
    if not container or not container.Parent then
        return true, "end action container disappeared"
    end
    if not button or not button.Parent then
        return true, "Restart button disappeared"
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui and not hierarchyVisible(endFrame, playerGui) then
        return true, "EndFrame hidden"
    end
    if playerGui and not hierarchyVisible(container, playerGui) then
        return true, "end action container hidden"
    end
    if playerGui and not hierarchyVisible(button, playerGui) then
        return true, "Restart button hidden"
    end

    local onScreen = readButtonGeometry(button)
    if not onScreen then
        return true, "Restart button left viewport"
    end

    local currentText = buttonText(button)
    local beforeVotes = voteCount(beforeText)
    local votes, required = voteCount(currentText)
    if votes and beforeVotes and votes > beforeVotes then
        return true, "restart vote=" .. tostring(votes) .. "/" .. tostring(required)
    end

    return false
end

local function livePairStillValid(playerGui, endFrame, container, restartButton, returnButton)
    if not playerGui
        or not endFrame or not endFrame.Parent
        or not container or not container.Parent
        or findEndFrame(restartButton) ~= endFrame
        or findEndFrame(returnButton) ~= endFrame
        or findActionContainer(restartButton, endFrame) ~= container
        or findActionContainer(returnButton, endFrame) ~= container
    then
        return false
    end

    local rBase, rActive, rOnScreen = baseButtonState(restartButton, playerGui)
    local bBase, bActive, bOnScreen = baseButtonState(returnButton, playerGui)
    return rBase and rActive and rOnScreen and bBase and bActive and bOnScreen
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

local function directClick(endFrame, container, button, returnButton, attempt)
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not livePairStillValid(playerGui, endFrame, container, button, returnButton) then
        return false, "end-screen pair changed before click", "changed"
    end

    local intersects, centerOnScreen, position, size, viewport = readButtonGeometry(button)
    if not intersects or not centerOnScreen then
        return false, geometryText(position, size, viewport), "offscreen"
    end

    local candidates = {
        { name = "MouseButton1Click", signal = button.MouseButton1Click },
        { name = "Activated", signal = button.Activated },
    }

    local getConnections = executorFunction("getconnections")
    if getConnections then
        for _, candidate in ipairs(candidates) do
            local okConnections, signalConnections = pcall(getConnections, candidate.signal)
            if okConnections and type(signalConnections) == "table" then
                local fired = 0
                for _, connection in ipairs(signalConnections) do
                    if fireConnectionObject(connection) then
                        fired = fired + 1
                    end
                end
                if fired > 0 then
                    local detail = candidate.name .. ":connections=" .. tostring(fired)
                    print(string.format(
                        "[XOMA V39] Auto Retry direct click %d | %s | %s",
                        attempt,
                        detail,
                        geometryText(position, size, viewport)
                    ))
                    return true, detail, "sent"
                end
            end
        end
    end

    local fireSignal = executorFunction("firesignal")
    if fireSignal then
        -- Without getconnections we cannot know which completed-click signal the
        -- game subscribed to. Alternate rather than firing both and risking a
        -- duplicate vote from one attempt.
        local candidate = candidates[((attempt - 1) % #candidates) + 1]
        local ok, err = pcall(fireSignal, candidate.signal)
        if ok then
            local detail = candidate.name .. ":firesignal"
            print(string.format(
                "[XOMA V39] Auto Retry direct click %d | %s | %s",
                attempt,
                detail,
                geometryText(position, size, viewport)
            ))
            return true, detail, "sent"
        end
        return false, candidate.name .. " firesignal failed: " .. tostring(err), "failed"
    end

    return false, "executor has no getconnections/firesignal", "failed"
end

local function confirmRestart(why)
    if control.confirmed then return end
    control.confirmed = true
    control.missingSince = 0
    print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
end

local function logOffscreen(button)
    local now = os.clock()
    if now - lastOffscreenLog < OFFSCREEN_LOG_INTERVAL then return end
    lastOffscreenLog = now

    local _, _, position, size, viewport = readButtonGeometry(button)
    print("[XOMA V39] Restart ignored off-screen | " .. geometryText(position, size, viewport))
end

local function stopReplayForRealEnd()
    if control.replayStopped then return end
    control.replayStopped = true
    if type(session.stopReplayForEndScreen) == "function" then
        local ok, err = pcall(session.stopReplayForEndScreen, "real end screen")
        if not ok then
            warn("[XOMA V39] Replay stop hook failed | " .. tostring(err))
        end
    end
end

-- Forced Auto Retry owns Restart. The old handler is retained only for
-- non-forced mode. Result values remain webhook diagnostics, never a Retry gate.
session.recorder.handleEndAction = function(...)
    if not session.alive then return end
    if session.forceAutoRetry ~= true then
        return originalHandle(...)
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local endFrame = findLiveEndActions(playerGui)
    local result = endFrame and readResult()
    if type(session.observeWebhookResult) == "function" then
        if result then
            pcall(session.observeWebhookResult, endFrame, result)
        else
            pcall(session.observeWebhookResult, nil, nil)
        end
    end
end

session.endClickWatcherSerialV39 = (tonumber(session.endClickWatcherSerialV39) or 0) + 1
local watcherSerial = session.endClickWatcherSerialV39

task.spawn(function()
    while session.alive and session.endClickWatcherSerialV39 == watcherSerial do
        task.wait(0.12)

        if session.forceAutoRetry ~= true then
            resetControl()
            continue
        end

        local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
        local endFrame, container, restartButton, returnButton, ignoredRestart =
            findLiveEndActions(playerGui)

        if not endFrame or not container or not restartButton or not returnButton then
            if ignoredRestart and not control.confirmed and control.attempts == 0 then
                logOffscreen(ignoredRestart)
            end

            if control.sentAtLeastOnce and not control.confirmed then
                local done, why = accepted(
                    control.endFrame,
                    control.container,
                    control.restart,
                    control.beforeText or ""
                )
                if done then confirmRestart(why) end
            end

            if control.confirmed then
                if control.missingSince == 0 then
                    control.missingSince = os.clock()
                elseif os.clock() - control.missingSince >= NEW_MATCH_RESET_DELAY then
                    resetControl()
                end
            elseif control.endFrame ~= nil then
                resetControl()
            end
            continue
        end

        control.missingSince = 0

        if control.endFrame ~= endFrame
            or control.container ~= container
            or control.restart ~= restartButton
            or control.returnButton ~= returnButton
        then
            resetControl()
            control.endFrame = endFrame
            control.container = container
            control.restart = restartButton
            control.returnButton = returnButton
            stopReplayForRealEnd()
            print(
                "[XOMA V39] End screen on-screen | Restart=" .. buttonText(restartButton)
                    .. " | Return=" .. buttonText(returnButton)
            )
        end

        if control.confirmed then continue end

        local beforeText = buttonText(restartButton)
        if control.sentAtLeastOnce and control.beforeText then
            local done, why = accepted(endFrame, container, restartButton, control.beforeText)
            if done then
                confirmRestart(why)
                continue
            end
        end

        if control.busy then continue end

        local now = os.clock()
        if control.attempts >= MAX_ATTEMPTS then
            if not control.exhaustedLogged then
                control.exhaustedLogged = true
                warn("[XOMA V39] Auto Retry stopped after "
                    .. tostring(MAX_ATTEMPTS) .. " unconfirmed clicks")
            end
            continue
        end
        if control.lastAttempt > 0 and now - control.lastAttempt < CLICK_INTERVAL then
            continue
        end

        local intersects, centerOnScreen = readButtonGeometry(restartButton)
        if not intersects or not centerOnScreen then
            logOffscreen(restartButton)
            continue
        end

        control.busy = true
        local attempt = control.attempts + 1
        local ok, detail, status = directClick(
            endFrame,
            container,
            restartButton,
            returnButton,
            attempt
        )

        if status == "offscreen" then
            logOffscreen(restartButton)
            control.busy = false
            continue
        elseif status == "changed" then
            control.busy = false
            continue
        end

        control.attempts = attempt
        control.lastAttempt = os.clock()

        if ok then
            control.sentAtLeastOnce = true
            control.beforeText = beforeText
            local deadline = os.clock() + 1.25
            repeat
                local acceptedNow, acceptedWhy = accepted(
                    endFrame,
                    container,
                    restartButton,
                    beforeText
                )
                if acceptedNow then
                    confirmRestart(acceptedWhy)
                    break
                end
                task.wait(0.04)
            until os.clock() >= deadline
        else
            warn("[XOMA V39] Auto Retry direct click failed | " .. tostring(detail))
        end

        control.busy = false
    end
end)

session.endClickBuild = "PASS32-AUTORETRY-DIRECT-CLICK-V39"
print("[XOMA V39] Auto Retry direct-button watcher installed")

return session.XOMA