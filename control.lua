
-- Startup settings
local RUN_EVERY_N_TICKS = 60 * settings.startup["AutoSwitchTechs-run-every-n-seconds"].value

-- Runtime settings - functions to fetch settings every time they're needed.
local function PRIORITIZE_SPOILABLE_SCIENCE() return settings.global["AutoSwitchTechs-prioritize-spoilable-science"].value end
local function SCIENCE_AVAILABLE_THRESHOLD() return settings.global["AutoSwitchTechs-science-available-threshold"].value end
local function NOTIFY_SWITCHES() return settings.global["AutoSwitchTechs-notify-switches"].value end
local function SHOW_WARNINGS() return settings.global["AutoSwitchTechs-show-warnings"].value end
local function WARN_EVERY_N_TICKS() return 60 * settings.global["AutoSwitchTechs-warn-every-n-seconds"].value end
local function SKIP_EARLY_GAME() return settings.global["AutoSwitchTechs-early-game-threshold"].value ~= "none" end
local function EARLY_GAME_THRESHOLD() return settings.global["AutoSwitchTechs-early-game-threshold"].value end

-- Constants to hold prototypes we fetch right at the start and then cache.
local LABS = nil
local SCIENCE_PACKS = nil
local SPOILABLE_SCIENCE_PACKS = nil

local function populateConstants()
	LABS = prototypes.get_entity_filtered({{filter = "type", type = "lab"}})
	SCIENCE_PACKS = {}
	SPOILABLE_SCIENCE_PACKS = {}
	for _, lab in pairs(LABS) do
		for _, sciPackName in pairs(lab.lab_inputs) do
			SCIENCE_PACKS[sciPackName] = true
			if prototypes.item[sciPackName].get_spoil_ticks() ~= 0 then
				SPOILABLE_SCIENCE_PACKS[sciPackName] = true
			end
		end
	end
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

local function maybeWarn(force, warning)
	if not SHOW_WARNINGS() then return end
	local lastWarnTime = getLastWarnTime(force)
	if lastWarnTime == nil or lastWarnTime + WARN_EVERY_N_TICKS() < game.tick then
		force.print(warning)
		updateLastWarnTime(force)
	end
end

------------------------------------------------------------------------

local function findLabsOfForce(force)
	-- Returns list of lists of labs, because I'm guessing that's faster than concatenating into one list.
	-- TODO if there's performance issues we can cache this per-force, mark forces as dirty if there's build events etc.
	local labs = {}
	for _, surface in pairs(game.surfaces) do
		local surfaceLabs = surface.find_entities_filtered({type="lab", force=force})
		if #surfaceLabs ~= 0 then
			table.insert(labs, surfaceLabs)
		end
	end
	return labs
end

local function forceHasLabs(force)
	for _, surface in pairs(game.surfaces) do
		local surfaceLabs = surface.find_entities_filtered({type="lab", force=force})
		if #surfaceLabs ~= 0 then
			return true
		end
	end
	return false
end

local function getLabSciencesAvailable(force)
	-- Returns a table mapping science pack names to true/false for whether enough labs have that pack.
	-- Returns nil if no labs.
	local forceLabs = findLabsOfForce(force)
	if #forceLabs == 0 then return nil end
	local numLabs = 0
	local sciPackAmounts = {} -- maps name of science pack to number of labs that have it
	for _, labList in pairs(forceLabs) do
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

local function techHasSpoilableSciences(tech)
	for _, sciPack in pairs(tech.research_unit_ingredients) do
		if SPOILABLE_SCIENCE_PACKS[sciPack.name] == true then
			return true
		end
	end
	return false
end

local function handleEmptyResearchQueue(force)
	-- If research queue is empty, first check if they have any labs. If they do, warn about empty queue.
	if not SHOW_WARNINGS() then return end
	if forceHasLabs(force) then
		maybeWarn(force, {"message.empty-research-queue"})
	end
end

local function switchToTech(force, targetTechIndex)
	-- Change research queue to put the specified tech at the start.
	-- Can be called with index 1 to not switch techs.
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
		force.print({"message.switched-to-tech", newTechName})
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

	local sciencesAvailable = getLabSciencesAvailable(force)
	if sciencesAvailable == nil then return end

	local queueHasPrioritizedTechs = false
	local annotatedQueue = {}
	for i, tech in pairs(force.research_queue) do
		local hasPrereqInQueue = checkIfTechHasPrereqInQueue(force.research_queue, i)
		local prioritizeTech = (not hasPrereqInQueue) and PRIORITIZE_SPOILABLE_SCIENCE() and techHasSpoilableSciences(tech)
		annotatedQueue[#annotatedQueue+1] = {
			tech = tech,
			available = techHasSciencesAvailable(tech, sciencesAvailable),
			prioritize = prioritizeTech,
			hasPrereqInQueue = hasPrereqInQueue,
		}
		if prioritizeTech then queueHasPrioritizedTechs = true end
	end

	-- If we're prioritizing some techs, and we have prioritized techs in the queue, first try switching to those.
	if queueHasPrioritizedTechs then
		for i, annotatedTech in pairs(annotatedQueue) do
			if (not annotatedTech.hasPrereqInQueue) and annotatedTech.available and annotatedTech.prioritize then
				switchToTech(force, i)
				return
			end
		end
	end

	-- If there's no prioritized techs, find the first available tech and switch to it.
	for i, annotatedTech in pairs(annotatedQueue) do
		if (not annotatedTech.hasPrereqInQueue) and annotatedTech.available then
			switchToTech(force, i)
			return
		end
	end

	-- If we reach this point, there are no available techs.
	maybeWarn(force, {"message.no-techs-available"})
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

-- TODO add a setting to auto-queue the next research in a series when research finishes.