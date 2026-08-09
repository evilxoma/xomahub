-- XOMA pre-game Ready / Difficulty / W0 / end-action guard patch
-- Build: PASS21-ENDSCREEN-GATE-V31
-- Ready and difficulty use authoritative replicated Voting state for confirmation.
-- Runtime scans show the real voting connection is hidden while the exposed
-- second MouseButton1Down connection is cosmetic. Prefer the hidden connection
-- in its own state; fall back to a coordinate-only VirtualInputManager Mouse1
-- event. Never move the cursor, send keyboard input, or use VirtualUser.
-- W0 actions begin immediately after Ready + Difficulty confirmation, while the
-- voting/countdown phase is still active, matching how Recorder labels pre-wave actions.
-- Auto Retry / Auto Back to Lobby are gated by a genuinely visible/active end-screen
-- action button so stale PlayerGameResult values cannot stop replay mid-match.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA V31 ready patch: CTDIG session is unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function safeConnectionField(connection, field)
    local ok, value = pcall(function()
        return connection[field]
    end)
    return ok and value or nil
end

local function buttonCenter(button)
    return button.AbsolutePosition + (button.AbsoluteSize / 2)
end

local function difficultyConfirmedName(difficulty)
    local voting = Workspace:FindFirstChild("Voting")
    local votes = voting and voting:FindFirstChild("DifficultyVotes")
    local folder = votes and votes:FindFirstChild(tostring(difficulty))
    return folder and player and folder:FindFirstChild(player.Name) ~= nil or false
end

local function difficultyConfirmed(button)
    if not button or not button.Parent or button.Parent.Name ~= "DifficultyHolder" then
        return false
    end
    return difficultyConfirmedName(button.Name)
end

local function buttonConfirmed(button)
    if not button then
        return false
    end

    if button.Name == "WaitingRoom" then
        local voting = Workspace:FindFirstChild("Voting")
        local done = voting and voting:FindFirstChild("WaitingRoomDone")
        return done and done.Value == true or false
    end

    return difficultyConfirmed(button)
end

local function hiddenConnectionSummary(connection, index)
    local fn = safeConnectionField(connection, "Function")
    local foreign = safeConnectionField(connection, "ForeignState")
    local luaConnection = safeConnectionField(connection, "LuaConnection")

    return string.format(
        "#%d fn=%s foreign=%s lua=%s",
        index,
        tostring(fn ~= nil),
        tostring(foreign),
        tostring(luaConnection)
    )
end

local function shouldTreatAsHidden(connection)
    local fn = safeConnectionField(connection, "Function")
    local foreign = safeConnectionField(connection, "ForeignState")
    local luaConnection = safeConnectionField(connection, "LuaConnection")

    if fn == nil then
        return true
    end
    if foreign == true then
        return true
    end
    if luaConnection == false then
        return true
    end
    return false
end

local function deferHiddenMouseDown(button)
    local getconnections = executorFunction("getconnections")
    if not getconnections then
        return false, "getconnections unavailable"
    end

    local ok, connections = pcall(getconnections, button.MouseButton1Down)
    if not ok or type(connections) ~= "table" then
        return false, "MouseButton1Down connections unavailable"
    end

    local center = buttonCenter(button)
    local tried = 0
    local details = {}

    for index, connection in ipairs(connections) do
        if shouldTreatAsHidden(connection) then
            tried = tried + 1
            details[#details + 1] = hiddenConnectionSummary(connection, index)

            local defer = safeConnectionField(connection, "Defer")
            local fired = false
            if type(defer) == "function" then
                fired = pcall(function()
                    defer(connection, center.X, center.Y)
                end)
            end

            if not fired then
                local fire = safeConnectionField(connection, "Fire")
                if type(fire) == "function" then
                    fired = pcall(function()
                        fire(connection, center.X, center.Y)
                    end)
                end
            end

            if fired then
                local deadline = os.clock() + 0.35
                repeat
                    if buttonConfirmed(button) then
                        return true,
                            "hidden connection confirmed | "
                                .. hiddenConnectionSummary(connection, index)
                    end
                    task.wait(0.03)
                until os.clock() >= deadline
            end
        end
    end

    return false,
        "hidden tried=" .. tostring(tried)
            .. (#details > 0 and (" | " .. table.concat(details, ", ")) or "")
end

local function getVim()
    local ok, service = pcall(game.GetService, game, "VirtualInputManager")
    if ok and service then
        return service
    end
    return nil
end

local function sendVimMouse1(button)
    local vim = getVim()
    if not vim then
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

    local center = buttonCenter(button)
    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.025)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    if not ok then
        return false, "VIM Mouse1 failed: " .. tostring(err)
    end

    local deadline = os.clock() + 0.45
    repeat
        if buttonConfirmed(button) then
            return true,
                string.format("VIM confirmed @ %.0f,%.0f", center.X, center.Y)
        end
        task.wait(0.03)
    until os.clock() >= deadline

    return false,
        string.format("VIM sent, not yet confirmed @ %.0f,%.0f", center.X, center.Y)
end

function session.auto.clickGuiButton(button)
    if not button or not button:IsA("GuiButton") then
        return false, "button missing"
    end
    if button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then
        return false, "button has no screen size"
    end

    if buttonConfirmed(button) then
        session.auto.lastGuiClickMethod = "already confirmed"
        return true, session.auto.lastGuiClickMethod
    end

    local directOk, directDetail = deferHiddenMouseDown(button)
    if directOk or buttonConfirmed(button) then
        session.auto.lastGuiClickMethod = directDetail
        return true, directDetail
    end

    local vimOk, vimDetail = sendVimMouse1(button)
    local detail = tostring(directDetail) .. " | " .. tostring(vimDetail)
    session.auto.lastGuiClickMethod = detail
    return vimOk or buttonConfirmed(button), detail
end

function session.auto.autoReadyVoting(timeout)
    local voting = Workspace:FindFirstChild("Voting") or Workspace:WaitForChild("Voting", 10)
    if not voting then
        return true
    end

    local waitingDone = voting:FindFirstChild("WaitingRoomDone")
        or voting:WaitForChild("WaitingRoomDone", 5)
    if not waitingDone or waitingDone.Value == true then
        return true
    end

    local gui = player and (
        player:FindFirstChildOfClass("PlayerGui")
        or player:WaitForChild("PlayerGui", 8)
    )
    local votingGui = gui and (
        gui:FindFirstChild("VotingGui")
        or gui:WaitForChild("VotingGui", 8)
    )
    if not votingGui then
        return false, "VotingGui missing"
    end

    local readyButton = votingGui:FindFirstChild("WaitingRoom")
        or votingGui:WaitForChild("WaitingRoom", 5)
    if not readyButton or not readyButton:IsA("GuiButton") then
        return false, "WaitingRoom button missing"
    end

    local deadline = os.clock() + (tonumber(timeout) or 15)
    local attempts = 0
    local nextAttempt = 0

    while session.alive and os.clock() < deadline do
        if waitingDone.Value == true then
            print(
                "[XOMA V31] Ready Up confirmed after "
                    .. tostring(attempts) .. " attempts"
            )
            return true
        end

        if readyButton.Visible and os.clock() >= nextAttempt then
            attempts = attempts + 1
            local okClick, detail = session.auto.clickGuiButton(readyButton)
            print(
                "[XOMA V31] Ready Up attempt " .. tostring(attempts)
                    .. " | ok=" .. tostring(okClick)
                    .. " | " .. tostring(detail)
            )

            if waitingDone.Value == true then
                return true
            end

            nextAttempt = os.clock() + 0.9
        end

        task.wait(0.06)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

function session.auto.autoSelectDifficulty(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting") or Workspace:WaitForChild("Voting", 10)
    if not voting then
        return true
    end

    local wanted, explicit = session.auto.strategyDifficulty(macro)
    if difficultyConfirmedName(wanted) then
        return true
    end

    local gui = player and (
        player:FindFirstChildOfClass("PlayerGui")
        or player:WaitForChild("PlayerGui", 8)
    )
    local votingGui = gui and (
        gui:FindFirstChild("VotingGui")
        or gui:WaitForChild("VotingGui", 8)
    )
    if not votingGui then
        return false, "VotingGui missing"
    end

    local startValue = voting:FindFirstChild("Start")
    local difficultyValue = Workspace:FindFirstChild("Difficulty")
    local deadline = os.clock() + (tonumber(timeout) or 15)
    local attempts = 0
    local nextAttempt = 0

    while session.alive and os.clock() < deadline do
        if difficultyConfirmedName(wanted) then
            print(
                "[XOMA V31] Difficulty " .. tostring(wanted)
                    .. " confirmed after " .. tostring(attempts) .. " attempts"
            )
            return true
        end

        if startValue and startValue.Value == true then
            local current = difficultyValue and tostring(difficultyValue.Value) or ""
            if not explicit or current == wanted then
                return true
            end
            return false,
                "voting closed on " .. tostring(current)
                    .. ", wanted " .. tostring(wanted)
        end

        local holder = votingGui:FindFirstChild("DifficultyHolder")
        local button = holder and holder:FindFirstChild(wanted)

        if button
            and button:IsA("GuiButton")
            and button.Visible
            and button.Selectable ~= false
            and os.clock() >= nextAttempt
        then
            attempts = attempts + 1
            local okClick, detail = session.auto.clickGuiButton(button)
            print(
                "[XOMA V31] Difficulty " .. tostring(wanted)
                    .. " attempt " .. tostring(attempts)
                    .. " | ok=" .. tostring(okClick)
                    .. " | " .. tostring(detail)
            )

            if difficultyConfirmedName(wanted) then
                return true
            end

            nextAttempt = os.clock() + 0.9
        end

        task.wait(0.06)
    end

    if difficultyConfirmedName(wanted) then
        return true
    end

    return false,
        "difficulty vote was not confirmed: " .. tostring(wanted)
            .. " | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

-- This override intentionally lives in the ready patch because player_v20 already
-- fetches this file in sessions where an older cached ctdui.lua may not know about
-- the standalone W0 patch. W0 means the voting/countdown pre-wave phase.
function session.auto.waitForPregameFinished(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA V31] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    print("[XOMA V31] Ready + difficulty confirmed | starting W0 replay during pre-game")
    return true
end

-- Core's old handleEndAction reads PlayerGameResult before proving the result UI
-- is live and stops replay before checking the button. A stale Triumph/Defeat can
-- therefore kill a new replay. Gate the original handler behind a genuinely live
-- Restart/Return button (or an already-confirmed end marker).
do
    local originalEndAction = session.recorder and session.recorder.handleEndAction

    if type(originalEndAction) == "function" then
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

        local function liveEndActionPresent(playerGui)
            if not playerGui then
                return false
            end

            for _, object in ipairs(playerGui:GetDescendants()) do
                if object:IsA("GuiButton")
                    and (object.Name == "Restart" or object.Name == "Return")
                    and object:FindFirstAncestor("EndFrame")
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

        session.recorder.handleEndAction = function()
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

            local alreadyConfirmed = endFrame:FindFirstChild("Restarted", true)
                or endFrame:FindFirstChild("Teleported", true)

            if not alreadyConfirmed and not liveEndActionPresent(playerGui) then
                return
            end

            return originalEndAction()
        end
    end
end

session.readyBuild = "PASS21-ENDSCREEN-GATE-V31"
session.w0Build = "PASS21-ENDSCREEN-GATE-V31"
session.endActionBuild = "PASS21-ENDSCREEN-GATE-V31"
return session.XOMA
