-- SpaceGrid: flying. Flight is StarCore's business (its core moves a whole ship as one body); SpaceGrid only makes
-- its ships ready for it:
--  * the chairs of cockpits, bridges, control desks and the captain's place are pilot seats, every other seat is a
--    passenger's (StarCore reads seat.StarCoreRolePreset);
--  * a ship with a pilot seat gets a StarCore core by itself: unseen, under the first pilot seat, welded to the
--    hull, gone with it (spacegrid_autocore 0 = not; a core put on with StarCore's own tool is used instead);
--  * sitting down on any free pilot seat takes the helm (StarCore knows one pilot seat per core: it is handed over);
--  * a ship too complex to move (SpaceGrid.TooBig) stays frozen whatever asks to move it.
-- Without StarCore the seats are plain seats; who sits down on a pilot seat is told once what flying needs.

local cvAuto = CreateConVar("spacegrid_autocore", "1", FCVAR_ARCHIVE, "A SpaceGrid ship with a pilot seat gets a StarCore core by itself (needs the StarCore addon)")

local PILOT = { "_cockpit2?$", "_bridge$", "^r2?_console$", "^r_captain$" }
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
	for _, c in ipairs(constraint.FindConstraints(hull, "Weld") or {}) do
		local o = c.Ent1 == hull and c.Ent2 or c.Ent1
		if IsValid(o) and o:GetClass() == "starcore" then return o end
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
-- 2026-11-14: hull:GetChildren() is empty although every seat's parent is the hull). So the seats are handed to the
-- core as StarCore's tool hands it loose parts: core.ExtraParts.
local function giveSeats(hull, core)
	core.ExtraParts = core.ExtraParts or {}
	for _, g in pairs(hull.SGSeats or {}) do
		for _, s in ipairs(g) do
			if IsValid(s) then core.ExtraParts[s] = true end
		end
	end
end

-- The automatic core exists only while somebody flies the ship: it is made when a player sits down at a pilot
-- seat (SpaceGrid.TakeHelm) and taken off when the ship is built on while nobody sits at its helm (DropIdleCore,
-- called by SpaceGrid.Commit). A core on a ship that was being built crashed the game in its physics - the full
-- suite crashed five times with it and passed 101 of 101 without it (2026-11-15).
function SpaceGrid.DropIdleCore(hull)
	local core = hull.SGCore
	if not IsValid(core) or not core.SGAuto then return end
	local seat = core.PilotSeat
	if IsValid(seat) and IsValid(seat:GetDriver()) then return end   -- (flown right now: it stays)
	if core.Helm and core.Helm.on and hasStarCore() then
		StarCore.SetFrozen(core, true)          -- (a parked ship stays where it hovers)
		StarCore.HelmSetOn(core, false)
	end
	core:Remove()
	hull.SGCore = nil
end

-- called by SpaceGrid.Commit after the seats are made: a core welded on by StarCore's own tool looks at the changed
-- ship again; the automatic one is only made for a pilot (SpaceGrid.MakeCore, from TakeHelm)
function SpaceGrid.SyncCore(hull)
	if not IsValid(hull) or not hasStarCore() then return end
	local core = SpaceGrid.CoreOf(hull)
	if IsValid(core) then
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
	constraint.Weld(core, hull, 0, 0, 0, true, false)
	hull:DeleteOnRemove(core)
	hull.SGCore = core
	giveSeats(hull, core)
	StarCore.Scan(core)
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
-- (the owner, 2026-11-15); a parked one is as firm as a ship that never flew.
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
			local phys = hull:GetPhysicsObject()
			if IsValid(phys) and phys:IsMotionEnabled() then
				phys:EnableMotion(false)
				local core = hasStarCore() and SpaceGrid.CoreOf(hull)
				if IsValid(core) and core.Helm and core.Helm.on then StarCore.HelmSetOn(core, false) end
			end
		end
	end
end)
