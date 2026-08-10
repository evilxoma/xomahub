-- XOMA Wave 0 start-gate hotfix
-- Build: PASS38-W0-START-GATE-V39
-- Scope: Wave 0 replay timing only. Restart/webhook/recorder/action logic untouched.
--
-- The recorder already saves W0 correctly. The previous w0_v30 patch returned
-- immediately after Ready + Difficulty were voted, which could start performPlace
-- while Voting.Start was still false. At that point the placement world/remotes
-- can exist only partially, so the first W0 Place could fail before the actual
-- preparation phase begins. We now wait for Voting.Start, but deliberately DO NOT
-- wait for Voting.Countdown to reach zero: that preserves the real Wave 0 window.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
    or type(session.XOMA) ~= "table"
then
    error("XOMA W0 V31 patch: CTDIG session is unavailable")
end

local Workspace = game:GetService("Workspace")

local function macroHasWaveZero(macro)
    if type(macro) ~= "table" or type(macro.actions) ~= "table" then
        return false
    end
    for _, action in ipairs(macro.actions) do
        if math.max(0, math.floor(tonumber(action and action.wave) or 0)) == 0 then
            return true
        end
    end
    return false
end

function session.auto.waitForPregameFinished(macro, timeout)
    local voting = Workspace:FindFirstChild("Voting")
    if not voting then
        return true
    end

    local readyOk, readyError = session.auto.autoReadyVoting(12)
    if not readyOk then
        print("[XOMA W0] Auto Ready warning: " .. tostring(readyError))
    end

    local voteOk, voteError = session.auto.autoSelectDifficulty(macro, 12)
    if not voteOk then
        return false, voteError
    end

    local hasW0 = macroHasWaveZero(macro)
    local startValue = voting:FindFirstChild("Start")
    local deadline = os.clock() + (tonumber(timeout) or 35)

    -- Critical gate: do not run W0 while the difficulty vote is merely accepted.
    -- Start=true is the game's transition into the playable preparation phase.
    while session.alive and os.clock() < deadline do
        if not voting.Parent then
            break
        end

        if not startValue or startValue.Value == true then
            -- Give the placement runtime one heartbeat to publish map/tower state.
            task.wait(0.08)
            print(hasW0
                and "[XOMA W0] Voting started | entering real Wave 0 placement window"
                or "[XOMA W0] Voting started | replay gate released")
            return true
        end

        task.wait(0.05)
    end

    if not session.alive then
        return false, "stopped"
    end

    if not voting.Parent then
        return true
    end

    return false, "pre-game did not enter playable start state"
end

session.w0Build = "PASS38-W0-START-GATE-V39"
print("[XOMA W0] start-gate hotfix installed | waits Start=true, not Countdown=0")

return session.XOMA
