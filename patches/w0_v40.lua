-- XOMA Wave 0 startup-readiness patch
-- Build: PASS38-W0-STARTUP-READY-V39
-- Scope: W0 replay timing only. Auto Retry / Restart is intentionally untouched.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) ~= "table" or type(session.auto) ~= "table" then
    error("XOMA W0 patch: CTDIG session unavailable")
end

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local originalWaitForReplayWave = session.auto.waitForReplayWave
if type(originalWaitForReplayWave) ~= "function" then
    error("XOMA W0 patch: waitForReplayWave unavailable")
end

local function toVector3(value)
    if typeof(value) == "Vector3" then
        return value
    end
    if type(value) == "table" then
        return Vector3.new(
            tonumber(value.x or value.X or value[1]) or 0,
            tonumber(value.y or value.Y or value[2]) or 0,
            tonumber(value.z or value.Z or value[3]) or 0
        )
    end
    return Vector3.zero
end

local function w0SurfaceReady(action)
    local map = Workspace:FindFirstChild("Map")
    local towers = Workspace:FindFirstChild("Towers")
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local placeUnit = remotes and remotes:FindFirstChild("PlaceUnit")

    if not map or not towers or not placeUnit or not placeUnit:IsA("RemoteFunction") then
        return false, "map/towers/PlaceUnit not ready"
    end

    local position = toVector3(action and action.position)
    if position == Vector3.zero then
        return false, "recorded W0 position unavailable"
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local enemies = map:FindFirstChild("Enemies")
    local projectiles = Workspace:FindFirstChild("Projectiles")
    if towers then ignore[#ignore + 1] = towers end
    if enemies then ignore[#ignore + 1] = enemies end
    if projectiles then ignore[#ignore + 1] = projectiles end
    if player and player.Character then ignore[#ignore + 1] = player.Character end
    params.FilterDescendantsInstances = ignore

    local hit = Workspace:Raycast(
        position + Vector3.new(0, 12, 0),
        Vector3.new(0, -30, 0),
        params
    )

    if not hit or not hit.Instance then
        return false, "recorded W0 surface not replicated yet"
    end

    return true, hit.Instance:GetFullName()
end

session.auto.waitForReplayWave = function(action, index, total)
    local target = math.max(0, math.floor(tonumber(action and action.wave) or 0))
    if target ~= 0 or not action or action.type ~= "place" then
        return originalWaitForReplayWave(action, index, total)
    end

    -- W0 used to start immediately after Ready/Difficulty confirmation. On a
    -- fresh match the map can still be replicating for a few frames; performPlace
    -- then reports "placement surface ... was not found", which the replay core
    -- treats as fatal. Wait for the REAL recorded surface + PlaceUnit pipeline
    -- instead of delaying until wave 1.
    local stable = 0
    local lastDetail = "waiting"
    local started = os.clock()

    while session.alive do
        -- Keep the normal wave gate semantics. If W1 already began because of a
        -- slow client, do not discard the recorded W0 action: allow it to run late.
        local ready, detail = w0SurfaceReady(action)
        lastDetail = detail or lastDetail
        if ready then
            stable = stable + 1
            if stable >= 3 then
                print("[XOMA V40] W0 placement pipeline ready | " .. tostring(lastDetail))
                return true
            end
        else
            stable = 0
        end

        if os.clock() - started > 20 then
            -- Do not deadlock replay forever. After 20s let performPlace become
            -- authoritative and expose the concrete error/retry behavior.
            warn("[XOMA V40] W0 readiness timeout | " .. tostring(lastDetail))
            return true
        end

        pcall(function()
            if type(session.setReplayStatus) == "function" then
                session.setReplayStatus(string.format(
                    "%d/%d | W0 | waiting placement pipeline | %s",
                    tonumber(index) or 0,
                    tonumber(total) or 0,
                    tostring(lastDetail)
                ))
            end
        end)
        task.wait(0.08)
    end

    return false
end

session.w0Build = "PASS38-W0-STARTUP-READY-V39"
print("[XOMA V40] W0 startup-readiness patch installed | Restart untouched")
return session.XOMA
