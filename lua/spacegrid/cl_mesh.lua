-- SpaceGrid: cheaper drawing of big ships. One model per part costs a handful of draw calls each: 512 parts halve the
-- frame rate, 2197 parts leave 35 fps (measured). So a ship that has been left alone for a moment is "baked":
-- the parts of one block of space (CELL units) become a few merged meshes, one per material, and their single
-- models go away. A part that is touched (added to, taken off) turns its block back into single models at once,
-- so building never waits for a bake; baking runs in small slices of a frame.
-- Switch: spacegrid_mesh 0 / 1 (client), on by default: measured 45 -> 249 fps at 2197 parts, 148 -> 254 fps
-- on 256 real kit parts, close-up pictures compared with the single models.
local cv = CreateClientConVar("spacegrid_mesh", "1", true, false, "SpaceGrid: draw ships that are left alone as a few merged meshes (1) or one model per part (0)")

local CELL = 512         -- a block of space that is baked as one (64 S cells)
local MAXV = 24000       -- vertices per mesh (the engine's limit is 65535; smaller = shorter single hitch)
local CALM = 1.5         -- seconds without a change before a hull is baked
local SLICE = 0.003      -- seconds of baking per frame
local ROOT_MODEL = "models/props_junk/popcan01a.mdl"
local TRANSLUCENT = 2097152   -- MATERIAL_VAR_TRANSLUCENT

-- the triangles of a part model, per material (kept for the session)
local modelCache = {}
local function modelData(model, skin)
	local id = model .. "#" .. (skin or 0)
	local d = modelCache[id]
	if d == nil then
		d = false
		local meshes = util.GetModelMeshes(model, 0, 0, skin or 0)
		if meshes then
			d = {}
			for _, m in ipairs(meshes) do
				local mat = Material(m.material)
				if mat and not mat:IsError() and m.triangles and #m.triangles > 0 then
					d[#d + 1] = { name = m.material, mat = mat, tris = m.triangles, trans = bit.band(mat:GetInt("$flags") or 0, TRANSLUCENT) ~= 0 }
				end
			end
			if #d == 0 then d = false end
		end
		modelCache[id] = d
	end
	return d
end

local WHITE = Color(255, 255, 255, 255)

-- the direction in which the texture's u grows across a triangle (model space), as { x, y, z }
local function faceTangent(a, b, c)
	if not (a and b and c) then return { 1, 0, 0 } end
	local e1x, e1y, e1z = b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z
	local e2x, e2y, e2z = c.pos.x - a.pos.x, c.pos.y - a.pos.y, c.pos.z - a.pos.z
	local dv1, dv2 = (b.v or 0) - (a.v or 0), (c.v or 0) - (a.v or 0)
	local det = ((b.u or 0) - (a.u or 0)) * dv2 - ((c.u or 0) - (a.u or 0)) * dv1
	if math.abs(det) < 1e-12 then return { e1x, e1y, e1z } end
	return { (e1x * dv2 - e2x * dv1) / det, (e1y * dv2 - e2y * dv1) / det, (e1z * dv2 - e2z * dv1) / det }
end

local floor = math.floor
local function keyOf(pos)
	-- (+ 0: a part at -0 must not get a block of its own)
	return (floor(pos.x / CELL) + 0) .. "," .. (floor(pos.y / CELL) + 0) .. "," .. (floor(pos.z / CELL) + 0)
end

-- A block's meshes go: their entities stop drawing at once and are removed; the meshes themselves are freed a
-- moment later. (Freed at once, the game could still draw one in the same frame - the full suite crashed the game
-- with an access violation four times, whenever a part was added to a baked block.)
local function dropChunk(c)
	for _, e in ipairs(c.ents) do
		if IsValid(e) then
			e.SGRender = nil
			e:SetNoDraw(true)
			e:Remove()
		end
	end
	local meshes = c.meshes
	c.ents, c.meshes = {}, {}
	timer.Simple(0.5, function()
		for _, im in ipairs(meshes) do
			if im and im.IsValid and im:IsValid() then im:Destroy() end
		end
	end)
end

-- a baked block back to single models
local function unbake(hull, key)
	local c = hull.SGChunks and hull.SGChunks[key]
	if not c then return end
	hull.SGChunks[key] = nil
	dropChunk(c)
	for pid in pairs(c.pids) do hull.SGBaked[pid] = nil end
	for pid in pairs(c.pids) do SpaceGrid.SyncPart(hull, pid) end
end

-- cl_hull.lua calls this for every part it makes, moves or removes
function SpaceGrid.MeshTouch(hull, pid)
	hull.SGBaked = hull.SGBaked or {}
	hull.SGChunks = hull.SGChunks or {}
	hull.SGChange = (hull.SGChange or 0) + 1
	hull.SGCalmAt = RealTime() + CALM
	hull.SGLoose = true
	local key = hull.SGBaked[pid]
	if key then unbake(hull, key) end
end

function SpaceGrid.MeshUnbakeAll(hull)
	for key in pairs(hull.SGChunks or {}) do unbake(hull, key) end
end

-- for tests and for the curious: what is baked
function SpaceGrid.MeshInfo(hull)
	local chunks, meshes, baked, loose = 0, 0, 0, 0
	for _, c in pairs(hull.SGChunks or {}) do
		chunks = chunks + 1
		meshes = meshes + #c.meshes
	end
	for _ in pairs(hull.SGBaked or {}) do baked = baked + 1 end
	for _, m in pairs(hull.SGModels or {}) do
		if IsValid(m) then loose = loose + 1 end
	end
	return { chunks = chunks, meshes = meshes, baked = baked, loose = loose }
end

-- ---- the baker (a coroutine that gives the frame back when its slice is used up)
local deadline = 0
local function breathe()
	if SysTime() > deadline then coroutine.yield() end
end

local function bakeChunk(hull, key, change)
	local st = hull.SG
	local ix, iy, iz = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
	local cx, cy, cz = (tonumber(ix) + 0.5) * CELL, (tonumber(iy) + 0.5) * CELL, (tonumber(iz) + 0.5) * CELL
	local groups, order, pids = {}, {}, {}
	local built = { ents = {}, meshes = {}, pids = pids }
	local mn, mx = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)

	local function flush(g)
		if g.n == 0 then return end
		local im = Mesh(g.mat)
		im:BuildFromTriangles(g.verts)
		built.meshes[#built.meshes + 1] = im
		built.draw = built.draw or {}
		built.draw[#built.draw + 1] = { im = im, mat = g.mat, trans = g.trans }
		g.verts, g.n = {}, 0
		deadline = 0   -- building a mesh is the long step: give the frame back after it
		breathe()
	end

	-- the block's parts first, in one go: the list may change while the baker is waiting for its next slice
	local list = {}
	for _, p in pairs(st.parts) do
		if keyOf(p.pos) == key then list[#list + 1] = p end
	end
	for _, p in ipairs(list) do
		do
			local pid = p.id
			local def = SpaceGrid.Parts[p.t]
			local data = def and modelData(def.model, def.skin)
			-- a part whose model cannot be read stays a single model
			if data then
				pids[pid] = true
				local f, r, u = p.ang:Forward(), p.ang:Right(), p.ang:Up()
				local fx, fy, fz, rx, ry, rz, ux, uy, uz = f.x, f.y, f.z, r.x, r.y, r.z, u.x, u.y, u.z
				local px, py, pz = p.pos.x - cx, p.pos.y - cy, p.pos.z - cz
				mn.x, mn.y, mn.z = math.min(mn.x, p.mn.x - cx), math.min(mn.y, p.mn.y - cy), math.min(mn.z, p.mn.z - cz)
				mx.x, mx.y, mx.z = math.max(mx.x, p.mx.x - cx), math.max(mx.y, p.mx.y - cy), math.max(mx.z, p.mx.z - cz)
				for _, md in ipairs(data) do
					local g = groups[md.name]
					if not g then
						g = { mat = md.mat, trans = md.trans, verts = {}, n = 0 }
						groups[md.name] = g
						order[#order + 1] = g
					end
					local verts, n = g.verts, g.n
					local tris = md.tris
					local faceT
					for i = 1, #tris do
						-- A mesh may not pass the engine's limit of 65535 corners: the game crashed when a block with the
						-- command deck and the great glass dome grew one material's mesh past it (the split used to come
						-- only between two whole models). So: split between two triangles.
						if i % 3 == 1 and n + 3 > MAXV then
							g.n = n
							flush(g)
							if not IsValid(hull) or hull.SGChange ~= change then dropChunk(built) return false end
							verts, n = g.verts, 0
						end
						local v = tris[i]
						local x, y, z = v.pos.x, v.pos.y, v.pos.z
						local nx, ny, nz = v.normal.x, v.normal.y, v.normal.z
						-- The bump-mapped materials need a tangent on every vertex (a missing one draws black). Taken
						-- from the model where it has one, else from the triangle's texture directions; then made
						-- square to the normal.
						if i % 3 == 1 then faceT = faceTangent(tris[i], tris[i + 1], tris[i + 2]) end
						local tx, ty, tz, tw = faceT[1], faceT[2], faceT[3], 1
						local ud, vt = v.userdata, v.tangent
						if ud and ud[1] * ud[1] + ud[2] * ud[2] + ud[3] * ud[3] > 0.25 then
							tx, ty, tz = ud[1], ud[2], ud[3]
							if ud[4] and ud[4] ~= 0 then tw = ud[4] end
						elseif vt and vt.x * vt.x + vt.y * vt.y + vt.z * vt.z > 0.25 then
							tx, ty, tz = vt.x, vt.y, vt.z
						end
						local d = tx * nx + ty * ny + tz * nz
						tx, ty, tz = tx - nx * d, ty - ny * d, tz - nz * d
						local l = math.sqrt(tx * tx + ty * ty + tz * tz)
						if l < 0.001 then
							if math.abs(nz) < 0.9 then tx, ty, tz = -ny, nx, 0 else tx, ty, tz = 0, -nz, ny end
							l = math.sqrt(tx * tx + ty * ty + tz * tz)
						end
						tx, ty, tz = tx / l, ty / l, tz / l
						n = n + 1
						verts[n] = {
							pos = Vector(px + fx * x - rx * y + ux * z, py + fy * x - ry * y + uy * z, pz + fz * x - rz * y + uz * z),
							normal = Vector(fx * nx - rx * ny + ux * nz, fy * nx - ry * ny + uy * nz, fz * nx - rz * ny + uz * nz),
							u = v.u, v = v.v, color = WHITE,
							userdata = { fx * tx - rx * ty + ux * tz, fy * tx - ry * ty + uy * tz, fz * tx - rz * ty + uz * tz, tw },
						}
						if i % 600 == 0 then
							g.n = n
							breathe()
							if not IsValid(hull) or hull.SGChange ~= change then dropChunk(built) return false end
						end
					end
					g.n = n
				end
			end
		end
	end
	for _, g in ipairs(order) do flush(g) end
	if not IsValid(hull) or hull.SGChange ~= change then dropChunk(built) return false end
	if not built.draw then return true end

	-- one helper entity per mesh; it stands in the block's middle so the game lights the block from there
	local centre = Vector(cx, cy, cz)
	for _, d in ipairs(built.draw) do
		local e = ents.CreateClientside("spacegrid_mesh")
		if IsValid(e) then
			e:SetModel(ROOT_MODEL)
			e:SetPos(hull:LocalToWorld(centre))
			e:SetAngles(hull:GetAngles())
			e:SetParent(hull)
			e:Spawn()
			e:SetLocalPos(centre)
			e:SetLocalAngles(angle_zero)
			e.SGRender = { Mesh = d.im, Material = d.mat }
			e.SGTrans = d.trans
			e:SetRenderBounds(mn, mx)
			e:DrawShadow(false)
			e:SetNoDraw(hull:IsDormant())
			built.ents[#built.ents + 1] = e
		end
	end
	built.draw = nil
	-- swap: the old bake of this block (if any) and the single models of its parts go
	local old = hull.SGChunks[key]
	if old then
		dropChunk(old)
		for pid in pairs(old.pids) do hull.SGBaked[pid] = nil end
	end
	hull.SGChunks[key] = built
	for _, e in ipairs(built.ents) do SpaceGrid.OwnModel(e, hull, built, key, centre, angle_zero) end   -- (cl_hull.lua: the sweep)
	for pid in pairs(pids) do
		hull.SGBaked[pid] = key
		local m = hull.SGModels[pid]
		if IsValid(m) then m:Remove() end
		hull.SGModels[pid] = nil
	end
	return true
end

local function bakeHull(hull)
	local change = hull.SGChange
	local keys = {}
	for pid, p in pairs(hull.SG.parts) do
		if not hull.SGBaked[pid] then keys[keyOf(p.pos)] = true end
	end
	for key in pairs(keys) do
		if not IsValid(hull) or hull.SGChange ~= change then return end
		if not bakeChunk(hull, key, change) then return end
		breathe()
	end
	if IsValid(hull) and hull.SGChange == change then hull.SGLoose = false end
end

local co, nextLook = nil, 0
hook.Add("Think", "SpaceGrid.MeshBake", function()
	if not cv:GetBool() then return end
	if co then
		deadline = SysTime() + SLICE
		local ok, err = coroutine.resume(co)
		if not ok then ErrorNoHalt("[spacegrid] mesh bake: " .. tostring(err) .. "\n") end
		if coroutine.status(co) == "dead" then co = nil end
		return
	end
	local now = RealTime()
	if now < nextLook then return end
	nextLook = now + 0.25
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if hull.SGLoose and hull.SG and hull.SGModels and hull.SGBaked and (hull.SGCalmAt or 0) < now and not hull:IsDormant() then
			co = coroutine.create(bakeHull)
			deadline = SysTime() + SLICE
			local ok, err = coroutine.resume(co, hull)
			if not ok then
				ErrorNoHalt("[spacegrid] mesh bake: " .. tostring(err) .. "\n")
				hull.SGLoose = false
			end
			if coroutine.status(co) == "dead" then co = nil end
			return
		end
	end
end)

cvars.AddChangeCallback("spacegrid_mesh", function(_, _, new)
	for _, hull in ipairs(ents.FindByClass("spacegrid_hull")) do
		if tonumber(new) == 1 then
			if hull.SGBaked then hull.SGLoose, hull.SGCalmAt = true, 0 end
		else
			SpaceGrid.MeshUnbakeAll(hull)
		end
	end
end, "SpaceGrid.Mesh")

-- out of sight with the hull, gone with the hull
hook.Add("NotifyShouldTransmit", "SpaceGrid.Mesh", function(ent, should)
	if not ent.SpaceGridHull or not ent.SGChunks then return end
	for _, c in pairs(ent.SGChunks) do
		for _, e in ipairs(c.ents) do
			if IsValid(e) then e:SetNoDraw(not should) end
		end
	end
end)

hook.Add("EntityRemoved", "SpaceGrid.Mesh", function(ent)
	if not ent.SpaceGridHull or not ent.SGChunks then return end
	local chunks = ent.SGChunks
	-- (a full update removes and re-creates the entity: only clean up when it is really gone)
	timer.Simple(0, function()
		if IsValid(ent) then return end
		for _, c in pairs(chunks) do dropChunk(c) end
	end)
end)
