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

	-- solid materials in the solid pass, glass in the see-through pass; the game lights the mesh like a model
	function ENT:Draw()
		if self.SGRender and not self.SGTrans then self:DrawModel() end
	end

	function ENT:DrawTranslucent()
		if self.SGRender and self.SGTrans then self:DrawModel() end
	end
end
