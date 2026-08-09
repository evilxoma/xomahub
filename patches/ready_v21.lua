-- XOMA pre-game Ready / Difficulty patch
-- Build: PASS15-HIDDEN-CONNECTION-V25
-- Runtime closure scans show that Ready and every difficulty button each have
-- two MouseButton1Down connections, while only the cosmetic second connection
-- exposes a Lua Function. The first connection is therefore handled in another
-- / protected Luau state. Prefer connection:Defer() so that hidden connection
-- runs in its own state. Only if that cannot produce replicated confirmation do
-- we fall back to a coordinate-only VirtualInputManager Mouse1 event. We never
-- move the cursor, send keyboard input, or use VirtualUser.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA V25 ready patch: CTDIG session is unavailable")
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

local function difficultyConfirmed(button)
    if not button or not button.Parent or button.Parent.Name ~= "DifficultyHolder" then
        return false
    end

    local voting = Workspace:FindFirstChild("Voting")
    local votes = voting and voting:FindFirstChild("DifficultyVotes")
    local folder = votes and votes:FindFirstChild(button.Name)
    return folder and player and folder:FindFirstChild(player.Name) ~= nil or false
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

    -- The runtime scan's real voting connection is the one whose Function is
    -- unavailable. ForeignState/LuaConnection are executor-specific hints only.
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

            -- Some executors expose Fire but not Defer. Keep it as a secondary
            -- connection-state fallback; no synthetic user input is produced.
            if not fired then
                local fire = safeConnectionField(connection, "Fire")
                if type(fire) == "function" then
                    fired = pcall(function()
                        fire(connection, center.X, center.Y)
                    end)
                end
            end

            if fired then
                -- Allow the hidden callback's server request to replicate back.
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
        -- No SendMouseMoveEvent: visible cursor/camera never gets repositioned.
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

    -- Primary path: execute the hidden first connection in its native state.
    local directOk, directDetail = deferHiddenMouseDown(button)
    if directOk or buttonConfirmed(button) then
        session.auto.lastGuiClickMethod = directDetail
        return true, directDetail
    end

    -- Fallback only. Still no mouse movement / keyboard / VirtualUser.
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
                "[XOMA V25] Ready Up confirmed after "
                    .. tostring(attempts) .. " attempts"
            )
            return true
        end

        if readyButton.Visible and os.clock() >= nextAttempt then
            attempts = attempts + 1
            local okClick, detail = session.auto.clickGuiButton(readyButton)
            print(
                "[XOMA V25] Ready Up attempt " .. tostring(attempts)
                    .. " | ok=" .. tostring(okClick)
                    .. " | " .. tostring(detail)
            )

            if waitingDone.Value == true then
                return true
            end

            -- Avoid the V22/V23 callback spam.
            nextAttempt = os.clock() + 0.9
        end

        task.wait(0.06)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

session.readyBuild = "PASS15-HIDDEN-CONNECTION-V25"
return session.XOMA
