-- SpaceGrid: a building kit for spaceships, stations and rovers. Parts that fit snap together and are joined for
-- good: a joined ship is ONE physics body (entity spacegrid_hull), not a pile of welded props. Loader.
SpaceGrid = SpaceGrid or {}
SpaceGrid.Version = "0.2.0"

local shared = { "sh_core.lua", "sh_sounds.lua", "sh_parts_data.lua", "sh_menu.lua", "sh_lang.lua", "sh_ladder.lua" }
local server = { "sv_keel.lua", "sv_hull.lua", "sv_doors.lua", "sv_air.lua", "sv_flight.lua", "sv_devices.lua", "sv_gear.lua", "sv_use.lua" }
local client = { "cl_hull.lua", "cl_mesh.lua", "cl_menu.lua", "cl_hum.lua", "cl_fx.lua", "cl_light.lua", "cl_view.lua", "cl_gate.lua" }

for _, f in ipairs(shared) do
	if file.Exists("spacegrid/" .. f, "LUA") then
		if SERVER then AddCSLuaFile("spacegrid/" .. f) end
		include("spacegrid/" .. f)
	end
end
for _, f in ipairs(client) do
	if file.Exists("spacegrid/" .. f, "LUA") then
		if SERVER then AddCSLuaFile("spacegrid/" .. f) else include("spacegrid/" .. f) end
	end
end
if SERVER then
	for _, f in ipairs(server) do include("spacegrid/" .. f) end
end
