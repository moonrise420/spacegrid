-- SpaceGrid: a force field in a gate or round a holding cell. Like the door it belongs to a part of a hull
-- (lua/spacegrid/sv_doors.lua makes and removes it with the part) and is parented to the hull.
-- On: the field shows and holds, like the shields in AGP: players and shots are stopped by an oriented box; props,
-- vehicles and other ships are thrown back (the field is a trigger too: SpaceGrid.ThrowBack in sv_doors.lua - it
-- cannot be a wall for the physics, an entity that rides on a ship has no body of its own). Off: gone. Passable:
-- it shows but lets everything through (a hangar's field that only marks the opening).
-- Use on the field switches it (who may build on the ship); a switched-off or passable field keeps a low solid
-- strip on its floor rail, so the Use key and the Wire tool still find it. Wiremod: inputs On and Passable, output
-- IsOn. The fields of one part (the three walls of a cell) switch together.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Force Field"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its fields itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true       -- for the build tool and the Remover it stands for its ship, as a door does
ENT.SpaceGridField = true
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local FADE = 0.35    -- seconds to come up or go out

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "On")
	self:NetworkVar("Bool", 1, "Passable")
	self:NetworkVar("Int", 0, "Wide")
	self:NetworkVar("Int", 1, "Tall")
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		self:SetModel("models/spacegrid/door_leaf_s.mdl")   -- (never drawn: the field is drawn as a sheet)
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetUseType(SIMPLE_USE)
		self:SetTrigger(true)
		self:DrawShadow(false)
		self:SGBox()
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, { "On", "Passable" })
			self.Outputs = WireLib.CreateOutputs(self, { "IsOn" })
			WireLib.TriggerOutput(self, "IsOn", self:GetOn() and 1 or 0)
		end
	end
end

-- Rays - shots, the tool gun's aim, the Wire tool - do not see the plain oriented box of an entity; only box-shaped
-- traces (a walking player) do. Measured 2026-11-14: every line trace went straight through a shut door and a
-- field that was on. So the entity answers traces itself: the same box, tested here, for rays and boxes alike.
function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	if isbox and extents then mn, mx = mn - extents, mx + extents end
	local hit, normal, frac = util.IntersectRayWithOBB(start, delta, self:GetPos(), self:GetAngles(), mn, mx)
	if hit then return { HitPos = hit, Fraction = frac, Normal = normal } end
end

if SERVER then
	-- the whole sheet while it holds; else only the strip on the floor rail
	function ENT:SGBox()
		local w, h = self:GetWide(), self:GetTall()
		if self:GetOn() and not self:GetPassable() then
			self:SetCollisionBounds(Vector(-8, -w / 2, -h / 2), Vector(8, w / 2, h / 2))   -- (thick: fast props must not slip through between two ticks)
		else
			self:SetCollisionBounds(Vector(-3, -w / 2, -h / 2 - 2), Vector(3, w / 2, -h / 2 + 2))
		end
	end

	local function each(self, fn)
		for _, e in ipairs(self.SGGroup or { self }) do
			if IsValid(e) then fn(e) end
		end
	end

	function ENT:SGSetOn(on)
		if self:GetOn() == on then return end
		each(self, function(e)
			e:SetOn(on)
			e:SGBox()
			if WireLib and e.Outputs then WireLib.TriggerOutput(e, "IsOn", on and 1 or 0) end
		end)
		SpaceGrid.Play(self, on and SpaceGrid.Sounds.field.on or SpaceGrid.Sounds.field.off, 70, 0.6)
		local lead = self.SGGroup and self.SGGroup[1] or self
		if IsValid(lead) then lead:SGHum() end
	end

	-- the hum of a field that is on: one for the fields of a part (the first of them carries it)
	function ENT:SGHum()
		local snd = SpaceGrid.Sounds.field.hum
		if not snd then return end
		if self:GetOn() then
			if not self.SGHumPatch then
				self.SGHumPatch = CreateSound(self, snd)
				self.SGHumPatch:SetSoundLevel(60)
			end
			self.SGHumPatch:PlayEx(0.35, 100)
		elseif self.SGHumPatch then
			self.SGHumPatch:Stop()
		end
	end

	function ENT:SGSetPassable(pass)
		if self:GetPassable() == pass then return end
		each(self, function(e)
			e:SetPassable(pass)
			e:SGBox()
		end)
	end

	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
		local hull = self:GetParent()
		if IsValid(hull) and hull.CPPICanTool and hull:CPPICanTool(ply, "spacegrid_build") == false then
			SpaceGrid.Play(self, SpaceGrid.Sounds.denied, 60, 0.5)
			return
		end
		self:SGSetOn(not self:GetOn())
	end

	-- holding, it throws back props, vehicles and other ships
	function ENT:Touch(e)
		if not self:GetOn() or self:GetPassable() then return end
		if SpaceGrid.ThrowBack(self, e, self:GetWide(), self:GetTall()) and (self.SGHitAt or 0) < CurTime() then
			self.SGHitAt = CurTime() + 0.3
			SpaceGrid.Play(self, SpaceGrid.Sounds.field.hit, 75, 0.6)
		end
	end

	function ENT:TriggerInput(name, value)
		if name == "On" then
			self:SGSetOn(value ~= 0)
		elseif name == "Passable" then
			self:SGSetPassable(value ~= 0)
		end
	end

	function ENT:OnRemove()
		if self.SGHumPatch then self.SGHumPatch:Stop() end
		if WireLib and WireLib.Remove then WireLib.Remove(self) end
	end
else
	local sheet
	local function material()
		if not sheet then
			sheet = CreateMaterial("spacegrid_field_sheet", "UnlitGeneric", {
				["$basetexture"] = "models/spacegrid/sg_field", ["$translucent"] = "1", ["$vertexalpha"] = "1", ["$vertexcolor"] = "1", ["$nocull"] = "1" })
		end
		return sheet
	end

	function ENT:Draw() end

	function ENT:DrawTranslucent()
		local w, h = self:GetWide(), self:GetTall()
		if w <= 0 or h <= 0 then return end
		if self.SGSize ~= w * 4096 + h then
			self.SGSize = w * 4096 + h
			self:SetRenderBounds(Vector(-4, -w / 2, -h / 2), Vector(4, w / 2, h / 2))
		end
		local want = self:GetOn() and 1 or 0
		local f = self.SGFrac or want
		if f ~= want then f = math.Approach(f, want, FrameTime() / FADE) end
		self.SGFrac = f
		if f <= 0 then return end
		-- coming up it flickers; a field that holds is denser than one that lets through
		local a = f * f * (3 - 2 * f)
		if f < 1 then a = a * (0.7 + 0.3 * math.sin(CurTime() * 90)) end
		local alpha = math.Clamp(255 * a * (self:GetPassable() and 0.6 or 1), 0, 255)
		local pos, ang = self:GetPos(), self:GetAngles()
		local lf, up = -ang:Right(), ang:Up()
		local u, v, drift = w / 64, h / 64, CurTime() * 0.03
		render.SetMaterial(material())
		mesh.Begin(MATERIAL_QUADS, 1)
		for _, c in ipairs({ { -1, -1 }, { -1, 1 }, { 1, 1 }, { 1, -1 } }) do
			mesh.Position(pos + lf * (c[1] * w / 2) + up * (c[2] * h / 2))
			mesh.TexCoord(0, (c[1] + 1) / 2 * u, (1 - c[2]) / 2 * v + drift)
			mesh.Color(255, 255, 255, alpha)
			mesh.AdvanceVertex()
		end
		mesh.End()
	end
end
