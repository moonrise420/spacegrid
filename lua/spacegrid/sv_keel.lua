-- SpaceGrid: the keel - a ship flies, falls and lands as a few big blocks; the ship one sees follows it.
--
-- The game's physics keeps, for every body that moves, lists of the piece pairs it watches, numbered with 16 bits
-- (~65,500 and ~32,700 entries); when one is full the game crashes (vphysics access violation, 32- and 64-bit alike).
-- A moving hull of a few hundred pieces got there as soon as its bounding sphere reached into the map's solid: on
-- flatgrass from ~340 pieces, on freespace13's broken ground from ~140 - even flying high, a long ship's sphere is big
-- (the owner's crash /21: four Gate halls on freespace13's grass, unfrozen when he sat down at the helm). No game
-- setting and no collision rule stops it; a "shadow" body (as lift platforms are) crashed too once it was near the
-- map. Only a FROZEN body never counts (tested: 494 pieces, its sphere 6000 into the ground, moved every tick). So:
--  * the hull (every part, what players walk on and shots hit) stays frozen; after every physics step it is put where
--    its keel is (players inside a flying ship are carried by StarCore's sh_walk.lua; loose props: below);
--  * the keel (entities/spacegrid_keel.lua) is the ship's body for the physics: at most KEEL_MAX blocks round its
--    parts, the ship's mass. It falls, lands, is flown by StarCore, is frozen and unfrozen. It touches only the map
--    and other ships' hulls - never players, props or its own hull.
-- Nothing is welded between the two: the hull goes exactly where the keel is, so the ship stays one rigid ship.

local KEEL_MAX = 24        -- blocks of a keel at most (few pieces: far below the pair lists' limits on any map)
-- (a ship this small may be held with the physgun as one moving body, as before; on freespace13 one Gate hall of 78
-- pieces never crashed as a moving body, two of 137 did)
local PHYSGUN_MAX = 80
-- the keel's blocks in hull space: the parts' boxes, put together per cell of a grid that grows until few are left
function SpaceGrid.KeelBoxes(st)
	local boxes = {}
	for _, p in pairs(st.parts) do
		local def = SpaceGrid.Parts[p.t]
		local a, b = SpaceGrid.PartBounds(def, p.pos, p.ang)
		if a then boxes[#boxes + 1] = { a, b } end
	end
	local min, max, floor = math.min, math.max, math.floor
	local cell, out = 256, boxes
	while #out > KEEL_MAX do
		local cells, list = {}, {}
		for _, bx in ipairs(boxes) do
			local a, b = bx[1], bx[2]
			local k = floor((a.x + b.x) / 2 / cell) .. "," .. floor((a.y + b.y) / 2 / cell) .. "," .. floor((a.z + b.z) / 2 / cell)
			local u = cells[k]
			if u then
				u[1] = Vector(min(u[1].x, a.x), min(u[1].y, a.y), min(u[1].z, a.z))
				u[2] = Vector(max(u[2].x, b.x), max(u[2].y, b.y), max(u[2].z, b.z))
			else
				u = { Vector(a), Vector(b) }
				cells[k] = u
				list[#list + 1] = u
			end
		end
		out = list
		cell = cell * 2
	end
	return out
end

local function corners(a, b)
	return { Vector(a.x, a.y, a.z), Vector(b.x, a.y, a.z), Vector(a.x, b.y, a.z), Vector(b.x, b.y, a.z),
		Vector(a.x, a.y, b.z), Vector(b.x, a.y, b.z), Vector(a.x, b.y, b.z), Vector(b.x, b.y, b.z) }
end

-- the body that moves the ship: the keel's physics object (the hull's own while it has no keel)
function SpaceGrid.Body(hull)
	local k = IsValid(hull) and hull.SGKeel
	if IsValid(k) then return k:GetPhysicsObject() end
	return IsValid(hull) and hull:GetPhysicsObject() or nil
end

-- What is welded to the keel (StarCore's core) must not point at a destroyed body when the keel is made anew: those
-- welds are taken off and made again a tick later (the same as sv_hull.lua's takeWelds / giveWelds for the hull; a weld
-- left on a removed body crashed the game).
local function keelWelds(k)
	local list = {}
	for _, c in ipairs(constraint.FindConstraints(k, "Weld") or {}) do
		local other, bone = c.Ent2, c.Bone2
		if other == k then other, bone = c.Ent1, c.Bone1 end
		if IsValid(other) and other ~= k then
			list[#list + 1] = { ent = other, bone = bone or 0, force = c.forcelimit or 0, nocollide = c.nocollide == true }
			local old = c.Constraint
			if IsValid(old) then
				for _, e in ipairs({ k, other }) do
					local t = e.Constraints
					if t then for key, v in pairs(t) do if v == old then t[key] = nil end end end
				end
				old:Remove()
			end
		end
	end
	return list
end

-- the blocks of the things welded on a hull that stand out of its own blocks, in hull space; sig = what they are made of
local RIDER_BLOCKS = 12
function SpaceGrid.RiderBlocks(hull, boxes)
	local list = {}
	for e, r in pairs(hull.SGRiders or {}) do
		if IsValid(e) and r.lp and not r.stow and e:IsSolid() and e:BoundingRadius() > 8 then
			local pts = corners(e:OBBMins(), e:OBBMaxs())
			local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
			for n, c in ipairs(pts) do
				local w = LocalToWorld(c, angle_zero, r.lp, r.la)
				pts[n] = w
				lo = Vector(math.min(lo.x, w.x), math.min(lo.y, w.y), math.min(lo.z, w.z))
				hi = Vector(math.max(hi.x, w.x), math.max(hi.y, w.y), math.max(hi.z, w.z))
			end
			local inside = false
			for _, bx in ipairs(boxes) do
				if lo.x >= bx[1].x - 2 and lo.y >= bx[1].y - 2 and lo.z >= bx[1].z - 2 and hi.x <= bx[2].x + 2 and hi.y <= bx[2].y + 2 and hi.z <= bx[2].z + 2 then inside = true break end
			end
			local d = hi - lo
			if not inside and math.min(d.x, d.y, d.z) > 0.5 then list[#list + 1] = { e = e, points = pts, lo = lo, hi = hi, vol = d.x * d.y * d.z } end
		end
	end
	table.sort(list, function(a, b) return a.vol > b.vol end)
	for n = #list, RIDER_BLOCKS + 1, -1 do list[n] = nil end
	local ids = {}
	for n, r in ipairs(list) do ids[n] = r.e:EntIndex() end
	table.sort(ids)
	list.sig = table.concat(ids, ",")
	return list
end

local keeled = {}   -- hull -> true: the hulls that follow a keel
SpaceGrid.Keeled = keeled
-- Put somewhere new, a step further: SetPos makes the game draw it there at once - a flying ship and all in it were drawn in
-- jumps of a tick (12 units at speed 800) while the player's eyes moved smoothly: everything shook (tests
-- sgshake, sginterp). SetLocalPos leaves the game's smoothing on. A jump (a gate, a paste) stays a jump.
local function stepTo(e, pos, ang)
	if IsValid(e:GetParent()) or e:GetPos():DistToSqr(pos) > 512 * 512 then
		e:SetPos(pos)
		e:SetAngles(ang)
	else
		e:SetLocalPos(pos)
		e:SetLocalAngles(ang)
	end
end
local apartPair      -- (below: the collision pair between a keel and the other half of its cut ship)
-- (an entry of k.SGApart is the pair entity, or true while it is still to be made: IsValid(true) is a Lua error)
local function isPair(c) return isentity(c) and IsValid(c) end

-- make or remake the keel of a hull for its parts; `state` = how the ship moved before ({ frozen, vel, avel, grav })
function SpaceGrid.SyncKeel(hull, state, mass)
	if not IsValid(hull) or not hull.SG then return end
	local boxes = SpaceGrid.KeelBoxes(hull.SG)
	if #boxes == 0 then return end
	local k = hull.SGKeel
	if not IsValid(k) then
		k = ents.Create("spacegrid_keel")
		if not IsValid(k) then return end
		k:SetPos(hull:GetPos())
		k:SetAngles(hull:GetAngles())
		k:Spawn()
		k:Activate()
		k.SGHull = hull
		hull.SGKeel = k
		hull:DeleteOnRemove(k)
		if IsValid(hull.SGOwner) then
			k.SGOwner = hull.SGOwner
			if k.CPPISetOwner then k:CPPISetOwner(hull.SGOwner) end
		end
	else
		k:SetPos(hull:GetPos())
		k:SetAngles(hull:GetAngles())
	end
	local conv = {}
	for i, bx in ipairs(boxes) do conv[i] = corners(bx[1], bx[2]) end
	-- (what is welded on - a turret on the roof - went through walls and buildings: only the ship's own parts counted.
	-- Each thing that stands out of the ship is a block of the keel too, the 12 biggest at most.)
	local out = SpaceGrid.RiderBlocks(hull, boxes)
	boxes = table.Copy(boxes)
	for _, r in ipairs(out) do
		conv[#conv + 1] = r.points
		boxes[#boxes + 1] = { r.lo, r.hi }
	end
	hull.SGRiderSig, hull.SGMassNow = out.sig, mass
	local welds = keelWelds(k)
	k:PhysicsInitMultiConvex(conv, "metal")
	k:SetMoveType(MOVETYPE_VPHYSICS)
	k:SetSolid(SOLID_VPHYSICS)
	k:EnableCustomCollisions(true)
	k:SetCustomCollisionCheck(true)
	k.SGBlocks = #conv
	k.SGBoxes = boxes
	local phys = k:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetMass(math.Clamp(mass or 1000, 1, 50000))
		-- (no air drag: on a block as long as a ship the game's drag let a ship sink at a crawl with the helm off -
		-- keelbig; StarCore switches it off while it flies anyway)
		phys:EnableDrag(false)
		phys:SetPos(hull:GetPos())
		phys:SetAngles(hull:GetAngles())
		local frozen = state == nil or state.frozen or SpaceGrid.TooBig(hull)
		phys:EnableGravity(state == nil or state.grav ~= false)
		-- (the author's play test: E+R cut a flying 4-hall ship and the game crashed in the physics, in the same place
		-- as the old big-ship crash.) A new keel body lies right inside its own hull, and the no-collide link between the
		-- two can only be made a tick later: moving in that tick, the keel's big blocks pushed into hundreds of the
		-- hull's pieces at once. So a new keel stays frozen until its links are made; then it gets the motion the ship
		-- had (SpaceGrid.KeelWant can change that, a cut piece takes its old ship's).
		phys:EnableMotion(false)
		-- (already held - a cut - the motion it had before the hold stays what it gets)
		if not ((k.SGHolds or 0) > 0 and k.SGWant ~= nil) then
			k.SGWant = (not frozen) and { vel = state.vel, avel = state.avel } or false
		end
		if SpaceGrid.TooBig(hull) then k.SGWant = false end
	end
	SpaceGrid.KeelHold(k)
	-- The keel must not touch its own hull: the hull is frozen, and the game never asks ShouldCollide about a frozen
	-- body - the keel was pushed out of its own ship and crept away (keelown). The physics' own no-collide link between
	-- the two does it; it names the bodies, so it is made anew with every new body (one tick later, after the old one
	-- is gone). The same for the links to the other half of a cut ship (SpaceGrid.KeelApart).
	for _, c in ipairs(constraint.FindConstraints(k, "NoCollide") or {}) do
		if IsValid(c.Constraint) and (c.Ent1 == hull or c.Ent2 == hull) then
			-- (out of their lists at once: still listed when the new one is made, the game says there is one already and
			-- makes none - the ship was left without this link, ptshieldown)
			for _, e in ipairs({ k, hull }) do
				for key, v in pairs(e.Constraints or {}) do if v == c.Constraint then e.Constraints[key] = nil end end
			end
			c.Constraint:Remove()
		end
	end
	-- (the links to the riders and to the other half of a cut: both bodies of a pair may be new now)
	for e in pairs(hull.SGRiders or {}) do
		if IsValid(e) and isPair(e.SGKeelPair) then e.SGKeelPair:Remove() end
		if IsValid(e) then e.SGKeelPair = nil end
	end
	for _, list in pairs(hull.SGStowShips or {}) do
		for _, t in ipairs(list) do
			if isPair(t[4]) then t[4]:Remove() end
			local p = t[5] and IsValid(t[1]) and t[1]:GetPhysicsObject()
			if IsValid(p) then p:EnableMotion(true) end
		end
	end
	for _, n in pairs(k.SGNear or {}) do if isPair(n.c) then n.c:Remove() end end
	k.SGNear = nil
	hull.SGStowShips = nil   -- (looked at again in a moment, with the new body)
	for _, c in pairs(k.SGFrozenPairs or {}) do if isPair(c) then c:Remove() end end
	k.SGFrozenPairs = {}
	for oh, c in pairs(k.SGApart or {}) do
		if isPair(c) then c:Remove() end
		k.SGApart[oh] = true
	end
	for ok in pairs(hull.SGApartK or {}) do
		local c = IsValid(ok) and ok.SGApart and ok.SGApart[hull]
		if isPair(c) then c:Remove() end
		if IsValid(ok) and ok.SGApart and ok.SGApart[hull] then ok.SGApart[hull] = true end
	end
	timer.Simple(0, function()
		if not (IsValid(k) and IsValid(hull)) then return end
		constraint.NoCollide(k, hull, 0, 0)
		for oh, c in pairs(k.SGApart or {}) do
			if not IsValid(oh) then k.SGApart[oh] = nil elseif not isPair(c) then k.SGApart[oh] = apartPair(k, oh) or true end
		end
		for ok in pairs(hull.SGApartK or {}) do
			if not (IsValid(ok) and ok.SGApart and ok.SGApart[hull]) then
				hull.SGApartK[ok] = nil
			elseif not isPair(ok.SGApart[hull]) then
				ok.SGApart[hull] = apartPair(ok, hull) or true
			end
		end
		for e in pairs(hull.SGRiders or {}) do
			if IsValid(e) and not isPair(e.SGKeelPair) then e.SGKeelPair = apartPair(k, e) end
		end
		SpaceGrid.Riders(hull)   -- (and the frozen things lying in it get their pairs with the new body)
		for _, w in ipairs(welds) do
			if IsValid(w.ent) then constraint.Weld(w.ent, k, w.bone, 0, w.force, w.nocollide, false) end
		end
		SpaceGrid.KeelRelease(k)
	end)
	keeled[hull] = true
	hull.SGRidersAt = 0   -- (what is welded on is looked at again: SpaceGrid.Riders)
end

-- A keel is held frozen while something is still to be made (its links, the other half of a cut); each hold is let go
-- once. When the last one goes, the keel gets the motion it should have (k.SGWant: false = frozen, or { vel, avel }).
function SpaceGrid.KeelHold(k)
	k.SGHolds = (k.SGHolds or 0) + 1
	local phys = k:GetPhysicsObject()
	if IsValid(phys) and phys:IsMotionEnabled() then
		k.SGWant = { vel = phys:GetVelocity(), avel = phys:GetAngleVelocity() }
		phys:EnableMotion(false)
	end
end
function SpaceGrid.KeelRelease(k)
	if not IsValid(k) then return end
	k.SGHolds = math.max((k.SGHolds or 1) - 1, 0)
	if k.SGHolds > 0 then return end
	local want, phys = k.SGWant, k:GetPhysicsObject()
	k.SGWant = nil
	if not (want and IsValid(phys)) then return end
	local hull = k.SGHull
	if IsValid(hull) and SpaceGrid.TooBig(hull) then return end
	phys:EnableMotion(true)
	if want.vel then phys:SetVelocity(want.vel) end
	if want.avel then phys:AddAngleVelocity(want.avel - phys:GetAngleVelocity()) end
	phys:Wake()
	k.SGLastV, k.SGLastW = want.vel, want.avel
	-- (the helm has its own idea of the speed: held for a moment - a cut, a part added - it thought the ship stood still and
	-- stopped it; cut in two in flight, the rear half flew through the front one)
	local core = IsValid(hull) and (SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull) or hull.SGCore)
	if want.vel then
		-- (it measures at the core, a body of its own welded to the keel: that one stood still as well)
		for _, e in pairs(constraint.GetAllConstrainedEntities(k) or {}) do
			local p = IsValid(e) and e ~= k and not e.SpaceGridHull and not e.SpaceGridKeel and not e.SGRiderOf and not IsValid(e:GetParent()) and e:GetPhysicsObject()
			if IsValid(p) and p:IsMotionEnabled() then p:SetVelocity(want.vel) end
		end
		if IsValid(core) and core.Helm and core.Helm.on and core.Helm.vel then core.Helm.vel = Vector(want.vel.x, want.vel.y, want.vel.z) end
	end
end
-- how a (new) ship should move once its keel is let go: frozen, or moving on with vel
function SpaceGrid.KeelWant(hull, moving, vel, avel)
	local k = IsValid(hull) and hull.SGKeel
	if not IsValid(k) then return end
	if (k.SGHolds or 0) > 0 then
		k.SGWant = moving and { vel = vel, avel = avel } or false
		return
	end
	local phys = k:GetPhysicsObject()
	if not IsValid(phys) then return end
	phys:EnableMotion(moving)
	if moving then
		if vel then phys:SetVelocity(vel) end
		phys:Wake()
	end
end

-- The two halves of a cut ship (or a piece that fell off) lie in each other at first: the old ship's keel still has
-- the old shape for a tick, and blocks of both keels reach a little over the seam. Touching each other's hull there,
-- both were thrown apart, and with many pieces in reach the physics crashed (the owner's E+R cut). So each keel does
-- not touch the other half's hull until the two no longer lie in each other (checked every second, below).
--
-- (Not StarCore's / GMod's no-collide constraint: StarCore finds a ship by everything constrained to its core, so the
-- two halves would have counted as one ship with two cores, one of them asleep. A bare collision pair is no constraint.
-- k.SGApart[otherHull] = that pair, or true while it is still to be made; otherHull.SGApartK[k] = true.)
apartPair = function(k, oh)
	local p1, p2 = k:GetPhysicsObject(), oh:GetPhysicsObject()
	if not (IsValid(p1) and IsValid(p2)) then return nil end
	local c = ents.Create("logic_collision_pair")
	if not IsValid(c) then return nil end
	c:SetPos(k:GetPos())
	c:SetKeyValue("startdisabled", 1)
	c:SetPhysConstraintObjects(p1, p2)
	c:Spawn()
	c:Activate()
	c:Input("DisableCollisions", nil, nil, nil)
	k:DeleteOnRemove(c)
	oh:DeleteOnRemove(c)
	return c
end
function SpaceGrid.KeelApart(a, b)
	local ka, kb = IsValid(a) and a.SGKeel, IsValid(b) and b.SGKeel
	if not (IsValid(ka) and IsValid(kb)) then return end
	ka.SGApart = ka.SGApart or {}; if ka.SGApart[b] == nil then ka.SGApart[b] = true end
	kb.SGApart = kb.SGApart or {}; if kb.SGApart[a] == nil then kb.SGApart[a] = true end
	a.SGApartK = a.SGApartK or {}; a.SGApartK[kb] = true
	b.SGApartK = b.SGApartK or {}; b.SGApartK[ka] = true
	SpaceGrid.KeelHold(ka)
	SpaceGrid.KeelHold(kb)
	-- (a few ticks: a hull with something welded on is rebuilt a tick later, sv_hull.lua Commit, and makes its own
	-- links a tick after that)
	timer.Simple(0.15, function()
		for _, pair in ipairs({ { ka, b }, { kb, a } }) do
			local k, oh = pair[1], pair[2]
			if IsValid(k) and IsValid(oh) and k.SGApart and k.SGApart[oh] and not isPair(k.SGApart[oh]) then
				k.SGApart[oh] = apartPair(k, oh) or true
			end
		end
		SpaceGrid.KeelRelease(ka)
		SpaceGrid.KeelRelease(kb)
	end)
end

-- does keel k (its blocks) lie in hull oh's parts? (a little space at the seam does not count)
local function keelInHull(k, oh)
	if not (k.SGBoxes and oh.SG) then return false end
	local boxes = {}
	for _, p in pairs(oh.SG.parts) do
		local a, b = SpaceGrid.PartBounds(SpaceGrid.Parts[p.t], p.pos, p.ang)
		if a then boxes[#boxes + 1] = { a, b } end
	end
	for _, bx in ipairs(k.SGBoxes) do
		local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
		for _, c in ipairs(corners(bx[1], bx[2])) do
			local l = oh:WorldToLocal(k:LocalToWorld(c))
			lo = Vector(math.min(lo.x, l.x), math.min(lo.y, l.y), math.min(lo.z, l.z))
			hi = Vector(math.max(hi.x, l.x), math.max(hi.y, l.y), math.max(hi.z, l.z))
		end
		for _, pb in ipairs(boxes) do
			local a, b = pb[1], pb[2]
			if lo.x < b.x - 4 and hi.x > a.x + 4 and lo.y < b.y - 4 and hi.y > a.y + 4 and lo.z < b.z - 4 and hi.z > a.z + 4 then return true end
		end
	end
	return false
end
timer.Create("SpaceGrid.KeelApart", 1, 0, function()
	for hull in pairs(keeled) do
		local k = IsValid(hull) and hull.SGKeel
		if IsValid(k) and k.SGApart and (k.SGHolds or 0) == 0 then
			for oh, c in pairs(k.SGApart) do
				if not IsValid(oh) then
					k.SGApart[oh] = nil
				elseif not keelInHull(k, oh) then
					-- (apart now: they touch again like any two ships; the pair going lets them collide)
					k.SGApart[oh] = nil
					if oh.SGApartK then oh.SGApartK[k] = nil end
					if isPair(c) then c:Input("EnableCollisions", nil, nil, nil); c:Remove() end
				end
			end
		end
	end
end)

-- What the player welds onto a SpaceGrid ship (an AGP weapon, a drone platform, a crate, a Wire chip) goes with it
-- like a part of it. The hull is a frozen body put on its keel every tick: a weld to it pulled the welded thing after
-- it one step late. So what is welded to the hull (and what is welded to that) is frozen as well and put on its place
-- in the ship every tick, the same way as the hull: a "rider". It stays one with the ship until its weld is taken off
-- (a tool, the ship destroyed): then it is let go with the ship's speed. Not riders: StarCore's core (it measures
-- the ship's motion, it is welded to the keel), other ships, what is fixed to the map, what has a parent.
--
local RIDER_EVERY = 0.5
local function riderSet(hull)
	local set, todo, anchored = {}, { hull }, false
	local seen = { [hull] = true }
	while #todo > 0 do
		local e = table.remove(todo)
		for _, c in ipairs(constraint.FindConstraints(e, "Weld") or {}) do
			local o = c.Ent1 == e and c.Ent2 or c.Ent1
			if IsValid(o) and o:IsWorld() then
				if e ~= hull then anchored = true end
			elseif IsValid(o) and not seen[o] then
				seen[o] = true
				if not (o.SpaceGridHull or o.SpaceGridKeel or o:GetClass() == "starcore" or o:IsPlayer() or o:IsNPC() or IsValid(o:GetParent())) then
					set[o] = true
					todo[#todo + 1] = o
				end
			end
		end
		-- what another addon keeps on this thing without a lasting weld (an AGP ZPM hub makes its ZPMs' weld anew every
		-- step while they slide; a look in between let them go and took them on again a few units behind - they
		-- drifted from the hub in flight): e.SGRideAlong = function(e) return { things } end (or a table)
		local along = e.SGRideAlong
		if isfunction(along) then along = along(e) end
		if istable(along) then
			for _, o in ipairs(along) do
				if IsValid(o) and not seen[o] then
					seen[o] = true
					if not (o.SpaceGridHull or o.SpaceGridKeel or o:IsPlayer() or o:IsNPC() or IsValid(o:GetParent())) then
						set[o] = true
						todo[#todo + 1] = o
					end
				end
			end
		end
	end
	if anchored then return {} end   -- (welded to the map as well: it holds the ship, not the other way round)
	return set
end
-- What is fixed in a flying ship without being welded to it: frozen things, and things built of several parts - the ship's
-- walls would pass through them. While the ship's engine is on they are "stowed": on their place in the ship like a rider,
-- but no part of it; parked, they are as they were (frozen stays frozen, what could move can move again). Only what is
-- enclosed by the hull. Simple loose things, ragdolls, cars and living things: carry(), below. (inside the hull, with walls
-- round it: from its middle at least five of six ways meet the ship)
--
local function enclosed(hull, at)
	local len, n = (hull.SGMaxs - hull.SGMins):Length(), 0
	for _, d in ipairs({ hull:GetForward(), -hull:GetForward(), hull:GetRight(), -hull:GetRight(), hull:GetUp(), -hull:GetUp() }) do
		local tr = util.TraceLine({ start = at, endpos = at + d * len, ignoreworld = true, filter = function(x) return x == hull or x:GetParent() == hull end })
		if tr.Hit then n = n + 1 end
	end
	return n >= 5
end
local middleIn   -- (below)
-- everything fixed to e (the ship itself and what is welded to it left out); nil = it is fixed to the map, or is a ship that flies
local function groupOf(e, hull)
	local list, tied = {}, constraint.HasConstraints(e) and constraint.GetAllConstrainedEntities(e) or { e }
	for _, o in pairs(tied) do
		if IsValid(o) and o ~= hull and o ~= hull.SGKeel and o ~= hull.SGCore and not (o.SGRiderOf == hull and not (hull.SGRiders[o] and hull.SGRiders[o].stow)) then
			if o.SpaceGridHull or o.SpaceGridKeel or o:IsPlayer() or o:IsNPC() or o:CreatedByMap() or o.StarCoreDockOn then return nil end
			if o:GetClass() == "starcore" and ((o.Helm and o.Helm.on) or o.DockedTo) then return nil end
			for _, c in ipairs(constraint.GetTable(o) or {}) do
				if c.Type ~= "NoCollide" and ((IsEntity(c.Ent1) and c.Ent1:IsWorld()) or (IsEntity(c.Ent2) and c.Ent2:IsWorld())) then return nil end
			end
			list[#list + 1] = o
		end
	end
	return list
end
local function stowable(e, hull)
	if IsValid(e:GetParent()) or e.SpaceGridHull or e.SpaceGridKeel or e.SpaceGridSeat or e.SpaceGridDoor or e.StarCoreDockOn or e == hull.SGCore then return false end
	if e:IsPlayer() or e:IsNPC() or e:IsWeapon() or e:IsRagdoll() or e:IsWorld() or e:CreatedByMap() or e:IsPlayerHolding() then return false end
	if e:IsVehicle() and e:GetClass() ~= "prop_vehicle_prisoner_pod" then return false end
	if IsValid(e.SGRiderOf) and not (e.SGRiderOf == hull and hull.SGRiders[e] and hull.SGRiders[e].stow) then return false end
	if e.SGNoCarry == true or e.AGPReplicator or e:GetMoveType() ~= MOVETYPE_VPHYSICS or not e:IsSolid() or (SpaceGrid.Resting and SpaceGrid.Resting[e]) then return false end
	return IsValid(e:GetPhysicsObject())
end
-- the ships docked in this one: what lies in them goes along with them, not with the carrier as well
local function innerShips(hull)
	local list = {}
	for oh in pairs(SpaceGrid.Keeled) do
		if IsValid(oh) and oh ~= hull and IsValid(oh.SGKeel) and (oh.SGKeel.StarCoreDockOn or oh.StarCoreDockOn) and oh:BoundingRadius() < hull:BoundingRadius()
			and oh:GetPos():DistToSqr(hull:GetPos()) < hull:BoundingRadius() ^ 2 then list[#list + 1] = oh end
	end
	return list[1] and list
end
local function inInner(list, e)
	for _, oh in ipairs(list) do if middleIn(oh, e) then return true end end
	return false
end
local function stowSet(hull)
	local set, k = {}, hull.SGKeel
	local kp = IsValid(k) and k:GetPhysicsObject()
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not (IsValid(kp) and mn) or hull.SGWreck then return set end
	local kept = hull.SGHeldBy or (k.SGHolds or 0) > 0 or k.AGPRideWith or hull.AGPRideWith or hull.SGAlong
	if kept then
		for e, r in pairs(hull.SGRiders) do if IsValid(e) and r.stow then set[e] = true end end
		return set
	end
	if not kp:IsMotionEnabled() and not k.StarCoreDockOn then return set end
	local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for i = 0, 7 do
		local c = hull:LocalToWorld(Vector(bit.band(i, 1) > 0 and mx.x or mn.x, bit.band(i, 2) > 0 and mx.y or mn.y, bit.band(i, 4) > 0 and mx.z or mn.z))
		lo = Vector(math.min(lo.x, c.x), math.min(lo.y, c.y), math.min(lo.z, c.z))
		hi = Vector(math.max(hi.x, c.x), math.max(hi.y, c.y), math.max(hi.z, c.z))
	end
	local seen = {}
	local innerOf = innerShips(hull)
	for _, e in ipairs(ents.FindInBox(lo, hi)) do
		if not seen[e] and stowable(e, hull) and not (innerOf and inInner(innerOf, e)) then
			local r = hull.SGRiders[e]
			local frozen = not e:GetPhysicsObject():IsMotionEnabled()
			local built = constraint.HasConstraints(e)
			if (frozen or built) and not (r and not r.stow) then
				local list = groupOf(e, hull)
				for _, o in ipairs(list or {}) do seen[o] = true end
				-- (one loose thing on a rope from the ship is cargo that swings)
				local any = list and (#list > 1 or (list[1] and frozen))
				for _, o in ipairs(any and list or {}) do
					if not (o == e or stowable(o, hull) or o:GetClass() == "starcore") or not hull:WorldToLocal(o:WorldSpaceCenter()):WithinAABox(mn, mx) then any = false break end
				end
				if any and (r or (middleIn(hull, e) and enclosed(hull, e:WorldSpaceCenter()))) then
					for _, o in ipairs(list) do if not (hull.SGRiders[o] and not hull.SGRiders[o].stow) then set[o] = true end end
				end
			end
		end
	end
	return set
end
-- A smaller ship that is in this one or comes near it slowly (test nestwho: a ship standing undocked in a hall threw the carrier
-- at 540 units a second): the keel's blocks fill the rooms, so this ship's keel does not touch it - its own keel meets this
-- ship's real walls. A fast one, or one of its own size, is met as ever.
local NEAR = 48
local function nearShips(hull, k, kp)
	local near = k.SGNear or {}
	k.SGNear = near
	local v = kp:GetVelocity()
	for oh in pairs(SpaceGrid.Keeled) do
		if IsValid(oh) and oh ~= hull then
			local ok = oh.SGKeel
			local okp = IsValid(ok) and ok:GetPhysicsObject()
			local is = false
			if IsValid(okp) and oh:BoundingRadius() < hull:BoundingRadius() * 0.7 and k.SGBoxes and oh:GetPos():DistToSqr(hull:GetPos()) < (oh:BoundingRadius() + hull:BoundingRadius() + 200) ^ 2
				-- (its middle in one of this ship's rooms: whatever the speed - thrown already, it was too fast to be let in)
				and (near[oh] or middleIn(hull, oh) or (okp:GetVelocity() - v):Length() < 300 or not okp:IsMotionEnabled() and v:Length() < 300) then
				local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
				for _, c in ipairs(corners(oh:OBBMins(), oh:OBBMaxs())) do
					local l = hull:WorldToLocal(oh:LocalToWorld(c))
					lo = Vector(math.min(lo.x, l.x), math.min(lo.y, l.y), math.min(lo.z, l.z))
					hi = Vector(math.max(hi.x, l.x), math.max(hi.y, l.y), math.max(hi.z, l.z))
				end
				local m = near[oh] and NEAR * 2 or NEAR
				for _, bx in ipairs(k.SGBoxes) do
					if lo.x < bx[2].x + m and hi.x > bx[1].x - m and lo.y < bx[2].y + m and hi.y > bx[1].y - m and lo.z < bx[2].z + m and hi.z > bx[1].z - m then is = true break end
				end
			end
			-- (a body made anew - a part added, a core put in - has no pair any more: it is looked whether both are still the same)
			local n, op = near[oh], oh:GetPhysicsObject()
			local good = n and isPair(n.c) and IsValid(n.a) and n.a == kp and IsValid(n.b) and n.b == op
			if n and not (is and good) then
				if isPair(n.c) then n.c:Input("EnableCollisions", nil, nil, nil) n.c:Remove() end
				near[oh] = nil
			end
			if is and not good and IsValid(op) and not (k.SGApart and k.SGApart[oh]) then near[oh] = { c = apartPair(k, oh), a = kp, b = op } end
		end
	end
	for oh, c in pairs(near) do if not IsValid(oh) then near[oh] = nil end end
end
-- A smaller ship flying in this one's hall (test hunt_hangar: let go from its dock in flight it was slower than the carrier,
-- slid back and went through the hall's back wall - its keel meets the real walls, and those are put somewhere new each
-- step). Where its middle crossed a wall of this ship since the last step it is put back; where a corner of its box is beyond
-- a wall, it is pushed in by as much (held by its middle only, its back half stood out of the back wall). Its speed into that
-- wall is taken away - it is pressed against the wall and goes along, as in a real hangar.
local function pushShip(hull, kp, oh, ok, okp, d, n)
	okp:SetPos(okp:GetPos() + d, true)
	ok:SetPos(ok:GetPos() + d)
	oh:SetPos(oh:GetPos() + d)
	-- (its speed into the wall, measured against this ship's: gone - in its body and in its helm)
	local cv = kp:GetVelocity()
	local into = (okp:GetVelocity() - cv):Dot(n)
	if into < 0 then okp:SetVelocity(okp:GetVelocity() - n * into) end
	local core = oh.SGCore
	local hm = IsValid(core) and core.Helm
	if hm and hm.vel then
		local hin = (hm.vel - cv):Dot(n)
		if hin < 0 then hm.vel = hm.vel - n * hin end
	end
	hull.SGShipsBack = (hull.SGShipsBack or 0) + 1   -- (tests read it)
end
local function only(hull) return function(x) return x == hull end end
local function guardInner(hull, k, kp)
	local last, now = k.SGInnerAt or {}, {}
	k.SGInnerAt = now
	local R = hull:BoundingRadius()
	for oh in pairs(SpaceGrid.Keeled) do
		local ok = IsValid(oh) and oh ~= hull and oh:BoundingRadius() < R * 0.7 and oh:GetPos():DistToSqr(hull:GetPos()) < R * R and oh.SGKeel
		local okp = IsValid(ok) and ok:GetPhysicsObject()
		if IsValid(okp) and okp:IsMotionEnabled() and not (ok.StarCoreDockOn or oh.StarCoreDockOn or oh.SGWreck) then
			local f = only(hull)
			local c = oh:WorldSpaceCenter()
			local l = hull:WorldToLocal(c)
			local was = last[oh]
			local back = false
			if was then
				local from = hull:LocalToWorld(was)
				local tr = util.TraceLine({ start = from, endpos = c, ignoreworld = true, filter = f })
				if tr.Hit and not tr.StartSolid then
					pushShip(hull, kp, oh, ok, okp, from - c, tr.HitNormal)
					now[oh], back, c = was, true, from
				end
			end
			if not back then
				if l:WithinAABox(hull.SGMins, hull.SGMaxs) then now[oh] = l end
				-- (its box: the corner deepest beyond a wall - from outside too: a small ship pushing at the side of a carrier
				-- had its nose in the wall, its middle outside)
				local best, bn = 0.5, nil
				for _, q in ipairs(corners(oh.SGMins or oh:OBBMins(), oh.SGMaxs or oh:OBBMaxs())) do
					local w = oh:LocalToWorld(q)
					local tr = util.TraceLine({ start = c, endpos = w, ignoreworld = true, filter = f })
					if tr.Hit and not tr.StartSolid then
						local depth = (w - tr.HitPos):Dot(-tr.HitNormal)
						if depth > best then best, bn = depth, tr.HitNormal end
					end
				end
				if bn then pushShip(hull, kp, oh, ok, okp, bn * (best + 1), bn) end
			end
		end
	end
end
SpaceGrid.GuardInner = guardInner
-- (or on it: a small ship parked on the roof of a flying carrier stayed where it was parked and was left 8500 units behind -
-- hunt_roofship; citizens and crates ride on the roof already)
local function onRoof(hull, oh)
	local mn, mx = hull.SGMins, hull.SGMaxs
	local c = oh:WorldSpaceCenter()
	local l = hull:WorldToLocal(c)
	local tall = (oh.SGMins and oh.SGMaxs) and (oh.SGMaxs.z - oh.SGMins.z) or 200
	if not (l.x > mn.x and l.x < mx.x and l.y > mn.y and l.y < mx.y and l.z > mn.z and l.z < mx.z + tall) then return false end
	local tr = util.TraceLine({ start = c, endpos = c - hull:GetUp() * (tall * 0.5 + 30), ignoreworld = true, filter = function(x) return x == hull end })
	return tr.Hit and not tr.StartSolid
end
-- another ship parked in this one, not docked: it stays on its place in it, as it is
local function stowShips(hull)
	local k, old, new = hull.SGKeel, hull.SGStowShips or {}, {}
	local kp = IsValid(k) and k:GetPhysicsObject()
	if hull.SGAlong or (IsValid(k) and (k.AGPRideWith or (k.SGHolds or 0) > 0)) then return end
	if IsValid(kp) and kp:IsMotionEnabled() and hull.SGMins then nearShips(hull, k, kp) end
	if IsValid(kp) and (kp:IsMotionEnabled() or k.StarCoreDockOn) and hull.SGMins and not hull.SGWreck then
		for oh in pairs(SpaceGrid.Keeled) do
			local ok = IsValid(oh) and oh ~= hull and oh.SGKeel
			local okp = IsValid(ok) and ok:GetPhysicsObject()
			if IsValid(okp) and (old[oh] or not okp:IsMotionEnabled() or (okp:GetVelocity() - kp:GetVelocity()):Length() < 300) and not (oh.SGWreck or oh.SGHeldBy or ok.StarCoreDockOn or oh.StarCoreDockOn) and oh:BoundingRadius() < hull:BoundingRadius() and (hull:WorldToLocal(oh:WorldSpaceCenter()):WithinAABox(hull.SGMins, hull.SGMaxs) or old[oh] or onRoof(hull, oh)) then
				local core = oh.SGCore
				if not (IsValid(core) and ((core.Helm and core.Helm.on) or core.DockedTo)) and (old[oh] or (middleIn(hull, oh) and enclosed(hull, oh:WorldSpaceCenter())) or onRoof(hull, oh)) then
					new[oh] = old[oh]
					if not new[oh] then
						local list = {}
						for _, o in pairs(constraint.GetAllConstrainedEntities(ok) or {}) do
							if IsValid(o) and not o.SGRiderOf and not o:IsWorld() and not IsValid(o:GetParent()) then
								local lp, la = WorldToLocal(o:GetPos(), o:GetAngles(), hull:GetPos(), hull:GetAngles())
								-- (one that lies there with its engine off is held too, until this ship parks)
								local p = o:GetPhysicsObject()
								local free = IsValid(p) and p:IsMotionEnabled()
								if free then p:EnableMotion(false) end
								-- (and apart from the keel: its block fills the hall, a frozen body in it threw the ship - scene_nest)
								list[#list + 1] = { o, lp, la, not o.SpaceGridHull and o ~= ok and apartPair(k, o) or false, free }
							end
						end
						new[oh] = list
					end
				end
			end
		end
	end
	for oh, list in pairs(old) do
		if new[oh] ~= list then
			for _, t in ipairs(list) do
				if isPair(t[4]) then t[4]:Input("EnableCollisions", nil, nil, nil) t[4]:Remove() end
				local p = t[5] and IsValid(t[1]) and t[1]:GetPhysicsObject()
				if IsValid(p) then
					p:EnableMotion(true)
					if IsValid(kp) and kp:IsMotionEnabled() then p:SetVelocity(kp:GetVelocity()) end
					p:Wake()
				end
			end
		end
	end
	hull.SGStowShips = next(new) and new or nil
end
SpaceGrid.StowShips = stowShips
local function placeShips(hull)
	for oh, list in pairs(hull.SGStowShips) do
		for _, t in ipairs(list) do
			local o = t[1]
			if IsValid(o) then
				local np, na = LocalToWorld(t[2], t[3], hull:GetPos(), hull:GetAngles())
				stepTo(o, np, na)
				local p = o:GetPhysicsObject()
				if IsValid(p) then p:SetPos(np, true) p:SetAngles(na) end
			end
		end
	end
end
-- a thing built of several parts that is not stowed just now (held with the physgun, a ship that flies inside this one): it
-- goes along too, part by part
local function builtAboard(e, hull)
	local c = e.SGBuiltAt
	if c and c.hull == hull and c.t > CurTime() then return c.ok end
	local list, ok = {}, true
	for _, o in pairs(constraint.GetAllConstrainedEntities(e) or {}) do
		if IsValid(o) and o ~= hull and o ~= hull.SGKeel and o.SGRiderOf ~= hull then
			list[#list + 1] = o
			local p = o:GetPhysicsObject()
			if o.SpaceGridHull or o.SpaceGridKeel or o:CreatedByMap() or not IsValid(p) or not p:IsMotionEnabled() or not hull:WorldToLocal(o:WorldSpaceCenter()):WithinAABox(hull.SGMins, hull.SGMaxs) then ok = false end
			for _, t in ipairs(constraint.GetTable(o) or {}) do
				if t.Type ~= "NoCollide" and ((IsEntity(t.Ent1) and t.Ent1:IsWorld()) or (IsEntity(t.Ent2) and t.Ent2:IsWorld())) then ok = false end
			end
		end
	end
	for _, o in ipairs(list) do o.SGBuiltAt = { hull = hull, t = CurTime() + 0.5, ok = ok } end
	return ok
end
local function letGo(e, hull)
	e.StarCoreFollower = nil
	e.SGRiderOf = nil
	e:SetNWEntity("SGRider", NULL)
	if isPair(e.SGKeelPair) then e.SGKeelPair:Input("EnableCollisions", nil, nil, nil) e.SGKeelPair:Remove() end
	e.SGKeelPair = nil
	local p = e:GetPhysicsObject()
	if not IsValid(p) then return end
	-- (was it moving when it came on? it moves again - with the ship's speed when the ship flies.: a parked ship kept
	-- it frozen, so a ZPM taken out of a hub on a parked ship hung in the air)
	if e.SGRiderMoved ~= false and not p:IsMotionEnabled() then
		local kp = SpaceGrid.Body(hull)
		p:EnableMotion(true)
		if IsValid(kp) and kp:IsMotionEnabled() then p:SetVelocity(kp:GetVelocity()) end
		p:Wake()
	end
	e.SGRiderMoved = nil
end
function SpaceGrid.Riders(hull)
	local now = CurTime()
	hull.SGRiders = hull.SGRiders or {}
	hull.SGRidersAt = now + RIDER_EVERY
	local set, changed = riderSet(hull), false
	local stow = stowSet(hull)
	stowShips(hull)
	for e, r in pairs(hull.SGRiders) do
		if r.stow and IsValid(e) and set[e] then   -- (welded on meanwhile)
			r.stow, changed = nil, true
			e.StarCoreFollower = true
		elseif not (IsValid(e) and (set[e] or (r.stow and stow[e] and not e:IsPlayerHolding()))) then
			hull.SGRiders[e] = nil
			changed = changed or not r.stow
			if IsValid(e) then letGo(e, hull) end
		end
	end
	for e in pairs(stow) do set[e] = set[e] or "stow" end
	for e, how in pairs(set) do
		local r = hull.SGRiders[e]
		if not r and not e.SGHeldBy then
			local p = e:GetPhysicsObject()
			if IsValid(p) then
				local hp, ha = hull:GetPos(), hull:GetAngles()
				local lp, la = WorldToLocal(e:GetPos(), e:GetAngles(), hp, ha)
				-- (was it moving when it came on? let go, it moves again; spawned frozen, it stays frozen)
				e.SGRiderMoved = p:IsMotionEnabled()
				p:EnableMotion(false)
				hull.SGRiders[e] = { lp = lp, la = la, wp = e:GetPos(), wa = e:GetAngles(), hp = hp, ha = ha, stow = how == "stow" or nil }
				if how ~= "stow" then e.StarCoreFollower = true end
				if isPair(e.SGCarryPair) then e.SGCarryPair:Remove() end
				e.SGCarryPair, e.SGCarryPairOf = nil, nil
				e.SGRiderOf = hull
				e:SetNWEntity("SGRider", hull)   -- (cl_gate.lua: hidden in a gate with the ship)
				-- (frozen, it is never asked about by the keel's "only the map and other ships" rule: welded crates inside
				-- the halls pushed their own ship's keel away -, ptcut. A collision pair keeps them apart.)
				if IsValid(hull.SGKeel) then e.SGKeelPair = apartPair(hull.SGKeel, e) end
				changed = changed or how ~= "stow"
			end
		end
	end
	if changed then
		local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
		if IsValid(core) and StarCore and StarCore.Scan then StarCore.Scan(core) end
	end
	-- something else is welded on now: the keel gets its block (a while after the last change; not while the ship is held,
	-- docked or in a wormhole)
	do
		local k = hull.SGKeel
		if IsValid(k) and (k.SGHolds or 0) == 0 and not hull.SGHeldBy and not k.AGPRideWith and not hull.AGPRideWith and not k.StarCoreDockOn then
			local sig = SpaceGrid.RiderBlocks(hull, SpaceGrid.KeelBoxes(hull.SG)).sig
			if sig ~= (hull.SGRiderSig or "") then
				if hull.SGRiderNew ~= sig then
					hull.SGRiderNew, hull.SGRiderNewAt = sig, now + 0.4
				elseif now >= (hull.SGRiderNewAt or 0) then
					hull.SGRiderNew = nil
					-- (after this tick, as a rebuild does it: its old links have to be gone when the new ones are made)
					timer.Simple(0, function()
						if not IsValid(hull) or not IsValid(hull.SGKeel) or (hull.SGKeel.SGHolds or 0) > 0 or hull.SGHeldBy or hull.SGKeel.AGPRideWith or hull.AGPRideWith then return end
						SpaceGrid.SyncKeel(hull, SpaceGrid.KeelState(hull), hull.SGMassNow)
						timer.Simple(0.3, function()
							local core = IsValid(hull) and SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
							if IsValid(core) and StarCore and StarCore.Scan then StarCore.Scan(core) end
						end)
					end)
				end
			end
		end
	end
	SpaceGrid.LyingIn(hull)
end
-- Does e reach into the keel's blocks? (traces through what e's box and a block have in common, 6 units in: what only
-- touches the ship does not count)
local GRID = { -0.98, -0.5, 0, 0.5, 0.98 }
local function reachesIn(k, e)
	local kp = k:GetPhysicsObject()
	if not IsValid(kp) then return false end
	local pos, ang = kp:GetPos(), kp:GetAngles()
	local function only(x) return x == e end
	local function hit(a, b)
		return util.TraceLine({ start = LocalToWorld(a, angle_zero, pos, ang), endpos = LocalToWorld(b, angle_zero, pos, ang), ignoreworld = true, filter = only }).Hit
	end
	local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, c in ipairs(corners(e:OBBMins(), e:OBBMaxs())) do
		local l = WorldToLocal(e:LocalToWorld(c), angle_zero, pos, ang)
		lo = Vector(math.min(lo.x, l.x), math.min(lo.y, l.y), math.min(lo.z, l.z))
		hi = Vector(math.max(hi.x, l.x), math.max(hi.y, l.y), math.max(hi.z, l.z))
	end
	for _, bx in ipairs(k.SGBoxes or {}) do
		local a = Vector(math.max(lo.x, bx[1].x + 6), math.max(lo.y, bx[1].y + 6), math.max(lo.z, bx[1].z + 6))
		local b = Vector(math.min(hi.x, bx[2].x - 6), math.min(hi.y, bx[2].y - 6), math.min(hi.z, bx[2].z - 6))
		if a.x < b.x and a.y < b.y and a.z < b.z then
			local m, h = (a + b) / 2, (b - a) / 2
			for _, u in ipairs(GRID) do
				for _, v in ipairs(GRID) do
					if hit(m + Vector(-h.x, h.y * u, h.z * v), m + Vector(h.x, h.y * u, h.z * v)) or hit(m + Vector(h.x * u, -h.y, h.z * v), m + Vector(h.x * u, h.y, h.z * v))
						or hit(m + Vector(h.x * u, h.y * v, -h.z), m + Vector(h.x * u, h.y * v, h.z)) then return true end
				end
			end
		end
	end
	return false
end
-- (a thing whose middle is in the ship, in one of its blocks - not a building the ship stands in. Not the box round the
-- whole ship: beside a narrow bridge that reaches forward one is in that box and outside the ship)
function middleIn(hull, e)
	local mn, mx = hull.SGMins, hull.SGMaxs
	local k = hull.SGKeel
	if not mn or not (IsValid(k) and k.SGBoxes) or e:BoundingRadius() >= (mx - mn):Length() / 2 then return false end
	local l = hull:WorldToLocal(e:WorldSpaceCenter())
	if not l:WithinAABox(mn, mx) then return false end
	for _, bx in ipairs(k.SGBoxes) do if l:WithinAABox(bx[1], bx[2]) then return true end end
	return false
end
-- Frozen things lying in a parked ship (a crate frozen with the physgun in a hall): frozen, the keel's rule is never
-- asked about them - flying off, the keel would push against them. While the ship is parked, what is frozen in it - lies
-- in it, or reaches into it (a ship built or let go inside a wall; the physics threw it out of the world) - gets a
-- collision pair with the keel; it stays where it was frozen (frozen is frozen) and the ship flies off through it. Once it
-- is out of the ship the pair goes: a frozen thing flown into is a hit. (before, whatever's box touched the ship's
-- box counted - a ship parked inside the box of a Ha'tak or of the Dakara building flew through it.)
function SpaceGrid.LyingIn(hull, letGoNow)
	local k = hull.SGKeel
	local kp = IsValid(k) and k:GetPhysicsObject()
	if not IsValid(kp) then return end
	k.SGFrozenPairs = k.SGFrozenPairs or {}
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not mn then return end
	for e, c in pairs(k.SGFrozenPairs) do
		-- (welded on meanwhile: a rider, its own pair is the same two bodies - this one taken off would let them meet again.
		-- a turret frozen on a hall's roof, then welded on - the ship was thrown out of the world)
		if IsValid(e) and e.SGRiderOf == hull then
			if not isPair(e.SGKeelPair) then e.SGKeelPair = c end
		elseif not IsValid(e) or not (middleIn(hull, e) or reachesIn(k, e)) then
			if isPair(c) then c:Input("EnableCollisions", nil, nil, nil) c:Remove() end
			k.SGFrozenPairs[e] = nil
		end
	end
	if kp:IsMotionEnabled() and not letGoNow then return end
	local a, b = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for i = 0, 7 do
		local c = hull:LocalToWorld(Vector(bit.band(i, 1) > 0 and mx.x or mn.x, bit.band(i, 2) > 0 and mx.y or mn.y, bit.band(i, 4) > 0 and mx.z or mn.z))
		a = Vector(math.min(a.x, c.x), math.min(a.y, c.y), math.min(a.z, c.z))
		b = Vector(math.max(b.x, c.x), math.max(b.y, c.y), math.max(b.z, c.z))
	end
	for _, e in ipairs(ents.FindInBox(a, b)) do
		if not k.SGFrozenPairs[e] and not e.SGRiderOf and not (e.SpaceGridHull or e.SpaceGridKeel or e:IsPlayer() or e:IsNPC() or e:IsWorld() or IsValid(e:GetParent())) then
			local p = e:GetPhysicsObject()
			if IsValid(p) and e:GetSolid() == SOLID_VPHYSICS and (not p:IsMotionEnabled() or SpaceGrid.KeelMeets(k, e)) and (middleIn(hull, e) or reachesIn(k, e)) then
				k.SGFrozenPairs[e] = apartPair(k, e) or true
			end
		end
	end
end
-- A rider that its own addon moved since it was last placed (a ZPM hub slides its ZPMs in and out, places a new one in
-- its slot, pops one out): that is its new place in the ship, not a mistake to undo. ZPMs on a hub on a SpaceGrid ship
-- were held where they were first seen - only one slid in, others sat over the slots or frozen somewhere on the
-- hub, one doubled.
local function movedByCode(e, r)
	if not r.wp then return false end
	if e:GetPos():DistToSqr(r.wp) > 0.01 then return true end
	local a, b = e:GetAngles(), r.wa
	return math.abs(math.AngleDifference(a.p, b.p)) + math.abs(math.AngleDifference(a.y, b.y)) + math.abs(math.AngleDifference(a.r, b.r)) > 0.05
end
local function placeRiders(hull, pos, ang)
	for e, r in pairs(hull.SGRiders or {}) do
		if IsValid(e) and not e.SGHeldBy then
			local p = e:GetPhysicsObject()
			if IsValid(p) and p:IsMotionEnabled() then
				-- (something unfroze it - the destroyed ship's parts are thrown, a player's key: looked at again now)
				hull.SGRidersAt = 0
			else
				-- (a jump or a teleport of the whole ship moves the rider too: not its own move - it is where it should be, or the
				-- ship is far from where it was.: after a hyperspace jump a welded turret stood the jump's length beside the ship.)
				--
				if movedByCode(e, r) and r.hp and pos:DistToSqr(r.hp) < 512 * 512 and WorldToLocal(e:GetPos(), angle_zero, pos, ang):DistToSqr(r.lp) > 4 then
					r.lp, r.la = WorldToLocal(e:GetPos(), e:GetAngles(), r.hp, r.ha)
				end
				local np, na = LocalToWorld(r.lp, r.la, pos, ang)
				stepTo(e, np, na)
				if IsValid(p) then p:SetPos(np, true); p:SetAngles(na) end
				r.wp, r.wa, r.hp, r.ha = np, na, pos, ang
			end
		end
	end
end
-- What is welded onto a ship is a part of it: the physgun does not pull it round on its weld (a welded railgun "i even
-- managed to pysgun it upside down + when i hold the weapon the cockpit is rotatting"). Its weld taken off, it is a
-- loose thing again.
hook.Add("PhysgunPickup", "SpaceGrid.Rider", function(ply, ent)
	local hull = IsValid(ent) and ent.SGRiderOf
	if not (IsValid(hull) and hull.SpaceGridHull) then return end
	local r = hull.SGRiders and hull.SGRiders[ent]
	if not (r and r.stow) then return false end
end)
-- (what is only stowed may be taken: it and what is fixed to it are let go)
local function unstow(ent)
	local hull = IsValid(ent) and ent.SGRiderOf
	local r = IsValid(hull) and hull.SGRiders and hull.SGRiders[ent]
	if not (r and r.stow) then return false end
	for _, o in ipairs(groupOf(ent, hull) or { ent }) do
		if hull.SGRiders[o] and hull.SGRiders[o].stow then hull.SGRiders[o] = nil letGo(o, hull) end
	end
	return true
end
hook.Add("OnPhysgunPickup", "SpaceGrid.Unstow", function(_, ent) unstow(ent) end)
-- (frozen or spawned in a flying ship: stowed at once, not only at the next look)
local function lookSoon() timer.Simple(0, function() for hull in pairs(SpaceGrid.Keeled or {}) do if IsValid(hull) then hull.SGRidersAt = 0 end end end) end
hook.Add("OnPhysgunFreeze", "SpaceGrid.Stow", lookSoon)
hook.Add("OnEntityCreated", "SpaceGrid.Stow", function(e) if e:GetClass() == "prop_physics" or e:IsScripted() then lookSoon() end end)
-- (picked up all the same, by another addon: it is moved by hand, then takes its new place in the ship)
hook.Add("OnPhysgunPickup", "SpaceGrid.Rider", function(ply, ent)
	if IsValid(ent) and IsValid(ent.SGRiderOf) then ent.SGHeldBy = ply end
end)
hook.Add("PhysgunDrop", "SpaceGrid.Rider", function(ply, ent)
	if not (IsValid(ent) and ent.SGHeldBy) or ent.SpaceGridHull then return end
	ent.SGHeldBy = nil
	local hull = ent.SGRiderOf
	if IsValid(hull) and hull.SGRiders and hull.SGRiders[ent] then
		local hp, ha = hull:GetPos(), hull:GetAngles()
		local lp, la = WorldToLocal(ent:GetPos(), ent:GetAngles(), hp, ha)
		hull.SGRiders[ent] = { lp = lp, la = la, wp = ent:GetPos(), wa = ent:GetAngles(), hp = hp, ha = ha }
		local p = ent:GetPhysicsObject()
		if IsValid(p) then p:EnableMotion(false) end
	end
end)
-- a player unfreezing a rider (R with the physgun) unfreezes the ship, as on the hull
hook.Add("CanPlayerUnfreeze", "SpaceGrid.Rider", function(ply, ent)
	local hull = IsValid(ent) and ent.SGRiderOf
	if not IsValid(hull) then return end
	if unstow(ent) then ent.SGRiderMoved = nil return end
	if not SpaceGrid.TooBig(hull) then SpaceGrid.UnfreezeShip(hull) end
	return false
end)

-- how a hull's ship moves right now (its keel's body), for a rebuild
function SpaceGrid.KeelState(hull)
	local phys = SpaceGrid.Body(hull)
	if not IsValid(phys) then return { frozen = true } end
	return { frozen = not phys:IsMotionEnabled(), vel = phys:GetVelocity(), avel = phys:GetAngleVelocity(), grav = phys:IsGravityEnabled() }
end

-- put a ship somewhere at once (both bodies)
function SpaceGrid.TeleportShip(hull, pos, ang)
	for _, e in ipairs({ hull, hull.SGKeel }) do
		if IsValid(e) then
			e:SetPos(pos)
			e:SetAngles(ang)
			local p = e:GetPhysicsObject()
			if IsValid(p) then p:SetPos(pos); p:SetAngles(ang) end
		end
	end
end

-- after every physics step: each hull is put where its keel is. Moved by something else while the keel stood still
-- (a tool, a paste, a jump): the keel goes there. Held in a player's physgun (small ships only): the keel follows.
-- (the hull as a teleport: moved the normal way, the physics kept its contacts and took the jump for a fast floor -
-- its grip pulled loose crates along at the ship's speed into the walls)
local function place(e, phys, pos, ang)
	stepTo(e, pos, ang)
	if IsValid(phys) then phys:SetPos(pos, e.SpaceGridHull == true); phys:SetAngles(ang) end
end
-- Loose things in a moving ship (cargo, a crate on the deck, a lamp welded to the wall): the hull is a frozen body
-- that is put somewhere new every tick - it pushes nothing along by itself. So what lies in its box is moved along
-- by the same step (its own motion stays: it is the motion inside the ship); what leaves the box gets the ship's speed
-- once. Players: StarCore carries them (sh_walk.lua). Not moved: other ships and their parts, players, NPCs, what is
-- fixed to something else (a contraption of its own), what is parented.
local carried = setmetatable({}, { __mode = "k" })   -- entity -> hull that carries it
-- far from where it was last put: a Stargate on board, rings, a transporter took it. That is no way out through a wall (it was put
-- back: no crate came through the gate on board of a flying ship) and it does not get the ship's speed (test rccrates)
local function jumped(e)
	local p = e:GetPhysicsObject()
	return e.SGCarryAt and IsValid(p) and p:GetPos():DistToSqr(e.SGCarryAt) > 300 * 300
end
local function carryable(e, hull, k)
	if not IsValid(e) or e == hull or e == k or e:IsPlayer() or e:IsNPC() or IsValid(e:GetParent()) then return false end
	if e.SpaceGridHull or e.SpaceGridKeel or e.SpaceGridSeat or e.SpaceGridDoor or e.StarCoreDockOn then return false end
	if e:GetClass() == "starcore" and (e == hull.SGCore or e.DockedTo or not builtAboard(e, hull)) then return false end
	-- (another addon that moves its own things in a flying ship - AGP's resting Replicators hold on to the deck
	-- themselves - says so with e.SGNoCarry = true; checked as a function too: e:SGNoCarry(hull))
	local nc = e.SGNoCarry
	if nc == true or (isfunction(nc) and nc(e, hull)) then return false end
	local p = e:GetPhysicsObject()
	if not IsValid(p) or not (p:IsMotionEnabled() or e.SGCarBodies or (SpaceGrid.Resting and SpaceGrid.Resting[e])) then return false end
	if constraint.HasConstraints(e) then
		-- fixed to something: only when that is this ship (a lamp welded to its wall) - not a contraption of its own
		for _, c in ipairs(constraint.GetTable(e) or {}) do
			local o = c.Ent1 == e and c.Ent2 or c.Ent1
			if IsValid(o) and o ~= hull and o ~= k and not o:IsWorld() then return builtAboard(e, hull) end
		end
	end
	return true
end
-- what may make a carried thing fast at once (carry's kick guard): hits, the physgun, the gravity gun, a player's Use
local function kickOK(e) if IsValid(e) then e.SGKickOK = CurTime() + 1 end end
SpaceGrid.KickOK = kickOK
-- What lies still on the deck with nobody near it is "at rest": its body frozen, on its place in the ship, like a rider
-- (odd_fps: a hall with 40 boxes in flight cost half of the frames - each step the physics looked for all their contacts
-- anew; 5 ms a step, a tenth of it at rest). Somebody comes near, it is hit, taken or the ship parks: it is loose again.
local resting = setmetatable({}, { __mode = "k" })   -- entity -> { hull, lp, la, tick }
local function unrest(e, hull)
	local r = resting[e]
	if not r then return end
	resting[e] = nil
	e.SGRestAt = nil
	local p = e:GetPhysicsObject()
	-- (one that was parented meanwhile - a Replicator holds on to the hull - is its owner's now: its body left as it is)
	if not IsValid(p) or IsValid(e:GetParent()) then return end
	p:EnableMotion(true)
	local kp = IsValid(r.hull) and SpaceGrid.Body(r.hull)
	p:SetVelocity(IsValid(kp) and kp:IsMotionEnabled() and kp:GetVelocity() or vector_origin)
	p:SetAngleVelocity(vector_origin)
	p:Wake()
end
SpaceGrid.Resting = resting
local function someoneNear(e)
	local c, r = e:WorldSpaceCenter(), e:BoundingRadius() + 90
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and not ply:InVehicle() then
			local w = ply:GetActiveWeapon()
			local far = IsValid(w) and w:GetClass() == "weapon_physcannon" and r + 400 or r
			if ply:WorldSpaceCenter():DistToSqr(c) < far * far then return true end
		end
	end
	return false
end
timer.Create("SpaceGrid.Resting", 0.2, 0, function()
	local now = engine.TickCount()
	for e, r in pairs(resting) do
		if not IsValid(e) then resting[e] = nil elseif now - r.tick > 10 then unrest(e) end
	end
end)
hook.Add("EntityTakeDamage", "SpaceGrid.CarryKick", function(e) if carried[e] then kickOK(e) unrest(e) end end)
hook.Add("PhysgunDrop", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPhysgunPickup", "SpaceGrid.CarryKick", function(_, e) kickOK(e) unrest(e) end)
hook.Add("GravGunPunt", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("GravGunOnDropped", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPlayerPhysicsDrop", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPlayerPhysicsPickup", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
-- (the door and field sheets ask: a carried thing's speed is already its speed inside the ship - sv_doors.lua ThrowBack)
function SpaceGrid.CarriedBy(e) return carried[e] end
-- What has more than one body (scene_aboard: a ragdoll slid out of a flying hall, a buggy was flung away): a ragdoll's
-- limbs each go along by the same step, a car as a whole (its wheels follow it); slow on the deck, it stays there.
local function manyBodies(e) return e:GetPhysicsObjectCount() > 1 or (e:IsVehicle() and e:GetClass() ~= "prop_vehicle_prisoner_pod") end
-- (its wheels are bodies of their own on springs: held, they were pressed down through the deck and stayed under it, the car
-- did not drive any more - sgcar; now they keep their places under it)
local function carWheels(e)
	local w, p = {}, e:GetPhysicsObject()
	for i = 1, e:GetPhysicsObjectCount() - 1 do
		local b = e:GetPhysicsObjectNum(i)
		if IsValid(b) then local lp, la = WorldToLocal(b:GetPos(), b:GetAngles(), p:GetPos(), p:GetAngles()) w[i] = { lp, la } end
	end
	return w
end
local function carStill(e, w, pos, ang)
	for i, l in pairs(w or {}) do
		local b = e:GetPhysicsObjectNum(i)
		if IsValid(b) then
			local np, na = LocalToWorld(l[1], l[2], pos, ang)
			-- (the place last: SetAngles puts a body back to where it was before SetPos in the same step)
			b:SetAngles(na)
			b:SetPos(np, true)
		end
	end
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local b = e:GetPhysicsObjectNum(i)
		if IsValid(b) then b:SetVelocity(vector_origin) b:SetAngleVelocity(vector_origin) b:Wake() end
	end
end
-- (a car's bodies cannot be put anywhere one by one, only the entity; its wheels come along at once only by a jump of more than
-- about 130 units, by steps they lag and end up to 132 off - measured by test cardbg)
local function carPut(e, at, np, na)
	e:SetPos(np)
	e:SetAngles(na)
	carStill(e)
end
-- (held, none of its bodies moves by itself: put into the deck's contact again and again, the physics stopped its wheels
-- meeting the ship at all, and they stayed under the deck - sgcar)
local function carFreeze(e, on)
	if on then
		if e.SGCarBodies then return end
		e.SGCarBodies = {}
		for i = 0, e:GetPhysicsObjectCount() - 1 do
			local b = e:GetPhysicsObjectNum(i)
			if IsValid(b) and b:IsMotionEnabled() then e.SGCarBodies[i] = true b:EnableMotion(false) end
		end
	elseif e.SGCarBodies then
		for i in pairs(e.SGCarBodies) do
			local b = e:GetPhysicsObjectNum(i)
			if IsValid(b) then b:EnableMotion(true) b:Wake() end
		end
		e.SGCarBodies = nil
	end
end
hook.Add("PhysgunPickup", "SpaceGrid.CarFree", function(_, e) if IsValid(e) and e.SGCarBodies then carFreeze(e, false) end end)
-- (let go: its wheels are put under it, still frozen, then it is free. Off their places they go through the deck)
local settling = {}
local function carPlace(e, at, up)
	local np, na = LocalToWorld(at.lp + Vector(0, 0, up or 1), at.la, at.hull:GetPos(), at.hull:GetAngles())
	carPut(e, at, np, na)
end
local function carFree(e)
	local at = e.SGCarAt
	if not at or not at.held then if not settling[e] then carFreeze(e, false) end return end
	at.held = nil
	if IsValid(at.hull) and not e:IsPlayerHolding() and LocalToWorld(at.lp, at.la, at.hull:GetPos(), at.hull:GetAngles()):DistToSqr(e:GetPos()) < 100 * 100 then
		settling[e] = { at = at, n = 0 }
	else
		carFreeze(e, false)
	end
end
hook.Add("Tick", "SpaceGrid.CarSettle", function()
	for e, st in pairs(settling) do
		if not IsValid(e) then settling[e] = nil
		elseif st.at.held or e:IsPlayerHolding() or not IsValid(st.at.hull) then settling[e] = nil if not st.at.held then carFreeze(e, false) end
		else
			st.n = st.n + 1
			e.SGCarJump = engine.TickCount()   -- (tests read it)
			carPlace(e, st.at, st.n == 2 and 160 or 1)   -- (up and back: its wheels under it again)
			if st.n >= 6 then
				settling[e] = nil
				carFreeze(e, false)
				carPlace(e, st.at)
			end
		end
	end
end)
local function carryMany(e, hull, oldPos, oldAng, newPos, newAng, free)
	local function step(p, set)
		local lp, la = WorldToLocal(p:GetPos(), p:GetAngles(), oldPos, oldAng)
		local lv = WorldToLocal(p:GetVelocity(), angle_zero, vector_origin, oldAng)
		if not free then
			local l = lv:Length()
			if l < 200 then lv = Vector(lv.x * 0.6, lv.y * 0.6, math.min(lv.z, 20)) elseif l > 400 and e:IsRagdoll() then lv = lv * (400 / l) end
		end
		local np, na = LocalToWorld(lp, la, newPos, newAng)
		set(np, na)
		p:SetVelocity(LocalToWorld(lv, angle_zero, vector_origin, newAng))
	end
	if e:IsVehicle() then
		free = e:IsPlayerHolding()   -- (its wheels on the deck count as hits)
		-- (a car put somewhere new each step loses the ground under its wheels and sank through the deck: while the ship
		-- moves its brake is on, it keeps its spot on the deck - test sgcar)
		local p, tick = e:GetPhysicsObject(), engine.TickCount()
		local d = e.GetDriver and e:GetDriver()
		if IsValid(d) and newPos:DistToSqr(oldPos) < 0.25 then carFree(e) return end   -- (driven while the ship only hovers)
		local at = e.SGCarAt
		local lp, la = WorldToLocal(p:GetPos(), p:GetAngles(), oldPos, oldAng)
		-- (a ship that hovers moves now and then: the same spot again, unless it was driven or pushed elsewhere)
		if free or not (at and at.hull == hull and (tick - at.tick < 20 or (tick - at.tick < 600 and (at.lp - lp):Length2DSqr() < 30 * 30 and math.abs(at.lp.z - lp.z) < 60))) then
			at = { hull = hull, lp = lp, la = la, wheels = carWheels(e) }
			e.SGCarAt = at
		end
		at.held = not free or nil
		at.tick = tick
		carFreeze(e, not free)
		local np, na = LocalToWorld(at.lp, at.la, newPos, newAng)
		-- (drawn smoothly by cl_aboard.lua)
		carPut(e, at, np, na)
		return
	end
	-- (a ragdoll that has passed a wall since the last step - one spawned half in the deck fell through it - goes back, all of it)
	do
		local p0 = e:GetPhysicsObject()
		local mid = p0:LocalToWorld(p0:GetMassCenter())
		local good = e.SGManyGood
		local function only(x) return x == hull end
		local past = good and good.hull == hull and util.TraceLine({ start = (LocalToWorld(good.lp, angle_zero, oldPos, oldAng)), endpos = mid, ignoreworld = true, filter = only })
		if past and (past.Hit or past.StartSolid) then
			local d = LocalToWorld(good.lp, angle_zero, oldPos, oldAng) - mid
			for i = 0, e:GetPhysicsObjectCount() - 1 do
				local b = e:GetPhysicsObjectNum(i)
				if IsValid(b) then b:SetPos(b:GetPos() + d, true) b:SetVelocity(vector_origin) end
			end
			hull.SGCarryBack = (hull.SGCarryBack or 0) + 1
		elseif not good and util.TraceLine({ start = mid, endpos = mid + Vector(0, 0, 0.1), ignoreworld = true, filter = only }).StartSolid then
			-- (spawned into the deck: up, out of it)
			local up = hull:GetUp()
			for n = 1, 12 do
				local q = mid + up * (n * 6)
				if not util.TraceLine({ start = q, endpos = q + Vector(0, 0, 0.1), ignoreworld = true, filter = only }).StartSolid then
					for i = 0, e:GetPhysicsObjectCount() - 1 do
						local b = e:GetPhysicsObjectNum(i)
						if IsValid(b) then b:SetPos(b:GetPos() + up * (n * 6 + 6), true) b:SetVelocity(vector_origin) end
					end
					break
				end
			end
		elseif not util.TraceLine({ start = mid, endpos = mid + Vector(0, 0, 0.1), ignoreworld = true, filter = only }).StartSolid then
			e.SGManyGood = { hull = hull, lp = (WorldToLocal(mid, angle_zero, oldPos, oldAng)) }
		end
		-- (and each limb: a ragdoll in a pile slid into the corner of deck and back wall, its legs went through the deck while
		-- its middle stayed above - odd_spawn on a server. A limb beyond a wall, seen from its middle, is put back before that
		-- wall.)
		if e:IsRagdoll() then
			local root = p0:LocalToWorld(p0:GetMassCenter())
			for i = 1, e:GetPhysicsObjectCount() - 1 do
				local b = e:GetPhysicsObjectNum(i)
				if IsValid(b) then
					local w = b:LocalToWorld(b:GetMassCenter())
					local tr = util.TraceLine({ start = root, endpos = w, ignoreworld = true, filter = only })
					if tr.Hit and not tr.StartSolid then
						b:SetPos(b:GetPos() + (tr.HitPos + tr.HitNormal * 4 - w), true)
						b:SetVelocity(p0:GetVelocity())
						hull.SGLimbBack = (hull.SGLimbBack or 0) + 1   -- (tests read it)
					end
				end
			end
		end
	end
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local p = e:GetPhysicsObjectNum(i)
		if IsValid(p) then step(p, function(np, na) p:SetPos(np, true) p:SetAngles(na) end) end
	end
end
-- who is drawn by the client on its place in the ship (cl_aboard.lua: an NPC thinks ten times a second, the game draws it in
-- steps of that while its ship turns or climbs - sgshake)
local shown = setmetatable({}, { __mode = "k" })
local function showAboard(e, hull, lp, la)
	local st = shown[e]
	if not st or st.hull ~= hull then
		-- (whoever dies in a flying ship leaves a body on the server, that goes along; the game's own lies in the world and went
		-- backwards out through the hull - hunt_fight)
		if e:IsNPC() and not e:GetShouldServerRagdoll() then e.SGCorpse = true e:SetShouldServerRagdoll(true) end
		st = { hull = hull }
		shown[e] = st
		e:SetNWEntity("SGAboard", hull)
	end
	-- (its place in the ship is sent by itself: the game's message may have it a step behind its ship)
	if not st.lp or st.lp:DistToSqr(lp) > 0.04 then st.lp = lp e:SetNWVector("SGAboardAt", lp) end
	if not st.la or math.abs(math.AngleDifference(st.la.p, la.p)) + math.abs(math.AngleDifference(st.la.y, la.y)) + math.abs(math.AngleDifference(st.la.r, la.r)) > 0.5 then st.la = la e:SetNWAngle("SGAboardAng", la) end
	st.tick = engine.TickCount()
end
timer.Create("SpaceGrid.Aboard", 0.25, 0, function()
	local now = engine.TickCount()
	for e, st in pairs(shown) do
		if not IsValid(e) then shown[e] = nil
		elseif now - st.tick > 10 then
			shown[e] = nil
			e:SetNWEntity("SGAboard", NULL)
			if e.SGCorpse then e.SGCorpse = nil e:SetShouldServerRagdoll(false) end
			carFree(e)
		end
	end
end)
-- A ragdoll from the spawn menu: the game puts it by its bounds, aimed at a ship's deck 62 units under it - it fell out of the
-- ship (odd_spawn in a hosted game, six of six). What the player cannot see through the hull comes to their side.
hook.Add("PlayerSpawnedRagdoll", "SpaceGrid.Aboard", function(ply, _, rag)
	if not (IsValid(ply) and IsValid(rag)) then return end
	local p0 = rag:GetPhysicsObject()
	if not IsValid(p0) then return end
	local eye, mid = ply:EyePos(), p0:LocalToWorld(p0:GetMassCenter())
	local tr = util.TraceLine({ start = eye, endpos = mid, ignoreworld = true, filter = function(x) return x.SpaceGridHull == true end })
	if not tr.Hit or tr.StartSolid then return end
	local n, low = tr.HitNormal, 0
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local b = rag:GetPhysicsObjectNum(i)
		if IsValid(b) then low = math.min(low, (b:GetPos() - tr.HitPos):Dot(n)) end
	end
	local d = n * (12 - low)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local b = rag:GetPhysicsObjectNum(i)
		if IsValid(b) then b:SetPos(b:GetPos() + d, true) end
	end
end)
-- the body of somebody who died aboard: as fast as the ship, gone again after a while (the newest eight stay)
local corpses = {}
hook.Add("CreateEntityRagdoll", "SpaceGrid.Corpse", function(owner, rag)
	if not (IsValid(owner) and owner.SGCorpse and IsValid(rag)) then return end
	local st = shown[owner]
	local k = st and IsValid(st.hull) and st.hull.SGKeel
	if IsValid(k) then
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local b = rag:GetPhysicsObjectNum(i)
			if IsValid(b) then b:SetVelocity(k:GetVelocity()) end
		end
	end
	corpses[#corpses + 1] = rag
	if #corpses > 8 then SafeRemoveEntity(table.remove(corpses, 1)) end
	SafeRemoveEntityDelayed(rag, 45)
end)
-- A player's own body (odd_die film): the game's body of a dead player moves on each player's computer only, the ship
-- cannot carry it - killed aboard in flight it flew through the hall and lay on the grass outside. Aboard a moving
-- ship the body is one of the server's instead, carried like the others, and the dead look at it until they spawn
-- again (the game's own spawn ends the looking).
hook.Add("PlayerDeath", "SpaceGrid.Corpse", function(ply)
	if not IsValid(ply) then return end
	local c = ply:WorldSpaceCenter()
	local hull
	local ab = ply.SGAboard
	if ab and IsValid(ab.hull) and engine.TickCount() - ab.tick < 66 then hull = ab.hull end
	if not hull then
		for _, h in ipairs(ents.FindByClass("spacegrid_hull")) do
			if h.SGMins and h:WorldToLocal(c):WithinAABox(h.SGMins, h.SGMaxs) and enclosed(h, c) then hull = h break end
		end
	end
	local k = hull and hull.SGKeel
	if not (IsValid(k) and k:GetVelocity():LengthSqr() > 40 * 40) then return end
	local rag = ents.Create("prop_ragdoll")
	if not IsValid(rag) then return end
	rag:SetModel(ply:GetModel())
	rag:SetPos(ply:GetPos())
	rag:SetAngles(Angle(0, ply:GetAngles().y, 0))
	rag:SetSkin(ply:GetSkin())
	for i = 0, ply:GetNumBodyGroups() - 1 do rag:SetBodygroup(i, ply:GetBodygroup(i)) end
	rag:Spawn()
	rag:Activate()
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)   -- (nobody trips over it)
	rag:SetNWVector("SGPlayerColor", ply:GetPlayerColor())
	local v = k:GetVelocity()
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local b = rag:GetPhysicsObjectNum(i)
		local bone = rag:TranslatePhysBoneToBone(i)
		local m = bone and bone >= 0 and ply:GetBoneMatrix(bone)
		if IsValid(b) then
			if m then b:SetPos(m:GetTranslation()) b:SetAngles(m:GetAngles()) end
			b:SetVelocity(v)
		end
	end
	local old = ply:GetRagdollEntity()
	if IsValid(old) then old:Remove() end
	ply:Spectate(OBS_MODE_CHASE)
	ply:SpectateEntity(rag)
	ply.SGBody = rag
	corpses[#corpses + 1] = rag
	if #corpses > 8 then SafeRemoveEntity(table.remove(corpses, 1)) end
	SafeRemoveEntityDelayed(rag, 45)
end)
local function carry(hull, k, oldPos, oldAng, newPos, newAng, vship)
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not mn then return end
	-- Never out through a wall (a crate pressed into a corner in hard turns went out through the wall at 2400 units
	-- a second). What the ship carried and has passed through its hull since the last step is put back where it was.
	--
	local tick = engine.TickCount()
	for e, h in pairs(carried) do
		if resting[e] then continue end
		-- (only while the hull still stands where this code last put it: moved by anything else - a paste, the
		-- physgun, a jump - the old spot means nothing)
		if h == hull and IsValid(e) and not IsValid(e:GetParent()) and e.SGCarryAt and e.SGCarryHull and oldPos:DistToSqr(e.SGCarryHull) < 0.01 and not jumped(e) then
			local p = e:GetPhysicsObject()
			local tr = IsValid(p) and util.TraceLine({ start = e.SGCarryAt, endpos = p:GetPos(), ignoreworld = true, filter = function(x) return x == hull end })
			-- (pressed into a wall bit by bit, its middle in it now: back to where it last was free - a balloon went out through
			-- the roof that way)
			local mid = IsValid(p) and p:LocalToWorld(p:GetMassCenter())
			-- (or past it: from its middle's last free spot to where the middle is now there is a wall)
			local good = e.SGCarryGood
			local tg = mid and good and util.TraceLine({ start = (LocalToWorld(good.mid, angle_zero, oldPos, oldAng)), endpos = mid, ignoreworld = true, filter = function(x) return x == hull end })
			local stuck = tg and (tg.Hit or tg.StartSolid)
			-- (the same for the middle of its shape: a balloon's weight is not there)
			local wc = e:WorldSpaceCenter()
			if not stuck and good and good.wc then stuck = util.TraceLine({ start = (LocalToWorld(good.wc, angle_zero, oldPos, oldAng)), endpos = wc, ignoreworld = true, filter = function(x) return x == hull end }).Hit end
			if mid and not stuck and not util.TraceLine({ start = mid, endpos = mid + Vector(0, 0, 0.1), ignoreworld = true, filter = function(x) return x == hull end }).StartSolid then
				e.SGCarryGood = { pos = (WorldToLocal(p:GetPos(), angle_zero, oldPos, oldAng)), mid = (WorldToLocal(mid, angle_zero, oldPos, oldAng)), wc = (WorldToLocal(wc, angle_zero, oldPos, oldAng)) }
			end
			if stuck and IsValid(p) then
				p:SetPos((LocalToWorld(good.pos, angle_zero, oldPos, oldAng)), true)
				p:SetVelocity(vector_origin)
				hull.SGCarryBack = (hull.SGCarryBack or 0) + 1
			elseif tr and tr.Hit and not tr.StartSolid then
				do
					p:SetPos(e.SGCarryAt)
					p:SetVelocity(vector_origin)
					p:SetAngleVelocity(vector_origin)
					hull.SGCarryBack = (hull.SGCarryBack or 0) + 1   -- (tests read it)
				end
			end
		end
	end
	local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for i = 0, 7 do
		local c = LocalToWorld(Vector(bit.band(i, 1) > 0 and mx.x or mn.x, bit.band(i, 2) > 0 and mx.y or mn.y, bit.band(i, 4) > 0 and mx.z or mn.z), angle_zero, oldPos, oldAng)
		lo = Vector(math.min(lo.x, c.x), math.min(lo.y, c.y), math.min(lo.z, c.z))
		hi = Vector(math.max(hi.x, c.x), math.max(hi.y, c.y), math.max(hi.z, c.z))
	end
	-- The deck's pull (same test): a ship that banks into a turn, pitches or rolls tilts its deck, and the world's
	-- gravity slid every loose thing down to the lowest wall and pressed it there. In the ship the pull is towards its
	-- deck, as on the ships of the series: the game's own gravity stays on, the difference is added here each step.
	local g = physenv.GetGravity()
	local gs = g:Length() * engine.TickInterval()
	local fix = WorldToLocal(-g:GetNormalized(), angle_zero, vector_origin, newAng) - Vector(0, 0, 1)   -- (ship space)
	local tilted = fix:LengthSqr() > 1e-6
	local inside = {}
	local innerOf = innerShips(hull)
	for _, e in ipairs(ents.FindInBox(lo, hi)) do
		if e:IsNPC() and not IsValid(e:GetParent()) and (e:GetMoveType() == MOVETYPE_VPHYSICS or e:GetMoveType() == MOVETYPE_FLY) then
			-- (one that flies in the hall: by its body, nothing holds it to the deck)
			local c = e.SGFliesIn
			if not (c and c.hull == hull and c.t > CurTime()) then
				c = { hull = hull, t = CurTime() + 0.5, ok = hull:WorldToLocal(e:WorldSpaceCenter()):WithinAABox(mn, mx) and (enclosed(hull, e:WorldSpaceCenter()) or (e.SGFlyBlock or 0) > CurTime() - 1) }
				e.SGFliesIn = c
			end
			if c.ok then
				local p = e:GetPhysicsObject()
				local body = e:GetMoveType() == MOVETYPE_VPHYSICS and IsValid(p)
				local lp, la = WorldToLocal(body and p:GetPos() or e:GetPos(), body and p:GetAngles() or e:GetAngles(), oldPos, oldAng)
				-- (never out through a wall: from where it last was to where it is now)
				do
					local w = e:WorldSpaceCenter()
					local good = e.SGFlyGood
					local tr = good and good.hull == hull and tick - good.tick < 10 and util.TraceLine({ start = (LocalToWorld(good.lp, angle_zero, oldPos, oldAng)), endpos = w, ignoreworld = true, filter = function(x) return x == hull end })
					if tr and (tr.Hit or tr.StartSolid) then
						lp, good.tick, e.SGFlyBlock = good.at, tick, CurTime()
						if body then p:SetVelocity(vector_origin) end
						hull.SGCarryBack = (hull.SGCarryBack or 0) + 1
					else e.SGFlyGood = { hull = hull, lp = (WorldToLocal(w, angle_zero, oldPos, oldAng)), at = lp, tick = tick } end
				end
				-- (one that stands on the deck - a floor turret, a rollermine at rest - is held up by it: put somewhere new each
				-- step, the deck pushed back too late and a turret sank 12 units into the floor in 4 seconds) (measured from where
				-- the body is put, never from the entity, which is a step behind: read from there the lift added up each step
				-- and a turret rose 30 units into the back wall)
				local onDeck = false
				if body and e.SGFlyBlock ~= CurTime() then
					local up = oldAng:Up()
					local mid = (e:OBBMaxs().z + e:OBBMins().z) * 0.5
					local half = mid - e:OBBMins().z
					local reach = half + 8
					local c = LocalToWorld(lp, angle_zero, oldPos, oldAng) + up * mid
					local tr = util.TraceLine({ start = c, endpos = c - up * reach, ignoreworld = true, filter = function(x) return x == hull end })
					if tr.Hit and not tr.StartSolid then
						local gap = tr.Fraction * reach
						if gap < half - 0.5 then lp = lp + Vector(0, 0, math.min(half - gap, 2)) end
						onDeck = gap < half + 2
					end
				end
				-- (a floor turret never moves by itself: on the deck it keeps its spot, as a crate does - in the turns it slid into
				-- the side walls and out. Knocked over, shot away or carried, it is free again.)
				local spot = false
				if onDeck and e:GetClass() == "npc_turret_floor" and (e.SGKickOK or 0) < CurTime() and not e:IsPlayerHolding() then
					local d = e.SGDeckSpot
					if d and d.hull == hull and (lp - d.lp):LengthSqr() < 40 * 40 then lp, la, spot = d.lp, d.la, true
					else e.SGDeckSpot = { hull = hull, lp = lp, la = la } end
				else e.SGDeckSpot = nil end
				local np, na = LocalToWorld(lp, la, newPos, newAng)
				local lv = body and WorldToLocal(p:GetVelocity(), angle_zero, vector_origin, oldAng)
				if onDeck and lv.z < 0 then lv.z = 0 end
				if spot then lv = Vector(0, 0, 0) p:SetAngleVelocity(vector_origin) end
				stepTo(e, np, na)
				showAboard(e, hull, lp, la)
				if body then p:SetPos(np, true) p:SetAngles(na) p:SetVelocity(LocalToWorld(lv, angle_zero, vector_origin, newAng)) end
			end
		elseif e:IsNPC() and not IsValid(e:GetParent()) then
			-- (who is no player stood still while the ship flew on - its walls went through them. Who stands on this
			-- ship's deck goes with it and stays on the deck.)
			local ab = e.SGAboard
			-- (cut in two in flight: who is in this half now goes with it)
			if ab and ab.hull ~= hull and k.SGApart and IsValid(ab.hull) and k.SGApart[ab.hull] and middleIn(hull, e) and not middleIn(ab.hull, e) then
				ab = { hull = hull, tick = tick }
				e.SGAboard = ab
			end
			-- (on the deck of a ship parked in this one: with it, or this ship's walls hit them - scene_nest)
			local gr = e:GetGroundEntity()
			local inner = hull.SGStowShips and (hull.SGStowShips[gr] and gr or ab and IsValid(ab.inner) and hull.SGStowShips[ab.inner] and tick - ab.tick < 40 and ab.inner) or nil
			-- (on something welded on - a ring platform - or on a lift, a seat of it: the ship's own)
			local under = IsValid(gr) and gr ~= hull and (gr.SGRiderOf == hull or gr:GetParent() == hull) and gr or nil
			local on = (gr == hull or inner or under) and not (ab and ab.hull ~= hull and (ab.ride or 0) > CurTime()) or (ab and ab.hull == hull and (tick - ab.tick < 40 or (ab.ride or 0) > CurTime()))
			local lp, la = WorldToLocal(e:GetPos(), e:GetAngles(), oldPos, oldAng)
			-- (one that dies here - in a jump, off its feet - stays where it fell until its body takes its place; it stood still
			-- in the air while the ship flew on, a fast headcrab) (and one that came in
			-- the air - beamed aboard by a transporter, 30 units over the deck: carried only once it stood on the deck, it fell
			-- for 0.3 s while the hall flew on and landed 150 to 200 units behind its spot. Inside the closed hull it is aboard at
			-- once.) (not one of a ship docked or parked in
			-- this one: that ship's crew - taken by the carrier, the docked ship hit its own citizen, scene_nest) (one beamed
			-- over from another ship still has that
			-- one's mark: it counts only while it is in that ship - rcbeam)
			if not on and not (ab and ab.hull ~= hull and IsValid(ab.hull) and tick - ab.tick < 40 and middleIn(ab.hull, e)) and lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z and lp.z < mx.z
				and not (innerOf and inInner(innerOf, e)) and not (hull.SGStowShips and (function() for oh in pairs(hull.SGStowShips) do if IsValid(oh) and middleIn(oh, e) then return true end end end)())
				and enclosed(hull, e:WorldSpaceCenter()) then on = true end
			if on and lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z - 30 and lp.z < mx.z + 24 then   -- (on its roof too)
				local tr = util.TraceLine({ start = LocalToWorld(lp + Vector(0, 0, 40), angle_zero, oldPos, oldAng), endpos = LocalToWorld(lp - Vector(0, 0, 12), angle_zero, oldPos, oldAng), ignoreworld = true, filter = function(x) return x == hull or x == inner or x == under end })
				if tr.Hit and not tr.StartSolid then
					local fz = WorldToLocal(tr.HitPos, angle_zero, oldPos, oldAng).z
					if lp.z < fz + 0.5 then lp = Vector(lp.x, lp.y, fz + 0.5) end
					e:SetGroundEntity(inner or under or hull)
					if e:GetVelocity().z < 0 then e:SetLocalVelocity(vector_origin) end
					e.SGAboard = { hull = hull, tick = tick, inner = inner, ride = ab and ab.hull == hull and ab.ride or nil }
				end
				local np, na = LocalToWorld(lp, la, newPos, newAng)
				stepTo(e, np, Angle(0, na.y, 0))
				showAboard(e, hull, lp, la)
				local shadow = e:GetPhysicsObject()
				if IsValid(shadow) then shadow:SetPos(np, true) end
			end
		elseif (e:GetMoveType() == MOVETYPE_FLY or e:GetMoveType() == MOVETYPE_FLYGRAVITY) and not e:IsPlayer() and not IsValid(e:GetParent()) and not e.SGNoCarry then
			-- (a rocket, a bolt: it flies by itself. Where a wall of the moving ship came over it since the last step it is put before
			-- that wall, to meet it - a rocket went through the deck of a climbing ship, hunt_shots)
			local w = e:GetPos()
			local l = WorldToLocal(w, angle_zero, newPos, newAng)
			local f = e.SGShotAt
			if f and f.hull == hull and tick - f.tick < 4 then
				local tr = util.TraceLine({ start = LocalToWorld(f.l, angle_zero, newPos, newAng), endpos = w, ignoreworld = true, filter = function(x) return x == hull end })
				if tr.Hit and not tr.StartSolid then
					local v = e:GetVelocity()
					local into = v:GetNormalized()
					e:SetPos(tr.HitPos + tr.HitNormal * 3)
					-- (flying away from the wall it would not meet it: into it)
					if into:Dot(tr.HitNormal) > -0.2 then e:SetLocalVelocity(-tr.HitNormal * math.max(v:Length(), 800)) end
					l = WorldToLocal(e:GetPos(), angle_zero, newPos, newAng)
				end
			end
			e.SGShotAt = { hull = hull, l = l, tick = tick }
		-- (Replicator chat's H 12: a bug at rest parented itself to the hull as the ship started; set on its world spot as if
		-- that were in the ship, it went out of the world. Parented, it is not ours to place.)
		elseif resting[e] and resting[e].hull == hull and IsValid(e:GetParent()) then
			unrest(e)
		elseif resting[e] and resting[e].hull == hull and (e.SGKickOK or 0) < CurTime() and not e:IsPlayerHolding() and not ((tick + e:EntIndex()) % 8 == 0 and (someoneNear(e) or (constraint.HasConstraints(e) and not carryable(e, hull, k)))) then
			local r, p = resting[e], e:GetPhysicsObject()
			if IsValid(p) then
				r.tick = tick
				inside[e], carried[e] = true, hull
				local np, na = LocalToWorld(r.lp, r.la, newPos, newAng)
				stepTo(e, np, na)
				p:SetPos(np, true)
				p:SetAngles(na)
				e.SGCarryAt, e.SGCarryTick, e.SGCarryHull = np, tick, newPos
			end
		elseif carryable(e, hull, k) and not (innerOf and inInner(innerOf, e)) then
			-- (where its body is: a sleeping thing's entity keeps the place from before the last step until it wakes -
			-- read from there, it was put back by the ship's whole step each time and thrown at the walls)
			if resting[e] then unrest(e) end
			local p = e:GetPhysicsObject()
			local lp, la = WorldToLocal(p:GetPos(), p:GetAngles(), oldPos, oldAng)
			if lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z and lp.z < mx.z + 48 then
				inside[e] = true
				if carried[e] ~= hull then e.SGCarryGood = nil end   -- (a free spot of another ship says nothing here)
				carried[e] = hull
				-- Its own no-touch link with the keel (two crates in a Gate hall were pushed along by the keel at the
				-- ship's speed, tick by tick, into the corners and out through the walls - the keel's block is the whole
				-- hall, and the "keel touches only the map" rule did not hold for them). The same link the welded
				-- riders have; made anew for a new keel body, taken off when it leaves.
				local kp = k:GetPhysicsObject()
				-- (here - the old keel body was gone after a rebuild, and comparing with a removed body is an error: looked
				-- at with IsValid first)
				local of = e.SGCarryPairOf
				if not (isPair(e.SGCarryPair) and of and IsValid(of) and of == kp) then
					if isPair(e.SGCarryPair) then e.SGCarryPair:Remove() end
					e.SGCarryPair, e.SGCarryPairOf = apartPair(k, e), kp
				end
				if manyBodies(e) then
					if e:IsVehicle() then showAboard(e, hull, e.SGCarAt and e.SGCarAt.lp or lp, e.SGCarAt and e.SGCarAt.la or la) end
					carryMany(e, hull, oldPos, oldAng, newPos, newAng, (e.SGKickOK or 0) >= CurTime() or e:IsPlayerHolding())
					e.SGCarryAt = nil
					continue
				end
				local np, na = LocalToWorld(lp, la, newPos, newAng)
				-- (its motion inside the ship turns with the ship: kept in ship space)
				-- (in the wormhole: it waits on its spot of the ship)
				local lv = e.AGPRideWith and Vector(0, 0, 0) or WorldToLocal(p:GetVelocity(), angle_zero, vector_origin, oldAng)
				-- No kick from the deck (same test): the hull is put somewhere new each step, and the physics takes that
				-- jump of the floor for a fast floor - a crate lying on it got up to the ship's whole speed at once and
				-- flew into the walls. Faster by more than 150 in one step, with nothing that hit it (a shot, a blast,
				-- the physgun or gravity gun: SpaceGrid.KickOK), it keeps the speed it had.
				-- (a slow ship follows its keel only every few steps: the speed it had when last carried, up to 10 steps ago)
				local last = (e.SGCarryTick or 0) >= tick - 10 and e.SGCarryLV
				local free = (e.SGKickOK or 0) >= CurTime() or e:IsPlayerHolding()   -- (thrown, hit, or carried by a player's E)
				if last and lv:Length() > last:Length() + 150 and not free then
					lv = last
					hull.SGKickCut = (hull.SGKickCut or 0) + 1   -- (tests read it)
					e.SGKickCutAt = tick
				end
				if tilted and p:IsGravityEnabled() and not e.AGPRideWith then lv = lv + fix * gs end
				-- Held on the deck while the ship flies (same test: two crates on the deck of a turning ship slid outwards
				-- faster each step, nothing touching them, until they were in the corners and out through the walls).
				-- Lying on the ship's floor and slow (nothing threw it), it does not slide: the deck holds it, as a
				-- crate is held by its weight on a real deck. Parked ships are not carried: there the game's own physics.
				local held
				local topple = false
				if lv:LengthSqr() < 200 * 200 and not free then
					local ext = (e:OBBMaxs() - e:OBBMins()):Length() * 0.5 + 6
					local down = -oldAng:Up()   -- (the hull still stands where it stood this step)
					local c = p:LocalToWorld(p:GetMassCenter())
					local tr = util.TraceLine({ start = c, endpos = c + down * ext, ignoreworld = true, filter = function(x) return x == hull end })
					-- (one that came down on an edge or a corner topples over first: held at once, a thrown crate stood on its
					-- corner until the ship parked - odd_throw. What cannot lie flat - a barrel on its side - is held after a
					-- second and a half.)
					if tr.Hit and not tr.StartSolid then
						local up = newAng:Up()
						local flat = math.max(math.abs(na:Forward():Dot(up)), math.abs(na:Right():Dot(up)), math.abs(na:Up():Dot(up))) > 0.97
						if flat then e.SGToppleAt = nil
						else
							e.SGToppleAt = e.SGToppleAt or CurTime()
							topple = CurTime() - e.SGToppleAt < 1.5
						end
					else e.SGToppleAt = nil end
					if tr.Hit and not tr.StartSolid and not topple then
						lv = Vector(0, 0, math.min(lv.z, 0))
						p:SetAngleVelocity(vector_origin)
						-- (and it keeps its spot on the deck: a hair's creep each step added up to the walls)
						local d = e.SGDeckLP
						if d and (lp.x - d.x) ^ 2 + (lp.y - d.y) ^ 2 < 4 then
							lp = Vector(d.x, d.y, lp.z)
							np = LocalToWorld(lp, la, newPos, newAng)
						end
						held = lp
					end
				end
				e.SGDeckLP = held
				-- (a hoverball holds the height in the world it was set to: in a climbing or diving ship it floated up to 582
				-- units off its spot - its height goes up and down with the ship)
				if e:GetClass() == "gmod_hoverball" and e.SetTargetZ then e:SetTargetZ(e:GetTargetZ() + np.z - p:GetPos().z) end
				stepTo(e, np, na)
				p:SetPos(np, true)
				p:SetAngles(na)
				e.SGCarryAt, e.SGCarryTick, e.SGCarryHull = np, tick, newPos
				-- Lying still on the deck it stays (a crate in the hangar "slowly gliding over the ships deck, if i push
				-- it its gliding more"). Put somewhere new each step, the game forgets that it rests on the floor and its
				-- grip is gone - so a slow thing that does not fall loses its sliding here.
				if not topple and math.abs(lv.z) < 8 and lv.x * lv.x + lv.y * lv.y < 40 * 40 then
					lv = Vector(lv.x * 0.6, lv.y * 0.6, lv.z)
					p:SetAngleVelocity(p:GetAngleVelocity() * 0.6)
				end
				p:SetVelocity(LocalToWorld(lv, angle_zero, vector_origin, newAng))
				e.SGCarryLV = lv
				-- (a second still on the deck and nobody near: at rest)
				if held and not e.AGPRideWith and not e.AGPReplicator and not e:IsPlayerHolding() and not IsValid(e:GetParent()) then
					e.SGRestAt = e.SGRestAt or tick
					if tick - e.SGRestAt > 66 and (tick + e:EntIndex()) % 8 == 0 and not someoneNear(e) then
						resting[e] = { hull = hull, lp = lp, la = la, tick = tick }
						p:EnableMotion(false)
					end
				else e.SGRestAt = nil end
			end
		end
	end
	-- out of the ship since the last step: it keeps the ship's speed
	for e, h in pairs(carried) do
		if h == hull and not inside[e] then
			carried[e] = nil
			local far = IsValid(e) and jumped(e)
			if IsValid(e) then
				e.SGCarryAt, e.SGCarryGood, e.SGLetOutAt = nil, nil, tick   -- (tests read SGLetOutAt)
				if isPair(e.SGCarryPair) then e.SGCarryPair:Remove() end
				e.SGCarryPair, e.SGCarryPairOf = nil, nil
			end
			local p = IsValid(e) and e:GetPhysicsObject()
			if IsValid(p) and vship and not far then p:AddVelocity(vship) end
		end
	end
end

-- A hit never makes a ship faster (faster with every bounce off the map's edge; sitting down in a ship built on uneven
-- ground shot it into the air). The keel's blocks are boxes round the parts; pushed into the map (flying into a
-- wall, Ctrl held on the ground, a block corner in a step of the ground when it is let go) the physics pushed them
-- out at any speed. So after each step the keel's speed may grow only as much as flying or falling can make it grow
-- in a step; more than that is cut back (the way it goes stays). Not while held with the physgun or when the ship is
-- destroyed.
local GROW_SPEED = 4000   -- units per second, per second (StarCore's acceleration, boost and gravity stay far below)
local GROW_SPIN = 720     -- degrees per second, per second
local function speedGuard(hull, k, kp)
	if not kp:IsMotionEnabled() then
		k.SGLastV, k.SGLastW = vector_origin, vector_origin   -- (frozen = at rest: let go, it starts from nothing)
		return
	end
	-- (a docked ship is kept on its place in the carrier, a ship in a Stargate's wormhole is held by the gate:
	-- StarCore and AGP move those)
	local core = hull.SGCore
	if not IsValid(core) then
		if (hull.SGCoreLook or 0) < CurTime() then
			hull.SGCoreLook = CurTime() + 1
			hull.SGCoreCache = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull) or nil
		end
		core = hull.SGCoreCache
	end
	if hull.SGHeldBy or hull.SGWreck or k.AGPRideWith or hull.AGPRideWith or (IsValid(core) and (core.DockedTo or core.AGPRideWith)) then
		k.SGLastV, k.SGLastW = nil, nil
		return
	end
	local dt = engine.TickInterval()
	local v, w = kp:GetVelocity(), kp:GetAngleVelocity()
	local lv, lw = k.SGLastV, k.SGLastW
	if lv then
		local most = lv:Length() + GROW_SPEED * dt + 20
		local s = v:Length()
		if s > most then
			v = v * (most / s)
			kp:SetVelocity(v)
			k.SGCutBack = (k.SGCutBack or 0) + 1   -- (tests read it)
		end
	end
	if lw then
		local most = lw:Length() + GROW_SPIN * dt + 5
		local s = w:Length()
		if s > most then
			w = w * (most / s)
			kp:AddAngleVelocity(w - kp:GetAngleVelocity())
			k.SGCutBack = (k.SGCutBack or 0) + 1
		end
	end
	k.SGLastV, k.SGLastW = v, w
end

local function turned(a, b)
	return math.abs(math.AngleDifference(a.p, b.p)) > 0.02 or math.abs(math.AngleDifference(a.y, b.y)) > 0.02
		or math.abs(math.AngleDifference(a.r, b.r)) > 0.02
end
-- People a ship hits. The hull is put somewhere new every step, so the game's own physics never counts a hit by it. Who
-- has gone through the hull's real shape since the last step - seen from the ship, so whoever stands or walks aboard is
-- not hit - is hit with that speed: 300 units a second and slower only pushes, from about 500 on it kills.
--
local BIG = 250   -- (a thing this big stands like a building, also when it is not frozen)
local HIT_FROM = 300
local function hitPeople(hull, k, kp)
	local mn, mx = hull.SGMins, hull.SGMaxs
	local v = kp:GetVelocity()
	local at = k.SGPeople or {}
	local now = {}
	k.SGPeople = now
	if not mn or v:LengthSqr() < 200 * 200 then return end
	local dt = engine.TickInterval()
	local mid, rad = hull:LocalToWorld((mn + mx) / 2), (mx - mn):Length() / 2 + 200
	for _, e in ipairs(ents.FindInSphere(mid, rad)) do
		if (e:IsPlayer() and e:Alive() and not e:InVehicle() and e:GetMoveType() ~= MOVETYPE_NOCLIP) or (e:IsNPC() and e:Health() > 0) or (e.IsNextBot and e:IsNextBot()) then
			-- (who is held for a gate ride is let out on the spot of the ship: not hit by it on the way - scene_nest)
			if not IsValid(e:GetParent()) and not (e.SGGateHeld or e.AGPRideWith or e.StarCoreGateHeld or (e.SGNoHit or 0) > CurTime()) then
				local c = e:WorldSpaceCenter()
				local lc = hull:WorldToLocal(c)
				now[e] = lc
				-- (who stood on this ship's deck a moment ago is aboard: its own walls do not hit)
				if e:GetGroundEntity() == hull and not (e.SGAboard and (e.SGAboard.ride or 0) > CurTime()) then e.SGAboard = { hull = hull, tick = engine.TickCount() } end
				local ab = e.SGAboard
				-- (cut in two: who stood in the other half a moment ago is not hit by this one)
				if ab and ab.hull ~= hull and k.SGApart and IsValid(ab.hull) and k.SGApart[ab.hull] and engine.TickCount() - ab.tick < 200 then now[e] = nil continue end
				local aboard = ab and ab.hull == hull and engine.TickCount() - ab.tick < 40
				local last = at[e]
				local rel = last and lc:Distance(last) / dt or 0
				if last and rel > 150 and rel < 8000 and (e.SGHitAt or 0) < CurTime() then
					local a, b = e:OBBMins() * 0.8, e:OBBMaxs() * 0.8
					local off = c - e:GetPos()
					local tr = util.TraceHull({ start = hull:LocalToWorld(last), endpos = c, mins = a - off * 0.8, maxs = b - off * 0.8, ignoreworld = true, filter = function(x) return x == hull end })
					if tr.Hit and not tr.StartSolid and enclosed(hull, hull:LocalToWorld(last)) then
						-- (in the closed ship until now, not in its way: left behind for a step, e.g. as it came out of a gate - back
						-- in, not hit; scene_nest in a hosted game. Players are kept by StarCore's walking, sh_walk.lua: not hit either)
						if not e:IsPlayer() then
							local np = e:GetPos() + hull:LocalToWorld(last) - c
							local p = e:GetPhysicsObject()
							e:SetLocalPos(np)
							if IsValid(p) then p:SetPos(np, true) end
							now[e] = last
							hull.SGCarryBack = (hull.SGCarryBack or 0) + 1
							hull.SGPeopleBack = (hull.SGPeopleBack or 0) + 1   -- (tests read it)
						end
					elseif tr.Hit and not tr.StartSolid and not aboard then
						e.SGHitAt = CurTime() + 0.5
						local push = v * 0.6 + Vector(0, 0, math.min(v:Length() * 0.2, 250))
						if e:IsPlayer() then e:SetVelocity(push - e:GetVelocity()) else e:SetVelocity(push) end
						if rel > HIT_FROM then
							local d = DamageInfo()
							d:SetDamage((rel - HIT_FROM) * 0.6)
							d:SetDamageType(DMG_VEHICLE)
							local core = hull.SGCore
							local seat = IsValid(core) and core.PilotSeat
							local pilot = IsValid(seat) and seat:GetDriver()
							d:SetAttacker(IsValid(pilot) and pilot or hull)
							d:SetInflictor(hull)
							d:SetDamageForce(v * 60)
							d:SetDamagePosition(tr.HitPos)
							e:TakeDamageInfo(d)
							k.SGPeopleHit = (k.SGPeopleHit or 0) + 1   -- (tests read it)
						end
					end
				end
			end
		end
	end
end

-- Loose things before a flying ship: the hull is put somewhere new each step, and a small thing can be on its other side
-- before the physics sees it. What went through the hull since the last step - seen from the ship, what lies in it does
-- not - is put back before it and goes along with the ship.
--
local function hitThings(hull, k, kp)
	local mn, mx = hull.SGMins, hull.SGMaxs
	local v = kp:GetVelocity()
	local at = k.SGLoose or {}
	local now = {}
	k.SGLoose = now
	if not mn or v:LengthSqr() < 60 * 60 then return end
	local core = hull.SGCore
	local partOf = StarCore and StarCore.PartCore or {}
	for _, e in ipairs(ents.FindInSphere(hull:LocalToWorld((mn + mx) / 2), (mx - mn):Length() / 2 + 200)) do
		local p = e:GetPhysicsObject()
		if IsValid(p) and p:IsMotionEnabled() and e:GetMoveType() == MOVETYPE_VPHYSICS and e:GetSolid() == SOLID_VPHYSICS and not e:IsPlayer() and not e:IsNPC()
			and carried[e] ~= hull and not e.SGRiderOf and not e.SpaceGridHull and not e.SpaceGridKeel and not IsValid(e:GetParent()) and not e.AGPReplicator and not e.SGNoCarry
			and not e:IsPlayerHolding() and e:GetClass() ~= "starcore" and e:BoundingRadius() < BIG and p:GetVelocity():LengthSqr() < 500 * 500
			and not (IsValid(core) and partOf[e] == core) then
			local c = p:LocalToWorld(p:GetMassCenter())
			local lc = hull:WorldToLocal(c)
			now[e] = lc
			local last = at[e]
			if last and last:DistToSqr(lc) > 1 and last:DistToSqr(lc) < 150 * 150 then
				local o = e:OBBMaxs() - e:OBBMins()
				local b = math.Clamp(math.min(o.x, o.y, o.z) * 0.42, 1, 80)
				local tr = util.TraceHull({ start = hull:LocalToWorld(last), endpos = c, mins = Vector(-b, -b, -b), maxs = Vector(b, b, b), ignoreworld = true, filter = function(x) return x == hull end })
				if tr.Hit and not tr.StartSolid then
					p:SetPos(p:GetPos() + (tr.HitPos + tr.HitNormal - c), true)
					local pv = p:GetVelocity()
					local want, have = v:Dot(tr.HitNormal) + 60, pv:Dot(tr.HitNormal)
					if have < want then pv = pv + tr.HitNormal * (want - have) end
					p:SetVelocity(pv)
					now[e] = hull:WorldToLocal(p:LocalToWorld(p:GetMassCenter()))
					k.SGThingsHit = (k.SGThingsHit or 0) + 1   -- (tests read it)
				end
			end
		end
	end
end

hook.Add("Tick", "SpaceGrid.KeelFollow", function()
	local now = CurTime()
	for hull in pairs(keeled) do
		local k = IsValid(hull) and hull.SGKeel
		if not IsValid(k) then
			keeled[hull] = nil
			for e in pairs(IsValid(hull) and hull.SGRiders or {}) do if IsValid(e) then letGo(e, hull) end end
		else
			local kp, hp = k:GetPhysicsObject(), hull:GetPhysicsObject()
			if IsValid(kp) and (k.SGHolds or 0) > 0 and kp:IsMotionEnabled() then
				-- (held: something unfroze it meanwhile - StarCore's helm. It moves once let go.)
				k.SGWant = { vel = kp:GetVelocity() }
				kp:EnableMotion(false)
			end
			if IsValid(kp) then
				speedGuard(hull, k, kp)
				-- (another ship's shut door or field is a wall for this ship: sv_doors.lua)
				if kp:IsMotionEnabled() and not hull.SGHeldBy and SpaceGrid.SheetWall then SpaceGrid.SheetWall(hull, k, kp) end
				if kp:IsMotionEnabled() and not hull.SGHeldBy and not k.AGPRideWith and SpaceGrid.ShieldWall then SpaceGrid.ShieldWall(hull, k, kp) end
				-- A frozen keel touches nothing (things spawned inside a ship fell through its floor). The game asks the "keel
				-- touches only the map and other ships" rule (ShouldCollide, below) only about moving bodies: a parked
				-- ship's frozen keel - boxes round whole rooms - pushed a crate spawned in a room out through the floor.
				-- Frozen, the ship one sees (the frozen hull) is all that is needed.
				local coll = kp:IsMotionEnabled()
				if k.SGColl ~= coll then
					k.SGColl = coll
					kp:EnableCollisions(coll)
					-- (let go: what reaches into it now is let out first)
					if coll and not hull.SGHeldBy then SpaceGrid.LyingIn(hull, true) end
					hull.SGShipsLook = 0
					hull.SGRidersAt = 0   -- (and what is fixed in it is stowed, or let go)
				end
			end
			-- (jumped - hyperspace, a gate: what is stowed and parked in it goes along first, then it is looked what is in it; the
			-- other way round it was no longer in the ship and stayed behind, now and then - scene_nest on a server)
			if hull.SGStowPos and hull:GetPos():DistToSqr(hull.SGStowPos) > 256 * 256 then
				if hull.SGRiders and next(hull.SGRiders) then placeRiders(hull, hull:GetPos(), hull:GetAngles()) hull.SGRidePos, hull.SGRideAng = hull:GetPos(), hull:GetAngles() end
				if hull.SGStowShips then placeShips(hull) hull.SGShipsPos, hull.SGShipsAng = hull:GetPos(), hull:GetAngles() end
			end
			hull.SGStowPos = hull:GetPos()
			if (hull.SGRidersAt or 0) < now then SpaceGrid.Riders(hull) end
			-- (a ship parked in this one freezes its core at once: looked at more often)
			if (hull.SGShipsLook or 0) < now and IsValid(kp) and kp:IsMotionEnabled() then hull.SGShipsLook = now + 0.1 SpaceGrid.StowShips(hull) end
			-- (a smaller ship flying in it: every step, never through its walls)
			if IsValid(kp) and kp:IsMotionEnabled() and hull.SGMins and not hull.SGAlong then SpaceGrid.GuardInner(hull, k, kp) end
			if IsValid(kp) and IsValid(hp) then
				local kpos, kang = kp:GetPos(), kp:GetAngles()
				local hpos, hang = hull:GetPos(), hull:GetAngles()
				if hull.SGHeldBy then
					place(k, kp, hpos, hang)
					kp:SetVelocity(hp:GetVelocity())
				elseif hp:IsMotionEnabled() then
					-- (safety net) something else unfroze the ship one sees (another addon, a wire chip, an admin tool):
					-- frozen again at once, its motion goes to the keel - as one moving body it could crash the game
					local v = hp:GetVelocity()
					hp:EnableMotion(false)
					place(k, kp, hpos, hang)
					kp:EnableMotion(true)
					kp:SetVelocity(v)
					kp:Wake()
				elseif hull.SGPutAt and hpos:DistToSqr(hull.SGPutAt) > 16 and kpos:DistToSqr(hull.SGKeelAt or kpos) < 1 then
					-- the hull was moved by something else, the keel stood: the keel goes to the hull
					place(k, kp, hpos, hang)
				elseif hpos:DistToSqr(kpos) > 0.0025 or turned(hang, kang) then
					-- (a hovering ship's keel trembles by hundredths of a unit; following that every step put the ship
					-- and what lies in it somewhere new each step - loose things lost their grip on the deck and slid.
					-- Now the ship follows once the keel is 0.05 units or 0.02 degrees away.) (a big jump
					-- - a teleport, a paste - carries nothing: what lies in the ship goes with the ship's own teleport
					-- code, StarCore's jump, or stays)
					if hpos:DistToSqr(kpos) < 512 * 512 then carry(hull, k, hpos, hang, kpos, kang, kp:GetVelocity()) end
					place(hull, hp, kpos, kang)
				end
				hull.SGPutAt, hull.SGKeelAt = hull:GetPos(), kp:GetPos()
				if kp:IsMotionEnabled() and not hull.SGHeldBy and not k.AGPRideWith then hitPeople(hull, k, kp) hitThings(hull, k, kp) else k.SGPeople, k.SGLoose = nil, nil end
				if hull.SGStowShips and (hull.SGShipsPos ~= hull:GetPos() or hull.SGShipsAng ~= hull:GetAngles()) then hull.SGShipsPos, hull.SGShipsAng = hull:GetPos(), hull:GetAngles() placeShips(hull) end
				-- what is welded on goes with the hull, wherever it went this step (sv_keel.lua's riders above)
				if hull.SGRiders and next(hull.SGRiders) then
					local pos, ang = hull:GetPos(), hull:GetAngles()
					if hull.SGRidePos ~= pos or hull.SGRideAng ~= ang or hull.SGRidersNew then
						hull.SGRidePos, hull.SGRideAng, hull.SGRidersNew = pos, ang, nil
						placeRiders(hull, pos, ang)
					end
				end
			end
		end
	end
end)

-- What a keel touches: the map, other ships and every solid thing that stands fixed and is not part of its own ship
-- (before, the map and other ships, then ramps and DHDs one by one). Loose things meet the hull itself, which has the
-- ship's real shape: the keel's blocks fill the rooms and would shut a hangar to them. Not touched: what rides or lies in
-- the ship, the crew and other living things, a gate's horizon, shield bubbles (their own rules), and near an open gate
-- its ring and ramp.
local PASS = { event_horizon = true, kawoosh_hurt = true, shield = true, ship_shield = true, spacegrid_door = true, spacegrid_field = true }
local function rootOf(e)
	for _ = 1, 6 do
		local p = e:GetParent()
		if not IsValid(p) then return e end
		e = p
	end
	return e
end
local function keelMeets(k, o)
	local hull = k.SGHull
	if not IsValid(hull) then return false end
	if o:IsPlayer() or o:IsNPC() or (o.IsNextBot and o:IsNextBot()) or o:IsWeapon() or o:IsRagdoll() or PASS[o:GetClass()] then return false end
	if not o:IsSolid() or bit.band(o:GetSolidFlags(), FSOLID_TRIGGER) > 0 then return false end
	-- its own ship: riders, what it carries, what hangs on it, the parts StarCore counts to it
	if o.SGRiderOf == hull or carried[o] == hull or o == hull then return false end
	local r = rootOf(o)
	if o:GetClass() == "shield_core_buble" then
		-- (a shield core's bubble has a real shape and a rule of its own, who may pass: not asked here - but never its own ship)
		if r == hull or r.SGRiderOf == hull or (IsValid(o.Parent) and o.Parent.SGRiderOf == hull) or (hull.SGMins and hull:WorldToLocal(o:GetPos()):WithinAABox(hull.SGMins, hull.SGMaxs)) then return false end
		return nil
	end
	if r == hull or r == k or r.SGRiderOf == hull then return false end
	local core = hull.SGCore
	if IsValid(core) and StarCore and StarCore.PartCore and (StarCore.PartCore[o] == core or StarCore.PartCore[r] == core) then return false end
	if r.SpaceGridHull then return false end   -- (a door, seat or device of another ship: that hull is met itself)
	-- what stands in the ship (asked when the two come near each other: what was outside then is met)
	if middleIn(hull, o) then return false end
	-- (a Stargate's ring never stops a ship, open or shut: the keel's blocks are coarser than the ship one sees, and a cockpit
	-- that just fits would catch on it)
	if o.IsStargate or r.IsStargate then return false end
	if o.IsRamp and k.SGRampFree then return false end
	local p = o:GetPhysicsObject()
	local mt, so = o:GetMoveType(), o:GetSolid()
	local still = mt == MOVETYPE_NONE or mt == MOVETYPE_PUSH
	-- (a thing without a body that stands: a door, a prop of the map. Not a shot in flight - it meets the hull.)
	local fixed
	if IsValid(p) then fixed = not p:IsMotionEnabled() or still else fixed = still and (so == SOLID_VPHYSICS or so == SOLID_BSP) end
	return fixed or (o:BoundingRadius() > BIG and not o:IsVehicle())
end
SpaceGrid.KeelMeets = keelMeets
hook.Add("ShouldCollide", "SpaceGrid.Keel", function(a, b)
	local k, o
	if a.SpaceGridKeel then k, o = a, b elseif b.SpaceGridKeel then k, o = b, a else return end
	if o:IsWorld() then return true end
	-- (docked in a bigger ship with StarCore: it does not touch that ship - StarCore's own rule, sv_dock.lua)
	if (k.StarCoreDockOn and k.StarCoreDockOn[o]) or (o.StarCoreDockOn and o.StarCoreDockOn[k]) then return false end
	if o.SpaceGridKeel then return false end
	if o.SpaceGridHull then return o ~= k.SGHull end
	if string.StartWith(o:GetClass(), "func_") then return true end
	return keelMeets(k, o)
end)

-- Ramps and open gates (the owner's second play test on freespace13: no cockpit got into a gate that stands on a ramp, and
-- out of "Spawn" one came out in the ramp, one in the hall under the map's floor). A ramp reaches up to a few dozen units
-- under its gate's middle - a ship that fits through the gate did not fit over the ramp, and out of the gate its body was
-- in the ramp and the physics pushed it out any way, also down through the floor. So near an open gate a ship passes
-- its ramp, and goes on passing it until it is out of it.
local gates, around = {}, {}   -- (around: what a ship passes near an open gate - rings and ramps)
timer.Create("SpaceGrid.GateThings", 2, 0, function()
	gates, around = {}, {}
	if not next(keeled) then return end
	for _, e in ipairs(ents.GetAll()) do
		if e.IsStargate then gates[#gates + 1] = e end
		if e.IsStargate or e.IsRamp then around[#around + 1] = e end
	end
end)
local function worldBox(hull)
	local mn, mx = hull.SGMins, hull.SGMaxs
	local a, b = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for n = 0, 7 do
		local c = hull:LocalToWorld(Vector(bit.band(n, 1) > 0 and mx.x or mn.x, bit.band(n, 2) > 0 and mx.y or mn.y, bit.band(n, 4) > 0 and mx.z or mn.z))
		a = Vector(math.min(a.x, c.x), math.min(a.y, c.y), math.min(a.z, c.z))
		b = Vector(math.max(b.x, c.x), math.max(b.y, c.y), math.max(b.z, c.z))
	end
	return a, b
end
timer.Create("SpaceGrid.RampFree", 0.1, 0, function()
	if #gates == 0 then return end
	for hull in pairs(keeled) do
		local k = IsValid(hull) and hull.SGMins and hull.SGKeel
		if IsValid(k) then
			local a, b = worldBox(hull)
			local free = false
			for _, r in ipairs(k.SGRampFree and around or {}) do
				if IsValid(r) and r:GetPos():DistToSqr((a + b) / 2) < (2000 + (b - a):Length()) ^ 2 then
					if k.SGRampFree then
						local lo, hi = r:WorldSpaceAABB()
						if a.x < hi.x and b.x > lo.x and a.y < hi.y and b.y > lo.y and a.z < hi.z and b.z > lo.z then free = true break end
					end
				end
			end
			if not free then
				local mid, rad = (a + b) / 2, (b - a):Length() / 2 + 900
				for _, g in ipairs(gates) do if IsValid(g) and g.IsOpen and g:GetPos():DistToSqr(mid) < rad * rad then free = true break end end
			end
			free = free or nil
			if k.SGRampFree ~= free then
				k.SGRampFree = free
				k:CollisionRulesChanged()
			end
		end
	end
end)

-- A ship that comes out of a gate stands clear in front of it (and later the hall under Spawn): its rear out of the gate,
-- its bottom over the floor and the ramp there. A body that came out in the floor was pushed on down by the physics. All of
-- it moves: hull, keel, what is welded to the keel, who stands in it.
local function shiftShip(hull, k, delta)
	local done = { [hull] = true, [k] = true }
	for e in pairs(constraint.GetAllConstrainedEntities(k) or {}) do
		if IsValid(e) and not done[e] and not e.SGRiderOf and not e:IsWorld() and not IsValid(e:GetParent()) then
			done[e] = true
			e:SetPos(e:GetPos() + delta)
			local p = e:GetPhysicsObject()
			if IsValid(p) then p:SetPos(p:GetPos() + delta) end
		end
	end
	for _, ply in ipairs(player.GetAll()) do
		if not ply:InVehicle() and hull:WorldToLocal(ply:GetPos() + Vector(0, 0, 8)):WithinAABox(hull.SGMins, hull.SGMaxs) then ply:SetPos(ply:GetPos() + delta) end
	end
	SpaceGrid.TeleportShip(hull, hull:GetPos() + delta, hull:GetAngles())
	-- (the ships docked in it: nothing holds them to it)
	local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
	for _, d in ipairs(IsValid(core) and StarCore and StarCore.DockedShips and StarCore.DockedShips(core) or {}) do
		for _, p in ipairs(d.OwnParts or d.Parts or {}) do
			if IsValid(p) and not done[p] and not p.SGRiderOf and not IsValid(p:GetParent()) then
				done[p] = true
				if p.SpaceGridHull then
					if IsValid(p.SGKeel) then done[p.SGKeel] = true end
					SpaceGrid.TeleportShip(p, p:GetPos() + delta, p:GetAngles())
				elseif not p.SpaceGridKeel then
					p:SetPos(p:GetPos() + delta)
					local pp = p:GetPhysicsObject()
					if IsValid(pp) then pp:SetPos(pp:GetPos() + delta) end
				end
			end
		end
		if not done[d] then done[d] = true d:SetPos(d:GetPos() + delta) local pp = d:GetPhysicsObject() if IsValid(pp) then pp:SetPos(pp:GetPos() + delta) end end
	end
end
local function standOut(hull, k)
	local g, f = hull.SGGateTo, hull.SGGateF
	local half, mid = (hull.SGMaxs - hull.SGMins) / 2, hull:LocalToWorld((hull.SGMaxs + hull.SGMins) / 2)
	local function reach(d) return math.abs(hull:GetForward():Dot(d)) * half.x + math.abs(hull:GetRight():Dot(d)) * half.y + math.abs(hull:GetUp():Dot(d)) * half.z end
	local up = Vector(0, 0, 1)
	local want = Vector(mid)
	if IsValid(g) and f then
		local rf = reach(f)
		local d = (mid - g:GetPos()):Dot(f)
		if d < rf + 24 then
			-- (as far as there is room in front of the gate)
			local tr = util.TraceLine({ start = mid, endpos = mid + f * (rf + 24 - d + rf), mask = MASK_SOLID_BRUSHONLY })
			local room = tr.Hit and not tr.StartSolid and (tr.HitPos - mid):Dot(f) - rf or math.huge
			want = want + f * math.Clamp(rf + 24 - d, 0, math.max(0, room))
		end
	end
	local fl = f and Vector(f.x, f.y, 0):GetNormalized() or hull:GetForward()
	local side = fl:Cross(up)
	local ru, rf, rs = reach(up), reach(fl) * 0.85, reach(side) * 0.85
	local function standsOn(e) return e.IsRamp == true or (not e.IsStargate and keelMeets(k, e)) end
	local lift = 0
	for _, o in ipairs({ { 0, 0 }, { rf, rs }, { rf, -rs }, { -rf, rs }, { -rf, -rs }, { rf, 0 }, { -rf, 0 } }) do
		local c = want + fl * o[1] + side * o[2]
		local tr = util.TraceLine({ start = c, endpos = c - up * ru, mask = MASK_SOLID, filter = standsOn })
		if tr.StartSolid then
			-- (its middle is in the floor there: looked at from its top)
			tr = util.TraceLine({ start = c + up * ru, endpos = c - up * ru, mask = MASK_SOLID, filter = standsOn })
		end
		if tr.Hit and not tr.StartSolid then lift = math.max(lift, tr.HitPos.z - (c.z - ru)) end
	end
	if lift > 0.5 then want = want + up * (lift + 4) end
	local delta = want - mid
	if delta:LengthSqr() > 1 then
		shiftShip(hull, k, delta)
		k.SGLifted, k.SGOutMoved = delta.z > 0.5 and delta.z or nil, delta   -- (tests read it)
	end
end
-- What lies loose in a ship and who stands in it goes through the gate with it (the gate took the ship's own parts; a
-- crate in it flew on into the gate by itself and came out under the ship, whoever stood in it was left behind). While the
-- ship is in the wormhole they are held - not seen, not solid; people see the tunnel too - and then they are in the ship
-- where they were.
local function tunnel(ply, on)
	if util.NetworkStringToID("AGP.WormholeRide") == 0 or (on and ply:GetInfoNum("cl_stargate_wormhole", 1) == 0) then return end
	ply.AGPRideView = on or nil   -- (AGP takes it off when he dies)
	net.Start("AGP.WormholeRide")
	net.WriteBool(on)
	net.Send(ply)
end
local function letOut(hull, st, place)
	local e = st.e
	if not IsValid(e) then return end
	if e.AGPRideWith == hull then e.AGPRideWith = nil end
	e.SGGateHeld = nil
	e.SGNoHit = CurTime() + 2   -- (its ship settles after the ride: a docked one is put on its place in the carrier - not hit by it)
	if st.ship then
		e:SetRenderMode(st.mode)
		e:SetColor(st.color)
		if not st.notSolid then e:SetNotSolid(false) end
		return
	end
	if st.stow then
		for _, v in ipairs(st.hidden) do if IsValid(v[1]) then v[1]:SetNoDraw(v[2]) if not v[3] then v[1]:SetNotSolid(false) end end end
		return
	end
	if not st.notSolid then e:SetNotSolid(false) end
	e:SetNoDraw(st.noDraw)
	local np, na
	if place and IsValid(hull) then np, na = LocalToWorld(st.lp, st.la, hull:GetPos(), hull:GetAngles()) end
	if e:IsPlayer() then
		if st.tunnel then tunnel(e, false) end
		if not st.god then e:GodDisable() end
		e:Freeze(st.frozen)
		if e:Alive() and e:Deaths() == st.deaths and not e:InVehicle() then
			e:SetMoveType(st.move)
			if np then
				e:SetPos(np)
				e:SetEyeAngles(Angle(st.eye.p, st.eye.y + math.AngleDifference(hull:GetAngles().y, st.yaw), 0))
			end
			e:SetLocalVelocity(vector_origin)
			if np then e:SetGroundEntity(hull) end
		end
		return
	end
	if e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then
		e:SetMoveType(st.move)
		if np then
			e:SetPos(np)
			e:SetAngles(Angle(0, na.y, 0))
			e:SetGroundEntity(hull)
			e.SGAboard = { hull = hull, tick = engine.TickCount(), ride = CurTime() + 2 }
		end
		return
	end
	local p = e:GetPhysicsObject()
	if np and e:IsVehicle() and e.SGCarAt and e:GetPhysicsObjectCount() > 1 then
		carPut(e, e.SGCarAt, np, na)
	elseif np then
		e:SetPos(np)
		e:SetAngles(na)
		if IsValid(p) and not e:IsVehicle() then p:SetPos(np, true) p:SetAngles(na) end
	end
	e.SGCarBodies = nil   -- (all its bodies are free after this; the ship takes it again)
	for i = 0, e:GetPhysicsObjectCount() - 1 do
		local b = e:GetPhysicsObjectNum(i)
		if IsValid(b) then
			local at = np and st.bodies and st.bodies[i]
			if at then
				local bp, ba = LocalToWorld(at[1], at[2], hull:GetPos(), hull:GetAngles())
				b:SetPos(bp, true)
				b:SetAngles(ba)
			end
			b:EnableMotion(true)
			b:SetVelocity(vector_origin)
			b:SetAngleVelocity(vector_origin)
			b:Wake()
		end
	end
	if IsValid(st.driver) then
		st.driver:SetNoDraw(false)
		if st.tunnel then tunnel(st.driver, false) end
	end
	e.SGCarryAt, e.SGDeckLP, e.SGCarryLV, e.SGCarryGood = nil, nil, nil, nil
end
local function allOut(hull, place)
	for _, st in ipairs(hull.SGAlong or {}) do letOut(hull, st, place) end
	hull.SGAlong = nil
end
-- (in the ship, not only in the box round it - beside a narrow part, under an overhang: it stands on its deck, is carried
-- along, or has its deck under it)
local function onDeck(e, hull)
	if e:GetGroundEntity() == hull or carried[e] == hull then return true end
	local ab = e.SGAboard
	if ab and ab.hull == hull and engine.TickCount() - ab.tick < 60 then return true end
	local c = e:WorldSpaceCenter()
	local tr = util.TraceLine({ start = c, endpos = c - hull:GetUp() * 220, ignoreworld = true, filter = function(x) return x == hull end })
	return tr.Hit and not tr.StartSolid
end
local function holdAlong(hull, k)
	local mn, mx = hull.SGMins, hull.SGMaxs
	if hull.SGAlong or not mn then return end
	local list = {}
	hull.SGAlong = list
	local mid, rad = hull:LocalToWorld((mn + mx) / 2), (mx - mn):Length() / 2 + 60
	for _, e in ipairs(ents.FindInSphere(mid, rad)) do
		local person = (e:IsPlayer() and e:Alive() and not e:InVehicle() and e:GetMoveType() ~= MOVETYPE_NOCLIP and not e.AGPRide)
			or (e:IsNPC() and e:Health() > 0) or (e.IsNextBot and e:IsNextBot())
		local p = e:GetPhysicsObject()
		local sr = hull.SGRiders and hull.SGRiders[e]
		if sr and sr.stow and not e.SGGateHeld then
			-- (stowed: it stays on its place in the ship, only unseen on the way; a gate on board shuts)
			local st = { e = e, stow = true, hidden = {} }
			local function hide(v)
				st.hidden[#st.hidden + 1] = { v, v:GetNoDraw(), bit.band(v:GetSolidFlags(), FSOLID_NOT_SOLID) > 0 }
				v:SetNoDraw(true)
				v:SetNotSolid(true)
				for _, c in ipairs(v:GetChildren()) do hide(c) end
			end
			hide(e)
			e.SGGateHeld = true
			if e.IsStargate and (e.IsOpen or e.Dialling or e.Active) and e.AbortDialling then e:AbortDialling() end
			list[#list + 1] = st
		elseif not e.SGGateHeld and not IsValid(e:GetParent()) and (person or (carryable(e, hull, k) and not e.AGPRideWith)) then
			local at = person and e:GetPos() or p:GetPos()
			local ang = person and Angle(0, e:GetAngles().y, 0) or p:GetAngles()
			local lp, la = WorldToLocal(at, ang, hull:GetPos(), hull:GetAngles())
			local lc = hull:WorldToLocal(e:WorldSpaceCenter())
			if lc.x > mn.x and lc.x < mx.x and lc.y > mn.y and lc.y < mx.y and lc.z > mn.z and lc.z < mx.z + 48 and onDeck(e, hull) then
				local st = { e = e, lp = lp, la = la, noDraw = e:GetNoDraw(), notSolid = bit.band(e:GetSolidFlags(), FSOLID_NOT_SOLID) > 0, move = e:GetMoveType() }
				list[#list + 1] = st
				unrest(e)
				if e:IsPlayerHolding() then e:ForcePlayerDrop() end   -- (held by who stands in the ship: it stayed at the first gate)
				e.SGGateHeld, e.AGPRideWith = true, hull
				e:SetNotSolid(true)
				e:SetNoDraw(true)
				if e:IsPlayer() then
					st.god, st.frozen, st.eye, st.yaw, st.deaths = e:HasGodMode(), e:IsFrozen(), e:EyeAngles(), hull:GetAngles().y, e:Deaths()
					e:GodEnable()
					e:Freeze(true)
					e:SetMoveType(MOVETYPE_NONE)
				elseif person then
					e:SetMoveType(MOVETYPE_NONE)
				else
					if manyBodies(e) and not e:IsVehicle() then
						st.bodies = {}
						for i = 0, e:GetPhysicsObjectCount() - 1 do
							local b = e:GetPhysicsObjectNum(i)
							if IsValid(b) then st.bodies[i] = { WorldToLocal(b:GetPos(), b:GetAngles(), hull:GetPos(), hull:GetAngles()) } b:EnableMotion(false) end
						end
					end
					p:EnableMotion(false)
					local d = e:IsVehicle() and e:GetDriver()
					if IsValid(d) then st.driver = d d:SetNoDraw(true) end
				end
			end
		end
	end
	for oh in pairs(hull.SGStowShips or {}) do
		if IsValid(oh) and not oh.SGGateHeld then
			list[#list + 1] = { e = oh, ship = true, mode = oh:GetRenderMode(), color = oh:GetColor(), notSolid = bit.band(oh:GetSolidFlags(), FSOLID_NOT_SOLID) > 0 }
			oh.SGGateHeld = true
			oh:SetRenderMode(RENDERMODE_TRANSALPHA)
			oh:SetColor(Color(0, 0, 0, 0))
			oh:SetNotSolid(true)
		end
	end
	-- (the tunnel only when there is a ride; the ship's own riders see it the same moment)
	timer.Simple(0, function()
		if not (IsValid(hull) and IsValid(k) and (k.AGPRideWith or hull.AGPRideWith)) then return end
		for _, st in ipairs(hull.SGAlong or {}) do
			if IsValid(st.e) and st.e:IsPlayer() then st.tunnel = true tunnel(st.e, true) end
			if IsValid(st.driver) then st.tunnel = true tunnel(st.driver, true) end
		end
	end)
end
-- A ship lost in a gate (a shut iris at the far end, a gate shut off meanwhile): everybody in it is lost with it, seated,
-- standing or held for the ride, and what lies in it. AGP tells it with the hook StarGate.Lost; an undone or cleaned up ship
-- is not lost - who was in it is let go.
local dockedHulls
local loseShip
function loseShip(hull)
	if hull.SGLost then return end
	hull.SGLost = true
	local people = {}
	for _, seat in ipairs(ents.FindByClass("prop_vehicle_*")) do
		local d = seat:GetParent() == hull and seat:GetDriver()
		if IsValid(d) then people[#people + 1] = d end
	end
	local along = hull.SGAlong or {}
	allOut(hull, false)
	for _, st in ipairs(along) do
		local e = st.e
		if IsValid(e) then
			if e:IsPlayer() or e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then people[#people + 1] = e else e:Remove() end
		end
	end
	for _, e in ipairs(people) do
		if e:IsPlayer() then
			if e:InVehicle() then e:ExitVehicle() end
			if e:Alive() and not e:HasGodMode() then e:KillSilent() end
		else
			e:Remove()
		end
	end
	local docked = dockedHulls(hull)
	-- (and what is welded on it: a gun of a lost ship hung in the air at the gate)
	for e in pairs(hull.SGRiders or {}) do if IsValid(e) and not e.IsStargate then e:Remove() end end
	timer.Simple(0, function() if IsValid(hull) then hull:Remove() end end)
	for _, dh in ipairs(docked) do loseShip(dh) end
end
hook.Add("StarGate.Lost", "SpaceGrid.Lost", function(e)
	local hull = IsValid(e) and (e.SpaceGridHull and e or e.SGHull)
	if not IsValid(hull) and IsValid(e) and e:GetClass() == "starcore" then
		for h in pairs(keeled) do if IsValid(h) and h.SGCore == e then hull = h break end end
	end
	if IsValid(hull) and hull.SpaceGridHull then loseShip(hull) end
end)
-- nobody gets out of a car held in the ship while it is in the wormhole (the ship's own seats: AGP, agp_ride.lua)
hook.Add("CanExitVehicle", "SpaceGrid.Gate", function(car) if car.SGGateHeld then return false end end)
-- the ship is gone (a gate's kawoosh, the remover, a cleanup): what was welded on is let go - held still while it rode,
-- it hung in the air where the hull had been (the author's play test). Not when the hull was joined into another ship:
-- its things are moved over and welded on there (sv_hull.lua MergeAt).
hook.Add("EntityRemoved", "SpaceGrid.RidersFree", function(e)
	if not e.SpaceGridHull or IsValid(e.SGMergedInto) or not e.SGRiders then return end
	for o in pairs(e.SGRiders) do if IsValid(o) then letGo(o, e) end end
	e.SGRiders = {}
end)
hook.Add("EntityRemoved", "SpaceGrid.Along", function(e)
	if e.SGAlong then allOut(e, false) end
end)

function dockedHulls(hull)
	local list = {}
	local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
	if not (IsValid(core) and StarCore and StarCore.DockedShips) then return list end
	for _, d in ipairs(StarCore.DockedShips(core)) do
		for _, p in ipairs(d.OwnParts or d.Parts or {}) do
			if IsValid(p) and p.SpaceGridHull and p ~= hull and IsValid(p.SGKeel) then list[#list + 1] = p end
		end
	end
	return list
end
-- is e in a ship that flies through this gate? (what lies or stands far forward in it reaches the horizon before the ship
-- itself goes in; a gate on board is the ship's own)
local function inFlyingShip(e, eh)
	if e.SpaceGridHull or e.SpaceGridKeel or IsValid(e:GetParent()) then return false end
	local rh = e.SGRiderOf
	if IsValid(rh) then return rh.SGRiders ~= nil and rh.SGRiders[e] ~= nil and rh.SGRiders[e].stow == true end
	local g = IsValid(eh) and eh:GetParent()
	local c = e:WorldSpaceCenter()
	for hull in pairs(keeled) do
		local mn, mx = hull.SGMins, hull.SGMaxs
		local k = IsValid(hull) and mn and hull.SGKeel
		local kp = IsValid(k) and k:GetPhysicsObject()
		if IsValid(kp) and kp:IsMotionEnabled() and kp:GetVelocity():LengthSqr() > 20 * 20 and not (k.AGPRideWith or hull.AGPRideWith) then
			local lc = hull:WorldToLocal(c)
			if lc.x > mn.x and lc.x < mx.x and lc.y > mn.y and lc.y < mx.y and lc.z > mn.z and lc.z < mx.z + 24 then
				local own = IsValid(g) and (g.SGRiderOf == hull or (IsValid(hull.SGCore) and StarCore and StarCore.PartCore and StarCore.PartCore[g] == hull.SGCore))
				if not own and constraint.FindConstraint(e, "Weld") == nil and onDeck(e, hull) then return true end
			end
		end
	end
	return false
end
hook.Add("StarGate.Teleport", "SpaceGrid.GateOut", function(e, eh)
	if IsValid(e) and inFlyingShip(e, eh) then return false end
	local hull = IsValid(e) and (e.SpaceGridHull and e or e.SGHull)
	-- (a docked ship goes with its carrier, never by itself: StarCore sv_dock.lua says no too, whichever is asked first)
	if IsValid(hull) and StarCore and StarCore.DockedCoreOf and StarCore.DockedCoreOf(hull) then return false end
	if IsValid(hull) and hull.SpaceGridHull then
		hull.SGGateOut = CurTime() + 15
		local t = IsValid(eh) and eh.Target
		hull.SGGateTo = IsValid(t) and t:GetParent() or nil
		hull.SGGateF = IsValid(t) and t:GetForward() or nil
		if IsValid(hull.SGKeel) and not (hull.SGKeel.AGPRideWith or hull.AGPRideWith) then
			holdAlong(hull, hull.SGKeel)
			-- (and who and what is in the ships docked in it)
			for _, dh in ipairs(dockedHulls(hull)) do holdAlong(dh, dh.SGKeel) end
		end
	end
end)
hook.Add("Tick", "SpaceGrid.GateOut", function()
	for hull in pairs(keeled) do
		local t = IsValid(hull) and hull.SGGateOut
		local k = t and hull.SGKeel
		if t and IsValid(k) and not (k.AGPRideWith or hull.AGPRideWith) and hull:GetColor().a > 0 then
			-- (through: out of the wormhole ride and seen again - or the ride never started)
			if hull.SGGateIn == nil or (hull:GetPos():DistToSqr(hull.SGGateIn) > 250000) then
				hull.SGGateOut, hull.SGGateIn = nil, nil
				hull:SetNWFloat("SGGateCame", CurTime())   -- (cl_gate.lua: it comes out of a gate, it does not stand round one)
				standOut(hull, k)
				allOut(hull, true)
				for _, dh in ipairs(dockedHulls(hull)) do
					dh:SetNWFloat("SGGateCame", CurTime())
					allOut(dh, true)
				end
			end
		elseif t and IsValid(k) and hull.SGGateIn == nil then
			hull.SGGateIn = hull:GetPos()
		end
		if t and CurTime() > t then
			hull.SGGateOut, hull.SGGateIn = nil, nil
			allOut(hull, true)
			for _, dh in ipairs(dockedHulls(hull)) do allOut(dh, true) end
		end
	end
end)

-- the keel takes no damage: an area hit (blast, a gate's kawoosh) finds the hull round it too (spacegrid_keel.lua)
hook.Add("EntityTakeDamage", "SpaceGrid.KeelNoDamage", function(ent, dmg)
	if ent.SpaceGridKeel then return true end
	-- (nor does it crush anybody: it is the body that flies, unseen, its blocks fill the rooms - the ship's hull is what hits
	-- people, hitPeople above. scene_nest on a server: a citizen on the deck was crushed as the ship came out of a gate)
	if dmg and dmg:IsDamageType(DMG_CRUSH) and (ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) then
		local i, a = dmg:GetInflictor(), dmg:GetAttacker()
		if (IsValid(i) and i.SpaceGridKeel) or (IsValid(a) and a.SpaceGridKeel) then return true end
	end
end)

-- The physgun and the freeze / unfreeze keys act on the ship one sees. A small ship may be held: while held its hull
-- moves as one body and the keel follows; let go, the hull is frozen again and the keel takes over with its motion.
-- A bigger ship cannot be held (as one moving body it would crash the game near the map); the keys go to its keel.
local told = setmetatable({}, { __mode = "k" })
hook.Add("PhysgunPickup", "SpaceGrid.Keel", function(ply, ent)
	if not (IsValid(ent) and ent.SpaceGridHull and IsValid(ent.SGKeel)) then return end
	if (ent.SGPieces or 0) <= PHYSGUN_MAX then return end
	if IsValid(ply) and (told[ply] or 0) < CurTime() then
		told[ply] = CurTime() + 4
		SpaceGrid.Say(ply, "say.too_big_physgun", ent.SGPieces, PHYSGUN_MAX)
	end
	return false
end)
hook.Add("OnPhysgunPickup", "SpaceGrid.Keel", function(ply, ent)
	if not (IsValid(ent) and ent.SpaceGridHull and IsValid(ent.SGKeel)) then return end
	ent.SGHeldBy = ply
end)
hook.Add("PhysgunDrop", "SpaceGrid.Keel", function(ply, ent)
	if not (IsValid(ent) and ent.SpaceGridHull and ent.SGHeldBy) then return end
	ent.SGHeldBy = nil
	local kp, hp = SpaceGrid.Body(ent), ent:GetPhysicsObject()
	if IsValid(kp) and IsValid(hp) and kp ~= hp then
		local moving = hp:IsMotionEnabled()
		local v, w = hp:GetVelocity(), hp:GetAngleVelocity()
		place(ent.SGKeel, kp, ent:GetPos(), ent:GetAngles())
		hp:EnableMotion(false)
		kp:EnableMotion(moving)
		if moving then
			kp:SetVelocity(v)
			kp:AddAngleVelocity(w - kp:GetAngleVelocity())
			kp:Wake()
			ent.SGKeel.SGLastV, ent.SGKeel.SGLastW = v, w   -- (thrown with the physgun: that speed is its own)
		end
	end
end)
hook.Add("OnPhysgunFreeze", "SpaceGrid.Keel", function(_, _, ent)
	if not (IsValid(ent) and ent.SpaceGridHull) then return end
	local kp = SpaceGrid.Body(ent)
	if IsValid(kp) and kp ~= ent:GetPhysicsObject() then kp:EnableMotion(false) end
end)
-- unfreeze a ship: its keel and what is fixed to it (StarCore's core - a parked ship has both frozen; the keel alone
-- unfrozen hung on the frozen core in the air). The hull stays a frozen body.
function SpaceGrid.UnfreezeShip(hull)
	local k = IsValid(hull) and hull.SGKeel
	if not IsValid(k) then return end
	for e in pairs(constraint.GetAllConstrainedEntities(k) or { [k] = true }) do
		-- (riders stay frozen: they go with the hull)
		local p = IsValid(e) and e ~= hull and not e.SGRiderOf and not IsValid(e:GetParent()) and e:GetPhysicsObject()
		if IsValid(p) then p:EnableMotion(true); p:Wake() end
	end
	local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
	if IsValid(core) and core.Helm then core.Helm.frozen = false; core:SetNWBool("starcore_frozen", false) end
end
hook.Add("CanPlayerUnfreeze", "SpaceGrid.Keel", function(ply, ent)
	if not (IsValid(ent) and ent.SpaceGridHull and IsValid(ent.SGKeel)) then return end
	if SpaceGrid.TooBig(ent) then return end   -- (sv_hull.lua says no and tells why)
	SpaceGrid.UnfreezeShip(ent)
	return false
end)
-- A prop held with the physgun does not go through a ship's walls (pushing a drone platform against the underside,
-- it went through the hull - "its logic that the hull is fest and not passable for other props"). The hull is a
-- frozen body: the physgun's pull is stronger than the physics' push back, and the hull's walls are thin plates. So
-- every tick the held thing's move is traced against the ships (a box a little smaller than its smallest side, from
-- where it was to where it is): through a wall, it is put back at the wall and loses the speed into it. Open ends and
-- doors that stand open have no wall: it goes through those.
local heldProps = {}
hook.Add("OnPhysgunPickup", "SpaceGrid.NoPushThrough", function(ply, e)
	if IsValid(e) and not (e.SpaceGridHull or e.SpaceGridKeel or e:IsPlayer() or e:IsNPC()) then heldProps[e] = {} end
end)
hook.Add("PhysgunDrop", "SpaceGrid.NoPushThrough", function(ply, e) heldProps[e] = nil end)
local function hitsHull(x) return x.SpaceGridHull == true end
hook.Add("Tick", "SpaceGrid.NoPushThrough", function()
	for e, st in pairs(heldProps) do
		local p = IsValid(e) and e:GetPhysicsObject()
		if not IsValid(p) then
			heldProps[e] = nil
		else
			local mn, mx = e:OBBMins(), e:OBBMaxs()
			local c = e:LocalToWorld((mn + mx) * 0.5)
			local half = math.max(1, math.min(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z) / 2 - 2)
			local box = Vector(half, half, half)
			local from = st.c
			if from and from:DistToSqr(c) > 0.25 then
				local tr = util.TraceHull({ start = from, endpos = c, mins = -box, maxs = box, filter = hitsHull, ignoreworld = true })
				if tr.Hit and not tr.StartSolid and IsValid(tr.Entity) then
					local back = tr.HitPos + tr.HitNormal * 0.5
					local np = e:GetPos() + (back - c)
					e:SetPos(np)
					p:SetPos(np)
					local v = p:GetVelocity()
					local into = v:Dot(tr.HitNormal)
					if into < 0 then p:SetVelocity(v - tr.HitNormal * into) end
					c = back
				end
			end
			st.c = c
		end
	end
end)
