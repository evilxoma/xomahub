-- XOMA pre-game Ready Up patch
-- Build: PASS14-READY-INPUTOBJECT-V24
-- game2(4) proves WaitingRoom.MouseButton1Down is cosmetic only. The real Ready
-- path is driven by Roblox input processing, so direct RBXScriptSignal callbacks
-- cannot produce the server vote. Use only VirtualInputManager mouse-button
-- events at the button coordinates. We never send mouse-move or keyboard input,
-- and never use VirtualUser, so the player's cursor/camera is not repositioned.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION

if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA V24 ready patch: CTDIG session is unavailable")
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local function getVim()
    local ok, service = pcall(game.GetService, game, "VirtualInputManager")
    if ok and service then
        return service
    end
    return nil
end

local function buttonCenter(button)
    return button.AbsolutePosition + (button.AbsoluteSize / 2)
end

local function sendButtonClick(button)
    if not button or not button:IsA("GuiButton") then
        return false, "button missing"
    end
    if button.AbsoluteSize.X <= 0 or button.AbsoluteSize.Y <= 0 then
        return false, "button has no screen size"
    end

    local vim = getVim()
    if not vim then
        return false, "VirtualInputManager unavailable"
    end

    -- Do not collide with a real click the player is currently holding.
    local heldOk, held = pcall(UserInputService.IsMouseButtonPressed,
        UserInputService, Enum.UserInputType.MouseButton1)
    if heldOk and held == true then
        return false, "player mouse1 is currently held"
    end

    local center = buttonCenter(button)
    local ok, err = pcall(function()
        -- Important: SendMouseMoveEvent is intentionally NEVER called. These x/y
        -- values belong to the synthetic InputObject only; the visible cursor is
        -- not moved to the button.
        vim:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.025)
        vim:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
    end)

    if not ok then
        return false, "VIM click failed: " .. tostring(err)
    end

    return true, string.format("VIM Mouse1 @ %.0f,%.0f", center.X, center.Y)
end

-- All pre-game buttons use one input path. This also fixes difficulty selection,
-- whose saved MouseButton1Down handler in game2 is visual feedback only.
function session.auto.clickGuiButton(button)
    local ok, detail = sendButtonClick(button)
    session.auto.lastGuiClickMethod = detail
    return ok, detail
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
    local nextAttempt = 0

    while session.alive and os.clock() < deadline do
        if waitingDone.Value == true then
            print("[XOMA V24] Ready Up confirmed after " .. tostring(attempts) .. " input attempts")
            return true
        end

        if readyButton.Visible and os.clock() >= nextAttempt then
            attempts = attempts + 1
            local ok, detail = sendButtonClick(readyButton)
            session.auto.lastGuiClickMethod = detail
            print(
                "[XOMA V24] Ready Up input " .. tostring(attempts)
                    .. " | sent=" .. tostring(ok)
                    .. " | " .. tostring(detail)
            )

            -- Give the server plenty of time to replicate WaitingRoomDone. This
            -- prevents the 30+ callback spam seen in V23.
            nextAttempt = os.clock() + 0.85
        end

        task.wait(0.06)
    end

    return waitingDone.Value == true,
        "ready vote was not confirmed | attempts=" .. tostring(attempts)
            .. " | last=" .. tostring(session.auto.lastGuiClickMethod)
end

session.readyBuild = "PASS14-READY-INPUTOBJECT-V24"
return session.XOMA
