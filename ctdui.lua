-- XOMA / CTDIG bootstrap
-- Build: PASS17-W0-PREGAME-V27
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
    -- A recorder strategy always calls ctdui.lua before declaring its actions.
    -- When the hub is already alive in THIS DataModel (Replay button), reuse it
    -- but give the strategy a clean builder so previous actions never duplicate.
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

-- Do not synthesize any user input during bootstrap. The macro only stores its
-- wanted difficulty in XOMA_AUTOEXEC_PREFLIGHT here. Ready/difficulty handling
-- is installed after core startup by the ready patch.

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

-- Replay can run from an executor thread that is allowed to control the game but
-- not allowed to mutate Obsidian's internal Plugin-capability UI Instances.
-- Status text is non-essential, so make the two SetText calls inside the shared
-- setLabelText helper non-fatal. This keeps W0 Place/Upgrade execution alive.
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

local coreChunk, coreError = loadstring(coreSource)
if not coreChunk then
    error("XOMA core compile failed: " .. tostring(coreError))
end
local XOMA = coreChunk()

-- Mark the live CTDIG session with the exact DataModel. This prevents a stale
-- executor environment from reusing a session created before a Roblox teleport.
local activeSession = environment.CTDIG_SESSION
if type(activeSession) == "table" then
    activeSession.dataModel = game
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
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/w0_v27.lua"
)
local w0Chunk, w0Error = loadstring(w0Source)
if not w0Chunk then
    error("XOMA W0 patch compile failed: " .. tostring(w0Error))
end
XOMA = w0Chunk() or XOMA

return XOMA