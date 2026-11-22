-- SpaceGrid: landing gear that folds. Every landing leg has a folded twin part (o_leg -> o_leg_up ...): folding
-- swaps the one for the other under the same part number, so the ship's body and its picture follow by the same
-- way every change of parts takes - a folded leg really is short, the ship can rest on its belly.
--  * By itself: the legs fold in when the ship moves faster than a walk and come out again when it has slowed down.
--  * By hand: Use on a leg (looking at it from near) folds or unfolds all legs and holds that for a while.
-- Skids do not fold.
local UP_SPEED, DOWN_SPEED = 160, 70    -- faster than this: in; slower than this: out
local HOLD = 20                         -- seconds a choice by hand stands before the ship decides again
local REACH = 220                       -- Use reaches a leg this far away

local function isLeg(t) return t:find("^o_leg") ~= nil end
local function folded(t) return t:sub(-3) == "_up" end
local function twin(t) return folded(t) and t:sub(1, -4) or (t .. "_up") end

-- has the hull legs, and are they folded (the first one says)
function SpaceGrid.GearState(hull)
	for _, p in pairs(hull.SG and hull.SG.parts or {}) do
		if isLeg(p.t) then return true, folded(p.t) end
	end
	return false, false
end

-- fold (up = true) or unfold all legs of a hull; returns true when something changed
function SpaceGrid.SetGear(hull, up)
	if not IsValid(hull) or not hull.SG then return false end
	local st, change = hull.SG, {}
	for pid, p in pairs(st.parts) do
		if isLeg(p.t) and folded(p.t) ~= up and SpaceGrid.Parts[twin(p.t)] then change[#change + 1] = { pid, twin(p.t), p.pos, p.ang } end
	end
	if #change == 0 then return false end
	for _, c in ipairs(change) do
		SpaceGrid.StateRemove(st, c[1])
		SpaceGrid.StateAdd(st, c[2], c[3], c[4], c[1])
	end
	hull.SGDirty = true
	SpaceGrid.Commit(hull, true)   -- (no building: the StarCore core stays, sv_hull.lua)
	return true
end

-- Use on the ship while looking at a leg (called by the hull's Use after the seats): all legs change, by hand
function SpaceGrid.UseGear(hull, ply)
	if not IsValid(ply) or not ply:IsPlayer() or ply:InVehicle() then return end
	if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
	local tr = ply:GetEyeTrace()
	if tr.Entity ~= hull or tr.HitPos:DistToSqr(ply:EyePos()) > REACH * REACH then return end
	local part = SpaceGrid.PartAtWorld(hull, tr.HitPos, tr.HitNormal)
	if not part or not isLeg(part.t) then return end
	if hull.CPPICanTool and hull:CPPICanTool(ply, "spacegrid_build") == false then return end
	hull.SGGearHold = CurTime() + HOLD
	return SpaceGrid.SetGear(hull, not folded(part.t))
end

timer.Create("SpaceGrid.Gear", 0.5, 0, function()
	local now = CurTime()
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if hull.SG and (hull.SGGearHold or 0) < now then
			local has, up = SpaceGrid.GearState(hull)
			if has then
				local phys = SpaceGrid.Body(hull)   -- (the keel: sv_keel.lua)
				local speed = IsValid(phys) and phys:IsMotionEnabled() and phys:GetVelocity():Length() or 0
				-- (it must hold for a moment: a bump or a short stop does not work the legs)
				if not up and speed > UP_SPEED then
					hull.SGGearN = (hull.SGGearN or 0) + 1
					if hull.SGGearN >= 2 then hull.SGGearN = 0; SpaceGrid.SetGear(hull, true) end
				elseif up and speed < DOWN_SPEED then
					hull.SGGearN = (hull.SGGearN or 0) + 1
					if hull.SGGearN >= 3 then hull.SGGearN = 0; SpaceGrid.SetGear(hull, false) end
				else
					hull.SGGearN = 0
				end
			end
		end
	end
end)
