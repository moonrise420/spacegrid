-- SpaceGrid: the build tool. Pick a part, aim at an open end of a ship (or look out through it): the part snaps on
-- and is joined for good (it becomes a piece of the ship's one body). Aim at the ground: a new ship starts there.
-- Left = place, right = turn the part (which of its openings is used; with Sprint held: a quarter turn round the
-- opening), reload = take the aimed part off again. With "join" switched off in the menu a part placed at an open end
-- stands there as a ship of its own; Use + reload cuts a ship in two along the joint aimed at.
TOOL.Tab = "SpaceGridKit"
TOOL.Category = "Build"
TOOL.Name = "#tool.spacegrid_build.name"
TOOL.Command = nil
TOOL.ConfigName = ""
TOOL.ClientConVar["part"] = "s_straight"
TOOL.ClientConVar["port"] = "1"
TOOL.ClientConVar["twist"] = "0"
TOOL.ClientConVar["join"] = "1"
TOOL.Information = { { name = "left" }, { name = "right" }, { name = "reload" }, { name = "left_use", icon2 = "gui/e.png" }, { name = "reload_use", icon2 = "gui/e.png" } }

if CLIENT then
	-- the tool's own lines (name, what the buttons do) in the game's language; again whenever that changes
	local function words()
		for _, k in ipairs({ "name", "desc", "left", "right", "reload", "left_use", "reload_use" }) do
			language.Add("tool.spacegrid_build." .. k, SpaceGrid.T("tool." .. k))
		end
	end
	words()
	cvars.AddChangeCallback("gmod_language", function() timer.Simple(0, words) end, "SpaceGrid.ToolWords")
end

-- a door hit by the aim stands for its ship (the tool works on ships, a closed door is in the way of the ray)
local function hullOf(ent)
	if IsValid(ent) and ent.SpaceGridDoor then return ent:GetParent() end
	return ent
end

-- The open end the player looks through: the aim ray passes through its opening before it hits anything. Looking
-- along a corridor and out of its far end hits the ground or nothing at all - the far end is meant all the same.
-- Returns hull, part, port number - and as fourth value the size of an opening of another size on the way.
local RAY_MAX = 4096
local XYZ = { "x", "y", "z" }
function SpaceGrid.AimPort(tr, ptype)
	local start, normal = tr.StartPos, tr.Normal
	if not start or not normal then return nil end
	local maxT = RAY_MAX
	if tr.Hit then maxT = math.min(maxT, start:Distance(tr.HitPos) + 1) end
	local bh, bp, bi, bt, bout, other
	for _, h in ipairs(ents.FindByClass("spacegrid_hull")) do
		local mn, mx = h.SGMins, h.SGMaxs
		if h.SG and mn and mx then
			local ls = h:WorldToLocal(start)
			local ld = WorldToLocal(normal, angle_zero, vector_origin, h:GetAngles())
			-- does the ray come near this ship at all (its box, a little wider)
			local t0, t1 = 0, maxT
			for _, k in ipairs(XYZ) do
				local s, d, lo, hi = ls[k], ld[k], mn[k] - 8, mx[k] + 8
				if math.abs(d) < 1e-6 then
					if s < lo or s > hi then t0 = math.huge end
				else
					local a, b = (lo - s) / d, (hi - s) / d
					if a > b then a, b = b, a end
					t0, t1 = math.max(t0, a), math.min(t1, b)
				end
			end
			if t0 <= t1 then
				local p, i, t, out, o = SpaceGrid.StateRayPort(h.SG, ls, ld, maxT, ptype)
				other = other or o
				if p and (not bp or (out and not bout) or (out == bout and t < bt)) then bh, bp, bi, bt, bout = h, p, i, t, out end
			end
		end
	end
	return bh, bp, bi, other
end

-- Where the chosen part would go for this aim. Shared: the server places with it, the client draws the ghost with it.
-- Returns { hull, lpos, lang, pos, ang, ok, why } (pos / ang in the world)
function SpaceGrid.ToolTarget(ply, tr, typ, own, twist)
	local def = SpaceGrid.Parts[typ]
	if not def then return nil end
	local function onto(hull, lpos, lang, a, b)
		local why
		if not lpos then why, lpos, lang = lang, a, b end   -- (nil, why, pos, ang) when there is no room
		if not lpos then return { hull = hull, ok = false, why = why } end
		local pos, ang = LocalToWorld(lpos, lang, hull:GetPos(), hull:GetAngles())
		return { hull = hull, lpos = lpos, lang = lang, pos = pos, ang = ang, ok = why == nil, why = why }
	end
	-- 1. aimed at a ship: the open end nearest to the spot
	-- the part's own opening: one of its openings (a wing has mounts only: one of those), never a hull part's mount
	if #def.ports > 0 then own = (own - 1) % SpaceGrid.OwnPorts(def) + 1 end
	local hull, miss = hullOf(tr.Entity), nil
	if tr.Hit and IsValid(hull) and hull.SpaceGridHull and hull.SG then
		miss = onto(hull, SpaceGrid.Placement(hull.SG, typ, own, twist, hull:WorldToLocal(tr.HitPos)))
		if miss.lpos then return miss end
	end
	-- 2. the open end looked through
	local ptype = #def.ports > 0 and def.ports[(own - 1) % #def.ports + 1].type or nil
	local rh, rp, ri, other = SpaceGrid.AimPort(tr, ptype)
	if rh and ptype then return onto(rh, SpaceGrid.PlacementAt(rh.SG, typ, own, twist, rp, ri)) end
	if miss then return miss end
	if other and ptype then
		if SpaceGrid.IsMount(ptype) then return { ok = false, why = "mount not opening" } end
		return { ok = false, why = "size_differs", whyA = { other, ptype } }
	end
	if not tr.Hit or tr.HitSky or (IsValid(tr.Entity) and tr.Entity:IsPlayer()) then return nil end
	if ptype and SpaceGrid.IsMount(ptype) then return { ok = false, why = "mount only" } end
	-- 3. a new ship: upright on the spot, turned to the player in steps of 45 degrees
	local yaw = math.Round(ply:EyeAngles().y / 45) * 45
	return { pos = tr.HitPos + Vector(0, 0, 1 - def.mins.z), ang = Angle(0, yaw, 0), ok = true }
end

local function mayTouch(ply, hull)
	if hull.CPPICanTool then return hull:CPPICanTool(ply, "spacegrid_build") ~= false end
	return true
end

-- Joining two ships: with Use held, click an open end of the ship that shall move, then an open end of the other
-- one. The first ship goes onto the second and both are one hull from then on.
local function joinClick(tool, ply, tr)
	local hull, part, port = hullOf(tr.Entity), nil, nil
	local onShip = IsValid(hull) and hull.SpaceGridHull and hull.SG
	if onShip then part, port = SpaceGrid.StateFreePort(hull.SG, hull:WorldToLocal(tr.HitPos), 260) end
	if not part then
		local rh, rp, ri = SpaceGrid.AimPort(tr)   -- the open end looked through
		if rh then hull, part, port = rh, rp, ri end
	end
	if not part then
		SpaceGrid.Say(ply, onShip and "say.no_end_here" or "say.aim_end")
		return false
	end
	if not mayTouch(ply, hull) then return false end
	local pick = ply.SGJoinPick
	if not pick or not IsValid(pick.hull) or pick.hull == hull or pick.time < CurTime() - 120 then
		ply.SGJoinPick = { hull = hull, pid = part.id, port = port, time = CurTime() }
		SpaceGrid.Say(ply, "say.will_move")
		return true
	end
	ply.SGJoinPick = nil
	local ok, why = SpaceGrid.MergeHulls(pick.hull, pick.pid, pick.port, hull, part.id, port, tool:GetClientNumber("twist"))
	if ok then SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.join) end
	if ok then SpaceGrid.Say(ply, "say.joined") else SpaceGrid.SayWhy(ply, "say.cannot_join", why) end
	return ok
end

function TOOL:LeftClick(tr)
	if CLIENT then return true end
	local ply = self:GetOwner()
	if ply:KeyDown(IN_USE) then return joinClick(self, ply, tr) end
	local typ = self:GetClientInfo("part")
	local t = SpaceGrid.ToolTarget(ply, tr, typ, self:GetClientNumber("port"), self:GetClientNumber("twist"))
	if not t then return false end
	if not t.ok then
		if t.whyA then SpaceGrid.Say(ply, "say." .. t.why, unpack(t.whyA)) else SpaceGrid.SayWhy(ply, "say.no_fit", t.why) end
		return false
	end
	local hull, part = t.hull, nil
	-- "join" off: the part is set down exactly where it would have been joined, but as a ship of its own
	if hull and self:GetClientNumber("join") == 0 then hull = nil end
	if hull then
		if not mayTouch(ply, hull) then return false end
		part = SpaceGrid.AddPart(hull, typ, t.lpos, t.lang)
		if not part then return false end
		SpaceGrid.Commit(hull)
	else
		if not gamemode.Call("PlayerSpawnSENT", ply, "spacegrid_hull") then return false end
		hull = SpaceGrid.CreateHull(t.pos, t.ang, ply)
		if not IsValid(hull) then return false end
		part = SpaceGrid.AddPart(hull, typ, Vector(0, 0, 0), Angle(0, 0, 0))
		SpaceGrid.Commit(hull)
		gamemode.Call("PlayerSpawnedSENT", ply, hull)
		ply:AddCleanup("sents", hull)
	end
	local pid = part.id
	SpaceGrid.Play(hull:LocalToWorld(part.pos), SpaceGrid.Sounds.tool.place)
	undo.Create("SpaceGrid part")
	undo.AddFunction(function()
		if IsValid(hull) and hull.SG and hull.SG.parts[pid] then SpaceGrid.RemovePart(hull, pid) end
	end)
	undo.SetPlayer(ply)
	undo.SetCustomUndoText("Undone " .. (SpaceGrid.Parts[typ].name or typ))
	undo.Finish()
	return true
end

function TOOL:RightClick()
	if CLIENT then return false end
	local ply = self:GetOwner()
	local def = SpaceGrid.Parts[self:GetClientInfo("part")]
	if not def then return false end
	if ply:KeyDown(IN_SPEED) then
		ply:ConCommand("spacegrid_build_twist " .. (self:GetClientNumber("twist") + 1) % 4)
	else
		ply:ConCommand("spacegrid_build_port " .. self:GetClientNumber("port") % math.max(SpaceGrid.OwnPorts(def), 1) + 1)
	end
	return false
end

function TOOL:Reload(tr)
	local hull = hullOf(tr.Entity)
	if CLIENT then return IsValid(hull) and hull.SpaceGridHull == true end
	local ply = self:GetOwner()
	-- the ends (sh_core.lua, StateEnds): R aimed through an end opened by hand shuts it - the line may go on into
	-- the open, hitting no ship at all, so the ships near the player are asked; R on an end wall opens it
	if not ply:KeyDown(IN_USE) then
		local reach = math.min(tr.StartPos:Distance(tr.HitPos), 250)
		for _, h in ipairs(ents.FindInSphere(tr.StartPos, 2500)) do
			if h.SpaceGridHull and h.SG and mayTouch(ply, h) then
				local okey = SpaceGrid.OpenEndOnRay(h, tr.StartPos, tr.Normal, reach)
				if okey then
					SpaceGrid.SetEndOpen(h, okey, false)
					SpaceGrid.Play(tr.StartPos + tr.Normal * 60, SpaceGrid.Sounds.tool.place)
					SpaceGrid.Say(ply, "say.end_closed")
					return true
				end
			end
		end
	end
	if not IsValid(hull) or not hull.SpaceGridHull then return false end
	if not mayTouch(ply, hull) then return false end
	if not ply:KeyDown(IN_USE) then
		local key = SpaceGrid.EndAtWorld(hull, tr.HitPos)
		if key then
			SpaceGrid.SetEndOpen(hull, key, true)
			SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
			SpaceGrid.Say(ply, "say.end_opened")
			return true
		end
	end
	local part = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
	if not part then return false end
	if ply:KeyDown(IN_USE) then
		-- cut: the joint of the aimed part that is nearest to the spot aimed at
		local lhit, best, bd = hull:WorldToLocal(tr.HitPos), nil, math.huge
		for i, f in ipairs(part.ports) do
			local d = part.links[i] and f.pos:DistToSqr(lhit) or math.huge
			if d < bd then best, bd = i, d end
		end
		if not best then
			SpaceGrid.Say(ply, "say.not_joined")
			return false
		end
		local made, why = SpaceGrid.CutJoint(hull, part.id, best)
		if not made then
			SpaceGrid.SayWhy(ply, "say.cannot_cut", why)
			return false
		end
		SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.cut)
		if #made > 0 then SpaceGrid.Say(ply, "say.cut", #made + 1) else SpaceGrid.Say(ply, "say.cut_still") end
		return true
	end
	SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
	SpaceGrid.RemovePart(hull, part.id)
	return true
end

if CLIENT then
	-- the ghost: where the part would go, green when it fits, red when not. Drawn here on the client (the tool's own
	-- ghost entity exists on the server only in single player).
	local ghost
	local function drop()
		if IsValid(ghost) then ghost:Remove() end
		ghost = nil
	end
	function SpaceGrid.GhostEnt() return ghost end
	hook.Add("Think", "SpaceGrid.Ghost", function()
		local ply = LocalPlayer()
		local wep = IsValid(ply) and ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "gmod_tool" or GetConVarString("gmod_toolmode") ~= "spacegrid_build" then drop() return end
		local typ = GetConVarString("spacegrid_build_part")
		local def = SpaceGrid.Parts[typ]
		local t = def and SpaceGrid.ToolTarget(ply, ply:GetEyeTrace(), typ, GetConVarNumber("spacegrid_build_port"), GetConVarNumber("spacegrid_build_twist"))
		if not t or not t.pos then drop() return end
		if not IsValid(ghost) or ghost:GetModel() ~= def.model then
			drop()
			ghost = ClientsideModel(def.model, RENDERGROUP_TRANSLUCENT)
			if not IsValid(ghost) then return end
			ghost:SetRenderMode(RENDERMODE_TRANSCOLOR)
		end
		ghost:SetPos(t.pos)
		ghost:SetAngles(t.ang)
		ghost:SetColor(t.ok and Color(120, 255, 160, 150) or Color(255, 90, 70, 150))
	end)
end

function TOOL.BuildCPanel(panel)
	panel:Help(SpaceGrid.T("panel.help"))
	panel:Help(SpaceGrid.T("panel.outside"))
	panel:CheckBox(SpaceGrid.T("panel.join"), "spacegrid_build_join")
	panel:ControlHelp(SpaceGrid.T("panel.join_help"))
	panel:Help(SpaceGrid.T("panel.ends"))
	panel:Help(SpaceGrid.T("panel.doors"))
	panel:Help(SpaceGrid.T("panel.seats"))
	-- the parts, sorted as in the spawn tab (sh_menu.lua). Every group folds; the one with the chosen part is open.
	local chosen = GetConVarString("spacegrid_build_part")
	for _, sec in ipairs(SpaceGrid.MenuList()) do
		local head = panel:Help(SpaceGrid.T("sec." .. sec.key))
		head:SetFont("DermaDefaultBold")
		for _, g in ipairs(sec.groups) do
			local cat = vgui.Create("DCollapsibleCategory")
			cat:SetLabel(SpaceGrid.T("grp." .. g.key) .. " (" .. #g.parts .. ")")
			local grid = vgui.Create("DIconLayout")
			grid:SetSpaceX(4); grid:SetSpaceY(4)
			local open = false
			for _, def in ipairs(g.parts) do
				if def.id == chosen then open = true end
				local b = grid:Add("DImageButton")
				b:SetSize(64, 64)
				b:SetImage("spacegrid/parts/" .. def.id .. ".png")
				b:SetTooltip(SpaceGrid.PartName(def))
				b.DoClick = function()
					RunConsoleCommand("spacegrid_build_part", def.id)
					RunConsoleCommand("spacegrid_build_port", "1")
					surface.PlaySound("ui/buttonclickrelease.wav")
				end
				b.PaintOver = function(_, w, h)
					if GetConVarString("spacegrid_build_part") == def.id then
						surface.SetDrawColor(235, 190, 90, 255)
						surface.DrawOutlinedRect(0, 0, w, h, 3)
					end
				end
			end
			cat:SetContents(grid)
			cat:SetExpanded(open)
			panel:AddItem(cat)
		end
	end
end
