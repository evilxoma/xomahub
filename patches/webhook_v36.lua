-- XOMA / CTDIG webhook lifecycle gate
-- Build: PASS26B-WEBHOOK-FRESH-ROUND-GATE-V36
-- Ignore stale Triumph/Defeat values and stale EndFrame state at bootstrap or
-- immediately after Restart. A webhook result is accepted only after this
-- client has observed the CURRENT round reach Wave >= 1 and also observed a
-- clean no-result-screen state for that round.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.observeWebhookResult) ~= "function" then
    error("XOMA V36 webhook patch: observeWebhookResult unavailable")
end

if session.webhookV36Installed == true then
    session.webhookBuild = "PASS26B-WEBHOOK-FRESH-ROUND-GATE-V36"
    return session.XOMA
end

local Workspace = game:GetService("Workspace")
local originalObserve = session.observeWebhookResult

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

    if wave >= 1 and not gate.armed and not gate.resultConsumed then
        gate.armed = true
        gate.sawClearState = false
        print("[XOMA V36] Webhook armed for current round at W" .. tostring(wave))
    end

    -- A consumed result stays disarmed through Restart/pre-game. When the next
    -- round actually reaches W1, allow it to arm again.
    if gate.resultConsumed and wave <= 0 then
        gate.resultConsumed = false
        gate.armed = false
        gate.sawClearState = false
    end

    gate.lastWave = wave
end

session.observeWebhookResult = function(endFrame, result, ...)
    refreshRoundGate()

    result = tostring(result or "")
    local isResult = result == "Defeat" or result == "Triumph"

    if not isResult or not endFrameLooksLive(endFrame) then
        if gate.armed then
            gate.sawClearState = true
        end
        return originalObserve(nil, nil, ...)
    end

    -- Stale PlayerGameResult/EndFrame from bootstrap cannot pass this gate. The
    -- current round must first have reached W1 and then been observed with no
    -- live result screen at least once.
    if not gate.armed or not gate.sawClearState or gate.resultConsumed then
        return originalObserve(nil, nil, ...)
    end

    gate.resultConsumed = true
    gate.armed = false
    print("[XOMA V36] Webhook result accepted for active round: " .. result)
    return originalObserve(endFrame, result, ...)
end

refreshRoundGate()

session.webhookV36Installed = true
session.webhookBuild = "PASS26B-WEBHOOK-FRESH-ROUND-GATE-V36"
print("[XOMA V36] Webhook fresh-round gate installed")

return session.XOMA
