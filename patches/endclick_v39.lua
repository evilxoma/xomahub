-- XOMA Auto Retry authoritative end-screen watcher
-- Build: PASS30-AUTORETRY-VIEWPORT-V39
-- The in-match Restart vote can exist before the match is actually over.
-- Auto Retry is armed only when BOTH Restart and Return/Exit to Lobby are
-- genuinely visible in the same EndFrame. This prevents startup clicks from
-- consuming retry attempts before the real result screen appears.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
then
    error("XOMA V39 end-click patch: CTDIG end-action API unavailable")
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
local originalHandle = session.recorder.handleEndAction
local CLICK_INTERVAL = 2.5
local MAX_ATTEMPTS = 4
local NEW_MATCH_RESET_DELAY = 3
local OFFSCREEN_LOG_INTERVAL = 4
local lastOffscreenLog = -math.huge

session.endClickV39 = {
    endFrame = nil,
    restart = nil,
    returnButton = nil,
    attempts = 0,
    lastAttempt = 0,
    busy = false,
    confirmed = false,
    beforeText = nil,
    missingSince = 0,
    exhaustedLogged = false,
}
local control = session.endClickV39

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
    return true
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

    local left = position.X
    local top = position.Y
    local right = left + size.X
    local bottom = top + size.Y
    local intersects = right > 0
        and bottom > 0
        and left < viewport.X
        and top < viewport.Y
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

local function buttonState(button, playerGui)
    if not button
        or not button:IsA("GuiButton")
        or button.Visible ~= true
        or not hierarchyVisible(button, playerGui)
    then
        return false, false
    end

    local onScreen = readButtonGeometry(button)
    return true, onScreen
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

local function findLiveEndActions(playerGui)
    if not playerGui then return nil, nil, nil, nil end

    local byFrame = {}
    local ignoredRestart
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") then
            local endFrame = object:FindFirstAncestor("EndFrame")
            local eligible, onScreen = buttonState(object, playerGui)
            if endFrame and hierarchyVisible(endFrame, playerGui) and eligible then
                local entry = byFrame[endFrame]
                if not entry then
                    entry = {
                        restart = nil,
                        restartOnScreen = false,
                        returnButton = nil,
                        returnOnScreen = false,
                    }
                    byFrame[endFrame] = entry
                end
                if looksLikeRestart(object) then
                    entry.restart = object
                    entry.restartOnScreen = onScreen
                    if not onScreen then
                        ignoredRestart = object
                    end
                elseif looksLikeReturn(object) then
                    entry.returnButton = object
                    entry.returnOnScreen = onScreen
                end
            end
        end
    end

    for endFrame, entry in pairs(byFrame) do
        if entry.restart
            and entry.returnButton
            and entry.restartOnScreen
            and entry.returnOnScreen
        then
            return endFrame, entry.restart, entry.returnButton
        end
    end

    return nil, nil, nil, ignoredRestart
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

local function findCTDIGScreenGuis()
    local roots = {}
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local gethuiFn = executorFunction("gethui")
    if gethuiFn then
        local ok, hui = pcall(gethuiFn)
        if ok and typeof(hui) == "Instance" then roots[#roots + 1] = hui end
    end

    local okCore, coreGui = pcall(game.GetService, game, "CoreGui")
    if okCore and coreGui and not table.find(roots, coreGui) then
        roots[#roots + 1] = coreGui
    end
    if playerGui and not table.find(roots, playerGui) then
        roots[#roots + 1] = playerGui
    end

    local found, seen = {}, {}
    local function addScreen(screen)
        if not screen or seen[screen] then return end

        local name = string.lower(tostring(screen.Name or ""))
        local matches = name:find("obsidian", 1, true) ~= nil
            or name:find("ctdig", 1, true) ~= nil
        if not matches then
            for _, object in ipairs(screen:GetDescendants()) do
                if (object:IsA("TextLabel") or object:IsA("TextButton"))
                    and tostring(object.Text):find("CTDIG", 1, true)
                then
                    matches = true
                    break
                end
            end
        end

        if matches then
            seen[screen] = true
            found[#found + 1] = screen
        end
    end

    for _, root in ipairs(roots) do
        if root:IsA("ScreenGui") then
            addScreen(root)
        end
        for _, object in ipairs(root:GetDescendants()) do
            if object:IsA("ScreenGui") then
                addScreen(object)
            end
        end
    end
    return found
end

local function suppressCTDIG()
    local restore = {}
    for _, screen in ipairs(findCTDIGScreenGuis()) do
        local ok, enabled = pcall(function() return screen.Enabled end)
        if ok and enabled == true then
            restore[#restore + 1] = screen
            pcall(function() screen.Enabled = false end)
        end
    end

    return function()
        for _, screen in ipairs(restore) do
            if screen and screen.Parent then
                pcall(function() screen.Enabled = true end)
            end
        end
    end, #restore
end

local function voteCount(text)
    local votes, required = tostring(text or ""):match("%((%d+)%s*/%s*(%d+)%)")
    return tonumber(votes), tonumber(required)
end

local function accepted(endFrame, button, beforeText)
    if not endFrame or not endFrame.Parent then
        return true, "EndFrame disappeared"
    end
    if endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end
    if not button or not button.Parent then
        return true, "Restart button disappeared"
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui and not hierarchyVisible(endFrame, playerGui) then
        return true, "EndFrame hidden"
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

    if beforeText ~= "" and currentText ~= "" and currentText ~= beforeText then
        return true, "text changed: " .. beforeText .. " -> " .. currentText
    end

    return false
end

local function waitOneFrame()
    local ok = pcall(function()
        RunService.Heartbeat:Wait()
    end)
    if not ok then
        task.wait()
    end
end

local function vimClick(button, attempt)
    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then
        return false, "VirtualInputManager unavailable", "failed"
    end

    local heldOk, held = pcall(
        UserInputService.IsMouseButtonPressed,
        UserInputService,
        Enum.UserInputType.MouseButton1
    )
    if heldOk and held == true then
        return false, "physical Mouse1 held", "blocked"
    end

    local restore, suppressed = suppressCTDIG()
    waitOneFrame()

    -- AbsolutePosition can change between discovery and the actual click.
    -- Re-read everything after Obsidian is removed from hit-testing.
    local intersects, centerOnScreen, position, size, viewport, center =
        readButtonGeometry(button)
    if not intersects or not centerOnScreen then
        restore()
        return false, geometryText(position, size, viewport), "offscreen"
    end

    print(string.format(
        "[XOMA V39] Auto Retry click %d | %s",
        attempt,
        geometryText(position, size, viewport)
    ))

    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.04)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    if not ok then
        pcall(function()
            vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        end)
    end
    restore()

    if not ok then
        return false, "VIM failed: " .. tostring(err), "failed"
    end

    return true, string.format(
        "VIM @ %.0f,%.0f | CTDIG suppressed=%d",
        center.X,
        center.Y,
        suppressed
    ), "sent"
end

local function resetControl()
    control.endFrame = nil
    control.restart = nil
    control.returnButton = nil
    control.attempts = 0
    control.lastAttempt = 0
    control.busy = false
    control.confirmed = false
    control.beforeText = nil
    control.missingSince = 0
    control.exhaustedLogged = false
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
    print("[XOMA V39] Restart ignored off-screen | "
        .. geometryText(position, size, viewport))
end

-- With forced Auto Retry enabled, this watcher exclusively owns Restart.
-- Calling the core handler here would re-enable its stale result-gated
-- firesignal path and could click an off-screen pre-match copy of Restart.
session.recorder.handleEndAction = function(...)
    if not session.alive then return end

    if session.forceAutoRetry ~= true then
        return originalHandle(...)
    end

    -- Result values are diagnostic/webhook data only. They never gate Retry.
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

if session.endClickWatcherV39Installed ~= true then
    session.endClickWatcherV39Installed = true
    task.spawn(function()
        while session.alive do
            task.wait(0.12)

            if session.forceAutoRetry ~= true then
                resetControl()
                continue
            end

            local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
            local endFrame, restartButton, returnButton, ignoredRestart =
                findLiveEndActions(playerGui)
            if not endFrame or not restartButton or not returnButton then
                if ignoredRestart and not control.confirmed and control.attempts == 0 then
                    logOffscreen(ignoredRestart)
                end

                if control.attempts > 0 and not control.confirmed then
                    local done, why = accepted(
                        control.endFrame,
                        control.restart,
                        control.beforeText or ""
                    )
                    if done then
                        confirmRestart(why)
                    end
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
            if control.confirmed then
                continue
            end

            if control.endFrame ~= endFrame or control.restart ~= restartButton then
                resetControl()
                control.endFrame = endFrame
                control.restart = restartButton
                control.returnButton = returnButton
                print(
                    "[XOMA V39] End screen on-screen | Restart=" .. buttonText(restartButton)
                        .. " | Return=" .. buttonText(returnButton)
                )
            end

            local beforeText = buttonText(restartButton)
            if control.attempts > 0 and control.beforeText then
                local done, why = accepted(endFrame, restartButton, control.beforeText)
                if done then
                    confirmRestart(why)
                    continue
                end
            end

            if control.confirmed or control.busy then
                continue
            end

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
            local ok, detail, status = vimClick(restartButton, attempt)

            if status == "offscreen" then
                logOffscreen(restartButton)
                control.busy = false
                continue
            elseif status == "blocked" then
                control.busy = false
                continue
            end

            control.attempts = attempt
            control.lastAttempt = os.clock()
            control.beforeText = beforeText

            if ok then
                local deadline = os.clock() + 1.25
                repeat
                    local acceptedNow, acceptedWhy = accepted(endFrame, restartButton, beforeText)
                    if acceptedNow then
                        confirmRestart(acceptedWhy)
                        break
                    end
                    task.wait(0.04)
                until os.clock() >= deadline
            else
                warn("[XOMA V39] Auto Retry click failed | " .. tostring(detail))
            end

            control.busy = false
        end
    end)
end

session.endClickBuild = "PASS30-AUTORETRY-VIEWPORT-V39"
print("[XOMA V39] Auto Retry viewport-safe watcher installed")

return session.XOMA
