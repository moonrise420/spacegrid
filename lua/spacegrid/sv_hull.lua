-- SpaceGrid: hulls on the server - making them, adding and taking off parts, splitting, merging, sending the part
-- list to the clients.
util.AddNetworkString("SpaceGrid.Hull")
util.AddNetworkString("SpaceGrid.Req")
util.AddNetworkString("SpaceGrid.Delta")

local CHUNK = 2000   -- parts per message (a part is ~10 bytes; a message holds 64 KB)
local DELTA_MAX = 64 -- up to this many changes go out as changes, more as the whole list

-- a new, empty hull (frozen). Add parts, then SpaceGrid.Commit(hull).
function SpaceGrid.CreateHull(pos, ang, ply)
	local e = ents.Create("spacegrid_hull")
	if not IsValid(e) then return nil end
	e:SetPos(pos)
	e:SetAngles(ang or angle_zero)
	e:Spawn()
	e:Activate()
	if IsValid(ply) then
		e.SGOwner = ply
		if e.CPPISetOwner then e:CPPISetOwner(ply) end
	end
	return e
end

-- add a part at (lpos, lang) in hull space. The collision body is rebuilt by Commit.
function SpaceGrid.AddPart(hull, typ, lpos, lang, pid)
	local part, why = SpaceGrid.StateAdd(hull.SG, typ, lpos, lang, pid)
	if part then hull.SGDirty = true end
	return part, why
end

-- What is welded to a hull (a StarCore core, a Wire chip, a lamp) must stay on it, and a new collision body drops
-- the constraints of the old one. So the welds to other entities are taken off before the body is rebuilt and made
-- again after it (as StarCore does for its core when its model changes).
local function takeWelds(hull)
	local list = {}
	for _, c in ipairs(constraint.FindConstraints(hull, "Weld") or {}) do
		local other, bone = c.Ent2, c.Bone2
		if other == hull then other, bone = c.Ent1, c.Bone1 end
		if IsValid(other) and other ~= hull then
			list[#list + 1] = { ent = other, bone = bone or 0, force = c.forcelimit or 0, nocollide = c.nocollide == true }
			-- The old weld is only gone at the end of this tick, and while both entities still list it the new weld
			-- is refused as a second one (seen 2026-11-14: a ship's core came loose with the first part added). So it
			-- is struck from their lists here.
			local old = c.Constraint
			if IsValid(old) then
				for _, e in ipairs({ hull, other }) do
					local t = e.Constraints
					if t then
						for k, v in pairs(t) do
							if v == old then t[k] = nil end
						end
					end
				end
				old:Remove()
			end
		end
	end
	return list
end
local function giveWelds(hull, list)
	for _, w in ipairs(list) do
		if IsValid(w.ent) then constraint.Weld(w.ent, hull, w.bone, 0, w.force, w.nocollide, false) end
	end
end

-- rebuild the collision body and tell the clients (call once after a batch of changes)
function SpaceGrid.Commit(hull)
	if not IsValid(hull) then return false end
	if hull.SG.count == 0 then hull:Remove() return false end
	local t0 = SysTime()
	-- an end opened by hand stays open only while it is an open end (joined since: forgotten)
	local open = hull.SG.open
	if open and next(open) then
		local free = {}
		for _, p in pairs(hull.SG.parts) do
			for i, f in ipairs(p.ports) do
				if not p.links[i] then free[SpaceGrid.PortKey(f.pos)] = true end
			end
		end
		for k in pairs(open) do
			if not free[k] then open[k] = nil end
		end
	end
	-- Something welded to the ship (its StarCore core, a Wire chip): the weld must be gone for real before the old
	-- body is. A removed weld only goes at the end of the tick; rebuilt at once, the body left the old weld pointing
	-- at a destroyed physics object - the game crashed in vphysics (access violation, five times on 2026-11-15, the
	-- crash dumps say so). So then the body is rebuilt a tick later, and the welds are made again on the new one.
	if SpaceGrid.DropIdleCore then SpaceGrid.DropIdleCore(hull) end   -- (building: the automatic StarCore core goes, sv_flight.lua)
	local ok = true
	local welds = takeWelds(hull)
	if #welds > 0 or hull.SGRebuildQueued then
		hull.SGPendingWelds = hull.SGPendingWelds or {}
		for _, w in ipairs(welds) do table.insert(hull.SGPendingWelds, w) end
		if not hull.SGRebuildQueued then
			hull.SGRebuildQueued = true
			timer.Simple(0, function()
				if not IsValid(hull) then return end
				hull.SGRebuildQueued = nil
				hull:SGRebuild()
				local pending = hull.SGPendingWelds or {}
				hull.SGPendingWelds = nil
				giveWelds(hull, pending)
			end)
		end
	else
		ok = hull:SGRebuild()
	end
	hull.SGBuildMs = (SysTime() - t0) * 1000
	hull.SGDirty = false
	hull:SetSGRev(hull:GetSGRev() + 1)
	-- a few changes since the last list: send only those (a click = one part); else the whole list
	local log = hull.SG.log
	hull.SG.log = {}
	if log and hull.SGSent == hull.SG and #log > 0 and #log <= DELTA_MAX then
		SpaceGrid.SendDelta(hull, log)
	else
		SpaceGrid.SendHull(hull)
	end
	hull.SGSent = hull.SG
	if SpaceGrid.SyncDoors then SpaceGrid.SyncDoors(hull) end   -- doorways get their doors (sv_doors.lua)
	if SpaceGrid.SyncDevices then SpaceGrid.SyncDevices(hull) end -- furnished pieces get their devices (sv_devices.lua)
	if SpaceGrid.SyncCore then SpaceGrid.SyncCore(hull) end     -- a ship with a pilot seat flies with StarCore (sv_flight.lua)
	hull.SGAirCache = nil                                       -- its rooms are other rooms now (sv_air.lua)
	return ok
end

-- the ends opened by hand (sh_core.lua, StateEnds): the clients build the same walls
local function writeOpen(hull)
	local keys = table.GetKeys(hull.SG.open or {})
	net.WriteUInt(#keys, 12)
	for _, k in ipairs(keys) do net.WriteString(k) end
end

local function writePart(p)
	net.WriteUInt(SpaceGrid.PartNum[p.t], 12)
	net.WriteUInt(p.id, 16)
	net.WriteInt(p.pos.x, 16); net.WriteInt(p.pos.y, 16); net.WriteInt(p.pos.z, 16)
	net.WriteUInt(math.Round(p.ang.p / 90) % 4, 2); net.WriteUInt(math.Round(p.ang.y / 90) % 4, 2); net.WriteUInt(math.Round(p.ang.r / 90) % 4, 2)
end

-- the changes of one Commit, in order: a part table = added, a number = that part id taken off. A client applies
-- them only if it has the list of the revision before; otherwise it asks for the whole list (ENT:Think).
function SpaceGrid.SendDelta(hull, log)
	net.Start("SpaceGrid.Delta")
	net.WriteUInt(hull:EntIndex(), 16)
	net.WriteUInt(hull:GetSGRev(), 32)
	net.WriteUInt(#log, 8)
	for _, e in ipairs(log) do
		if isnumber(e) then
			net.WriteBool(false)
			net.WriteUInt(e, 16)
		else
			net.WriteBool(true)
			writePart(e)
		end
	end
	writeOpen(hull)
	net.Broadcast()
end

-- the part list to one player or to everybody
function SpaceGrid.SendHull(hull, ply)
	local list = {}
	for _, p in pairs(hull.SG.parts) do list[#list + 1] = p end
	local total, rev = #list, hull:GetSGRev()
	local at = 1
	repeat
		local n = math.min(CHUNK, total - at + 1)
		net.Start("SpaceGrid.Hull")
		net.WriteUInt(hull:EntIndex(), 16)
		net.WriteUInt(rev, 32)
		net.WriteUInt(total, 16)
		net.WriteUInt(at, 16)
		net.WriteUInt(n, 16)
		for i = at, at + n - 1 do
			writePart(list[i])
		end
		writeOpen(hull)
		if ply then net.Send(ply) else net.Broadcast() end
		at = at + n
	until at > total
end

net.Receive("SpaceGrid.Req", function(_, ply)
	local hull = net.ReadEntity()
	if not IsValid(hull) or hull:GetClass() ~= "spacegrid_hull" or not hull.SG then return end
	ply.SGAsked = ply.SGAsked or {}
	local now = CurTime()
	if (ply.SGAsked[hull] or 0) > now then return end
	ply.SGAsked[hull] = now + 0.2
	SpaceGrid.SendHull(hull, ply)
end)

-- a hull above SpaceGrid.MaxPieces stays frozen: no unfreezing, no physgun (which unfreezes what it picks up)
local told = setmetatable({}, { __mode = "k" })
local function refuseTooBig(ply, ent)
	if not SpaceGrid.TooBig(ent) then return end
	if IsValid(ply) and (told[ply] or 0) < CurTime() then
		told[ply] = CurTime() + 4
		SpaceGrid.Say(ply, "say.too_complex", ent.SGPieces, SpaceGrid.MaxPieces)
	end
	return false
end
hook.Add("CanPlayerUnfreeze", "SpaceGrid.TooBig", refuseTooBig)
hook.Add("PhysgunPickup", "SpaceGrid.TooBig", refuseTooBig)

-- a hull space transform -> the world
local function toWorld(hull, lpos, lang) return LocalToWorld(lpos, lang, hull:GetPos(), hull:GetAngles()) end

-- A new hull from some parts of another (they keep their place in the world). Used when a hull falls apart.
local function splitOff(hull, pids)
	local first = hull.SG.parts[pids[1]]
	local wpos, wang = toWorld(hull, first.pos, first.ang)
	local n = SpaceGrid.CreateHull(wpos, wang, hull.SGOwner)
	if not IsValid(n) then return nil end
	for _, pid in ipairs(pids) do
		local p = hull.SG.parts[pid]
		local lp, la = WorldToLocal(p.pos, p.ang, first.pos, first.ang)
		SpaceGrid.StateAdd(n.SG, p.t, SpaceGrid.SnapPos(lp), SpaceGrid.Snap90(la))
	end
	for _, pid in ipairs(pids) do SpaceGrid.StateRemove(hull.SG, pid) end
	-- it moves on like the hull it came from
	local op = hull:GetPhysicsObject()
	local frozen = not IsValid(op) or not op:IsMotionEnabled()
	SpaceGrid.Commit(n)
	frozen = frozen or SpaceGrid.TooBig(n)
	local np = n:GetPhysicsObject()
	if IsValid(np) then
		np:EnableMotion(not frozen)
		if not frozen then np:SetVelocity(op:GetVelocity()); np:Wake() end
	end
	return n
end

-- take a part off. What no longer hangs together becomes hulls of its own. Returns the new hulls.
function SpaceGrid.RemovePart(hull, pid)
	if not SpaceGrid.StateRemove(hull.SG, pid) then return nil end
	local made = {}
	if hull.SG.count == 0 then hull:Remove() return made end
	local islands = SpaceGrid.StateIslands(hull.SG)
	for i = 2, #islands do
		local n = splitOff(hull, islands[i])
		if n then made[#made + 1] = n end
	end
	SpaceGrid.Commit(hull)
	return made
end

-- Cut a ship in two along a joint: the joint of part `pid` at its port `port` and every other joint in the same
-- plane are undone (a ship of two corridors side by side is cut through both). What no longer hangs together
-- becomes hulls of its own, exactly where it is. Returns the new hulls, or nil + why.
function SpaceGrid.CutJoint(hull, pid, port)
	local st = hull.SG
	local part = st.parts[pid]
	local f = part and part.ports[port]
	if not f or not part.links[port] then return nil, "no joint here" end
	local n, at = f.dir, f.pos
	for _, p in pairs(st.parts) do
		for i, g in ipairs(p.ports) do
			local l = p.links[i]
			if l and math.abs(g.dir:Dot(n)) > 0.99 and math.abs((g.pos - at):Dot(n)) < 1 then
				local o = st.parts[l[1]]
				if o then o.links[l[2]] = nil end
				p.links[i] = nil
			end
		end
	end
	local islands = SpaceGrid.StateIslands(st)
	local made = {}
	for i = 2, #islands do
		local h = splitOff(hull, islands[i])
		if h then made[#made + 1] = h end
	end
	SpaceGrid.Commit(hull)
	return made
end

-- Join hull `a` to hull `b`: a's part `pa` port `ia` goes onto b's part `pb` port `ib`; all of a's parts move into
-- b's list and a is removed. Returns true, or false + why.
function SpaceGrid.MergeHulls(a, pa, ia, b, pb, ib, twist)
	if a == b then return false, "same hull" end
	local A, B = a.SG.parts[pa], b.SG.parts[pb]
	if not A or not B then return false, "no such part" end
	local fa, fb = A.ports[ia], B.ports[ib]
	if not fa or not fb or A.links[ia] or B.links[ib] then return false, "port is not free" end
	if fa.type ~= fb.type then return false, "the openings differ" end
	if not SpaceGrid.TwistAllowed(fa.type, twist) then twist = 0 end
	if b.SG.count + a.SG.count > SpaceGrid.MaxParts then return false, "hull is full" end
	-- where a's own frame lands in b's space: a's port frame (in a space) is mated to b's port
	local want = (-fb.dir):AngleEx(fb.up)
	if twist and twist % 4 ~= 0 then want:RotateAroundAxis(fb.dir, 90 * (twist % 4)) end
	local ip, ia2 = WorldToLocal(vector_origin, angle_zero, fa.pos, fa.dir:AngleEx(fa.up))
	local opos, oang = LocalToWorld(ip, ia2, fb.pos, want)
	local moved = {}
	for _, p in pairs(a.SG.parts) do
		local lp, la = LocalToWorld(p.pos, p.ang, opos, oang)
		lp, la = SpaceGrid.SnapPos(lp), SpaceGrid.Snap90(la)
		if SpaceGrid.StateOverlap(b.SG, SpaceGrid.Parts[p.t], lp, la) then return false, "no room" end
		moved[#moved + 1] = { p.t, lp, la }
	end
	for _, m in ipairs(moved) do SpaceGrid.StateAdd(b.SG, m[1], m[2], m[3]) end
	a:Remove()
	SpaceGrid.Commit(b)
	return true
end

-- the part of a hull at a world position (e.g. a trace's HitPos, pushed in a little along the hit normal)
-- open or shut an end by hand (key: SpaceGrid.PortKey of the opening)
function SpaceGrid.SetEndOpen(hull, key, open)
	if not IsValid(hull) or not hull.SG then return end
	hull.SG.open = hull.SG.open or {}
	hull.SG.open[key] = open and true or nil
	SpaceGrid.Commit(hull)
end

-- the end wall a spot of the ship lies on (world), or nil: its key
function SpaceGrid.EndAtWorld(hull, wpos)
	local lp = hull:WorldToLocal(wpos)
	for key, e in pairs(hull.SG.ends or {}) do
		local mn, mx = SpaceGrid.PartBounds(SpaceGrid.Parts[e.t], e.pos, e.ang)
		if lp.x > mn.x - 2 and lp.x < mx.x + 2 and lp.y > mn.y - 2 and lp.y < mx.y + 2 and lp.z > mn.z - 2 and lp.z < mx.z + 2 then return key end
	end
end

-- the end opened by hand that a line from a spot (world) along a direction passes through within reach, or nil
function SpaceGrid.OpenEndOnRay(hull, wstart, wdir, reach)
	local ls = hull:WorldToLocal(wstart)
	local ld = hull:WorldToLocal(wstart + wdir) - ls
	local p, i = SpaceGrid.StateRayPort(hull.SG, ls, ld, reach or 250)
	local key = p and SpaceGrid.PortKey(p.ports[i].pos)
	if key and hull.SG.open and hull.SG.open[key] then return key end
end

function SpaceGrid.PartAtWorld(hull, wpos, normal)
	if normal then wpos = wpos - normal * 2 end
	return SpaceGrid.StatePartAt(hull.SG, hull:WorldToLocal(wpos))
end

-- the stock Remover on a hull takes the one part aimed at, not the whole ship
-- (left click only: button 1, or nil on game versions that do not pass it; a player a prop protection would stop
-- is left to that protection)
hook.Add("CanTool", "SpaceGrid.Remover", function(ply, tr, mode, _, button)
	if mode ~= "remover" or (button ~= nil and button ~= 1) then return end
	local door = IsValid(tr.Entity) and tr.Entity.SpaceGridDoor
	local hull = door and tr.Entity:GetParent() or tr.Entity   -- a door stands for its doorway part
	if not IsValid(hull) or hull:GetClass() ~= "spacegrid_hull" or not hull.SG then return end
	if hull.CPPICanTool and hull:CPPICanTool(ply, "remover") == false then
		if door then return false end   -- not his ship: its door stays too
		return
	end
	if hull.SG.count <= 1 then
		if not door then return end   -- the last part: the stock Remover takes the hull
		hull:Remove()                 -- (aimed at its door: the same, not the door alone)
		return false
	end
	local part = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
	if not part then return end
	SpaceGrid.RemovePart(hull, part.id)
	return false
end)
