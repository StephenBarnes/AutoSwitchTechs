local nextOrder = 0
local function getNextOrder()
    nextOrder = nextOrder + 1
    return string.format("%03d", nextOrder)
end

local settings = {
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-run-every-n-seconds",
        type = "double-setting",
        setting_type = "startup",
        default_value = 10,
        minimum_value = 0.1,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-prioritize-spoilable-science",
        type = "bool-setting",
        setting_type = "runtime-global",
        default_value = true,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-prioritize-late-game-science",
        type = "bool-setting",
        setting_type = "runtime-global",
        default_value = false,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-notify-switches",
        type = "bool-setting",
        setting_type = "runtime-global",
        default_value = true,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-show-warnings",
        type = "bool-setting",
        setting_type = "runtime-global",
        default_value = false,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-warn-every-n-seconds",
        type = "double-setting",
        setting_type = "runtime-global",
        default_value = 60,
        minimum_value = 1,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-move-to-back",
        type = "bool-setting",
        setting_type = "runtime-global",
        default_value = true,
    },
    {
        order = getNextOrder(),
        name = "AutoSwitchTechs-science-available-threshold",
        type = "double-setting",
        setting_type = "runtime-global",
        default_value = 0.8,
        minimum_value = 0,
        maximum_value = 1,
    },
}

data:extend(settings)