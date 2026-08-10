-- XOMA / CTDIG cache-busted bootstrap
-- Build: PASS42-POTASSIUM-PLACE-FALLBACK-V39
-- V33 replay base is frozen to one source snapshot, then V39 applies only the
-- existing input/reliability/webhook layers plus the safe W0 gate and end watcher.

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

-- Potassium can successfully require CTDModule itself, but CTDModule.checkcanplace
-- may perform nested requires that are rejected in executor/RobloxScript context:
--   Cannot require a non-RobloxScript module from a RobloxScript
-- That is an executor limitation, not a negative placement result. In exactly
-- that case, treat client validation as unavailable and let the real PlaceUnit
-- RemoteFunction remain authoritative. Every other checkcanplace error/false
-- result keeps the existing behavior.
local validationOld = [[        if not checked then
            return nil, "placement validation failed: " .. tostring(valid) .. " | surface=" .. tostring(surface and surface:GetFullName()) .. " | pos=" .. tostring(position)
        end
        placeable = valid == true]]

local validationOldPlain = [[        if not checked then
            return nil, "placement validation failed: " .. tostring(valid)
        end
        placeable = valid == true]]

local validationNew = [[        if not checked then
            local validationError = tostring(valid)
            if validationError:find("Cannot require a non-RobloxScript module from a RobloxScript", 1, true) then
                placeable = true
                if not session.potassiumPlacementValidationWarned then
                    session.potassiumPlacementValidationWarned = true
                    warn("[XOMA PLACE] Potassium cannot execute nested checkcanplace require; deferring this validation to PlaceUnit server")
                end
            else
                return nil, "placement validation failed: " .. validationError .. " | surface=" .. tostring(surface and surface:GetFullName()) .. " | pos=" .. tostring(position)
            end
        else
            placeable = valid == true
        end]]

local validationAt = coreSource:find(validationOld, 1, true)
local validationNeedle = validationOld
if not validationAt then
    validationAt = coreSource:find(validationOldPlain, 1, true)
    validationNeedle = validationOldPlain
end
if not validationAt then
    error("XOMA V42 Potassium placement patch anchor missing")
end
coreSource = coreSource:sub(1, validationAt - 1)
    .. validationNew
    .. coreSource:sub(validationAt + #validationNeedle)
print("[XOMA V42] Potassium placement fallback injected | recorder untouched")

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

-- W0 only: no independent CTDModule require here. The core owns/caches the
-- placement module. This gate only waits for W0 + real recorded surface +
-- Map/Towers/PlaceUnit, then lets the normal performPlace path do validation.
XOMA = runSource(
    "https://raw.githubusercontent.com/evilxoma/xomahub/32aa43f3a459f2523b31194dbd6012cb6ac1e8df/patches/w0_v33.lua",
    "XOMA Wave 0 safe Potassium start fix"
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
    session.bootstrapBuild = "PASS42-POTASSIUM-PLACE-FALLBACK-V39"
    session.bootstrapCoreRef = CORE_REF
end

print("[XOMA V39] bootstrap loaded | Potassium placement fixed | W0 fixed | webhook fixed | PASS36 Auto Retry unchanged")
return XOMA