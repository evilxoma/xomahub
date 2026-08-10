-- XOMA Auto Retry / Auto Back to Lobby real input patch
-- Build: PASS25-ENDSCREEN-VIM-V35
-- The saved EndFrame callbacks can be foreign/hidden connections. firesignal or
-- connection.Function can therefore report success without reaching the real
-- Restart/Return vote. Reuse the proven Ready/Difficulty input path instead:
-- temporarily remove CTDIG from hit-testing, send one real Mouse1 at the game
-- button, then confirm by marker/text/state before another attempt.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
    or type(session.auto) ~= "table"
    or type(session.auto.clickGuiButton) ~= "function"
then
    error("XOMA V35 end-click patch: required CTDIG input/end-action API unavailable")
end

if session.endClickV35Installed == true then
    session.endClickBuild = "PASS25-ENDSCREEN-VIM-V35"
    return session.XOMA
end

local Players = game:GetService("Players")
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

local function visibleInHierarchy(object, playerGui)
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

local function requestAccepted(button, endFrame, markerName)
    if markerExists(endFrame, markerName) then
        return true
    end

    if not button or not button.Parent then
        -- EndFrame/button disappearing immediately after the click is a valid
        -- transition toward teleport/restart; do not click an old reference.
        return true
    end

    local text = tostring(button.Text or "")
    if control.beforeText and text ~= control.beforeText then
        return true
    end

    if button.Active == false then
        return true
    end

    return false
end

local function wantedAction()
    -- V34 makes Auto Retry authoritative. Keep Return compatibility for builds
    -- where forceAutoRetry is not enabled, but never let both paths click.
    if session.forceAutoRetry == true then
        return "Restart", "Restarted", "Auto Retry"
    end

    return nil
end

session.recorder.handleEndAction = function(...)
    -- Preserve result/webhook/end-state logic from the existing handler. Its
    -- signal-based click may be a no-op; V35 performs the authoritative input
    -- immediately afterwards and confirms it independently.
    pcall(originalHandle, ...)

    if not session.alive then
        return
    end

    local actionName, markerName, label = wantedAction()
    if not actionName then
        return
    end

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return
    end

    local endFrame = playerGui:FindFirstChild("EndFrame", true)
    if not endFrame then
        return
    end

    if markerExists(endFrame, markerName) then
        control.key = nil
        control.beforeText = nil
        return
    end

    local button, score = findButton(playerGui, endFrame, actionName)
    if not button or score < 20 or not button.Active then
        return
    end

    local resultValue = player:FindFirstChild("PlayerGameResult")
    local result = resultValue and tostring(resultValue.Value) or ""
    if result ~= "Triumph" and result ~= "Defeat" then
        return
    end

    local key = result .. ":" .. actionName
    if control.key ~= key then
        control.key = key
        control.sentAt = 0
        control.beforeText = nil
        control.attempts = 0
        control.busy = false
    end

    if requestAccepted(button, endFrame, markerName) then
        return
    end

    local now = os.clock()
    if control.sentAt > 0 and now - control.sentAt < 2.5 then
        return
    end

    if control.busy then
        return
    end

    control.busy = true
    control.attempts = control.attempts + 1
    control.beforeText = tostring(button.Text or "")

    local ok, detail = session.auto.clickGuiButton(button)
    control.sentAt = os.clock()

    print(string.format(
        "[XOMA V35] %s click %d | sent=%s | before=%s | %s",
        label,
        control.attempts,
        tostring(ok),
        control.beforeText,
        tostring(detail)
    ))

    -- Give replication a short window. We deliberately do not send another
    -- click in this call: Restart can be a vote/toggle button and double-clicks
    -- could undo an accepted vote.
    local deadline = os.clock() + 0.75
    repeat
        if requestAccepted(button, endFrame, markerName) then
            print("[XOMA V35] " .. label .. " request confirmed")
            break
        end
        task.wait(0.03)
    until os.clock() >= deadline

    control.busy = false
end

session.endClickV35Installed = true
session.endClickBuild = "PASS25-ENDSCREEN-VIM-V35"
print("[XOMA V35] End-screen VIM click-through installed")

return session.XOMA
