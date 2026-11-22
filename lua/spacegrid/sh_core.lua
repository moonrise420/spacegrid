-- SpaceGrid: the parts, their ports and the maths of joining (shared: server and client must agree, both build the
-- same collision body from it).
--
-- A part  = a model + collision pieces + ports, in part space (x forward, y left, z up).
-- A port  = the middle of an opening: pos, dir (pointing out of the part), up, type (the opening's size class).
-- A hull  = one entity holding a list of parts { id, t = part id, pos, ang } in hull space, and which ports are joined.
-- The hull's state (ent.SG) is a plain table, so the same functions run on both sides.

SpaceGrid.Parts = SpaceGrid.Parts or {}        -- part id -> definition
SpaceGrid.PartIds = SpaceGrid.PartIds or {}    -- sorted ids; the position is the number sent over the network
SpaceGrid.PartNum = SpaceGrid.PartNum or {}    -- part id -> that number
SpaceGrid.MaxParts = 6000                      -- per hull

-- port types: the opening, in units (width x height); square ones may be joined turned by a quarter
SpaceGrid.PortTypes = SpaceGrid.PortTypes or {
	S = { w = 128, h = 128, square = true },
	M = { w = 256, h = 128 },
	L = { w = 256, h = 256, square = true },
	XL = { w = 512, h = 256 },
	XXL = { w = 1024, h = 512 },
	C = { w = 64, h = 64, square = true },      -- crawl ways: a player ducks through
}
-- H = a mount, no opening: one in the middle of every cell of plain wall, roof and underside. Wings, fins, landing
-- legs, dishes go onto them; and two parts that lie wall to wall or deck on deck are joined through them. Nobody
-- walks through a mount: it never counts as an open end.
SpaceGrid.PortTypes.H = SpaceGrid.PortTypes.H or { w = 128, h = 128, square = true, mount = true }
SpaceGrid.PortTypes.C = SpaceGrid.PortTypes.C or { w = 64, h = 64, square = true }
-- V = a lift shaft's opening in its floor or roof: the shaft pieces of the decks stand on each other through it
SpaceGrid.PortTypes.V = SpaceGrid.PortTypes.V or { w = 128, h = 128, square = true }
-- U = the same for ladder shafts (its own type: a ladder shaft's floors would stand in a lift's way)
SpaceGrid.PortTypes.U = SpaceGrid.PortTypes.U or { w = 128, h = 128, square = true }
-- (How the menus sort the parts: sh_menu.lua.)

function SpaceGrid.IsMount(ptype)
	local t = SpaceGrid.PortTypes[ptype]
	return t ~= nil and t.mount == true
end

-- how many of a part's ports the tool may use as "its own" one: its openings; a part with mounts only (a wing): those.
-- (The generator lists the openings first.)
function SpaceGrid.OwnPorts(def)
	local n = 0
	for _, p in ipairs(def.ports) do
		if not SpaceGrid.IsMount(p.type) then n = n + 1 end
	end
	return n > 0 and n or #def.ports
end

local function boxPoints(a, b)
	return {
		Vector(a.x, a.y, a.z), Vector(b.x, a.y, a.z), Vector(a.x, b.y, a.z), Vector(b.x, b.y, a.z),
		Vector(a.x, a.y, b.z), Vector(b.x, a.y, b.z), Vector(a.x, b.y, b.z), Vector(b.x, b.y, b.z),
	}
end

-- def: { name, model, mass, class = "S", family = "hull", boxes = { { mins, maxs }, ... }, hulls = { { points }, ... },
--        ports = { { pos, dir, up, type }, ... }, rooms = { { mins, maxs }, ... } }
function SpaceGrid.RegisterPart(id, def)
	def.id = id
	def.mass = def.mass or 100
	def.convex = {}
	for i, b in ipairs(def.boxes or {}) do def.convex[i] = boxPoints(b[1], b[2]) end
	for _, c in ipairs(def.hulls or {}) do def.convex[#def.convex + 1] = c end
	local mn, mx = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, c in ipairs(def.convex) do
		for _, v in ipairs(c) do
			mn.x, mn.y, mn.z = math.min(mn.x, v.x), math.min(mn.y, v.y), math.min(mn.z, v.z)
			mx.x, mx.y, mx.z = math.max(mx.x, v.x), math.max(mx.y, v.y), math.max(mx.z, v.z)
		end
	end
	def.mins, def.maxs = def.mins or mn, def.maxs or mx
	def.ports = def.ports or {}
	for _, p in ipairs(def.ports) do
		p.dir = p.dir:GetNormalized()
		p.up = p.up or (math.abs(p.dir.z) > 0.9 and Vector(1, 0, 0) or Vector(0, 0, 1))
		p.ang = p.dir:AngleEx(p.up)
	end
	SpaceGrid.Parts[id] = def
	local ids = table.GetKeys(SpaceGrid.Parts)
	table.sort(ids)
	SpaceGrid.PartIds = ids
	SpaceGrid.PartNum = {}
	for i, k in ipairs(ids) do SpaceGrid.PartNum[k] = i end
	return def
end

-- angles on the lattice: every component a multiple of 90
local function snap90(a)
	return Angle(math.Round(a.p / 90) % 4 * 90, math.Round(a.y / 90) % 4 * 90, math.Round(a.r / 90) % 4 * 90)
end
local function snapPos(v) return Vector(math.Round(v.x), math.Round(v.y), math.Round(v.z)) end
SpaceGrid.Snap90, SpaceGrid.SnapPos = snap90, snapPos

-- Where part `def` must sit so that its port number `own` meets a port at (tpos, tdir, tup) - all in one space
-- (hull space, or the world for a ghost). twist = quarter turns round the port's axis.
function SpaceGrid.Mate(def, own, tpos, tdir, tup, twist)
	local p = def.ports[own]
	if not p then return nil end
	local want = (-tdir):AngleEx(tup)
	if twist and twist % 4 ~= 0 then want:RotateAroundAxis(tdir, 90 * (twist % 4)) end
	local ip, ia = WorldToLocal(vector_origin, angle_zero, p.pos, p.ang)   -- the part's origin, seen from its port
	local pos, ang = LocalToWorld(ip, ia, tpos, want)
	return pos, ang
end

-- the ports of a part sitting at (pos, ang): { { pos, dir, up, type }, ... }
function SpaceGrid.PortFrames(def, pos, ang)
	local out = {}
	for i, p in ipairs(def.ports) do
		local wp, wa = LocalToWorld(p.pos, p.ang, pos, ang)
		out[i] = { pos = wp, dir = wa:Forward(), up = wa:Up(), type = p.type }
	end
	return out
end

-- do two ports (in one space) fit: same opening, same spot, facing each other, the opening the same way round
function SpaceGrid.PortsFit(a, b)
	if a.type ~= b.type then return false end
	if a.pos:DistToSqr(b.pos) > 4 then return false end
	if a.dir:Dot(b.dir) > -0.99 then return false end
	local d = math.abs(a.up:Dot(b.up))
	if d > 0.99 then return true end
	local t = SpaceGrid.PortTypes[a.type]
	return d < 0.01 and t ~= nil and t.square == true
end

-- may a part be joined there at all: is a quarter twist allowed for this opening
function SpaceGrid.TwistAllowed(ptype, twist)
	twist = (twist or 0) % 4
	if twist == 0 then return true end
	local t = SpaceGrid.PortTypes[ptype]
	if t and t.square then return true end
	return twist == 2
end

-- the box a part fills in hull space (parts turn in quarter steps, so the box is exact)
local function partBounds(def, pos, ang)
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	local a, b = def.mins, def.maxs
	local mn, mx = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for i = 0, 7 do
		local x = bit.band(i, 1) == 0 and a.x or b.x
		local y = bit.band(i, 2) == 0 and a.y or b.y
		local z = bit.band(i, 4) == 0 and a.z or b.z
		local vx = pos.x + f.x * x - r.x * y + u.x * z
		local vy = pos.y + f.y * x - r.y * y + u.y * z
		local vz = pos.z + f.z * x - r.z * y + u.z * z
		mn.x, mn.y, mn.z = math.min(mn.x, vx), math.min(mn.y, vy), math.min(mn.z, vz)
		mx.x, mx.y, mx.z = math.max(mx.x, vx), math.max(mx.y, vy), math.max(mx.z, vz)
	end
	return mn, mx
end
SpaceGrid.PartBounds = partBounds

local function portKey(v)
	return math.Round(v.x / 4) .. "," .. math.Round(v.y / 4) .. "," .. math.Round(v.z / 4)
end

-- ---------------------------------------------------------------------------------------------------------------
-- the state of a hull
function SpaceGrid.NewState()
	return { parts = {}, map = {}, count = 0, nextId = 1, open = {}, ends = {} }
end

-- would a part at (pos, ang) sit inside another part of this hull? (touching faces are fine)
function SpaceGrid.StateOverlap(st, def, pos, ang, ignore)
	local mn, mx = partBounds(def, pos, ang)
	for _, o in pairs(st.parts) do
		if o ~= ignore and mn.x < o.mx.x - 2 and mx.x > o.mn.x + 2 and mn.y < o.mx.y - 2 and mx.y > o.mn.y + 2 and mn.z < o.mx.z - 2 and mx.z > o.mn.z + 2 then
			return o
		end
	end
	return nil
end

-- add a part; every port of it that meets a fitting free port of the hull is joined. Returns the part, or nil + why.
function SpaceGrid.StateAdd(st, typ, pos, ang, pid)
	local def = SpaceGrid.Parts[typ]
	if not def then return nil, "unknown part" end
	if st.count >= SpaceGrid.MaxParts then return nil, "hull is full" end
	pid = pid or st.nextId
	if st.parts[pid] then return nil, "id taken" end
	local part = { id = pid, t = typ, pos = pos, ang = ang, links = {} }
	part.mn, part.mx = partBounds(def, pos, ang)
	part.ports = SpaceGrid.PortFrames(def, pos, ang)
	for i, f in ipairs(part.ports) do
		local key = portKey(f.pos)
		local list = st.map[key]
		if not list then list = {}; st.map[key] = list end
		for _, o in ipairs(list) do
			local op = st.parts[o[1]]
			if op and not op.links[o[2]] and not part.links[i] and SpaceGrid.PortsFit(f, op.ports[o[2]]) then
				part.links[i] = { op.id, o[2] }
				op.links[o[2]] = { pid, i }
			end
		end
		list[#list + 1] = { pid, i }
	end
	st.parts[pid] = part
	st.count = st.count + 1
	if pid >= st.nextId then st.nextId = pid + 1 end
	-- the server keeps a journal of changes (st.log) so that a click sends one part, not the whole ship
	if st.log then st.log[#st.log + 1] = part end
	return part
end

function SpaceGrid.StateRemove(st, pid)
	local part = st.parts[pid]
	if not part then return false end
	for i, l in pairs(part.links) do
		local o = st.parts[l[1]]
		if o then o.links[l[2]] = nil end
		part.links[i] = nil
	end
	for i, f in ipairs(part.ports) do
		local key = portKey(f.pos)
		local list = st.map[key]
		if list then
			for k = #list, 1, -1 do
				if list[k][1] == pid and list[k][2] == i then table.remove(list, k) end
			end
			if #list == 0 then st.map[key] = nil end
		end
	end
	st.parts[pid] = nil
	st.count = st.count - 1
	if st.log then st.log[#st.log + 1] = pid end
	return true
end

-- the groups of parts that hang together through joined ports: { { pid, pid, ... }, ... } (biggest first)
function SpaceGrid.StateIslands(st)
	local seen, out = {}, {}
	for pid in pairs(st.parts) do
		if not seen[pid] then
			local group, queue, head = {}, { pid }, 1
			seen[pid] = true
			while head <= #queue do
				local p = st.parts[queue[head]]; head = head + 1
				group[#group + 1] = p.id
				for _, l in pairs(p.links) do
					if not seen[l[1]] and st.parts[l[1]] then seen[l[1]] = true; queue[#queue + 1] = l[1] end
				end
			end
			out[#out + 1] = group
		end
	end
	table.sort(out, function(a, b) return #a > #b end)
	return out
end

-- Boxes that continue each other (same cross-section, touching or overlapping along one axis) become one box: a row of
-- corridor floors is one long plate, a deck of them one slab. The body covers exactly the same space with far fewer
-- pieces. Why: the game's physics rebuilds the whole body on every change (82 ms at 512 pieces), and the game crashed by
-- chance when a hull of more than 1000 pieces was unfrozen - SBEP never had a body above 91 pieces. boxes: { x0,
-- y0, z0, x1, y1, z1 } in whole raster steps. The result does not depend on the order of the input.
local RASTER = 8
local AXES = { { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 } }
function SpaceGrid.MergeBoxes(boxes)
	local changed, pass = true, 0
	while changed and pass < 8 do
		changed, pass = false, pass + 1
		for _, ax in ipairs(AXES) do
			local a, b, c = ax[1], ax[2], ax[3]
			local groups, order = {}, {}
			for _, bx in ipairs(boxes) do
				local key = bx[b] .. "," .. bx[b + 3] .. "," .. bx[c] .. "," .. bx[c + 3]
				local g = groups[key]
				if not g then
					g = {}
					groups[key] = g
					order[#order + 1] = g
				end
				g[#g + 1] = bx
			end
			local out, n = {}, 0
			for _, g in ipairs(order) do
				if #g > 1 then table.sort(g, function(p, r) return p[a] < r[a] end) end
				local cur = g[1]
				for i = 2, #g do
					local nx = g[i]
					if nx[a] <= cur[a + 3] then
						if nx[a + 3] > cur[a + 3] then cur[a + 3] = nx[a + 3] end
						changed = true
					else
						n = n + 1
						out[n] = cur
						cur = nx
					end
				end
				n = n + 1
				out[n] = cur
			end
			boxes = out
		end
	end
	return boxes
end

-- Closed by default (the owner,: "so many parts missing walls ... it should be logic and easy to build"). Every
-- opening of a ship that nothing is joined to is shut by an end wall: the end cap of its size stands there by itself
-- - drawn, solid, airtight. Joining a part there takes it away. The build tool's Reload on a wall opens that end for
-- good (st.open, by the opening's place), Reload aimed at the opening shuts it again. No wall where a door of the
-- part already closes the way (the outer side of a doorway, an airlock, a gate: a way in), and none where another
-- part is in the way. Switch: spacegrid_closedends 0 (server) - ends stay open as they were before.
SpaceGrid.EndCap = { S = "s_cap", M = "m_cap", L = "l_cap", XL = "xl_cap", XXL = "xxl_cap", C = "c_cap", V = "s_cap", U = "s_cap" }
local cvClosed = CreateConVar("spacegrid_closedends", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), "SpaceGrid: every open end of a ship is shut by a wall by itself (1) or stays open (0)")
SpaceGrid.PortKey = portKey
-- the outside parts that may also stand on the deck inside a room (on its inside mounts)
SpaceGrid.InsideParts = { o_crate = true, o_tank = true }

-- does a port (part space) lie behind one of the part's doors, seen from the part's middle?
local function behindDoor(def, p)
	local list = def.doors or (def.door and { def.door })
	if not list then return false end
	local mid = (def.mins + def.maxs) / 2
	for _, d in ipairs(list) do
		local a = Angle(0, d.yaw or 0, 0)
		local n, t = a:Forward(), a:Right()
		local sp, sm = (p.pos - d.pos):Dot(n), (mid - d.pos):Dot(n)
		if math.abs(sp) > 2 and math.abs((p.pos - d.pos):Dot(t)) <= (d.w or 64) / 2 + 40 and (math.abs(sm) < 2 or (sp > 0) ~= (sm > 0)) then return true end
	end
	return false
end

-- the end walls of a hull: key (SpaceGrid.PortKey of the opening) -> { t = the cap's part id, pos, ang (hull space),
-- part, port }. Kept in st.ends (the body, the air and the drawing all read it).
-- Walls in joints (two Gate Halls joined at the big opening and at the corridors - the big opening shall be shut,
-- the corridors stay the way through). A plug (end cap, glass or force-field plug) set into a joint is kept in
-- st.open as "<key>=<plug id>" - so it is saved, copied and sent with the opened ends, nothing new on the way -
-- and stands in st.ends like an end wall, with joint = true: on the part of the joint with the lower id,
-- reaching into the other one by its own thickness.
function SpaceGrid.JointSeals(st)
	local out = {}
	for k in pairs(st.open or {}) do
		local key, cap = string.match(k, "^(.-)=(.+)$")
		if key then out[key] = cap end
	end
	return out
end

-- the carrier of a joint: the joined port at that place on the part with the lowest id (part, port number)
local function jointAt(st, key)
	local bp, bi
	for _, o in ipairs(st.map[key] or {}) do
		local p = st.parts[o[1]]
		if p and p.links[o[2]] and (not bp or p.id < bp.id) then bp, bi = p, o[2] end
	end
	return bp, bi
end
SpaceGrid.StateJointAt = jointAt

-- may this part go into a joint as its wall: a plug of the joint's size
function SpaceGrid.IsPlug(id)
	return id ~= nil and (string.find(id, "_cap$") or string.find(id, "_glasscap$") or string.find(id, "_fieldcap$")
		or string.find(id, "_shuttercap$") or string.find(id, "_blastcap$") or string.find(id, "_jawscap$") or string.find(id, "_autocap$")) ~= nil   -- (the flat hangar doors)
end

function SpaceGrid.StateEnds(st)
	local ends = {}
	st.ends = ends
	for key, cap in pairs(SpaceGrid.JointSeals(st)) do
		local cdef = SpaceGrid.Parts[cap]
		local bp, bi = jointAt(st, key)
		local f = bp and bp.ports[bi]
		if cdef and f and cdef.ports[1] and cdef.ports[1].type == f.type then
			local pos, ang = SpaceGrid.Mate(cdef, 1, f.pos, f.dir, f.up, 0)
			ends[key] = { t = cap, pos = snapPos(pos), ang = snap90(ang), part = bp.id, port = bi, joint = true }
		end
	end
	if not cvClosed:GetBool() then return ends end
	local open = st.open or {}
	for _, part in pairs(st.parts) do
		local def = SpaceGrid.Parts[part.t]
		for i, f in ipairs(part.ports) do
			local cap = not part.links[i] and not def.noends and SpaceGrid.EndCap[f.type]   -- (noends: a force-field plug)
			local cdef = cap and SpaceGrid.Parts[cap]
			if cdef then
				local key = portKey(f.pos)
				local here = st.map[key]
				if not open[key] and (not here or #here <= 1) and not behindDoor(def, def.ports[i]) then
					local pos, ang = SpaceGrid.Mate(cdef, 1, f.pos, f.dir, f.up, 0)
					pos, ang = snapPos(pos), snap90(ang)
					if not SpaceGrid.StateOverlap(st, cdef, pos, ang, part) then
						ends[key] = { t = cap, pos = pos, ang = ang, part = part.id, port = i }
					end
				end
			end
		end
	end
	return ends
end

-- Guard. The game's physics crashed by chance when a frozen body of more than 1000 pieces was set moving (seen at
-- 1001, 1216 and 2048 pieces, never at 513 or below). Merged bodies stay far below that (2197 corridor
-- cells = 200 pieces), but a very big, very mixed ship could get there. Above MaxPieces a hull stays frozen: it can
-- be built on, not moved (sv_hull.lua, cl_hull.lua and the entity ask SpaceGrid.TooBig).
-- The trace test of the small entities that ride on a ship and answer traces themselves (ENT:TestCollision of the
-- doors, fields, lifts, lamps, switches, nav boxes): their box mn..mx in the entity's space. A box that starts on or
-- in it - a player touching it, or one a door shut on - is stopped only going into it through the face he is
-- nearest to; every other way he goes free. (by a flat door's control panel he stuck and could not move - the plain
-- ray test said "hit at once" for every way out of a touch.)
local BOX_EPS = 0.5
local BOX_FACES = { { 1, -1 }, { 1, 1 }, { 2, -1 }, { 2, 1 }, { 3, -1 }, { 3, 1 } }
function SpaceGrid.BoxHit(ent, start, delta, isbox, extents, mn, mx)
	if isbox and extents then mn, mx = mn - extents, mx + extents end
	local pos, ang = ent:GetPos(), ent:GetAngles()
	local ls = WorldToLocal(start, angle_zero, pos, ang)
	if ls.x > mn.x - BOX_EPS and ls.x < mx.x + BOX_EPS and ls.y > mn.y - BOX_EPS and ls.y < mx.y + BOX_EPS and ls.z > mn.z - BOX_EPS and ls.z < mx.z + BOX_EPS then
		-- how deep in it a place is (0 or less: outside or on its face), and the face it is nearest to
		local function depth(q)
			local best, n = math.huge, nil
			for _, f in ipairs(BOX_FACES) do
				local d = f[2] < 0 and q[f[1]] - mn[f[1]] or mx[f[1]] - q[f[1]]
				if d < best then
					best = d
					n = Vector(0, 0, 0)
					n[f[1]] = f[2]
				end
			end
			return best, n
		end
		local d0, n = depth(ls)
		local ld = WorldToLocal(delta, angle_zero, vector_origin, ang)
		-- only a move that goes deeper in is stopped: one who stands right in the middle of a shut door goes out either
		-- way (the nearest face alone stopped him going out of the other one)
		local d1 = depth(ls + ld)
		if d1 <= math.max(d0, 0) + 0.01 then return nil end
		return { HitPos = start, Fraction = 0, Normal = LocalToWorld(n, angle_zero, vector_origin, ang) }
	end
	local hit, normal, frac = util.IntersectRayWithOBB(start, delta, pos, ang, mn, mx)
	if hit then return { HitPos = hit, Fraction = frac, Normal = normal } end
end

-- (the cause was the physics' pair list of a moving body; a hull now follows its keel as a shadow and has no such list
-- - sv_keel.lua. The guard stays for very big ships, where building and drawing get slow.)
SpaceGrid.MaxPieces = SpaceGrid.MaxPieces or 4000
function SpaceGrid.TooBig(ent)
	return IsValid(ent) and ent.SpaceGridHull == true and (ent.SGPieces or 0) > SpaceGrid.MaxPieces
end

local function axisOnly(x, y, z)
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	return (ax < 0.001 or ax > 0.999) and (ay < 0.001 or ay > 0.999) and (az < 0.001 or az > 0.999)
end

-- every collision piece of the hull as point lists in hull space, its bounds, its mass, and the number of pieces
-- before merging. SpaceGrid.MergeCollision = false keeps every part's own boxes (for measurements).
function SpaceGrid.StateCollision(st)
	local conv, n, mass, raw = {}, 0, 0, 0
	local boxes, nb = {}, 0
	local merge = SpaceGrid.MergeCollision ~= false
	local floor, min, max = math.floor, math.min, math.max
	local mn, mx = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, part in pairs(st.parts) do
		local def = SpaceGrid.Parts[part.t]
		local f, r, u = part.ang:Forward(), part.ang:Right(), part.ang:Up()
		local fx, fy, fz, rx, ry, rz, ux, uy, uz = f.x, f.y, f.z, r.x, r.y, r.z, u.x, u.y, u.z
		local px, py, pz = part.pos.x, part.pos.y, part.pos.z
		local first = 1
		-- a part that stands square in the hull (the normal case): its boxes stay boxes and can be merged
		if merge and def.boxes and axisOnly(fx, fy, fz) and axisOnly(rx, ry, rz) and axisOnly(ux, uy, uz) then
			for _, b in ipairs(def.boxes) do
				local p, q = b[1], b[2]
				local x0, y0, z0 = px + fx * p.x - rx * p.y + ux * p.z, py + fy * p.x - ry * p.y + uy * p.z, pz + fz * p.x - rz * p.y + uz * p.z
				local x1, y1, z1 = px + fx * q.x - rx * q.y + ux * q.z, py + fy * q.x - ry * q.y + uy * q.z, pz + fz * q.x - rz * q.y + uz * q.z
				nb = nb + 1
				boxes[nb] = {
					floor(min(x0, x1) * RASTER + 0.5), floor(min(y0, y1) * RASTER + 0.5), floor(min(z0, z1) * RASTER + 0.5),
					floor(max(x0, x1) * RASTER + 0.5), floor(max(y0, y1) * RASTER + 0.5), floor(max(z0, z1) * RASTER + 0.5),
				}
			end
			first = #def.boxes + 1
			raw = raw + #def.boxes
		end
		for k = first, #def.convex do
			local out = {}
			for i, v in ipairs(def.convex[k]) do
				local x, y, z = v.x, v.y, v.z
				out[i] = Vector(px + fx * x - rx * y + ux * z, py + fy * x - ry * y + uy * z, pz + fz * x - rz * y + uz * z)
			end
			n = n + 1
			conv[n] = out
			raw = raw + 1
		end
		mass = mass + def.mass
		mn.x, mn.y, mn.z = math.min(mn.x, part.mn.x), math.min(mn.y, part.mn.y), math.min(mn.z, part.mn.z)
		mx.x, mx.y, mx.z = math.max(mx.x, part.mx.x), math.max(mx.y, part.mx.y), math.max(mx.z, part.mx.z)
	end
	-- the end walls (StateEnds): their boxes are part of the body as a part's are
	for _, e in pairs(SpaceGrid.StateEnds(st)) do
		local def = SpaceGrid.Parts[e.t]
		local f, r, u = e.ang:Forward(), e.ang:Right(), e.ang:Up()
		for _, b in ipairs(def.boxes or {}) do
			local p, q = b[1], b[2]
			local a = e.pos + f * p.x - r * p.y + u * p.z
			local c = e.pos + f * q.x - r * q.y + u * q.z
			if merge then
				nb = nb + 1
				boxes[nb] = {
					floor(min(a.x, c.x) * RASTER + 0.5), floor(min(a.y, c.y) * RASTER + 0.5), floor(min(a.z, c.z) * RASTER + 0.5),
					floor(max(a.x, c.x) * RASTER + 0.5), floor(max(a.y, c.y) * RASTER + 0.5), floor(max(a.z, c.z) * RASTER + 0.5),
				}
			else
				n = n + 1
				conv[n] = boxPoints(Vector(min(a.x, c.x), min(a.y, c.y), min(a.z, c.z)), Vector(max(a.x, c.x), max(a.y, c.y), max(a.z, c.z)))
			end
			raw = raw + 1
		end
		local cmn, cmx = partBounds(def, e.pos, e.ang)
		mn.x, mn.y, mn.z = min(mn.x, cmn.x), min(mn.y, cmn.y), min(mn.z, cmn.z)
		mx.x, mx.y, mx.z = max(mx.x, cmx.x), max(mx.y, cmx.y), max(mx.z, cmx.z)
	end
	if nb > 0 then
		for _, b in ipairs(SpaceGrid.MergeBoxes(boxes)) do
			n = n + 1
			conv[n] = boxPoints(Vector(b[1] / RASTER, b[2] / RASTER, b[3] / RASTER), Vector(b[4] / RASTER, b[5] / RASTER, b[6] / RASTER))
		end
	end
	return conv, mn, mx, mass, raw
end

-- the part at a point of the hull (hull space), e.g. where a trace hit: the part whose box holds the point, the
-- nearest middle winning
function SpaceGrid.StatePartAt(st, lpos, slack)
	slack = slack or 3
	local best, bd
	for _, p in pairs(st.parts) do
		if lpos.x > p.mn.x - slack and lpos.x < p.mx.x + slack and lpos.y > p.mn.y - slack and lpos.y < p.mx.y + slack and lpos.z > p.mn.z - slack and lpos.z < p.mx.z + slack then
			local d = lpos:DistToSqr((p.mn + p.mx) / 2)
			if not bd or d < bd then best, bd = p, d end
		end
	end
	return best
end

-- the free port of the hull nearest to a point (hull space), not farther than maxDist: part, port number
function SpaceGrid.StateFreePort(st, lpos, maxDist, ptype)
	local best, bi, bd = nil, nil, (maxDist or 200) ^ 2
	local mount = SpaceGrid.IsMount
	for _, p in pairs(st.parts) do
		for i, f in ipairs(p.ports) do
			-- (without a size asked for: an open end, never a mount)
			if not p.links[i] and ((ptype and f.type == ptype) or (not ptype and not mount(f.type))) then
				local d = lpos:DistToSqr(f.pos)
				if d < bd then best, bi, bd = p, i, d end
			end
		end
	end
	return best, bi
end

-- The open end a ray passes through (hull space): from `start` along the unit vector `dir`, not farther than maxT.
-- An opening the ray leaves the ship through wins over one it enters through (the new part then appears where the
-- player looks, not round their head); among equals the nearer one. ptype: only openings of that size count.
-- Returns part, port number, distance, leaving - and as fifth value the size of an opening of another size the ray
-- went through (for the "wrong size" message).
function SpaceGrid.StateRayPort(st, start, dir, maxT, ptype)
	local best, bi, bt, bout, other
	for _, p in pairs(st.parts) do
		for i, f in ipairs(p.ports) do
			local dn = not p.links[i] and dir:Dot(f.dir) or 0
			if dn > 0.05 or dn < -0.05 then
				local t = (f.pos - start):Dot(f.dir) / dn
				local pt = SpaceGrid.PortTypes[f.type]
				if pt and not pt.mount and t > 0 and t <= maxT then   -- (a mount is no opening to look through)
					local off = start + dir * t - f.pos
					if math.abs(off:Dot(f.up)) <= pt.h / 2 and math.abs(off:Dot(f.dir:Cross(f.up))) <= pt.w / 2 then
						local out = dn > 0
						if ptype and f.type ~= ptype then
							other = other or f.type
						elseif not best or (out and not bout) or (out == bout and t < bt) then
							best, bi, bt, bout = p, i, t, out
						end
					end
				end
			end
		end
	end
	return best, bi, bt, bout, other
end

-- The joint a ray passes through (hull space; a joint = two joined openings at one place), nearest first, of the
-- size `ptype` if given: its key, the carrier part and port (StateJointAt), the distance - or nil.
function SpaceGrid.StateRayJoint(st, start, dir, maxT, ptype)
	local bkey, bp, bi, bt
	for _, p in pairs(st.parts) do
		for i, f in ipairs(p.ports) do
			local pt = p.links[i] and (not ptype or f.type == ptype) and SpaceGrid.PortTypes[f.type]
			local dn = pt and not pt.mount and dir:Dot(f.dir) or 0
			if math.abs(dn) > 0.05 then
				local t = (f.pos - start):Dot(f.dir) / dn
				if t > 0 and t <= maxT and (not bt or t < bt - 0.5) then
					local off = start + dir * t - f.pos
					if math.abs(off:Dot(f.up)) <= pt.h / 2 and math.abs(off:Dot(f.dir:Cross(f.up))) <= pt.w / 2 then
						local key = portKey(f.pos)
						local cp, ci = jointAt(st, key)
						if cp then bkey, bp, bi, bt = key, cp, ci, t end
					end
				end
			end
		end
	end
	return bkey, bp, bi, bt
end

-- The joint (two parts joined at an opening) of type ptype nearest to a point (hull space), within maxDist of the
-- opening's middle. Returns key, carrier part, port, distance - or nil. (a plug aimed from outside at the seam of two
-- joined halls was refused - "no free port of that size here" - though the joint was right there.)
function SpaceGrid.StateNearJoint(st, pos, maxDist, ptype)
	local bkey, bp, bi, bd
	for _, p in pairs(st.parts) do
		for i, f in ipairs(p.ports) do
			if p.links[i] and (not ptype or f.type == ptype) and not SpaceGrid.IsMount(f.type) then
				local d = f.pos:Distance(pos)
				if d <= maxDist and (not bd or d < bd - 0.5) then
					local key = portKey(f.pos)
					local cp, ci = jointAt(st, key)
					if cp then bkey, bp, bi, bd = key, cp, ci, d end
				end
			end
		end
	end
	return bkey, bp, bi, bd
end

-- how many ports are open (nothing joined there)
function SpaceGrid.StateOpenPorts(st)
	local n = 0
	for _, p in pairs(st.parts) do
		for i, f in ipairs(p.ports) do
			if not p.links[i] and not SpaceGrid.IsMount(f.type) then n = n + 1 end
		end
	end
	return n
end

-- Where the chosen part would go when the player aims at `hitLocal` (hull space) of a hull: the nearest free port
-- that the part's port `own` fits. Returns pos, ang (hull space), target part, target port - or nil + why.
function SpaceGrid.Placement(st, typ, own, twist, hitLocal)
	local def = SpaceGrid.Parts[typ]
	if not def then return nil, "unknown part" end
	if #def.ports == 0 then return nil, "part has no ports" end
	own = (own - 1) % #def.ports + 1
	local tp, ti = SpaceGrid.StateFreePort(st, hitLocal, 260, def.ports[own].type)
	if not tp then return nil, "no free port of that size here" end
	return SpaceGrid.PlacementAt(st, typ, own, twist, tp, ti)
end

-- the same for a given open end (part tp, its port ti)
function SpaceGrid.PlacementAt(st, typ, own, twist, tp, ti)
	local def = SpaceGrid.Parts[typ]
	if not def then return nil, "unknown part" end
	if #def.ports == 0 then return nil, "part has no ports" end
	own = (own - 1) % #def.ports + 1
	local ptype = def.ports[own].type
	local f = tp.ports[ti]
	if not f or tp.links[ti] or f.type ~= ptype then return nil, "no free port of that size here" end
	if not SpaceGrid.TwistAllowed(ptype, twist) then twist = 0 end
	-- The turn counts from the way the part stands upright on the ship (its up nearest the hull's up). On an opening
	-- of a part that was itself set on turned (a hall joined upside down), "not turned" was turned too: a cockpit came
	-- on sideways or on its head (the author's play test). Where the opening sits upright the upright way is turn 0, as
	-- before.
	local sq = SpaceGrid.PortTypes[ptype] and SpaceGrid.PortTypes[ptype].square
	local base, upBest = 0, -2
	for b = 0, 3, sq and 1 or 2 do
		local _, a = SpaceGrid.Mate(def, own, f.pos, f.dir, f.up, b)
		local u = a:Up().z
		if u > upBest + 0.01 then base, upBest = b, u end
	end
	twist = (base + (twist or 0)) % 4
	local pos, ang = SpaceGrid.Mate(def, own, f.pos, f.dir, f.up, twist)
	pos, ang = snapPos(pos), snap90(ang)
	-- a mount on a deck inside a room (cargo stands there): the part it stands in is not in its way
	local inside
	if SpaceGrid.IsMount(ptype) then
		local q = f.pos + f.dir * 8
		if q.x > tp.mn.x and q.x < tp.mx.x and q.y > tp.mn.y and q.y < tp.mx.y and q.z > tp.mn.z and q.z < tp.mx.z then inside = tp end
	end
	-- only what belongs in a room stands on a deck inside: a wing or a truss there would reach through the walls
	-- into the next parts (and bodies that cross each other are what the game's physics is touchy about)
	if inside and not SpaceGrid.InsideParts[typ] then return nil, "no room", pos, ang end
	if SpaceGrid.StateOverlap(st, def, pos, ang, inside) then return nil, "no room", pos, ang end
	return pos, ang, tp, ti
end
