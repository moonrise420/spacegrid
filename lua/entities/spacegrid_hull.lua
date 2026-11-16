-- SpaceGrid: a hull - every part joined into it is one piece of ONE collision body (no welds). The parts list
-- lives in self.SG (lua/spacegrid/sh_core.lua); the clients get it from the server and build the same body, so
-- walking on it is smooth, and they draw the part models.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Hull"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.SpaceGridHull = true

local ROOT_MODEL = "models/props_junk/popcan01a.mdl"   -- never drawn: an entity needs some model

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "SGRev")   -- counts the changes of the part list; the clients ask for the list when it moved
end

function ENT:Initialize()
	if SERVER then
		self:SetModel(ROOT_MODEL)
		self:PhysicsInitBox(Vector(-4, -4, -4), Vector(4, 4, 4))
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then phys:EnableMotion(false) end   -- a new hull is frozen: building stays calm
		self.SG = self.SG or SpaceGrid.NewState()
		if self.SGDupe and self.SG.count == 0 then self:SGLoad(self.SGDupe) end
	else
		self.SG = SpaceGrid.NewState()
		self.SGModels = self.SGModels or {}   -- (kept when a full update re-creates the entity)
		self.SGRevHave = -1
		self.SGAsk = 0
	end
end

-- (re)build the one collision body from all parts. Keeps frozen / moving as it was.
function ENT:SGRebuild()
	local conv, mn, mx, mass, raw = SpaceGrid.StateCollision(self.SG)
	if #conv == 0 then return false end
	self.SGPiecesRaw = raw
	local phys = self:GetPhysicsObject()
	local frozen, vel, avel, grav = true, nil, nil, true
	if SERVER and IsValid(phys) then
		frozen = not phys:IsMotionEnabled()
		grav = phys:IsGravityEnabled()   -- (a ship that StarCore flies has none: it must not start to sink when a part is added)
		vel, avel = phys:GetVelocity(), phys:GetAngleVelocity()
	end
	local ok = self:PhysicsInitMultiConvex(conv, "metal")
	self.SGPhysOk = ok
	if SERVER then
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
	end
	self:EnableCustomCollisions(true)
	self:SetCollisionBounds(mn, mx)
	self.SGMins, self.SGMaxs, self.SGPieces = mn, mx, #conv
	if SpaceGrid.TooBig(self) then frozen = true end   -- see SpaceGrid.MaxPieces
	phys = self:GetPhysicsObject()
	if IsValid(phys) then
		if SERVER then
			phys:SetMass(math.Clamp(mass, 1, 50000))
			phys:EnableGravity(grav)
			phys:EnableMotion(not frozen)
			if not frozen then
				phys:SetVelocity(vel)
				phys:AddAngleVelocity(avel - phys:GetAngleVelocity())
				phys:Wake()
			end
		else
			phys:EnableMotion(false)
			phys:SetPos(self:GetPos())
			phys:SetAngles(self:GetAngles())
		end
	end
	if CLIENT then self:SetRenderBounds(mn, mx) end
	return ok
end

if SERVER then
	-- Use on the ship: sit down on the seat one looks at (sv_doors.lua); looking at a landing leg: fold or unfold
	-- the legs (sv_gear.lua)
	function ENT:Use(ply)
		if SpaceGrid.UseSeat and SpaceGrid.UseSeat(self, ply) then return end
		if SpaceGrid.UseGear and SpaceGrid.UseGear(self, ply) then return end
		if SpaceGrid.UseLift then SpaceGrid.UseLift(self, ply) end   -- looking at a lift shaft: the lift comes (sv_devices.lua)
	end

	-- the part list as plain data (duplicator, saves)
	function ENT:SGSave()
		local out = {}
		for _, p in pairs(self.SG.parts) do
			out[#out + 1] = { t = p.t, x = p.pos.x, y = p.pos.y, z = p.pos.z, p = p.ang.p, w = p.ang.y, r = p.ang.r }
		end
		return out
	end

	function ENT:SGLoad(list)
		self.SG = SpaceGrid.NewState()
		for _, d in ipairs(list or {}) do
			if SpaceGrid.Parts[d.t] then SpaceGrid.StateAdd(self.SG, d.t, Vector(d.x, d.y, d.z), Angle(d.p, d.w, d.r)) end
		end
		for _, k in ipairs(self.SGDupeOpen or {}) do self.SG.open[k] = true end   -- (the ends that were opened by hand)
		self.SGDupeOpen = nil
		self.SGDupe = nil
		if self.SG.count > 0 then SpaceGrid.Commit(self) end
	end

	-- duplicator / saves: the live tables stay here, the copy carries the plain list; a pasted hull is made by the
	-- function below (the list is on the entity before it spawns, Initialize builds it)
	function ENT:OnEntityCopyTableFinish(data)
		data.SG, data.SGMins, data.SGMaxs, data.SGOwner = nil, nil, nil, nil
		data.SGDupe = self:SGSave()
		data.SGDupeOpen = table.GetKeys(self.SG.open or {})
	end

	duplicator.Allow("spacegrid_hull")
	duplicator.RegisterEntityClass("spacegrid_hull", function(ply, data)
		if IsValid(ply) and not gamemode.Call("PlayerSpawnSENT", ply, "spacegrid_hull") then return end
		local e = ents.Create("spacegrid_hull")
		if not IsValid(e) then return end
		e:SetPos(data.Pos or vector_origin)
		e:SetAngles(data.Angle or angle_zero)
		e.SGDupe = data.SGDupe
		e.SGDupeOpen = data.SGDupeOpen
		e:Spawn()
		e:Activate()
		if IsValid(ply) then
			e.SGOwner = ply
			if e.CPPISetOwner then e:CPPISetOwner(ply) end
			gamemode.Call("PlayerSpawnedSENT", ply, e)
		end
		local po = data.PhysicsObjects and data.PhysicsObjects[0]
		local phys = e:GetPhysicsObject()
		if IsValid(phys) and po then
			local frozen = po.Frozen or SpaceGrid.TooBig(e)
			phys:EnableMotion(not frozen)
			if not frozen then phys:Wake() end
		end
		return e
	end, "Data")
else
	-- the kill notice when a ship (or a closing door, a lift platform) hits a player: the game's own prop icon. Without
	-- it the notice had no icon and the console said "killicon not found 'spacegrid_hull'" (multiplayer test 2026-11-16).
	for _, class in ipairs({ "spacegrid_hull", "spacegrid_door", "spacegrid_lift" }) do
		if not killicon.Exists(class) then killicon.AddAlias(class, "prop_physics") end
	end

	function ENT:Think()
		-- the client's copy of the body follows the entity (it does not simulate by itself)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetPos(self:GetPos())
			phys:SetAngles(self:GetAngles())
		end
		-- behind the server's revision for a quarter of a second (the list or the changes are normally already on
		-- their way): ask for the whole list
		if self:GetSGRev() ~= self.SGRevHave then
			local now = RealTime()
			self.SGBehind = self.SGBehind or now
			if now - self.SGBehind > 0.25 and self.SGAsk < now then
				self.SGAsk = now + 0.5
				net.Start("SpaceGrid.Req")
				net.WriteEntity(self)
				net.SendToServer()
			end
		else
			self.SGBehind = nil
		end
		self:SetNextClientThink(CurTime())
		return true
	end

	function ENT:Draw() end              -- the parts are drawn as models of their own (cl_hull.lua)
	function ENT:DrawTranslucent() end

	function ENT:OnRemove()
		local models = table.Add(table.ClearKeys(table.Copy(self.SGModels or {})), table.ClearKeys(table.Copy(self.SGEndModels or {})))
		-- (a full update removes and re-creates the entity: only clean up when it is really gone)
		timer.Simple(0, function()
			if IsValid(self) then return end
			for _, m in pairs(models or {}) do
				if IsValid(m) then m:Remove() end
			end
		end)
	end
end
