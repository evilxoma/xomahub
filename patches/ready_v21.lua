-- XOMA pre-game Ready Up callback patch
-- Build: PASS13-READY-CALLBACK-V23
-- No VirtualInputManager / VirtualUser. We invoke the actual Lua callback
-- functions behind GUI connections and only accept replicated server state as
-- success. This is required because game2's saved WaitingRoom MouseButton1Down
-- handler is cosmetic only (button offset + click sound).

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA V23 ready patch: CTDIG session is unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local function executorFunction(name)
    local value = rawget(environment, name) or rawget(_G, name)
    return type(value) == "function" and value or nil
end

local function connectionFunction(connection)
    if not connection then
        return nil
    end
    local ok, fn = pcall(function()
        return connection.Function
    end)
    if ok and (type(fn) == "function" or typeof(fn) == "function") then
        return fn
    end
    return nil
end

local function connectionEnabled(connection)
    local ok, enabled = pcall(function()
        return connection.Enabled
    end)
    return not ok or enabled ~= false
end

local function functionLabel(fn)
    local label = "callback"
    pcall(function()
        if debug and type(debug.info) == "function" then
            local source = debug.info(fn, "s")
            local line = debug.info(fn, "l")
            if source then
                label = tostring(source) .. ":" .. tostring(line or "?")
            end
        end
    end)
    return label
end

local function invokeFunction(fn, signalName, center)
    if not fn then
        return false, "no function"
    end

    -- Extra arguments are ignored by zero-argument Luau callbacks. For mouse
    -- callbacks they match the normal x/y shape exposed by executor signals.
    local ok, err
    if signalName == "MouseButton1Down"
        or signalName == "MouseButton1Up"
        or signalName == "MouseButton1Click"
    then
        ok, err = pcall(fn, center.X, center.Y)
    else
        ok, err = pcall(fn)
    end

    if ok then
        return true, functionLabel(fn)
    end
    return false, tostring(err)
end

local function restoreButtonVisual(button, position, dark, darkPosition)
    pcall(function()
        if button and button.Parent and position then
            button.Position = position
        end
        if dark and dark.Parent and darkPosition then
            dark.Position = darkPosition
        end
    end)
end

local function invokeSignalCallbacks(button, signalName, waitingDone)
    local signal = button and button[signalName]
    if not signal then
        return false, signalName .. ":missing"
    end

    local getconnectionsFn = executorFunction("getconnections")
    if not getconnectionsFn then
        return false, signalName .. ":getconnections unavailable"
    end

    local okConnections, connections = pcall(getconnectionsFn, signal)
    if not okConnections or type(connections) ~= "table" then
        return false, signalName .. ":connections unavailable"
    end

    local center = button.AbsolutePosition + (button.AbsoluteSize / 2)
    local oldPosition = button.Position
    local dark = button:FindFirstChild("BackgroundDark")
    local oldDarkPosition = dark and dark:IsA("GuiObject") and dark.Position or nil
    local called = 0
    local errors = 0
    local lastDetail = "none"

    for index, connection in ipairs(connections) do
        if waitingDone and waitingDone.Value == true then
            restoreButtonVisual(button, oldPosition, dark, oldDarkPosition)
            return true, signalName .. ":confirmed-before-" .. tostring(index)
        end

        if connectionEnabled(connection) then
            local fn = connectionFunction(connection)
            if fn then
                local callOk, detail = invokeFunction(fn, signalName, center)
                lastDetail = tostring(index) .. "=" .. tostring(detail)
                if callOk then
                    called = called + 1
                else
                    errors = errors + 1
                end

                -- Give a callback that fired a remote one replication slice to
                -- update WaitingRoomDone before trying another callback.
                task.wait(0.06)
                if waitingDone and waitingDone.Value == true then
                    restoreButtonVisual(button, oldPosition, dark, oldDarkPosition)
                    return true,
                        signalName .. ":callback#" .. tostring(index)
                            .. " confirmed | " .. tostring(detail)
                end
            end
        end
    end

    restoreButtonVisual(button, oldPosition, dark, oldDarkPosition)
    return false,
        signalName .. ":functions=" .. tostring(called)
            .. " errors=" .. tostring(errors)
            .. " last=" .. tostring(lastDetail)
end

-- Targeted fallback for executors where the real Ready callback is created
-- dynamically but its RBXScriptConnection wrapper hides Function. We inspect
-- only Lua closures that directly capture this exact WaitingRoom button and a
-- RemoteEvent/RemoteFunction; unrelated GC functions are never called.
local function invokeCapturedReadyClosures(button, waitingDone)
    local getgcFn = executorFunction("getgc")
    local getupvaluesFn = executorFunction("getupvalues")
        or (debug and type(debug.getupvalues) == "function" and debug.getupvalues)

    if not getgcFn or not getupvaluesFn then
        return false, "gc fallback unavailable"
    end

    local okGc, objects = pcall(getgcFn, true)
    if not okGc or type(objects) ~= "table" then
        return false, "getgc failed"
    end

    local candidates = 0
    for _, object in ipairs(objects) do
        if type(object) == "function" or typeof(object) == "function" then
            local okUps, upvalues = pcall(getupvaluesFn, object)
            if okUps and type(upvalues) == "table" then
                local hasButton = false
                local hasRemote = false
                for _, value in pairs(upvalues) do
                    if value == button then
                        hasButton = true
                    elseif typeof(value) == "Instance"
                        and (value:IsA("RemoteEvent") or value:IsA("RemoteFunction"))
                    then
                        hasRemote = true
                    end
                end

                if hasButton and hasRemote then
                    candidates = candidates + 1
                    local okCall = pcall(object)
                    print(
                        "[XOMA V23] Ready captured callback #"
                            .. tostring(candidates)
                            .. " | " .. functionLabel(object)
                            .. " | call=" .. tostring(okCall)
                    )
                    task.wait(0.08)
                    if waitingDone.Value == true then
                        return true, "captured callback #" .. tostring(candidates)
                    end
                end
            end
        end
    end

    return false, "captured candidates=" .. tostring(candidates)
end

function session.auto.clickGuiButton(button, confirmationValue)
    if not button or not button:IsA("GuiButton") then
        return false, "button missing"
    end
    if button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then
        return false, "button has no screen size"
    end

    -- For ordinary difficulty buttons this still invokes their exact connected
    -- callback functions. For Ready we additionally pass WaitingRoomDone so we
    -- can stop immediately on authoritative confirmation.
    local signalOrder = {
        "MouseButton1Click",
        "Activated",
        "MouseButton1Down",
    }
    local details = {}

    for _, signalName in ipairs(signalOrder) do
        local confirmed, detail = invokeSignalCallbacks(button, signalName, confirmationValue)
        details[#details + 1] = detail
        if confirmed then
            session.auto.lastGuiClickMethod = detail
            return true, detail
        end
    end

    session.auto.lastGuiClickMethod = table.concat(details, " | ")
    return false, session.auto.lastGuiClickMethod
end

function session.auto.autoReadyVoting(timeout)
    local voting = Workspace:FindFirstChild("Voting") or Workspace:WaitForChild("Voting", 10)
    if not voting then
        return true
    end

    local waitingDone = voting:FindFirstChild("WaitingRoomDone") or voting:WaitForChild("WaitingRoomDone", 5)
    if not waitingDone or waitingDone.Value == true then
        return true
    end

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
    local attempts = 0
    local gcTried = false

    while session.alive and os.clock() < deadline do
        if waitingDone.Value == true then
            print("[XOMA V23] Ready Up confirmed after " .. tostring(attempts) .. " attempts")
            return true
        end

        if readyButton.Visible then
            attempts = attempts + 1
            local ok, detail = session.auto.clickGuiButton(readyButton, waitingDone)
            print(
                "[XOMA V23] Ready Up attempt " .. tostring(attempts)
                    .. " | ok=" .. tostring(ok)
                    .. " | " .. tostring(detail)
            )
            if waitingDone.Value == true then
                print("[XOMA V23] Ready Up confirmed via direct callback")
                return true
            end

            if not gcTried and attempts >= 2 then
                gcTried = true
                local gcOk, gcDetail = invokeCapturedReadyClosures(readyButton, waitingDone)
                print("[XOMA V23] Ready GC fallback | " .. tostring(gcDetail))
                if gcOk and waitingDone.Value == true then
                    return true
                end
            end
        end

        task.wait(0.25)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

session.readyBuild = "PASS13-READY-CALLBACK-V23"
return session.XOMA
