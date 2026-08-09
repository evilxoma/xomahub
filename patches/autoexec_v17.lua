-- XOMA AutoExec patch loader
-- Build: PASS7-AUTOEXEC-V17

local BASE = "https://raw.githubusercontent.com/evilxoma/xomahub/refs/heads/main/patches/v17/"
local parts = {}

for i = 1, 3 do
    parts[i] = game:HttpGet(BASE .. string.format("part%02d.lua.txt", i))
end

local source = table.concat(parts, "\n")
local chunk, err = loadstring(source)
if not chunk then
    error("XOMA V17 patch compile failed: " .. tostring(err))
end

return chunk()