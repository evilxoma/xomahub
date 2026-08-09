-- XOMA / CTDIG bootstrap
-- Build: PASS23-NONBLOCKING-SKIP-V33
-- Reuses an already-loaded XOMA session so strategy files can be executed
-- directly by the Player without recursively rebuilding/cleaning the hub.

local environment = typeof(getgenv) == "function" and getgenv() or _G
local existingSession = environment.CTDIG_SESSION

if type(existingSession) == "table"
    and existingSession.alive == true
    and existingSession.dataModel == game
    and type(existingSession.XOMA) == "table"
    and type(existingSession.XOMA.Run) == "function"
then
    existingSession.XOMA._macro = {
        version = 1,
        map = "Unknown",
        deck = {},
        config = {},
        actions = {},
    }
    existingSession.XOMA._nextId = 0
    return existingSession.XOMA
end

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

coreSource = coreSource:gsub(
    "label:SetText%(text%)",
    "pcall(label.SetText, label, text)",
    1
)
coreSource = coreSource:gsub(
    "option:SetText%(text%)",
    "pcall(option.SetText, option, text)",
    1
)

coreSource = coreSource:gsub(
    "if not session%.combatTowerDpsEnabled then%s+session%.visuals%.clearDpsGuis%(%s*%)%s+end",
    [[if not session.combatTowerDpsEnabled then
            if type(session.visuals.clearDpsGuis) == "function" then
                session.visuals.clearDpsGuis()
            end
        end]],
    1
)
coreSource = coreSource:gsub(
    "if not session%.combatKillPreviewEnabled then%s+session%.visuals%.clearKillHighlights%(%s*%)%s+end",
    [[if not session.combatKillPreviewEnabled then
            if type(session.visuals.clearKillHighlights) == "function" then
                session.visuals.clearKillHighlights()
            end
        end]],
    1
)

coreSource = coreSource:gsub(
    "if player%.Character then ignore%[#ignore %+ 1%] = player%.Character end%s+params%.FilterDescendantsInstances = ignore",
    [[if player.Character then ignore[#ignore + 1] = player.Character end

        pcall(function()
            local placementModule = getCTDModule()
            local placementUnits = ReplicatedStorage:FindFirstChild("Units")
            local placementFolder = placementUnits and placementUnits:FindFirstChild(action.unit)
            local placementTags = placementFolder and placementFolder:FindFirstChild("Tags")

            if placementModule
                and type(placementModule.getplacementmouseignores) == "function"
                and placementTags
            then
                local nativeIgnores = placementModule.getplacementmouseignores()
                local nativeList = placementTags:FindFirstChild("Path")
                    and nativeIgnores.Path
                    or nativeIgnores.Normal

                if type(nativeList) == "table" then
                    for _, object in ipairs(nativeList) do
                        if typeof(object) == "Instance" and not table.find(ignore, object) then
                            ignore[#ignore + 1] = object
                        end
                    end
                end
            end

            if unit and typeof(unit) == "Instance" and not table.find(ignore, unit) then
                ignore[#ignore + 1] = unit
            end
        end)

        params.FilterDescendantsInstances = ignore]],
    1
)

coreSource = coreSource:gsub(
    "local tower, placeError = performPlace%(action%)",
    [[local tower, placeError = performPlace(action)
                if not tower then
                    warn("[XOMA PLACE] " .. tostring(placeError))
                end]],
    1
)
coreSource = coreSource:gsub(
    'return nil, "placement currently invalid"',
    'return nil, "placement currently invalid | surface=" .. tostring(surface and surface:GetFullName()) .. " | pos=" .. tostring(position)',
    1
)
coreSource = coreSource:gsub(
    'return nil, "server rejected placement"',
    'return nil, "server rejected placement | surface=" .. tostring(surface and surface:GetFullName()) .. " | pos=" .. tostring(position) .. " | unit=" .. tostring(unit and unit:GetFullName())',
    1
)
coreSource = coreSource:gsub(
    'return nil, "placement validation failed: " .. tostring%(valid%)',
    'return nil, "placement validation failed: " .. tostring(valid) .. " | surface=" .. tostring(surface and surface:GetFullName()) .. " | pos=" .. tostring(position)',
    1
)

-- Recorder can save Skip followed by more actions on the SAME wave. The old
-- performSkip blocked until the wave changed, so those same-wave actions were
-- delayed to the next wave (W8 in the current strategy is exactly Skip -> Place
-- -> Upgrade -> Upgrade). A Skip is a request, not a barrier: turn native
-- AutoSkip on and immediately continue replay. If CTDIG only enabled it
-- temporarily, restore the prior setting asynchronously after that wave ends.
coreSource = coreSource:gsub(
    "local function performSkip%(%)%s+.-%s+return confirmed, confirmed and nil or \"skip was not confirmed\"%s+end",
    [[local function performSkip(targetWave)
    local target = math.max(0, math.floor(tonumber(targetWave) or getWave()))
    local current = getWave()

    -- A late Skip action must never skip the NEXT wave. If its recorded wave is
    -- already over, the requested skip is already satisfied.
    if current > target then
        return true
    end

    local setting = getNativeAutoSkipSetting()
    local wasEnabled = setting and setting.Value == true or false
    local keepEnabled = Toggles.CTDIGAutoSkip and Toggles.CTDIGAutoSkip.Value == true or false

    session.replaySkipSerial = (tonumber(session.replaySkipSerial) or 0) + 1
    local serial = session.replaySkipSerial

    local ok, err = setNativeAutoSkip(true)
    if not ok then
        -- Do not freeze the macro on Skip. Retry the native request in the
        -- background while this recorded wave is still current.
        task.spawn(function()
            while session.alive and replaying and getWave() <= target do
                local retryOk = setNativeAutoSkip(true)
                if retryOk then
                    break
                end
                task.wait(0.2)
            end
        end)
    end

    if not wasEnabled and not keepEnabled then
        task.spawn(function()
            while session.alive and getWave() <= target do
                task.wait(0.05)
            end

            -- A newer Skip owns the setting now; never let an older cleanup
            -- turn AutoSkip off underneath a later wave's request.
            if session.alive and session.replaySkipSerial == serial then
                setNativeAutoSkip(false)
            end
        end)
    end

    print("[XOMA V33] Skip W" .. tostring(target) .. " requested non-blocking")
    return true, ok and nil or tostring(err)
end]],
    1
)
coreSource = coreSource:gsub(
    "local ok, skipError = performSkip%(%s*%)",
    "local ok, skipError = performSkip(action.wave)",
    1
)

-- Newly recorded strategies should use the cache-busted bootstrap.
coreSource = coreSource:gsub(
    'local RAW_CORE_URL = "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/ctdui%.lua"',
    'local RAW_CORE_URL = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui_v33.lua"',
    1
)

local coreChunk, coreError = loadstring(coreSource)
if not coreChunk then
    error("XOMA core compile failed: " .. tostring(coreError))
end
local XOMA = coreChunk()

local activeSession = environment.CTDIG_SESSION
if type(activeSession) == "table" then
    activeSession.dataModel = game
    activeSession.bootstrapBuild = "PASS23-NONBLOCKING-SKIP-V33"
end

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

local playerSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/player_v20.lua"
)
local playerChunk, playerError = loadstring(playerSource)
if not playerChunk then
    error("XOMA Player patch compile failed: " .. tostring(playerError))
end
XOMA = playerChunk() or XOMA

local w0Source = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/w0_v30.lua"
)
local w0Chunk, w0Error = loadstring(w0Source)
if not w0Chunk then
    error("XOMA V30 patch compile failed: " .. tostring(w0Error))
end
XOMA = w0Chunk() or XOMA

local endActionSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/endaction_v31.lua"
)
local endActionChunk, endActionError = loadstring(endActionSource)
if not endActionChunk then
    error("XOMA V31 end-action patch compile failed: " .. tostring(endActionError))
end
XOMA = endActionChunk() or XOMA

local inputSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/input_v32.lua"
)
local inputChunk, inputError = loadstring(inputSource)
if not inputChunk then
    error("XOMA V32 input patch compile failed: " .. tostring(inputError))
end
XOMA = inputChunk() or XOMA

return XOMA
