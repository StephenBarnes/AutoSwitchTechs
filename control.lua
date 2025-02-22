local scienceAlertIcon = { type = "virtual", name = "AutoSwitchTechs-science-alert" }

-- Startup settings
local RUN_EVERY_N_TICKS = 60 * settings.startup["AutoSwitchTechs-run-every-n-seconds"].value

-- Runtime settings - functions to fetch settings every time they're needed.
local function PRIORITIZE_SPOILABLE_SCIENCE() return settings.global["AutoSwitchTechs-prioritize-spoilable-science"].value end
local function PRIORITIZE_LATE_GAME_SCIENCE() return settings.global["AutoSwitchTechs-prioritize-late-game-science"].value end
local function SCIENCE_AVAILABLE_THRESHOLD() return settings.global["AutoSwitchTechs-science-available-threshold"].value end
local function NOTIFY_SWITCHES() return settings.global["AutoSwitchTechs-notify-switches"].value end
local function SHOW_WARNINGS() return settings.global["AutoSwitchTechs-show-warnings"].value end
local function WARN_EVERY_N_TICKS() return 60 * settings.global["AutoSwitchTechs-warn-every-n-seconds"].value end
local function SKIP_EARLY_GAME() return settings.global["AutoSwitchTechs-early-game-threshold"].value ~= "none" end
local function EARLY_GAME_THRESHOLD() return settings.global["AutoSwitchTechs-early-game-threshold"].value end
local function MOVE_TO_BACK() return settings.global["AutoSwitchTechs-move-to-back"].value end

-- Constants to hold prototypes we fetch right at the start and then cache.
local LABS = nil
local SCIENCE_PACKS = nil

local function populateConstants()
	LABS = prototypes.get_entity_filtered({{filter = "type", type = "lab"}})
	SCIENCE_PACKS = {}
	for _, lab in pairs(LABS) do
		for _, sciPackName in pairs(lab.lab_inputs) do
			SCIENCE_PACKS[sciPackName] = true
		end
	end
end

------------------------------------------------------------------------

-- Table of priorities used for science packs when late-game priority is enabled. Priority of a tech is sum of priorities of its science packs, so it's determined first by the latest-game science pack and then by the other science packs in order.
local lateGameness = {
	["promethium-science-pack"] = 1e7,
	["cryogenic-science-pack"] = 1e6,
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
local spoilablePriority = 1e8 -- If using setting to prioritize spoilable science, then they have higher priority than any other science pack.
local lateGamenessDefault = 1e5 -- If no priority is set, it's probably a planetary science pack from a modded planet, so give it the same priority as the other planetary science packs.

local function getSciencePriority(sciPackName)
	-- Returns a number for priority of the science pack. Higher numbers are higher priority.
	-- Note this can change in the middle of a game, since we use runtime-global settings for priorities.
	if PRIORITIZE_SPOILABLE_SCIENCE() then
		if prototypes.item[sciPackName].get_spoil_ticks() ~= 0 then
			return spoilablePriority
		end
	end
	if PRIORITIZE_LATE_GAME_SCIENCE() then
		return lateGameness[sciPackName] or lateGamenessDefault
	end
	return 0
end

------------------------------------------------------------------------
---Functions to issue warnings to player when research queue is empty or has no available techs, etc.

local function getLastWarnTime(force)
	if not storage then storage = {} end
	if storage.lastWarnTimes == nil then
		storage.lastWarnTimes = {}
		return nil
	end
	return storage.lastWarnTimes[force.index]
end

local function updateLastWarnTime(force)
	if not storage then storage = {} end
	if storage.lastWarnTimes == nil then
		storage.lastWarnTimes = {}
	end
	storage.lastWarnTimes[force.index] = game.tick
end

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
	if not SHOW_WARNINGS() then return false end
	local lastWarnTime = getLastWarnTime(force)
	return (lastWarnTime == nil) or (lastWarnTime + WARN_EVERY_N_TICKS() < game.tick)
end

local function warnForce(force, warning, anyLab)
	-- Issue a warning, for empty research queue or no techs available. Switching techs is not considered a warning.
	updateLastWarnTime(force)
	alertForce(force, warning, anyLab)
end

------------------------------------------------------------------------

local function findLabsOfForce(force)
	-- Looks at all surfaces and finds all labs of the force.
	-- This is expensive! Can easily take like 70ms on a good computer, which is multiple frames. So prefer to use getLabsOfForce below, which uses a cache.
	-- Returns list of lists of labs, because I'm guessing that's faster than inserting them one-by-one into one list.
	local labs = {}
	for _, surface in pairs(game.surfaces) do
		local surfaceLabs = surface.find_entities_filtered({type="lab", force=force})
		if #surfaceLabs ~= 0 then
			table.insert(labs, surfaceLabs)
		end
	end
	return labs
end

local function getLabsOfForce(force)
	-- Gets list-of-lists of labs, using cache. This is faster than findLabsOfForce.
	if not storage then storage = {} end
	if not storage.labsOfForce then storage.labsOfForce = {} end
	if storage.labsOfForce[force.index] then
		return storage.labsOfForce[force.index]
	else
		local labs = findLabsOfForce(force)
		storage.labsOfForce[force.index] = labs
		return labs
	end
end

local function getAnyLabOfForce(force)
	-- Returns any lab of the force, or nil if the force has no labs. Uses cache.
	local labsOfForce = getLabsOfForce(force)
	if #labsOfForce ~= 0 then return labsOfForce[1][1] end
end

---@param force LuaForce
local function invalidateLabCache(force)
	-- Clears cache of labs of the force. Called when a lab is built or destroyed.
	if not storage then storage = {} end
	if not storage.labsOfForce then storage.labsOfForce = {} end
	if force ~= nil and force.valid and force.index ~= nil then
		storage.labsOfForce[force.index] = nil
	else
		-- If force is invalid/nil, we can't get its index and sth has gone very wrong, so just clear the whole cache to be safe.
		storage.labsOfForce = {}
	end
end

------------------------------------------------------------------------

local function getLabSciencesAvailable(labs)
	-- Returns a table mapping science pack names to true/false for whether enough labs have that pack.
	-- Assumes there's at least 1 lab. Caller checks for case where there's no labs.
	-- Returns nil if labs is invalid, in which case cache for force should be invalidated. Seems to happen sometimes in multiplayer with forces changing?
	local numLabs = 0
	local sciPackAmounts = {} -- maps name of science pack to number of labs that have it
	for _, labList in pairs(labs) do
		numLabs = numLabs + #labList
		for _, lab in pairs(labList) do
			---@cast lab LuaEntity
			if lab == nil or (not lab.valid) then
				-- Entire labs arg is invalid, so return nil to invalidate cache for force.
				log("Error: Invalid lab in call to getLabSciencesAvailable, invalidating lab cache for force.")
				return nil
			end
			local inventory = lab.get_output_inventory()
			if inventory == nil then
				log("Null inventory for lab, this shouldn't happen")
				inventory = {}
			end

			for i = 1, #inventory do
				local item = inventory[i]
				if item.valid_for_read then
					local sciPackName = item.name
					sciPackAmounts[sciPackName] = (sciPackAmounts[sciPackName] or 0) + 1
				end
			end
		end
	end
	for sciPackName, count in pairs(sciPackAmounts) do
		local fracAvailable = count / numLabs
		sciPackAmounts[sciPackName] = (fracAvailable > SCIENCE_AVAILABLE_THRESHOLD())
	end
	return sciPackAmounts
end

local function techHasSciencesAvailable(tech, sciencesAvailable)
	for _, sciPack in pairs(tech.research_unit_ingredients) do
		if not sciencesAvailable[sciPack.name] then
			return false
		end
	end
	return true
end

local function getTechPriority(tech)
	-- Returns a number for priority of the tech, based on science packs.
	if not PRIORITIZE_LATE_GAME_SCIENCE() and not PRIORITIZE_SPOILABLE_SCIENCE() then
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

local function handleNoTechsAvailable(force, anyLab, annotatedQueue, sciencesAvailable)
	-- Handle situation where none of the techs in the queue have all their science packs available.
	-- Look through the list of techs in the queue, and collect list of unavailable science packs that they need.
	if not canWarnNow(force) then return end
	local missingSciences = {}
	for _, annotatedTech in pairs(annotatedQueue) do
		if not annotatedTech.available and not annotatedTech.hasPrereqInQueue then
			for _, sciPack in pairs(annotatedTech.tech.research_unit_ingredients) do
				if not sciencesAvailable[sciPack.name] then
					missingSciences[sciPack.name] = true
				end
			end
		end
	end
	warnForce(force, {"message.no-techs-available", makeScienceIconString(missingSciences)}, anyLab)
end

local function switchToTech(force, targetTechIndex, anyLab, annotatedQueue, sciencesAvailable)
	-- Change research queue to put the specified tech at the start.
	-- Can be called with index 1 to not switch techs.
	-- anyLab argument is any lab of the force, used as target of the alert popup thing.
	if targetTechIndex == 1 then return end
	local queue = force.research_queue
	local newQueue = {queue[targetTechIndex]}
	if not MOVE_TO_BACK() then
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

	if NOTIFY_SWITCHES() then
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
				if not sciencesAvailable[sciPack.name] then
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
				if sciPackPriority * 9 >= switchPriorityDelta and sciPackPriority <= switchPriorityDelta then
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

local function skipBecauseEarlyGame(force)
	-- Returns true if we should skip processing because this force is in early game, defined as not having green science or other tech.
	if not SKIP_EARLY_GAME() then return false end
	return (not force.technologies[EARLY_GAME_THRESHOLD()].researched)
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

---@param force LuaForce
local function updateResearchQueueForForce(force)
	if not force.research_enabled then return end
	if skipBecauseEarlyGame(force) then return end
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
	if #forceLabs == 0 then return end
	local anyLab = forceLabs[1][1]
	profiler:reset()
	local sciencesAvailable = getLabSciencesAvailable(forceLabs)
	force.print({"", "abc", profiler})
	force.print("-- for getLabSciencesAvailable")
	]]

	local forceLabs = getLabsOfForce(force)
	if #forceLabs == 0 then return end
	local anyLab = forceLabs[1][1]
	local sciencesAvailable = getLabSciencesAvailable(forceLabs)

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
	if LABS == nil or SCIENCE_PACKS == nil then
		populateConstants()
	end
	for _, force in pairs(game.forces) do
		updateResearchQueueForForce(force)
	end
end

script.on_nth_tick(RUN_EVERY_N_TICKS, updateResearchQueue)

-- When a lab is built or destroyed, invalidate the cache of labs of the force. So next time they're needed, we'll re-find them using findLabsOfForce.
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
			invalidateLabCache(force)
		end,
		{{ filter = "type", type = "lab" }})
end
