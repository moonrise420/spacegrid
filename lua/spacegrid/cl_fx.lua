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
						-- towards its end - one flame, not a row of dots (the first try, 2026-11-14: six small glows far
						-- apart read as a string of beads; a glow's bright middle is a small part of its square).
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
