-- SpaceGrid: a ship's keel - the body that flies, falls and lands. A few big blocks round the ship's parts,
-- unseen and not hit by anything but the map and other ships. The ship one sees (spacegrid_hull) follows it
-- exactly every tick as a "shadow" (as lift and train platforms do), so it is one rigid ship with no welds.
-- Why: the game's physics keeps, for every moving body, a list of the piece pairs it watches, and it overflows at
-- ~65,500 pairs - a moving hull of a few hundred pieces whose bounding sphere reached into the map crashed the game
-- (access violation in vphysics; Code/). A shadow body has no such list with the map, and the keel has few pieces.
-- lua/spacegrid/sv_keel.lua makes and moves it.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Keel"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its keel itself
ENT.PhysgunDisabled = true     -- (the physgun takes the ship one sees: sv_keel.lua hands it on)
ENT.SpaceGridKeel = true
-- damage that hits an area (blasts, a gate's kawoosh) found the keel AND the hull round it: StarCore counted
-- every such hit twice (a supergate's kawoosh destroyed a ship in half a second). The ship one sees takes the
-- hits; the keel takes none, and only goes with its hull (DeleteOnRemove), never dissolved on its own.
ENT.StarCoreNoDamage = true
ENT.NoDissolve = true

function ENT:Initialize()
	if SERVER then
		self:SetModel("models/props_junk/popcan01a.mdl")   -- never drawn: an entity needs some model
		self:PhysicsInitBox(Vector(-4, -4, -4), Vector(4, 4, 4))
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end
	end
	self:SetNoDraw(true)
	self:DrawShadow(false)
	self:EnableCustomCollisions(true)
	self:SetCustomCollisionCheck(true)   -- (sv_keel.lua's ShouldCollide: only the map and other ships)
end

-- no trace ever hits it: shots, the tool gun, the Use key and walking players meet the ship one sees
function ENT:TestCollision() end

if CLIENT then
	function ENT:Draw() end
end
