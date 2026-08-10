-- XOMA / CTDIG webhook live end-screen gate
-- Build: PASS29-WEBHOOK-LIVE-ENDSCREEN-V39
-- Accept Triumph/Defeat only when the real EndFrame action UI is actually
-- visible through its full GuiObject/LayerCollector hierarchy. This rejects
-- stale PlayerGameResult/Rewards.Result values at bootstrap without requiring
-- a separate round-clear state machine.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.observeWebhookResult) ~= "function" then
    error("XOMA V39 webhook patch: observeWebhookResult unavailable")
end

local originalObserve = session.observeWebhookResult

local function hierarchyVisible(object)
    local current = object
    while current do
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

local function liveResultScreen(endFrame)
    if not endFrame or not endFrame.Parent or not hierarchyVisible(endFrame) then
        return false
    end

    for _, object in ipairs(endFrame:GetDescendants()) do
        if object:IsA("GuiButton")
            and (object.Name == "Restart" or object.Name == "Return")
            and object.Visible == true
            and object.Active == true
            and object.AbsoluteSize.X > 1
            and object.AbsoluteSize.Y > 1
            and hierarchyVisible(object)
        then
            return true
        end
    end

    return false
end

session.observeWebhookResult = function(endFrame, result, ...)
    result = tostring(result or "")
    local isResult = result == "Defeat" or result == "Triumph"

    if not isResult or not liveResultScreen(endFrame) then
        return originalObserve(nil, nil, ...)
    end

    return originalObserve(endFrame, result, ...)
end

session.webhookBuild = "PASS29-WEBHOOK-LIVE-ENDSCREEN-V39"
print("[XOMA V39] Webhook live-end-screen gate installed")

return session.XOMA
