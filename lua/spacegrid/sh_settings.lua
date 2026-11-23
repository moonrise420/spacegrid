-- SpaceGrid: the settings page. One page in the SpaceGrid tab, Settings > SpaceGrid: the server's settings (only
-- admins change them, every player sees them) and each player's own. The server settings are replicated ConVars, so
-- the page shows the server's values; a change goes to the server (net "spacegrid_set"), which takes it only from
-- an admin and logs it.
local SERVER_CV = {
	{ "spacegrid_closedends", "set.closedends" },
	{ "spacegrid_autocore", "set.autocore" },
}
local PLAYER_CV = {
	{ "spacegrid_view", "set.view" },
	{ "spacegrid_glow", "set.glow" },
	{ "spacegrid_hum", "set.hum" },
	{ "spacegrid_roomlights", "set.roomlights" },
	{ "spacegrid_mesh", "set.mesh" },
}

-- (made here, before sv_flight.lua asks for it: replicated, so the page shows the server's value)
CreateConVar("spacegrid_autocore", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), "A SpaceGrid ship with a pilot seat gets a StarCore core by itself (needs the StarCore addon)", 0, 1)

if SERVER then
	util.AddNetworkString("spacegrid_set")
	local allowed = {}
	for _, it in ipairs(SERVER_CV) do allowed[it[1]] = true end
	net.Receive("spacegrid_set", function(_, ply)
		local name, on = net.ReadString(), net.ReadBool()
		if not (IsValid(ply) and ply:IsAdmin()) or not allowed[name] then return end   -- (a listen server's host is an admin)
		RunConsoleCommand(name, on and "1" or "0")
		MsgN("SpaceGrid settings: " .. ply:Nick() .. " (" .. ply:SteamID() .. ") set " .. name .. " = " .. (on and "1" or "0"))
	end)
	return
end

local function build(form)
	local T = SpaceGrid.T
	local head = form:Help(T("set.server"))
	head:SetFont("DermaDefaultBold")
	local isAdmin = LocalPlayer():IsAdmin()
	if not isAdmin then form:Help(T("set.not_admin")) end
	local boxes = {}
	for _, it in ipairs(SERVER_CV) do
		local cv = GetConVar(it[1])
		if cv then
			local c = form:CheckBox(T(it[2]))
			c:SetChecked(cv:GetBool())
			c:SetTooltip(it[1])   -- (the console name, for admins who type it)
			c.OnChange = function(_, on)
				if c.SGSet then return end
				net.Start("spacegrid_set")
				net.WriteString(it[1])
				net.WriteBool(on)
				net.SendToServer()
			end
			if not isAdmin then c:SetEnabled(false) end
			boxes[#boxes + 1] = { c, cv }
		end
	end
	head = form:Help(T("set.player"))
	head:SetFont("DermaDefaultBold")
	for _, it in ipairs(PLAYER_CV) do
		if GetConVar(it[1]) then
			local c = form:CheckBox(T(it[2]), it[1])
			c:SetTooltip(it[1])
		end
	end
	-- the server's values change (another admin, the console): the page follows them
	local tn = "SpaceGridSettings_" .. tostring(form)
	timer.Create(tn, 1, 0, function()
		if not IsValid(form) then timer.Remove(tn) return end
		for _, b in ipairs(boxes) do
			local c, cv = b[1], b[2]
			if IsValid(c) and c:GetChecked() ~= cv:GetBool() then c.SGSet = true; c:SetChecked(cv:GetBool()); c.SGSet = nil end
		end
	end)
end

SpaceGrid.SettingsPanel = build   -- (the test opens the page in a window of its own)

hook.Add("AddToolMenuCategories", "SpaceGrid.Settings", function()
	spawnmenu.AddToolCategory("SpaceGridKit", "Settings", " " .. SpaceGrid.T("set.category"))
end)
hook.Add("PopulateToolMenu", "SpaceGrid.Settings", function()
	spawnmenu.AddToolMenuOption("SpaceGridKit", "Settings", "spacegrid_settings", "SpaceGrid", "", "", build)
end)
