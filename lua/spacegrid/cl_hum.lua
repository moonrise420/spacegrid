-- SpaceGrid: the quiet sounds of machine pieces - the machine block, the column of light, the fan, a control desk.
-- A part whose data has `hum = { kind, pos }` is heard by a player who stands near it. Parts are no entities, so
-- the sound hangs on an unseen helper that rides on the ship at the part's place. Only the few nearest ones sound.
-- Switch: spacegrid_hum 0 / 1 (client).
local cv = CreateClientConVar("spacegrid_hum", "1", true, false, "SpaceGrid: quiet machine sounds near machine pieces (1) or none (0)")

local MAX = 4          -- so many at once, the nearest
local RANGE = 420      -- heard from this far
local LEVEL = 55       -- quiet: gone after a room or two
local HELPER = "models/props_junk/popcan01a.mdl"

local active = {}      -- "hull index:part id" -> { ent, patch, snd, again }

local function stop(key)
	local a = active[key]
	if not a then return end
	if a.patch then a.patch:Stop() end
	if IsValid(a.ent) then a.ent:Remove() end
	active[key] = nil
end

-- for tests and the curious: how many are sounding
function SpaceGrid.HumCount()
	return table.Count(active)
end

timer.Create("SpaceGrid.Hum", 0.5, 0, function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local want = {}
	local sounds = SpaceGrid.Sounds and SpaceGrid.Sounds.hum
	if cv:GetBool() and sounds then
		local eye, found = ply:EyePos(), {}
		for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
			local st, mn, mx = hull.SG, hull.SGMins, hull.SGMaxs
			if st and mn and mx and not hull:IsDormant() then
				local r = (mx - mn):Length() / 2 + RANGE
				if hull:LocalToWorld((mn + mx) / 2):DistToSqr(eye) < r * r then
					for pid, p in pairs(st.parts) do
						local h = SpaceGrid.Parts[p.t].hum
						local snd = h and sounds[h.kind]
						if snd then
							local lp = LocalToWorld(h.pos, angle_zero, p.pos, p.ang)
							local d = hull:LocalToWorld(lp):DistToSqr(eye)
							if d < RANGE * RANGE then found[#found + 1] = { key = hull:EntIndex() .. ":" .. pid, d = d, hull = hull, lp = lp, snd = snd } end
						end
					end
				end
			end
		end
		table.sort(found, function(a, b) return a.d < b.d end)
		for i = 1, math.min(MAX, #found) do want[found[i].key] = found[i] end
	end
	for key, a in pairs(active) do
		local f = want[key]
		if not f or not IsValid(a.ent) or a.snd ~= f.snd then stop(key) end
	end
	local now = CurTime()
	for key, f in pairs(want) do
		local a = active[key]
		if not a then
			local e = ClientsideModel(HELPER, RENDERGROUP_OTHER)
			if IsValid(e) then
				e:SetNoDraw(true)
				e:SetParent(f.hull)
				e:SetLocalPos(f.lp)
				local patch = CreateSound(e, f.snd)
				patch:SetSoundLevel(LEVEL)
				patch:PlayEx(0.3, 100)
				active[key] = { ent = e, patch = patch, snd = f.snd, again = 0 }
			end
		elseif not a.patch:IsPlaying() then
			-- a recording that does not loop by itself (a desk's beeps) comes again after a pause
			if a.again == 0 then
				a.again = now + math.Rand(4, 9)
			elseif now > a.again then
				a.again = 0
				a.patch:PlayEx(0.3, 100)
			end
		end
	end
end)
