-- SpaceGrid: closed rooms hold air. A player stands in a sealed room when no way leads from where he stands to an
-- opening of the ship that nothing closes: every opening on the way is joined to another part or capped, every
-- door on the way out is shut, every force field on the way out is on. An open door joins its two sides; the room
-- behind a shut door is a room of its own.
--
-- PowerGrid's life support asks through the hook "AGP.LS.PlayerSealed" (the player; true = he is in a closed,
-- air-filled room): he then keeps and refills his suit's air and takes no harm from vacuum, cold or heat. Neither
-- addon needs the other. For other code: SpaceGrid.Sealed(ply), SpaceGrid.SealedAt(hull, place in hull space).

-- Per part type: its doors and fields as upright sheets, and for every opening on which side of each sheet it lies.
-- A sheet that cuts the whole part (a doorway piece: its middle lies on the sheet) has two sides; a door in a room's
-- wall has the room as its inside and only what lies right behind the door as its outside.
local function airOf(def)
	if def.SGAir then return def.SGAir end
	local planes = {}
	local mid = (def.mins + def.maxs) / 2
	local function add(list, kind)
		for i, d in ipairs(list or {}) do
			local a = Angle(0, d.yaw or 0, 0)
			local n = a:Forward()
			local side = (mid - d.pos):Dot(n)
			planes[#planes + 1] = { pos = d.pos, n = n, t = a:Right(), half = (d.w or 64) / 2 + 8, kind = kind, i = i,
				inner = math.abs(side) >= 2 and (side > 0 and 1 or -1) or 0, join = def.air and d.join or nil }
		end
	end
	add(def.doors or (def.door and { def.door }), "door")
	add(def.fields, "field")
	-- a part with air rooms (def.air: room box -> air room): a door with join = { a, b } joins air rooms a and b and
	-- gets no bit of its own; the other sheets keep their bit. The air room sits above those bits in the section.
	local nbit = 0
	for _, pl in ipairs(planes) do
		if not pl.join then pl.bit = bit.lshift(1, nbit); nbit = nbit + 1 end
	end
	local air = { planes = planes, port = {}, shift = def.air and bit.lshift(1, nbit) or nil }
	def.SGAir = air
	for i, p in ipairs(def.ports) do air.port[i] = SpaceGrid.AirSection(def, p.pos) end
	return air
end

-- the air room (def.air) of the room box a place lies in: first the box it lies in, else the first box it lies in
-- with each box grown by GROW (ports and doorways on the walls); 0 = in no box
local GROW = 16
local function airRoom(def, q)
	for g = 0, GROW, GROW do
		for i, r in ipairs(def.rooms or {}) do
			local a, b = r[1], r[2]
			if q.x >= a.x - g and q.x <= b.x + g and q.y >= a.y - g and q.y <= b.y + g and q.z >= a.z - g and q.z <= b.z + g then
				return def.air[i] or 0
			end
		end
	end
	return 0
end

-- the section of a part (a number: one bit per sheet without join, plus air room * shift) that a place in part space lies in
function SpaceGrid.AirSection(def, q)
	local air = def.SGAir or airOf(def)
	local s = air.shift and airRoom(def, q) * air.shift or 0
	for _, pl in ipairs(air.planes) do
		if pl.bit then
			local rel = q - pl.pos
			local d = rel:Dot(pl.n)
			local out
			if pl.inner == 0 then
				out = d > 0
			else
				out = (d > 0) ~= (pl.inner > 0) and math.abs(rel:Dot(pl.t)) <= pl.half
			end
			if out then s = s + pl.bit end
		end
	end
	return s
end

-- does this sheet of a part let air through right now (an open door, a field that is off, a sheet that is gone)
local function passes(hull, pid, pl)
	if pl.kind == "door" then
		local g = hull.SGDoors and hull.SGDoors[pid]
		local d = g and g[pl.i]
		return not IsValid(d) or d:GetOpen()
	end
	local g = hull.SGFields and hull.SGFields[pid]
	local e = g and g[pl.i]
	return not IsValid(e) or not e:GetOn()
end

-- is the joint at this place (hull space) shut by a wall in it: a cap or a glass plug always, a force-field plug
-- while its field is on (as a field of a part: passes above)
local function jointShut(hull, st, pos)
	local ends = st.ends
	if not ends or not next(ends) then return false end
	local key = SpaceGrid.PortKey(pos)
	local e = ends[key]
	if not e or not e.joint then return false end
	-- (a flat hangar door,: shut while its door is shut)
	if SpaceGrid.Parts[e.t].door then
		local dg = hull.SGDoors and hull.SGDoors["j" .. key]
		local d = dg and dg[1]
		return IsValid(d) and not d:GetOpen()
	end
	if not SpaceGrid.Parts[e.t].fields then return true end
	local g = hull.SGFields and hull.SGFields["j" .. key]
	local f = g and g[1]
	return IsValid(f) and f:GetOn()
end

-- Is the room at a place of the hull (hull space) sealed? true / false; nil = the place is in no part.
-- The answer for a whole room is kept for a moment (doors move, parts come and go): many players ask twice a second.
local KEEP = 0.4
function SpaceGrid.SealedAt(hull, lpos)
	local st = hull.SG
	if not st then return nil end
	local part = SpaceGrid.StatePartAt(st, lpos, 0)
	if not part then return nil end
	local def = SpaceGrid.Parts[part.t]
	local q = WorldToLocal(lpos, angle_zero, part.pos, part.ang)
	local start = part.id * 65536 + SpaceGrid.AirSection(def, q)
	local cache = hull.SGAirCache
	local now = CurTime()
	if not cache or cache.t + KEEP < now or cache.t > now then
		cache = { t = now, res = {} }
		hull.SGAirCache = cache
	end
	if cache.res[start] ~= nil then return cache.res[start] end
	local seen, queue, head, sealed = { [start] = true }, { start }, 1, true
	while head <= #queue and sealed do
		local key = queue[head]; head = head + 1
		local pid, sec = math.floor(key / 65536), key % 65536
		local p = st.parts[pid]
		if p then
			local pdef = SpaceGrid.Parts[p.t]
			local air = pdef.SGAir or airOf(pdef)
			for i, port in ipairs(pdef.ports) do
				if air.port[i] == sec and not SpaceGrid.IsMount(port.type) then
					local l = p.links[i]
					local o = l and st.parts[l[1]]
					-- an opening that leads outside - unless its end wall shuts it (sh_core.lua, StateEnds)
					if not o and not (st.ends and st.ends[SpaceGrid.PortKey(p.ports[i].pos)]) then sealed = false break end
					-- a wall in the joint (sh_core.lua, JointSeals): no way through - a force field only while it holds
					if o and jointShut(hull, st, p.ports[i].pos) then o = nil end
					if o then
						local odef = SpaceGrid.Parts[o.t]
						local k2 = o.id * 65536 + (odef.SGAir or airOf(odef)).port[l[2]]
						if not seen[k2] then seen[k2] = true; queue[#queue + 1] = k2 end
					end
				end
			end
			for _, pl in ipairs(air.planes) do
				if passes(hull, pid, pl) then
					local k2
					if pl.bit then
						k2 = pid * 65536 + bit.bxor(sec, pl.bit)
					else   -- an open door between two air rooms: the same bits, the other room
						local bits = sec % air.shift
						local r = math.floor(sec / air.shift)
						local o = r == pl.join[1] and pl.join[2] or r == pl.join[2] and pl.join[1] or nil
						if o then k2 = pid * 65536 + o * air.shift + bits end
					end
					if k2 and not seen[k2] then seen[k2] = true; queue[#queue + 1] = k2 end
				end
			end
		end
	end
	if sealed then
		for key in pairs(seen) do cache.res[key] = true end   -- the whole room has the same answer
	else
		cache.res[start] = false
	end
	return sealed
end

-- Is the player inside a sealed room of a SpaceGrid ship? Inside = within a part, with the ship over his head and
-- under his feet (standing on the roof, or beside the keel under a dome's deck, is outside).
local UP, DOWN = 2048, 640
function SpaceGrid.Sealed(ply)
	if not IsValid(ply) then return false end
	local pos = ply:WorldSpaceCenter()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		local mn, mx = hull.SGMins, hull.SGMaxs
		if mn and hull.SG then
			local lp = hull:WorldToLocal(pos)
			if lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z and lp.z < mx.z and SpaceGrid.SealedAt(hull, lp) then
				local up = hull:GetUp()
				local only = function(e) return e == hull end
				local a = util.TraceLine({ start = pos, endpos = pos + up * UP, filter = only, mask = MASK_SOLID })
				local b = a.Hit and util.TraceLine({ start = pos, endpos = pos - up * DOWN, filter = only, mask = MASK_SOLID })
				if b and b.Hit then return true end
			end
		end
	end
	return false
end

hook.Add("AGP.LS.PlayerSealed", "SpaceGrid.Sealed", function(ply)
	if SpaceGrid.Sealed(ply) then return true end
end)

-- Under water a ship does not push the water out: the game still counts a player in a sealed room as under water
-- and drowns him after a few seconds - its own damage, apart from PowerGrid's suit air. A sealed room has air, so
-- that damage does not come (the owner,: "under water in our ships we have also oxygen?"; the same as AGP's ships
-- and PowerGrid's core ships do).
hook.Add("EntityTakeDamage", "SpaceGrid.SealedNoDrown", function(ent, dmg)
	if ent:IsPlayer() and dmg:IsDamageType(DMG_DROWN) and ent:WaterLevel() >= 3 and SpaceGrid.Sealed(ent) then return true end
end)
