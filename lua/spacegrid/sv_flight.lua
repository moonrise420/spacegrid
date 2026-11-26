-- SpaceGrid: flying. Flight is StarCore's business (its core moves a whole ship as one body); SpaceGrid only makes
-- its ships ready for it:
--  * the chairs of cockpits, bridges, control desks and the captain's place are pilot seats, every other seat is a
--    passenger's (StarCore reads seat.StarCoreRolePreset);
--  * a ship with a pilot seat gets a StarCore core by itself: unseen, under the first pilot seat, welded to the
--    hull, gone with it (spacegrid_autocore 0 = not; a core put on with StarCore's own tool is used instead);
--  * sitting down on any free pilot seat takes the helm (StarCore knows one pilot seat per core: it is handed over);
--  * a ship too complex to move (SpaceGrid.TooBig) stays frozen whatever asks to move it.
-- Without StarCore the seats are plain seats; who sits down on a pilot seat is told once what flying needs.

local cvAuto = CreateConVar("spacegrid_autocore", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), "A SpaceGrid ship with a pilot seat gets a StarCore core by itself (needs the StarCore addon)")

local PILOT = { "_cockpit2?$", "_bridge$", "^r_gatebridge$", "^r2?_console$", "^r_captain$" }   -- (r_gatebridge: the Gate Hall's bridge, - its name does not end in _bridge)
local pilotPart = {}
function SpaceGrid.IsPilotPart(id)
	local r = pilotPart[id]
	if r == nil then
		r = false
		for _, pat in ipairs(PILOT) do
			if id:find(pat) then r = true break end
		end
		pilotPart[id] = r
	end
	return r
end

local function hasStarCore() return StarCore ~= nil and StarCore.Scan ~= nil and scripted_ents.GetStored("starcore") ~= nil end

-- the StarCore core on this hull: the one SpaceGrid put there, or one welded on with StarCore's tool
function SpaceGrid.CoreOf(hull)
	if IsValid(hull.SGCore) then return hull.SGCore end
	-- (welded to the hull with StarCore's tool, or to its keel - sv_keel.lua)
	for _, e in ipairs({ hull, hull.SGKeel }) do
		if IsValid(e) then
			for _, c in ipairs(constraint.FindConstraints(e, "Weld") or {}) do
				local o = c.Ent1 == e and c.Ent2 or c.Ent1
				if IsValid(o) and o:GetClass() == "starcore" then return o end
			end
		end
	end
	return nil
end

function SpaceGrid.FirstPilotSeat(hull)
	local seat
	for _, g in pairs(hull.SGSeats or {}) do
		for _, s in ipairs(g) do
			if IsValid(s) and s.SGPilot and (not seat or s:EntIndex() < seat:EntIndex()) then seat = s end
		end
	end
	return seat
end

-- StarCore finds a ship's seats as the children of its parts - and the game lists none for a hull (measured
-- hull:GetChildren() is empty although every seat's parent is the hull). So the seats are handed to the core as
-- StarCore's tool hands it loose parts: core.ExtraParts.
local function giveSeats(hull, core)
	core.ExtraParts = core.ExtraParts or {}
	core.ExtraParts[hull] = true   -- (the core is welded to the keel; the ship one sees is a part of the ship too)
	for _, g in pairs(hull.SGSeats or {}) do
		for _, s in ipairs(g) do
			if IsValid(s) then core.ExtraParts[s] = true end
		end
	end
end

-- The automatic core exists only while somebody flies the ship: it is made when a player sits down at a pilot
-- seat (SpaceGrid.TakeHelm) and taken off when the ship is built on while nobody sits at its helm (DropIdleCore,
-- called by SpaceGrid.Commit). A core on a ship that was being built crashed the game in its physics - the full
-- suite crashed five times with it and passed 101 of 101 without it.
function SpaceGrid.DropIdleCore(hull)
	local core = hull.SGCore
	if not IsValid(core) or not core.SGAuto then return end
	local seat = core.PilotSeat
	if IsValid(seat) and IsValid(seat:GetDriver()) then return end   -- (flown right now: it stays)
	if core.Helm and core.Helm.on and hasStarCore() then
		StarCore.SetFrozen(core, true)          -- (a parked ship stays where it hovers)
		StarCore.HelmSetOn(core, false)
		-- (its keel held for a rebuild or a cut, sv_keel.lua: it stays where it is once let go)
		local k = hull.SGKeel
		if IsValid(k) and (k.SGHolds or 0) > 0 then k.SGWant = false end
	end
	-- its damage stays with the ship: the next core starts with it (a new core had the full hull, so building on
	-- a damaged ship repaired it for free)
	if core.HullMax and core.HullMax > 0 and core.Hull then hull.SGHullFrac = math.Clamp(core.Hull / core.HullMax, 0, 1) end
	core:Remove()
	hull.SGCore = nil
end

-- called by SpaceGrid.Commit after the seats are made: a core welded on by StarCore's own tool looks at the changed
-- ship again; the automatic one is only made for a pilot (SpaceGrid.MakeCore, from TakeHelm)
function SpaceGrid.SyncCore(hull)
	if not IsValid(hull) or not hasStarCore() then return end
	local core = SpaceGrid.CoreOf(hull)
	if IsValid(core) then
		core:SetNWEntity("starcore_walk_on", hull)
		if core.SGAuto then giveSeats(hull, core) end
		core.NextScan = 0     -- (it looks at the changed ship again right away)
	end
end

function SpaceGrid.MakeCore(hull)
	local seat = SpaceGrid.FirstPilotSeat(hull)
	if not seat or not cvAuto:GetBool() or not hasStarCore() then return end
	local core = ents.Create("starcore")
	if not IsValid(core) then return end
	core:SetPos(seat:GetPos() - hull:GetUp() * 6)
	core:SetAngles(hull:GetAngles())
	core:Spawn()
	core:Activate()
	core:SetNoDraw(true)
	core:DrawShadow(false)
	core:SetNotSolid(true)          -- nothing bumps into it, no click and no Use finds it
	core.SGAuto = true
	core.DoNotDuplicate = true      -- a pasted hull gets its core the same way
	core.PhysgunDisabled = true
	local owner = hull.SGOwner
	if IsValid(owner) then
		core:SetNWEntity("starcore_owner", owner)
		if core.CPPISetOwner then core:CPPISetOwner(owner) end
		core:SetCreator(owner)
	end
	constraint.Weld(core, IsValid(hull.SGKeel) and hull.SGKeel or hull, 0, 0, 0, true, false)   -- (the keel moves the ship: sv_keel.lua)
	hull:DeleteOnRemove(core)
	hull.SGCore = core
	core:SetNWEntity("starcore_walk_on", hull)   -- (who walks in the ship goes with the hull: StarCore sh_walk.lua)
	-- (damaged to 78 %, sat down again - 100 %) however the core goes (Replicators ate it, a blast, a rebuild), its damage
	-- stays with the ship for the next core
	core:CallOnRemove("SpaceGrid.KeepHull", function(c)
		if IsValid(hull) and c.HullMax and c.HullMax > 0 and c.Hull then hull.SGHullFrac = math.Clamp(c.Hull / c.HullMax, 0, 1) end
		-- gone while the pilot sits (the same play test: the HUD went and the ship fell out of the sky): the ship gets
		-- its next core at once and the pilot keeps the helm. Not after a destroyed ship's end.
		local pseat = c.PilotSeat
		local ply = IsValid(pseat) and pseat:GetDriver()
		if c.Destroyed or not IsValid(ply) then return end
		timer.Simple(0, function()
			if not IsValid(hull) or IsValid(hull.SGCore) or not IsValid(pseat) or pseat:GetDriver() ~= ply then return end
			local nc = SpaceGrid.MakeCore(hull)
			if not IsValid(nc) then return end
			nc.PilotSeat = pseat
			nc:SetNWEntity("starcore_pilotseat", pseat)
			if StarCore.CrewAttach then StarCore.CrewAttach(nc) end
			if StarCore.CanControl(nc, ply) and nc.Helm and not nc.Helm.on then StarCore.HelmSetOn(nc, true) end
		end)
	end)
	giveSeats(hull, core)
	StarCore.Scan(core)
	-- the damage the last core left (DropIdleCore)
	local frac = hull.SGHullFrac
	if frac and frac < 1 then
		if not core.HullMax and StarCore.CrewAttach then StarCore.CrewAttach(core) end
		if core.HullMax and core.HullMax > 0 then
			core.Hull = math.max(1, math.floor(core.HullMax * frac))
			core:SetNWInt("starcore_hull", core.Hull)
		end
	end
	hull.SGHullFrac = nil
	return core
end

-- called by SpaceGrid.UseSeat before the player sits down. On a pilot seat: the helm goes to this seat unless the
-- ship's pilot seat is taken.
local told = {}
function SpaceGrid.TakeHelm(hull, seat, ply)
	if not seat.SGPilot then return end
	if not hasStarCore() then
		if IsValid(ply) and not told[ply] then
			told[ply] = true
			SpaceGrid.Say(ply, "say.no_starcore")
		end
		return
	end
	if SpaceGrid.TooBig(hull) then
		if IsValid(ply) then SpaceGrid.Say(ply, "say.too_complex", hull.SGPieces, SpaceGrid.MaxPieces) end
		return
	end
	local core = SpaceGrid.CoreOf(hull)
	if not IsValid(core) then core = SpaceGrid.MakeCore(hull) end
	if not IsValid(core) then return end
	local cur = core.PilotSeat
	if cur ~= seat and not (IsValid(cur) and IsValid(cur:GetDriver())) then
		core.PilotSeat = seat
		core:SetNWEntity("starcore_pilotseat", seat)
		if StarCore.CrewAttach then StarCore.CrewAttach(core) end
	end
end

-- The pilot gets up: the ship is parked where it hovers (StarCore's own parking: frozen until somebody steers
-- again). A hovering ship is a moving body, and walking inside a moving body is where players got stuck
-- a parked one is as firm as a ship that never flew.
hook.Add("PlayerLeaveVehicle", "SpaceGrid.Park", function(_, veh)
	if not IsValid(veh) or not veh.SGPilot or not hasStarCore() then return end
	local hull = veh:GetParent()
	local core = IsValid(hull) and SpaceGrid.CoreOf(hull)
	if not IsValid(core) or not core.Helm or not core.Helm.on or core.PilotSeat ~= veh then return end
	if StarCore.SetFrozen then StarCore.SetFrozen(core, true) end
end)

-- the view keys, told once to who sits down on one of the ship's seats
local toldView = {}
hook.Add("PlayerEnteredVehicle", "SpaceGrid.ViewHint", function(ply, veh)
	if not IsValid(veh) or not veh.SpaceGridSeat or toldView[ply] then return end
	toldView[ply] = true
	SpaceGrid.Say(ply, "say.seat_keys")
end)

-- (the game's own seat view code - Duck flips its third person - is not for these seats: cl_view.lua)
hook.Add("VehicleMove", "SpaceGrid.SeatView", function(_, veh)
	if IsValid(veh) and veh.SpaceGridSeat then return true end
end)

-- A hull with more collision pieces than the game moves safely stays frozen (StarCore's helm unfreezes what it
-- flies; the game has crashed on unfreezing such a hull).
timer.Create("SpaceGrid.TooBigStays", 1, 0, function()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if SpaceGrid.TooBig(hull) then
			local phys = SpaceGrid.Body(hull)
			if IsValid(phys) and phys:IsMotionEnabled() then
				phys:EnableMotion(false)
				local core = hasStarCore() and SpaceGrid.CoreOf(hull)
				if IsValid(core) and core.Helm and core.Helm.on then StarCore.HelmSetOn(core, false) end
			end
		end
	end
end)

-- a ship StarCore destroys as a wreck (starcore_destroy_mode 1) keeps its hull - one body - so StarCore's own
-- darkening and fire of single parts did not show on it. The hull is marked a wreck: the clients draw it dark, its
-- lights go out, fires burn at spots over it and smoke after them (cl_fx.lua); the fire is heard from here for as
-- long as it burns.
SpaceGrid.WreckBurn = 45    -- seconds of fire (then smoke, cl_fx.lua)
hook.Add("StarCore.Event", "SpaceGrid.Wreck", function(core, ev)
	if ev ~= "destroyed" then return end
	for _, e in ipairs(core.Parts or {}) do
		if IsValid(e) and e.SpaceGridHull and not e.SGWreck then
			e.SGWreck = true
			e:SetNWBool("SGWreck", true)
			e:SetNWFloat("SGWreckAt", CurTime())
			local snd = CreateSound(e, "ambient/fire/fire_big_loop1.wav")
			if snd then
				snd:SetSoundLevel(85)
				snd:PlayEx(0.8, 100)
				e:CallOnRemove("SpaceGrid.WreckSound", function() snd:Stop() end)
				timer.Simple(SpaceGrid.WreckBurn, function() if IsValid(e) then snd:FadeOut(4) end end)
			end
		end
	end
end)
