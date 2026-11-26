-- SpaceGrid: ladders one can climb. A part whose data has `ladder = { mins, maxs }` (a box in part space: the
-- climbing space before its rungs - the ladder shaft pieces) holds whoever is in that box: he does not fall, and
-- "forward" moves him where he looks - up the rungs when he looks up, down when he looks down, off the ladder onto
-- the deck when he looks along it. Back does the opposite, left and right shift him, Jump lets go.
-- Shared: the player's own game moves him the same way the server does, so climbing does not stutter.
local SPEED = 150       -- units per second on the rungs
local REACH = 40        -- the box holds a player this far above a ladder's upper end (he climbs out over the edge)

-- the ladders of a hull, kept until its part list changes
local function ladders(hull)
	local rev = SERVER and hull:GetSGRev() or hull.SGRevHave
	if hull.SGLadders and hull.SGLaddersRev == rev then return hull.SGLadders end
	local list = {}
	for _, p in pairs(hull.SG.parts) do
		local l = SpaceGrid.Parts[p.t] and SpaceGrid.Parts[p.t].ladder
		if l then list[#list + 1] = { part = p, a = l[1], b = l[2] } end
	end
	hull.SGLadders, hull.SGLaddersRev = list, rev
	return list
end

-- the hull whose ladder holds a point (a player's middle), or nil
function SpaceGrid.LadderAt(pos)
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		local mn, mx = hull.SGMins, hull.SGMaxs
		if hull.SG and mn then
			local lp = hull:WorldToLocal(pos)
			if lp.x > mn.x and lp.x < mx.x and lp.y > mn.y and lp.y < mx.y and lp.z > mn.z - 8 and lp.z < mx.z + REACH then
				for _, l in ipairs(ladders(hull)) do
					local q = WorldToLocal(lp, angle_zero, l.part.pos, l.part.ang)
					if q.x > l.a.x and q.x < l.b.x and q.y > l.a.y and q.y < l.b.y and q.z > l.a.z - 8 and q.z < l.b.z + REACH then return hull, l end
				end
			end
		end
	end
	return nil
end

local cvGravity = GetConVar("sv_gravity")

hook.Add("Move", "SpaceGrid.Ladder", function(ply, mv)
	if ply:GetMoveType() ~= MOVETYPE_WALK or mv:KeyDown(IN_JUMP) then return end
	local origin = mv:GetOrigin()
	local hull, lad = SpaceGrid.LadderAt(origin + Vector(0, 0, 36))
	if not hull then return end
	local ang = mv:GetAngles()
	local f = (mv:KeyDown(IN_FORWARD) and 1 or 0) - (mv:KeyDown(IN_BACK) and 1 or 0)
	local s = (mv:KeyDown(IN_MOVERIGHT) and 1 or 0) - (mv:KeyDown(IN_MOVELEFT) and 1 or 0)
	local v = ang:Forward() * (f * SPEED) + Angle(0, ang.y, 0):Right() * (s * SPEED * 0.5)
	-- Looking steeply up or down he climbs straight, kept in the middle of the shaft (test deckflight: he drifted forward
	-- while he climbed, and in a ship that does not stand along the map's axes his square box met the opening's edge)
	if f ~= 0 and math.abs(ang.p) > 45 then
		local up = hull:GetUp()
		local mid = (lad.a + lad.b) / 2
		local axis = hull:LocalToWorld((LocalToWorld(mid, angle_zero, lad.part.pos, lad.part.ang)))
		local to = axis - origin
		to = to - up * to:Dot(up)
		local pull = to * 4
		if pull:Length() > 80 then pull = pull:GetNormalized() * 80 end
		v = up * (f * SPEED * (ang.p < 0 and 1 or -1)) + pull
	end
	if ply:OnGround() then
		-- standing on a deck by the ladder: he walks as ever, unless he starts to climb up
		if v.z < 30 then return end
		mv:SetOrigin(origin + Vector(0, 0, 3))
		ply:SetGroundEntity(NULL)
	end
	-- (the game pulls him down by its gravity in the same tick: that much is given back)
	v.z = v.z + (cvGravity and cvGravity:GetFloat() or 600) * FrameTime()
	mv:SetVelocity(v)
end)
