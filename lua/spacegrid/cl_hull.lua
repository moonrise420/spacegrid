-- SpaceGrid: hulls on the client - take the part list from the server, build the same collision body, draw the parts.
local pending = {}   -- entity index -> { rev, total, parts = {} } while the chunks of a list arrive

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
