-- Startup settings
local RUN_EVERY_N_TICKS = 60 * settings.startup["AutoSwitchTechs-run-every-n-seconds"].value

-- Runtime settings - refetched at game start or when they're changed, since they can be changed during teh game.
settingPrioritizeSpoilableScience, settingPrioritizeLateGameScience, settingScienceAvailableThreshold, settingCommonScienceLowerThreshold, settingNotifySwitches, settingShowWarnings, settingWarnEveryNTicks, settingMoveToBack = nil, nil, nil, nil, nil, nil, nil, nil
local function refetchSettings()
	local settingsGlobal = settings.global
	settingPrioritizeSpoilableScience = settingsGlobal["AutoSwitchTechs-prioritize-spoilable-science"].value
	settingPrioritizeLateGameScience = settingsGlobal["AutoSwitchTechs-prioritize-late-game-science"].value
	settingScienceAvailableThreshold = settingsGlobal["AutoSwitchTechs-science-available-threshold"].value
	settingCommonScienceLowerThreshold = settingsGlobal["AutoSwitchTechs-common-science-lower-threshold"].value
	settingNotifySwitches = settingsGlobal["AutoSwitchTechs-notify-switches"].value
	settingShowWarnings = settingsGlobal["AutoSwitchTechs-show-warnings"].value
	settingWarnEveryNTicks = 60 * settingsGlobal["AutoSwitchTechs-warn-every-n-seconds"].value
	settingMoveToBack = settingsGlobal["AutoSwitchTechs-move-to-back"].value
end

-- Constants to hold prototypes we fetch right at the start and then cache.
local LABS = nil
---@type table<string, boolean>
local SCIENCE_PACKS = nil
---@type table<string, table<string, boolean>>
local LAB_ALLOWS_SCIENCE_PACK = nil

local function populateConstants()
	LABS = prototypes.get_entity_filtered({{filter = "type", type = "lab"}})
	SCIENCE_PACKS = {}
	LAB_ALLOWS_SCIENCE_PACK = {}
	for _, lab in pairs(LABS) do
		LAB_ALLOWS_SCIENCE_PACK[lab.name] = {}
		for _, sciPackName in pairs(lab.lab_inputs) do
			SCIENCE_PACKS[sciPackName] = true
			LAB_ALLOWS_SCIENCE_PACK[lab.name][sciPackName] = true
		end
	end
end

------------------------------------------------------------------------

-- Table of priorities used for science packs when late-game priority is enabled. Priority of a tech is sum of priorities of its science packs, so it's determined first by the latest-game science pack and then by the other science packs in order.
-- TODO I don't like this system. It basically uses decimal numbers to do a kind of digit-wise comparison - like bitwise comparison, except base-10 because we can have multiple science packs with the same priority. Will behave weirdly if you have 10+ science packs at the same priority level. Would be better to just explicitly keep track of all science packs and do the comparisons in a loop.
local lateGameness = {
	["promethium-science-pack"] = 1e8,
	["cryogenic-science-pack"] = 1e7,

	["cerysian-science-pack"] = 1e6, -- For Cerys mod - Cerys is after Fulgora.
	["electrochemical-science-pack"] = 1e6, -- For Corrundum - after Vulcanus.
	["ring-science-pack"] = 1e6, -- For Metal and Stars - after nanite science.
	["anomaly-science-pack"] = 1e6, -- For Metal and Stars - after nanite science.
	["nanite-science-pack"] = 1e5, -- For Metal and Stars - after space science.

	["metallurgic-science-pack"] = 1e5,
	["electromagnetic-science-pack"] = 1e5,
	["agricultural-science-pack"] = 1e5,
	["space-science-pack"] = 1e4,
	["utility-science-pack"] = 1e3,
	["production-science-pack"] = 1e3,
	["chemical-science-pack"] = 1e2,
	["military-science-pack"] = 1e1,
	["logistic-science-pack"] = 1e0,
	["automation-science-pack"] = 0,
}
local spoilablePriority = 1e9 -- If using setting to prioritize spoilable science, then they have higher priority than any other science pack.
local lateGamenessDefault = 1e5 -- If no priority is set, it's probably a planetary science pack from a modded planet, so give it the same priority as the other planetary science packs.

local function getSciencePriority(sciPackName)
	-- Returns a number for priority of the science pack. Higher numbers are higher priority.
	-- Note this can change in the middle of a game, since we use runtime-global settings for priorities.
	if settingPrioritizeSpoilableScience then
		if prototypes.item[sciPackName].get_spoil_ticks() ~= 0 then
			return spoilablePriority
		end
	end
	if settingPrioritizeLateGameScience then
		return lateGameness[sciPackName] or lateGamenessDefault -- In Lua, `0 or 100` is 0.
	end
	return 0
end

------------------------------------------------------------------------
--- Handling the shortcut button to toggle mod on or off.
local shortcutName = "toggle-auto-switch-techs"

---@param force LuaForce
local function getShortcutState(force)
	local forceId = force.index
	if storage.shortcutState[forceId] == nil then
		storage.shortcutState[forceId] = true
		return true
	end
	return storage.shortcutState[forceId]
end

---@param force LuaForce
---@param newState boolean
local function setShortcutState(force, newState)
	storage.shortcutState[force.index] = newState
	for _, p in pairs(force.players) do
		p.set_shortcut_toggled(shortcutName, newState)
	end
end

-- Handler for when button is pressed.
script.on_event(defines.events.on_lua_shortcut, function(event)
	if event.prototype_name == shortcutName then
		local player = game.get_player(event.player_index)
		if player == nil then
			log("ERROR: player who toggled shortcut could not be found")
			return
		end
		local oldState = player.is_shortcut_toggled(shortcutName)
		local newState = not oldState
		local force = player.force
		---@cast force LuaForce
		setShortcutState(force, newState)
	end
end)

for _, eventType in pairs{
	defines.events.on_player_changed_force,
	defines.events.on_player_joined_game,
	defines.events.on_player_created,
} do
	script.on_event(eventType, function(e)
		---@cast e EventData.on_player_changed_force | EventData.on_player_joined_game | EventData.on_player_created
		if e.player_index == nil then
			log("ERROR: player has nil index")
			return
		end
		local player = game.get_player(e.player_index)
		if player == nil or not player.valid then
			log("ERROR: player is nil or invalid")
			return
		end
		local force = player.force
		---@cast force LuaForce
		if force and force.valid then
			player.set_shortcut_toggled(shortcutName, getShortcutState(force))
		end
	end)
end

-----------------------------------------------------------------------
---Functions to issue warnings to player when research queue is empty or has no available techs, etc.

local function getLastWarnTime(force)
	return storage.lastWarnTimes[force.index]
end

local function updateLastWarnTime(force)
	storage.lastWarnTimes[force.index] = game.tick
end

local scienceAlertIcon = { type = "virtual", name = "AutoSwitchTechs-science-alert" }
local function alertForce(force, message, anyLab)
	-- Send an alert to every player on the force.
	-- anyLab is any lab of the force, required by the game's alert system.
	for _, player in pairs(force.players) do
		if player ~= nil and player.valid then
			player.add_custom_alert(anyLab, scienceAlertIcon, message, false)
		end
	end
end

local function canWarnNow(force)
	-- Returns true if we can issue a warning to the force now, else false.
	-- There's a setting to not warn more than once every N seconds.
	if not settingShowWarnings then return false end
	local lastWarnTime = getLastWarnTime(force)
	return (lastWarnTime == nil) or (lastWarnTime + settingWarnEveryNTicks < game.tick)
end

local function warnForce(force, warning, anyLab)
	-- Issue a warning, for empty research queue or no techs available. Switching techs is not considered a warning.
	updateLastWarnTime(force)
	alertForce(force, warning, anyLab)
end

------------------------------------------------------------------------

---@param force LuaForce
---@return table<string, LuaEntity[]>
local function findLabsOfForce(force)
	-- Looks at all surfaces and finds all labs of the force.
	-- This is expensive! Can easily take like 70ms on a good computer, which is multiple frames. So prefer to use getLabsOfForce below, which uses a cache.
	-- Returns table mapping surface name to list of labs.
	---@type table<string, LuaEntity[]>
	local labs = {}
	for _, surface in pairs(game.surfaces) do
		local surfaceLabs = surface.find_entities_filtered({type="lab", force=force})
		if #surfaceLabs ~= 0 then
			labs[surface.name] = surfaceLabs
		end
	end
	return labs
end

---@param force LuaForce
---@param surfaceName string
---@return LuaEntity[]?
local function findLabsOfForceOnSurface(force, surfaceName)
	-- Returns list of all labs on the given surface, or nil if none found.
	-- This is somewhat expensive. Prefer using getLabsOfForce below.
	local surface = game.get_surface(surfaceName)
	if surface == nil or not surface.valid then
		log("ERROR: tried to find labs on invalid/nil surface: " .. serpent.line(surfaceName))
		return {}
	end
	local surfaceLabs = surface.find_entities_filtered({type="lab", force=force})
	if #surfaceLabs ~= 0 then
		return surfaceLabs
	end
	return nil
end

---@param force LuaForce
local function fixInvalidatedSurfaces(force)
	-- Checks cached lists of labs for the force, and fixes any that have been invalidated (because labs were created or destroyed on that surface) by finding labs on those invalidated surfaces.
	local forceIndex = force.index
	storage.someSurfacesInvalidated[forceIndex] = false

	if storage.forceSurfaceLabs[forceIndex] == nil then
		storage.forceSurfaceLabs[forceIndex] = findLabsOfForce(force)
		return
	end

	for surfaceName, labs in pairs(storage.forceSurfaceLabs[forceIndex]) do
		if labs == false then -- ie, if this surface was invalidated
			storage.forceSurfaceLabs[forceIndex][surfaceName] = findLabsOfForceOnSurface(force, surfaceName)
		end
	end
end

local function getLabsOfForce(force)
	-- Gets table of surface name to labs, using cache. This is faster than findLabsOfForce.
	local forceIndex = force.index

	if storage.someSurfacesInvalidated[forceIndex] then
		fixInvalidatedSurfaces(force)
		return storage.forceSurfaceLabs[forceIndex]
	end

	if storage.forceSurfaceLabs[forceIndex] then
		return storage.forceSurfaceLabs[forceIndex]
	else
		local labs = findLabsOfForce(force)
		storage.forceSurfaceLabs[forceIndex] = labs
		storage.someSurfacesInvalidated[forceIndex] = false
		return labs
	end
end

local function getAnyLabOfForce(force)
	-- Returns any lab of the force, or nil if the force has no labs. Uses cache.
	local forceSurfaceLabs = getLabsOfForce(force)
	if table_size(forceSurfaceLabs) ~= 0 then
		-- Try returning first one on Nauvis, if it exists.
		local nauvisLabs = forceSurfaceLabs.nauvis
		if nauvisLabs ~= nil and nauvisLabs ~= false and #nauvisLabs > 0 then
			return nauvisLabs[1]
		end
		-- Else, return first lab found.
		for _, labs in pairs(forceSurfaceLabs) do
			if labs ~= false and #labs > 0 then return labs[1] end
		end
	end
end

---@param force LuaForce
---@param surfaceName string|nil
local function invalidateLabCache(force, surfaceName)
	-- Clears cache of labs of the force, on one surface or all of them. Called when a lab is built or destroyed.
	if force == nil or not force.valid then
		--If force is invalid/nil, we can't get its index and something has gone very wrong, so just clear the whole cache to be safe.
		log("ERROR: Force is invalid or nil. Invalidating all lab caches.")
		storage.forceSurfaceLabs = {}
		return
	end

	local forceIndex = force.index
	if surfaceName == nil then
		storage.forceSurfaceLabs[forceIndex] = nil
		storage.someSurfacesInvalidated[forceIndex] = true
	else
		if storage.forceSurfaceLabs[forceIndex] == nil then
			storage.forceSurfaceLabs[forceIndex] = {}
		end
		storage.forceSurfaceLabs[forceIndex][surfaceName] = false
		storage.someSurfacesInvalidated[forceIndex] = true
	end
end

------------------------------------------------------------------------

---@param labs table<string, LuaEntity[]>
---@param commonSciencePacks table<string, boolean>
---@return table<string, {labsWithPack: number, labsAllowingPack: number, enough: boolean}> | nil
local function getLabSciencesAvailable(labs, commonSciencePacks)
	-- Returns a table mapping science pack names to how many labs have or allow that pack, and whether it's in enough labs to count as available.
	-- Assumes there's at least 1 lab. Caller checks for case where there's no labs.
	-- Returns nil if labs is invalid, in which case cache for force should be invalidated. Seems to happen sometimes in multiplayer with forces changing?
	---@type table<string, {labsWithPack: number, labsAllowingPack: number, enough: boolean}>
	local sciPackAvailability = {} -- maps name of science pack to {number of labs that have it, number of labs that allow that science pack, whether enough labs have it}
	for sciPackName, _ in pairs(SCIENCE_PACKS) do
		sciPackAvailability[sciPackName] = {labsWithPack = 0, labsAllowingPack = 0, enough = false}
	end

	for _, labList in pairs(labs) do
		if labList == false then
			log("ERROR: Invalidated surface cache was not fixed, this should not happen.")
			labList = {}
		end
		for surfaceName, lab in pairs(labList) do
			---@cast lab LuaEntity
			if lab == nil or (not lab.valid) then
				-- Entire labs arg is invalid, so return nil to invalidate cache for force.
				log("ERROR: Invalid lab in call to getLabSciencesAvailable, invalidating lab cache for force.")
				return nil
			end
			if lab.frozen then goto continue end
			local inventory = lab.get_output_inventory()
			if inventory == nil then
				log("ERROR: Null inventory for lab, this shouldn't happen.")
			elseif inventory.is_empty() then -- Ignore labs that don't have any science packs.
				goto continue
			else
				for i = 1, #inventory do
					local item = inventory[i]
					if item.valid_for_read then
						local sciPackName = item.name
						local thisSciPackAmounts = sciPackAvailability[sciPackName]
						-- Can be e.g. spoilage, instad of a science pack.
						if thisSciPackAmounts ~= nil then
							thisSciPackAmounts.labsWithPack = thisSciPackAmounts.labsWithPack + 1
						end
					end
				end
			end
			for sciPackName, _ in pairs(SCIENCE_PACKS) do
				if LAB_ALLOWS_SCIENCE_PACK[lab.name][sciPackName] then
					local thisSciPackAmounts = sciPackAvailability[sciPackName]
					thisSciPackAmounts.labsAllowingPack = thisSciPackAmounts.labsAllowingPack + 1
				end
			end
			::continue::
		end
	end

	for sciPackName, vals in pairs(sciPackAvailability) do
		if vals.labsAllowingPack > 0 then
			local fracAvailable = vals.labsWithPack / vals.labsAllowingPack
			local threshold
			if commonSciencePacks[sciPackName] then
				threshold = settingCommonScienceLowerThreshold
			else
				threshold = settingScienceAvailableThreshold
			end
			sciPackAvailability[sciPackName].enough = (fracAvailable > threshold)
		end
	end
	return sciPackAvailability
end

---@param sciencesAvailable table<string, {labsWithPack: number, labsAllowingPack: number, enough: boolean}>
local function techHasSciencesAvailable(tech, sciencesAvailable)
	for _, sciPack in pairs(tech.research_unit_ingredients) do
		if not sciencesAvailable[sciPack.name].enough then
			return false
		end
	end
	return true
end

local function getTechPriority(tech)
	-- Returns a number for priority of the tech, based on science packs.
	if not settingPrioritizeLateGameScience and not settingPrioritizeSpoilableScience then
		return 0
	end

	local priority = 0
	for _, sciPack in pairs(tech.research_unit_ingredients) do
		priority = priority + getSciencePriority(sciPack.name)
	end
	return priority
end

local function handleEmptyResearchQueue(force)
	-- If research queue is empty, first check if they have any labs. If they do, warn about empty queue.
	if not canWarnNow(force) then return end
	local forceLab = getAnyLabOfForce(force)
	if forceLab ~= nil then
		warnForce(force, {"message.empty-research-queue"}, forceLab)
	end
end

local function makeScienceIconString(sciences)
	if table_size(sciences) == 0 then return "(error)" end
	local r = ""
	for sciPack, _ in pairs(sciences) do
		r = r .. "[img=item/" .. sciPack .. "] "
	end
	return r
end

---@param sciencesAvailable table<string, {labsWithPack: number, labsAllowingPack: number, enough: boolean}>
local function handleNoTechsAvailable(force, anyLab, annotatedQueue, sciencesAvailable)
	-- Handle situation where none of the techs in the queue have all their science packs available.
	-- Look through the list of techs in the queue, and collect list of unavailable science packs that they need.
	if not canWarnNow(force) then return end
	local missingSciences = {}
	for _, annotatedTech in pairs(annotatedQueue) do
		if not annotatedTech.available and not annotatedTech.hasPrereqInQueue then
			for _, sciPack in pairs(annotatedTech.tech.research_unit_ingredients) do
				if not sciencesAvailable[sciPack.name].enough then
					missingSciences[sciPack.name] = true
				end
			end
		end
	end
	warnForce(force, {"message.no-techs-available", makeScienceIconString(missingSciences)}, anyLab)
end

---@param sciencesAvailable table<string, {labsWithPack: number, labsAllowingPack: number, enough: boolean}>
local function switchToTech(force, targetTechIndex, anyLab, annotatedQueue, sciencesAvailable)
	-- Change research queue to put the specified tech at the start.
	-- Can be called with index 1 to not switch techs.
	-- anyLab argument is any lab of the force, used as target of the alert popup thing.
	if targetTechIndex == 1 then return end
	local queue = force.research_queue
	local newQueue = {queue[targetTechIndex]}
	if not settingMoveToBack then
		for i, tech in pairs(queue) do
			if i ~= targetTechIndex then
				table.insert(newQueue, tech)
			end
		end
	else -- Moving first to back, or to before first tech with a prereq.
		local firstGoesToIndex = #queue -- Index we're moving the 1st tech in queue to, in newQueue.
		for i, tech in pairs(queue) do
			if i ~= 1 and i ~= targetTechIndex then
				table.insert(newQueue, tech)
				if annotatedQueue[i].hasPrereqInQueue then
					firstGoesToIndex = #newQueue
				end
			end
		end
		table.insert(newQueue, firstGoesToIndex, queue[1])
	end
	force.research_queue = newQueue

	if settingNotifySwitches then
		local newTechName
		local newTechProto = newQueue[1].prototype
		if newTechProto.level == newTechProto.max_level then -- Weird inconsistency in whether the localised_name contains the number already or not.
			newTechName = newQueue[1].localised_name
		else
			newTechName = {"", newQueue[1].localised_name, " ", (newQueue[1].level or "")}
		end

		-- Figure out why we switched.
		local switchReason
		if not annotatedQueue[1].available then
			local missingSciences = {}
			for _, sciPack in pairs(annotatedQueue[1].tech.research_unit_ingredients) do
				if not sciencesAvailable[sciPack.name].enough then
					missingSciences[sciPack.name] = true
				end
			end
			switchReason = {"message.switched-bc-first-tech-missing-science", makeScienceIconString(missingSciences)}
		else
			local switchTargetPriority = annotatedQueue[targetTechIndex].priority
			local originalPriority = annotatedQueue[1].priority
			local switchPriorityDelta = switchTargetPriority - originalPriority
			local prioritizedSciences = {}
			for _, sciPack in pairs(annotatedQueue[targetTechIndex].tech.research_unit_ingredients) do
				local sciPackPriority = getSciencePriority(sciPack.name)
				if sciPackPriority * 9 >= switchPriorityDelta and sciPackPriority <= switchPriorityDelta * 9 then
					-- The *9 is because we're adding up priorities that are powers of 10, so eg there could be two sciences with priority 1e6 resulting in total priority of 2e6 plus some remainder smaller than 1e6. Then we want to include all the 1e6 sciences as "reasons" for the switch.
					-- Note that we subtract out the original priority from the switch target priority, so that we're only looking at the delta. This matters in some cases, eg when switching from tech with {spoilable science} to tech with {spoilable science, late-game science} -- in this case the highest-priority is the spoilable science, but the reason for the switch is the late-game science.
					prioritizedSciences[sciPack.name] = true
				end
			end
			switchReason = {"message.switched-bc-prioritized", makeScienceIconString(prioritizedSciences)}
		end

		local alertMessage = {"message.switched-to-tech", newTechName, switchReason}
		alertForce(force, alertMessage, anyLab)
	end
end

local function checkIfTechHasPrereqInQueue(queue, i)
	-- Check whether the tech at index i has a prerequisite earlier in the queue. In that case, we can't switch to it.
	for j = 1, i-1 do
		local previousName = queue[j].name
		if previousName == queue[i].name then return true end
		if queue[i].prerequisites[previousName] then return true end
	end
	return false
end

--- Function to return a set mapping science packs to true if all techs in the force's research queue require that science pack. This is used to decide whether to use the lower availability threshold for that science.
---@param force LuaForce
---@return table<string, boolean>
local function getCommonSciencePacks(force)
	if #(force.research_queue) <= 1 then
		return {} -- If there's only 1 in the queue, we're not switching anyway, so count nothing as common, so everything uses the higher threshold and gets correctly reported as missing.
	end
	local common = {}
	for _, tech in pairs(force.research_queue) do
		for _, sciPack in pairs(tech.research_unit_ingredients) do
			local sciPackName = sciPack.name
			if common[sciPackName] == nil then
				common[sciPackName] = 1
			else
				common[sciPackName] = common[sciPackName] + 1
			end
		end
	end
	local researchQueueSize = #(force.research_queue)
	for sciPackName, count in pairs(common) do
		common[sciPackName] = (count == researchQueueSize)
	end
	return common
end

---@param force LuaForce
local function updateResearchQueueForForce(force)
	if not force.research_enabled then return end
	if getShortcutState(force) == false then return end
	local queue = force.research_queue
	if #queue == 0 then
		handleEmptyResearchQueue(force)
		return
	end

	--[[ For profiling, if you want to optimize further, uncomment this and comment out the next section.
	local profiler = game.create_profiler()
	profiler:reset()
	local forceLabs = getLabsOfForce(force)
	force.print(profiler)
	force.print("-- for findLabsOfForce")
	if table_size(forceLabs) == 0 then return end
	local anyLab = forceLabs[1][1]
	profiler:reset()
	local sciencesAvailable = getLabSciencesAvailable(forceLabs)
	force.print({"", "abc", profiler})
	force.print("-- for getLabSciencesAvailable")
	]]

	local forceLabs = getLabsOfForce(force)
	if table_size(forceLabs) == 0 then return end
	local anyLab = getAnyLabOfForce(force)
	local commonSciencePacks = getCommonSciencePacks(force)
	local sciencesAvailable = getLabSciencesAvailable(forceLabs, commonSciencePacks)

	if sciencesAvailable == nil then -- GetLabSciencesAvailable returned nil indicating invalid labs, so invalidate cache for force.
		invalidateLabCache(force)
		return nil
	end

	local annotatedQueue = {}
	for i, tech in pairs(force.research_queue) do
		local hasPrereqInQueue = checkIfTechHasPrereqInQueue(force.research_queue, i)
		local available = techHasSciencesAvailable(tech, sciencesAvailable)
		local priority
		if hasPrereqInQueue or not available then
			priority = -1
		else
			priority = getTechPriority(tech)
		end
		annotatedQueue[#annotatedQueue+1] = {
			tech = tech,
			available = available,
			priority = priority,
			hasPrereqInQueue = hasPrereqInQueue,
		}
	end

	-- Find tech with highest priority and switch to it.
	local bestPriority = -1
	local techIdxWithBestPriority = 0
	for i, annotatedTech in pairs(annotatedQueue) do
		if annotatedTech.priority > bestPriority then
			bestPriority = annotatedTech.priority
			techIdxWithBestPriority = i
		end
	end
	if techIdxWithBestPriority ~= 0 then
		switchToTech(force, techIdxWithBestPriority, anyLab, annotatedQueue, sciencesAvailable)
	else
		-- If we reach this point, there are no available techs.
		handleNoTechsAvailable(force, anyLab, annotatedQueue, sciencesAvailable)
	end
end

local function updateResearchQueue(nthTickEventData)
	if LABS == nil or SCIENCE_PACKS == nil or LAB_ALLOWS_SCIENCE_PACK == nil then
		populateConstants()
	end
	for _, force in pairs(game.forces) do
		updateResearchQueueForForce(force)
	end
end
script.on_nth_tick(RUN_EVERY_N_TICKS, updateResearchQueue)

-- When a lab is built or destroyed, invalidate the cache of labs of the force for that surface. So next time they're needed, we'll re-find them using findLabsOfForceOnSurface.
for _, eventType in pairs({
	defines.events.on_built_entity,
	defines.events.on_player_mined_entity,

	defines.events.on_robot_built_entity,
	defines.events.on_robot_mined_entity,

	defines.events.on_space_platform_built_entity,
	defines.events.on_space_platform_mined_entity,

	defines.events.script_raised_built,
	defines.events.script_raised_revive,

	defines.events.on_entity_died,
	defines.events.on_entity_cloned,
}) do
	script.on_event(eventType,
		function(event)
			---@cast event EventData.on_built_entity | EventData.on_player_mined_entity | EventData.on_robot_built_entity | EventData.on_robot_mined_entity | EventData.on_space_platform_built_entity | EventData.on_space_platform_mined_entity | EventData.script_raised_built | EventData.script_raised_revive | EventData.on_entity_died | EventData.on_entity_cloned
			local force = event.entity.force
			---@cast force LuaForce -- Guaranteed to be LuaForce when read: lua-api.factorio.com/latest/classes/LuaControl.html#force
			---@type LuaEntity?
			local entity = event.entity
			local surfaceName = nil
			if entity ~= nil and entity.valid then
				surfaceName = entity.surface.name
			end
			invalidateLabCache(force, surfaceName)
		end,
		{{ filter = "type", type = "lab" }})
end

------------------------------------------------------------------------

local function setUpStorage()
	if not storage then storage = {} end
	if storage.shortcutState == nil then storage.shortcutState = {} end
	if storage.lastWarnTimes == nil then storage.lastWarnTimes = {} end
	if storage.forceSurfaceLabs == nil then storage.forceSurfaceLabs = {} end
	if storage.someSurfacesInvalidated == nil then storage.someSurfacesInvalidated = {} end
end

-- On configuration changed, invalidate all forces' caches (so we rebuild the lists), and also refetch settings and set up storage.
script.on_configuration_changed(function()
	refetchSettings()
	setUpStorage()
	for _, force in pairs(game.forces) do
		invalidateLabCache(force)
	end
end)

-- On init, fetch settings and set up storage.
script.on_init(function()
	refetchSettings()
	setUpStorage()
end)

-- On mod settings changed, refetch settings.
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	refetchSettings()
end)