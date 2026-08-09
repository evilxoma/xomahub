-- XOMA / CTDIG bootstrap
-- Build: PASS6-SESSION-XOMA-V16
-- The core is split into source chunks only to keep GitHub updates manageable.
-- Strategies keep using the same XOMA:Place / XOMA:Upgrade / ... API.

local BASE = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/src/"
local parts = {}

for i = 1, 16 do
    parts[i] = game:HttpGet(BASE .. string.format("part%02d.lua.txt", i))
end

local source = table.concat(parts, "\n")
local chunk, err = loadstring(source)
if not chunk then
    error("XOMA core compile failed: " .. tostring(err))
end

return chunk()
