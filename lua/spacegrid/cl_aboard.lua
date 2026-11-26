-- SpaceGrid: who stands in a flying ship is drawn on their place in the ship. The server names the ship (NW "SGAboard",
-- sv_keel.lua) and the place in it; they are drawn there on the ship as the ship is drawn now. Steps of their own are drawn
-- smoothly over a tenth of a second.
local list, nextLook = {}, 0
local state = setmetatable({}, { __mode = "k" })

local function look()
	nextLook = RealTime() + 0.25
	local new = {}
	for _, c in ipairs({ "npc_*", "prop_vehicle_*" }) do
		for _, e in ipairs(ents.FindByClass(c)) do
			if IsValid(e:GetNWEntity("SGAboard")) then new[e] = true end
		end
	end
	for e in pairs(list) do
		if not new[e] and IsValid(e) then
			e:SetRenderOrigin(nil)
			e:SetRenderAngles(nil)
			state[e] = nil
		end
	end
	list = new
end

hook.Add("PreRender", "SpaceGrid.Aboard", function()
	local now = RealTime()
	if now > nextLook then look() end
	for e in pairs(list) do
		local hull = IsValid(e) and e:GetNWEntity("SGAboard")
		if hull and IsValid(hull) and not e:IsDormant() and not hull:IsDormant() then
			local lp, la = e:GetNWVector("SGAboardAt"), e:GetNWAngle("SGAboardAng")
			local st = state[e]
			if not st or st.hull ~= hull or st.to:DistToSqr(lp) > 200 * 200 then
				st = { hull = hull, from = lp, to = lp, t = now, la = la }
				state[e] = st
			elseif st.to ~= lp then
				st.from = LerpVector(math.Clamp((now - st.t) / 0.1, 0, 1), st.from, st.to)
				st.to, st.t = lp, now
			end
			st.la = LerpAngle(math.Clamp(RealFrameTime() * 12, 0, 1), st.la, la)
			local at, ang = LocalToWorld(LerpVector(math.Clamp((now - st.t) / 0.1, 0, 1), st.from, st.to), st.la, hull:GetPos(), hull:GetAngles())
			e:SetRenderOrigin(at)
			e:SetRenderAngles(e:IsNPC() and Angle(0, ang.y, 0) or ang)
			-- (asked for earlier in the frame - a voice, a look - the body is already made at the place of before: a flicker, test rcpeople)
			e:InvalidateBoneCache()
		end
	end
end)
-- (the body of a player who died aboard a flying ship is one of the server's ragdolls, sv_keel.lua: it wears that player's colour)
local plain = Vector(62 / 255, 88 / 255, 106 / 255)
hook.Add("OnEntityCreated", "SpaceGrid.BodyColour", function(e)
	if IsValid(e) and e:GetClass() == "prop_ragdoll" and not e.GetPlayerColor then
		e.GetPlayerColor = function(s) return s:GetNWVector("SGPlayerColor", plain) end
	end
end)
