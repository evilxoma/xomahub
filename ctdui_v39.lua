-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS38-W0-START-GATE-V39
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

    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/src/",
        "https://raw.githubusercontent.com/evilxoma/xomahub/" .. CORE_REF .. "/src/"
    )
    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/patches/",
        "https://raw.githubusercontent.com/evilxoma/xomahub/" .. CORE_REF .. "/patches/"
    )

    source = source:gsub(
        "https://raw%.githubusercontent%.com/evilxoma/xomahub/refs/heads/main/ctdui_v33%.lua",
        "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/ctdui_v39.lua"
    )

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
    "https://raw.githubusercontent.com/evilxoma/xomahub/2b96b9145d63272ccbb12a81eb978cf42bdf0d56/patches/webhook_v40.lua",
    "XOMA V40 webhook session accounting fix"
) or XOMA

-- Wave 0 timing only: wait until Voting.Start=true, but release before the
-- countdown reaches zero so the first recorded W0 Place runs in the real prep window.
XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/e7f6ef965d9e87ad6a1e1c9ccae328c04238d19b/patches/w0_v31.lua",
    "XOMA Wave 0 start-gate hotfix"
) or XOMA

XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/0867a0957c5833a4fda30f7f357d73b766fe3c85/patches/endclick_v39.lua",
    "XOMA V39 legacy end-screen watcher"
) or XOMA

-- IMPORTANT: PASS36 Auto Retry remains pinned exactly as-is. W0/Webhook patches
-- do not modify any endClick*/Restart state or injector API behavior.
XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/b73de5197c78d2d42f3bce06ffafa03de6fda6ad/patches/endclick_v39_hotfix.lua",
    "XOMA V39 injector-API Auto Retry hotfix"
) or XOMA

local environment = typeof(getgenv) == "function" and getgenv() or _G
local session = environment.CTDIG_SESSION
if type(session) == "table" then
    session.bootstrapBuild = "PASS38-W0-START-GATE-V39"
    session.bootstrapCoreRef = CORE_REF
end

print("[XOMA V39] bootstrap loaded | W0 start fixed | webhook fixed | PASS36 Auto Retry unchanged")
return XOMA