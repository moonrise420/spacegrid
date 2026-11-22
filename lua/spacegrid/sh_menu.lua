-- SpaceGrid: how the menus sort the parts - by what a part is, not by its size class. Sections hold groups; a part
-- goes into the first group one of whose patterns its id fits (Lua patterns, tried in the order written here). A
-- part no rule fits lands in "Other parts", so nothing can vanish from the menus - and the test suite fails until
-- the new part has got its place here., the owner after his first build: in "Rooms" he looks for whole
-- rooms, not single cells. So Rooms holds the complete rooms and domes; the single room cells and furnished wall
-- cells moved to "Advanced" at the end. cockpits first, then rooms, then corridors - and the bridges of whole
-- rooms with the cockpits. Titles are kept to one or two words (the owner,: short and quick to read); the tree cuts
-- long ones off.
SpaceGrid.Menu = {
	{ key = "ships", title = "Ship shapes", groups = {
		{ key = "fronts", title = "Cockpits", ids = { "_cockpit2?$", "_bridge$", "_nose$", "^r_gatebridge$" } },   -- (the bridges of whole rooms too: they fly the ship)
		{ key = "engines", title = "Engines", ids = { "^%a+_engine2?$", "_tail$" }, no = { "^o_" } },
	} },
	{ key = "rooms", title = "Rooms", groups = {
		{ key = "complete", title = "Complete rooms", ids = { "^r_gate" } },   -- (r_gate...: the Gate Halls)
		{ key = "domes", title = "Domes", ids = { "^r_dome", "^m_hub$", "^dome%d" } },
	} },
	{ key = "corridors", title = "Corridors", groups = {
		{ key = "corr_s", title = "Size S", ids = { "^s_straight", "^s_half$", "^s_corner$", "^s_tee$", "^s_cross$", "^s_ramp$", "^s_stairs$", "^s_lift", "^s_ladder" } },
		{ key = "corr_m", title = "Size M", ids = { "^m_straight", "^m_half$", "^m_corner$", "^m_tee$", "^m_cross$", "^m_branch$", "^m_ramp$", "^m_stairs$" } },
		{ key = "hall_l", title = "Halls L", ids = { "^l_straight", "^l_corner$", "^l_tee$", "^l_cross$" } },
		{ key = "hall_xl", title = "Hangars XL", ids = { "^xl_straight", "^xl_corner$", "^xl_tee$", "^xl_cross$", "^xl_pad$" } },
		{ key = "hall_xxl", title = "Great halls XXL", ids = { "^xxl_straight", "^xxl_corner$", "^xxl_tee$", "^xxl_cross$" } },
		{ key = "crawl", title = "Crawl ways", ids = { "^c_" } },
	} },
	{ key = "glass", title = "Glass", groups = {
		{ key = "glass", title = "Windows", ids = { "_window2?$", "_skylight$", "_glass$", "_glassfloor$", "_endwin$" }, no = { "^r" } },
	} },
	{ key = "doors", title = "Doors", groups = {
		{ key = "doors", title = "Doors", ids = { "^[sm]_door2?$", "^[sm]_hatch$", "^[sm]_airlock$", "^[sm]_dock$" } },
		{ key = "gates", title = "Gates", ids = { "_gate$", "_shutter$", "_blast$", "_jaws$", "_auto$" } },
		-- (a door that sits flat in the joint of two halls, its own group)
		{ key = "flatdoors", title = "Flat hangar doors", ids = { "_shuttercap$", "_blastcap$", "_jawscap$", "_autocap$" } },
	} },
	{ key = "ends", title = "Ends", groups = {
		{ key = "ends", title = "End caps", ids = { "_cap$", "_glasscap$", "_fieldcap$" } },
		{ key = "adapters", title = "Adapters", ids = { "_adapter$", "_wall$" } },
	} },
	{ key = "outside", title = "Outside", groups = {
		{ key = "o_wings", title = "Wings", ids = { "^o_wing", "^o_fin" } },
		{ key = "o_gear", title = "Landing gear", ids = { "^o_leg", "^o_skid$" } },
		{ key = "o_drive", title = "Thrusters", ids = { "^o_thruster$", "^o_nacelle$", "^o_ring$", "^o_intake$" } },
		{ key = "o_weapons", title = "Weapons", ids = { "^o_turret$", "^o_cannon$", "^o_gun" } },
		{ key = "o_sensors", title = "Antennas", ids = { "^o_dish$", "^o_mast", "^o_whips$", "^o_radome$", "^o_lamp$" } },
		{ key = "o_struct", title = "Structure", ids = { "^o_truss", "^o_plate$", "^o_slope$", "^o_ridge$", "^o_blister$", "^o_catwalk$", "^o_ladder$", "^o_arm$", "^o_tower$", "^o_hatch$" } },
		{ key = "o_util", title = "Utility", ids = { "^o_solar", "^o_radiator$", "^o_tank$", "^o_crate$", "^o_pipes$", "^o_vent$", "^o_pod$" } },
	} },
	{ key = "advanced", title = "Advanced", groups = {
		{ key = "room1", title = "One deck", ids = { "^r_centre", "^r_edge$", "^r_corner$", "^r_window$", "^r_door2?$", "^r_skylight$", "^r_pillar$" } },
		{ key = "room2", title = "Two decks", ids = { "^r2_centre$", "^r2_edge$", "^r2_corner$", "^r2_window$", "^r2_door$", "^r2_gallery", "^r2_stairs$" } },
		{ key = "room4", title = "Four decks", ids = { "^r4_" } },
		{ key = "f_command", title = "Command", ids = { "^r2?_console$", "^r2?_table$", "^r_captain$", "^r_nav$", "^r_holo$", "^r_desk$", "^r_screen$", "^r_servers$" } },
		{ key = "f_crew", title = "Crew", ids = { "^r2?_bunk$", "^r2?_locker$", "^r_bed$", "^r2?_sofa$", "^r2?_galley$", "^r_bar$", "^r_wash$", "^r_seats$", "^r_cryo$" } },
		{ key = "f_med", title = "Medical", ids = { "^r2?_medbed$", "^r_lab$", "^r_brig$", "^r_armoury$" } },
		{ key = "f_engine", title = "Engineering", ids = { "^r_core$", "^r_generator$", "^r2?_bench$", "^r_pipes$", "^r_tanks$", "^r_breakers$", "^r_pad$", "^r2_reactor$" } },
		{ key = "f_cargo", title = "Cargo", ids = { "^r2?_rack$", "^r_cargo$" } },
	} },
}
local OTHER = { key = "other", title = "Other parts", ids = {} }

-- the group of a part (its table of SpaceGrid.Menu, or the "Other parts" one)
function SpaceGrid.MenuGroup(id)
	for _, sec in ipairs(SpaceGrid.Menu) do
		for _, g in ipairs(sec.groups) do
			local skip = false
			for _, pat in ipairs(g.no or {}) do
				if id:find(pat) then skip = true end
			end
			if not skip then
				for _, pat in ipairs(g.ids) do
					if id:find(pat) then return g end
				end
			end
		end
	end
	return OTHER
end

-- is the part a door itself - a doorway, a gate, a plug (its door or field is the part), not a room that has doors
function SpaceGrid.IsDoorPart(id)
	local k = SpaceGrid.MenuGroup(id).key
	return k == "doors" or k == "gates" or k == "ends"
end

-- (The titles here are the English ones; what a player reads comes from the language files: SpaceGrid.T("sec." ..
-- section.key) and SpaceGrid.T("grp." .. group.key), see sh_lang.lua.)
-- The menus' content: { { title, groups = { { key, title, parts = { def, ... } }, ... } }, ... } - only groups that
-- hold a part, each sorted by size (S, M, L, XL, XXL) and then as the kit lists them.
local RANK = { S = 1, M = 2, L = 3, XL = 4, XXL = 5, C = 6, X = 7, R = 8, O = 9 }
local SIZE = { s = 1, m = 2, l = 3, xl = 4, xxl = 5 }
function SpaceGrid.MenuList()
	local by = {}
	for id, def in pairs(SpaceGrid.Parts) do
		if def.family == "hull" then
			local g = SpaceGrid.MenuGroup(id)
			by[g.key] = by[g.key] or {}
			table.insert(by[g.key], def)
		end
	end
	local function rank(def)
		-- (ship shapes are all of class X: their size is in the id's first letters)
		return (RANK[def.class] or 10) * 10 + (SIZE[def.id:match("^(%a+)_") or ""] or 0)
	end
	local out = {}
	local function add(key, title, groups)
		local sec = { key = key, title = title, groups = {} }
		for _, g in ipairs(groups) do
			local list = by[g.key]
			if list then
				table.sort(list, function(a, b)
					local ra, rb = rank(a), rank(b)
					if ra ~= rb then return ra < rb end
					if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
					return a.id < b.id
				end)
				sec.groups[#sec.groups + 1] = { key = g.key, title = g.title, parts = list }
			end
		end
		if #sec.groups > 0 then out[#out + 1] = sec end
	end
	for _, sec in ipairs(SpaceGrid.Menu) do add(sec.key, sec.title, sec.groups) end
	add("other", "Other", { OTHER })
	return out
end
