-- XOMA / CTDIG webhook lifecycle gate
-- Build: PASS28-WEBHOOK-HIERARCHY-GATE-V38
-- The end-screen buttons exist for the whole match, but their parent UI is hidden.
-- V36 checked only the button's own Visible/Active state, so sawClearState never
-- became true. V38 checks the full GUI hierarchy before treating EndFrame as live.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.observeWebhookResult) ~= "function" then
    error("XOMA V38 webhook patch: observeWebhookResult unavailable")
end

local Workspace = game:GetService("Workspace")
local originalObserve = session.observeWebhookResult

-- Keep this compatibility field because endclick_v37 reads it.
session.webhookRoundGateV36 = {
    armed = false,
    sawClearState = false,
    lastWave = 0,
    resultConsumed = false,
}
local gate = session.webhookRoundGateV36

local function currentWave()
    local map = Workspace:FindFirstChild("Map")
    local config = map and map:FindFirstChild("Configuration")
    local wave = config and config:FindFirstChild("Wave")
    return wave and tonumber(wave.Value) or 0
end

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

local function endFrameLooksLive(endFrame)
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

local function refreshRoundGate()
    local wave = currentWave()

    -- New round after Restart: wave returns to 0 first.
    if gate.resultConsumed and wave <= 0 then
        gate.resultConsumed = false
        gate.armed = false
        gate.sawClearState = false
    end

    if wave >= 1 and not gate.armed and not gate.resultConsumed then
        gate.armed = true
        gate.sawClearState = false
        print("[XOMA V38] Webhook armed for current round at W" .. tostring(wave))
    end

    gate.lastWave = wave
end

session.observeWebhookResult = function(endFrame, result, ...)
    refreshRoundGate()

    result = tostring(result or "")
    local isResult = result == "Defeat" or result == "Triumph"
    local liveEnd = endFrameLooksLive(endFrame)

    -- During the active match EndFrame/buttons may exist but are hidden by an
    -- ancestor. That is the clean state V36 failed to recognize.
    if not isResult or not liveEnd then
        if gate.armed and not gate.sawClearState then
            gate.sawClearState = true
            print("[XOMA V38] Fresh round clear-state confirmed at W" .. tostring(gate.lastWave))
        end
        return originalObserve(nil, nil, ...)
    end

    if not gate.armed or not gate.sawClearState or gate.resultConsumed then
        return originalObserve(nil, nil, ...)
    end

    gate.resultConsumed = true
    gate.armed = false
    print("[XOMA V38] Webhook result accepted for active round: " .. result)
    return originalObserve(endFrame, result, ...)
end

refreshRoundGate()
session.webhookBuild = "PASS28-WEBHOOK-HIERARCHY-GATE-V38"
print("[XOMA V38] Webhook hierarchy gate installed")

return session.XOMA
