-- Create virtual signal for the science warning icon.
-- This is necessary because custom alerts can only use virtual signals for their icons.
data:extend({
	{
		type = "virtual-signal",
		name = "AutoSwitchTechs-science-alert",
		icon = "__AutoSwitchTechs__/graphics/science-alert.png",
		icon_size = 64,
		--hidden_in_factoriopedia = true,
		subgroup = "additions", -- So it won't show up in "unsorted" tab of combinators.
		order = "z",
	},
})
