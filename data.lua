-- Create virtual signal for the science warning icon.
-- This is necessary because custom alerts can only use virtual signals for their icons.
data:extend({
	{
		type = "virtual-signal",
		name = "AutoTechSwitch-science-alert",
		icon = "__AutoSwitchTechs__/graphics/science-alert.png",
		icon_size = 64,
	},
})
