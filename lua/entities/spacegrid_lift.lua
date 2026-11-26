-- SpaceGrid: a lift's platform. It belongs to the bottom piece of a lift shaft (lua/spacegrid/sv_devices.lua makes
-- and removes it with the part) and rides on the ship, up and down the shaft pieces that stand on that bottom piece
-- (parts s_lift_base, s_lift, s_lift_top: joined through their openings of type V).
--  * Use on the platform: it goes to the next deck - upwards until the top, then down again.
--  * Use on a shaft from a deck (the hull's Use: SpaceGrid.UseLift): it comes to that deck.
--  * Wiremod: input Deck (1 = the lowest), outputs Deck and Moving.
-- An entity that rides on a ship has no body of its own, so nothing would carry a player who stands on it: the
-- platform moves him along itself, step by step. It waits while somebody stands under it on its way down.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Lift"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its devices itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true       -- for the build tool and the Remover it stands for its ship, as a door does
ENT.RenderGroup = RENDERGROUP_OPAQUE

local HALF, THICK = 52, 6      -- the platform: 104 x 104, 6 thick; the entity's origin is the middle of its top
local DECK = 128               -- from deck to deck
local SPEED = 110              -- units per second

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Wide")
	self:NetworkVar("Int", 1, "Tall")
	self:NetworkVar("Int", 2, "Decks")
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		self:SetModel("models/spacegrid/lift_pad.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetUseType(SIMPLE_USE)
		self:DrawShadow(false)
		self:SetCollisionBounds(Vector(-HALF, -HALF, -THICK), Vector(HALF, HALF, 0))
		self:SetDecks(1)
		self.SGAt, self.SGGoal, self.SGDir = 0, 0, 1     -- height over the lowest deck; the deck it goes to (0 = lowest); which way Use sends it next
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, { "Deck" })
			self.Outputs = WireLib.CreateOutputs(self, { "Deck", "Moving" })
			WireLib.TriggerOutput(self, "Deck", 1)
		end
	end
end

-- (rays and a walking player's box alike: the plain box of an entity that rides on a ship is not seen by rays)
function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	return SpaceGrid.BoxHit(self, start, delta, isbox, extents, mn, mx)   -- (a touching player goes free: sh_core.lua)

end

if CLIENT then
	function ENT:Draw() self:DrawModel() end
	return
end

-- called by SpaceGrid.SyncDevices when the platform is made and after every change of the ship: its home (hull
-- space) and how many decks its shaft has (the shaft pieces standing on its bottom piece)
function ENT:SGRefresh(hull)
	local part = self.SGPart
	if not part or not hull.SG then return end
	if not self.SGHome then
		self.SGHome = hull:WorldToLocal(self:GetPos())
		self.SGUp = part.ang:Up()
	end
	local n, cur, from = 1, part, nil
	while n < 64 do
		local nxt
		for i, port in ipairs(SpaceGrid.Parts[cur.t].ports) do
			local l = cur.links[i]
			if port.type == "V" and l and l[1] ~= from then
				local o = hull.SG.parts[l[1]]
				if o and (o.pos - cur.pos):Dot(self.SGUp) > 1 then nxt = o end
			end
		end
		if not nxt then break end
		from, cur, n = cur.id, nxt, n + 1
	end
	self:SetDecks(n)
	if self.SGGoal > n - 1 then self.SGGoal = n - 1 end
end

-- go to a deck (0 = the lowest)
function ENT:SGGo(deck)
	self.SGGoal = math.Clamp(math.floor(deck), 0, self:GetDecks() - 1)
end

function ENT:Use(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
	local n = self:GetDecks()
	if n < 2 or math.abs(self.SGAt - self.SGGoal * DECK) > 1 then return end   -- one deck only, or still on its way
	if self.SGGoal >= n - 1 then self.SGDir = -1 elseif self.SGGoal <= 0 then self.SGDir = 1 end
	self:SGGo(self.SGGoal + self.SGDir)
end

function ENT:TriggerInput(name, value)
	if name == "Deck" and value >= 1 then self:SGGo(value - 1) end
end

-- the players it carries (who stands on it) and whether somebody stands in its way below
-- (who stands still on it keeps their spot on it until the ride is over: on a server with lag a passenger slid off it in a
-- turning ship and it went up without them - deckflight)
local KEYS = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP)
local function riders(self)
	local on, under = {}, false
	local spots = self.SGSpots or {}
	self.SGSpots = spots
	for _, ply in ipairs(player.GetAll()) do
		if not (ply:Alive() and not ply:InVehicle() and ply:GetMoveType() == MOVETYPE_WALK and ply:KeyDown(KEYS) == false) then spots[ply] = nil end
		if ply:Alive() and not ply:InVehicle() then
			local lp = self:WorldToLocal(ply:GetPos())
			local sp = spots[ply]
			if sp and (sp.t < CurTime() - 0.3 or lp:DistToSqr(sp.lp) > 40 * 40) then spots[ply] = nil sp = nil end
			if sp then
				sp.t = CurTime()
				on[#on + 1] = ply
			elseif math.abs(lp.x) < HALF + 6 and math.abs(lp.y) < HALF + 6 then
				if lp.z > -3 and lp.z < 26 then
					on[#on + 1] = ply
					if lp.z < 6 and ply:GetMoveType() == MOVETYPE_WALK and not ply:KeyDown(KEYS) then spots[ply] = { lp = lp, t = CurTime() } end
				elseif lp.z <= -3 and lp.z > -THICK - 90 then under = true end
			end
		end
	end
	return on, under
end

-- (who stood on it a moment ago and is under it now fell through it: on a server with lag a step of the ship is missed now and
-- then, the platform is 6 thick)
local function noFall(self)
	local last = self.SGLast or {}
	self.SGLast = last
	for _, ply in ipairs(player.GetAll()) do
		local lp = ply:Alive() and not ply:InVehicle() and ply:GetMoveType() == MOVETYPE_WALK and self:WorldToLocal(ply:GetPos())
		if lp and math.abs(lp.x) < HALF + 6 and math.abs(lp.y) < HALF + 6 and lp.z > -THICK - 72 and lp.z < 12 then
			if lp.z > -3 then last[ply] = CurTime()
			elseif last[ply] and CurTime() - last[ply] < 0.25 then
				local at = self:LocalToWorld(Vector(lp.x, lp.y, 0.2))
				ply:SetLocalPos(at)
				ply.SGLifted = engine.TickCount()   -- (StarCore's walking leaves this step in: sh_walk.lua)
				local shadow = ply:GetPhysicsObject()
				if IsValid(shadow) then shadow:SetPos(at, true) end
				local v = ply:GetVelocity()
				ply:SetLocalVelocity(Vector(v.x, v.y, 0))
				last[ply] = CurTime()
				self.SGCaught = (self.SGCaught or 0) + 1   -- (tests read it)
			end
		else
			last[ply] = nil
		end
	end
end

function ENT:Think()
	local hull = self:GetParent()
	if IsValid(hull) and IsValid(hull.SGKeel) and hull.SGKeel:GetVelocity():LengthSqr() > 100 * 100 then noFall(self) end
	local want = (self.SGGoal or 0) * DECK
	local at = self.SGAt or 0
	if IsValid(hull) and self.SGHome and math.abs(want - at) > 0.01 then
		local step = SPEED * FrameTime()
		local d = math.Clamp(want - at, -step, step)
		local on, under = riders(self)
		if d < 0 and under then d = 0 end      -- it does not come down on somebody
		if d ~= 0 then
			at = at + d
			self.SGAt = at
			self:SetLocalPos(self.SGHome + self.SGUp * at)
			local move = hull:LocalToWorld(self.SGUp * d) - hull:GetPos()
			for _, ply in ipairs(on) do
				-- (SetPos put him there in jumps, the passenger's view shook while the ship flew -; measured 3 units a frame, test
				-- deckflight. SetLocalPos leaves the game's smoothing on.)
				local sp = self.SGSpots[ply]
				local at = sp and self:LocalToWorld(sp.lp) or ply:GetPos() + move
				ply:SetLocalPos(at)
				ply.SGLifted = engine.TickCount()   -- (StarCore's walking leaves this step in: sh_walk.lua)
				local shadow = ply:GetPhysicsObject()
				if IsValid(shadow) then shadow:SetPos(at, true) end
				local v = ply:GetVelocity()
				ply:SetLocalVelocity(Vector(v.x, v.y, 0))   -- (no falling speed builds up while he is carried)
			end
		end
		if not self.SGMoving then
			self.SGMoving = true
			if WireLib and self.Outputs then WireLib.TriggerOutput(self, "Moving", 1) end
		end
	elseif self.SGMoving then
		self.SGMoving = false
		if WireLib and self.Outputs then
			WireLib.TriggerOutput(self, "Moving", 0)
			WireLib.TriggerOutput(self, "Deck", (self.SGGoal or 0) + 1)
		end
	end
	self:NextThink(CurTime())
	return true
end

function ENT:OnRemove()
	if WireLib and WireLib.Remove then WireLib.Remove(self) end
end
