-- SpaceGrid: a ship going through a Stargate. The event horizon takes a ship when the whole of it has passed its
-- plane (Ascension Gates / CAP); until then the part already through would stick out of the back of the gate.
-- The gate hides it by a clip plane on the entity it buffers - but a hull draws its parts as models of their own
-- (and baked blocks, end walls, doors, devices are entities of their own), so the same plane is put on each of them
-- here while the gate says the hull is in its buffer (NW "PhysBuffered", "PhysEntity", "PhysBufferedDir" - set by
-- the gate's physics clipping; the release chat's finding, 2026-11-15: "the ship stands out behind the ring").
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

hook.Add("Think", "SpaceGrid.GateClip", function()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		local eh = hull:GetNWBool("PhysBuffered", false) and hull:GetNWEntity("PhysEntity")
		if IsValid(eh) then
			local norm = eh:GetForward() * hull:GetNWInt("PhysBufferedDir", 1)
			local d = norm:Dot(eh:GetPos())
			for _, e in ipairs(drawn(hull)) do
				if IsValid(e) then
					e:SetRenderClipPlaneEnabled(true)
					e:SetRenderClipPlane(norm, d)
				end
			end
			hull.SGGateClip = true
		elseif hull.SGGateClip then
			for _, e in ipairs(drawn(hull)) do
				if IsValid(e) then e:SetRenderClipPlaneEnabled(false) end
			end
			hull.SGGateClip = nil
		end
	end
end)
