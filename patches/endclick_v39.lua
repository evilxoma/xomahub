-- XOMA Auto Retry authoritative visible-button click
-- Build: PASS29-AUTORESTART-LIVE-BUTTON-V39
-- Do not depend on webhook round state. A stale result is harmless unless the
-- real Restart button is visible through its full hierarchy. If it is visible
-- and the game reports Triumph/Defeat, send one real VIM Mouse1 click.

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
    key = nil,
    attempts = 0,
    lastAttempt = 0,
    busy = false,
    lastDiag = 0,
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

local function findLiveRestart(playerGui)
    if not playerGui then return nil, nil end

    local bestFrame
    local bestButton
    local bestScore = -math.huge

    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") and object.Name == "Restart" then
            local endFrame = object:FindFirstAncestor("EndFrame")
            if endFrame then
                local score = 0
                if object.Visible then score = score + 4 end
                if object.Active then score = score + 8 end
                if object.AbsoluteSize.X > 1 and object.AbsoluteSize.Y > 1 then score = score + 2 end
                if hierarchyVisible(object, playerGui) then score = score + 32 end
                if hierarchyVisible(endFrame, playerGui) then score = score + 16 end
                if score > bestScore then
                    bestScore = score
                    bestFrame = endFrame
                    bestButton = object
                end
            end
        end
    end

    if not bestButton or bestScore < 62 then
        return nil, nil
    end
    return bestFrame, bestButton
end

local function readResult()
    local playerResult = player and player:FindFirstChild("PlayerGameResult")
    local playerText = playerResult and tostring(playerResult.Value) or ""
    if playerText == "Triumph" or playerText == "Defeat" then
        return playerText, "PlayerGameResult", playerText, ""
    end

    local service = Workspace:FindFirstChild("WorkspaceScriptService")
    local rewards = service and service:FindFirstChild("Rewards")
    local rewardResult = rewards and rewards:FindFirstChild("Result")
    local rewardText = rewardResult and tostring(rewardResult.Value) or ""
    if rewardText == "Triumph" or rewardText == "Defeat" then
        return rewardText, "WorkspaceScriptService.Rewards.Result", playerText, rewardText
    end

    return nil, nil, playerText, rewardText
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
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.035)
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

local function accepted(endFrame, button, beforeText)
    if endFrame and endFrame:FindFirstChild("Restarted", true) then
        return true, "Restarted marker"
    end
    if not button or not button.Parent then
        return true, "Restart button disappeared"
    end
    if button.Active == false then
        return true, "Restart button inactive"
    end
    local currentText = tostring(button.Text or "")
    if beforeText and currentText ~= beforeText then
        return true, "text changed: " .. beforeText .. " -> " .. currentText
    end
    return false
end

session.recorder.handleEndAction = function(...)
    if not session.alive then return end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local beforeFrame, beforeButton = findLiveRestart(playerGui)
    local beforeText = beforeButton and tostring(beforeButton.Text or "") or nil

    -- Keep core webhook/result bookkeeping. If its old signal click happens to
    -- work, the state-change check below prevents a second physical click.
    pcall(originalHandle, ...)

    if not session.alive or session.forceAutoRetry ~= true then return end

    playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local endFrame, button = findLiveRestart(playerGui)
    if not endFrame or not button then
        return
    end

    local result, source, playerText, rewardText = readResult()
    if not result then
        if os.clock() - control.lastDiag >= 3 then
            control.lastDiag = os.clock()
            print(string.format(
                "[XOMA V39] Restart visible but result missing | PlayerGameResult=%s | Rewards.Result=%s",
                tostring(playerText),
                tostring(rewardText)
            ))
        end
        return
    end

    local alreadyAccepted, whyAccepted = accepted(endFrame, button, beforeText)
    if alreadyAccepted then
        local acceptedKey = result .. ":accepted"
        if control.key ~= acceptedKey then
            control.key = acceptedKey
            print("[XOMA V39] Auto Retry already accepted | " .. tostring(whyAccepted))
        end
        return
    end

    local key = result .. ":Restart"
    if control.key ~= key then
        control.key = key
        control.attempts = 0
        control.lastAttempt = 0
        control.busy = false
        print("[XOMA V39] Live Restart detected | result=" .. result .. " | source=" .. source)
    end

    local now = os.clock()
    if control.busy or (control.lastAttempt > 0 and now - control.lastAttempt < 2.5) then
        return
    end

    control.busy = true
    control.attempts = control.attempts + 1
    local clickBefore = tostring(button.Text or "")
    local ok, detail = vimClick(button)
    control.lastAttempt = os.clock()

    print(string.format(
        "[XOMA V39] Auto Retry VIM click %d | sent=%s | result=%s via %s | before=%s | %s",
        control.attempts,
        tostring(ok),
        result,
        source,
        clickBefore,
        tostring(detail)
    ))

    if ok then
        local deadline = os.clock() + 0.9
        repeat
            local done, why = accepted(endFrame, button, clickBefore)
            if done then
                print("[XOMA V39] Auto Retry confirmed | " .. tostring(why))
                break
            end
            task.wait(0.03)
        until os.clock() >= deadline
    end

    control.busy = false
end

session.endClickBuild = "PASS29-AUTORESTART-LIVE-BUTTON-V39"
print("[XOMA V39] Auto Restart live-button VIM installed")

return session.XOMA
