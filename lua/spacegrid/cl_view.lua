-- SpaceGrid: the view from a ship's seat. The game's own seat view had two faults for the owner (2026-11-15): the
-- Duck key - "down" when flying - also flipped between first and third person, and the first-person view sat
-- tilted. So in SpaceGrid's seats the view is made here:
--  * F (the flashlight key) switches between the seat's own view and a view from behind the ship; the mouse wheel
--    moves that camera nearer and farther. Duck does nothing to the view.
--  * first person: the seat's eyes, level with the ship (no tilt of its own);
--  * third person: round the ship's middle, as far away as the ship is big, turned by the mouse.
-- A pilot seat starts in third person, any other seat in first. spacegrid_view remembers the pilot's choice.
local cvThird = CreateClientConVar("spacegrid_view", "1", true, false, "SpaceGrid: a pilot seat's view - from behind the ship (1) or from the seat (0)")
local zoom = 1          -- the third-person camera's distance, as a factor
local third = false     -- the view of the seat one sits in right now

local function seat(ply)
	local v = IsValid(ply) and ply:GetVehicle()
	if IsValid(v) and v:GetNWBool("SGSeat", false) then return v end
end

-- sitting down: a pilot seat takes the remembered choice, any other seat the seat's own view
local last
hook.Add("Think", "SpaceGrid.SeatView", function()
	local v = seat(LocalPlayer())
	if v ~= last then
		last = v
		if v then third = v:GetNWBool("SGPilot", false) and cvThird:GetBool() end
	end
end)

-- F and the mouse wheel
hook.Add("PlayerBindPress", "SpaceGrid.SeatView", function(ply, bind, pressed)
	local v = seat(ply)
	if not v or not pressed then return end
	if bind:find("impulse 100", 1, true) then
		third = not third
		if v:GetNWBool("SGPilot", false) then RunConsoleCommand("spacegrid_view", third and "1" or "0") end
		return true
	end
	if third and bind:find("invprev", 1, true) then zoom = math.max(zoom * 0.88, 0.35) return true end
	if third and bind:find("invnext", 1, true) then zoom = math.min(zoom * 1.14, 4) return true end
end)

hook.Add("CalcView", "SpaceGrid.SeatView", function(ply, origin, angles, fov)
	local v = seat(ply)
	if not v then return end
	local hull = v:GetParent()
	if not IsValid(hull) then return end
	local view = { fov = fov, drawviewer = false }
	if not third then
		-- the seat's eyes; the horizon is the ship's deck, nothing else tilts it
		local a = hull:WorldToLocalAngles(angles)
		a.r = 0
		view.origin = origin
		view.angles = hull:LocalToWorldAngles(a)
		return view
	end
	local mn, mx = hull.SGMins, hull.SGMaxs
	local mid = mn and hull:LocalToWorld((mn + mx) / 2) or hull:GetPos()
	local size = mn and (mx - mn):Length() / 2 or 200
	local dist = (size * 1.7 + 160) * zoom
	local a = Angle(angles.p, angles.y, 0)
	local want = mid - a:Forward() * dist + a:Up() * (size * 0.25)
	-- not through the ground or a wall of the world (the ship itself and what rides on it do not count)
	local tr = util.TraceLine({ start = mid, endpos = want, mask = MASK_SOLID_BRUSHONLY })
	view.origin = tr.Hit and (tr.HitPos + tr.HitNormal * 12) or want
	view.angles = a
	view.drawviewer = true
	return view
end)

-- (the game's own seat view code: Duck flips its third person, the wheel moves its camera - not in these seats)
hook.Add("VehicleMove", "SpaceGrid.SeatView", function(ply, veh)
	if IsValid(veh) and veh:GetNWBool("SGSeat", false) then return true end
end)
