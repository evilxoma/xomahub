-- XOMA / CTDIG webhook lifecycle gate
-- Build: PASS26-WEBHOOK-ROUND-GATE-V36
-- Ignore stale Triumph/Defeat values and stale EndFrame state at bootstrap or
-- immediately after Restart. A webhook result is accepted only after this
-- client has observed the CURRENT round actually reach Wave >= 1.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.observeWebhookResult) ~= "function" then
    error("XOMA V36 webhook patch: observeWebhookResult unavailable")
end

if session.webhookV36Installed == true then
    session.webhookBuild = "PASS26-WEBHOOK-ROUND-GATE-V36"
    return session.XOMA
end

local Workspace = game:GetService("Workspace")
local originalObserve = session.observeWebhookResult

session.webhookRoundGateV36 = {
    armed = false,
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

local function endFrameLooksLive(endFrame)
    if not endFrame or not endFrame.Parent then
        return false
    end

    if endFrame:IsA("LayerCollector") and endFrame.Enabled == false then
        return false
    end

    for _, object in ipairs(endFrame:GetDescendants()) do
        if object:IsA("GuiButton")
            and (object.Name == "Restart" or object.Name == "Return")
            and object.Visible == true
            and object.Active == true
            and object.AbsoluteSize.X > 1
            and object.AbsoluteSize.Y > 1
        then
            return true
        end
    end

    return false
end

local function refreshRoundGate()
    local wave = currentWave()

    -- A real active round has now been observed. This is deliberately stricter
    -- than checking PlayerGameResult because that Value can stay stale from a
    -- previous round during bootstrap/restart.
    if wave >= 1 and not gate.armed then
        gate.armed = true
        gate.resultConsumed = false
        print("[XOMA V36] Webhook armed for current round at W" .. tostring(wave))
    end

    -- Restart returns the wave to pre-game. Once a result has been consumed,
    -- keep webhook disarmed until the NEXT round reaches W1.
    if gate.resultConsumed and wave <= 0 then
        gate.armed = false
    end

    gate.lastWave = wave
end

session.observeWebhookResult = function(endFrame, result, ...)
    refreshRoundGate()

    result = tostring(result or "")
    local isResult = result == "Defeat" or result == "Triumph"

    if not isResult then
        -- Preserve the original observer's idle/reset behavior, but never feed
        -- it a stale result while the current round is not armed.
        return originalObserve(nil, nil, ...)
    end

    if not gate.armed then
        return originalObserve(nil, nil, ...)
    end

    if gate.resultConsumed then
        return
    end

    if not endFrameLooksLive(endFrame) then
        return originalObserve(nil, nil, ...)
    end

    gate.resultConsumed = true
    gate.armed = false
    print("[XOMA V36] Webhook result accepted for active round: " .. result)
    return originalObserve(endFrame, result, ...)
end

-- Heartbeat is unnecessary; handleEndAction already calls the observer often.
-- Still seed the gate if V36 was injected mid-match after W1.
refreshRoundGate()

session.webhookV36Installed = true
session.webhookBuild = "PASS26-WEBHOOK-ROUND-GATE-V36"
print("[XOMA V36] Webhook stale-result gate installed")

return session.XOMA
