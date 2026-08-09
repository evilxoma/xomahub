-- XOMA Auto Retry / Auto Back to Lobby end-screen gate
-- Build: PASS21-ENDSCREEN-GATE-V31
-- Never let stale result values stop an active replay. The original end-action
-- handler is allowed to run only when a real, visible, active EndFrame action
-- button exists (or the game already created its completion marker).

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.recorder) ~= "table"
    or type(session.recorder.handleEndAction) ~= "function"
then
    error("XOMA V31 end-action patch: handleEndAction is unavailable")
end

if session.endActionV31Installed == true then
    session.endActionBuild = "PASS21-ENDSCREEN-GATE-V31"
    return session.XOMA
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local originalEndAction = session.recorder.handleEndAction

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

local function liveEndActionPresent(playerGui, endFrame)
    if not playerGui or not endFrame then
        return false
    end

    for _, object in ipairs(endFrame:GetDescendants()) do
        if object:IsA("GuiButton")
            and (object.Name == "Restart" or object.Name == "Return")
            and object.Active == true
            and object.AbsoluteSize.X > 1
            and object.AbsoluteSize.Y > 1
            and hierarchyVisible(object, playerGui)
        then
            return true
        end
    end

    return false
end

session.recorder.handleEndAction = function(...)
    if not session.alive then
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

    local completed = endFrame:FindFirstChild("Restarted", true)
        or endFrame:FindFirstChild("Teleported", true)

    if not completed and not liveEndActionPresent(playerGui, endFrame) then
        return
    end

    return originalEndAction(...)
end

session.endActionV31Installed = true
session.endActionBuild = "PASS21-ENDSCREEN-GATE-V31"
print("[XOMA V31] End-action gate installed")

return session.XOMA
