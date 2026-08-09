-- XOMA / CTDIG bootstrap
-- Build: PASS10-UNIFIED-PLAYER-V20
-- Reuses an already-loaded XOMA session so strategy files can be executed
-- directly by the Player without recursively rebuilding/cleaning the hub.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local existingSession = environment.CTDIG_SESSION

if type(existingSession) == "table"
    and existingSession.alive == true
    and type(existingSession.XOMA) == "table"
    and type(existingSession.XOMA.Run) == "function"
then
    return existingSession.XOMA
end

-- Start Auto Ready / difficulty voting BEFORE the large hub finishes loading.
-- New Recorder files set XOMA_AUTOEXEC_PREFLIGHT.Difficulty before this loader.
-- Old strategies stay compatible and use the current/default Normal difficulty.
task.spawn(function()
    local Players = game:GetService("Players")
    local Workspace = game:GetService("Workspace")
    local player = Players.LocalPlayer
    local voting = Workspace:FindFirstChild("Voting")
    if not player or not voting then
        return
    end

    local preflight = environment.XOMA_AUTOEXEC_PREFLIGHT
    local wanted = type(preflight) == "table" and tostring(preflight.Difficulty or "") or ""
    if wanted == "" then
        local current = Workspace:FindFirstChild("Difficulty")
        wanted = current and tostring(current.Value or "") or ""
    end
    if wanted == "" or wanted == "None" then
        wanted = "Normal"
    end

    local function click(button)
        if not button or not button:IsA("GuiButton")
            or button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0
        then
            return false
        end

        local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
        local ok, vim = pcall(game.GetService, game, "VirtualInputManager")
        if ok and vim then
            local sent = pcall(function()
                vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
                task.wait()
                vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
            end)
            if sent then
                return true
            end
        end

        if typeof(firesignal) == "function" then
            return pcall(function()
                firesignal(button.MouseButton1Click)
            end)
        end

        return false
    end

    local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 8)
    local votingGui = playerGui and (playerGui:FindFirstChild("VotingGui") or playerGui:WaitForChild("VotingGui", 8))
    if not votingGui then
        return
    end

    local waitingDone = voting:FindFirstChild("WaitingRoomDone")
    local readyButton = votingGui:FindFirstChild("WaitingRoom")
    local readyDeadline = os.clock() + 10
    local lastReadyClick = 0

    while waitingDone and waitingDone.Value == false and os.clock() < readyDeadline do
        if readyButton and readyButton.Visible and os.clock() - lastReadyClick >= 0.55 then
            click(readyButton)
            lastReadyClick = os.clock()
        end
        task.wait(0.1)
    end

    local startValue = voting:FindFirstChild("Start")
    local votes = voting:FindFirstChild("DifficultyVotes")
    local holder = votingGui:FindFirstChild("DifficultyHolder")
    local button = holder and holder:FindFirstChild(wanted)
    local countdownGui = votingGui:FindFirstChild("Countdown")
    local buttonsReady = countdownGui and countdownGui:FindFirstChild("ButtonsReady")
    local voteDeadline = os.clock() + 12
    local lastVoteClick = 0

    while os.clock() < voteDeadline do
        local folder = votes and votes:FindFirstChild(wanted)
        if folder and folder:FindFirstChild(player.Name) then
            break
        end
        if startValue and startValue.Value == true then
            break
        end
        if (not buttonsReady or buttonsReady.Value == true)
            and button and button:IsA("GuiButton")
            and button.Visible and button.Selectable ~= false
            and os.clock() - lastVoteClick >= 0.55
        then
            click(button)
            lastVoteClick = os.clock()
        end
        task.wait(0.1)
    end
end)

local function fetchParts(base, count, workers)
    local parts = table.create(count)
    local nextIndex = 1
    local completed = 0
    local failed
    local workerCount = math.max(1, math.min(tonumber(workers) or 4, count))

    for _ = 1, workerCount do
        task.spawn(function()
            while true do
                local index = nextIndex
                nextIndex = nextIndex + 1
                if index > count then
                    return
                end

                local ok, result = pcall(function()
                    return game:HttpGet(base .. string.format("part%02d.lua.txt", index))
                end)

                if ok and type(result) == "string" and result ~= "" then
                    parts[index] = result
                elseif not failed then
                    failed = "part" .. string.format("%02d", index) .. ": " .. tostring(result)
                end

                completed = completed + 1
            end
        end)
    end

    while completed < count do
        task.wait()
    end

    if failed then
        error("XOMA source download failed: " .. failed)
    end

    return table.concat(parts, "\n")
end

local coreSource = fetchParts(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/src/",
    16,
    4
)
local coreChunk, coreError = loadstring(coreSource)
if not coreChunk then
    error("XOMA core compile failed: " .. tostring(coreError))
end
local XOMA = coreChunk()

local autoexecSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/autoexec_v17.lua"
)
local autoexecChunk, autoexecError = loadstring(autoexecSource)
if not autoexecChunk then
    error("XOMA AutoExec patch compile failed: " .. tostring(autoexecError))
end
XOMA = autoexecChunk() or XOMA

local pregameSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/pregame_v19.lua"
)
local pregameChunk, pregameError = loadstring(pregameSource)
if not pregameChunk then
    error("XOMA pre-game patch compile failed: " .. tostring(pregameError))
end
XOMA = pregameChunk() or XOMA

return XOMA