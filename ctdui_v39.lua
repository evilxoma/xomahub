-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS32-AUTORETRY-DIRECT-CLICK-V39
-- V33 replay base is frozen to one source snapshot, then V39 applies only the
-- existing input/reliability/webhook layers plus the authoritative end watcher.

local CORE_REF = "faa93d642b8f577bd50e819f5bbd34c442c291e6"
local BASE_REF = "be5bdb4c68e59796ecba8bad836cbea945b77c02"

local function runSource(url, label)
    local source = game:HttpGet(url)
    local chunk, err = loadstring(source)
    if not chunk then
        error(label .. " compile failed: " .. tostring(err))
    end
    return chunk()
end

local function insertBeforePlain(source, needle, insertion, label)
    local first = source:find(needle, 1, true)
    if not first then
        error(label .. " patch anchor missing")
    end
    return source:sub(1, first - 1) .. insertion .. source:sub(first)
end

local function runPinnedBase()
    local source = game:HttpGet(
        "https://raw.githubusercontent.com/evilxoma/xomahub/" .. BASE_REF .. "/ctdui.lua"
    )

    -- The pinned ctdui.lua historically fetched src/patches from main. Freeze
    -- those URLs too so V39 cannot silently change when another branch updates.
    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/src/",
        "https://raw.githubusercontent.com/evilxoma/xomahub/" .. CORE_REF .. "/src/"
    )
    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/patches/",
        "https://raw.githubusercontent.com/evilxoma/xomahub/" .. CORE_REF .. "/patches/"
    )

    -- Recorder strategies created while V39 is loaded must point straight back
    -- to V39; do not depend on the later reliability monitor to rewrite V33.
    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/ctdui_v33%.lua",
        "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui_v39.lua"
    )

    -- Add one V39-only escape hatch for the end watcher. It changes no replay
    -- action implementation; it only flips the same local stop flags used by
    -- the existing Stop Replay/end-action paths once a REAL end screen exists.
    local replayStopPatch = [=[
local replayStopHookCount
coreSource, replayStopHookCount = coreSource:gsub(
    "session%.recorder = {%s+bindGameSources = bindGameSources,",
    [[session.stopReplayForEndScreen = function(reason)
        replayStopRequested = true
        replaying = false
        if replayTaskRunning then
            setRecorderState("replay_stopped")
            setReplayStatus("Stopped: " .. tostring(reason or "end screen"))
        end
        return true
    end

    session.recorder = {
        bindGameSources = bindGameSources,]],
    1
)
if replayStopHookCount ~= 1 then
    error("XOMA V39 replay-stop hook injection failed")
end

]=]

    source = insertBeforePlain(
        source,
        "local coreChunk, coreError = loadstring(coreSource)",
        replayStopPatch,
        "XOMA V39 replay-stop"
    )

    local chunk, err = loadstring(source)
    if not chunk then
        error("XOMA V39 pinned base compile failed: " .. tostring(err))
    end
    return chunk()
end

local XOMA = runPinnedBase()

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/" .. CORE_REF .. "/patches/input_v32.lua",
    "XOMA click-through"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/1b5a27d14eb5e3c5e56834e22a9f0dee0867458c/patches/reliability_v39.lua",
    "XOMA V39 reliability"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/5962551b4ff1a27898aeeaf20f2be00539b4bbf0/patches/webhook_v39.lua",
    "XOMA V39 webhook"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/b91ce2c3a731a1daaddc638b714d8e706691a848/patches/endclick_v39.lua",
    "XOMA V39 direct end-screen click"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS32-AUTORETRY-DIRECT-CLICK-V39"
    session.bootstrapCoreRef = CORE_REF
end

print("[XOMA V39] cache-busted bootstrap loaded | direct-button Auto Retry")
return XOMA