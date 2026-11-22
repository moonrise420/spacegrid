-- SpaceGrid: the glow of a moving ship's drives. A part whose data has `glow = { { pos, dir, r }, ... }` - the
-- throat of a nozzle, the way its jet leaves, its radius: engines, engine pods, steering thrusters - shows a jet
-- while its ship moves: bright and long at speed, a faint ember when the ship has only just come to rest.
-- Drawn by this client from the ship's own motion (a client does not know a ship's speed by itself: it is taken
-- from how far the ship has moved). Switch: spacegrid_glow 0 / 1 (client).
local cv = CreateClientConVar("spacegrid_glow", "1", true, false, "SpaceGrid: the drives of a moving ship glow (1) or not (0)")

local FULL = 500        -- at this speed the jet is at its longest
local RANGE = 9000      -- drawn for ships this near
local SPRITE = Material("sprites/light_glow02_add")
local CORE, NEAR, JET = Color(215, 240, 255), Color(150, 210, 255), Color(70, 150, 255)

SpaceGrid.GlowForce = nil   -- (tests: a number 0..1 here shows the jets of every ship at that strength)

-- the nozzles of a hull in hull space, kept until its part list changes
local function nozzles(hull)
	local rev = hull.SGRevHave
	if hull.SGGlow and hull.SGGlowRev == rev then return hull.SGGlow end
	local list = {}
	for _, p in pairs(hull.SG.parts) do
		local def = SpaceGrid.Parts[p.t]
		for _, g in ipairs(def and def.glow or {}) do
			local lp, la = LocalToWorld(g.pos, g.dir:Angle(), p.pos, p.ang)
			list[#list + 1] = { pos = lp, dir = la:Forward(), r = g.r }
		end
	end
	hull.SGGlow, hull.SGGlowRev = list, rev
	return list
end

hook.Add("PostDrawTranslucentRenderables", "SpaceGrid.Glow", function(_, sky)
	if sky or not cv:GetBool() then return end
	local eye, now = EyePos(), RealTime()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if hull.SG and not hull:IsDormant() and hull:GetPos():DistToSqr(eye) < RANGE * RANGE then
			local list = nozzles(hull)
			if #list > 0 then
				-- the ship's speed, from its own motion, and from it the jets' strength (it comes up and dies away softly)
				local pos = hull:GetPos()
				local dt = now - (hull.SGFxAt or now)
				if dt > 0.05 then
					local sp = dt < 0.5 and pos:Distance(hull.SGFxPos or pos) / dt or 0
					hull.SGFxPos, hull.SGFxAt = pos, now
					local want = math.Clamp(sp / FULL, 0, 1)
					if sp > 4 then want = math.max(want, 0.12) end
					local cur = hull.SGFxPow or 0
					hull.SGFxPow = cur + (want - cur) * math.min(dt * (want > cur and 3 or 1.2), 1)
				elseif not hull.SGFxAt then
					hull.SGFxPos, hull.SGFxAt = pos, now
				end
				local pow = SpaceGrid.GlowForce or hull.SGFxPow or 0
				if pow > 0.02 then
					render.SetMaterial(SPRITE)
					local flick = 0.92 + 0.08 * math.sin(now * 31 + hull:EntIndex())
					for _, g in ipairs(list) do
						local wp = hull:LocalToWorld(g.pos)
						local wd = hull:LocalToWorld(g.pos + g.dir) - wp
						local r = g.r
						-- The throat: a hot white heart. Behind it the jet: glows that lie into each other and thin out
						-- towards its end - one flame, not a row of dots (the first try,: six small glows far apart read
						-- as a string of beads; a glow's bright middle is a small part of its square).
						local k = (0.45 + pow * 0.75) * flick
						render.DrawSprite(wp + wd * (r * 0.2), r * 6.5 * k, r * 6.5 * k, CORE)
						local len = r * (1.0 + 6.0 * pow)
						-- (a soft line through its whole length holds the thin end together)
						-- (it narrows and fades to nothing at the jet's end: a plain beam was a bar with a blunt end)
						local glowA = math.min(pow * 1.6, 1)
						render.StartBeam(5)
						for i = 0, 4 do
							local f = i / 4
							NEAR.a = 210 * glowA * (1 - f)
							render.AddBeam(wp + wd * (len * f), r * (1.7 - 1.3 * f) * k, 0.5, NEAR)
						end
						render.EndBeam()
						for i = 1, 20 do
							local f = i / 20
							local s = r * (5.2 - 3.4 * f) * k
							local c = f < 0.34 and NEAR or JET
							c.a = 255 * (1 - f * 0.8) * math.min(pow * 1.6, 1)
							render.DrawSprite(wp + wd * (len * f), s, s, c)
						end
						NEAR.a = 255
					end
					JET.a = 255
				end
			end
		end
	end
end)

-- a wreck - a hull StarCore destroyed (sv_flight.lua marks it "SGWreck"): all its parts are drawn burnt dark, and
-- fires burn at spots over its top for SpaceGrid.WreckBurn seconds, then smoke rises from them a while longer.
--
local BURN, SMOKE = 45, 40     -- (the same fire time as the server's sound: sv_flight.lua)
local TINT = { 0.33, 0.29, 0.25 }
local function tinted(self, flags)
	render.SetColorModulation(TINT[1], TINT[2], TINT[3])
	self:DrawModel(flags)
	render.SetColorModulation(1, 1, 1)
end
SpaceGrid.WreckTint = TINT
function SpaceGrid.IsWreck(hull) return IsValid(hull) and hull:GetNWBool("SGWreck", false) end

-- the fire spots in hull space: a grid over the ship's outline as it lies now (spread evenly, more on a big ship, at
-- most 10); at each, a line straight down from above to where it first meets the hull - whatever side faces up now (a
-- wreck that landed on its back burns on its belly). Found again every 2 s while it tumbles or lies.
local function wreckSpots(hull)
	local now = CurTime()
	if hull.SGWreckSpots and now < (hull.SGWreckSpotsAt or 0) then return hull.SGWreckSpots end
	hull.SGWreckSpotsAt = now + 2
	local mn, mx = hull:WorldSpaceAABB()
	local nx = math.Clamp(math.Round((mx.x - mn.x) / 500), 2, 5)
	local ny = math.Clamp(math.Round((mx.y - mn.y) / 500), 2, 4)
	local spots = {}
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			-- (a little off the grid, the same on every client: the cell's own numbers)
			local fx = (i + 0.5 + 0.3 * math.sin(i * 12.9898 + j * 78.233)) / nx
			local fy = (j + 0.5 + 0.3 * math.sin(i * 39.346 + j * 11.135)) / ny
			local x, y = mn.x + (mx.x - mn.x) * fx, mn.y + (mx.y - mn.y) * fy
			local tr = util.TraceLine({ start = Vector(x, y, mx.z + 60), endpos = Vector(x, y, mn.z - 60),
				filter = function(e) return e == hull end, ignoreworld = true })
			if tr.Hit and tr.Entity == hull then spots[#spots + 1] = hull:WorldToLocal(tr.HitPos) end
		end
	end
	while #spots > 10 do table.remove(spots, math.floor(#spots / 2)) end
	hull.SGWreckSpots = spots
	return spots
end

local nextFx = 0
hook.Add("Think", "SpaceGrid.Wreck", function()
	local now = CurTime()
	if now < nextFx then return end
	local dt = 0.08
	nextFx = now + dt
	local eye = EyePos()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if hull.SG and SpaceGrid.IsWreck(hull) then
			-- dark: every part model (made anew ones too) and the end walls; the merged blocks look at the flag themselves
			-- (spacegrid_mesh.lua)
			for _, t in ipairs({ hull.SGModels or {}, hull.SGEndModels or {} }) do
				for _, m in pairs(t) do if IsValid(m) and m.RenderOverride ~= tinted then m.RenderOverride = tinted end end
			end
			local age = now - hull:GetNWFloat("SGWreckAt", now)
			if age < BURN + SMOKE and not hull:IsDormant() and hull:GetPos():DistToSqr(eye) < 16000 * 16000 then
				local em = hull.SGWreckEm
				if not em then
					em = ParticleEmitter(hull:GetPos())
					hull.SGWreckEm = em
					hull:CallOnRemove("SpaceGrid.WreckFx", function(h) if h.SGWreckEm then h.SGWreckEm:Finish() h.SGWreckEm = nil end end)
				end
				if em then
					em:SetPos(hull:GetPos())
					local size = math.Clamp(hull:BoundingRadius() / 12, 40, 220)
					local fire = age < BURN and 1 or 0
					local smoke = age < BURN and 1 or math.Clamp(1 - (age - BURN) / SMOKE, 0, 1)
					for i, lp in ipairs(wreckSpots(hull)) do
						local wp = hull:LocalToWorld(lp)
						local flick = 0.7 + 0.3 * math.sin(now * 7 + i * 1.7)
						if fire > 0 then
							for _ = 1, 2 do
								local f = em:Add("particles/flamelet" .. math.random(1, 5), wp + VectorRand() * size * 0.4)
								if f then
									f:SetVelocity(Vector(math.Rand(-20, 20), math.Rand(-20, 20), math.Rand(90, 180)))
									f:SetDieTime(math.Rand(0.6, 1.1))
									f:SetStartAlpha(230) f:SetEndAlpha(0)
									f:SetStartSize(size * math.Rand(0.7, 1.1) * flick) f:SetEndSize(size * 0.25)
									f:SetRoll(math.Rand(0, 360)) f:SetRollDelta(math.Rand(-2, 2))
								end
							end
						end
						if math.random() < 0.6 * smoke + 0.1 then
							local s = em:Add("particle/smokesprites_000" .. math.random(1, 9), wp + Vector(0, 0, size * 0.6))
							if s then
								s:SetVelocity(Vector(math.Rand(-25, 25), math.Rand(-25, 25), math.Rand(70, 140)))
								s:SetDieTime(math.Rand(3, 5))
								s:SetStartAlpha(170 * math.max(smoke, 0.2)) s:SetEndAlpha(0)
								s:SetStartSize(size * 1.1) s:SetEndSize(size * 4.5)
								s:SetColor(45, 42, 38)
								s:SetAirResistance(30)
								s:SetRoll(math.Rand(0, 360)) s:SetRollDelta(math.Rand(-0.5, 0.5))
							end
						end
					end
				end
			elseif hull.SGWreckEm and age >= BURN + SMOKE then
				hull.SGWreckEm:Finish()
				hull.SGWreckEm = nil
			end
		end
	end
end)
