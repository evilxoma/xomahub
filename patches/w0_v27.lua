-- XOMA Wave 0 pre-game replay timing patch
-- Build: PASS17-W0-PREGAME-V27
-- Recorder wave 0 actions are actions performed during the voting/countdown
-- phase. Start replay as soon as Ready + Difficulty are authoritatively
-- confirmed so W0 Place/Upgrade actions run in the same phase they were recorded.
-- W1+ actions remain gated by the core waitForReplayWave() implementation.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA V27 W0 patch: CTDIG session is unavailable")
end

local Workspace = game:GetService("Workspace")

function session.auto.waitForPregameFinished(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA V27] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    -- Do NOT wait for Voting.Start / Countdown <= 0 here. Wave 0 in recorder
    -- macros is the pre-wave voting/countdown phase, and the game already allows
    -- manual tower placement during this window.
    print("[XOMA V27] Ready + difficulty confirmed | starting W0 replay during pre-game")
    return true
end

session.w0Build = "PASS17-W0-PREGAME-V27"
return session.XOMA
