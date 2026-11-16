-- SpaceGrid: a floodlight's glass. It belongs to a part of a hull (lua/spacegrid/sv_devices.lua makes and removes it
-- with the part) and rides on the ship. On: the glass glows and the lamp throws its light ahead (cl_light.lua lets
-- the few lamps nearest to the player really light the scene). Use on the glass switches it (who may build on the
-- ship); Wiremod: input On, output IsOn.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Floodlight"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its devices itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true       -- for the build tool and the Remover it stands for its ship, as a door does
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "On")
	self:NetworkVar("Int", 0, "Wide")
	self:NetworkVar("Int", 1, "Tall")
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		self:SetModel("models/spacegrid/door_leaf_s.mdl")   -- (never drawn)
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetUseType(SIMPLE_USE)
		self:DrawShadow(false)
		self:SetOn(true)
		local w, h = self:GetWide(), self:GetTall()
		self:SetCollisionBounds(Vector(-1.5, -w / 2, -h / 2), Vector(1.5, w / 2, h / 2))
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, { "On" })
			self.Outputs = WireLib.CreateOutputs(self, { "IsOn" })
			WireLib.TriggerOutput(self, "IsOn", 1)
		end
	end
end

-- (rays - the Use key's aim, the Wire tool's - do not see the plain box of an entity that rides on a ship: see
-- spacegrid_field.lua)
function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	if isbox and extents then mn, mx = mn - extents, mx + extents end
	local hit, normal, frac = util.IntersectRayWithOBB(start, delta, self:GetPos(), self:GetAngles(), mn, mx)
	if hit then return { HitPos = hit, Fraction = frac, Normal = normal } end
end

if SERVER then
	function ENT:SGSetOn(on)
		if self:GetOn() == on then return end
		self:SetOn(on)
		if WireLib and self.Outputs then WireLib.TriggerOutput(self, "IsOn", on and 1 or 0) end
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
		local hull = self:GetParent()
		if IsValid(hull) and hull.CPPICanTool and hull:CPPICanTool(ply, "spacegrid_build") == false then return end
		self:SGSetOn(not self:GetOn())
	end

	function ENT:TriggerInput(name, value)
		if name == "On" then self:SGSetOn(value ~= 0) end
	end

	function ENT:OnRemove()
		if WireLib and WireLib.Remove then WireLib.Remove(self) end
	end
	return
end

local GLOW = Material("sprites/light_glow02_add")
local WHITE = Color(215, 232, 255)

function ENT:Draw() end

function ENT:DrawTranslucent()
	if not self:GetOn() then return end
	local s = self:GetWide() * 2.6
	render.SetMaterial(GLOW)
	render.DrawSprite(self:GetPos() + self:GetForward() * 2, s, s, WHITE)
end

function ENT:OnRemove()
	if IsValid(self.SGProj) then self.SGProj:Remove() end
end
