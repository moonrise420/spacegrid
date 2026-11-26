-- SpaceGrid: a ship going through a Stargate. The event horizon takes a ship when the whole of it has passed its
-- plane (Ascension Gates / CAP); until then the part already through would stick out of the back of the gate.
-- The gate hides it by a clip plane on the entity it buffers - but a hull draws its parts as models of their own
-- (and baked blocks, end walls, doors, devices are entities of their own), so the same plane is put on each of them
-- here while the ship reaches through a horizon. (while the gate said the hull is in its buffer - but since a hidden keel
-- moves the ship it is the keel that the gate buffers, and the hull stuck out again: a player watching a Supergate.
-- Where the ship is tells it without the gate. What is in and on the ship is hidden the same.)
local KINDS = { "spacegrid_door", "spacegrid_field", "spacegrid_nav", "spacegrid_lamp", "spacegrid_lift" }

local function drawn(hull)
	local out = {}
	for _, m in pairs(hull.SGModels or {}) do out[#out + 1] = m end
	for _, m in pairs(hull.SGEndModels or {}) do out[#out + 1] = m end
	for _, c in pairs(hull.SGChunks or {}) do
		for _, e in ipairs(c.ents or {}) do out[#out + 1] = e end
	end
	for _, cls in ipairs(KINDS) do
		for _, e in ipairs(ents.FindByClass(cls)) do
			if e:GetParent() == hull then out[#out + 1] = e end
		end
	end
	return out
end

-- does the ship reach through this horizon?
local function through(hull, eh)
	local mn, mx = hull:OBBMins(), hull:OBBMaxs()
	local n, at = eh:GetForward(), eh:GetPos()
	local c = hull:LocalToWorld((mn + mx) / 2)
	local h = (mx - mn) / 2
	local reach = math.abs(hull:GetForward():Dot(n)) * h.x + math.abs(hull:GetRight():Dot(n)) * h.y + math.abs(hull:GetUp():Dot(n)) * h.z
	local rel = c - at
	local d = rel:Dot(n)
	if math.abs(d) > reach then return false, d end
	return (rel - n * d):LengthSqr() < (eh:BoundingRadius() * 1.1) ^ 2, d
end
-- In the wormhole the gate sets the ship unseen (colour alpha 0) - but its parts are models of their own, which know nothing
-- of it. They are taken out of the picture while it lasts.
local function unseen(hull, on)
	if on then
		hull.SGUnseen = hull.SGUnseen or {}
		local function no(m)
			if not IsValid(m) then return end
			if hull.SGUnseen[m] == nil then hull.SGUnseen[m] = m:GetNoDraw() end
			if not m:GetNoDraw() then m:SetNoDraw(true) end
		end
		-- (its doors, fields, lamps and lifts draw themselves as well: the film showed the doors alone in the air)
		for _, m in ipairs(drawn(hull)) do no(m) end
		for _, cls in ipairs({ "spacegrid_*" }) do
			for _, e in ipairs(ents.FindByClass(cls)) do if e:GetParent() == hull then no(e) end end
		end
	elseif hull.SGUnseen then
		for m, was in pairs(hull.SGUnseen) do if IsValid(m) then m:SetNoDraw(was == true or (m:EntIndex() <= 0 and hull:IsDormant())) end end
		hull.SGUnseen = nil
	end
end
-- is it flying through it? Not a gate on board, not a gate the ship or station stands round or beside (the release
-- chat: a gate opened in a Gate hall and half of the hall was gone): it was before the horizon, came to it from the front
-- and reaches through it now. What reached through it when it was first seen does not count, until it is out of it.
local function flyingThrough(hull, eh)
	local st = hull.SGHorizons
	if not st then st = {} hull.SGHorizons = st end
	local gate = eh:GetParent()
	local thr, d = through(hull, eh)
	local was = st[eh]
	-- all of it is behind the plane, the gate takes it in a moment (it takes a ship when the whole of it is past): still hidden,
	-- for 4 seconds at most - the author saw a carrier again behind the gate it had gone into
	if not thr and was == "in" and d < 0 and hull.SGHorizonAt and hull:GetPos():DistToSqr(hull.SGHorizonAt) < 500 * 500 then
		hull.SGPast = hull.SGPast or {}
		hull.SGPast[eh] = hull.SGPast[eh] or CurTime()
		if CurTime() - hull.SGPast[eh] < 4 then return true end
	else
		if hull.SGPast then hull.SGPast[eh] = nil end
	end
	local at = hull:GetPos()
	if IsValid(gate) and gate:GetNWEntity("SGRider") == hull then thr = false end
	local now
	if not thr then
		now = "out"
	elseif was == "in" or was == "skip" then
		now = was
	else
		-- (came out of it: seen somewhere else a moment ago - the ride takes 3.2 seconds. A far gate this player never had on
		-- his side before counts too; a ship or station first seen round a gate does not.)
		-- (the server says so as well: a player who waits at the far gate sees the ship there for the first time)
		local jumped = CurTime() - hull:GetNWFloat("SGGateCame", -100) < 4 or hull.SGHorizonAt and CurTime() - (hull.SGHorizonT or 0) < 6 and at:DistToSqr(hull.SGHorizonAt) > 500 * 500
		now = (jumped or (was == "out" and d > 0)) and "in" or "skip"
	end
	st[eh] = now
	return now == "in"
end
-- what is in and on the ship, not parented to it: welded weapons, cargo, people
local function aboard(hull, out)
	local mn, mx = hull:OBBMins() - Vector(40, 40, 40), hull:OBBMaxs() + Vector(40, 40, 160)
	for _, e in ipairs(ents.FindInSphere(hull:LocalToWorld((mn + mx) / 2), (mx - mn):Length() / 2 + 200)) do
		local cls = e:GetClass()
		if not (e.SpaceGridHull or e.SpaceGridKeel or e.IsStargate or cls == "event_horizon" or cls == "kawoosh_hurt" or cls:sub(1, 8) == "stargate" or e:IsWorld())
			and e:GetModel() and (e:GetNWEntity("SGRider") == hull or hull:WorldToLocal(e:WorldSpaceCenter()):WithinAABox(mn, mx)) then out[#out + 1] = e end
	end
	return out
end
local function unclip(hull)
	for e in pairs(hull.SGGateClip or {}) do if IsValid(e) then e:SetRenderClipPlaneEnabled(false) end end
	hull.SGGateClip = nil
end

-- (before each frame is drawn: after the gate's own messages, which put a plane of their own on what touches it)
hook.Add("PreRender", "SpaceGrid.GateClip", function()
	local ehs = ents.FindByClass("event_horizon")
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		local eh
		local away = hull:GetColor().a == 0
		if away or hull.SGUnseen then unseen(hull, away) end
		if not away and not hull:IsDormant() then
			for _, x in ipairs(ehs) do if IsValid(x) and flyingThrough(hull, x) then eh = eh or x end end
			hull.SGHorizonAt, hull.SGHorizonT = hull:GetPos(), CurTime()
			for x in pairs(hull.SGHorizons or {}) do if not IsValid(x) then hull.SGHorizons[x] = nil end end
		end
		hull.SGGoesThrough = eh
		if eh then
			-- (seen: the front of the gate - a ship that flies in comes from there, one that comes out goes there)
			local norm = eh:GetForward()
			local d = norm:Dot(eh:GetPos())
			local now = {}
			for _, e in ipairs(aboard(hull, drawn(hull))) do
				if IsValid(e) then
					e:SetRenderClipPlaneEnabled(true)
					e:SetRenderClipPlane(norm, d)
					now[e] = true
				end
			end
			for e in pairs(hull.SGGateClip or {}) do if IsValid(e) and not now[e] then e:SetRenderClipPlaneEnabled(false) end end
			hull.SGGateClip = now
		elseif hull.SGGateClip then
			unclip(hull)
		end
	end
end)
hook.Add("EntityRemoved", "SpaceGrid.GateClip", function(e)
	if e.SGGateClip then unclip(e) end
end)

-- Aboard (the release chat's film from inside): the gate takes a ship when the whole of it is past the plane, and what is
-- past it is hidden - who stood in front hung in the open air behind the gate until then. Who is aboard is in the
-- wormhole from the moment the own eyes are past the plane: the tunnel is seen until the gate's own ride shows it.
local tunnel, tunnelFrom, lastEH, lastAt = nil, nil, nil, 0
local function aboardOf(ply, hull)
	local v = ply:GetVehicle()
	if IsValid(v) then return v:GetParent() == hull end
	return ply:GetGroundEntity() == hull or hull:WorldToLocal(ply:EyePos()):WithinAABox(hull:OBBMins(), hull:OBBMaxs())
end
hook.Add("HUDDrawScoreBoard", "SpaceGrid.GateTunnel", function()
	local ply, on = LocalPlayer(), false
	if IsValid(ply) and ply:Alive() then
		for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
			local eh = hull.SGGoesThrough
			if IsValid(eh) and (EyePos() - eh:GetPos()):Dot(eh:GetForward()) < 6 and aboardOf(ply, hull) then on = true lastEH, lastAt = eh, CurTime() break end
		end
	end
	local hooks = hook.GetTable().HUDDrawScoreBoard
	local ride = hooks and hooks["AGP.WormholeRide"] ~= nil
	-- (the ride's end comes a frame or more before the player's new place: until he is at the far gate the tunnel stays)
	if ride then
		if lastEH then lastAt = CurTime() end
	elseif not on and IsValid(lastEH) and CurTime() - lastAt < 0.7 and (EyePos() - lastEH:GetPos()):Dot(lastEH:GetForward()) < 6 and EyePos():DistToSqr(lastEH:GetPos()) < 3000 * 3000 then
		on = true
	elseif not on and CurTime() - lastAt > 1 then
		lastEH = nil
	end
	SpaceGrid.TunnelOn = on   -- (tests read it)
	if not on or ride then tunnelFrom = nil return end
	tunnelFrom = tunnelFrom or CurTime()
	tunnel = tunnel or Material("!AGPWormholeTravel")
	local tex = tunnel and not tunnel:IsError() and tunnel:GetTexture("$basetexture")
	if tex and not tex:IsError() then
		tunnel:SetInt("$frame", math.floor((CurTime() - tunnelFrom) * 30) % math.max(tex:GetNumAnimationFrames(), 1))
		surface.SetDrawColor(255, 255, 255, 255)
		surface.SetMaterial(tunnel)
		surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
	else
		surface.SetDrawColor(10, 20, 60, 255)
		surface.DrawRect(0, 0, ScrW(), ScrH())
	end
end)
