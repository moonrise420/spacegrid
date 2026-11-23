-- SpaceGrid: the Use key with the tool gun in hand. The build tool uses Use as a modifier (Use + click), so a held
-- Use belongs to the tool: seats, landing legs, lifts, doors, lamps and switches ignore it. But a player who builds
-- has the tool gun in hand most of the time, and "E does nothing on my landing legs" is no answer. So: a short tap
-- of Use - pressed and let go again without a click in between - is a plain Use on what he looks at, tool gun or
-- not.
local TAP = 0.35      -- seconds between press and release that still count as a tap
local TAP_DOOR = 1.5  -- (on a door, a gate or a switch)
local REACH = 220

-- may this Use be ignored because the tool has the key? (asked by everything that answers Use)
function SpaceGrid.ToolHasUse(ply)
	if ply.SGTapUse then return false end
	local wep = ply:GetActiveWeapon()
	return IsValid(wep) and wep:GetClass() == "gmod_tool"
end

hook.Add("KeyPress", "SpaceGrid.TapUse", function(ply, key)
	if key == IN_USE then
		ply.SGUseAt = CurTime()
	elseif key == IN_ATTACK or key == IN_ATTACK2 or key == IN_RELOAD then
		ply.SGUseAt = nil      -- Use + click: the tool's
	end
end)

hook.Add("KeyRelease", "SpaceGrid.TapUse", function(ply, key)
	if key ~= IN_USE then return end
	local at = ply.SGUseAt
	ply.SGUseAt = nil
	-- (a door or gate takes a longer press too - E on a gate seemed to do nothing)
	if not at or ply:InVehicle() then return end
	local held = CurTime() - at
	local wep = ply:GetActiveWeapon()
	if not (IsValid(wep) and wep:GetClass() == "gmod_tool") then return end   -- (any other weapon: the game's own Use has done it)
	local tr = ply:GetEyeTrace()
	local e = tr.Entity
	if not IsValid(e) or tr.HitPos:DistToSqr(ply:EyePos()) > REACH * REACH then return end
	if not (e.SpaceGridHull or e.SpaceGridDoor) or not e.Use then return end
	if held > (e.SpaceGridDoor and TAP_DOOR or TAP) then return end
	ply.SGTapUse = true
	e:Use(ply, ply, USE_ON, 1)
	ply.SGTapUse = nil
end)
