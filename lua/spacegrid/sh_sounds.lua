-- SpaceGrid: every sound of the kit in one place. All are recordings that ship with the game - the addon only names
-- them. The author chose them by ear (its database document board/picks). His rule: where he chose nothing
-- there is no sound - so a use without an entry here stays silent, and nothing plays a sound that is not in this
-- table.
SpaceGrid.Sounds = {
	-- one set for each kind of door: first = with the first movement (bolts), open / close = the movement,
	-- stop = when it has come to rest, hiss = air (airlock)
	door = {
		slide = { open = "doors/doormove2.wav", close = "doors/doormove2.wav" },            -- as Spacebuild's sliding doors
		slide_wide = { open = "doors/doormove3.wav", close = "doors/doormove3.wav" },
		quad = { first = "doors/metal_stop1.wav", open = "doors/heavy_metal_move1.wav", close = "doors/heavy_metal_move1.wav" },
		-- for the kinds to come
		hatch = { open = "doors/door_metal_medium_open1.wav", close = "doors/door_metal_medium_close1.wav" },
		gate = { open = "doors/garage_move1.wav", close = "doors/garage_move1.wav", stop = "doors/garage_stop1.wav" },
		gate2 = { open = "doors/drawbridge_move1.wav", close = "doors/drawbridge_move1.wav", stop = "doors/drawbridge_stop1.wav" },
		gate3 = { open = "ambient/machines/floodgate_move_short1.wav", close = "ambient/machines/floodgate_move_short1.wav", stop = "ambient/machines/floodgate_stop1.wav" },
		airlock = { open = "doors/door_metal_large_open1.wav", close = "doors/door_metal_large_chamber_close1.wav", hiss = "ambient/gas/steam2.wav" },
		fold = { open = "ambient/machines/wall_ambient1.wav", close = "ambient/machines/wall_ambient1.wav" },
		-- swinging door: nothing chosen
	},
	lock = "buttons/lever7.wav",          -- locking and unlocking a door
	denied = "buttons/button8.wav",       -- Use by someone who may not
	field = {
		on = "ambient/levels/citadel/zapper_warmup1.wav",
		off = "ambient/levels/citadel/weapon_disintegrate1.wav",
		hum = "ambient/levels/citadel/field_loop1.wav",      -- a loop, while the field is on
		hit = "ambient/energy/weld1.wav",                    -- something is thrown back
	},
	tool = {
		place = "physics/metal/metal_solid_impact_hard1.wav",
		take = "doors/vent_open2.wav",
		join = "doors/drawbridge_stop1.wav",
		cut = "doors/vent_open1.wav",
	},
	-- quiet loops heard standing next to a piece (cl_hum.lua). Sleep pods and the ship's own background: nothing chosen.
	hum = {
		machine = "ambient/machines/lab_loop1.wav",
		column = "ambient/levels/labs/machine_ring_resonance_loop1.wav",
		fan = "ambient/machines/city_ventpump_loop1.wav",
		desk = "ambient/machines/combine_terminal_idle1.wav",
	},
	-- chosen for parts that do not exist yet
	light = "buttons/button1.wav",
	lift = { move = "plats/elevator_move_loop1.wav", stop = "plats/elevator_stop1.wav" },
	gear = { out = "npc/turret_floor/deploy.wav", back = "npc/turret_floor/retract.wav" },
	breach = "ambient/levels/labs/electric_explosion1.wav",
	alarm = "ambient/alarms/combine_bank_alarm_loop4.wav",
}

-- play one of them on an entity, or at a place; no file = silence
function SpaceGrid.Play(where, snd, level, volume)
	if not snd then return end
	if isvector(where) then
		sound.Play(snd, where, level or 70, 100, volume or 0.6)
	elseif IsValid(where) then
		where:EmitSound(snd, level or 65, 100, volume or 0.6)
	end
end
