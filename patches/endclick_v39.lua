-- XOMA Auto Retry authoritative end-screen watcher
-- Build: PASS29C-AUTORESTART-ENDSCREEN-V39
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
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
local originalHandle = session.recorder.handleEndAction

session.endClickV39 = {
    endFrame = nil,
    restart = nil,
    attempts = 0,
    lastAttempt = 0,
    busy = false,
    confirmed = false,
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

local function liveButton(button, playerGui)
    return button
        and button:IsA("GuiButton")
        and button.Visible == true
        and button.AbsoluteSize.X > 1
        and button.AbsoluteSize.Y > 1
        and hierarchyVisible(button, playerGui)
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
    if not playerGui then return nil, nil, nil end

    local byFrame = {}
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") then
            local endFrame = object:FindFirstAncestor("EndFrame")
            if endFrame and hierarchyVisible(endFrame, playerGui) and liveButton(object, playerGui) then
                local entry = byFrame[endFrame]
                if not entry then
                    entry = { restart = nil, returnButton = nil }
                    byFrame[endFrame] = entry
                end
                if looksLikeRestart(object) then
                    entry.restart = object
                elseif looksLikeReturn(object) then
                    entry.returnButton = object
                end
            end
        end
    end

    for endFrame, entry in pairs(byFrame) do
        if entry.restart and entry.returnButton then
            return endFrame, entry.restart, entry.returnButton
        end
    end

    return nil, nil, nil
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
    local gethuiFn = executorFunction("gethui")
    if gethuiFn then
        local ok, hui = pcall(gethuiFn)
        if ok and typeof(hui) == "Instance" then roots[#roots + 1] = hui end
    end

    local okCore, coreGui = pcall(game.GetService, game, "CoreGui")
    if okCore and coreGui and not table.find(roots, coreGui) then
        roots[#roots + 1] = coreGui
    end

    local found, seen = {}, {}
    for _, root in ipairs(roots) do
        for _, object in ipairs(root:GetDescendants()) do
            if (object:IsA("TextLabel") or object:IsA("TextButton"))
                and tostring(object.Text):find("CTDIG", 1, true)
            then
                local screen = object:FindFirstAncestorOfClass("ScreenGui")
                if screen and not seen[screen] then
                    seen[screen] = true
                    found[#found + 1] = screen
                end
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

local function accepted(endFrame, button, beforeText)
    if endFrame and endFrame.Parent and endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end
    if not button or not button.Parent then
        return true, "Restart button disappeared"
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui and not hierarchyVisible(button, playerGui) then
        return true, "Restart button hidden"
    end

    local currentText = buttonText(button)
    local votes, required = currentText:match("%((%d+)%s*/%s*(%d+)%)")
    if votes and required and tonumber(votes) and tonumber(votes) > 0 then
        return true, "restart vote=" .. tostring(votes) .. "/" .. tostring(required)
    end

    if beforeText ~= "" and currentText ~= "" and currentText ~= beforeText then
        return true, "text changed: " .. beforeText .. " -> " .. currentText
    end

    return false
end

local function vimClick(button)
    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then
        return false, "VirtualInputManager unavailable"
    end

    local heldOk, held = pcall(
        UserInputService.IsMouseButtonPressed,
        UserInputService,
        Enum.UserInputType.MouseButton1
    )
    if heldOk and held == true then
        return false, "physical Mouse1 held"
    end

    local center = button.AbsolutePosition + button.AbsoluteSize / 2
    local restore, suppressed = suppressCTDIG()
    task.wait()

    local ok, err = pcall(function()
        pcall(function()
            vim:SendMouseMoveEvent(center.X, center.Y, game)
        end)
        task.wait(0.03)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.05)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    restore()

    if not ok then
        return false, "VIM failed: " .. tostring(err)
    end

    return true, string.format(
        "VIM @ %.0f,%.0f | CTDIG suppressed=%d",
        center.X,
        center.Y,
        suppressed
    )
end

local function resetControl()
    control.endFrame = nil
    control.restart = nil
    control.attempts = 0
    control.lastAttempt = 0
    control.busy = false
    control.confirmed = false
end

-- The old core handler is allowed during normal gameplay. Once the REAL end
-- screen is present (Restart + Exit to Lobby together), this watcher owns
-- Restart so the old signal-based click cannot race the physical VIM click.
session.recorder.handleEndAction = function(...)
    if not session.alive then return end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local endFrame, restartButton = findLiveEndActions(playerGui)
    if endFrame and restartButton and session.forceAutoRetry == true then
        local result = readResult()
        if result and type(session.observeWebhookResult) == "function" then
            pcall(session.observeWebhookResult, endFrame, result)
        end
        return
    end

    return originalHandle(...)
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
            local endFrame, restartButton, returnButton = findLiveEndActions(playerGui)
            if not endFrame or not restartButton or not returnButton then
                if control.endFrame ~= nil then
                    resetControl()
                end
                continue
            end

            if control.endFrame ~= endFrame or control.restart ~= restartButton then
                resetControl()
                control.endFrame = endFrame
                control.restart = restartButton
                print(
                    "[XOMA V39] Real end screen detected | Restart=" .. buttonText(restartButton)
                        .. " | Return=" .. buttonText(returnButton)
                )
            end

            local beforeText = buttonText(restartButton)
            local done, why = accepted(endFrame, restartButton, beforeText)
            if done then
                if not control.confirmed then
                    control.confirmed = true
                    print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
                end
                continue
            end

            if control.confirmed or control.busy then
                continue
            end

            local now = os.clock()
            if control.lastAttempt > 0 and now - control.lastAttempt < 2.5 then
                continue
            end

            control.busy = true
            control.attempts = control.attempts + 1
            local ok, detail = vimClick(restartButton)
            control.lastAttempt = os.clock()

            print(string.format(
                "[XOMA V39] Auto Retry end-screen click %d | sent=%s | before=%s | %s",
                control.attempts,
                tostring(ok),
                beforeText,
                tostring(detail)
            ))

            if ok then
                local deadline = os.clock() + 1.0
                repeat
                    local acceptedNow, acceptedWhy = accepted(endFrame, restartButton, beforeText)
                    if acceptedNow then
                        control.confirmed = true
                        print("[XOMA V39] Auto Retry confirmed | " .. tostring(acceptedWhy))
                        break
                    end
                    task.wait(0.04)
                until os.clock() >= deadline
            end

            control.busy = false
        end
    end)
end

session.endClickBuild = "PASS29C-AUTORESTART-ENDSCREEN-V39"
print("[XOMA V39] Auto Retry real-end-screen watcher installed")

return session.XOMA
