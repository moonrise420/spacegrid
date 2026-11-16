-- SpaceGrid: the door of a doorway or a gate. It belongs to a part of a hull (lua/spacegrid/sv_doors.lua makes and
-- removes it with the part), is parented to the hull and so moves with the ship. It is no piece of the hull's
-- collision body: opening and closing must not rebuild a whole ship. It stops players by an oriented box of its own
-- (no physics object - a parented one would stay behind in the world). Loose things - props, vehicles, other ships -
-- are thrown back by a shut door (it is a trigger too: SpaceGrid.ThrowBack in sv_doors.lua).
-- Kinds: 0 = two leaves that part in the middle and slide into the wall; 1 = four leaves, the doorway's rectangle
-- cut along its diagonals: the bolts let go, the side leaves draw back, then the upper and the lower one; 2 = an
-- iris of eight blades in a round hatch: a twist, then each blade draws back along its own middle line.
-- The doors of gates (halls, hangars): 3 = a roll-up door of slats that runs up into the beam; 4 = a blast door, two
-- halves with teeth that part in the middle and slide into the posts; 5 = a jaw door, the upper half runs up into
-- the beam, the lower one down into the deck.
-- Doorways open by themselves for a player who comes near. Use on such a door locks / unlocks it (who may build on
-- the ship). Gates do not open by themselves: Use on the control panel on the post - or on the shut door - opens and
-- shuts them. Wiremod: inputs Open and Lock (stays shut; wins over Open), outputs IsOpen and IsLocked. An open door
-- keeps something solid, so the Wire tool and the Use key still find it: a strip over a doorway (where its light
-- is), the control panel of a gate.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Door"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its doors itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true
ENT.RenderGroup = RENDERGROUP_BOTH

local TALL = 96      -- every doorway of the kit is 96 high; a gate says its own height
local LEAF = { [64] = "models/spacegrid/door_leaf_s.mdl", [128] = "models/spacegrid/door_leaf_m.mdl" }
local IRIS = "models/spacegrid/door_iris_blade.mdl"
local QUAD = {
	[64] = { "models/spacegrid/door_quad_s_side.mdl", "models/spacegrid/door_quad_s_top.mdl" },
	[128] = { "models/spacegrid/door_quad_m_side.mdl", "models/spacegrid/door_quad_m_top.mdl" },
}
local GATE = { [3] = "shutter", [4] = "blast", [5] = "jaws" }      -- models/spacegrid/gate_<name>_<width>.mdl
-- move = seconds to open or close; pass = seconds after the start of opening until one can pass (a gate is solid
-- again as long before it has shut); set = its sounds (sh_sounds.lua)
local KIND = {
	[0] = { move = 0.35, pass = 0 }, [1] = { move = 0.9, pass = 0.45 }, [2] = { move = 0.8, pass = 0.4 },
	[3] = { move = 3.0, pass = 1.3, set = "gate" }, [4] = { move = 4.0, pass = 2.0, set = "gate2" }, [5] = { move = 5.0, pass = 2.6, set = "gate3" },
}

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "Open")
	self:NetworkVar("Bool", 1, "Locked")
	self:NetworkVar("Int", 0, "Wide")   -- the opening's width: 64 or 128; a gate's as its part says
	self:NetworkVar("Int", 1, "Kind")
	self:NetworkVar("Int", 2, "Tall")   -- a gate's height; 0 = a doorway's 96
end

function ENT:SGTall()
	local t = self:GetTall()
	return t > 0 and t or TALL
end

function ENT:SGIsGate() return GATE[self:GetKind()] ~= nil end

-- how far a tooth of a gate's two-part door reaches over the middle (the rule of tools/sg_models.py, gate_half)
local function tooth(w) return 8 + (w + 40) / 64 end

-- the sheet (6 thick to each side: a thin sheet lets a fast prop slip through between two ticks)
local function sheetBox(w, t) return Vector(-6, -w / 2, -t / 2), Vector(6, w / 2, t / 2) end
-- what stays solid of an open door: the strip over a doorway, the control panel on a gate's post
local function restBox(w, t, gate)
	if gate then return Vector(-18, -w / 2 - 12, -t / 2 + 34), Vector(18, -w / 2 + 2, -t / 2 + 60) end
	return Vector(-18, -w / 2, t / 2 + 1), Vector(18, w / 2, t / 2 + 7)
end
-- the bounds of a shut door: a doorway's sheet; a gate's sheet and its control panel in one box (what of it is
-- solid, TestCollision says)
local function shutBox(w, t, gate)
	if gate then return Vector(-18, -w / 2 - 12, -t / 2), Vector(18, w / 2, t / 2) end
	return sheetBox(w, t)
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		local w, kind = self:GetWide(), self:GetKind()
		local quad = kind == 1 and QUAD[w]
		if GATE[kind] then
			self:SetModel(("models/spacegrid/gate_%s_%d.mdl"):format(GATE[kind], w))
		else
			self:SetModel(kind == 2 and IRIS or quad and quad[1] or LEAF[w] or LEAF[64])
		end
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:SetCollisionBounds(shutBox(w, self:SGTall(), self:SGIsGate()))
		self:SetUseType(SIMPLE_USE)
		self:SetTrigger(true)
		self:DrawShadow(false)
		if WireLib then
			self.Inputs = WireLib.CreateInputs(self, { "Open", "Lock" })
			self.Outputs = WireLib.CreateOutputs(self, { "IsOpen", "IsLocked" })
		end
	end
end

-- Rays - shots, the tool gun's aim, the Wire tool - do not see the plain oriented box of an entity; only box-shaped
-- traces (a walking player) do. Measured 2026-11-14: every line trace went straight through a shut door and a
-- field that was on. So the entity answers traces itself: the same box, tested here, for rays and boxes alike.
local function hitBox(self, start, delta, isbox, extents, mn, mx)
	if isbox and extents then mn, mx = mn - extents, mx + extents end
	local hit, normal, frac = util.IntersectRayWithOBB(start, delta, self:GetPos(), self:GetAngles(), mn, mx)
	if hit then return { HitPos = hit, Fraction = frac, Normal = normal } end
end

function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	if mx.y > 0 and self:SGIsGate() then
		-- a shut gate: its bounds hold the sheet and the control panel; solid are those two, not the post between
		local w, t = self:GetWide(), self:SGTall()
		local a = hitBox(self, start, delta, isbox, extents, sheetBox(w, t))
		local b = hitBox(self, start, delta, isbox, extents, restBox(w, t, true))
		if a and b then return a.Fraction <= b.Fraction and a or b end
		return a or b
	end
	return hitBox(self, start, delta, isbox, extents, mn, mx)
end

if SERVER then
	local function out(self, name, on)
		if WireLib and self.Outputs then WireLib.TriggerOutput(self, name, on and 1 or 0) end
	end

	-- open = out of the way (at once, or when the leaves have drawn back far enough); closed = solid again (a gate:
	-- only when its leaves have nearly met - nobody walks into a wall he cannot see)
	function ENT:SGSetOpen(open)
		if self:GetOpen() == open then return end
		self:SetOpen(open)
		local kind = self:GetKind()
		local k = KIND[kind] or KIND[0]
		local w, t, gate = self:GetWide(), self:SGTall(), self:SGIsGate()
		local id = (self.SGMove or 0) + 1
		self.SGMove = id
		local function settle()
			if not IsValid(self) or self.SGMove ~= id then return end
			if open then self:SetCollisionBounds(restBox(w, t, gate)) else self:SetCollisionBounds(shutBox(w, t, gate)) end
		end
		local wait = open and k.pass or (gate and k.move - k.pass or 0)
		if wait > 0 then timer.Simple(wait, settle) else settle() end
		if not open then self.SGShutAt = CurTime() end
		-- (sh_sounds.lua; SGSet = a set named by what the door belongs to: an airlock's doors)
		local set = SpaceGrid.Sounds.door[self.SGSet or k.set or (kind == 2 and "hatch") or (kind == 1 and "quad") or (w >= 128 and "slide_wide" or "slide")]
		local level, vol = gate and 75 or 65, gate and 0.7 or 0.6
		if self.SGMoving then self:StopSound(self.SGMoving) end
		self.SGMoving = nil
		if set.first then self:EmitSound(set.first, level, 100, vol) end
		if set.hiss and open then self:EmitSound(set.hiss, level, 100, 0.5) end
		local snd = open and set.open or set.close
		self:EmitSound(snd, level, 100, vol)
		if set.stop then
			-- (a gate's moving sound runs on by itself: it is cut where the leaves come to rest)
			self.SGMoving = snd
			timer.Simple(k.move, function()
				if not IsValid(self) or self.SGMove ~= id then return end
				self:StopSound(snd)
				self.SGMoving = nil
				self:EmitSound(set.stop, level, 100, vol)
			end)
		end
		out(self, "IsOpen", open)
	end

	function ENT:SGSetLocked(locked)
		if self:GetLocked() == locked then return end
		self:SetLocked(locked)
		SpaceGrid.Play(self, SpaceGrid.Sounds.lock, 60, 0.5)
		out(self, "IsLocked", locked)
	end

	-- Use on a doorway's door: lock / unlock - for those who may build on the ship. Use on a gate: open / shut, for
	-- everybody (a locked gate stays shut: its lock is the wire input).
	function ENT:Use(ply)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if SpaceGrid.ToolHasUse(ply) then return end   -- a held Use is the tool's; a tap is a Use (sv_use.lua)
		if self:SGIsGate() then
			if self:GetLocked() then
				SpaceGrid.Play(self, SpaceGrid.Sounds.denied, 60, 0.5)
				return
			end
			self.SGWant = not self.SGWant
			return
		end
		local hull = self:GetParent()
		if IsValid(hull) and hull.CPPICanTool and hull:CPPICanTool(ply, "spacegrid_build") == false then
			SpaceGrid.Play(self, SpaceGrid.Sounds.denied, 60, 0.5)
			return
		end
		self:SGSetLocked(not self:GetLocked())
		SpaceGrid.Say(ply, self:GetLocked() and "say.door_locked" or "say.door_unlocked")
	end

	-- shut, it throws back props, vehicles and other ships
	function ENT:Touch(e)
		if self:GetOpen() then return end
		SpaceGrid.ThrowBack(self, e, self:GetWide(), self:SGTall())   -- (silent: no sound was chosen for it)
	end

	function ENT:TriggerInput(name, value)
		if name == "Open" then
			self.SGWireOpen = value ~= 0
			if self:SGIsGate() then self.SGWant = value ~= 0 end       -- a gate: the wire and the Use key move the same switch
		elseif name == "Lock" then
			self:SGSetLocked(value ~= 0)
		end
	end

	function ENT:OnRemove()
		if self.SGMoving then self:StopSound(self.SGMoving) end
		if WireLib and WireLib.Remove then WireLib.Remove(self) end
	end
else
	-- for pictures and for judging the animation: 0 .. 1 holds every door at that point of its way, -1 = off
	local cvFrac = CreateClientConVar("spacegrid_door_frac", "-1", false, false, "SpaceGrid: hold all doors at this point of their way (0 = shut, 1 = open, -1 = off)")
	local glow = Material("sprites/light_glow02_add")
	local RED = Color(255, 60, 40, 255)

	local function smooth(x)
		x = math.Clamp(x, 0, 1)
		return x * x * (3 - 2 * x)
	end

	function ENT:SGFraction()
		local k = KIND[self:GetKind()] or KIND[0]
		local want = self:GetOpen() and 1 or 0
		local f = self.SGFrac or want
		if f ~= want then f = math.Approach(f, want, FrameTime() / k.move) end
		self.SGFrac = f
		local held = cvFrac:GetFloat()
		if held >= 0 then return math.min(held, 1) end
		return f
	end

	-- One model drawn at several places in one frame (the two leaves of a door): the game keeps a model's bones
	-- for the frame, so without throwing them away each time every copy was drawn where the first one was set up
	-- - both leaves of a door in one place (the owner, 2026-11-15: an open door with a leaf still in the middle).
	local function drawAt(ent, pos, ang)
		ent:SetRenderOrigin(pos); ent:SetRenderAngles(ang)
		ent:InvalidateBoneCache(); ent:SetupBones(); ent:DrawModel()
	end

	function ENT:Draw()
		local w, tall = self:GetWide(), self:SGTall()
		if w <= 0 then return end
		if self.SGWide ~= w or self.SGHigh ~= tall then
			self.SGWide, self.SGHigh = w, tall
			self:SetRenderBounds(Vector(-20, -w, -tall / 2 - 2), Vector(20, w, tall / 2 + 10))
		end
		local f = self:SGFraction()
		local kind = self:GetKind()
		local ang, flip = self:GetAngles(), nil
		if kind == 1 and QUAD[w] then
			-- four leaves. First the bolts let go (the leaves part by a crack), then the side leaves draw back, the
			-- upper and the lower one follow. Nothing shows outside the doorway's frame: the leaves are cut off there
			-- (the lower one would hang out under the floor).
			local top = self.SGTop
			if not IsValid(top) then
				top = ClientsideModel(QUAD[w][2], RENDERGROUP_OPAQUE)
				if not IsValid(top) then return end
				top:SetNoDraw(true)
				self.SGTop = top
			end
			local crack = 1.5 * smooth(f / 0.15)
			local side = crack + smooth((f - 0.12) / 0.55) * (w / 2)
			local updown = crack + smooth((f - 0.35) / 0.65) * (TALL / 2)
			local pos = self:GetPos()
			local lf, up = -ang:Right(), ang:Up()
			flip = self:LocalToWorldAngles(Angle(0, 0, 180))
			local old = render.EnableClipping(true)
			render.PushCustomClipPlane(-lf, -lf:Dot(pos) - w / 2)
			render.PushCustomClipPlane(lf, lf:Dot(pos) - w / 2)
			render.PushCustomClipPlane(-up, -up:Dot(pos) - TALL / 2)
			render.PushCustomClipPlane(up, up:Dot(pos) - TALL / 2)
			drawAt(self, pos - lf * side, ang)
			drawAt(self, pos + lf * side, flip)
			drawAt(top, pos + up * updown, ang)
			drawAt(top, pos - up * updown, flip)
			render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane()
			render.EnableClipping(old)
		elseif kind == 2 then
			-- an iris: eight blades, their tips meeting in the middle. They give a twist (the lock lets go), then each
			-- draws back along its own middle line and turns on while it goes. They vanish into the wall; what would
			-- show beyond the wall is cut off.
			local twist = 8 * smooth(f / 0.2)
			local s = smooth((f - 0.12) / 0.88)
			local pos = self:GetPos()
			local lf, up = -ang:Right(), ang:Up()
			local old = render.EnableClipping(true)
			render.PushCustomClipPlane(-lf, -lf:Dot(pos) - 56)
			render.PushCustomClipPlane(lf, lf:Dot(pos) - 56)
			render.PushCustomClipPlane(-up, -up:Dot(pos) - 62)
			render.PushCustomClipPlane(up, up:Dot(pos) - 47)
			for k = 0, 7 do
				local a = self:LocalToWorldAngles(Angle(0, 0, k * 45 + twist + s * 30))
				drawAt(self, pos - a:Right() * (s * 50), a)
			end
			render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane()
			render.EnableClipping(old)
		elseif GATE[kind] then
			-- a gate's door. Whatever leaves the opening is cut off: it has gone into the beam, the posts, the deck.
			local pos = self:GetPos()
			local lf, up = -ang:Right(), ang:Up()
			local old = render.EnableClipping(true)
			render.PushCustomClipPlane(-lf, -lf:Dot(pos) - w / 2)
			render.PushCustomClipPlane(lf, lf:Dot(pos) - w / 2)
			render.PushCustomClipPlane(-up, -up:Dot(pos) - tall / 2)
			render.PushCustomClipPlane(up, up:Dot(pos) - tall / 2)
			if kind == 3 then
				-- the sheet of slats runs up: a slow start, an even run, a soft stop
				drawAt(self, pos + up * (smooth(f) * tall), ang)
			else
				-- two halves with teeth: the lock lets go (a crack shows), then they draw apart until the teeth are gone
				local crack = 2.5 * smooth(f / 0.08)
				local s = smooth((f - 0.06) / 0.94)
				flip = self:LocalToWorldAngles(Angle(0, 0, 180))
				if kind == 4 then
					local off = math.max(crack, s * (w / 2 + tooth(w)))
					drawAt(self, pos - lf * off, ang)
					drawAt(self, pos + lf * off, flip)
				else
					local off = math.max(crack, s * (tall / 2 + tooth(w)))
					drawAt(self, pos + up * off, ang)
					drawAt(self, pos - up * off, flip)
				end
			end
			render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane(); render.PopCustomClipPlane()
			render.EnableClipping(old)
		else
			-- two leaves: closed they meet in the middle; open each has slid its own width into the wall. What leaves
			-- the doorway is cut off: beside some doorways there is no wall to hide a leaf (the stairs' foot in the
			-- command deck - the owner, 2026-11-15: "the door did not open completely").
			-- (each leaf is a model of its own: the door's own model drawn twice at two places came out as one leaf
			-- standing in the middle of the open doorway in some doors - the owner, 2026-11-15)
			local s = smooth(f)
			local off = w / 4 + s * (w / 2 + 1)
			local pos = self:GetPos()
			local lf = -ang:Right()
			local leaves = self.SGLeaves
			if not leaves or not IsValid(leaves[1]) or not IsValid(leaves[2]) or leaves.w ~= w then
				if leaves then
					for _, m in ipairs(leaves) do if IsValid(m) then m:Remove() end end
				end
				leaves = { w = w }
				for i = 1, 2 do
					local m = ClientsideModel(LEAF[w] or LEAF[64], RENDERGROUP_OPAQUE)
					if not IsValid(m) then return end
					m:SetNoDraw(true)
					leaves[i] = m
				end
				self.SGLeaves = leaves
			end
			local old = render.EnableClipping(true)
			render.PushCustomClipPlane(-lf, -lf:Dot(pos) - w / 2)
			render.PushCustomClipPlane(lf, lf:Dot(pos) - w / 2)
			leaves[1]:SetPos(pos - lf * off); leaves[1]:SetAngles(ang)
			leaves[1]:SetupBones(); leaves[1]:DrawModel()
			leaves[2]:SetPos(pos + lf * off); leaves[2]:SetAngles(self:LocalToWorldAngles(Angle(0, 180, 0)))
			leaves[2]:SetupBones(); leaves[2]:DrawModel()
			render.PopCustomClipPlane(); render.PopCustomClipPlane()
			render.EnableClipping(old)
		end
		self:SetRenderOrigin(nil); self:SetRenderAngles(nil)
		self:InvalidateBoneCache(); self:SetupBones()
	end

	-- a locked door shows a red light on both faces: over a doorway, at the control panel of a gate
	function ENT:DrawTranslucent()
		if not self:GetLocked() then return end
		local w, tall = self:GetWide(), self:SGTall()
		local at = self:SGIsGate() and Vector(0, -w / 2 - 5, -tall / 2 + 66) or Vector(0, 0, tall / 2 + 4)
		render.SetMaterial(glow)
		for _, x in ipairs({ -19, 19 }) do
			at.x = x
			render.DrawSprite(self:LocalToWorld(at), 26, 26, RED)
		end
	end

	function ENT:OnRemove()
		if IsValid(self.SGTop) then self.SGTop:Remove() end
		for _, m in ipairs(self.SGLeaves or {}) do
			if IsValid(m) then m:Remove() end
		end
	end
end
