-- SpaceGrid: hulls on the client - take the part list from the server, build the same collision body, draw the parts.
local pending = {}   -- entity index -> { rev, total, parts = {} } while the chunks of a list arrive

-- Every model and merged-mesh helper drawn for a hull is noted here with its hull and the list that holds it. Once a
-- second they are looked over: one whose hull is gone, or whose hull no longer holds it, is removed; one that has come
-- off its hull is hung on it again. (A player,: after deleting, one part's model stayed in the world - it looked like
-- a prop, touched nothing and did not go on "Clear everything". No way of removing found in the tests left one; this
-- catches whatever does - e.g. a full update that makes the hull entity anew on a server.) The
-- look-over goes a few pieces per frame (64), not all at once: all 2400 pieces of a 2048-part ship in one go took 1.5
-- ms (2.4 ms at worst) - a small jolt once a second (measured). A round starts at most once a second.
local owned = {}   -- model -> { hull, holder (the table that holds it), key, lpos, lang }
local list = {}    -- the same models in a row, for the look-over
local BATCH = 64
function SpaceGrid.OwnModel(m, hull, holder, key, lpos, lang)
	if not owned[m] then list[#list + 1] = m end
	owned[m] = { hull = hull, holder = holder, key = key, lpos = lpos, lang = lang }
end
local function holds(o, m)
	local h = o.hull
	if not IsValid(h) or not h.SpaceGridHull then return false end
	local t = o.holder
	if t ~= h.SGModels and t ~= h.SGEndModels and not (h.SGChunks and h.SGChunks[o.key] == t) then return false end
	if t.ents then
		for _, e in ipairs(t.ents) do if e == m then return true end end
		return false
	end
	return t[o.key] == m
end
-- one piece looked over: true = it stays in the row
local function look(m)
	local o = owned[m]
	if not o or not IsValid(m) then
		owned[m] = nil
		return false
	end
	if not holds(o, m) then
		m.SGRender = nil   -- (a merged-mesh helper: it must not draw its mesh any more)
		m:SetNoDraw(true)
		m:Remove()
		owned[m] = nil
		return false
	end
	if m:GetParent() ~= o.hull then
		m:SetParent(o.hull)
		m:SetLocalPos(o.lpos)
		m:SetLocalAngles(o.lang)
	end
	return true
end
local cursor, nextRound = 1, 0
-- up to `n` pieces from where the round stands (a piece that goes takes the last one's place in the row)
local function step(n, now)
	if cursor > #list then
		if not now and RealTime() < nextRound then return end
		cursor, nextRound = 1, RealTime() + 1
	end
	local done = 0
	while done < n and cursor <= #list do
		if look(list[cursor]) then
			cursor = cursor + 1
		else
			list[cursor] = list[#list]
			list[#list] = nil
		end
		done = done + 1
	end
end
local paused = false
hook.Add("Think", "SpaceGrid.ModelSweep", function()
	if not paused then step(BATCH) end
end)
-- for tests: one whole round at once, one frame's share, pause / go on, how many are noted
function SpaceGrid.ModelSweep()
	cursor = #list + 1
	nextRound = 0
	step(math.huge)
end
function SpaceGrid.ModelSweepStep() step(BATCH, true) end   -- (a round goes on at once: every call does a full share)
function SpaceGrid.ModelSweepPause(p) paused = p and true or false end
function SpaceGrid.OwnedCount() return #list end

-- one model per part, hanging on the hull (the engine culls and lights them one by one)
-- the model of one part: made, moved or (the part is gone) removed
local function syncPart(hull, pid)
	-- a touched part's block stops being a merged mesh (cl_mesh.lua)
	if SpaceGrid.MeshTouch then SpaceGrid.MeshTouch(hull, pid) end
	local models = hull.SGModels
	local p = hull.SG.parts[pid]
	local m = models[pid]
	if not p then
		if IsValid(m) then m:Remove() end
		models[pid] = nil
		return
	end
	local def = SpaceGrid.Parts[p.t]
	if IsValid(m) and m.SGType ~= p.t then m:Remove(); m = nil end
	if not IsValid(m) then
		m = ClientsideModel(def.model, def.translucent and RENDERGROUP_BOTH or RENDERGROUP_OPAQUE)
		if not IsValid(m) then return end
		m.SGType = p.t
		m:SetParent(hull)
		models[pid] = m
	end
	m:SetLocalPos(p.pos)
	m:SetLocalAngles(p.ang)
	SpaceGrid.OwnModel(m, hull, models, pid, p.pos, p.ang)
	if def.skin then m:SetSkin(def.skin) end
	m:SetNoDraw(hull:IsDormant())
end

SpaceGrid.SyncPart = syncPart

-- the end walls (sh_core.lua, StateEnds): one end cap model each, hanging on the hull
local function syncEnds(hull)
	local have = hull.SGEndModels or {}
	hull.SGEndModels = have
	local ends = hull.SG.ends or {}
	for key, m in pairs(have) do
		local e = ends[key]
		if not e or not IsValid(m) or m.SGType ~= e.t or m.SGPos ~= e.pos or m.SGAng ~= e.ang then
			if IsValid(m) then m:Remove() end
			have[key] = nil
		end
	end
	for key, e in pairs(ends) do
		if not have[key] then
			local m = ClientsideModel(SpaceGrid.Parts[e.t].model, RENDERGROUP_OPAQUE)
			if IsValid(m) then
				m.SGType, m.SGPos, m.SGAng = e.t, e.pos, e.ang
				m:SetParent(hull)
				m:SetLocalPos(e.pos)
				m:SetLocalAngles(e.ang)
				m:SetNoDraw(hull:IsDormant())
				have[key] = m
				SpaceGrid.OwnModel(m, hull, have, key, e.pos, e.ang)
			end
		end
	end
end
SpaceGrid.SyncEnds = syncEnds

local function syncModels(hull)
	for pid in pairs(hull.SG.parts) do syncPart(hull, pid) end
	for pid in pairs(hull.SGModels) do
		if not hull.SG.parts[pid] then syncPart(hull, pid) end
	end
end

local function apply(hull, rev, parts, open)
	local t0 = SysTime()
	local st = SpaceGrid.NewState()
	for _, p in ipairs(parts) do
		if SpaceGrid.Parts[p[1]] then SpaceGrid.StateAdd(st, p[1], p[3], p[4], p[2]) end
	end
	st.open = open or {}
	hull.SG = st
	hull.SGRevHave = rev
	hull:SGRebuild()
	syncEnds(hull)
	hull.SGBuildMs = (SysTime() - t0) * 1000
	syncModels(hull)
	hull.SGSyncMs = (SysTime() - t0) * 1000
end

local function readOpen()
	local set = {}
	for _ = 1, net.ReadUInt(12) do set[net.ReadString()] = true end
	return set
end

local function readPart()
	local num, pid = net.ReadUInt(12), net.ReadUInt(16)
	local x, y, z = net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
	local p, w, r = net.ReadUInt(2), net.ReadUInt(2), net.ReadUInt(2)
	return { SpaceGrid.PartIds[num], pid, Vector(x, y, z), Angle(p * 90, w * 90, r * 90) }
end

-- a few changes to a hull whose list is here already: only those parts and their models are touched (the body is
-- built anew, it is small). Anything else - hull not known, a revision missed - is left to ENT:Think, which asks for
-- the whole list.
net.Receive("SpaceGrid.Delta", function()
	local idx, rev, n = net.ReadUInt(16), net.ReadUInt(32), net.ReadUInt(8)
	local ops = {}
	for i = 1, n do
		if net.ReadBool() then ops[i] = readPart() else ops[i] = net.ReadUInt(16) end
	end
	local open = readOpen()
	local hull = Entity(idx)
	if not IsValid(hull) or not hull.SpaceGridHull or not hull.SG or hull.SGRevHave ~= rev - 1 then return end
	local t0 = SysTime()
	local st, touched = hull.SG, {}
	for _, op in ipairs(ops) do
		if isnumber(op) then
			SpaceGrid.StateRemove(st, op)
			touched[op] = true
		elseif SpaceGrid.Parts[op[1]] then
			SpaceGrid.StateAdd(st, op[1], op[3], op[4], op[2])
			touched[op[2]] = true
		end
	end
	st.open = open
	hull.SGRevHave = rev
	hull:SGRebuild()
	hull.SGBuildMs = (SysTime() - t0) * 1000
	for pid in pairs(touched) do syncPart(hull, pid) end
	syncEnds(hull)
	hull.SGSyncMs = (SysTime() - t0) * 1000
	hull.SGDeltas = (hull.SGDeltas or 0) + 1
end)

net.Receive("SpaceGrid.Hull", function()
	local idx, rev, total, at, n = net.ReadUInt(16), net.ReadUInt(32), net.ReadUInt(16), net.ReadUInt(16), net.ReadUInt(16)
	local got = pending[idx]
	if not got or got.rev ~= rev then got = { rev = rev, total = total, parts = {} }; pending[idx] = got end
	for i = at, at + n - 1 do
		got.parts[i] = readPart()
	end
	got.open = readOpen()
	if #got.parts < total then return end
	pending[idx] = nil
	local hull = Entity(idx)
	-- not known here yet (out of sight): it asks for the list itself once it appears (ENT:Think)
	if not IsValid(hull) or not hull.SpaceGridHull or not hull.SG then return end
	apply(hull, rev, got.parts, got.open)
end)

-- the physgun's own guess on the client must match the server's no (sv_hull.lua)
hook.Add("PhysgunPickup", "SpaceGrid.TooBig", function(_, ent)
	if SpaceGrid.TooBig(ent) then return false end
end)

-- out of sight: the server stops updating the hull, so its part models are hidden with it
hook.Add("NotifyShouldTransmit", "SpaceGrid.Hull", function(ent, should)
	if not ent.SpaceGridHull or not ent.SGModels then return end
	for _, m in pairs(ent.SGModels) do
		if IsValid(m) then m:SetNoDraw(not should) end
	end
	for _, m in pairs(ent.SGEndModels or {}) do
		if IsValid(m) then m:SetNoDraw(not should) end
	end
end)
