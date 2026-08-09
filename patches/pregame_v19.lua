-- XOMA pre-game / voting patch
-- Build: PASS9-PREGAME-READY-V19
-- Loaded after PASS7 AutoExec. Keeps existing XOMA strategy syntax compatible.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA V19 patch: CTDIG session is unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

session.replayBuild = "PASS9-PREGAME-READY-V19"
session.autoBuild = "PASS9-PREGAME-READY-V19"

function session.auto.normalizeDifficulty(value)
    value = tostring(value or "")
    local aliases = {
        easy = "Easy",
        normal = "Normal",
        hard = "Hard",
        insane = "Insane",
        nightmare = "Nightmare",
    }
    return aliases[string.lower(value)] or value
end

function session.auto.strategyDifficulty(macro)
    local explicit = type(macro) == "table"
        and type(macro.difficulty) == "string"
        and macro.difficulty ~= ""

    local preflight = environment.XOMA_AUTOEXEC_PREFLIGHT
    if not explicit and type(preflight) == "table"
        and type(preflight.Difficulty) == "string"
        and preflight.Difficulty ~= ""
    then
        return session.auto.normalizeDifficulty(preflight.Difficulty), true
    end

    if explicit then
        return session.auto.normalizeDifficulty(macro.difficulty), true
    end

    local current = Workspace:FindFirstChild("Difficulty")
    local currentValue = current and tostring(current.Value) or ""
    if currentValue ~= "" and currentValue ~= "None" then
        return session.auto.normalizeDifficulty(currentValue), false
    end

    return "Normal", false
end

function session.auto.clickGuiButton(button)
    if not button or not button:IsA("GuiButton") then
        return false, "button missing"
    end

    if button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then
        return false, "button has no screen size"
    end

    local center = button.AbsolutePosition + (button.AbsoluteSize / 2)

    local vimOk, vim = pcall(game.GetService, game, "VirtualInputManager")
    if vimOk and vim then
        local ok = pcall(function()
            vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
            task.wait()
            vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        end)
        if ok then
            return true
        end
    end

    local vuOk, virtualUser = pcall(game.GetService, game, "VirtualUser")
    if vuOk and virtualUser then
        local ok = pcall(function()
            local camera = Workspace.CurrentCamera
            local cf = camera and camera.CFrame or CFrame.new()
            virtualUser:Button1Down(center, cf)
            task.wait()
            virtualUser:Button1Up(center, cf)
        end)
        if ok then
            return true
        end
    end

    if typeof(firesignal) == "function" then
        local ok = pcall(function()
            firesignal(button.MouseButton1Click)
        end)
        if ok then
            return true
        end
    end

    return false, "no usable GUI click method"
end

function session.auto.playerHasDifficultyVote(voting, difficulty)
    local votes = voting and voting:FindFirstChild("DifficultyVotes")
    local folder = votes and votes:FindFirstChild(difficulty)
    return folder and folder:FindFirstChild(player.Name) ~= nil or false
end

function session.auto.autoReadyVoting(timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local waitingDone = voting:FindFirstChild("WaitingRoomDone")
    if not waitingDone or waitingDone.Value == true then
        return true
    end

    local gui = player:FindFirstChildOfClass("PlayerGui")
    local votingGui = gui and gui:FindFirstChild("VotingGui")
    if not votingGui then
        votingGui = gui and gui:WaitForChild("VotingGui", 8)
    end
    if not votingGui then
        return false, "VotingGui missing"
    end

    local readyButton = votingGui:FindFirstChild("WaitingRoom")
    local deadline = os.clock() + (tonumber(timeout) or 12)
    local lastClick = 0

    while session.alive and os.clock() < deadline do
        if waitingDone.Value == true then
            return true
        end

        if readyButton and readyButton:IsA("GuiButton")
            and readyButton.Visible
            and os.clock() - lastClick >= 0.55
        then
            session.auto.clickGuiButton(readyButton)
            lastClick = os.clock()
        end

        task.wait(0.1)
    end

    return waitingDone.Value == true, "ready vote was not confirmed"
end

function session.auto.autoSelectDifficulty(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local wanted, explicit = session.auto.strategyDifficulty(macro)
    local startValue = voting:FindFirstChild("Start")
    local difficultyValue = Workspace:FindFirstChild("Difficulty")

    if session.auto.playerHasDifficultyVote(voting, wanted) then
        return true
    end

    local gui = player:FindFirstChildOfClass("PlayerGui")
    local votingGui = gui and gui:FindFirstChild("VotingGui")
    if not votingGui then
        votingGui = gui and gui:WaitForChild("VotingGui", 8)
    end
    if not votingGui then
        return false, "VotingGui missing"
    end

    local holder = votingGui:FindFirstChild("DifficultyHolder")
    local button = holder and holder:FindFirstChild(wanted)
    local countdownGui = votingGui:FindFirstChild("Countdown")
    local buttonsReady = countdownGui and countdownGui:FindFirstChild("ButtonsReady")
    local deadline = os.clock() + (tonumber(timeout) or 12)
    local lastClick = 0

    while session.alive and os.clock() < deadline do
        if session.auto.playerHasDifficultyVote(voting, wanted) then
            return true
        end

        if startValue and startValue.Value == true then
            local current = difficultyValue and tostring(difficultyValue.Value) or ""
            if not explicit or current == wanted then
                return true
            end
            return false, "voting closed on " .. tostring(current) .. ", wanted " .. tostring(wanted)
        end

        local ready = not buttonsReady or buttonsReady.Value == true
        if ready and button and button:IsA("GuiButton")
            and button.Visible and button.Selectable ~= false
            and os.clock() - lastClick >= 0.55
        then
            session.auto.clickGuiButton(button)
            lastClick = os.clock()
        end

        task.wait(0.1)
    end

    if session.auto.playerHasDifficultyVote(voting, wanted) then
        return true
    end

    return false, "difficulty vote was not confirmed: " .. tostring(wanted)
end

function session.auto.waitForPregameFinished(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA V19] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    local startValue = voting:FindFirstChild("Start")
    local countdown = voting:FindFirstChild("Countdown")
    local deadline = os.clock() + (tonumber(timeout) or 35)

    while session.alive and os.clock() < deadline do
        local started = not startValue or startValue.Value == true
        local countDone = not countdown or tonumber(countdown.Value) == nil or tonumber(countdown.Value) <= 0

        if started and countDone then
            task.wait(0.2)
            return true
        end

        task.wait(0.1)
    end

    return false, "pre-game countdown did not finish"
end

function session.XOMA:Difficulty(name)
    self._macro.difficulty = session.auto.normalizeDifficulty(name or "Normal")
    return self
end

function session.auto.runMacroInMatch(macro)
    local ready, readyError = session.auto.waitForMatchReady(macro, 35)
    if not ready then
        return false, readyError
    end

    local pregameOk, pregameError = session.auto.waitForPregameFinished(macro, 40)
    if not pregameOk then
        return false, pregameError
    end

    print("[XOMA V19] pre-game ready | starting replay")

    local ok, replayError = xpcall(function()
        session.recorder.replayMacro(macro)
    end, function(err)
        if debug and type(debug.traceback) == "function" then
            return debug.traceback(tostring(err), 2)
        end
        return tostring(err)
    end)

    if not ok then
        return false, tostring(replayError)
    end

    return true
end

return session.XOMA