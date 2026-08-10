-- XOMA Auto Retry / Auto Back to Lobby real input patch
-- Build: PASS25B-ENDSCREEN-VIM-ONLY-V35
-- Restart/Return are vote-style buttons. Never chain hidden connections + VIM:
-- that can double-toggle a successful vote. Let the legacy handler try once,
-- verify whether it REALLY changed the button/marker, and only if it did not,
-- send exactly one VIM Mouse1 while CTDIG is temporarily removed from hit-test.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
then
    error("XOMA V35 end-click patch: CTDIG end-action API unavailable")
end

if session.endClickV35Installed == true then
    session.endClickBuild = "PASS25B-ENDSCREEN-VIM-ONLY-V35"
    return session.XOMA
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local originalHandle = session.recorder.handleEndAction

session.endClickV35 = session.endClickV35 or {
    key = nil,
    sentAt = 0,
    beforeText = nil,
    attempts = 0,
    busy = false,
}
local control = session.endClickV35

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function visibleInHierarchy(object, playerGui)
    local current = object
    while current and current ~= playerGui do
        if current:IsA("GuiObject") and current.Visible == false then return false end
        if current:IsA("LayerCollector") and current.Enabled == false then return false end
        current = current.Parent
    end
    return true
end

local function findButton(playerGui, endFrame, name)
    local best
    local bestScore = -math.huge
    for _, object in ipairs(endFrame:GetDescendants()) do
        if object:IsA("GuiButton") and object.Name == name then
            local score = 0
            if object.Active then score = score + 8 end
            if object.Visible then score = score + 4 end
            if visibleInHierarchy(object, playerGui) then score = score + 16 end
            if object.AbsoluteSize.X > 1 and object.AbsoluteSize.Y > 1 then score = score + 2 end
            if score > bestScore then
                bestScore = score
                best = object
            end
        end
    end
    return best, bestScore
end

local function markerExists(endFrame, markerName)
    return endFrame and endFrame:FindFirstChild(markerName, true) ~= nil
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

    local found = {}
    local seen = {}
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

local function suppressCTDIGOverlay()
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

local function vimOnlyClick(button)
    if not button or not button.Parent or not button:IsA("GuiButton") then
        return false, "button missing"
    end

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
        return false, "player mouse1 is currently held"
    end

    local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
    local restoreOverlay, suppressed = suppressCTDIGOverlay()
    task.wait()

    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.025)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    restoreOverlay()

    if not ok then
        return false, "VIM failed: " .. tostring(err)
    end

    return true, string.format(
        "VIM-only @ %.0f,%.0f | CTDIG screens suppressed=%d",
        center.X,
        center.Y,
        suppressed
    )
end

local function accepted(button, endFrame, markerName, beforeText)
    if markerExists(endFrame, markerName) then return true end
    if not button or not button.Parent then return true end
    if tostring(button.Text or "") ~= tostring(beforeText or "") then return true end
    if button.Active == false then return true end
    return false
end

session.recorder.handleEndAction = function(...)
    if not session.alive then return end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local endFrame = playerGui and playerGui:FindFirstChild("EndFrame", true)
    local button = endFrame and findButton(playerGui, endFrame, "Restart") or nil
    local beforeLegacy = button and tostring(button.Text or "") or nil

    -- Preserve webhook/result/replay-stop behavior. If its legacy signal happens
    -- to work, detect the real state change and DO NOT add a VIM click.
    pcall(originalHandle, ...)

    if not session.alive or session.forceAutoRetry ~= true then return end

    playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    endFrame = playerGui and playerGui:FindFirstChild("EndFrame", true)
    if not endFrame or markerExists(endFrame, "Restarted") then return end

    button = findButton(playerGui, endFrame, "Restart")
    if not button or not button.Active or not visibleInHierarchy(button, playerGui) then return end

    local resultValue = player:FindFirstChild("PlayerGameResult")
    local result = resultValue and tostring(resultValue.Value) or ""
    if result ~= "Triumph" and result ~= "Defeat" then return end

    if beforeLegacy and accepted(button, endFrame, "Restarted", beforeLegacy) then
        print("[XOMA V35] Auto Retry confirmed by legacy handler; VIM not needed")
        return
    end

    local key = result .. ":Restart"
    if control.key ~= key then
        control.key = key
        control.sentAt = 0
        control.beforeText = nil
        control.attempts = 0
        control.busy = false
    end

    if control.beforeText and accepted(button, endFrame, "Restarted", control.beforeText) then
        return
    end

    local now = os.clock()
    if control.sentAt > 0 and now - control.sentAt < 2.5 then return end
    if control.busy then return end

    control.busy = true
    control.attempts = control.attempts + 1
    control.beforeText = tostring(button.Text or "")

    local ok, detail = vimOnlyClick(button)
    control.sentAt = os.clock()
    print(string.format(
        "[XOMA V35] Auto Retry VIM click %d | sent=%s | before=%s | %s",
        control.attempts,
        tostring(ok),
        control.beforeText,
        tostring(detail)
    ))

    local deadline = os.clock() + 0.9
    repeat
        if accepted(button, endFrame, "Restarted", control.beforeText) then
            print("[XOMA V35] Auto Retry request confirmed")
            break
        end
        task.wait(0.03)
    until os.clock() >= deadline

    control.busy = false
end

session.endClickV35Installed = true
session.endClickBuild = "PASS25B-ENDSCREEN-VIM-ONLY-V35"
print("[XOMA V35] End-screen VIM-only click-through installed")
return session.XOMA
