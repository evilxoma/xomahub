-- XOMA pre-game Ready Up signal patch
-- Build: PASS12-READY-NOINPUT-V22
-- Never synthesizes mouse/keyboard input. Ready/difficulty voting is driven only
-- through the button's existing Roblox signal connections, so player control is
-- never moved or captured by the macro.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
then
    error("XOMA V22 ready patch: CTDIG session is unavailable")
end

local Workspace = game:GetService("Workspace")
local clickCycles = setmetatable({}, { __mode = "k" })

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function fireConnection(connection, ...)
    if not connection then
        return false
    end

    local enabledOk, enabled = pcall(function()
        return connection.Enabled
    end)
    if enabledOk and enabled == false then
        return false
    end

    if type(connection.Fire) == "function" then
        return pcall(connection.Fire, connection, ...)
    end

    if type(connection.Function) == "function" then
        return pcall(connection.Function, ...)
    end

    return false
end

local function directSignal(button, signalName, center)
    local signal = button and button[signalName]
    if not signal then
        return false, signalName .. ":missing"
    end

    -- Prefer the real connected callbacks. The previous build returned early
    -- after firesignal() merely because pcall succeeded, which could be a false
    -- positive and prevented us from reaching the actual connection objects.
    local getconnectionsFn = executorFunction("getconnections")
    if getconnectionsFn then
        local ok, connections = pcall(getconnectionsFn, signal)
        if ok and type(connections) == "table" then
            local fired = 0
            for _, connection in ipairs(connections) do
                local didFire
                if signalName == "MouseButton1Down"
                    or signalName == "MouseButton1Up"
                    or signalName == "MouseButton1Click"
                then
                    didFire = fireConnection(connection, center.X, center.Y)
                else
                    didFire = fireConnection(connection)
                end

                if didFire then
                    fired = fired + 1
                end
            end

            if fired > 0 then
                return true, signalName .. ":connections=" .. tostring(fired)
            end
        end
    end

    -- firesignal is still input-free: it does not move the user's mouse. Keep it
    -- as a compatibility fallback for executors that do not expose connections.
    local firesignalFn = executorFunction("firesignal")
    if firesignalFn then
        local ok
        if signalName == "MouseButton1Down"
            or signalName == "MouseButton1Up"
            or signalName == "MouseButton1Click"
        then
            ok = pcall(firesignalFn, signal, center.X, center.Y)
        else
            ok = pcall(firesignalFn, signal)
        end

        if ok then
            return true, signalName .. ":firesignal"
        end
    end

    return false, signalName .. ":unavailable"
end

function session.auto.clickGuiButton(button)
    if not button or not button:IsA("GuiButton") then
        return false, "button missing"
    end

    if button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then
        return false, "button has no screen size"
    end

    local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
    local cycle = (clickCycles[button] or 0) + 1
    clickCycles[button] = cycle

    -- These are all direct signal invocations. VirtualInputManager/VirtualUser
    -- are intentionally not used anywhere in this patch.
    local modes = {
        "Activated",
        "MouseButton1Click",
        "MouseButton1Down",
    }
    local signalName = modes[((cycle - 1) % #modes) + 1]

    -- MouseButton1Down in game2 also has a cosmetic press animation. Restore its
    -- visual position immediately so a direct callback cannot leave it depressed.
    local oldPosition
    local oldDarkPosition
    local dark = button:FindFirstChild("BackgroundDark")
    if signalName == "MouseButton1Down" then
        oldPosition = button.Position
        if dark and dark:IsA("GuiObject") then
            oldDarkPosition = dark.Position
        end
    end

    local ok, detail = directSignal(button, signalName, center)

    if signalName == "MouseButton1Down" then
        pcall(function()
            button.Position = oldPosition
            if dark and oldDarkPosition then
                dark.Position = oldDarkPosition
            end
        end)
    end

    session.auto.lastGuiClickMethod = detail
    return ok, detail
end

-- Confirmation comes exclusively from the replicated WaitingRoomDone value.
-- A direct callback returning successfully is never treated as proof by itself.
function session.auto.autoReadyVoting(timeout)
    local voting = Workspace:FindFirstChild("Voting") or Workspace:WaitForChild("Voting", 10)
    if not voting then
        return true
    end

    local waitingDone = voting:FindFirstChild("WaitingRoomDone") or voting:WaitForChild("WaitingRoomDone", 5)
    if not waitingDone or waitingDone.Value == true then
        return true
    end

    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    local gui = player and (player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 8))
    local votingGui = gui and (gui:FindFirstChild("VotingGui") or gui:WaitForChild("VotingGui", 8))
    if not votingGui then
        return false, "VotingGui missing"
    end

    local readyButton = votingGui:FindFirstChild("WaitingRoom") or votingGui:WaitForChild("WaitingRoom", 5)
    if not readyButton or not readyButton:IsA("GuiButton") then
        return false, "WaitingRoom button missing"
    end

    local deadline = os.clock() + (tonumber(timeout) or 15)
    local lastClick = 0
    local attempts = 0

    while session.alive and os.clock() < deadline do
        if waitingDone.Value == true then
            print("[XOMA V22] Ready Up confirmed after " .. tostring(attempts) .. " attempts")
            return true
        end

        if readyButton.Visible and os.clock() - lastClick >= 0.35 then
            attempts = attempts + 1
            local _, method = session.auto.clickGuiButton(readyButton)
            print("[XOMA V22] Ready Up attempt " .. tostring(attempts) .. " via " .. tostring(method))
            lastClick = os.clock()
        end

        task.wait(0.06)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

session.readyBuild = "PASS12-READY-NOINPUT-V22"
return session.XOMA
