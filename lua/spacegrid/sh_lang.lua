-- SpaceGrid: its texts in the game's language. One file for each language in lua/spacegrid/lang/ (key -> text; the
-- same twelve languages as PowerGrid), written by tools/sg_lang.py (en) and by hand / translators (the others).
-- SpaceGrid.T(key) gives a text in this player's language, in English where his language has none. A part's name:
-- SpaceGrid.PartName(def). The server knows no player's language: it sends a key (SpaceGrid.Say) and the player's own
-- game puts the words to it.
SpaceGrid.LangCodes = { "en", "cs", "de", "es-es", "et", "fr", "hr", "hu", "nl", "ru", "sv-se", "tr" }
SpaceGrid.Lang = {}
for _, code in ipairs(SpaceGrid.LangCodes) do
	local f = "spacegrid/lang/" .. code .. ".lua"
	if file.Exists(f, "LUA") then
		if SERVER then AddCSLuaFile(f) end
		local ok, t = pcall(include, f)
		if ok and istable(t) then SpaceGrid.Lang[code] = t end
	end
end

local function current()
	if CLIENT then
		local cv = GetConVar("gmod_language")
		return cv and string.lower(cv:GetString()) or "en"
	end
	return "en"
end

function SpaceGrid.T(key, lang)
	lang = lang or current()
	local t = SpaceGrid.Lang[lang] or SpaceGrid.Lang[string.sub(lang, 1, 2)]
	local s = t and t[key]
	if s == nil or s == "" then
		local en = SpaceGrid.Lang.en
		s = en and en[key]
	end
	return s or key
end

function SpaceGrid.PartName(def, lang)
	local key = "part." .. tostring(def.id)
	local s = SpaceGrid.T(key, lang)
	if s == key then return def.name or key end
	return s
end

-- a reason the core gave (its own English words) as a key: "no free port of that size here" -> why.no_free_port_...
function SpaceGrid.WhyKey(reason)
	return "why." .. string.Trim(string.gsub(string.lower(tostring(reason)), "[^%a%d]+", "_"), "_")
end

if SERVER then
	util.AddNetworkString("SpaceGrid.Say")
	-- a chat line for one player, in his language: key = a text of the language files, further values fill its %s.
	-- A value that starts with "@" is itself a key ("@why.no_room").
	function SpaceGrid.Say(ply, key, ...)
		if not IsValid(ply) then return end
		local args = { ... }
		net.Start("SpaceGrid.Say")
		net.WriteString(key)
		net.WriteUInt(#args, 4)
		for _, a in ipairs(args) do net.WriteString(tostring(a)) end
		net.Send(ply)
	end
	-- (the same for a reason of the core)
	function SpaceGrid.SayWhy(ply, key, reason)
		SpaceGrid.Say(ply, key, "@" .. SpaceGrid.WhyKey(reason or "does not fit here") .. "|" .. tostring(reason or ""))
	end
else
	net.Receive("SpaceGrid.Say", function()
		local key = net.ReadString()
		local args = {}
		for i = 1, net.ReadUInt(4) do
			local a = net.ReadString()
			if string.sub(a, 1, 1) == "@" then
				-- "@key|fallback": the text of the key, or - a reason nobody has translated - the fallback as it is
				local k, fb = string.match(a, "^@([^|]*)|?(.*)$")
				local s = SpaceGrid.T(k)
				a = (s ~= k and s) or (fb ~= "" and fb) or k
			end
			args[i] = a
		end
		local ok, line = pcall(string.format, SpaceGrid.T(key), unpack(args))
		chat.AddText(Color(235, 190, 90), "SpaceGrid: ", Color(235, 235, 235), ok and line or SpaceGrid.T(key))
	end)
end
