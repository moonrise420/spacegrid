-- SpaceGrid: one merged mesh of a baked block of a ship (lua/spacegrid/cl_mesh.lua). Made on the client only, as a
-- child of the hull; the game lights and culls it like any model.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Mesh"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH

if CLIENT then
	function ENT:GetRenderMesh() return self.SGRender end

	-- (a wreck: drawn burnt dark, lua/spacegrid/cl_fx.lua)
	local function draw(self)
		local t = SpaceGrid.IsWreck and SpaceGrid.IsWreck(self:GetParent()) and SpaceGrid.WreckTint
		if t then render.SetColorModulation(t[1], t[2], t[3]) end
		self:DrawModel()
		if t then render.SetColorModulation(1, 1, 1) end
	end

	-- solid materials in the solid pass, glass in the see-through pass; the game lights the mesh like a model
	function ENT:Draw()
		if self.SGRender and not self.SGTrans then draw(self) end
	end

	function ENT:DrawTranslucent()
		if self.SGRender and self.SGTrans then draw(self) end
	end
end
