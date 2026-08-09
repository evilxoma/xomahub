-- XOMA / CTDIG bootstrap
-- Build: PASS7-AUTOEXEC-V17
-- Base core stays on the stable V16 chunks; V17 applies a small AutoExec patch.
-- Strategy syntax remains unchanged: XOMA:Place / XOMA:Upgrade / ... / XOMA:Run.

local BASE = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/src/"
local parts = {}

for i = 1, 16 do
    parts[i] = game:HttpGet(BASE .. string.format("part%02d.lua.txt", i))
end

local source = table.concat(parts, "\n")
local coreChunk, coreError = loadstring(source)
if not coreChunk then
    error("XOMA core compile failed: " .. tostring(coreError))
end

local XOMA = coreChunk()

local patchSource = game:HttpGet(
    "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/autoexec_v17.lua"
)
local patchChunk, patchError = loadstring(patchSource)
if not patchChunk then
    error("XOMA AutoExec patch compile failed: " .. tostring(patchError))
end

local patchedXOMA = patchChunk()
return patchedXOMA or XOMA