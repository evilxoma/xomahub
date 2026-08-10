-- XOMA / CTDIG webhook session-accounting hotfix
-- Build: PASS37-WEBHOOK-SESSION-FIX-V40
-- Scope: WEBHOOK ONLY. Do not touch Auto Retry / Restart / end-click behavior.
--
-- Bug fixed:
-- The older webhook gate treated an off-screen EndFrame button as a live result
-- screen. Because EndFrame/Restart can remain present between rounds, a stale
-- PlayerGameResult (commonly Defeat) could be accounted at bootstrap and the
-- state.accounted flag could then stay true through the real next match. That
-- produced Discord embeds such as title=Triumph but Session=Wins 0/Losses 1,
-- Session Coins/EXP=0 and Avg run=0.
--
-- V40 only forwards Triumph/Defeat to the existing webhook implementation when
-- the exact EndFrame.RoundFrame Restart + Return pair is visible, active AND
-- actually on-screen. During normal gameplay/off-screen transition it explicitly
-- clears only webhook result-state so the next real end screen is accounted once.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.observeWebhookResult) ~= "function" then
    error("XOMA V40 webhook patch: observeWebhookResult unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

-- Keep the previously-installed webhook implementation (including sendWebhook,
-- rewards, farm stats and Discord payload formatting) untouched.
if type(session.webhookOriginalObserveV40) ~= "function" then
    session.webhookOriginalObserveV40 = session.observeWebhookResult
end
local originalObserve = session.webhookOriginalObserveV40

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
    return stopAt == nil or current == stopAt
end

local function buttonOnScreen(button)
    local camera = Workspace.CurrentCamera
    if not button or not button.Parent or not camera then
        return false
    end

    local ok, position, size, viewport = pcall(function()
        return button.AbsolutePosition, button.AbsoluteSize, camera.ViewportSize
    end)
    if not ok
        or typeof(position) ~= "Vector2"
        or typeof(size) ~= "Vector2"
        or typeof(viewport) ~= "Vector2"
        or size.X <= 1
        or size.Y <= 1
        or viewport.X <= 1
        or viewport.Y <= 1
    then
        return false
    end

    local center = position + size / 2
    return center.X >= 0
        and center.Y >= 0
        and center.X < viewport.X
        and center.Y < viewport.Y
end

local function exactLiveResultScreen(endFrame)
    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui
        or not endFrame
        or not endFrame.Parent
        or endFrame.Name ~= "EndFrame"
        or not endFrame:IsA("LayerCollector")
        or endFrame.Enabled ~= true
        or not hierarchyVisible(endFrame, playerGui)
    then
        return false
    end

    local roundFrame = endFrame:FindFirstChild("RoundFrame")
    if not roundFrame or not roundFrame:IsA("GuiObject") or not hierarchyVisible(roundFrame, playerGui) then
        return false
    end

    local restart = roundFrame:FindFirstChild("Restart")
    local returnButton = roundFrame:FindFirstChild("Return")
    if not restart or not restart:IsA("GuiButton")
        or not returnButton or not returnButton:IsA("GuiButton")
    then
        return false
    end

    local function live(button)
        return button.Visible == true
            and button.Active == true
            and hierarchyVisible(button, playerGui)
            and buttonOnScreen(button)
    end

    return live(restart) and live(returnButton)
end

local function clearWebhookEndState()
    local state = session.webhook
    if type(state) ~= "table" then return end

    -- This state belongs only to webhook accounting/delivery. Auto Retry uses
    -- separate endClick* controls and is intentionally not read or modified here.
    state.endActive = false
    state.endResult = nil
    state.endSeenAt = 0
    state.sent = false
    state.busy = false
    state.attempts = 0
    state.nextAttempt = 0
    state.accounted = false
end

local function repairKnownPhantomSummaryOnce()
    if session.webhookPhantomRepairV40 == true then return end
    session.webhookPhantomRepairV40 = true

    local summary = session.farmSession
    if type(summary) ~= "table" then return end

    local runs = tonumber(summary.runs) or 0
    local wins = tonumber(summary.wins) or 0
    local losses = tonumber(summary.losses) or 0
    local coins = tonumber(summary.coins) or 0
    local exp = tonumber(summary.exp) or 0
    local seconds = tonumber(summary.totalGameSeconds) or 0

    -- Strict signature of the stale-bootstrap accounting bug: one or more runs
    -- were counted, but literally no game duration and no rewards were ever
    -- accumulated. Do not touch normal/legitimate session history.
    if runs > 0
        and wins + losses == runs
        and seconds <= 0
        and coins == 0
        and exp == 0
    then
        summary.runs = 0
        summary.wins = 0
        summary.losses = 0
        summary.coins = 0
        summary.exp = 0
        summary.totalGameSeconds = 0
        summary.startedAt = os.time()
        print("[XOMA V40] Webhook phantom session entry repaired")
    end
end

repairKnownPhantomSummaryOnce()
clearWebhookEndState()

session.observeWebhookResult = function(endFrame, result, ...)
    result = tostring(result or "")
    local isResult = result == "Triumph" or result == "Defeat"

    if not isResult or not exactLiveResultScreen(endFrame) then
        -- Let the existing observer update its status text, then force the
        -- accounting latch open for the next real result screen.
        local ok, a, b, c = pcall(originalObserve, nil, nil, ...)
        clearWebhookEndState()
        if not ok then
            warn("[XOMA V40] Webhook reset observer failed | " .. tostring(a))
            return nil
        end
        return a, b, c
    end

    local state = session.webhook
    if type(state) == "table"
        and state.endActive == true
        and state.endResult ~= nil
        and state.endResult ~= result
    then
        -- A changed result on a newly-live screen must never inherit the old
        -- accounted latch. This is webhook-only state and does not affect Restart.
        clearWebhookEndState()
    end

    return originalObserve(endFrame, result, ...)
end

session.webhookBuild = "PASS37-WEBHOOK-SESSION-FIX-V40"
print("[XOMA V40] Webhook session accounting fixed | Auto Retry untouched")

return session.XOMA
