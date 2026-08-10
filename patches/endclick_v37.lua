-- XOMA Auto Retry authoritative end-screen click
-- Build: PASS27-AUTORESTART-RESULT-FALLBACK-V37
-- V35 only trusted PlayerGameResult, while the core also accepts
-- Workspace.WorkspaceScriptService.Rewards.Result. That made V35 return before
-- the VIM click on builds where the authoritative result lives in Rewards.
-- V37 uses both result sources and requires the V36 fresh-round gate before
-- touching Restart, preventing stale bootstrap results from causing a click.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
then
    error("XOMA V37 end-click patch: CTDIG end-action API unavailable")
end

if session.endClickV37Installed == true then
    session.endClickBuild = "PASS27-AUTORESTART-RESULT-FALLBACK-V37"
    return session.XOMA
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
local originalHandle = session.recorder.handleEndAction

session.endClickV37 = {
    key = nil,
    attempts = 0,
    lastAttempt = 0,
    busy = false,
    lastDiag = 0,
}
local control = session.endClickV37

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function hierarchyVisible(object, playerGui)
    local current = object
    while current and current ~= playerGui do
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

local function findRestartButton(playerGui)
    local endFrame = playerGui and playerGui:FindFirstChild("EndFrame", true)
    if not endFrame then
        return nil, nil
    end

    local best
    local bestScore = -math.huge
    for _, object in ipairs(endFrame:GetDescendants()) do
        if object:IsA("GuiButton") and object.Name == "Restart" then
            local score = 0
            if object.Visible then score = score + 4 end
            if object.Active then score = score + 8 end
            if hierarchyVisible(object, playerGui) then score = score + 16 end
            if object.AbsoluteSize.X > 1 and object.AbsoluteSize.Y > 1 then score = score + 2 end
            if score > bestScore then
                bestScore = score
                best = object
            end
        end
    end

    if not best or bestScore < 26 then
        return endFrame, nil
    end
    return endFrame, best
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

local function freshRoundConfirmed()
    local gate = session.webhookRoundGateV36
    if type(gate) ~= "table" then
        return false, "V36 webhook gate missing"
    end
    if gate.resultConsumed == true then
        return true
    end
    return false, string.format(
        "fresh gate not confirmed | armed=%s clear=%s consumed=%s wave=%s",
        tostring(gate.armed),
        tostring(gate.sawClearState),
        tostring(gate.resultConsumed),
        tostring(gate.lastWave)
    )
end

local function findCTDIGScreenGuis()
    local roots = {}
    local gethuiFn = executorFunction("gethui")
    if gethuiFn then
        local ok, hui = pcall(gethuiFn)
        if ok and typeof(hui) == "Instance" then
            roots[#roots + 1] = hui
        end
    end

    local okCore, coreGui = pcall(game.GetService, game, "CoreGui")
    if okCore and coreGui and not table.find(roots, coreGui) then
        roots[#roots + 1] = coreGui
    end

    local result = {}
    local seen = {}
    for _, root in ipairs(roots) do
        for _, object in ipairs(root:GetDescendants()) do
            if (object:IsA("TextLabel") or object:IsA("TextButton"))
                and tostring(object.Text):find("CTDIG", 1, true)
            then
                local screen = object:FindFirstAncestorOfClass("ScreenGui")
                if screen and not seen[screen] then
                    seen[screen] = true
                    result[#result + 1] = screen
                end
            end
        end
    end
    return result
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
        task.wait(0.03)
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
    local beforeFrame, beforeButton = findRestartButton(playerGui)
    local beforeText = beforeButton and tostring(beforeButton.Text or "") or nil

    -- Preserve webhook/result bookkeeping and the core's own handler. V37 only
    -- adds the authoritative physical click if that handler did not change the
    -- real Restart state.
    pcall(originalHandle, ...)

    if not session.alive or session.forceAutoRetry ~= true then
        return
    end

    playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local endFrame, button = findRestartButton(playerGui)
    if not endFrame or not button then
        return
    end

    local fresh, freshWhy = freshRoundConfirmed()
    if not fresh then
        if os.clock() - control.lastDiag >= 3 then
            control.lastDiag = os.clock()
            print("[XOMA V37] Restart waiting | " .. tostring(freshWhy))
        end
        return
    end

    local result, source, playerText, rewardText = readResult()
    if not result then
        if os.clock() - control.lastDiag >= 3 then
            control.lastDiag = os.clock()
            print(string.format(
                "[XOMA V37] Restart waiting | no result | PlayerGameResult=%s | Rewards.Result=%s",
                tostring(playerText),
                tostring(rewardText)
            ))
        end
        return
    end

    -- If the original handler actually worked, do not send a second vote.
    local alreadyAccepted, acceptedWhy = accepted(endFrame, button, beforeText)
    if alreadyAccepted then
        if control.key ~= result .. ":accepted" then
            control.key = result .. ":accepted"
            print("[XOMA V37] Auto Retry already accepted by game | " .. tostring(acceptedWhy))
        end
        return
    end

    local key = result .. ":Restart"
    if control.key ~= key then
        control.key = key
        control.attempts = 0
        control.lastAttempt = 0
        control.busy = false
        print("[XOMA V37] Fresh end detected | result=" .. result .. " | source=" .. source)
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
        "[XOMA V37] Auto Retry VIM click %d | sent=%s | result=%s via %s | before=%s | %s",
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
                print("[XOMA V37] Auto Retry confirmed | " .. tostring(why))
                break
            end
            task.wait(0.03)
        until os.clock() >= deadline
    end

    control.busy = false
end

session.endClickV37Installed = true
session.endClickBuild = "PASS27-AUTORESTART-RESULT-FALLBACK-V37"
print("[XOMA V37] Auto Restart result-fallback VIM installed")

return session.XOMA
