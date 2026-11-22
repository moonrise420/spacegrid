-- SpaceGrid: the navigation console's screen. It belongs to a part of a hull (lua/spacegrid/sv_devices.lua makes
-- and removes it with the part) and is parented to the hull. It writes where the ship is and how it moves: a compass
-- with the heading, the position, speed, height over the ground, pitch and roll. Nothing to set up, no Wiremod
-- needed. With Wiremod the same numbers are outputs: Position, Velocity, Angle, Heading, Pitch, Roll, Speed, Altitude.
-- Heading: 0 = the map's +Y ("north"), 90 = +X, as StarCore's core gives it. The ship's front is the way its first
-- pilot seat looks (a ship without one: the hull's own front).
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "SpaceGrid Navigation Console"
ENT.Author = "SpaceGrid"
ENT.Spawnable = false
ENT.DoNotDuplicate = true      -- a pasted hull makes its devices itself
ENT.PhysgunDisabled = true
ENT.SpaceGridDoor = true       -- for the build tool and the Remover it stands for its ship, as a door does
ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Wide")
	self:NetworkVar("Int", 1, "Tall")
	self:NetworkVar("Float", 0, "Fwd")   -- the ship's front as a turn in hull space
end

function ENT:Initialize()
	self:EnableCustomCollisions(true)
	if SERVER then
		self:SetModel("models/spacegrid/door_leaf_s.mdl")   -- (never drawn: the screen is drawn as a sheet)
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_OBB)
		self:DrawShadow(false)
		local w, h = self:GetWide(), self:GetTall()
		self:SetCollisionBounds(Vector(-1, -w / 2, -h / 2), Vector(1, w / 2, h / 2))
		if WireLib then
			self.Outputs = WireLib.CreateOutputs(self, { "Position [VECTOR]", "Velocity [VECTOR]", "Angle [ANGLE]", "Heading", "Pitch", "Roll", "Speed", "Altitude" })
		end
	end
end

-- (rays - the Wire tool's aim - do not see the plain box of an entity that rides on a ship: see spacegrid_field.lua)
function ENT:TestCollision(start, delta, isbox, extents)
	local mn, mx = self:GetCollisionBounds()
	return SpaceGrid.BoxHit(self, start, delta, isbox, extents, mn, mx)   -- (a touching player goes free: sh_core.lua)

end

-- the numbers: position, the ship's angle, heading (0..360), pitch (nose up = positive), roll, height over the ground
-- (-1 = no ground below)
function ENT:SGNav()
	local hull = self:GetParent()
	if not IsValid(hull) then hull = self end
	local pos = self:GetPos()
	local ang = hull:LocalToWorldAngles(Angle(0, self:GetFwd(), 0))
	local tr = util.TraceLine({ start = pos, endpos = pos - Vector(0, 0, 60000), mask = MASK_SOLID_BRUSHONLY })
	return pos, ang, (90 - ang.y) % 360, -math.NormalizeAngle(ang.p), math.NormalizeAngle(ang.r), tr.Hit and not tr.HitSky and (pos.z - tr.HitPos.z) or -1
end

if SERVER then
	function ENT:Think()
		if self.Outputs then
			local pos, ang, heading, pitch, roll, alt = self:SGNav()
			local hull = self:GetParent()
			local phys = IsValid(hull) and (SpaceGrid.Body and SpaceGrid.Body(hull) or hull:GetPhysicsObject())   -- (the keel: sv_keel.lua)
			local vel = IsValid(phys) and phys:IsMotionEnabled() and phys:GetVelocity() or vector_origin
			WireLib.TriggerOutput(self, "Position", pos)
			WireLib.TriggerOutput(self, "Velocity", vel)
			WireLib.TriggerOutput(self, "Angle", ang)
			WireLib.TriggerOutput(self, "Heading", heading)
			WireLib.TriggerOutput(self, "Pitch", pitch)
			WireLib.TriggerOutput(self, "Roll", roll)
			WireLib.TriggerOutput(self, "Speed", vel:Length())
			WireLib.TriggerOutput(self, "Altitude", alt)
		end
		self:NextThink(CurTime() + 0.25)
		return true
	end
	return
end

-- ---------------------------------------------------------------------------------------------------------------
-- The screen: 10 dots to a unit, so 840 x 440 dots. Large letters on a plain dark ground (the owner,:
-- "navigation console can't be read good" - the first one wrote small numbers over the model's busy screen picture).
surface.CreateFont("SpaceGridNavS", { font = "Roboto", size = 38, weight = 600, extended = true })
surface.CreateFont("SpaceGridNavR", { font = "Roboto", size = 48, weight = 700, extended = true })
surface.CreateFont("SpaceGridNavM", { font = "Roboto", size = 60, weight = 700, extended = true })
surface.CreateFont("SpaceGridNavL", { font = "Roboto", size = 128, weight = 800, extended = true })

local VALUE, GOLD, LABEL, WHITE, LINE = Color(150, 220, 255), Color(245, 185, 80), Color(165, 195, 225), Color(255, 255, 255), Color(60, 105, 145)
local SEE = 1400 * 1400   -- written only for who stands this near

function ENT:Draw() end

-- Distances and speeds in the unit the player chose for all our addons (PowerGrid's agp_unit_distance: metres, feet
-- or game units; 1 game unit = 1 inch). Without PowerGrid: metres and km/h. (Wire outputs stay in game units.)
local function dist(u, short)
	if AGP and AGP.Units and AGP.Units.Distance then return AGP.Units.Distance(u, short) end
	return string.Comma(math.Round(u * 0.0254)) .. (short and "" or " m")
end
local function distName()
	if AGP and AGP.Units and AGP.Units.DistanceName then return AGP.Units.DistanceName() end
	return "m"
end
local function speedText(ups)
	if AGP and AGP.Units and AGP.Units.Speed then return AGP.Units.Speed(ups) end
	return math.floor(ups * 0.09144) .. " km/h"
end

function ENT:DrawTranslucent()
	local eye = EyePos()
	local pos0, fwd = self:GetPos(), self:GetForward()
	if eye:DistToSqr(pos0) > SEE or (eye - pos0):Dot(fwd) <= 0 then return end
	local w, h = self:GetWide() * 10, self:GetTall() * 10
	local pos, _, heading, pitch, roll, alt = self:SGNav()
	-- the speed: from the way the screen has moved (a client does not know a ship's speed by itself)
	local now = RealTime()
	if self.SGAt and now - self.SGAt < 0.5 then
		if now - self.SGAt > 0.1 then
			local v = (pos - self.SGPos) / (now - self.SGAt)
			self.SGVel = self.SGVel and LerpVector(0.5, self.SGVel, v) or v
			self.SGPos, self.SGAt = pos, now
		end
	else
		self.SGPos, self.SGAt, self.SGVel = pos, now, vector_origin
	end
	local speed = (self.SGVel or vector_origin):Length()
	if speed < 1 then speed = 0 end

	local a = self:GetAngles()
	a:RotateAroundAxis(a:Up(), 90)
	a:RotateAroundAxis(a:Forward(), 90)
	local T = SpaceGrid.T
	cam.Start3D2D(pos0 + fwd * 0.25 + self:GetRight() * (w / 20) + self:GetUp() * (h / 20), a, 0.1)
	surface.SetDrawColor(4, 9, 18, 255)
	surface.DrawRect(0, 0, w, h)
	-- the compass: a band of marks that slides over a fixed pointer, five dots to a degree
	local cx, per, base = w / 2, 5, 104
	local letters = string.Explode(" ", T("nav.compass"))
	surface.SetDrawColor(LINE)
	surface.DrawRect(24, base, w - 48, 3)
	for d = math.floor((heading - 80) / 10) * 10, heading + 80, 10 do
		local x = cx + (d - heading) * per
		if x > 40 and x < w - 40 then
			local deg = d % 360
			local main = deg % 90 == 0
			surface.SetDrawColor(main and GOLD or VALUE)
			surface.DrawRect(x - 2, base - (main and 26 or 14), 4, main and 26 or 14)
			if main then
				draw.SimpleText(letters[deg / 90 + 1] or "", "SpaceGridNavM", x, 44, GOLD, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			elseif deg % 30 == 0 then
				draw.SimpleText(tostring(deg), "SpaceGridNavS", x, 52, VALUE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			end
		end
	end
	surface.SetDrawColor(WHITE)
	surface.DrawRect(cx - 3, base - 4, 6, 26)
	-- the heading, very large
	draw.SimpleText(T("nav.heading"), "SpaceGridNavS", 36, 150, LABEL)
	draw.SimpleText(("%03d°"):format(math.Round(heading) % 360), "SpaceGridNavL", cx + 14, 116, WHITE, TEXT_ALIGN_CENTER)
	surface.SetDrawColor(LINE)
	surface.DrawRect(24, 244, w - 48, 3)
	surface.DrawRect(cx - 1, 256, 3, h - 272)
	-- left: where
	for i, q in ipairs({ { "X", pos.x }, { "Y", pos.y }, { "Z", pos.z } }) do
		local y = 252 + (i - 1) * 60
		draw.SimpleText(q[1], "SpaceGridNavM", 36, y, GOLD)
		draw.SimpleText(dist(q[2], true), "SpaceGridNavM", cx - 28 - 52, y, VALUE, TEXT_ALIGN_RIGHT)
		draw.SimpleText(distName(), "SpaceGridNavS", cx - 28, y + 14, LABEL, TEXT_ALIGN_RIGHT)
	end
	-- right: how
	local rows = {
		{ T("nav.speed"), speedText(speed) },
		{ T("nav.altitude"), alt >= 0 and dist(alt) or "-" },
		{ T("nav.pitch"), ("%d°"):format(math.Round(pitch)) },
		{ T("nav.roll"), ("%d°"):format(math.Round(roll)) },
	}
	for i, q in ipairs(rows) do
		local y = 250 + (i - 1) * 46
		draw.SimpleText(q[1], "SpaceGridNavS", cx + 26, y + 6, LABEL)
		draw.SimpleText(q[2], "SpaceGridNavR", w - 36, y, VALUE, TEXT_ALIGN_RIGHT)
	end
	cam.End3D2D()
end
