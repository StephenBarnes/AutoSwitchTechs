-- Create virtual signal for the science warning icon.
-- This is necessary because custom alerts can only use virtual signals for their icons.
local subgroup = nil
if data.raw["item-subgroup"]["virtual-signal"] ~= nil then
	subgroup = "virtual-signal"
end
data:extend({
	{
		type = "virtual-signal",
		name = "AutoSwitchTechs-science-alert",
		icon = "__AutoSwitchTechs__/graphics/science-alert.png",
		icon_size = 64,
		--hidden_in_factoriopedia = true,
		subgroup = subgroup, -- So it won't show up in "unsorted" tab of combinators.
		order = "z",
	},
})

-- Create toggle button
data:extend({
	{
		type = "shortcut",
		name = "toggle-auto-switch-techs",
		icon = "__AutoSwitchTechs__/graphics/technology-black.png",
		small_icon = "__AutoSwitchTechs__/graphics/technology-black.png",
		toggleable = true,
		action = "lua",
		order = "z",
	} ---@as data.ShortcutPrototype
})