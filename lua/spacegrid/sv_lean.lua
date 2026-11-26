-- SpaceGrid: people in a flying ship stand upright. The game leans every person into the way they moved since their last
-- thought; a ship moves them 12 units a tick, so they leaned by 45 degrees in flight and 53 in boost (test rcpeople). Who is
-- carried by a ship does not lean. What they walk themselves is far too slow to lean anybody.
local people, look = {}, 0
-- (the game sets it in the person's own thought: taken off right before the server sends the frame, or it is set again)
local done = -1
hook.Add("SetupPlayerVisibility", "SpaceGrid.Lean", function()
	local tick = engine.TickCount()
	if done == tick then return end
	done = tick
	local now = CurTime()
	if now > look then
		look = now + 0.25
		people = {}
		for _, e in ipairs(ents.FindByClass("npc_*")) do
			if e.SGAboard and e:IsNPC() then people[#people + 1] = e end
		end
	end
	for _, e in ipairs(people) do
		if IsValid(e) and e.SGAboard and tick - (e.SGAboard.tick or 0) < 40 then
			e:SetSaveValue("m_vecLean", vector_origin)
			e:SetSaveValue("m_vecShift", vector_origin)
		end
	end
end)
