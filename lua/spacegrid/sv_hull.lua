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
-- (pick: only the welds to the entities it says yes to - splitOff hands the cut-off half's own things on)
local function takeWelds(hull, pick)
	local list = {}
	for _, c in ipairs(constraint.FindConstraints(hull, "Weld") or {}) do
		local other, bone = c.Ent2, c.Bone2
		if other == hull then other, bone = c.Ent1, c.Bone1 end
		if IsValid(other) and other ~= hull and (not pick or pick(other)) then
			list[#list + 1] = { ent = other, bone = bone or 0, force = c.forcelimit or 0, nocollide = c.nocollide == true }
			-- The old weld is only gone at the end of this tick, and while both entities still list it the new weld
			-- is refused as a second one (seen: a ship's core came loose with the first part added). So it is struck
			-- from their lists here.
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

-- A wall that comes where a player stands (a joint shut, an end made by taking a part away) held him in it (round 5 of
-- the night loop: standing in the hangar joint of two halls, the second hall taken away - stuck in the first
-- one's new hangar wall). So after a new body, a player standing in one of the ship's end walls is moved to the
-- nearest free spot beside it. Only players at the walls are looked at; noclip and seated players are left alone.
local function freePlayers(hull)
	if not IsValid(hull) or not hull.SG then return end
	local ends = SpaceGrid.StateEnds(hull.SG)   -- (fresh: the list of the last change is older than this body)
	if not next(ends) then return end
	local onlyHull = function(e) return e == hull end
	for _, p in ipairs(player.GetAll()) do
		-- (no distance check first: a hull's own bounds are its small first body, not the ship)
		if p:Alive() and not p:InVehicle() and p:GetMoveType() == MOVETYPE_WALK then
			local mn, mx = p:OBBMins(), p:OBBMaxs()
			local lp = hull:WorldToLocal(p:WorldSpaceCenter())
			local atWall = false
			for _, e in pairs(ends) do
				local def = SpaceGrid.Parts[e.t]
				if def then
					local a, b = SpaceGrid.PartBounds(def, e.pos, e.ang)
					if lp.x > a.x - 40 and lp.x < b.x + 40 and lp.y > a.y - 40 and lp.y < b.y + 40 and lp.z > a.z - 48 and lp.z < b.z + 48 then atWall = true break end
				end
			end
			-- (2 units up: standing on the floor is no wall)
			local function solid(pos, filter)
				local q = pos + Vector(0, 0, 2)
				return util.TraceHull({ start = q, endpos = q, mins = mn, maxs = mx, filter = filter, mask = MASK_PLAYERSOLID }).StartSolid
			end
			if atWall and solid(p:GetPos(), onlyHull) then
				local dirs = { hull:GetForward(), -hull:GetForward(), hull:GetRight(), -hull:GetRight(), hull:GetUp(), -hull:GetUp() }
				local moved = false
				for d = 16, 192, 16 do
					for _, dir in ipairs(dirs) do
						local q = p:GetPos() + dir * d
						if not solid(q, p) then
							p:SetPos(q + Vector(0, 0, 2))
							moved = true
							break
						end
					end
					if moved then break end
				end
			end
		end
	end
end

-- rebuild the collision body and tell the clients (call once after a batch of changes)
-- (keepCore: the change is no building - the landing legs folding or unfolding, sv_gear.lua: the ship's StarCore core
-- stays even with nobody at the helm, the release chat's picture run: a pilot got up in fast flight, the parked ship
-- slowed down, the legs came out and took the core with its tractor beam, shields, weapons and crew)
function SpaceGrid.Commit(hull, keepCore)
	if not IsValid(hull) then return false end
	if hull.SG.count == 0 then hull:Remove() return false end
	local t0 = SysTime()
	-- an end opened by hand stays open only while it is an open end (joined since: forgotten); a wall in a joint
	-- ("<key>=<plug>", sh_core.lua) only while the joint is there
	local open = hull.SG.open
	if open and next(open) then
		local free, joint = {}, {}
		for _, p in pairs(hull.SG.parts) do
			for i, f in ipairs(p.ports) do
				if p.links[i] then joint[SpaceGrid.PortKey(f.pos)] = true else free[SpaceGrid.PortKey(f.pos)] = true end
			end
		end
		for k in pairs(open) do
			local jk = string.match(k, "^(.-)=")
			if jk then
				if not joint[jk] then open[k] = nil end
			elseif not free[k] then
				open[k] = nil
			end
		end
	end
	-- Something welded to the ship (its StarCore core, a Wire chip): the weld must be gone for real before the old
	-- body is. A removed weld only goes at the end of the tick; rebuilt at once, the body left the old weld pointing
	-- at a destroyed physics object - the game crashed in vphysics (access violation, the crash dumps say so). So
	-- then the body is rebuilt a tick later, and the welds are made again on the new one.
	if not keepCore and SpaceGrid.DropIdleCore then SpaceGrid.DropIdleCore(hull) end   -- (building: the automatic StarCore core goes, sv_flight.lua)
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
				freePlayers(hull)
			end)
		end
	else
		ok = hull:SGRebuild()
		freePlayers(hull)
	end
	hull.SGBuildMs = (SysTime() - t0) * 1000
	hull.SGDirty = false
	hull:SetSGRev(hull:GetSGRev() + 1)
	-- a few changes since the last list: send only those (a click = one part); else the whole list
	local log = hull.SG.log
	hull.SG.log = {}
	-- (an end opened or shut changes no part: an empty list of changes carries the opened ends -, R on an end cap sent
	-- the whole ship to every player each time, and fast R presses made the game lag)
	if log and hull.SGSent == hull.SG and #log <= DELTA_MAX then
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

-- The ends opened by hand and the walls in joints (st.open, keyed by the opening's place) of some parts, carried to
-- another hull's space: move(pos) gives an opening's place there. (a ship joined onto another one, or a piece that
-- fell off, lost its opened ends and the plugs in its joints - their keys were left behind.)
local function carryOpen(st, parts, move, into)
	local open = st.open
	if not open or not next(open) then return end
	local seals = SpaceGrid.JointSeals(st)
	for _, p in ipairs(parts) do
		for _, f in ipairs(p.ports) do
			local k = SpaceGrid.PortKey(f.pos)
			if open[k] or seals[k] then
				local nk = SpaceGrid.PortKey(SpaceGrid.SnapPos(move(f.pos)))
				if open[k] then into[nk] = true end
				if seals[k] then into[nk .. "=" .. seals[k]] = true end
			end
		end
	end
end

-- A new hull from some parts of another (they keep their place in the world). Used when a hull falls apart.
local function splitOff(hull, pids)
	local first = hull.SG.parts[pids[1]]
	local wpos, wang = toWorld(hull, first.pos, first.ang)
	local n = SpaceGrid.CreateHull(wpos, wang, hull.SGOwner)
	if not IsValid(n) then return nil end
	n.SGCutOf = { hull = hull, pos = Vector(first.pos), ang = Angle(first.ang) }   -- (where it sat: SpaceGrid.UndoCut)
	local list = {}
	for _, pid in ipairs(pids) do
		local p = hull.SG.parts[pid]
		list[#list + 1] = p
		local lp, la = WorldToLocal(p.pos, p.ang, first.pos, first.ang)
		SpaceGrid.StateAdd(n.SG, p.t, SpaceGrid.SnapPos(lp), SpaceGrid.Snap90(la))
	end
	n.SG.open = n.SG.open or {}
	carryOpen(hull.SG, list, function(v) return (WorldToLocal(v, angle_zero, first.pos, first.ang)) end, n.SG.open)
	-- what is welded on inside or on the cut-off parts (a crate, a lamp, a Wire chip) is welded to the new ship
	-- (round 5: it stayed welded to the old one and hung in the air when the cut-off ship flew away)
	local mine = takeWelds(hull, function(e)
		local lp = hull:WorldToLocal(e:WorldSpaceCenter())
		for _, p in ipairs(list) do
			local mn, mx = SpaceGrid.PartBounds(SpaceGrid.Parts[p.t], p.pos, p.ang)
			if mn and lp.x > mn.x - 48 and lp.x < mx.x + 48 and lp.y > mn.y - 48 and lp.y < mx.y + 48 and lp.z > mn.z - 48 and lp.z < mx.z + 48 then return true end
		end
		return false
	end)
	for _, pid in ipairs(pids) do SpaceGrid.StateRemove(hull.SG, pid) end
	-- it moves on like the hull it came from
	local op = SpaceGrid.Body(hull)   -- (the keel moves the ship: sv_keel.lua)
	local frozen = not IsValid(op) or not op:IsMotionEnabled()
	local vel = IsValid(op) and op:GetVelocity() or nil
	-- (the old ship's keel is held still while a cut is made, sv_keel.lua KeelApart: how it moved before that)
	local ok = hull.SGKeel
	if IsValid(ok) and (ok.SGHolds or 0) > 0 and ok.SGWant ~= nil then
		frozen = ok.SGWant == false
		vel = ok.SGWant and ok.SGWant.vel or nil
	end
	SpaceGrid.Commit(n)
	-- (welded a moment later, held still until then: welded in the tick the new body was made, the crate was crushed
	-- by its own ship as soon as it flew -; a weld to a hull that stood a while held)
	if #mine > 0 then
		local held = {}
		for _, w in ipairs(mine) do
			local ph = IsValid(w.ent) and w.ent:GetPhysicsObject()
			if IsValid(ph) and ph:IsMotionEnabled() then ph:EnableMotion(false); held[#held + 1] = w.ent end
		end
		timer.Simple(0.2, function()
			if IsValid(n) then giveWelds(n, mine) end
			timer.Simple(0.2, function()
				for _, e in ipairs(held) do
					local ph = IsValid(e) and e:GetPhysicsObject()
					if IsValid(ph) then ph:EnableMotion(true); ph:Wake() end
				end
			end)
		end)
	end
	frozen = frozen or SpaceGrid.TooBig(n)
	SpaceGrid.KeelWant(n, not frozen, vel)
	-- the two halves lie in each other's keels for a moment: they do not touch until apart (sv_keel.lua)
	SpaceGrid.KeelApart(hull, n)
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
	-- (a damaged ship was back at 100 % later) the pieces cut off keep the ship's damage
	local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
	local frac = hull.SGHullFrac
	if IsValid(core) and core.HullMax and core.HullMax > 0 and core.Hull then frac = math.Clamp(core.Hull / core.HullMax, 0, 1) end
	for i = 2, #islands do
		local h = splitOff(hull, islands[i])
		if h then made[#made + 1] = h; h.SGHullFrac = frac end
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
	return SpaceGrid.MergeAt(a, b, opos, oang)
end

-- Join hull `a` into hull `b` with a's own frame at opos, oang in b's space (MergeHulls; undoing a cut). Returns true
-- and the ids of a's parts in b, or false + why.
function SpaceGrid.MergeAt(a, b, opos, oang)
	if a == b then return false, "same hull" end
	if b.SG.count + a.SG.count > SpaceGrid.MaxParts then return false, "hull is full" end
	local moved, list = {}, {}
	for _, p in pairs(a.SG.parts) do
		local lp, la = LocalToWorld(p.pos, p.ang, opos, oang)
		lp, la = SpaceGrid.SnapPos(lp), SpaceGrid.Snap90(la)
		if SpaceGrid.StateOverlap(b.SG, SpaceGrid.Parts[p.t], lp, la) then return false, "no room" end
		moved[#moved + 1] = { p.t, lp, la }
		list[#list + 1] = p
	end
	local pids = {}
	for _, m in ipairs(moved) do
		local np = SpaceGrid.StateAdd(b.SG, m[1], m[2], m[3])
		if np then pids[#pids + 1] = np.id end
	end
	b.SG.open = b.SG.open or {}
	carryOpen(a.SG, list, function(v) return (LocalToWorld(v, angle_zero, opos, oang)) end, b.SG.open)
	-- What is welded to a (the owner's crates, a lamp on them, a StarCore core, a Wire chip) goes along with a's parts
	-- to where they are joined, and is welded to b (round 5: the welds went with a, the crates stayed behind in the air,
	-- loose). Not moved when it also hangs on another ship.
	local group = constraint.GetAllConstrainedEntities(a) or {}
	local welds = takeWelds(a)
	local toShip = true
	for e in pairs(group) do
		if IsValid(e) and e ~= a and e:GetClass() == "spacegrid_hull" then toShip = false end
	end
	-- (held still until they are welded on again: loose for the tick the new body takes, a wooden crate fell into the
	-- new floor and broke - seen)
	local thaw = {}
	if toShip then
		local ap, aa = a:GetPos(), a:GetAngles()
		local wp, wa = LocalToWorld(opos, oang, b:GetPos(), b:GetAngles())
		for e in pairs(group) do
			if IsValid(e) and e ~= a and not e:IsPlayer() then
				local lp, la = WorldToLocal(e:GetPos(), e:GetAngles(), ap, aa)
				local np, na = LocalToWorld(lp, la, wp, wa)
				local ph = e:GetPhysicsObject()
				if IsValid(ph) and ph:IsMotionEnabled() then
					ph:EnableMotion(false)
					thaw[#thaw + 1] = e
				end
				e:SetPos(np)
				e:SetAngles(na)
				if IsValid(ph) then ph:SetPos(np); ph:SetAngles(na); ph:SetVelocity(vector_origin) end
			end
		end
	end
	a:Remove()
	SpaceGrid.Commit(b)
	if b.SGRebuildQueued then
		b.SGPendingWelds = b.SGPendingWelds or {}
		for _, w in ipairs(welds) do table.insert(b.SGPendingWelds, w) end
	else
		giveWelds(b, welds)
	end
	if #thaw > 0 then
		timer.Simple(0.3, function()
			for _, e in ipairs(thaw) do
				local ph = IsValid(e) and e:GetPhysicsObject()
				if IsValid(ph) then ph:EnableMotion(true); ph:Wake() end
			end
		end)
	end
	return true, pids
end

-- Undo, the way the game's own undo of a weld goes: undoing a join cuts the ships apart again where they are now
-- (the parts that came with the join become a ship of their own); undoing a cut puts the cut-off pieces back onto
-- the ship where they were - wherever they flew since - with what is welded to them. Each returns true, or false +
-- why.
function SpaceGrid.UndoJoin(hull, pids)
	if not IsValid(hull) or not hull.SG then return false, "no such part" end
	local alive = {}
	for _, pid in ipairs(pids) do if hull.SG.parts[pid] then alive[#alive + 1] = pid end end
	if #alive == 0 or #alive >= hull.SG.count then return false, "no joint here" end
	local n = splitOff(hull, alive)
	if not n then return false, "no joint here" end
	-- (what was built since may now hang on nothing: a ship of its own, as when a part is taken off)
	local islands = SpaceGrid.StateIslands(hull.SG)
	for i = 2, #islands do splitOff(hull, islands[i]) end
	SpaceGrid.Commit(hull)
	return true, n
end

function SpaceGrid.UndoCut(hull, made)
	if not IsValid(hull) or not hull.SG then return false, "no such part" end
	local any, why = false, nil
	for _, n in ipairs(made) do
		local from = IsValid(n) and n.SG and n.SGCutOf
		if from and from.hull == hull then
			local ok, w = SpaceGrid.MergeAt(n, hull, from.pos, from.ang)
			if ok then any = true else why = w end
		end
	end
	if any then return true end
	return false, why or "no such part"
end

-- the part of a hull at a world position (e.g. a trace's HitPos, pushed in a little along the hit normal)
-- open or shut an end by hand (key: SpaceGrid.PortKey of the opening)
function SpaceGrid.SetEndOpen(hull, key, open)
	if not IsValid(hull) or not hull.SG then return end
	hull.SG.open = hull.SG.open or {}
	hull.SG.open[key] = open and true or nil
	SpaceGrid.Commit(hull, true)   -- (no building: a parked ship keeps its StarCore core)
end

-- set a plug into a joint as its wall, or take it out (cap = nil); key: SpaceGrid.PortKey of the joint
function SpaceGrid.SetJointSeal(hull, key, cap)
	if not IsValid(hull) or not hull.SG then return end
	local open = hull.SG.open or {}
	hull.SG.open = open
	for k in pairs(open) do
		if string.sub(k, 1, #key + 1) == key .. "=" then open[k] = nil end
	end
	if cap then open[key .. "=" .. cap] = true end
	SpaceGrid.Commit(hull, true)
end

-- the end wall a spot of the ship lies on (world), or nil: its key
function SpaceGrid.EndAtWorld(hull, wpos)
	local lp = hull:WorldToLocal(wpos)
	for key, e in pairs(hull.SG.ends or {}) do
		local mn, mx = SpaceGrid.PartBounds(SpaceGrid.Parts[e.t], e.pos, e.ang)
		if lp.x > mn.x - 2 and lp.x < mx.x + 2 and lp.y > mn.y - 2 and lp.y < mx.y + 2 and lp.z > mn.z - 2 and lp.z < mx.z + 2 then return key end
	end
end

-- the end opened by hand that a line from a spot (world) along a direction passes through within reach, or nil: its
-- key and how far along the line. Only the opened ends are asked (the author's play test: the nearest free
-- opening on the line was asked alone - from outside a hangar that was the far end behind it, still shut, and R
-- took the whole hangar away). A hand's width round the opening counts too: aimed at its rim, R means the end.
local RIM = 12
function SpaceGrid.OpenEndOnRay(hull, wstart, wdir, reach)
	local open = hull.SG and hull.SG.open
	if not open or not next(open) then return end
	local ls = hull:WorldToLocal(wstart)
	local ld = hull:WorldToLocal(wstart + wdir) - ls
	reach = reach or 250
	local bkey, bt
	for _, p in pairs(hull.SG.parts) do
		for i, f in ipairs(p.ports) do
			local key = not p.links[i] and SpaceGrid.PortKey(f.pos)
			local pt = key and open[key] and SpaceGrid.PortTypes[f.type]
			local dn = pt and ld:Dot(f.dir) or 0
			if math.abs(dn) > 0.05 then
				local t = (f.pos - ls):Dot(f.dir) / dn
				if t > 0 and t <= reach and (not bt or t < bt) then
					local off = ls + ld * t - f.pos
					if math.abs(off:Dot(f.up)) <= pt.h / 2 + RIM and math.abs(off:Dot(f.dir:Cross(f.up))) <= pt.w / 2 + RIM then
						bkey, bt = key, t
					end
				end
			end
		end
	end
	return bkey, bt
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
	-- a wall in a joint (sh_core.lua, JointSeals): only the wall goes, the two parts stay
	local jkey = SpaceGrid.EndAtWorld(hull, tr.HitPos)
	if jkey and hull.SG.ends[jkey] and hull.SG.ends[jkey].joint then
		SpaceGrid.SetJointSeal(hull, jkey, nil)
		return false
	end
	-- a door or field of a room (a Gate Hall's own doors): not the whole room for it, as with the build tool's R
	if door then
		local p = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
		if p and not SpaceGrid.IsDoorPart(p.t) then
			SpaceGrid.Say(ply, "say.door_of_room")
			return false
		end
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


-- Crossbow bolts. A bolt that hits a ship is taken away by the game at once, without a mark (the game treats the
-- ship as a body that takes damage: a thwack, gone) - in a map's wall a bolt sticks. So it looked as if it flew
-- through. Now a bolt that hits a ship, its glass, a door or a field of it sticks in it as in a wall: the
-- crossbow's own bolt model where it hit, riding on the ship, and the wall's sound. The damage it does is not
-- changed.
local BOLT_MODEL, BOLT_KEEP, BOLT_MAX = "models/crossbow_bolt.mdl", 20, 24
local stuckBolts = {}
hook.Add("EntityTakeDamage", "SpaceGrid.BoltSticks", function(ent, dmg)
	if not IsValid(ent) then return end
	local bolt = dmg:GetInflictor()
	if not IsValid(bolt) or bolt:GetClass() ~= "crossbow_bolt" or bolt.SGStuck then return end
	local hull = ent.SpaceGridHull and ent or nil
	if not hull then
		local par = ent:GetParent()
		if IsValid(par) and par.SpaceGridHull then hull = par end
	end
	if not hull then return end
	bolt.SGStuck = true
	local dir = bolt:GetVelocity()
	if dir:LengthSqr() < 1 then dir = bolt:GetForward() end
	dir:Normalize()
	local p = bolt:GetPos()
	local tr = util.TraceLine({ start = p - dir * 48, endpos = p + dir * 48, filter = function(e) return e == ent end })
	local at = tr.Hit and tr.HitPos or p
	timer.Simple(0, function()
		if IsValid(bolt) then bolt:Remove() end   -- (with several players the game leaves it hanging where it hit)
		if not IsValid(hull) then return end
		local s = ents.Create("prop_dynamic")
		if not IsValid(s) then return end
		s:SetModel(BOLT_MODEL)
		s:SetPos(at - dir * 6)
		s:SetAngles(dir:Angle())
		s:Spawn()
		s:SetSolid(SOLID_NONE)
		s:SetMoveType(MOVETYPE_NONE)
		s:SetParent(hull)
		s.DoNotDuplicate = true
		s.PhysgunDisabled = true
		s:EmitSound("Weapon_Crossbow.BoltHitWorld")
		hull:DeleteOnRemove(s)
		stuckBolts[#stuckBolts + 1] = s
		while #stuckBolts > BOLT_MAX do
			local old = table.remove(stuckBolts, 1)
			if IsValid(old) then old:Remove() end
		end
		timer.Simple(BOLT_KEEP, function()
			if IsValid(s) then s:Remove() end
			table.RemoveByValue(stuckBolts, s)
		end)
	end)
end)