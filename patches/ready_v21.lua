-- XOMA pre-game Ready Up signal patch
-- Build: PASS11-READY-SIGNAL-V21
-- game2's WaitingRoom button is driven from MouseButton1Down. Do not treat a
-- successful VirtualInputManager pcall as proof that the GUI accepted a click.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table"
    or type(session.auto) ~= "table"
then
    error("XOMA V21 ready patch: CTDIG session is unavailable")
end

local Workspace = game:GetService("Workspace")
local clickCycles = setmetatable({}, { __mode = "k" })

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function signalFire(button, signalName, center)
    local signal = button and button[signalName]
    if not signal then
        return false
    end

    local firesignalFn = executorFunction("firesignal")
    if firesignalFn then
        local ok
        if signalName == "MouseButton1Down" or signalName == "MouseButton1Up" or signalName == "MouseButton1Click" then
            ok = pcall(firesignalFn, signal, center.X, center.Y)
        else
            ok = pcall(firesignalFn, signal)
        end
        if ok then
            return true
        end
    end

    local getconnectionsFn = executorFunction("getconnections")
    if getconnectionsFn then
        local ok, connections = pcall(getconnectionsFn, signal)
        if ok and type(connections) == "table" then
            local fired = 0
            for _, connection in ipairs(connections) do
                local didFire = false
                if type(connection.Fire) == "function" then
                    didFire = pcall(connection.Fire, connection, center.X, center.Y)
                elseif type(connection.Function) == "function" then
                    didFire = pcall(connection.Function, center.X, center.Y)
                end
                if didFire then
                    fired = fired + 1
                end
            end
            if fired > 0 then
                return true
            end
        end
    end

    return false
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
    local mode = ((cycle - 1) % 5) + 1

    -- WaitingRoom in the supplied game2 binds MouseButton1Down directly.
    if mode == 1 then
        if signalFire(button, "MouseButton1Down", center) then
            session.auto.lastGuiClickMethod = "MouseButton1Down"
            return true, session.auto.lastGuiClickMethod
        end
    elseif mode == 2 then
        if signalFire(button, "Activated", center) then
            session.auto.lastGuiClickMethod = "Activated"
            return true, session.auto.lastGuiClickMethod
        end
    elseif mode == 3 then
        if signalFire(button, "MouseButton1Click", center) then
            session.auto.lastGuiClickMethod = "MouseButton1Click"
            return true, session.auto.lastGuiClickMethod
        end
    elseif mode == 4 then
        local vimOk, vim = pcall(game.GetService, game, "VirtualInputManager")
        if vimOk and vim then
            local ok = pcall(function()
                vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
                task.wait(0.03)
                vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
            end)
            if ok then
                session.auto.lastGuiClickMethod = "VirtualInputManager"
                return true, session.auto.lastGuiClickMethod
            end
        end
    else
        local vuOk, virtualUser = pcall(game.GetService, game, "VirtualUser")
        if vuOk and virtualUser then
            local ok = pcall(function()
                local camera = Workspace.CurrentCamera
                local cf = camera and camera.CFrame or CFrame.new()
                virtualUser:Button1Down(center, cf)
                task.wait(0.03)
                virtualUser:Button1Up(center, cf)
            end)
            if ok then
                session.auto.lastGuiClickMethod = "VirtualUser"
                return true, session.auto.lastGuiClickMethod
            end
        end
    end

    session.auto.lastGuiClickMethod = "method " .. tostring(mode) .. " unavailable"
    return false, session.auto.lastGuiClickMethod
end

-- Override only Ready Up. Confirmation comes exclusively from WaitingRoomDone,
-- so false-positive synthetic clicks cannot advance the strategy.
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
            print("[XOMA V21] Ready Up confirmed after " .. tostring(attempts) .. " attempts")
            return true
        end

        if readyButton.Visible and os.clock() - lastClick >= 0.45 then
            attempts = attempts + 1
            local _, method = session.auto.clickGuiButton(readyButton)
            print("[XOMA V21] Ready Up attempt " .. tostring(attempts) .. " via " .. tostring(method))
            lastClick = os.clock()
        end

        task.wait(0.08)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

session.readyBuild = "PASS11-READY-SIGNAL-V21"
return session.XOMA
