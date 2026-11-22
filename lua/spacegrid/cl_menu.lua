-- SpaceGrid: its own tool tab and spawn tab. (PowerGrid's tool tab has the inner id "SpaceGrid" for old reasons;
-- ours is "SpaceGridKit", shown as "SpaceGrid".)
hook.Add("AddToolMenuTabs", "SpaceGrid.Tabs", function()
	spawnmenu.AddToolTab("SpaceGridKit", "SpaceGrid", "icon16/brick.png")
	spawnmenu.AddToolCategory("SpaceGridKit", "Build", " " .. SpaceGrid.T("tool.category"))
end)

-- our tool tabs side by side. GMod sorts tool tabs by their inner names (Stargate, SpaceGrid = PowerGrid's,
-- SpaceGridKit = SpaceGrid's), other addons' tabs came between them. When the tool menu is built, our tabs are
-- moved together in this order, at the place of the first of them. Only the shown tabs move: GMod's own list (tab
-- numbers) stays as it is. The same code is in Ascension Gates, PowerGrid and SpaceGrid (each works alone); the
-- first one loaded does it, once.
hook.Add("PopulateToolMenu", "AGP.OurTabOrder", function()
	local tm = vgui.GetControlTable("ToolMenu")
	if not tm or tm.AGPTabOrder then return end
	tm.AGPTabOrder = true
	local OUR = { Stargate = 1, SpaceGridKit = 2, SpaceGrid = 3 }
	local load = tm.LoadTools
	tm.LoadTools = function(self, ...)
		local r = load(self, ...)
		local rank = {}
		for i, t in ipairs(spawnmenu.GetTools()) do
			local p = self.ToolPanels and self.ToolPanels[i]
			if OUR[t.Name] and IsValid(p) then rank[p] = OUR[t.Name] end
		end
		local items, ours, first = self.Items or {}, {}, nil
		for j, it in ipairs(items) do
			if rank[it.Panel] then ours[#ours + 1] = it; first = first or j end
		end
		if #ours < 2 then return r end
		table.sort(ours, function(a, b) return rank[a.Panel] < rank[b.Panel] end)
		local new = {}
		for j, it in ipairs(items) do
			if j == first then for _, o in ipairs(ours) do new[#new + 1] = o end end
			if not rank[it.Panel] then new[#new + 1] = it end
		end
		for j = 1, #new do items[j] = new[j] end
		local sc = self.tabScroller
		if IsValid(sc) and sc.Panels then
			for j = 1, #new do sc.Panels[j] = new[j].Tab end
			sc:InvalidateLayout(true)
		end
		return r
	end
end)

-- Spawn tab: the parts as pictures, sorted by what they are (sh_menu.lua). On the left a tree of sections and their
-- groups - a click shows that section or that one group - and a box that finds parts by name. A click on a picture
-- takes the build tool with that part.
local GOLD = Color(235, 190, 90)

-- what stands under a picture: the part's name without its family word ("Room: wall with bunks" -> "wall with bunks")
local function short(name)
	local s = name:match("^[^:]+:%s*(.+)$") or name
	return s:sub(1, 1):upper() .. s:sub(2)
end

local function tile(grid, def)
	local t = grid:Add("DPanel")
	t:SetSize(128, 158)
	t:SetPaintBackground(false)
	local b = t:Add("DImageButton")
	b:SetPos(0, 0); b:SetSize(128, 128)
	b:SetImage("spacegrid/parts/" .. def.id .. ".png")
	b:SetTooltip(SpaceGrid.PartName(def))
	b.DoClick = function()
		RunConsoleCommand("spacegrid_build_part", def.id)
		RunConsoleCommand("spacegrid_build_port", "1")
		RunConsoleCommand("gmod_tool", "spacegrid_build")
		surface.PlaySound("ui/buttonclickrelease.wav")
	end
	b.PaintOver = function(_, w, h)
		if GetConVarString("spacegrid_build_part") == def.id then
			surface.SetDrawColor(GOLD)
			surface.DrawOutlinedRect(0, 0, w, h, 3)
		end
	end
	local l = t:Add("DLabel")
	l:SetPos(2, 129); l:SetSize(124, 28)
	l:SetFont("DermaDefault"); l:SetTextColor(Color(225, 228, 235))
	l:SetWrap(true); l:SetContentAlignment(7)
	l:SetText(short(SpaceGrid.PartName(def)))
	return t
end

spawnmenu.AddCreationTab("SpaceGrid", function()
	local root = vgui.Create("DPanel")
	root:SetPaintBackground(false)
	local left = root:Add("DPanel")
	left:Dock(LEFT); left:SetWide(250); left:DockMargin(0, 0, 6, 0)
	left:SetPaintBackground(false)
	local find = left:Add("DTextEntry")
	find:Dock(TOP); find:SetTall(24); find:DockMargin(0, 0, 0, 6)
	find:SetPlaceholderText(SpaceGrid.T("menu.find"))
	find.SGFind = true
	find:SetUpdateOnType(true)
	local tree = left:Add("DTree")
	tree:Dock(FILL)
	local scroll = root:Add("DScrollPanel")
	scroll:Dock(FILL)

	local menu = SpaceGrid.MenuList()
	local shown = nil   -- what the tree last chose: a list of groups

	-- the right side: the given groups, each a heading and its pictures
	local function show(groups, note)
		scroll:Clear()
		if note then
			local n = scroll:Add("DLabel")
			n:Dock(TOP); n:DockMargin(8, 8, 8, 0)
			n:SetFont("DermaDefaultBold"); n:SetTextColor(Color(225, 228, 235)); n:SetText(note); n:SizeToContents()
		end
		for _, g in ipairs(groups) do
			local head = scroll:Add("DLabel")
			head:Dock(TOP); head:DockMargin(8, 10, 8, 4)
			head:SetFont("DermaLarge"); head:SetText(g.shown or SpaceGrid.T("grp." .. g.key)); head:SetTextColor(GOLD); head:SizeToContents()
			local grid = scroll:Add("DIconLayout")
			grid:Dock(TOP); grid:DockMargin(8, 0, 8, 0)
			grid:SetSpaceX(6); grid:SetSpaceY(4)
			for _, def in ipairs(g.parts) do tile(grid, def) end
		end
		scroll:InvalidateLayout(true)
	end

	local all, total = {}, 0
	for _, sec in ipairs(menu) do
		for _, g in ipairs(sec.groups) do
			all[#all + 1] = g
			total = total + #g.parts
		end
	end
	local top = tree:AddNode(SpaceGrid.T("menu.all") .. " (" .. total .. ")", "icon16/bricks.png")
	top.DoClick = function() shown = all; find:SetText(""); show(all) end
	for _, sec in ipairs(menu) do
		local node = tree:AddNode(SpaceGrid.T("sec." .. sec.key), "icon16/folder.png")
		node.DoClick = function() shown = sec.groups; find:SetText(""); show(sec.groups) end
		for _, g in ipairs(sec.groups) do
			local sub = node:AddNode(SpaceGrid.T("grp." .. g.key) .. " (" .. #g.parts .. ")", "icon16/brick.png")
			sub.SGGroup = g.key
			sub.DoClick = function() shown = { g }; find:SetText(""); show({ g }) end
		end
		node:SetExpanded(true, true)
	end

	-- the search box: every part whose name holds all the words typed, in one list; emptied, the tree's choice is back
	find.OnValueChange = function(_, text)
		local words = {}
		for w in string.gmatch(string.lower(text or ""), "%S+") do words[#words + 1] = w end
		if #words == 0 then show(shown or { all[1] }) return end
		local found = {}
		for _, g in ipairs(all) do
			for _, def in ipairs(g.parts) do
				local hay, ok = string.lower(SpaceGrid.PartName(def) .. " " .. def.name .. " " .. def.id .. " " .. SpaceGrid.T("grp." .. g.key) .. " " .. g.title), true
				for _, w in ipairs(words) do
					if not string.find(hay, w, 1, true) then ok = false break end
				end
				if ok then found[#found + 1] = def end
			end
		end
		show({ { key = "found", shown = SpaceGrid.T("menu.found"):format(#found), parts = found } })
	end

	-- at first: the first group (corridors), so the tab opens at once; the tree leads on
	shown = { all[1] }
	show(shown, SpaceGrid.T("menu.hint"))
	return root
end, "icon16/brick.png", 60.02)   -- (Ascension Gates 60.01, SpaceGrid 60.02, PowerGrid 60.03 - right after the Vehicles tab, and after other addons' 60 such as VJ Base and Pills, so ours stay side by side)
