-- SpaceGrid: the doors of the doorways. A part whose data has `door = { pos, yaw, w }` - or `doors = { ... }`, an
-- airlock's two - (the middle of its doorway
-- in part space, the turn of the door's plane, the width) gets a spacegrid_door entity; it goes with the part.
-- Doors open by themselves for a player who comes near and close behind them. The doors of gates (part data with
-- `h`, the opening's height, and kind shutter / blast / jaws) do not: Use or a wire opens and shuts them.

local NEAR = 100      -- a player this close to the door's middle opens it
local HOLD = 1.0      -- seconds it stays open after the last player left
local BLOCK = 34      -- a player this close to the door's middle stands in the doorway: it does not shut on him
local GATE_BLOCK = 24 -- a gate: a player's middle this close to its sheet stands in its opening
local GATE_NEAR, GATE_NEAR_RIDING, GATE_HOLD = 230, 900, 2.0   -- an automatic gate: how near on foot / in a seat opens it, how long it stays open
local DOOR_KIND = { quad = 1, iris = 2, shutter = 3, blast = 4, jaws = 5 }   -- part data's `kind` -> the door entity's (spacegrid_door.lua)

-- make the doors of a hull match its parts (called by SpaceGrid.Commit)
function SpaceGrid.SyncDoors(hull)
	if not IsValid(hull) or not hull.SG then return end
	local doors = hull.SGDoors or {}
	hull.SGDoors = doors
	local jends = SpaceGrid.StateEnds(hull.SG)
	for pid, g in pairs(doors) do
		-- (the part table itself is compared: a part put back under an old number is a new table; a flat hangar door
		-- in a joint is kept under "j<key>" and goes with its wall, as a force-field plug's field)
		local gone
		if g.joint then
			local e = jends[g.joint]
			gone = not e or e.t ~= g.t or e.pos ~= g.pos
		else
			gone = g.part ~= hull.SG.parts[pid]
		end
		if gone then
			for _, d in ipairs(g) do
				if IsValid(d) then d:Remove() end
			end
			doors[pid] = nil
		end
	end
	local todo = {}
	for pid, part in pairs(hull.SG.parts) do todo[#todo + 1] = { pid, part, { part = part } } end
	for key, e in pairs(jends) do
		if e.joint then todo[#todo + 1] = { "j" .. key, e, { joint = key, t = e.t, pos = e.pos } } end
	end
	for _, w in ipairs(todo) do
		local pid, part = w[1], w[2]
		local def = SpaceGrid.Parts[part.t]
		local list = def.doors or (def.door and { def.door })
		if list and not doors[pid] then
			local g = w[3]
			for _, dd in ipairs(list) do
				local lpos, lang = LocalToWorld(dd.pos, Angle(0, dd.yaw or 0, 0), part.pos, part.ang)
				local d = ents.Create("spacegrid_door")
				if IsValid(d) then
					d:SetWide(dd.w)
					d:SetKind(DOOR_KIND[dd.kind or ""] or 0)
					d:SetTall(dd.h or 0)
					d:SetFlat(g.joint ~= nil)   -- (a flat hangar door: its panel's solid box matches its thin posts)
					d:SetPos(hull:LocalToWorld(lpos))
					d:SetAngles(hull:LocalToWorldAngles(lang))
					d:Spawn()
					d:SetParent(hull)
					d.SGPart = not g.joint and part or nil
					d.SGJoint = g.joint   -- (a flat hangar door in a joint: R takes it out of the joint, the tool)
					d.SGAuto = dd.auto == true   -- (a gate that opens by itself for who comes near)
					if IsValid(hull.SGOwner) and d.CPPISetOwner then d:CPPISetOwner(hull.SGOwner) end
					hull:DeleteOnRemove(d)
					g[#g + 1] = d
				end
			end
			-- an airlock: its two doors know each other (they never stand open together) and have the airlock's sounds
			if def.airlock and IsValid(g[1]) and IsValid(g[2]) then
				local lock = { a = g[1], b = g[2] }
				g[1].SGLock, g[2].SGLock = lock, lock
				g[1].SGSet, g[2].SGSet = "airlock", "airlock"
			end
			doors[pid] = g
		end
	end
	-- the force fields of gates and holding cells (part data `fields = { { pos, yaw, w, h }, ... }`): the same way.
	-- The fields of one part switch together.
	local fields = hull.SGFields or {}
	hull.SGFields = fields
	local ends = SpaceGrid.StateEnds(hull.SG)   -- (now: with welds on the ship its body is rebuilt a tick later)
	for pid, g in pairs(fields) do
		-- (a force-field plug in a joint: kept under "j<key>", it goes with its wall - sh_core.lua, JointSeals)
		local gone
		if g.joint then
			local e = ends[g.joint]
			gone = not e or e.t ~= g.t or e.pos ~= g.pos
		else
			gone = g.part ~= hull.SG.parts[pid]
		end
		if gone then
			for _, e in ipairs(g) do
				if IsValid(e) then e:Remove() end
			end
			fields[pid] = nil
		end
	end
	local function spawnFields(gkey, list, g, part)
		for _, fd in ipairs(list) do
			local lpos, lang = LocalToWorld(fd.pos, Angle(0, fd.yaw or 0, 0), part.pos, part.ang)
			local e = ents.Create("spacegrid_field")
			if IsValid(e) then
				e:SetWide(fd.w)
				e:SetTall(fd.h)
				e:SetOn(true)
				e:SetPos(hull:LocalToWorld(lpos))
				e:SetAngles(hull:LocalToWorldAngles(lang))
				e:Spawn()
				e:SetParent(hull)
				e.SGGroup = g
				if IsValid(hull.SGOwner) and e.CPPISetOwner then e:CPPISetOwner(hull.SGOwner) end
				hull:DeleteOnRemove(e)
				g[#g + 1] = e
			end
		end
		fields[gkey] = g
		if IsValid(g[1]) then g[1]:SGHum() end
	end
	for key, e in pairs(ends) do
		local list = e.joint and SpaceGrid.Parts[e.t].fields
		if list and not fields["j" .. key] then spawnFields("j" .. key, list, { joint = key, t = e.t, pos = e.pos }, e) end
	end
	for pid, part in pairs(hull.SG.parts) do
		local list = SpaceGrid.Parts[part.t].fields
		if list and not fields[pid] then spawnFields(pid, list, { part = part }, part) end
	end
	SpaceGrid.SyncSeats(hull)
end

-- The seats of furnished pieces (part data `seats = { { pos, yaw }, ... }`: the middle of the seat's top, the way the
-- sitter faces). Each gets an unseen vehicle seat that rides on the ship. It is not solid - the chair one sees is
-- part of the hull - so it is not the seat that takes the Use key but the ship: SpaceGrid.UseSeat (called by the
-- hull's Use) sits the player on the free seat he looks at. Getting up puts him on a free spot next to it.
local SEAT_DOWN = 4     -- the seat entity's origin lies this far under the top of the seat one sees
local SEAT_TURN = -90   -- the seat model looks a quarter turn away from where its sitter looks
function SpaceGrid.SyncSeats(hull)
	local seats = hull.SGSeats or {}
	hull.SGSeats = seats
	for pid, g in pairs(seats) do
		if g.part ~= hull.SG.parts[pid] then
			for _, s in ipairs(g) do
				if IsValid(s) then s:Remove() end
			end
			seats[pid] = nil
		end
	end
	for pid, part in pairs(hull.SG.parts) do
		local list = SpaceGrid.Parts[part.t].seats
		if list and not seats[pid] then
			local g = { part = part }
			for _, sd in ipairs(list) do
				local yaw = sd.yaw or 0
				local lpos, lang = LocalToWorld(sd.pos - Vector(0, 0, SEAT_DOWN), Angle(0, yaw + SEAT_TURN, 0), part.pos, part.ang)
				local s = ents.Create("prop_vehicle_prisoner_pod")
				if IsValid(s) then
					s:SetModel("models/nova/airboat_seat.mdl")
					s:SetKeyValue("vehiclescript", "scripts/vehicles/prisoner_pod.txt")
					s:SetKeyValue("limitview", "0")
					s:SetPos(hull:LocalToWorld(lpos))
					s:SetAngles(hull:LocalToWorldAngles(lang))
					s:Spawn()
					s:Activate()
					s:SetParent(hull)
					s:SetNoDraw(true)
					s:SetNotSolid(true)
					s:DrawShadow(false)
					s.SpaceGridSeat = true
					-- a cockpit's, bridge's or control desk's chair flies the ship with StarCore (sv_flight.lua)
					-- (a seat with its own role in the part data - the Gate Hall bridge: the captain flies, the desks are a
					-- gunner's and an engineer's (StarCore's crew roles) - else the part decides)
					if sd.role then
						s.SGPilot = sd.role == "pilot"
						s.StarCoreRolePreset = sd.role
					else
						s.SGPilot = SpaceGrid.IsPilotPart ~= nil and SpaceGrid.IsPilotPart(part.t)
						s.StarCoreRolePreset = s.SGPilot and "pilot" or "passenger"
					end
					s:SetNWBool("SGSeat", true)                -- the clients make the view from these seats themselves (cl_view.lua)
					s:SetNWBool("SGPilot", s.SGPilot == true)
					s:SetNWString("SGRole", s.StarCoreRolePreset or "")   -- (cl_view.lua: gunners start in the view from behind)
					s:SetThirdPersonMode(false)
					s.DoNotDuplicate = true      -- a pasted hull makes its seats itself
					s.PhysgunDisabled = true
					-- where one stands after getting up: before the seat, behind it, to its sides - the first free one
					-- (places in hull space, on the deck and a little above it for a seat on a dais)
					local f = Angle(0, yaw, 0):Forward()
					local r = Angle(0, yaw, 0):Right()
					s.SGExit = {}
					for _, d in ipairs({ f * 36, f * -36, r * 36, r * -36 }) do
						for _, z in ipairs({ -54, -48 }) do
							local at = LocalToWorld(Vector(sd.pos.x + d.x, sd.pos.y + d.y, z), angle_zero, part.pos, part.ang)
							s.SGExit[#s.SGExit + 1] = at
						end
					end
					if IsValid(hull.SGOwner) and s.CPPISetOwner then s:CPPISetOwner(hull.SGOwner) end
					hull:DeleteOnRemove(s)
					g[#g + 1] = s
				end
			end
			seats[pid] = g
		end
	end
end

-- Use on the ship: the free seat the player looks at (within reach), if there is one. Returns true when he sat down.
function SpaceGrid.UseSeat(hull, ply)
	if not IsValid(ply) or not ply:IsPlayer() or ply:InVehicle() then return end
	if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
	local eye, aim = ply:EyePos(), ply:GetAimVector()
	local best, bestOff
	for _, g in pairs(hull.SGSeats or {}) do
		for _, s in ipairs(g) do
			if IsValid(s) and not IsValid(s:GetDriver()) then
				local rel = s:GetPos() + s:GetUp() * 12 - eye
				local along = rel:Dot(aim)
				if along > 0 and along < 100 then
					local off = (rel - aim * along):Length()
					if off < 26 and (not bestOff or off < bestOff) then best, bestOff = s, off end
				end
			end
		end
	end
	if not best then return end
	if SpaceGrid.TakeHelm then SpaceGrid.TakeHelm(hull, best, ply) end
	ply:EnterVehicle(best)
	return true
end

-- Who sits stays in the seat (flown through the Dakara building, the pilot sat outside, left of the ship: 180 to 440 units
-- off his seat, on the server, until he got up). A seated player is an entity of his own that the game moves out of a
-- solid thing it finds itself in - the seat and the ship do not. His spot on the seat is taken once he sits, and he is
-- put back there.
local seatSpots = setmetatable({}, { __mode = "k" })   -- player -> { seat, spot, since }
hook.Add("PlayerEnteredVehicle", "SpaceGrid.SeatSpot", function(ply, veh)
	if IsValid(veh) and veh.SpaceGridSeat then seatSpots[ply] = { seat = veh, at = CurTime() + 0.25 } end
end)
hook.Add("PlayerLeaveVehicle", "SpaceGrid.SeatSpot", function(ply) seatSpots[ply] = nil end)
hook.Add("Tick", "SpaceGrid.SeatSpot", function()
	for ply, st in pairs(seatSpots) do
		if not (IsValid(ply) and IsValid(st.seat)) or ply:GetVehicle() ~= st.seat then
			seatSpots[ply] = nil
		elseif ply:GetParent() == st.seat then
			local lp = ply:GetLocalPos()
			if not st.spot then
				-- (as he sits at first; far off already - sat down inside a wall: on the seat)
				if CurTime() >= st.at then st.spot = lp:LengthSqr() < 60 * 60 and lp or Vector(0, 0, 0) end
			elseif lp:DistToSqr(st.spot) > 9 then
				ply:SetLocalPos(st.spot)
				st.seat.SGSeatBack = (st.seat.SGSeatBack or 0) + 1   -- (tests read it)
			end
		end
	end
end)

hook.Add("PlayerLeaveVehicle", "SpaceGrid.Seat", function(ply, veh)
	if not IsValid(veh) or not veh.SpaceGridSeat then return end
	local hull = veh:GetParent()
	if not IsValid(hull) then return end
	-- (getting up from a gunner seat put him outside, through the window - when the seat's own 8 spots were taken,
	-- the game chose one. Now: those spots first, then the nearest free spot round the seat on its deck - inside the
	-- ship, nothing solid between it and the seat (StarCore's SeatExitSpot); never the game's own.)
	local list = {}
	for _, lp in ipairs(veh.SGExit or {}) do list[#list + 1] = hull:LocalToWorld(lp) end
	local mn, mx = hull.SGMins, hull.SGMaxs
	local function inside(at)
		if not mn then return true end
		local l = hull:WorldToLocal(at)
		return l.x > mn.x and l.x < mx.x and l.y > mn.y and l.y < mx.y and l.z > mn.z and l.z < mx.z
	end
	local at
	if StarCore and StarCore.SeatExitSpot then
		at = StarCore.SeatExitSpot(veh, ply, list, inside)
	else
		for _, p in ipairs(list) do
			local tr = util.TraceHull({ start = p, endpos = p, mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72), filter = ply, mask = MASK_PLAYERSOLID })
			if not tr.StartSolid and not tr.Hit then at = p break end
		end
	end
	-- (nothing free at all: on the seat's own spot, a little up - the ship's "stuck player" help frees him from there)
	at = at or (veh:GetPos() + Vector(0, 0, 8))
	if StarCore and StarCore.PutOutOfSeat then StarCore.PutOutOfSeat(ply, hull, at) else ply:SetPos(at) end
end)

-- A door or a field that holds keeps loose things out too: props, vehicles, other ships. It cannot be a wall for
-- the physics (an entity that rides on a ship has no body of its own), so - as the shields in AGP do - it is a
-- trigger that throws back whatever touches it: the thing leaves the sheet again at least as fast as a walk, a fast
-- one bounces. Very fast things can slip through between two ticks. What is fixed to the ship itself (welded
-- lamps, wire parts) is left alone. w, h = the sheet's size. Returns true when it threw something back.
function SpaceGrid.ThrowBack(self, e, w, h)
	if not IsValid(e) or e:IsPlayer() or e:IsNPC() or e.SpaceGridDoor then return end
	local hull = self:GetParent()
	if not IsValid(hull) or e == hull or e:GetParent() == hull then return end
	-- its own ship's body, what is welded on it and its core are never thrown back. (asked by its links alone, in the
	-- moment a ship's body was made anew - something welded on - it had none, and the ship's own shut doors threw the
	-- ship across the map.)
	if e.SGHull == hull or e.SGRiderOf == hull or e == hull.SGCore then return end
	local core = hull.SGCore
	if IsValid(core) and StarCore and StarCore.PartCore and StarCore.PartCore[e] == core then return end
	local phys = e:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then return end
	local now = CurTime()
	if (e.SGRideAt or 0) < now then      -- is it fixed to this ship? (asked every two seconds at most)
		e.SGRideAt = now + 2
		e.SGRides = constraint.HasConstraints(e) and constraint.GetAllConstrainedEntities(e)[hull] ~= nil and hull or nil
	end
	if e.SGRides == hull then return end
	local pos, ang = self:GetPos(), self:GetAngles()
	local n, lf, up = ang:Forward(), -ang:Right(), ang:Up()
	local c = e:LocalToWorld(e:OBBCenter())
	local half = (e:OBBMaxs() - e:OBBMins()) * 0.5
	local ea = e:GetAngles()
	local ex, ey, ez = ea:Forward(), ea:Right(), ea:Up()
	local function reach(d) return math.abs(ex:Dot(d)) * half.x + math.abs(ey:Dot(d)) * half.y + math.abs(ez:Dot(d)) * half.z end
	local rel = c - pos
	local side = rel:Dot(n)
	if math.abs(side) > reach(n) + 2 then return end                                   -- it does not reach the sheet
	if math.abs(rel:Dot(lf)) > w / 2 + reach(lf) or math.abs(rel:Dot(up)) > h / 2 + reach(up) then return end
	local hp = SpaceGrid.Body(hull)   -- (the keel moves the ship: sv_keel.lua)
	local base = IsValid(hp) and hp:GetVelocityAtPoint(c) or vector_origin         -- the ship may be moving itself
	-- (a loose thing the ship carries along - sv_keel.lua - has its speed in the ship already: with the ship's speed taken
	-- off once more, a shut door in a flying ship threw it at the ship's whole speed - out through the hull.)
	--
	if SpaceGrid.CarriedBy and SpaceGrid.CarriedBy(e) == hull then base = vector_origin end
	local v = phys:GetVelocity() - base
	-- the side it came from: against the way it moves (a fast one may have its middle past the sheet already - by its
	-- middle it would be thrown on through); a slow one: where its middle is
	local raw = v:Dot(n)
	local s = math.abs(raw) > 30 and (raw > 0 and -1 or 1) or (side >= 0 and 1 or -1)
	local vn = raw * s                                                                 -- below zero: on its way in
	local want = math.max(-vn * 0.6, 60)
	if vn >= want then return end
	if SpaceGrid.KickOK then SpaceGrid.KickOK(e) end   -- (a push the ship's carry may keep: sv_keel.lua)
	phys:SetVelocity(v + n * (s * (want - vn)) + base)
	-- and out of the sheet: a thing that drives itself - a car, an AGP ship, a jumper - sets its own speed again
	-- every tick and went on through a shut door (tracker: "closed doors and fields must stop props and ships");
	-- put back to the sheet's face on its side, it meets a wall
	local deep = reach(n) + 6 - side * s
	if deep > 1 and deep < reach(n) * 2 + 12 then
		local to = e:GetPos() + n * (s * deep)
		if e:IsVehicle() then e:SetPos(to) else phys:SetPos(to) end
	end
	return true
end

-- Another ship's (or a base's) shield stops a ship (AGP's bubbles stop what touches them by pushing its body, and a
-- ship's hull is a frozen one that its keel carries - the keel ignored them). A round bubble, or a ship's
-- longish one: the ship is put back to it and loses its speed into it, and the shield takes the hit. Passed: its own ship's,
-- one that is down, a containment field, one that knows the ship (a shield identifier), and one round the ship when it came on.
local bubbles = {}
timer.Create("SpaceGrid.Bubbles", 0.25, 0, function()
	bubbles = {}
	for _, cls in ipairs({ "shield", "ship_shield" }) do for _, b in ipairs(ents.FindByClass(cls)) do bubbles[#bubbles + 1] = b end end
end)
local function bubbleHolds(b, hull, k)
	local gen = b.Parent
	if not IsValid(gen) or gen.Depleted or (tonumber(gen.Strength) or 0) <= 0 or gen.Containment then return false end
	local nc = b.nocollide
	if istable(nc) and (nc[hull] or nc[k] or (IsValid(hull.SGCore) and nc[hull.SGCore])) then return false end
	if hull.IgnoreShield then return false end
	if gen.SGRiderOf == hull or gen:GetParent() == hull then return false end
	local core = hull.SGCore
	if IsValid(core) and StarCore and StarCore.PartCore and StarCore.PartCore[gen] == core then return false end
	return true
end
function SpaceGrid.ShieldWall(hull, k, kp)
	local boxes, mn, mx = k.SGBoxes, hull.SGMins, hull.SGMaxs
	if #bubbles == 0 or not boxes or not mn then return end
	local kpos, kang, v = kp:GetPos(), kp:GetAngles(), kp:GetVelocity()
	local mid = LocalToWorld((mn + mx) / 2, angle_zero, kpos, kang)
	local rad = (mx - mn):Length() / 2
	k.SGBubbles = k.SGBubbles or setmetatable({}, { __mode = "k" })
	local moved
	for _, b in ipairs(bubbles) do
		if IsValid(b) then
			local c = b:GetPos()
			local half = (b:OBBMaxs() - b:OBBMins()) / 2
			if b:GetClass() == "shield" then half = Vector(b.Size or 80, b.Size or 80, b.Size or 80) end
			local big = math.max(half.x, half.y, half.z)
			local seen = k.SGBubbles[b]
			if mid:DistToSqr(c) > (big + rad + 600) ^ 2 or not bubbleHolds(b, hull, k) then
				k.SGBubbles[b] = nil
			else
				local ba = b:GetAngles()
				-- the ship's point nearest the bubble's middle, and how far in it is
				local bestL, bestP = math.huge, nil
				for _, bx in ipairs(boxes) do
					local lc = WorldToLocal(c, angle_zero, kpos, kang)
					local pt = LocalToWorld(Vector(math.Clamp(lc.x, bx[1].x, bx[2].x), math.Clamp(lc.y, bx[1].y, bx[2].y), math.Clamp(lc.z, bx[1].z, bx[2].z)), angle_zero, kpos, kang)
					local q = WorldToLocal(pt, angle_zero, c, ba)
					local L = Vector(q.x / math.max(half.x, 1), q.y / math.max(half.y, 1), q.z / math.max(half.z, 1)):Length()
					if L < bestL then bestL, bestP = L, pt end
				end
				local qm = WorldToLocal(mid, angle_zero, c, ba)
				local Lm = Vector(qm.x / math.max(half.x, 1), qm.y / math.max(half.y, 1), qm.z / math.max(half.z, 1)):Length()
				if seen == nil then
					-- (in it already when it came on, or the ship was made there: it may fly out)
					k.SGBubbles[b] = Lm < 1 and "in" or "out"
				elseif seen == "in" then
					if bestL > 1 then k.SGBubbles[b] = "out" end
				elseif bestL < 1 and bestP then
					local n = (mid - c):GetNormalized()
					local deep = bestL > 0.05 and (1 - bestL) * bestP:Distance(c) / bestL or big
					kpos = kpos + n * math.min(deep, 120)
					mid = mid + n * math.min(deep, 120)
					local raw = v:Dot(n)
					if raw < 0 then v = v - n * raw end
					local hv = IsValid(hull.SGCore) and hull.SGCore.Helm and hull.SGCore.Helm.vel
					if hv and hv:Dot(n) < 0 then hull.SGCore.Helm.vel = hv - n * hv:Dot(n) end
					moved = true
					if raw < -60 and (b.SGHitAt or 0) < CurTime() then
						b.SGHitAt = CurTime() + 0.4
						pcall(b.Hit, b, hull, bestP, math.Clamp(-raw / 200, 1, 10), n)
					end
				end
			end
		end
	end
	if not moved then return end
	k:SetPos(kpos)
	kp:SetPos(kpos)
	kp:SetVelocity(v)
	k.SGLastV = v
	k.SGShieldHits = (k.SGShieldHits or 0) + 1   -- (tests read it)
end

-- A shut door or a field that holds is a wall for a whole SpaceGrid ship too. A ship is moved by its keel
-- (sv_keel.lua), which touches only the map and other hulls - and a door is no piece of its hull's body, so a
-- ship flew through another ship's shut hangar door. After each physics step sv_keel.lua asks here: each keel
-- block that reaches into such a sheet of another ship is put back to the sheet's face, and its speed into the sheet
-- - and the helm's wish for it - is taken away; along the sheet it slides on. (holds?,
-- width, height, half the sheet's thickness: a field's box is 8 to each side, a door's sheet 6)
local function holds(d)
	if d.SpaceGridField then return d:GetOn() and not d:GetPassable(), d:GetWide(), d:GetTall(), 8 end
	if d.SGTall then return not d:GetOpen(), d:GetWide(), d:SGTall(), 6 end
end
function SpaceGrid.SheetWall(hull, k, kp)
	local boxes = k.SGBoxes
	local mn, mx = hull.SGMins, hull.SGMaxs
	if not boxes or not mn then return end
	local v = kp:GetVelocity()
	if v:LengthSqr() < 1 then return end
	local kpos, kang = kp:GetPos(), kp:GetAngles()
	local ax, ay, az = kang:Forward(), kang:Right(), kang:Up()
	-- what lies round the ship this step (its box in the world, one tick's way wider)
	local pad = v:Length() * engine.TickInterval() + 32
	local c0 = LocalToWorld((mn + mx) / 2, angle_zero, kpos, kang)
	local hx = (mx - mn) / 2
	local ex = Vector(math.abs(ax.x) * hx.x + math.abs(ay.x) * hx.y + math.abs(az.x) * hx.z,
		math.abs(ax.y) * hx.x + math.abs(ay.y) * hx.y + math.abs(az.y) * hx.z,
		math.abs(ax.z) * hx.x + math.abs(ay.z) * hx.y + math.abs(az.z) * hx.z) + Vector(pad, pad, pad)
	local hit
	for _, d in ipairs(ents.FindInBox(c0 - ex, c0 + ex)) do
		local other = d.SpaceGridDoor and d:GetParent()
		if IsValid(other) and other ~= hull then
			local on, w, h, THICK = holds(d)
			if on then
				local dp, da = d:GetPos(), d:GetAngles()
				local n, lf, up = da:Forward(), -da:Right(), da:Up()
				local ob = SpaceGrid.Body(other)
				local vr = v - (IsValid(ob) and ob:GetVelocityAtPoint(dp) or vector_origin)
				local raw = vr:Dot(n)
				local best, bs = 0, nil
				for _, bx in ipairs(boxes) do
					local e = (bx[2] - bx[1]) / 2
					local rel = LocalToWorld((bx[1] + bx[2]) / 2, angle_zero, kpos, kang) - dp
					local function reach(dir) return math.abs(ax:Dot(dir)) * e.x + math.abs(ay:Dot(dir)) * e.y + math.abs(az:Dot(dir)) * e.z end
					local function sheet(dir) return math.abs(n:Dot(dir)) * THICK + math.abs(lf:Dot(dir)) * w / 2 + math.abs(up:Dot(dir)) * h / 2 end
					local dn, rn = rel:Dot(n), reach(n)
					-- (overlap: on the sheet's three axes and on the block's own three)
					if math.abs(dn) < rn + THICK and math.abs(rel:Dot(lf)) < w / 2 + reach(lf) and math.abs(rel:Dot(up)) < h / 2 + reach(up)
						and math.abs(rel:Dot(ax)) < e.x + sheet(ax) and math.abs(rel:Dot(ay)) < e.y + sheet(ay) and math.abs(rel:Dot(az)) < e.z + sheet(az) then
						local s = math.abs(raw) > 5 and (raw > 0 and -1 or 1) or (dn >= 0 and 1 or -1)
						local deep = rn + THICK - dn * s
						-- (a block mostly through already - the door shut on a ship in its opening: left alone)
						if deep > best and deep < 256 then best, bs = deep, s end
					end
				end
				if bs then
					kpos = kpos + n * (bs * best)
					if raw * bs < 0 then v = v - n * raw end
					local core = hull.SGCore
					local hv = IsValid(core) and core.Helm and core.Helm.vel
					if hv and hv:Dot(n) * bs < 0 then core.Helm.vel = hv - n * hv:Dot(n) end
					hit = true
					if d.SpaceGridField and (d.SGHitAt or 0) < CurTime() then
						d.SGHitAt = CurTime() + 0.3
						SpaceGrid.Play(d, SpaceGrid.Sounds.field.hit, 75, 0.6)
					end
				end
			end
		end
	end
	if not hit then return end
	k:SetPos(kpos)
	kp:SetPos(kpos)
	kp:SetVelocity(v)
	k.SGLastV = v
	k.SGSheetHits = (k.SGSheetHits or 0) + 1   -- (tests read it)
	return true
end

-- An airlock's two doors. Nobody in the chamber: each opens for whoever comes to it from outside, but only one at a
-- time. Somebody in the chamber: the door he came through shuts behind him, a moment later the other one opens.
local SETTLE = 0.6    -- seconds one door has been shut before the other may open
local function airlock(lock, at, now)
	local a, b = lock.a, lock.b
	local pa, pb = a:GetPos(), b:GetPos()
	local mid, axis = (pa + pb) / 2, pb - pa
	local half = axis:Length() / 2
	axis:Normalize()
	local inside, sideA, sideB = false, false, false
	for _, q in ipairs(at) do
		local rel = q - mid
		local along = rel:Dot(axis)
		if (rel - axis * along):LengthSqr() < 80 * 80 then
			if math.abs(along) < half - 14 then inside = true
			elseif along < 0 and q:DistToSqr(pa) < NEAR * NEAR then sideA = true
			elseif along > 0 and q:DistToSqr(pb) < NEAR * NEAR then sideB = true end
		end
	end
	local wantA, wantB
	if inside then
		local from = lock.last == b and b or a          -- the door he came through
		wantA, wantB = from ~= a, from ~= b
	else
		if sideA ~= sideB then lock.last = sideA and a or b end
		if sideA or a.SGWireOpen then a.SGStay = now + HOLD end
		if sideB or b.SGWireOpen then b.SGStay = now + HOLD end
		wantA, wantB = (a.SGStay or 0) > now, (b.SGStay or 0) > now
	end
	if a:GetLocked() then wantA = false end
	if b:GetLocked() then wantB = false end
	-- a door never shuts on somebody in its doorway
	if not wantA and a:GetOpen() and a.SGInWay then wantA = true end
	if not wantB and b:GetOpen() and b.SGInWay then wantB = true end
	-- never both: a shut door opens only when the other one has been shut for a moment
	if wantA and not a:GetOpen() and (b:GetOpen() or (b.SGShutAt or 0) > now - SETTLE) then wantA = false end
	if wantB and not b:GetOpen() and (a:GetOpen() or wantA or (a.SGShutAt or 0) > now - SETTLE) then wantB = false end
	a:SGSetOpen(wantA)
	b:SGSetOpen(wantB)
end

timer.Create("SpaceGrid.Doors", 0.2, 0, function()
	local doors = ents.FindByClass("spacegrid_door")
	if #doors == 0 then return end
	-- (flying from the captain's chair, a door near it kept opening and shutting. Somebody in a seat of a ship is not
	-- near that ship's own doors - only of other ships' doors, a rover driving into a hangar.)
	local at, riding, aboard = {}, {}, {}
	for _, p in ipairs(player.GetAll()) do
		if p:Alive() then
			at[#at + 1] = p:WorldSpaceCenter()
			riding[#at] = p:InVehicle()
			local v = riding[#at] and p:GetVehicle()
			aboard[#at] = IsValid(v) and v.SpaceGridSeat and v:GetParent() or false
		end
	end
	local now, near2, block2 = CurTime(), NEAR * NEAR, BLOCK * BLOCK
	local locks = {}
	for _, d in ipairs(doors) do
		local pos = d:GetPos()
		local gate = d:SGIsGate()
		local own = d:GetParent()
		if not IsValid(own) then own = nil end
		local near, inWay = false, false
		if gate then
			-- a gate: in the way is who stands in its opening, anywhere along its width
			local a = d:GetAngles()
			local n, r, u = a:Forward(), a:Right(), a:Up()
			local hw, ht = d:GetWide() / 2, d:SGTall() / 2 + 40
			for i, q in ipairs(at) do
				if aboard[i] == own then continue end
				local rel = q - pos
				local dn, dr, du = math.abs(rel:Dot(n)), math.abs(rel:Dot(r)), math.abs(rel:Dot(u))
				-- (only in the opening itself: a player at its side or at a button in front of it is not in the way -
				-- a flat hangar door would not shut standing at it)
				if dn < GATE_BLOCK and dr < hw - 8 and du < ht then inWay = true end
				-- an automatic gate: who comes towards its opening (on foot from near, in a vehicle's seat from far)
				if d.SGAuto and dn < (riding[i] and GATE_NEAR_RIDING or GATE_NEAR) and dr < hw + 48 and du < ht then near = true end
			end
		else
			for i, q in ipairs(at) do
				if aboard[i] == own then continue end
				local d2 = q:DistToSqr(pos)
				if d2 < near2 then near = true end
				if d2 < block2 then inWay = true end
			end
		end
		d.SGInWay = inWay
		local lock = d.SGLock
		if lock and IsValid(lock.a) and IsValid(lock.b) then
			locks[lock] = true
		elseif gate then
			-- a gate does not open by itself: its switch (the Use key, or the wire input Open) says where it stands.
			-- Locked it shuts. It never shuts on a player who stands in its opening.
			-- (shut by hand: an automatic gate opens again only once nobody has been near)
			if d.SGManualShut then
				if not near then d.SGManualShut = nil end
			elseif near then
				d.SGStay = now + GATE_HOLD
			end
			local want = (d.SGWant == true or (d.SGStay or 0) > now) and not d:GetLocked()
			if not want and d:GetOpen() and inWay then want = true end
			d:SGSetOpen(want)
		else
			if near then d.SGStay = now + HOLD end
			-- locked: shut, whoever comes. Wire input Open: open. Else: open for a player who is near.
			local want
			if d:GetLocked() then want = false
			elseif d.SGWireOpen then want = true
			else want = (d.SGStay or 0) > now end
			-- it never shuts on a player who stands in the doorway (a lock or a wire can ask for that)
			if not want and d:GetOpen() and inWay then want = true end
			d:SGSetOpen(want)
		end
	end
	for lock in pairs(locks) do
		local own, list = lock.a:GetParent(), {}
		for i, q in ipairs(at) do if not (IsValid(own) and aboard[i] == own) then list[#list + 1] = q end end
		airlock(lock, list, now)
	end
end)
