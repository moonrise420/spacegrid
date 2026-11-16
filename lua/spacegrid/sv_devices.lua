-- SpaceGrid: the devices of furnished pieces. A part whose data has `devices = { { class, pos, yaw, w, h }, ... }`
-- (an entity class, its middle in part space, the way it faces, its size) gets these entities; they ride on the
-- ship and go with the part, as doors and seats do. So far: spacegrid_nav, the navigation console's screen.

-- make the devices of a hull match its parts (called by SpaceGrid.Commit)
function SpaceGrid.SyncDevices(hull)
	if not IsValid(hull) or not hull.SG then return end
	local devs = hull.SGDevices or {}
	hull.SGDevices = devs
	for pid, g in pairs(devs) do
		if g.part ~= hull.SG.parts[pid] then
			for _, e in ipairs(g) do
				if IsValid(e) then e:Remove() end
			end
			devs[pid] = nil
		end
	end
	for pid, part in pairs(hull.SG.parts) do
		local list = SpaceGrid.Parts[part.t].devices
		if list and not devs[pid] then
			local g = { part = part }
			for _, dd in ipairs(list) do
				local lpos, lang = LocalToWorld(dd.pos, Angle(0, dd.yaw or 0, 0), part.pos, part.ang)
				local e = ents.Create(dd.class)
				if IsValid(e) then
					if e.SetWide then e:SetWide(dd.w or 64) end
					if e.SetTall then e:SetTall(dd.h or 32) end
					e:SetPos(hull:LocalToWorld(lpos))
					e:SetAngles(hull:LocalToWorldAngles(lang))
					e:Spawn()
					e:SetParent(hull)
					e.SGPart = part
					if IsValid(hull.SGOwner) and e.CPPISetOwner then e:CPPISetOwner(hull.SGOwner) end
					hull:DeleteOnRemove(e)
					g[#g + 1] = e
				end
			end
			devs[pid] = g
		end
	end
	-- the ship's front for its instruments: the way its first pilot seat looks (the seat entity is turned a
	-- quarter against its sitter); without one, the hull's own front
	local seat = SpaceGrid.FirstPilotSeat and SpaceGrid.FirstPilotSeat(hull)
	local fwd = IsValid(seat) and math.NormalizeAngle(hull:WorldToLocalAngles(seat:GetAngles()).y + 90) or 0
	for _, g in pairs(devs) do
		for _, e in ipairs(g) do
			if IsValid(e) and e.SetFwd and e:GetFwd() ~= fwd then e:SetFwd(fwd) end
			if IsValid(e) and e.SGRefresh then e:SGRefresh(hull) end   -- (a lift counts its decks anew)
		end
	end
end

-- Use on the ship while looking at a lift shaft from near (called by the hull's Use after seats and legs): the lift
-- comes to that deck. Returns true when a lift was called.
local function isShaft(t) return t:find("^s_lift") ~= nil end
function SpaceGrid.UseLift(hull, ply)
	if not IsValid(ply) or not ply:IsPlayer() or ply:InVehicle() then return end
	if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
	local tr = ply:GetEyeTrace()
	if tr.Entity ~= hull or tr.HitPos:DistToSqr(ply:EyePos()) > 170 * 170 then return end
	local part = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
	if not part or not isShaft(part.t) then return end
	return SpaceGrid.CallLift(hull, part)
end

-- send the lift of a shaft piece to that piece's deck: down the shaft to its bottom piece, whose platform it is
function SpaceGrid.CallLift(hull, part)
	local st = hull.SG
	local deck, cur, from = 0, part, nil
	while deck < 64 do
		local g = hull.SGDevices and hull.SGDevices[cur.id]
		local lift = g and g[1]
		if IsValid(lift) and lift:GetClass() == "spacegrid_lift" then
			lift:SGGo(deck)
			return true
		end
		local nxt
		for i, port in ipairs(SpaceGrid.Parts[cur.t].ports) do
			local l = cur.links[i]
			local o = port.type == "V" and l and l[1] ~= from and st.parts[l[1]]
			-- downwards: the neighbour through the opening that looks away from this piece's own roof
			if o and isShaft(o.t) and (o.pos - cur.pos):Dot(cur.ang:Up()) < -1 then nxt = o end
		end
		if not nxt then return false end
		from, cur, deck = cur.id, nxt, deck + 1
	end
	return false
end

-- The ship's room lights: on unless its main switch (entity spacegrid_switch) has put them out. The clients draw
-- the light strips dark and leave the rooms unlit (cl_light.lua).
function SpaceGrid.LightsOn(hull) return not hull:GetNWBool("SGLightsOff", false) end
function SpaceGrid.SetLights(hull, on)
	if not IsValid(hull) or SpaceGrid.LightsOn(hull) == on then return end
	hull:SetNWBool("SGLightsOff", not on)
	if not WireLib then return end
	for _, g in pairs(hull.SGDevices or {}) do
		for _, e in ipairs(g) do
			if IsValid(e) and e:GetClass() == "spacegrid_switch" and e.Outputs then WireLib.TriggerOutput(e, "LightsOn", on and 1 or 0) end
		end
	end
end
