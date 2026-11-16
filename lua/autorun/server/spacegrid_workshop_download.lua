-- Players who join a server download this addon's models, materials and sounds from the Steam Workshop before they
-- spawn (resource.AddWorkshop). Without it they see ERROR models and missing textures. Same switch as our other
-- addons: servers with their own FastDL can turn it off with agp_workshop_download 0
local IDS = {
	"3840679187", -- SpaceGrid
}

local cv = CreateConVar("agp_workshop_download", "1", FCVAR_ARCHIVE, "Send our addons' Workshop content to joining players (1 = on)")
if not cv:GetBool() then return end
for _, id in ipairs(IDS) do
	if id ~= "" then resource.AddWorkshop(id) end
end
