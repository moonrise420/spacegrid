-- SpaceGrid: the ship's main light switch - the lever on the wall of switch cabinets. It belongs to a part of a
-- hull (lua/spacegrid/sv_devices.lua makes and removes it with the part). Use on the lever switches the room
-- lights of the whole ship: the light strips go dark and the rooms' light goes out (cl_light.lua), or come back.
-- A ship without such a wall has its lights on. Wiremod: input Lights (1 = on), output LightsOn.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Light Switch"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its devices itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true       -- for the build tool and the Remover it stands for its ship, as a door does

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Wide")
	self:NetworkVar("Int", 1, "Tall")
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		self:SetModel("models/spacegrid/door_leaf_s.mdl")   -- (never drawn: the lever is part of the wall piece)
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetUseType(SIMPLE_USE)
		self:DrawShadow(false)
		local w, h = self:GetWide(), self:GetTall()
		self:SetCollisionBounds(Vector(-1.5, -w / 2, -h / 2), Vector(1.5, w / 2, h / 2))
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, { "Lights" })
			self.Outputs = WireLib.CreateOutputs(self, { "LightsOn" })
			WireLib.TriggerOutput(self, "LightsOn", 1)
		end
	end
end

-- (rays do not see the plain box of an entity that rides on a ship: see spacegrid_field.lua)
function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	return SpaceGrid.BoxHit(self, start, delta, isbox, extents, mn, mx)   -- (a touching player goes free: sh_core.lua)

end

if SERVER then
	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
		local hull = self:GetParent()
		if not IsValid(hull) then return end
		if hull.CPPICanTool and hull:CPPICanTool(ply, "spacegrid_build") == false then return end
		SpaceGrid.SetLights(hull, not SpaceGrid.LightsOn(hull))
	end

	function ENT:TriggerInput(name, value)
		local hull = self:GetParent()
		if name == "Lights" and IsValid(hull) then SpaceGrid.SetLights(hull, value ~= 0) end
	end

	function ENT:OnRemove()
		if WireLib and WireLib.Remove then WireLib.Remove(self) end
	end
else
	function ENT:Draw() end
end
