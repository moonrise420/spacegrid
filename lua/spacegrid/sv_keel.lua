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

local keeled = {}   -- hull -> true: the hulls that follow a keel
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
		-- as the old big-ship crash.) A new keel body lies right inside its own hull, and the no-collide link between
		-- the two can only be made a tick later: moving in that tick, the keel's big blocks pushed into hundreds of the
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
	-- body - the keel was pushed out of its own ship and crept away (keelown). The physics' own no-collide link
	-- between the two does it; it names the bodies, so it is made anew with every new body (one tick later, after the
	-- old one is gone). The same for the links to the other half of a cut ship (SpaceGrid.KeelApart).
	for _, c in ipairs(constraint.FindConstraints(k, "NoCollide") or {}) do
		if IsValid(c.Constraint) and (c.Ent1 == hull or c.Ent2 == hull) then c.Constraint:Remove() end
	end
	-- (the links to the riders and to the other half of a cut: both bodies of a pair may be new now)
	for e in pairs(hull.SGRiders or {}) do
		if IsValid(e) and isPair(e.SGKeelPair) then e.SGKeelPair:Remove() end
		if IsValid(e) then e.SGKeelPair = nil end
	end
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
local function letGo(e, hull)
	e.StarCoreFollower = nil
	e.SGRiderOf = nil
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
	for e, r in pairs(hull.SGRiders) do
		if not (IsValid(e) and set[e]) then
			hull.SGRiders[e] = nil
			changed = true
			if IsValid(e) then letGo(e, hull) end
		end
	end
	for e in pairs(set) do
		local r = hull.SGRiders[e]
		if not r and not e.SGHeldBy then
			local p = e:GetPhysicsObject()
			if IsValid(p) then
				local hp, ha = hull:GetPos(), hull:GetAngles()
				local lp, la = WorldToLocal(e:GetPos(), e:GetAngles(), hp, ha)
				-- (was it moving when it came on? let go, it moves again; spawned frozen, it stays frozen)
				e.SGRiderMoved = p:IsMotionEnabled()
				p:EnableMotion(false)
				hull.SGRiders[e] = { lp = lp, la = la, wp = e:GetPos(), wa = e:GetAngles(), hp = hp, ha = ha }
				e.StarCoreFollower = true
				e.SGRiderOf = hull
				-- (frozen, it is never asked about by the keel's "only the map and other ships" rule: welded crates inside
				-- the halls pushed their own ship's keel away -, ptcut. A collision pair keeps them apart.)
				if IsValid(hull.SGKeel) then e.SGKeelPair = apartPair(hull.SGKeel, e) end
				changed = true
			end
		end
	end
	if changed then
		local core = SpaceGrid.CoreOf and SpaceGrid.CoreOf(hull)
		if IsValid(core) and StarCore and StarCore.Scan then StarCore.Scan(core) end
	end
	-- Frozen things lying in a parked ship (a crate frozen with the physgun in a hall): frozen, the keel's rule is never
	-- asked about them either - flying off, the keel would push against them. While the ship is parked, what is frozen
	-- inside its box gets a collision pair with the keel; it stays where it was frozen (frozen is frozen) and the ship
	-- flies off through it. Once it is out of the ship's box the pair goes: a frozen thing flown into is a hit.
	local k = hull.SGKeel
	local kp = IsValid(k) and k:GetPhysicsObject()
	if not IsValid(kp) then return end
	k.SGFrozenPairs = k.SGFrozenPairs or {}
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not mn then return end
	local lo, hi = hull:LocalToWorld(mn), hull:LocalToWorld(mx)
	local a, b = Vector(math.min(lo.x, hi.x), math.min(lo.y, hi.y), math.min(lo.z, hi.z)), Vector(math.max(lo.x, hi.x), math.max(lo.y, hi.y), math.max(lo.z, hi.z))
	local inBox = {}
	for _, e in ipairs(ents.FindInBox(a, b)) do inBox[e] = true end
	for e, c in pairs(k.SGFrozenPairs) do
		if not (IsValid(e) and inBox[e]) or e.SGRiderOf then
			if isPair(c) then c:Input("EnableCollisions", nil, nil, nil) c:Remove() end
			k.SGFrozenPairs[e] = nil
		end
	end
	if kp:IsMotionEnabled() then return end
	for e in pairs(inBox) do
		if not k.SGFrozenPairs[e] and not e.SGRiderOf and not (e.SpaceGridHull or e.SpaceGridKeel or e:IsPlayer() or e:IsNPC() or e:IsWorld() or IsValid(e:GetParent())) then
			local p = e:GetPhysicsObject()
			if IsValid(p) and not p:IsMotionEnabled() and e:GetSolid() == SOLID_VPHYSICS then k.SGFrozenPairs[e] = apartPair(k, e) or true end
		end
	end
end
-- A rider that its own addon moved since it was last placed (a ZPM hub slides its ZPMs in and out, places a new one in
-- its slot, pops one out): that is its new place in the ship, not a mistake to undo. ZPMs on a hub on a SpaceGrid
-- ship were held where they were first seen - only one slid in, others sat over the slots or frozen somewhere
-- on the hub, one doubled.
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
				if movedByCode(e, r) and r.hp then r.lp, r.la = WorldToLocal(e:GetPos(), e:GetAngles(), r.hp, r.ha) end
				local np, na = LocalToWorld(r.lp, r.la, pos, ang)
				e:SetPos(np)
				e:SetAngles(na)
				if IsValid(p) then p:SetPos(np); p:SetAngles(na) end
				r.wp, r.wa, r.hp, r.ha = np, na, pos, ang
			end
		end
	end
end
-- the physgun on a rider: it is moved by hand, then takes its new place in the ship
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
-- its grip pulled loose crates along at the ship's speed into the walls; test ptcargo2)
local function place(e, phys, pos, ang)
	e:SetPos(pos)
	e:SetAngles(ang)
	if IsValid(phys) then phys:SetPos(pos, e.SpaceGridHull == true); phys:SetAngles(ang) end
end
-- Loose things in a moving ship (cargo, a crate on the deck, a lamp welded to the wall): the hull is a frozen body
-- that is put somewhere new every tick - it pushes nothing along by itself. So what lies in its box is moved along
-- by the same step (its own motion stays: it is the motion inside the ship); what leaves the box gets the ship's speed
-- once. Players: StarCore carries them (sh_walk.lua). Not moved: other ships and their parts, players, NPCs, what is
-- fixed to something else (a contraption of its own), what is parented.
local carried = setmetatable({}, { __mode = "k" })   -- entity -> hull that carries it
local function carryable(e, hull, k)
	if not IsValid(e) or e == hull or e == k or e:IsPlayer() or e:IsNPC() or IsValid(e:GetParent()) then return false end
	if e.SpaceGridHull or e.SpaceGridKeel or e.SpaceGridSeat or e.SpaceGridDoor or e:GetClass() == "starcore" or e.StarCoreDockOn then return false end
	-- (another addon that moves its own things in a flying ship - AGP's resting Replicators hold on to the deck
	-- themselves - says so with e.SGNoCarry = true; checked as a function too: e:SGNoCarry(hull))
	local nc = e.SGNoCarry
	if nc == true or (isfunction(nc) and nc(e, hull)) then return false end
	local p = e:GetPhysicsObject()
	if not IsValid(p) or not p:IsMotionEnabled() then return false end
	if constraint.HasConstraints(e) then
		-- fixed to something: only when that is this ship (a lamp welded to its wall) - not a contraption of its own
		for _, c in ipairs(constraint.GetTable(e) or {}) do
			local o = c.Ent1 == e and c.Ent2 or c.Ent1
			if IsValid(o) and o ~= hull and o ~= k and not o:IsWorld() then return false end
		end
	end
	return true
end
-- what may make a carried thing fast at once (carry's kick guard): hits, the physgun, the gravity gun, a player's Use
local function kickOK(e) if IsValid(e) then e.SGKickOK = CurTime() + 1 end end
SpaceGrid.KickOK = kickOK
hook.Add("EntityTakeDamage", "SpaceGrid.CarryKick", function(e) if carried[e] then kickOK(e) end end)
hook.Add("PhysgunDrop", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPhysgunPickup", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("GravGunPunt", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("GravGunOnDropped", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPlayerPhysicsDrop", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
hook.Add("OnPlayerPhysicsPickup", "SpaceGrid.CarryKick", function(_, e) kickOK(e) end)
-- (the door and field sheets ask: a carried thing's speed is already its speed inside the ship - sv_doors.lua ThrowBack)
function SpaceGrid.CarriedBy(e) return carried[e] end
local function carry(hull, k, oldPos, oldAng, newPos, newAng, vship)
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not mn then return end
	-- Never out through a wall (test ptcargo: a crate pressed into a corner in hard turns went out through the wall
	-- at 2400 units a second). What the ship carried and has passed through its hull since the last step is put back
	-- where it was.
	local tick = engine.TickCount()
	for e, h in pairs(carried) do
		-- (only while the hull still stands where this code last put it: moved by anything else - a paste, the
		-- physgun, a jump - the old spot means nothing)
		if h == hull and IsValid(e) and e.SGCarryAt and e.SGCarryHull and oldPos:DistToSqr(e.SGCarryHull) < 0.01 then
			local p = e:GetPhysicsObject()
			local tr = IsValid(p) and util.TraceLine({ start = e.SGCarryAt, endpos = p:GetPos(), ignoreworld = true, filter = function(x) return x == hull end })
			if tr and tr.Hit and not tr.StartSolid then
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
	for _, e in ipairs(ents.FindInBox(lo, hi)) do
		if carryable(e, hull, k) then
			-- (where its body is: a sleeping thing's entity keeps the place from before the last step until it wakes -
			-- read from there, it was put back by the ship's whole step each time and thrown at the walls)
			local p = e:GetPhysicsObject()
			local lp, la = WorldToLocal(p:GetPos(), p:GetAngles(), oldPos, oldAng)
			if lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z and lp.z < mx.z + 48 then
				inside[e] = true
				carried[e] = hull
				-- Its own no-touch link with the keel (test ptcargo2: two crates in a Gate hall were pushed along by
				-- the keel at the ship's speed, tick by tick, into the corners and out through the walls - the keel's
				-- block is the whole hall, and the "keel touches only the map" rule did not hold for them). The
				-- same link the welded riders have; made anew for a new keel body, taken off when it leaves.
				local kp = k:GetPhysicsObject()
				-- (the owner's console: "Tried to use a NULL physics object!" here - the old keel body was gone after a
				-- rebuild, and comparing with a removed body is an error: looked at with IsValid first)
				local of = e.SGCarryPairOf
				if not (isPair(e.SGCarryPair) and of and IsValid(of) and of == kp) then
					if isPair(e.SGCarryPair) then e.SGCarryPair:Remove() end
					e.SGCarryPair, e.SGCarryPairOf = apartPair(k, e), kp
				end
				local np, na = LocalToWorld(lp, la, newPos, newAng)
				-- (its motion inside the ship turns with the ship: kept in ship space)
				local lv = WorldToLocal(p:GetVelocity(), angle_zero, vector_origin, oldAng)
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
				if tilted and p:IsGravityEnabled() then lv = lv + fix * gs end
				-- Held on the deck while the ship flies (same test: two crates on the deck of a turning ship slid outwards
				-- faster each step, nothing touching them, until they were in the corners and out through the walls).
				-- Lying on the ship's floor and slow (nothing threw it), it does not slide: the deck holds it, as a
				-- crate is held by its weight on a real deck. Parked ships are not carried: there the game's own physics.
				local held
				if lv:LengthSqr() < 200 * 200 and not free then
					local ext = (e:OBBMaxs() - e:OBBMins()):Length() * 0.5 + 6
					local down = -oldAng:Up()   -- (the hull still stands where it stood this step)
					local c = p:LocalToWorld(p:GetMassCenter())
					local tr = util.TraceLine({ start = c, endpos = c + down * ext, ignoreworld = true, filter = function(x) return x == hull end })
					if tr.Hit and not tr.StartSolid then
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
				e:SetPos(np)
				e:SetAngles(na)
				p:SetPos(np, true)
				p:SetAngles(na)
				e.SGCarryAt, e.SGCarryTick, e.SGCarryHull = np, tick, newPos
				-- Lying still on the deck it stays (a crate in the hangar "slowly gliding over the ships deck, if i push
				-- it its gliding more"). Put somewhere new each step, the game forgets that it rests on the floor and its
				-- grip is gone - so a slow thing that does not fall loses its sliding here.
				if math.abs(lv.z) < 8 and lv.x * lv.x + lv.y * lv.y < 40 * 40 then
					lv = Vector(lv.x * 0.6, lv.y * 0.6, lv.z)
					p:SetAngleVelocity(p:GetAngleVelocity() * 0.6)
				end
				p:SetVelocity(LocalToWorld(lv, angle_zero, vector_origin, newAng))
				e.SGCarryLV = lv
			end
		end
	end
	-- out of the ship since the last step: it keeps the ship's speed
	for e, h in pairs(carried) do
		if h == hull and not inside[e] then
			carried[e] = nil
			if IsValid(e) then
				e.SGCarryAt, e.SGLetOutAt = nil, tick   -- (tests read SGLetOutAt)
				if isPair(e.SGCarryPair) then e.SGCarryPair:Remove() end
				e.SGCarryPair, e.SGCarryPairOf = nil, nil
			end
			local p = IsValid(e) and e:GetPhysicsObject()
			if IsValid(p) and vship then p:AddVelocity(vship) end
		end
	end
end

-- A hit never makes a ship faster (the author's play test: "everywhere i fly fast into it is catapulting the ship high
-- speed away", faster with every bounce off the map's edge; sitting down in a ship built on uneven ground shot it
-- into the air). The keel's blocks are boxes round the parts; pushed into the map (flying into a wall, Ctrl held on
-- the ground, a block corner in a step of the ground when it is let go) the physics pushed them out at any speed.
-- So after each step the keel's speed may grow only as much as flying or falling can make it grow in a step; more
-- than that is cut back (the way it goes stays). Not while held with the physgun or when the ship is destroyed.
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
				-- A frozen keel touches nothing (things spawned inside a ship fell through its floor). The game asks the
				-- "keel touches only the map and other ships" rule (ShouldCollide, below) only about moving bodies: a
				-- parked ship's frozen keel - boxes round whole rooms - pushed a crate spawned in a room out through the
				-- floor. Frozen, the ship one sees (the frozen hull) is all that is needed.
				local coll = kp:IsMotionEnabled()
				if k.SGColl ~= coll then
					k.SGColl = coll
					kp:EnableCollisions(coll)
				end
			end
			if (hull.SGRidersAt or 0) < now then SpaceGrid.Riders(hull) end
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

-- what a keel touches: the map (and its moving brushes) and other ships' hulls - nothing else
hook.Add("ShouldCollide", "SpaceGrid.Keel", function(a, b)
	local k, o
	if a.SpaceGridKeel then k, o = a, b elseif b.SpaceGridKeel then k, o = b, a else return end
	if o:IsWorld() then return true end
	-- (docked in a bigger ship with StarCore: it does not touch that ship - StarCore's own rule, sv_dock.lua)
	if (k.StarCoreDockOn and k.StarCoreDockOn[o]) or (o.StarCoreDockOn and o.StarCoreDockOn[k]) then return false end
	if o.SpaceGridKeel then return false end
	if o.SpaceGridHull then return o ~= k.SGHull end
	if string.StartWith(o:GetClass(), "func_") then return true end
	return false
end)

-- the keel takes no damage: an area hit (blast, a gate's kawoosh) finds the hull round it too (spacegrid_keel.lua)
hook.Add("EntityTakeDamage", "SpaceGrid.KeelNoDamage", function(ent)
	if ent.SpaceGridKeel then return true end
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
