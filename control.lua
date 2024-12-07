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

-- Table of priorities used for science packs when late-game priority is enabled.
local lateGameness = {
	["promethium-science-pack"] = 9,
	["cryogenic-science-pack"] = 8,
	["metallurgic-science-pack"] = 7,
	["electromagnetic-science-pack"] = 7,
	["agricultural-science-pack"] = 7,
	["space-science-pack"] = 6,
	["utility-science-pack"] = 5,
	["production-science-pack"] = 5,
	["chemical-science-pack"] = 4,
	["military-science-pack"] = 3,
	["logistic-science-pack"] = 2,
	["automation-science-pack"] = 1,
}

local function getSciencePriority(sciPackName)
	-- Returns a number for priority of the science pack. Higher numbers are higher priority.
	-- Note this can change in the middle of a game, since we use runtime-global settings for priorities. So can't populate it with constants above.
	if PRIORITIZE_SPOILABLE_SCIENCE() then
		if prototypes.item[sciPackName].get_spoil_ticks() ~= 0 then
			return 10
		end
	end
	if PRIORITIZE_LATE_GAME_SCIENCE() then
		return lateGameness[sciPackName] or 1
	end
	return 1
end

------------------------------------------------------------------------
---Functions to issue warnings to player when research queue is empty or has no available techs, etc.

local function getLastWarnTime(force)
	if not global then global = {} end
	if global.lastWarnTimes == nil then
		global.lastWarnTimes = {}
		return nil
	end
	return global.lastWarnTimes[force.index]
end

local function updateLastWarnTime(force)
	if not global then global = {} end
	if global.lastWarnTimes == nil then
		global.lastWarnTimes = {}
	end
	global.lastWarnTimes[force.index] = game.tick
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
	if not global then global = {} end
	if not global.labsOfForce then global.labsOfForce = {} end
	if global.labsOfForce[force.index] then
		return global.labsOfForce[force.index]
	else
		local labs = findLabsOfForce(force)
		global.labsOfForce[force.index] = labs
		return labs
	end
end

local function getAnyLabOfForce(force)
	-- Returns any lab of the force, or nil if the force has no labs. Uses cache.
	local labsOfForce = getLabsOfForce(force)
	if #labsOfForce ~= 0 then return labsOfForce[1][1] end
end

local function invalidateLabCache(force)
	-- Clears cache of labs of the force. Called when a lab is built or destroyed.
	if not global then global = {} end
	if not global.labsOfForce then global.labsOfForce = {} end
	global.labsOfForce[force.index] = nil
end

------------------------------------------------------------------------

local function getLabSciencesAvailable(labs)
	-- Returns a table mapping science pack names to true/false for whether enough labs have that pack.
	-- Assumes there's at least 1 lab. Caller checks for case where there's no labs.
	local numLabs = 0
	local sciPackAmounts = {} -- maps name of science pack to number of labs that have it
	for _, labList in pairs(labs) do
		numLabs = numLabs + #labList
		for _, lab in pairs(labList) do
			local inventory = lab.get_output_inventory()
			if inventory == nil then
				log("Null inventory for lab, this shouldn't happen")
				inventory = {}
			end

			for i = 1, #inventory do
				local item = inventory[i]
				if item.valid_for_read then
					sciPackName = item.name
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
	local maxPriority = 0
	for _, sciPack in pairs(tech.research_unit_ingredients) do
		maxPriority = math.max(maxPriority, getSciencePriority(sciPack.name))
	end
	return maxPriority
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
	for i, tech in pairs(queue) do
		if i ~= targetTechIndex then
			table.insert(newQueue, tech)
		end
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
			local prioritizedSciences = {}
			for _, sciPack in pairs(annotatedQueue[targetTechIndex].tech.research_unit_ingredients) do
				if getSciencePriority(sciPack.name) == switchTargetPriority then
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
	if sciencesAvailable == nil then return end
	]]

	local forceLabs = getLabsOfForce(force)
	if #forceLabs == 0 then return end
	local anyLab = forceLabs[1][1]
	local sciencesAvailable = getLabSciencesAvailable(forceLabs)
	if sciencesAvailable == nil then return end

	local annotatedQueue = {}
	for i, tech in pairs(force.research_queue) do
		local hasPrereqInQueue = checkIfTechHasPrereqInQueue(force.research_queue, i)
		local available = techHasSciencesAvailable(tech, sciencesAvailable)
		local priority
		if hasPrereqInQueue or not available then
			priority = 0
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
	local bestPriority = 0
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
	defines.events.on_entity_died,
}) do
	script.on_event(eventType,
		function(event)
			---@cast event EventData.on_built_entity | EventData.on_player_mined_entity | EventData.on_robot_built_entity | EventData.on_robot_mined_entity | EventData.on_entity_died
			invalidateLabCache(event.entity.force)
		end,
		{{ filter = "type", type = "lab" }})
end
