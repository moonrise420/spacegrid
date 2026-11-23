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
	-- a new part starts the right way round: its first opening, not turned (the turn of the part before stayed and
	-- a cockpit came on sideways -, the author's play test)
	cvars.AddChangeCallback("spacegrid_build_part", function(_, old, new)
		-- (set at once, not queued: a port or turn sent right after the part - the test suites do so - must win)
		if old ~= new then
			local cp, ct = GetConVar("spacegrid_build_port"), GetConVar("spacegrid_build_twist")
			if cp then cp:SetInt(1) end
			if ct then ct:SetInt(0) end
		end
	end, "SpaceGrid.NewPartUpright")
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

-- The joint the player looks through (two parts joined at an opening): the aim ray passes through it before it hits
-- anything. ptype: only joints of that size. Returns hull, key, carrier part, port (sh_core.lua, StateRayJoint).
function SpaceGrid.AimJoint(tr, ptype)
	local start, normal = tr.StartPos, tr.Normal
	if not start or not normal then return nil end
	local maxT = RAY_MAX
	if tr.Hit then maxT = math.min(maxT, start:Distance(tr.HitPos) + 16) end
	local bh, bkey, bp, bi, bt
	for _, h in ipairs(ents.FindByClass("spacegrid_hull")) do
		if h.SG then
			local ls = h:WorldToLocal(start)
			local ld = WorldToLocal(normal, angle_zero, vector_origin, h:GetAngles())
			local key, p, i, t = SpaceGrid.StateRayJoint(h.SG, ls, ld, maxT, ptype)
			if key and (not bt or t < bt) then bh, bkey, bp, bi, bt = h, key, p, i, t end
		end
	end
	return bh, bkey, bp, bi
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
	-- 0. a plug (end cap, glass or force-field plug) looking through a joint of its size: it goes into the joint as
	-- its wall (sh_core.lua, JointSeals) - two joined halls shut at one opening, joined at the others (the first
	-- one looked through: a joint on the way to an end wall gets the plug - aimed along a corridor the line lands on
	-- its far end wall, and the joint in between was meant; the ghost shows which)
	if SpaceGrid.IsPlug(typ) and def.ports[1] then
		local jh, jkey, jp, ji = SpaceGrid.AimJoint(tr, def.ports[1].type)
		if jh then
			local f = jp.ports[ji]
			local lpos, lang = SpaceGrid.Mate(def, 1, f.pos, f.dir, f.up, 0)
			local t = onto(jh, SpaceGrid.SnapPos(lpos), SpaceGrid.Snap90(lang))
			t.joint = jkey
			return t
		end
	end
	-- 1. aimed at a ship: the open end nearest to the spot
	-- the part's own opening: one of its openings (a wing has mounts only: one of those), never a hull part's mount
	if #def.ports > 0 then own = (own - 1) % SpaceGrid.OwnPorts(def) + 1 end
	local hull, miss = hullOf(tr.Entity), nil
	if tr.Hit and IsValid(hull) and hull.SpaceGridHull and hull.SG then
		miss = onto(hull, SpaceGrid.Placement(hull.SG, typ, own, twist, hull:WorldToLocal(tr.HitPos)))
		if miss.lpos then return miss end
		-- a plug aimed at the ship from outside with no free opening of its size near: the nearest joint of its size
		-- (aimed at the seam of two joined halls it was refused - "no free port of that size here" - and went in
		-- only when aimed from inside through the opening; the ghost shows where it goes)
		if SpaceGrid.IsPlug(typ) and def.ports[1] then
			local pt = SpaceGrid.PortTypes[def.ports[1].type]
			local jkey, jp, ji = SpaceGrid.StateNearJoint(hull.SG, hull:WorldToLocal(tr.HitPos), (pt and pt.w or 256) + 400, def.ports[1].type)
			if jkey then
				local f = jp.ports[ji]
				local lpos, lang = SpaceGrid.Mate(def, 1, f.pos, f.dir, f.up, 0)
				local t = onto(hull, SpaceGrid.SnapPos(lpos), SpaceGrid.Snap90(lang))
				t.joint = jkey
				return t
			end
		end
	end
	-- 2. the open end looked through
	local ptype = #def.ports > 0 and def.ports[(own - 1) % #def.ports + 1].type or nil
	local rh, rp, ri, other = SpaceGrid.AimPort(tr, ptype)
	if rh and ptype then return onto(rh, SpaceGrid.PlacementAt(rh.SG, typ, own, twist, rp, ri)) end
	if miss then return miss end
	if other and ptype then
		if SpaceGrid.IsMount(ptype) then return { ok = false, why = "mount not opening" } end
		-- (made no sense - right click does nothing for a door, a gate or a hangar door: they have one opening only)
		-- "Right click: next opening" only when the part has one that fits
		for i = 1, SpaceGrid.OwnPorts(def) do
			if def.ports[i] and def.ports[i].type == other then return { ok = false, why = "size_differs_turn", whyA = { other, ptype } } end
		end
		return { ok = false, why = "size_differs", whyA = { other, ptype, other } }
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

-- R through an end opened by hand shuts it again. The line may go on into the open, hitting no ship at all, so every
-- ship is asked; the opening only has to come before what the line hits (`reach`). From outside a hangar that is its
-- floor or far wall - the hangar must not be taken away then (the author's play test: only 250 units counted, a
-- hangar is wider, and only the nearest free opening on the line was asked - the far end behind it). R through
-- a joint (two parts joined at an opening) shuts it with the end wall of its size; R through a joint that has a
-- wall or plug already takes that out (a force-field plug lets the line through: the hall behind it was taken
-- away). The nearest opening on the line counts, an opened end or a joint (two Gate Halls joined at their
-- hangars, R aimed into the joint took the second hall away - "Shut it with a wall").
local function shutEndOnLine(ply, start, normal, reach)
	if CLIENT then return false end
	local bh, bkey, bt, jh, jkey, jt, jtype
	for _, h in ipairs(ents.FindByClass("spacegrid_hull")) do
		if h.SG and mayTouch(ply, h) then
			local key, t = SpaceGrid.OpenEndOnRay(h, start, normal, reach)
			if key and (not bt or t < bt) then bh, bkey, bt = h, key, t end
			local ls = h:WorldToLocal(start)
			local ld = WorldToLocal(normal, angle_zero, vector_origin, h:GetAngles())
			local k2, p2, i2, t2 = SpaceGrid.StateRayJoint(h.SG, ls, ld, reach)
			if k2 and (not jt or t2 < jt) then jh, jkey, jt, jtype = h, k2, t2, p2.ports[i2].type end
		end
	end
	if jkey and (not bt or jt < bt) then
		local at = start + normal * math.min(jt, 200)
		if SpaceGrid.JointSeals(jh.SG)[jkey] then
			SpaceGrid.SetJointSeal(jh, jkey, nil)
			SpaceGrid.Play(at, SpaceGrid.Sounds.tool.take)
			SpaceGrid.Say(ply, "say.joint_opened")
		else
			local cap = SpaceGrid.EndCap[jtype]
			if not cap then return false end
			SpaceGrid.SetJointSeal(jh, jkey, cap)
			SpaceGrid.Play(at, SpaceGrid.Sounds.tool.place)
			SpaceGrid.Say(ply, "say.joint_shut")
		end
		return true
	end
	if not bkey then return false end
	SpaceGrid.SetEndOpen(bh, bkey, false)
	SpaceGrid.Play(start + normal * math.min(bt, 200), SpaceGrid.Sounds.tool.place)
	SpaceGrid.Say(ply, "say.end_closed")
	return true
end

-- Looking out of an open end into empty space the tool gun's line hits nothing, and then the tool gun calls none of
-- the tool's buttons (sandbox gmod_tool: PrimaryAttack, SecondaryAttack and Reload stop when DoToolTrace finds
-- nothing). Yet that is how a cockpit is set onto a front opening: the ghost shows out there, but a click did not
-- place it, a right click did not turn it, R did not shut the end (the author's play test). So the three buttons
-- are heard here too - only when the line hits nothing; else the tool gun calls them itself.
if SERVER then
	local BUTTONS = { [IN_ATTACK] = { "LeftClick", 1 }, [IN_ATTACK2] = { "RightClick", 2 }, [IN_RELOAD] = { "Reload", 3 } }
	hook.Add("KeyPress", "SpaceGrid.ToolIntoSpace", function(ply, key)
		local b = BUTTONS[key]
		if not b then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or wep:GetClass() ~= "gmod_tool" or not wep.GetMode or wep:GetMode() ~= "spacegrid_build" then return end
		if wep.DoToolTrace then
			if wep:DoToolTrace() then return end
		elseif util.TraceLine(util.GetPlayerTrace(ply)).Hit then
			return
		end
		local tool = wep.GetToolObject and wep:GetToolObject()
		if not tool or (tool.Allowed and not tool:Allowed()) then return end
		local tr = util.GetPlayerTrace(ply)
		tr.filter = { ply, ply:GetVehicle() }
		tr = util.TraceLine(tr)
		if not gamemode.Call("CanTool", ply, tr, "spacegrid_build", tool, b[2]) then return end
		tool[b[1]](tool, tr)
	end)
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
	if ok then
		-- undo: the two ships apart again, where they are (sv_hull.lua UndoJoin)
		local pids = why
		undo.Create("SpaceGrid join")
		undo.AddFunction(function()
			local done, w = SpaceGrid.UndoJoin(hull, pids)
			if not done then
				if IsValid(ply) then SpaceGrid.SayWhy(ply, "say.cannot_undo", w) end
				return false
			end
			if IsValid(ply) then SpaceGrid.Say(ply, "say.join_undone") end
		end)
		undo.SetPlayer(ply)
		undo.SetCustomUndoText("Undone join")
		undo.Finish()
	end
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
	-- a plug into a joint: the joint's wall (undo takes it out again)
	if t.joint then
		local hull, key = t.hull, t.joint
		if not IsValid(hull) or not mayTouch(ply, hull) then return false end
		local before = SpaceGrid.JointSeals(hull.SG)[key]
		SpaceGrid.SetJointSeal(hull, key, typ)
		SpaceGrid.Play(t.pos, SpaceGrid.Sounds.tool.place)
		SpaceGrid.Say(ply, "say.joint_shut")
		undo.Create("SpaceGrid part")
		undo.AddFunction(function()
			if IsValid(hull) and hull.SG then SpaceGrid.SetJointSeal(hull, key, before) end
		end)
		undo.SetPlayer(ply)
		undo.SetCustomUndoText("Undone " .. (SpaceGrid.Parts[typ].name or typ))
		undo.Finish()
		return true
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
	-- Right click: the next opening the part goes on by. A part with one opening (a cockpit) turns instead (a cockpit
	-- could not be turned). Sprint + right click: only the turn. Openings that are not square turn by half turns only.
	-- (from 11-19 to 11-21 a round of right clicks turned the part a step after its last opening, and a Gate hall
	-- came on its side.)
	local n = math.max(SpaceGrid.OwnPorts(def), 1)
	local port, twist = (self:GetClientNumber("port") - 1) % n + 1, self:GetClientNumber("twist") % 4
	local square = false
	for i = 1, n do
		local pt = def.ports[i] and SpaceGrid.PortTypes[def.ports[i].type]
		if pt and pt.square then square = true end
	end
	local step = square and 1 or 2
	if ply:KeyDown(IN_SPEED) or n == 1 then
		twist = (twist + step) % 4
	else
		port = port % n + 1
	end
	ply:ConCommand("spacegrid_build_port " .. port)
	ply:ConCommand("spacegrid_build_twist " .. twist)
	return false
end

-- R on the skin of a big room right at the seam where it is joined to another big room means that joint: its wall
-- goes in, or out (round 5 of the night loop: aimed from outside at the seam of two joined Gate Halls, or from inside
-- the joint at its rim, R took a whole hall away). Only rooms this big: a corridor or a small room piece near its
-- joint is taken off by R as always. Returns the joint's key and opening type.
local SEAM, BIG = 48, 1000
local function bigPart(def)
	if not def or not def.mins or not def.maxs then return false end
	local d = def.maxs - def.mins
	return math.max(d.x, d.y, d.z) >= BIG
end
local function seamJoint(hull, part, lhit)
	if not bigPart(SpaceGrid.Parts[part.t]) then return nil end
	local bkey, bd, btype
	for i, f in ipairs(part.ports) do
		local l = part.links[i]
		local o = l and hull.SG.parts[l[1]]
		if o and bigPart(SpaceGrid.Parts[o.t]) and not SpaceGrid.IsMount(f.type) and SpaceGrid.EndCap[f.type] then
			local off = lhit - f.pos
			if math.abs(off:Dot(f.dir)) <= SEAM then
				local d = off:Length()
				if not bd or d < bd then bkey, bd, btype = SpaceGrid.PortKey(f.pos), d, f.type end
			end
		end
	end
	return bkey, btype
end

function TOOL:Reload(tr)
	local hull = hullOf(tr.Entity)
	if CLIENT then return IsValid(hull) and hull.SpaceGridHull == true end
	local ply = self:GetOwner()
	-- (R pressed fast on an end cap made the game lag - each press rebuilt the ship)
	if (ply.SGNextR or 0) > CurTime() then return false end
	ply.SGNextR = CurTime() + 0.25
	-- R on a door, gate or hangar door set into an opening: that door goes (R shut the opening behind it with a cap
	-- instead). Without it the opening is an open end and gets its cap by itself, as any end.
	--
	local d = tr.Entity
	if not ply:KeyDown(IN_USE) and IsValid(d) and d.SpaceGridDoor and IsValid(hull) and hull.SG and mayTouch(ply, hull) then
		if d.SGJoint then
			SpaceGrid.SetJointSeal(hull, d.SGJoint, nil)
			SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
			return true
		end
		local part = d.SGPart
		if part and hull.SG.parts[part.id] == part and SpaceGrid.IsDoorPart(part.t) then
			SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
			SpaceGrid.RemovePart(hull, part.id)
			return true
		end
	end
	-- the ends (sh_core.lua, StateEnds): R aimed through an end opened by hand shuts it; R on an end wall opens it
	if not ply:KeyDown(IN_USE) and shutEndOnLine(ply, tr.StartPos, tr.Normal, tr.Hit and math.min(tr.StartPos:Distance(tr.HitPos) + 16, RAY_MAX) or RAY_MAX) then
		return true
	end
	if not IsValid(hull) or not hull.SpaceGridHull then return false end
	if not mayTouch(ply, hull) then return false end
	if not ply:KeyDown(IN_USE) then
		local key = SpaceGrid.EndAtWorld(hull, tr.HitPos)
		local e = key and hull.SG.ends[key]
		if e and e.joint then
			-- the wall in a joint: taken out, the parts stay joined
			SpaceGrid.SetJointSeal(hull, key, nil)
			SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
			SpaceGrid.Say(ply, "say.joint_opened")
			return true
		end
		if key then
			SpaceGrid.SetEndOpen(hull, key, true)
			SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
			SpaceGrid.Say(ply, "say.end_opened")
			return true
		end
	end
	local part = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
	if not part then return false end
	if not ply:KeyDown(IN_USE) and not (IsValid(tr.Entity) and tr.Entity.SpaceGridDoor) then
		local jkey, jtype = seamJoint(hull, part, hull:WorldToLocal(tr.HitPos))
		if jkey then
			if SpaceGrid.JointSeals(hull.SG)[jkey] then
				SpaceGrid.SetJointSeal(hull, jkey, nil)
				SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.take)
				SpaceGrid.Say(ply, "say.joint_opened")
			else
				SpaceGrid.SetJointSeal(hull, jkey, SpaceGrid.EndCap[jtype])
				SpaceGrid.Play(tr.HitPos, SpaceGrid.Sounds.tool.place)
				SpaceGrid.Say(ply, "say.joint_shut")
			end
			return true
		end
	end
	-- R on a door or field that belongs to a room (a Gate Hall's own doors): not the whole room for it (the
	-- author's play test - R on the hall's door took the hall away). A doorway, a gate, a plug: the door is the
	-- part, R takes it as before.
	if not ply:KeyDown(IN_USE) and IsValid(tr.Entity) and tr.Entity.SpaceGridDoor and not SpaceGrid.IsDoorPart(part.t) then
		SpaceGrid.Say(ply, "say.door_of_room")
		return false
	end
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
		if #made > 0 then
			-- undo: the cut-off pieces back onto the ship, where they were (sv_hull.lua UndoCut)
			undo.Create("SpaceGrid cut")
			undo.AddFunction(function()
				local done, w = SpaceGrid.UndoCut(hull, made)
				if not done then
					if IsValid(ply) then SpaceGrid.SayWhy(ply, "say.cannot_undo", w) end
					return false
				end
				if IsValid(ply) then SpaceGrid.Say(ply, "say.cut_undone") end
			end)
			undo.SetPlayer(ply)
			undo.SetCustomUndoText("Undone cut")
			undo.Finish()
		end
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
	panel:Help(SpaceGrid.T("panel.joints"))
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
