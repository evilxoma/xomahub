-- XOMA Ready/Difficulty input overlay patch
-- Build: PASS22-OBSIDIAN-CLICKTHROUGH-V32
-- Obsidian lives in gethui/CoreGui and can sit above VotingGui. Coordinate VIM
-- clicks then hit CTDIG instead of the game's Ready/Difficulty buttons. During
-- the synthetic Mouse1 press only, disable the ScreenGui that owns the visible
-- CTDIG title, restore it immediately after release, and leave cursor/camera and
-- Obsidian's own toggled state untouched.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA V32 input patch: CTDIG session is unavailable")
end

local UserInputService = game:GetService("UserInputService")

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

local function buttonConfirmed(button)
    if not button or not button.Parent then
        return false
    end

    local voting = workspace:FindFirstChild("Voting")
    if not voting then
        return false
    end

    if button.Name == "WaitingRoom" then
        local done = voting:FindFirstChild("WaitingRoomDone")
        return done and done.Value == true or false
    end

    if button.Parent.Name == "DifficultyHolder" then
        local player = game:GetService("Players").LocalPlayer
        local votes = voting:FindFirstChild("DifficultyVotes")
        local folder = votes and votes:FindFirstChild(button.Name)
        return folder and player and folder:FindFirstChild(player.Name) ~= nil or false
    end

    return false
end

local function shouldTreatAsHidden(connection)
    local fn = safeConnectionField(connection, "Function")
    local foreign = safeConnectionField(connection, "ForeignState")
    local luaConnection = safeConnectionField(connection, "LuaConnection")
    return fn == nil or foreign == true or luaConnection == false
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

    for _, connection in ipairs(connections) do
        if shouldTreatAsHidden(connection) then
            tried = tried + 1
            local fired = false

            local defer = safeConnectionField(connection, "Defer")
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
                local deadline = os.clock() + 0.30
                repeat
                    if buttonConfirmed(button) then
                        return true, "hidden connection confirmed"
                    end
                    task.wait(0.03)
                until os.clock() >= deadline
            end
        end
    end

    return false, "hidden tried=" .. tostring(tried)
end

local function findCTDIGScreenGuis()
    local roots = {}
    local gethuiFn = executorFunction("gethui")

    if gethuiFn then
        local ok, hui = pcall(gethuiFn)
        if ok and typeof(hui) == "Instance" then
            roots[#roots + 1] = hui
        end
    end

    local okCore, coreGui = pcall(game.GetService, game, "CoreGui")
    if okCore and coreGui and not table.find(roots, coreGui) then
        roots[#roots + 1] = coreGui
    end

    local found = {}
    local seen = {}

    for _, root in ipairs(roots) do
        for _, object in ipairs(root:GetDescendants()) do
            if (object:IsA("TextLabel") or object:IsA("TextButton"))
                and tostring(object.Text):find("CTDIG", 1, true)
            then
                local screen = object:FindFirstAncestorOfClass("ScreenGui")
                if screen and not seen[screen] then
                    seen[screen] = true
                    found[#found + 1] = screen
                end
            end
        end
    end

    return found
end

local function suppressCTDIGOverlay()
    local restore = {}

    for _, screen in ipairs(findCTDIGScreenGuis()) do
        local ok, enabled = pcall(function()
            return screen.Enabled
        end)

        if ok and enabled == true then
            restore[#restore + 1] = screen
            pcall(function()
                screen.Enabled = false
            end)
        end
    end

    return function()
        for _, screen in ipairs(restore) do
            if screen and screen.Parent then
                pcall(function()
                    screen.Enabled = true
                end)
            end
        end
    end, #restore
end

local function sendVimMouse1(button)
    local okService, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not okService or not vim then
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
    local restoreOverlay, suppressed = suppressCTDIGOverlay()
    task.wait()

    local ok, err = pcall(function()
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.025)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    restoreOverlay()

    if not ok then
        return false, "VIM click failed: " .. tostring(err)
    end

    local deadline = os.clock() + 0.45
    repeat
        if buttonConfirmed(button) then
            return true, string.format(
                "VIM confirmed @ %.0f,%.0f | CTDIG screens suppressed=%d",
                center.X,
                center.Y,
                suppressed
            )
        end
        task.wait(0.03)
    until os.clock() >= deadline

    return false, string.format(
        "VIM sent @ %.0f,%.0f | CTDIG screens suppressed=%d | not confirmed",
        center.X,
        center.Y,
        suppressed
    )
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

session.inputBuild = "PASS22-OBSIDIAN-CLICKTHROUGH-V32"
print("[XOMA V32] Obsidian click-through installed")

return session.XOMA
