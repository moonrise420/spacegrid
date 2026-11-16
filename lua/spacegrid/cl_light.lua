-- SpaceGrid: light. Three things, all on this client:
--  * a ship's room lights: while they are on, the rooms nearest to the player are lit (the game's own moving
--    lights, a few at a time); spacegrid_roomlights 0 switches that off;
--  * switched off at the ship's main switch (entity spacegrid_switch; the hull's flag "SGLightsOff"), the light
--    strips of the whole ship are drawn dark and the rooms' light is out;
--  * the floodlights (entity spacegrid_lamp) nearest to the player throw real light ahead.
local cvRoom = CreateClientConVar("spacegrid_roomlights", "1", true, false, "SpaceGrid: the rooms of a ship near you are lit by its lamps (1) or not (0)")

local ROOMS, ROOM_RANGE = 4, 560      -- so many rooms are lit at once, the nearest within this range
local LAMPS, LAMP_RANGE = 3, 4000     -- so many floodlights throw real light, the nearest within this range

function SpaceGrid.LightsOn(hull) return not hull:GetNWBool("SGLightsOff", false) end

-- the dark twin of the light strips' material
local OFF
function SpaceGrid.LightOffMaterial(name)
	if not OFF and name then
		local base = Material(name):GetString("$basetexture")
		OFF = CreateMaterial("spacegrid_light_off", "VertexLitGeneric", { ["$basetexture"] = base or "models/debug/debugwhite", ["$color2"] = "[0.06 0.08 0.12]" })
	end
	return OFF
end

local function isStrip(name) return name ~= nil and name:find("sg_light$") ~= nil end

-- draw a hull's light strips dark or as they are: its baked blocks and its single part models
local function strips(hull, off)
	local n = 0
	for _, c in pairs(hull.SGChunks or {}) do
		for _, e in ipairs(c.ents or {}) do
			local r = IsValid(e) and e.SGRender
			if r then
				r.MatOn = r.MatOn or r.Material
				local name = r.MatOn:GetName()
				if isStrip(name) then
					r.Material = off and SpaceGrid.LightOffMaterial(name) or r.MatOn
					n = n + 1
				end
			end
		end
	end
	local models = {}
	for _, m in pairs(hull.SGModels or {}) do models[#models + 1] = m end
	for _, m in pairs(hull.SGEndModels or {}) do models[#models + 1] = m end   -- (the end walls: cl_hull.lua)
	for _, m in ipairs(models) do
		if IsValid(m) then
			for i, name in ipairs(m:GetMaterials()) do
				if isStrip(name) then
					SpaceGrid.LightOffMaterial(name)
					m:SetSubMaterial(i - 1, off and "!spacegrid_light_off" or "")
					n = n + 1
				end
			end
		end
	end
	hull.SGStripsOff = off and n or 0
end

-- the lamps of a hull's rooms in hull space (under the ceiling of each part's room), kept until its parts change
local function roomLamps(hull)
	local rev = hull.SGRevHave
	if hull.SGLamps and hull.SGLampsRev == rev then return hull.SGLamps end
	local list = {}
	for _, p in pairs(hull.SG.parts) do
		local def = SpaceGrid.Parts[p.t]
		local room = def and def.rooms and def.rooms[1]
		if room then
			local a, b = room[1], room[2]
			list[#list + 1] = LocalToWorld(Vector((a.x + b.x) / 2, (a.y + b.y) / 2, b.z - 14), angle_zero, p.pos, p.ang)
		end
	end
	hull.SGLamps, hull.SGLampsRev = list, rev
	return list
end

timer.Create("SpaceGrid.Lights", 0.1, 0, function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local eye, now = ply:EyePos(), CurTime()
	local near = {}
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if hull.SG and not hull:IsDormant() then
			local off = not SpaceGrid.LightsOn(hull)
			-- the strips: a ship that is dark (or just was) is gone over again and again - blocks are baked and
			-- single models come and go while it is built on
			if (off or hull.SGWasOff) and (hull.SGStripAt or 0) < now then
				hull.SGStripAt = now + 0.5
				strips(hull, off)
				hull.SGWasOff = off
			end
			if not off and cvRoom:GetBool() and hull.SGMins then
				local r = (hull.SGMaxs - hull.SGMins):Length() / 2 + ROOM_RANGE
				if hull:LocalToWorld((hull.SGMins + hull.SGMaxs) / 2):DistToSqr(eye) < r * r then
					for _, lp in ipairs(roomLamps(hull)) do
						local wp = hull:LocalToWorld(lp)
						local d = wp:DistToSqr(eye)
						if d < ROOM_RANGE * ROOM_RANGE then near[#near + 1] = { d = d, pos = wp } end
					end
				end
			end
		end
	end
	table.sort(near, function(a, b) return a.d < b.d end)
	for i = 1, math.min(ROOMS, #near) do
		local dl = DynamicLight(28800 + i)
		if dl then
			dl.pos = near[i].pos
			dl.r, dl.g, dl.b = 150, 190, 255
			dl.brightness = 1
			dl.Size = 330
			dl.Decay = 0
			dl.DieTime = now + 0.35
		end
	end

	-- the floodlights: the nearest ones that are on get a real light, the others lose theirs
	local lamps = {}
	for _, e in ipairs(ents.FindByClass("spacegrid_lamp")) do
		local d = e:GetPos():DistToSqr(eye)
		if e:GetOn() and not e:IsDormant() and d < LAMP_RANGE * LAMP_RANGE then
			lamps[#lamps + 1] = { e = e, d = d }
		elseif IsValid(e.SGProj) then
			e.SGProj:Remove()
			e.SGProj = nil
		end
	end
	table.sort(lamps, function(a, b) return a.d < b.d end)
	for i, q in ipairs(lamps) do
		local e = q.e
		if i <= LAMPS then
			if not IsValid(e.SGProj) then
				local pt = ProjectedTexture()
				if pt then
					pt:SetTexture("effects/flashlight001")
					pt:SetFOV(80)
					pt:SetNearZ(8)
					pt:SetFarZ(1600)
					pt:SetBrightness(5)
					pt:SetColor(Color(215, 230, 255))
					pt:SetEnableShadows(false)
					e.SGProj = pt
				end
			end
		elseif IsValid(e.SGProj) then
			e.SGProj:Remove()
			e.SGProj = nil
		end
	end
end)

-- a lamp's real light rides with its ship
hook.Add("PreRender", "SpaceGrid.Lamps", function()
	for _, e in ipairs(ents.FindByClass("spacegrid_lamp")) do
		local pt = e.SGProj
		if IsValid(pt) then
			pt:SetPos(e:GetPos() + e:GetForward() * 6)
			pt:SetAngles(e:GetAngles())
			pt:Update()
		end
	end
end)
