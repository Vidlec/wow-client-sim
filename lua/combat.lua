-- The battle simulator: creatures from the game's data stand near the player as units an addon sees as in the game
-- (their nameplates as they come in range, the target, the focus, the mouseover, with GUIDs, health, power, level,
-- rank, side, threat, casts and auras), and fight: the player targets them (Tab, a click on a plate), swings at them,
-- casts the spells on the action bars (costs, cooldowns, the global cooldown, ranges, cast bars), and they aggro,
-- chase, swing and cast back. The player's health and power regenerate, the player can die, release and come back;
-- creatures die, giving kill credit, experience and loot. Everything rolls from a seed: a scenario plays the same
-- fight every time.
--
-- What the client keeps from addons stays kept: the combat log (COMBAT_LOG_EVENT_UNFILTERED has restrictions in this
-- build, CombatLogGetCurrentEventInfo is gone, C_CombatLog has no event info) never reaches them; the page's log
-- below is the simulator's own. Kills reach addons as the client tells them: UNIT_HEALTH to 0, PARTY_KILL, UNIT_DIED.
--
-- The numbers (damage, health, chances) are made to give believable fights, not measured: see combat/data.lua.
local sim = require("sim")
local game = require("game")
local data = require("combat.data")

local combat = {}
local G = sim.G

combat.enemies = {} -- in the order they came, dead ones too until they are gone
combat.byId = {}
combat.plates = {} -- [index] = the enemy holding nameplate<index>
combat.log = {} -- the page's combat log, newest last
combat.target, combat.focus, combat.mouseover = nil, nil, nil
combat.loot = nil -- the open loot window: { enemy, slots }
combat.seed = 20261123
combat.rangeChecked = {} -- action slots the bars asked range updates for (C_ActionBar.EnableActionRangeCheck)

local MELEE_RANGE = 5 -- yards: the two units' reach together, as most fights have it (a guess for every creature)
local RUN_SPEED = 7 -- yards a second, a creature running at the player as the player runs
local LEASH = 60 -- yards from where it was pulled before a creature gives up (a guess)
local CORPSE_SECONDS = 300 -- a corpse lies this long (120 once looted)
local LOG_LINES = 60
local POWER = data.POWER

local nextEnemyId, castCount, auraCount = 0, 0, 0

-- Rolls: the fight's own sequence (the quest drops keep the game's, game.random), from a seed
local randomState = combat.seed
local function roll()
    randomState = (randomState * 1103515245 + 12345) % 2147483648
    return randomState / 2147483648
end
local function rollBetween(low, high)
    return low + (high - low) * roll()
end
function combat.setSeed(seed)
    combat.seed = tonumber(seed) or combat.seed
    randomState = combat.seed
end

local function now()
    return sim.now
end
local function fire(event, ...)
    sim.fireEvent(event, ...)
end
local function text(name, fallback)
    local value = rawget(G, name)
    return type(value) == "string" and value or fallback
end

-- The player in a fight
local player = {
    maximaKey = nil,
    health = 1,
    healthMax = 1,
    power = 0,
    powerMax = 0,
    powerType = POWER.MANA,
    isDead = false,
    isGhost = false,
    inCombat = false,
    diedAt = nil,
    isAutoAttacking = false,
    autoRepeatSpellId = nil,
    swingAt = 0,
    rangeWarned = false,
    cast = nil,
    gcdStart = 0,
    gcdDuration = 0,
    cooldowns = {},
    queuedSpellId = nil,
    comboPoints = 0,
    comboTarget = nil,
    auras = {},
    absorb = 0,
    lastManaSpend = -math.huge,
    nextRegenAt = 0,
    lastPosition = nil,
    isFleeing = false,
}
combat.player = player

local function powerTypeOf(class)
    if class == "WARRIOR" then
        return POWER.RAGE
    end
    if class == "ROGUE" then
        return POWER.ENERGY
    end
    return POWER.MANA
end

---The player's health and power for their class, race and level, worked out again when one of them changes (a
---login, a level gained): kept at the same share of the new maxima.
local function ensurePlayer()
    local profile = game.profile
    local key = tostring(profile.class) .. "/" .. tostring(profile.race) .. "/" .. tostring(profile.level)
    if player.maximaKey == key then
        return player
    end
    local healthMax, manaMax =
        data.playerMaxima(tostring(profile.class or "WARRIOR"):upper(), profile.race, tonumber(profile.level) or 1)
    local powerType = powerTypeOf(tostring(profile.class or ""):upper())
    local powerMax = powerType == POWER.MANA and math.max(manaMax, 1) or 100
    local wasSet = player.maximaKey ~= nil
    local healthShare = wasSet and player.healthMax > 0 and player.health / player.healthMax or 1
    local powerShare = wasSet
            and player.powerType == powerType
            and player.powerMax > 0
            and player.power / player.powerMax
        or nil
    player.maximaKey, player.healthMax, player.powerType, player.powerMax = key, healthMax, powerType, powerMax
    player.health = (player.isDead or player.isGhost) and (player.isGhost and 1 or 0)
        or math.max(1, math.floor(healthMax * healthShare + 0.5))
    -- Rage starts empty, energy and mana full
    player.power = powerShare and math.floor(powerMax * powerShare + 0.5) or (powerType == POWER.RAGE and 0 or powerMax)
    -- (told at the next tick: this can run inside an addon's UnitHealth)
    if wasSet then
        player.maximaChanged = true
    end
    return player
end

local function powerToken(powerType)
    return data.POWER_NAMES[powerType] or "MANA"
end

local function playerChanged(isHealth, isPower)
    if isHealth then
        fire("UNIT_HEALTH", "player")
    end
    if isPower then
        fire("UNIT_POWER_UPDATE", "player", powerToken(player.powerType))
        fire("UNIT_POWER_FREQUENT", "player", powerToken(player.powerType))
    end
end

-- Where everyone is: world yards on the player's continent (an instance has no world place here: the fight stands
-- round a fixed point there)
local positionCache = {}
local function playerPosition()
    local profile, cache = game.profile, positionCache
    if
        cache.uiMapId == profile.uiMapId
        and cache.x == profile.x
        and cache.y == profile.y
        and cache.inside == profile.isInInstance
    then
        return cache.continentId, cache.north, cache.west
    end
    local continentId, north, west = game.getPlayerWorldPosition()
    if not continentId then
        continentId, north, west = "instance", 0, 0
    end
    cache.uiMapId, cache.x, cache.y, cache.inside = profile.uiMapId, profile.x, profile.y, profile.isInInstance
    cache.continentId, cache.north, cache.west = continentId, north, west
    return continentId, north, west
end

---@return number distance Yards from the player, math.huge on another continent
---@return number bearing Radians clockwise from the player's facing (-pi..pi)
local function measure(enemy)
    local continentId, north, west = playerPosition()
    if enemy.continentId ~= continentId then
        return math.huge, 0
    end
    local dNorth, dWest = enemy.north - north, enemy.west - west
    local angle = math.atan2(dWest, dNorth) -- the facing's own reckoning: 0 north, growing to the west
    local relative = ((game.profile.facing or 0) - angle + math.pi) % (2 * math.pi) - math.pi
    return math.sqrt(dNorth * dNorth + dWest * dWest), relative
end
local function distanceBetween(first, second)
    if first.continentId ~= second.continentId then
        return math.huge
    end
    return math.sqrt((first.north - second.north) ^ 2 + (first.west - second.west) ^ 2)
end

-- Unit tokens: which enemy a token stands for now
local function enemyForToken(unit)
    if type(unit) ~= "string" then
        return nil
    end
    local lower = unit:lower()
    if lower == "target" then
        return combat.target
    end
    if lower == "focus" then
        return combat.focus
    end
    if lower == "mouseover" then
        return combat.mouseover
    end
    local index = lower:match("^nameplate(%d+)$")
    if index then
        return combat.plates[tonumber(index)]
    end
    return nil
end

---@return string? kind "enemy" (with it), "player" (a token that leads back to the player: the creature's target)
local function resolve(unit)
    local enemy = enemyForToken(unit)
    if enemy then
        return "enemy", enemy
    end
    if type(unit) ~= "string" then
        return nil
    end
    local inner = unit:lower():match("^(.+)target$")
    if inner then
        local innerEnemy = enemyForToken(inner)
        if innerEnemy then
            if not innerEnemy.isDead and innerEnemy.targetUnit == "player" then
                return "player"
            end
            return "none"
        end
        if inner == "player" and combat.target then
            return "enemy", combat.target
        end
    end
    return nil
end

-- Every token an enemy has now: a unit event goes out once for each, as the client fires one for every token of a unit
local function tokensOf(enemy)
    local tokens = {}
    if combat.target == enemy then
        tokens[#tokens + 1] = "target"
    end
    if combat.focus == enemy then
        tokens[#tokens + 1] = "focus"
    end
    if combat.mouseover == enemy then
        tokens[#tokens + 1] = "mouseover"
    end
    if enemy.plateIndex then
        tokens[#tokens + 1] = "nameplate" .. enemy.plateIndex
    end
    return tokens
end
local function fireUnit(enemy, event, ...)
    for _, token in ipairs(tokensOf(enemy)) do
        fire(event, token, ...)
    end
end

-- The page's combat log, worded as the game's log window words it
local function logLine(entry)
    entry.time = now()
    local log = combat.log
    log[#log + 1] = entry
    if #log > LOG_LINES then
        table.remove(log, 1)
    end
end
local function nameOf(who)
    if who == "player" then
        return game.profile.name
    end
    return who and who.name or nil
end
local OUTCOME_VERBS = {
    DODGE = "dodge",
    PARRY = "parry",
    BLOCK = "block",
    RESIST = "resist",
    ABSORB = "absorb",
    EVADE = "evade",
    IMMUNE = "ignore",
}
local OUTCOME_VERBS_THIRD = {
    DODGE = "dodges",
    PARRY = "parries",
    BLOCK = "blocks",
    RESIST = "resists",
    ABSORB = "absorbs",
    EVADE = "evades",
    IMMUNE = "ignores",
}
local function logHit(event, source, dest, spell, amount, outcome, school)
    local sourceName, destName = nameOf(source), nameOf(dest)
    -- In the first person, as the player's own log has it: "Your Fireball hits", "You hit", "hits you"
    local isYou = source == "player" and not spell
    local what = spell
            and ((source == "player" and "Your" or ((sourceName or "Something") .. "'s")) .. " " .. spell.name)
        or (source == "player" and "You" or (sourceName or "Something"))
    local whom = dest == "player" and (source == "player" and "you" or "you") or (destName or "?")
    local line
    if amount == nil then
        local attack = spell and spell.name or "attack"
        if outcome == "MISS" or outcome == nil then
            line = string.format("%s %s %s.", what, isYou and "miss" or "misses", whom)
        elseif dest == "player" then
            line =
                string.format("You %s %s's %s.", (OUTCOME_VERBS[outcome] or "avoid"), sourceName or "Something", attack)
        else
            line = string.format(
                "%s %s %s.",
                destName or "?",
                OUTCOME_VERBS_THIRD[outcome] or "avoids",
                source == "player" and ("your " .. attack) or attack
            )
        end
    elseif event == "SPELL_HEAL" or event == "SPELL_PERIODIC_HEAL" then
        line = string.format(
            "%s %s %s for %d%s.",
            what,
            isYou and "heal" or "heals",
            source == dest and (dest == "player" and "you" or whom) or whom,
            amount,
            outcome == "CRITICAL" and " (critical)" or ""
        )
    else
        local verb = outcome == "CRITICAL" and "crit" or "hit"
        line = string.format(
            "%s %s %s for %d%s.",
            what,
            isYou and verb or (verb .. "s"),
            whom,
            amount,
            (outcome == "GLANCING" or outcome == "CRUSHING" or outcome == "ABSORB") and (" (" .. outcome:lower() .. ")")
                or ""
        )
    end
    logLine({
        event = event,
        sourceName = sourceName,
        destName = destName,
        spellId = spell and spell.id or nil,
        spellName = spell and spell.name or nil,
        amount = amount,
        outcome = outcome,
        text = line,
    })
end
local function logEvent(event, source, dest, spell, line)
    logLine({
        event = event,
        sourceName = nameOf(source),
        destName = nameOf(dest),
        spellId = spell and spell.id or nil,
        spellName = spell and spell.name or nil,
        amount = nil,
        outcome = nil,
        text = line,
    })
end

local function errorMessage(name, fallback)
    local message = text(name, fallback)
    local errorType = rawget(G, "LE_GAME_ERR_" .. name:gsub("^ERR_", "")) or 0
    fire("UI_ERROR_MESSAGE", errorType, message)
    return false, message
end

-- Auras
local function auraData(aura)
    return {
        applications = aura.stacks or 0,
        auraInstanceID = aura.instanceId,
        canApplyAura = aura.source == "player",
        charges = 0,
        duration = aura.duration,
        expirationTime = aura.expirationTime,
        icon = aura.icon,
        isBossAura = false,
        isFromPlayerOrPlayerPet = aura.source == "player",
        isHarmful = aura.isHarmful,
        isHelpful = not aura.isHarmful,
        isNameplateOnly = false,
        isRaid = false,
        isStealable = false,
        maxCharges = 0,
        name = aura.name,
        nameplateShowAll = false,
        nameplateShowPersonal = aura.source == "player" and aura.isHarmful,
        points = { aura.amount or 0 },
        sourceUnit = aura.source,
        spellId = aura.spellId,
        timeMod = 1,
    }
end
local function fireAuras(holder, info)
    -- The game's aura frames (Blizzard_AuraContainer) run in the client's secure environment, which keeps
    -- secretunwrap after Blizzard_EnvironmentCleanup takes it from the global one. The simulator has the one
    -- environment: it is given back for them once there are auras to show (addons can reach it here, unlike the client)
    if rawget(G, "secretunwrap") == nil then
        rawset(G, "secretunwrap", function(...)
            return ...
        end)
    end
    if holder == player then
        fire("UNIT_AURA", "player", info)
    else
        fireUnit(holder, "UNIT_AURA", info)
    end
end
local function addAura(holder, spell, effect, isHarmful, amount)
    local list = holder.auras
    -- The same spell again refreshes it; a stance or form (aura 36) replaces the other
    for index = #list, 1, -1 do
        local other = list[index]
        if other.spellId == spell.id and other.source == "player" or (effect.aura == 36 and other.auraType == 36) then
            table.remove(list, index)
            fireAuras(holder, { removedAuraInstanceIDs = { other.instanceId } })
        end
    end
    auraCount = auraCount + 1
    local duration = spell.duration > 0 and spell.duration or 0
    local aura = {
        instanceId = auraCount,
        spellId = spell.id,
        name = spell.name,
        icon = spell.icon,
        isHarmful = isHarmful,
        source = "player",
        auraType = effect.aura,
        duration = duration,
        expirationTime = duration > 0 and now() + duration or 0,
        period = effect.period > 0 and effect.period or nil,
        nextTick = effect.period > 0 and now() + effect.period or nil,
        amount = amount,
        school = spell.school,
        spell = spell,
    }
    list[#list + 1] = aura
    fireAuras(holder, { addedAuras = { auraData(aura) } })
    logEvent(
        "SPELL_AURA_APPLIED",
        "player",
        holder == player and "player" or holder,
        spell,
        string.format(
            "%s %s %s.",
            holder == player and "You" or holder.name,
            holder == player and "gain" or "is afflicted by",
            spell.name
        )
    )
    if effect.aura == data.AURA.SCHOOL_ABSORB and holder == player then
        player.absorb = player.absorb + (amount or 0)
    end
    return aura
end
local function removeAura(holder, aura, isQuiet)
    for index, other in ipairs(holder.auras) do
        if other == aura then
            table.remove(holder.auras, index)
            if aura.auraType == data.AURA.SCHOOL_ABSORB and holder == player then
                player.absorb = 0
            end
            if not isQuiet then
                fireAuras(holder, { removedAuraInstanceIDs = { aura.instanceId } })
                logEvent(
                    "SPELL_AURA_REMOVED",
                    "player",
                    holder == player and "player" or holder,
                    aura.spell,
                    string.format("%s fades from %s.", aura.name, holder == player and "you" or holder.name)
                )
            end
            return
        end
    end
end
local function clearAuras(holder)
    if #holder.auras == 0 then
        return
    end
    holder.auras = {}
    if holder == player then
        player.absorb = 0
    end
    fireAuras(holder, { isFullUpdate = true })
end
local function hasAura(holder, auraType)
    for _, aura in ipairs(holder.auras) do
        if aura.auraType == auraType then
            return aura
        end
    end
    return nil
end

-- Creatures
local function plateToken(enemy)
    return enemy.plateIndex and ("nameplate" .. enemy.plateIndex) or nil
end

local function classificationOf(enemy)
    return data.CLASSIFICATIONS[enemy.rank] or "normal"
end

local function reactionFor(creature)
    local profile = game.profile
    local reaction = creature.factionId and data.getReaction(creature.factionId, profile.race)
    if reaction then
        return reaction
    end
    -- Without the game's faction table: friendly to the faction QuestieDB names, else hostile
    local letter = profile.faction == "Alliance" and "A" or "H"
    if type(creature.friendlyTo) == "string" and creature.friendlyTo:find(letter, 1, true) then
        return 5
    end
    return 2
end

local function makeEnemy(creature, spec, continentId, north, west)
    nextEnemyId = nextEnemyId + 1
    local level = math.floor(tonumber(spec.level) or creature.minLevel or 1)
    local healthMax
    if creature.minHealth and creature.minHealth > 0 then
        local span = math.max(0, (creature.maxLevel or level) - (creature.minLevel or level))
        local share = span > 0 and math.max(0, math.min(1, (level - creature.minLevel) / span)) or 0
        healthMax = math.floor(
            creature.minHealth + ((creature.maxHealth or creature.minHealth) - creature.minHealth) * share + 0.5
        )
    else
        healthMax = data.guessCreatureHealth(level, creature.rank)
    end
    local spellId = tonumber(spec.spellId) or creature.spellId
    local enemy = {
        id = nextEnemyId,
        npcId = creature.npcId,
        name = creature.name,
        level = level,
        rank = creature.rank or 0,
        guid = string.format("Creature-0-1-0-1-%d-%010X", creature.npcId, 0x2000000 + nextEnemyId),
        reaction = reactionFor(creature),
        health = healthMax,
        healthMax = healthMax,
        -- Casters have mana, as their frames show; the rest no power (the database tells no creature's)
        powerType = spellId and POWER.MANA or POWER.MANA,
        powerMax = spellId and (level * 20 + 50) or 0,
        continentId = continentId,
        north = north,
        west = west,
        homeNorth = north,
        homeWest = west,
        isDead = false,
        inCombat = false,
        isEvading = false,
        targetUnit = nil,
        threat = {},
        auras = {},
        swingAt = 0,
        swingSpeed = 2,
        spellId = spellId,
        nextCastAt = 0,
        cast = nil,
        isAggressive = spec.aggro ~= false,
        isTappedByOthers = spec.isTappedByOthers == true,
        isTapped = false,
        dropChance = tonumber(spec.dropChance),
        spawnedAt = now(),
        distance = math.huge,
        bearing = 0,
    }
    enemy.power = enemy.powerMax
    combat.enemies[#combat.enemies + 1] = enemy
    combat.byId[enemy.id] = enemy
    return enemy
end

-- Nameplates: a creature in range has one (NAME_PLATE_UNIT_ADDED as it comes, _REMOVED as it goes or dies), placed
-- on the screen where it stands in front of the camera (behind the player: off the screen, still a unit)
local function plateRange()
    return tonumber(G.GetCVar and G.GetCVar("nameplateMaxDistance")) or 41
end
local function wantsPlate(enemy)
    if enemy.isDead or enemy.isGone then
        return false
    end
    if enemy.distance > plateRange() then
        return false
    end
    local setting = enemy.reaction >= 5 and "nameplateShowFriends" or "nameplateShowEnemies"
    local value = G.GetCVar and G.GetCVar(setting)
    if enemy.reaction >= 5 then
        return value == "1"
    end
    return value ~= "0"
end
local function placePlate(enemy)
    local frame = G.C_NamePlate.GetNamePlateForUnit(plateToken(enemy))
    if not frame then
        return
    end
    local world = G.WorldFrame
    local halfWidth = (world and world:GetWidth() or sim.screenWidth) / 2
    local halfView = math.rad(50) -- half the camera's view across (a guess at the client's default)
    local x, y
    if math.abs(enemy.bearing) < halfView then
        x = math.tan(enemy.bearing) / math.tan(halfView) * halfWidth
        y = -60 + 200 * math.max(0, math.min(1, (enemy.distance - 5) / 35)) -- the further, the higher on the screen
    else
        x, y = (enemy.bearing > 0 and 1 or -1) * halfWidth * 3, 0
    end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if enemy.plateX == x and enemy.plateY == y then
        return
    end
    enemy.plateX, enemy.plateY = x, y
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", world, "CENTER", x, y)
end
local function addPlate(enemy)
    local index = 1
    while combat.plates[index] or G.C_NamePlate.GetNamePlateForUnit("nameplate" .. index) do
        index = index + 1
    end
    enemy.plateIndex, enemy.plateX, enemy.plateY = index, nil, nil
    combat.plates[index] = enemy
    game.addNamePlate("nameplate" .. index)
    placePlate(enemy)
end
local function removePlate(enemy)
    local index = enemy.plateIndex
    if not index then
        return
    end
    game.removeNamePlate("nameplate" .. index) -- (NAME_PLATE_UNIT_REMOVED while the token still stands for it)
    combat.plates[index] = nil
    enemy.plateIndex = nil
end
local function updatePlates()
    for _, enemy in ipairs(combat.enemies) do
        enemy.distance, enemy.bearing = measure(enemy)
        local wants = wantsPlate(enemy)
        if wants and not enemy.plateIndex then
            addPlate(enemy)
        elseif not wants and enemy.plateIndex then
            removePlate(enemy)
        elseif enemy.plateIndex then
            placePlate(enemy)
        end
    end
end

---Creatures of the game near the player: count of them, distance yards ahead (bearing degrees to the right).
---@param spec { npcId: number?, name: string?, count: number?, distance: number?, bearing: number?, level: number?,
---aggro: boolean?, spellId: number?, isTappedByOthers: boolean?, dropChance: number? }
---@return number[]? ids, string? problem
function combat.spawn(spec)
    spec = spec or {}
    local npcId = tonumber(spec.npcId) or (spec.name and data.findNpc(spec.name))
    if not npcId then
        return nil, "no creature called " .. tostring(spec.name or spec.npcId)
    end
    local creature = data.getCreature(npcId)
    if not creature then
        return nil, "the NPC data has no creature " .. npcId
    end
    local count = math.max(1, math.min(20, math.floor(tonumber(spec.count) or 1)))
    local continentId, north, west = playerPosition()
    local facing = game.profile.facing or 0
    local distance = math.max(0, tonumber(spec.distance) or 20)
    local ids = {}
    for index = 1, count do
        -- Side by side, four yards apart, alternately left and right of the line given
        local step = math.floor(index / 2) * (index % 2 == 0 and 1 or -1)
        local bearing = math.rad(tonumber(spec.bearing) or 0) + (distance > 0 and step * 4 / distance or 0)
        local angle = facing - bearing
        local enemy = makeEnemy(
            creature,
            spec,
            continentId,
            north + math.cos(angle) * distance,
            west + math.sin(angle) * distance
        )
        ids[#ids + 1] = enemy.id
    end
    combat.isEngaged = true
    updatePlates()
    sim.touch()
    return ids
end

-- Being in combat: PLAYER_REGEN_DISABLED before the lockdown (its handlers may still do protected things, as in the
-- client), PLAYER_REGEN_ENABLED after it ends. The page's "In combat" switch stays an override: on, the lockdown
-- holds whatever the fight does
local function playerEntersCombat()
    if player.inCombat then
        return
    end
    player.inCombat = true
    if not sim.inCombat then
        fire("PLAYER_REGEN_DISABLED")
        sim.inCombat = true
        combat.ownsLockdown = true
    end
    fire("UNIT_FLAGS", "player")
    sim.touch()
end
local function playerLeavesCombat()
    if not player.inCombat then
        return
    end
    player.inCombat = false
    if combat.ownsLockdown then
        combat.ownsLockdown = false
        sim.inCombat = false
        fire("PLAYER_REGEN_ENABLED")
    end
    fire("UNIT_FLAGS", "player")
    sim.touch()
end
local function checkCombatEnd()
    if not player.inCombat then
        return
    end
    for _, enemy in ipairs(combat.enemies) do
        if enemy.inCombat and not enemy.isDead and enemy.threat.player then
            return
        end
    end
    playerLeavesCombat()
end

local function threatChanged(enemy)
    fireUnit(enemy, "UNIT_THREAT_LIST_UPDATE")
    fire("UNIT_THREAT_SITUATION_UPDATE", "player")
end

---A creature takes the player on: in combat, the player on its threat list, its friends near it coming along (classic's
---social pull: the same creature within 10 yards, a guess at the radius).
local function engage(enemy)
    if enemy.isDead or enemy.isEvading then
        return
    end
    if not enemy.inCombat then
        enemy.inCombat, enemy.targetUnit = true, "player"
        enemy.threat.player = enemy.threat.player or 0
        enemy.swingAt = math.max(enemy.swingAt, now() + 0.4)
        enemy.nextCastAt = now() + 0.2
        enemy.pulledNorth, enemy.pulledWest = enemy.north, enemy.west
        fireUnit(enemy, "UNIT_FLAGS")
        threatChanged(enemy)
        for _, other in ipairs(combat.enemies) do
            if
                other ~= enemy
                and not other.inCombat
                and not other.isDead
                and other.reaction <= 2
                and other.npcId == enemy.npcId
                and other.isAggressive
                and distanceBetween(other, enemy) <= 10
            then
                engage(other)
            end
        end
    end
    playerEntersCombat()
end

local function addThreat(enemy, amount)
    if enemy.isDead then
        return
    end
    enemy.threat.player = (enemy.threat.player or 0) + math.max(0, amount)
    threatChanged(enemy)
end

local function stopEnemyCast(enemy, interruptedBy)
    local cast = enemy.cast
    if not cast then
        return
    end
    enemy.cast = nil
    if interruptedBy ~= nil then
        fireUnit(enemy, "UNIT_SPELLCAST_INTERRUPTED", cast.castGUID, cast.spellId, interruptedBy)
    end
    fireUnit(enemy, "UNIT_SPELLCAST_STOP", cast.castGUID, cast.spellId)
end

---It gives up the fight (the player went too far, or died): back to where it was pulled from, whole again.
local function evade(enemy)
    stopEnemyCast(enemy, false)
    enemy.inCombat, enemy.isEvading, enemy.targetUnit, enemy.threat = false, true, nil, {}
    clearAuras(enemy)
    logEvent("EVADE", enemy, nil, nil, enemy.name .. " evades.")
    fireUnit(enemy, "UNIT_FLAGS")
    threatChanged(enemy)
end

-- The player's attacks
local function isAttackable(enemy)
    return enemy ~= nil and not enemy.isDead and not enemy.isGone and enemy.reaction <= 4
end

local function playerSwingDamage(isRanged)
    local level = tonumber(game.profile.level) or 1
    local class = tostring(game.profile.class or ""):upper()
    local speed = isRanged and (player.autoRepeatSpellId == data.AUTO_SHOT and 2.8 or 1.5)
        or ((G.UnitAttackSpeed and G.UnitAttackSpeed("player")) or 2)
    -- Melee classes carry most of their damage in their swings, casters little (a hunter's shots most of theirs)
    local share = isRanged and (class == "HUNTER" and 0.6 or 0.4) or (data.MELEE_CLASSES[class] and 0.7 or 0.35)
    return data.playerDps(level) * speed * share * rollBetween(0.85, 1.15), speed
end

local function playerCritChance(isSpell, school)
    if isSpell then
        return (G.GetSpellCritChance and G.GetSpellCritChance(school) or 1)
    end
    return G.GetCritChance and G.GetCritChance() or 5
end

---The player's attack against a creature: the hit table, as classic rolls one (a single roll down miss, dodge, parry,
---glancing, crit, hit), its chances guessed from the level difference
---@param kind "white"|"melee"|"ranged"|"spell"
local function rollPlayerOutcome(enemy, kind, school)
    if enemy.isEvading then
        return "EVADE"
    end
    local difference = math.max(0, enemy.level - (tonumber(game.profile.level) or 1))
    local value = roll() * 100
    local function take(chance)
        if value < chance then
            return true
        end
        value = value - chance
        return false
    end
    if kind == "spell" then
        if take(4 + difference + (difference >= 3 and 8 or 0)) then
            return "RESIST"
        end
        if take(playerCritChance(true, school)) then
            return "CRITICAL"
        end
        return "HIT"
    end
    if take(5 + difference) then
        return "MISS"
    end
    if kind ~= "ranged" then
        if take(5 + difference * 0.5) then
            return "DODGE"
        end
        if take(5) then
            return "PARRY"
        end
    end
    if kind == "white" and enemy.level >= (tonumber(game.profile.level) or 1) and take(10 + difference * 5) then
        return "GLANCING"
    end
    if take(math.max(0, playerCritChance(false) - difference)) then
        return "CRITICAL"
    end
    return "HIT"
end

-- Armor a creature has (a guess: 20 a level) and what it takes off a blow, as classic's formula has it
local function enemyMitigation(enemy)
    local armor = enemy.level * 20
    return 1 - armor / (armor + 400 + 85 * (tonumber(game.profile.level) or 1))
end

local function gainRage(amount)
    if player.powerType ~= POWER.RAGE or amount <= 0 then
        return
    end
    local before = player.power
    player.power = math.min(player.powerMax, player.power + amount)
    if player.power ~= before then
        playerChanged(false, true)
    end
end

local kill -- (below)

---Damage to a creature from the player: it is the player's now (tapped), in combat with them, its health falls, its
---frames hear of it; at 0 it dies.
local function damageEnemy(enemy, amount, school, spell, outcome, event)
    if enemy.isDead then
        return
    end
    amount = math.max(0, math.floor(amount + 0.5))
    if not enemy.isTappedByOthers then
        enemy.isTapped = true
    end
    engage(enemy)
    enemy.health = math.max(0, enemy.health - amount)
    addThreat(enemy, amount)
    fireUnit(enemy, "UNIT_HEALTH")
    fireUnit(
        enemy,
        "UNIT_COMBAT",
        "WOUND",
        (outcome == "CRITICAL" or outcome == "GLANCING" or outcome == "CRUSHING") and outcome or "",
        amount,
        school or 1
    )
    logHit(event, "player", enemy, spell, amount, outcome ~= "HIT" and outcome or nil, school)
    if event == "SWING_DAMAGE" or (spell and spell.isMelee) then
        gainRage(amount / data.rageFactor(tonumber(game.profile.level) or 1) * 7.5)
    end
    if enemy.health <= 0 then
        kill(enemy)
    end
end

local function missEnemy(enemy, outcome, spell, event)
    if not enemy.isTappedByOthers then
        enemy.isTapped = true
    end
    engage(enemy)
    addThreat(enemy, 1)
    fireUnit(enemy, "UNIT_COMBAT", outcome == "RESIST" and "RESIST" or outcome, "", 0, spell and spell.school or 1)
    logHit(event, "player", enemy, spell, nil, outcome)
end

local stopAutoAttack, playerDies

---Damage to the player: an absorb takes its share first, a cast in progress is pushed back, rage comes from it.
local function damagePlayer(source, amount, school, spell, outcome, event)
    if player.isDead or player.isGhost then
        return
    end
    ensurePlayer()
    amount = math.max(0, math.floor(amount + 0.5))
    local absorbed = 0
    if player.absorb > 0 and amount > 0 then
        absorbed = math.min(player.absorb, amount)
        player.absorb = player.absorb - absorbed
        amount = amount - absorbed
        if player.absorb <= 0 then
            local shield = hasAura(player, data.AURA.SCHOOL_ABSORB)
            if shield then
                removeAura(player, shield)
            end
        end
    end
    player.health = math.max(0, player.health - amount)
    if amount > 0 then
        gainRage(amount / data.rageFactor(tonumber(game.profile.level) or 1) * 2.5)
    end
    -- A cast is pushed back half a second a blow, two seconds at most (a guess at the client's rule)
    local cast = player.cast
    if cast and not cast.isChannel and amount > 0 and cast.pushback < 2 then
        cast.pushback = cast.pushback + 0.5
        cast.endTime = cast.endTime + 0.5
        fire("UNIT_SPELLCAST_DELAYED", "player", cast.castGUID, cast.spellId)
    end
    fire("UNIT_HEALTH", "player")
    fire(
        "UNIT_COMBAT",
        "player",
        absorbed > 0 and amount == 0 and "ABSORB" or "WOUND",
        (outcome == "CRITICAL" or outcome == "CRUSHING" or outcome == "GLANCING") and outcome or "",
        amount,
        school or 1
    )
    logHit(
        event,
        source,
        "player",
        spell,
        amount,
        absorbed > 0 and amount == 0 and "ABSORB" or (outcome ~= "HIT" and outcome or nil),
        school
    )
    if player.health <= 0 then
        playerDies()
    end
end

local function healPlayer(amount, spell, outcome, event)
    if player.isDead or player.isGhost then
        return
    end
    ensurePlayer()
    amount = math.floor(amount + 0.5)
    local before = player.health
    player.health = math.min(player.healthMax, player.health + amount)
    if player.health ~= before then
        fire("UNIT_HEALTH", "player")
    end
    logHit(event or "SPELL_HEAL", "player", "player", spell, amount, outcome ~= "HIT" and outcome or nil)
    -- Healing draws half its worth of threat from every creature fighting the player
    for _, enemy in ipairs(combat.enemies) do
        if enemy.inCombat and enemy.threat.player then
            addThreat(enemy, amount * 0.5)
        end
    end
end

-- Loot: what a creature leaves (money for most, the quest items it drops for the log)
local function makeLoot(enemy)
    local slots = {}
    -- Copper, by level, for three creatures in four (a guess)
    if roll() < 0.75 then
        local copper =
            math.max(1, math.floor((enemy.level * enemy.level * 0.4 + enemy.level * 3 + 2) * rollBetween(0.6, 1.4)))
        if enemy.rank == 1 or enemy.rank == 2 then
            copper = copper * 2
        end
        slots[#slots + 1] = { isMoney = true, quantity = copper }
    end
    local seen = {}
    game.rollQuestDrops(enemy.npcId, enemy.dropChance, function(itemId)
        if seen[itemId] then
            return
        end
        seen[itemId] = true
        local item = game.items and game.items[itemId]
        slots[#slots + 1] = {
            itemId = itemId,
            quantity = 1,
            isQuestItem = true,
            name = item and item.name or ("Item " .. itemId),
            icon = item and item.icon or 134400,
            quality = item and item.quality or 1,
        }
    end)
    return slots
end

local function gainExperience(amount, enemyName)
    local profile = game.profile
    if amount <= 0 or (tonumber(profile.level) or 1) >= 60 then
        return
    end
    profile.xp = (profile.xp or 0) + amount
    fire(
        "CHAT_MSG_COMBAT_XP_GAIN",
        string.format(text("COMBATLOG_XPGAIN_FIRSTPERSON", "%s dies, you gain %d experience."), enemyName, amount),
        "",
        "",
        "",
        "",
        "",
        0,
        0,
        "",
        0,
        0,
        "",
        0,
        false,
        false,
        false,
        false
    )
    fire("PLAYER_XP_UPDATE", "player")
    while profile.xp >= (profile.xpMax or math.huge) and profile.level < 60 do
        local oldLevel = profile.level
        profile.xp = profile.xp - profile.xpMax
        profile.level = oldLevel + 1
        profile.xpMax = data.levelExperience(profile.level)
        local class = tostring(profile.class or "WARRIOR"):upper()
        local oldHealth, oldMana = data.playerMaxima(class, profile.race, oldLevel)
        local newHealth, newMana = data.playerMaxima(class, profile.race, profile.level)
        local stats = require("stats")
        local before, after = stats.base(profile.race, class, oldLevel), stats.base(profile.race, class, profile.level)
        -- A level up fills health and mana, as in classic
        ensurePlayer()
        player.health = player.healthMax
        if player.powerType == POWER.MANA then
            player.power = player.powerMax
        end
        fire(
            "PLAYER_LEVEL_UP",
            profile.level,
            newHealth - oldHealth,
            newMana - oldMana,
            profile.level >= 10 and 1 or 0,
            0,
            after[1] - before[1],
            after[2] - before[2],
            after[3] - before[3],
            after[4] - before[4]
        )
        fire("PLAYER_LEVEL_CHANGED", oldLevel, profile.level, true)
        fire("UNIT_LEVEL", "player")
        fire("UNIT_MAXHEALTH", "player")
        fire("UNIT_MAXPOWER", "player", powerToken(player.powerType))
        playerChanged(true, true)
        fire("PLAYER_XP_UPDATE", "player")
    end
    sim.touch()
end

---A creature dies: health 0, the client's PARTY_KILL (a kill of the player's) and UNIT_DIED, its nameplate taken
---away; the player's kill counts for quests, gives experience and leaves loot.
kill = function(enemy)
    stopEnemyCast(enemy, false)
    enemy.isDead, enemy.health, enemy.inCombat, enemy.targetUnit, enemy.isEvading = true, 0, false, nil, false
    enemy.diedAt = now()
    enemy.threat = {}
    clearAuras(enemy)
    fireUnit(enemy, "UNIT_FLAGS")
    threatChanged(enemy)
    local isPlayersKill = enemy.isTapped and not enemy.isTappedByOthers
    logEvent("UNIT_DIED", nil, enemy, nil, enemy.name .. " dies.")
    if isPlayersKill then
        logEvent("PARTY_KILL", "player", enemy, nil, "You have slain " .. enemy.name .. "!")
        fire("PARTY_KILL", sim.hide(G.UnitGUID("player"), "identity"), sim.hide(enemy.guid, "identity"))
    end
    fire("UNIT_DIED", sim.hide(enemy.guid, "identity"))
    removePlate(enemy)
    if player.comboTarget == enemy then
        player.comboTarget, player.comboPoints = nil, 0
    end
    if combat.target == enemy and player.isAutoAttacking then
        stopAutoAttack()
    end
    if player.cast and player.cast.target == enemy and not player.cast.isChannel then
        combat.interruptPlayerCast("SPELL_FAILED_TARGETS_DEAD")
    end
    if isPlayersKill then
        game.creditKill(enemy.npcId)
        gainExperience(data.killExperience(tonumber(game.profile.level) or 1, enemy.level, enemy.rank), enemy.name)
        enemy.loot = makeLoot(enemy)
    else
        enemy.loot = {}
    end
    enemy.isLootable = #enemy.loot > 0
    checkCombatEnd()
    sim.touch()
end

-- Turning auto-attack on and off: PLAYER_ENTER_COMBAT / PLAYER_LEAVE_COMBAT are the client's events for the swinging,
-- not for being in combat (that is PLAYER_REGEN_*)
local function startAutoAttack(spellId)
    local target = combat.target
    if not target then
        return errorMessage("ERR_NO_ATTACK_TARGET", "There is nothing to attack.")
    end
    if not isAttackable(target) then
        return errorMessage("ERR_INVALID_ATTACK_TARGET", "You cannot attack that target.")
    end
    local isRepeat = spellId == data.AUTO_SHOT or spellId == data.SHOOT
    if isRepeat then
        if player.autoRepeatSpellId == spellId then
            return true
        end
        player.autoRepeatSpellId = spellId
        fire("START_AUTOREPEAT_SPELL")
    elseif not player.isAutoAttacking then
        fire("PLAYER_ENTER_COMBAT")
    end
    if not player.isAutoAttacking or isRepeat then
        player.isAutoAttacking = true
        player.rangeWarned = false
        player.swingAt = math.max(player.swingAt, now())
    end
    if target.reaction <= 2 or target.inCombat then
        engage(target)
    end
    fire("ACTIONBAR_UPDATE_STATE")
    return true
end
stopAutoAttack = function()
    if not player.isAutoAttacking then
        return
    end
    player.isAutoAttacking = false
    if player.autoRepeatSpellId then
        player.autoRepeatSpellId = nil
        fire("STOP_AUTOREPEAT_SPELL")
    else
        fire("PLAYER_LEAVE_COMBAT")
    end
    fire("ACTIONBAR_UPDATE_STATE")
end

-- Spells
local function rollBase(effect)
    local variance = effect.variance or 0
    return effect.base * (1 + variance * (roll() - 0.5))
end

local function spellOnBars(spellId)
    for _, action in pairs(require("actions").getSlots(game)) do
        if action.type == "spell" and action.id == spellId then
            return true
        end
    end
    return require("actions").isClassSpell(game.profile.class, spellId)
end

local function needsEnemy(spell)
    for _, effect in ipairs(spell.effects) do
        if effect.target == data.TARGET.ENEMY or effect.target2 == data.TARGET.ENEMY then
            return true
        end
    end
    -- (no effects known: a spell at range with no table to say otherwise is aimed at the target)
    return #spell.effects == 0 and not spell.isSelf and spell.rangeMax > 0
end
local function isAreaAroundCaster(effect)
    return effect.target == data.TARGET.SOURCE_CASTER
        and (effect.target2 == data.TARGET.AREA_ENEMY_AROUND_SOURCE or effect.target2 == data.TARGET.AREA_ENEMY)
end
local function usesComboPoints(spell)
    for _, effect in ipairs(spell.effects) do
        if effect.perResource ~= 0 then
            return true
        end
    end
    return false
end

local function costOf(spell)
    local cost = spell.cost or 0
    -- Mana costs grow with the rank of the character's level, as the damage does (a guess: rank 1's cost times the
    -- level's factor, without the steeper curve)
    if spell.powerType == POWER.MANA and cost > 0 then
        cost = math.floor(cost * data.rankFactor(spell, tonumber(game.profile.level) or 1, 1.0) + 0.5)
    end
    return cost
end
local function canPay(spell)
    ensurePlayer()
    local cost = costOf(spell)
    if cost <= 0 then
        return true
    end
    if spell.powerType ~= player.powerType then
        return false
    end -- (a power the class does not have)
    return player.power >= cost
end
local function pay(spell)
    local cost = costOf(spell)
    if cost <= 0 or spell.powerType ~= player.powerType then
        return
    end
    player.power = math.max(0, player.power - cost)
    if player.powerType == POWER.MANA then
        player.lastManaSpend = now()
    end
    playerChanged(false, true)
end
local function notEnoughPower(spell)
    if spell.powerType == POWER.RAGE then
        return errorMessage("ERR_OUT_OF_RAGE", "Not enough rage")
    end
    if spell.powerType == POWER.ENERGY then
        return errorMessage("ERR_OUT_OF_ENERGY", "Not enough energy")
    end
    return errorMessage("ERR_OUT_OF_MANA", "Not enough mana")
end

local function newCastGUID(spellId)
    castCount = castCount + 1
    return string.format("Cast-3-1-0-0-%d-%010X", spellId, castCount)
end

local function cooldownLeft(spellId)
    local cooldown = player.cooldowns[spellId]
    if cooldown and now() < cooldown.start + cooldown.duration then
        return cooldown.start + cooldown.duration - now()
    end
    return 0
end
local function isOnGcd(spell)
    return spell.gcd > 0 and now() < player.gcdStart + player.gcdDuration
end

local function cooldownsChanged()
    fire("SPELL_UPDATE_COOLDOWN")
    fire("ACTIONBAR_UPDATE_COOLDOWN")
end

local refreshUsable -- (below)

---What a spell does to its targets once cast: its effects in the game's tables, the damage and healing made to fit
---the character's level (rank 1's numbers grown by data.rankFactor), one hit roll per target.
local function applySpell(spell, target, castGUID)
    local level = tonumber(game.profile.level) or 1
    local comboPoints = (player.comboTarget == target) and player.comboPoints or 0
    local targets = {}
    if target then
        targets[#targets + 1] = target
    end
    local isArea = false
    for _, effect in ipairs(spell.effects) do
        if isAreaAroundCaster(effect) then
            isArea = true
            break
        end
    end
    if isArea then
        targets = {}
        local radius = 10
        for _, effect in ipairs(spell.effects) do
            if isAreaAroundCaster(effect) then
                radius = data.getRadius(effect.radiusIndex)
                break
            end
        end
        for _, enemy in ipairs(combat.enemies) do
            if isAttackable(enemy) and enemy.distance <= radius then
                targets[#targets + 1] = enemy
            end
        end
    end
    local hasHarmful, weaponPart, weaponPercent, weaponBonus, schoolPart = false, nil, 1, 0, 0
    for _, effect in ipairs(spell.effects) do
        local kind = effect.effect
        if kind == data.EFFECT.SCHOOL_DAMAGE then
            schoolPart = schoolPart
                + rollBase(effect) * data.rankFactor(spell, level, 1.4)
                + effect.perResource * comboPoints * data.rankFactor(spell, level, 1.4)
            hasHarmful = true
        elseif
            kind == data.EFFECT.WEAPON_DAMAGE_NOSCHOOL
            or kind == data.EFFECT.WEAPON_DAMAGE
            or kind == data.EFFECT.NORMALIZED_WEAPON_DMG
        then
            weaponPart = weaponPart or playerSwingDamage(spell.rangeMax > 5)
            weaponBonus = weaponBonus + rollBase(effect) * data.rankFactor(spell, level, 1.0)
            hasHarmful = true
        elseif kind == data.EFFECT.WEAPON_PERCENT_DAMAGE then
            weaponPart = weaponPart or playerSwingDamage(false)
            weaponPercent = effect.base / 100
            hasHarmful = true
        end
    end
    local kind = (weaponPart or spell.isMelee) and (spell.rangeMax > 5 and "ranged" or "melee") or "spell"
    local outcomes = {}
    for _, enemy in ipairs(targets) do
        if enemy.reaction <= 4 then
            local outcome = rollPlayerOutcome(enemy, kind, spell.school)
            outcomes[enemy] = outcome
            local isHit = outcome == "HIT" or outcome == "CRITICAL"
            if not isHit then
                missEnemy(enemy, outcome, spell, "SPELL_MISSED")
            elseif hasHarmful then
                local amount = schoolPart
                if weaponPart then
                    amount = amount + weaponPart * weaponPercent + weaponBonus
                end
                if weaponPart or spell.school == 1 then
                    amount = amount * enemyMitigation(enemy)
                end
                if outcome == "CRITICAL" then
                    amount = amount * (kind == "spell" and 1.5 or 2)
                end
                damageEnemy(enemy, amount, spell.school, spell, outcome, "SPELL_DAMAGE")
            else
                -- A harmful spell without damage of its own (a curse, a sting's first moment): the fight is on
                if not enemy.isTappedByOthers then
                    enemy.isTapped = true
                end
                engage(enemy)
                addThreat(enemy, 10)
            end
        end
    end
    -- The rest of its effects, on whom they fall
    for _, effect in ipairs(spell.effects) do
        local kind = effect.effect
        local onSelf = effect.target == data.TARGET.CASTER
            or effect.target == data.TARGET.FRIEND
            or (effect.target == data.TARGET.ANY and not (target and target.reaction <= 4))
        if kind == data.EFFECT.HEAL then
            local amount = rollBase(effect) * data.rankFactor(spell, level, 1.4)
            local isCrit = roll() * 100 < playerCritChance(true, spell.school)
            healPlayer(amount * (isCrit and 1.5 or 1), spell, isCrit and "CRITICAL" or "HIT")
        elseif kind == data.EFFECT.APPLY_AURA or kind == data.EFFECT.APPLY_AREA_AURA_PARTY then
            local amount = math.abs(rollBase(effect)) * data.rankFactor(spell, level, 1.4)
            if onSelf or kind == data.EFFECT.APPLY_AREA_AURA_PARTY then
                if not player.isDead then
                    addAura(player, spell, effect, false, amount)
                end
            else
                for _, enemy in ipairs(targets) do
                    local outcome = outcomes[enemy]
                    if not enemy.isDead and (outcome == "HIT" or outcome == "CRITICAL") then
                        addAura(enemy, spell, effect, true, amount)
                    end
                end
            end
        elseif kind == data.EFFECT.ENERGIZE then
            if effect.misc == POWER.COMBO_POINTS then
                if target and (outcomes[target] == "HIT" or outcomes[target] == "CRITICAL") then
                    if player.comboTarget ~= target then
                        player.comboTarget, player.comboPoints = target, 0
                    end
                    player.comboPoints = math.min(5, player.comboPoints + math.max(1, math.floor(effect.base)))
                    fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
                    fire("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS")
                end
            elseif effect.misc == player.powerType then
                local amount = effect.misc == POWER.RAGE and effect.base / 10 or effect.base
                player.power = math.min(player.powerMax, player.power + amount)
                playerChanged(false, true)
                logHit("SPELL_ENERGIZE", "player", "player", spell, math.floor(amount), nil)
            end
        elseif kind == data.EFFECT.INTERRUPT_CAST then
            if
                target
                and target.cast
                and not target.cast.notInterruptible
                and (outcomes[target] == "HIT" or outcomes[target] == "CRITICAL")
            then
                logEvent(
                    "SPELL_INTERRUPT",
                    "player",
                    target,
                    spell,
                    string.format("Your %s interrupts %s's %s.", spell.name, target.name, target.cast.name)
                )
                stopEnemyCast(target, G.UnitGUID("player"))
                target.nextCastAt = now() + 6
            end
        elseif kind == data.EFFECT.ATTACK then
            startAutoAttack(data.AUTO_ATTACK)
        elseif kind == data.EFFECT.CHARGE and target then
            -- The player runs at the target and stands at its side
            local continentId, north, west = playerPosition()
            if target.continentId == continentId and target.distance > MELEE_RANGE then
                local share = (target.distance - 3) / target.distance
                local toNorth, toWest = north + (target.north - north) * share, west + (target.west - west) * share
                if continentId ~= "instance" then
                    local uiMapId, x, y = game.findZoneAt(continentId, toNorth, toWest, game.profile.uiMapId)
                    if uiMapId then
                        game.setPosition(uiMapId, x, y)
                    end
                end
            end
        end
    end
    if usesComboPoints(spell) and comboPoints > 0 then
        player.comboPoints = 0
        fire("UNIT_POWER_UPDATE", "player", "COMBO_POINTS")
        fire("UNIT_POWER_FREQUENT", "player", "COMBO_POINTS")
    end
end

local function spellTarget(spell, unit)
    if not needsEnemy(spell) then
        return nil
    end
    if unit then
        local kind, enemy = resolve(unit)
        if kind == "enemy" then
            return enemy
        end
    end
    return combat.target
end

local function checkRange(spell, target)
    if not target then
        return true
    end
    local distance = target.distance
    if spell.isMelee then
        return distance <= MELEE_RANGE
    end
    if spell.rangeMax > 0 and distance > spell.rangeMax then
        return false
    end
    return true
end

---The cast ends: power spent, the cooldown started, the client's STOP then SUCCEEDED (the order is a guess), and the
---spell's effects on its target.
local function completeCast()
    local cast = player.cast
    player.cast = nil
    local spell, target = cast.spell, cast.target
    pay(spell)
    local cooldown = math.max(spell.cooldown, spell.categoryCooldown)
    if cooldown > 0 then
        player.cooldowns[spell.id] = { start = now(), duration = cooldown }
    end
    fire("UNIT_SPELLCAST_STOP", "player", cast.castGUID, spell.id)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast.castGUID, spell.id)
    logEvent(
        "SPELL_CAST_SUCCESS",
        "player",
        target,
        spell,
        "You cast " .. spell.name .. (target and (" on " .. target.name) or "") .. "."
    )
    if cooldown > 0 then
        cooldownsChanged()
    end
    fire("ACTIONBAR_UPDATE_STATE")
    if target and target.isDead then
        return
    end
    applySpell(spell, target, cast.castGUID)
    refreshUsable()
end

---A cast stops before its end (moved, the target died, stopped): INTERRUPTED then STOP, as the cast bar needs them
---to show it interrupted.
function combat.interruptPlayerCast(reason)
    local cast = player.cast
    if not cast then
        return false
    end
    player.cast = nil
    if cast.isChannel then
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", cast.castGUID, cast.spell.id, G.UnitGUID("player"))
    else
        fire("UNIT_SPELLCAST_INTERRUPTED", "player", cast.castGUID, cast.spell.id, G.UnitGUID("player"))
        fire("UNIT_SPELLCAST_STOP", "player", cast.castGUID, cast.spell.id)
    end
    if reason then
        errorMessage(reason, text(reason, "Interrupted"))
    end
    logEvent("SPELL_CAST_FAILED", "player", cast.target, cast.spell, "Your " .. cast.spell.name .. " was interrupted.")
    fire("ACTIONBAR_UPDATE_STATE")
    return true
end

---The player casts a spell: every check the client makes first (dead, busy, the global cooldown, the spell's own
---cooldown, power, a target, its range), then SENT and START (a cast with a cast time, on the cast bar),
---CHANNEL_START (a channel), or straight on to its end (an instant). A spell that waits for the next swing (Heroic
---Strike) is queued.
---@return boolean isCast, string? problem
function combat.castSpell(spellId, unit)
    spellId = tonumber(spellId)
    local spell = spellId and data.getSpell(spellId)
    if not spell then
        return false, "no such spell"
    end
    ensurePlayer()
    if player.isDead or player.isGhost then
        return errorMessage("SPELL_FAILED_CASTER_DEAD", "You are dead")
    end
    if spell.isPassive then
        return false, "a passive spell"
    end
    if spell.isAutoAttack then
        if player.isAutoAttacking and not player.autoRepeatSpellId then
            stopAutoAttack()
            return true
        end
        return startAutoAttack(spellId)
    end
    if spell.isAutoRepeat then
        if player.autoRepeatSpellId == spellId then
            stopAutoAttack()
            return true
        end
        local target = combat.target
        if target and target.distance > spell.rangeMax then
            return errorMessage("SPELL_FAILED_OUT_OF_RANGE", "Out of range.")
        end
        if player.isAutoAttacking and not player.autoRepeatSpellId then
            stopAutoAttack()
        end
        return startAutoAttack(spellId)
    end
    if player.cast then
        return errorMessage("SPELL_FAILED_SPELL_IN_PROGRESS", "Another action is in progress")
    end
    if isOnGcd(spell) or cooldownLeft(spellId) > 0 then
        return errorMessage("SPELL_FAILED_NOT_READY", "Spell is not ready yet.")
    end
    if not canPay(spell) then
        return notEnoughPower(spell)
    end
    local target = spellTarget(spell, unit)
    if needsEnemy(spell) then
        if not target then
            return errorMessage("ERR_GENERIC_NO_TARGET", "You have no target.")
        end
        if target.isDead then
            return errorMessage("SPELL_FAILED_TARGETS_DEAD", "Your target is dead")
        end
        if target.reaction >= 5 then
            return errorMessage("SPELL_FAILED_BAD_TARGETS", "Invalid target")
        end
        if not checkRange(spell, target) then
            return errorMessage("SPELL_FAILED_OUT_OF_RANGE", "Out of range.")
        end
        if spell.rangeMin > 0 and target.distance < spell.rangeMin then
            return errorMessage("SPELL_FAILED_TOO_CLOSE", "Target too close")
        end
    end
    if usesComboPoints(spell) and not (player.comboTarget == target and player.comboPoints > 0) then
        return errorMessage("SPELL_FAILED_NO_COMBO_POINTS", "That ability requires combo points")
    end
    if spell.isOnNextSwing then
        -- Waits for the next swing: auto-attack comes on with it, the cost is paid when it lands
        player.queuedSpellId = spellId
        startAutoAttack(data.AUTO_ATTACK)
        fire("ACTIONBAR_UPDATE_STATE")
        return true
    end
    local castGUID = newCastGUID(spellId)
    fire("UNIT_SPELLCAST_SENT", "player", target and target.name or "", castGUID, spellId)
    -- (where the cast starts: only a move after this breaks it)
    player.lastPosition = { game.profile.uiMapId, game.profile.x, game.profile.y }
    if spell.gcd > 0 then
        player.gcdStart, player.gcdDuration = now(), spell.gcd
        cooldownsChanged()
    end
    local castTime = spell.castTime
    if spell.isChanneled then
        local duration = spell.duration > 0 and spell.duration or 3
        pay(spell)
        player.cast = {
            spell = spell,
            target = target,
            castGUID = castGUID,
            spellId = spellId,
            startTime = now(),
            endTime = now() + duration,
            isChannel = true,
            pushback = 0,
            nextTick = now() + 1,
        }
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", castGUID, spellId)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", castGUID, spellId)
        logEvent("SPELL_CAST_SUCCESS", "player", target, spell, "You cast " .. spell.name .. ".")
        fire("ACTIONBAR_UPDATE_STATE")
        if target then
            engage(target)
        end
        return true
    end
    player.cast = {
        spell = spell,
        target = target,
        castGUID = castGUID,
        spellId = spellId,
        startTime = now(),
        endTime = now() + castTime,
        isChannel = false,
        pushback = 0,
    }
    if castTime > 0 then
        fire("UNIT_SPELLCAST_START", "player", castGUID, spellId)
        logEvent("SPELL_CAST_START", "player", target, spell, "You begin to cast " .. spell.name .. ".")
        fire("ACTIONBAR_UPDATE_STATE")
        return true
    end
    completeCast()
    return true
end

-- Ticking channels: their periodic effect each second (Arcane Missiles' missiles, Drain Life's drain)
local function tickChannel(cast)
    local spell, target = cast.spell, cast.target
    local level = tonumber(game.profile.level) or 1
    for _, effect in ipairs(spell.effects) do
        if
            effect.effect == data.EFFECT.APPLY_AURA
            and (
                effect.aura == data.AURA.PERIODIC_DAMAGE
                or effect.aura == data.AURA.PERIODIC_LEECH
                or effect.aura == 23
            )
        then
            if target and not target.isDead then
                local amount = math.max(1, rollBase(effect)) * data.rankFactor(spell, level, 1.4)
                if effect.aura == 23 then
                    amount = 24 * data.rankFactor(spell, level, 1.4)
                end -- (Arcane Missiles: its missile's own spell, guessed)
                local outcome = rollPlayerOutcome(target, "spell", spell.school)
                if outcome == "HIT" or outcome == "CRITICAL" then
                    damageEnemy(
                        target,
                        amount * (outcome == "CRITICAL" and 1.5 or 1),
                        spell.school,
                        spell,
                        outcome,
                        "SPELL_PERIODIC_DAMAGE"
                    )
                    if effect.aura == data.AURA.PERIODIC_LEECH then
                        healPlayer(amount, spell, "HIT", "SPELL_PERIODIC_HEAL")
                    end
                else
                    missEnemy(target, outcome, spell, "SPELL_PERIODIC_MISSED")
                end
            end
        end
    end
end

-- Swings
local function playerSwing(target, isRanged)
    local spellId = player.queuedSpellId
    if spellId and not isRanged then
        player.queuedSpellId = nil
        local spell = data.getSpell(spellId)
        if spell and canPay(spell) then
            pay(spell)
            local castGUID = newCastGUID(spellId)
            fire("UNIT_SPELLCAST_SENT", "player", target.name, castGUID, spellId)
            fire("UNIT_SPELLCAST_SUCCEEDED", "player", castGUID, spellId)
            fire("ACTIONBAR_UPDATE_STATE")
            applySpell(spell, target, castGUID)
            return
        end
        fire("ACTIONBAR_UPDATE_STATE")
    end
    local amount = playerSwingDamage(isRanged)
    local outcome = rollPlayerOutcome(target, isRanged and "ranged" or "white", 1)
    if isRanged then
        local castGUID = newCastGUID(player.autoRepeatSpellId)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", castGUID, player.autoRepeatSpellId)
    end
    local event = isRanged and "RANGE_DAMAGE" or "SWING_DAMAGE"
    local spell = isRanged and data.getSpell(player.autoRepeatSpellId) or nil
    if outcome == "HIT" or outcome == "CRITICAL" or outcome == "GLANCING" then
        amount = amount * enemyMitigation(target)
        if outcome == "CRITICAL" then
            amount = amount * 2
        elseif outcome == "GLANCING" then
            amount = amount * 0.7
        end
        damageEnemy(target, amount, 1, spell, outcome, event)
    else
        missEnemy(target, outcome, spell, isRanged and "RANGE_MISSED" or "SWING_MISSED")
    end
end

local function enemySwing(enemy)
    ensurePlayer()
    local playerLevel = tonumber(game.profile.level) or 1
    local difference = enemy.level - playerLevel
    local value = roll() * 100
    local function take(chance)
        if value < chance then
            return true
        end
        value = value - math.max(0, chance)
        return false
    end
    local outcome = "HIT"
    if take(math.max(0, 5 - difference * 0.5)) then
        outcome = "MISS"
    elseif take(G.GetDodgeChance and G.GetDodgeChance() or 5) then
        outcome = "DODGE"
    elseif take(G.GetParryChance and G.GetParryChance() or 0) then
        outcome = "PARRY"
    elseif combat.hasShield() and take(G.GetBlockChance and G.GetBlockChance() or 5) then
        outcome = "BLOCK"
    elseif take(5 + math.max(0, difference)) then
        outcome = "CRITICAL"
    elseif difference >= 4 and take(15) then
        outcome = "CRUSHING"
    end
    if outcome == "MISS" or outcome == "DODGE" or outcome == "PARRY" then
        fire("UNIT_COMBAT", "player", outcome, "", 0, 1)
        logHit("SWING_MISSED", enemy, "player", nil, nil, outcome)
        return
    end
    local amount = data.guessCreatureSwing(enemy.level, enemy.rank)
        * rollBetween(0.85, 1.15)
        * (1 + 0.05 * math.max(0, difference))
    local armor = G.UnitArmor and select(2, G.UnitArmor("player")) or 0
    amount = amount * (1 - armor / (armor + 400 + 85 * enemy.level))
    if outcome == "CRITICAL" then
        amount = amount * 2
    elseif outcome == "CRUSHING" then
        amount = amount * 1.5
    elseif outcome == "BLOCK" then
        amount = math.max(0, amount - (tonumber(playerLevel) * 2 + 10))
    end
    damagePlayer(enemy, amount, 1, nil, outcome, "SWING_DAMAGE")
end

---Does the player hold a shield (the off hand's item an armor of the shield kind): only then can they block
function combat.hasShield()
    local itemId = G.GetInventoryItemID and G.GetInventoryItemID("player", 17)
    local item = itemId and game.items and game.items[itemId]
    return item ~= nil and item.classId == 4 and item.subclassId == 6
end

local function startEnemyCast(enemy)
    local spell = data.getSpell(enemy.spellId)
    if not spell then
        enemy.spellId = nil
        return
    end
    -- A creature's bolt takes two seconds at least (rank 1's 1.5 seconds is the player's)
    local castTime = math.max(2, spell.castTime)
    local castGUID = newCastGUID(spell.id)
    enemy.cast = {
        spellId = spell.id,
        name = spell.name,
        icon = spell.icon,
        startTime = now(),
        endTime = now() + castTime,
        castGUID = castGUID,
        notInterruptible = false,
        spell = spell,
    }
    fireUnit(enemy, "UNIT_SPELLCAST_START", castGUID, spell.id)
    logEvent("SPELL_CAST_START", enemy, "player", spell, enemy.name .. " begins to cast " .. spell.name .. ".")
end
local function finishEnemyCast(enemy)
    local cast = enemy.cast
    enemy.cast = nil
    fireUnit(enemy, "UNIT_SPELLCAST_STOP", cast.castGUID, cast.spellId)
    fireUnit(enemy, "UNIT_SPELLCAST_SUCCEEDED", cast.castGUID, cast.spellId)
    enemy.nextCastAt = now() + rollBetween(7, 11)
    enemy.swingAt = math.max(enemy.swingAt, now() + 0.5)
    if player.isDead or player.isGhost then
        return
    end
    local spell = cast.spell
    if roll() < 0.05 + math.max(0, (tonumber(game.profile.level) or 1) - enemy.level) * 0.01 then
        fire("UNIT_COMBAT", "player", "RESIST", "", 0, spell.school)
        logHit("SPELL_MISSED", enemy, "player", spell, nil, "RESIST")
        return
    end
    local isCrit = roll() < 0.05
    local amount = data.guessCreatureSwing(enemy.level, enemy.rank)
        * 1.6
        * rollBetween(0.85, 1.15)
        * (isCrit and 1.5 or 1)
    damagePlayer(enemy, amount, spell.school, spell, isCrit and "CRITICAL" or "HIT", "SPELL_DAMAGE")
end

local function moveEnemyToward(enemy, north, west, yards, stopAt)
    local dNorth, dWest = north - enemy.north, west - enemy.west
    local distance = math.sqrt(dNorth * dNorth + dWest * dWest)
    if distance <= (stopAt or 0) or distance == 0 then
        return distance
    end
    local step = math.min(yards, distance - (stopAt or 0))
    enemy.north, enemy.west = enemy.north + dNorth / distance * step, enemy.west + dWest / distance * step
    return distance - step
end

-- Auras over time: periodic damage and healing, and their end
local function updateAuras(holder, time)
    for index = #holder.auras, 1, -1 do
        local aura = holder.auras[index]
        if aura and aura.period and aura.nextTick and time >= aura.nextTick then
            aura.nextTick = aura.nextTick + aura.period
            if holder == player then
                if aura.auraType == data.AURA.PERIODIC_HEAL then
                    healPlayer(aura.amount or 1, aura.spell, "HIT", "SPELL_PERIODIC_HEAL")
                end
            elseif aura.auraType == data.AURA.PERIODIC_DAMAGE or aura.auraType == data.AURA.PERIODIC_LEECH then
                damageEnemy(holder, aura.amount or 1, aura.school, aura.spell, "HIT", "SPELL_PERIODIC_DAMAGE")
            end
        end
        if aura and aura.expirationTime > 0 and time >= aura.expirationTime and holder.auras[index] == aura then
            removeAura(holder, aura)
        end
    end
end

local function updateEnemy(enemy, dt, time)
    if enemy.isDead then
        if time - (enemy.diedAt or time) > ((enemy.isLooted or not enemy.isLootable) and 120 or CORPSE_SECONDS) then
            combat.despawn(enemy.id)
        end
        return
    end
    updateAuras(enemy, time)
    if enemy.isDead then
        return
    end
    if enemy.isEvading then
        local left = moveEnemyToward(
            enemy,
            enemy.pulledNorth or enemy.homeNorth,
            enemy.pulledWest or enemy.homeWest,
            RUN_SPEED * 2 * dt,
            0
        )
        if left < 0.5 then
            enemy.isEvading = false
            if enemy.health ~= enemy.healthMax then
                enemy.health = enemy.healthMax
                fireUnit(enemy, "UNIT_HEALTH")
            end
        end
        return
    end
    if not enemy.inCombat then
        -- Out of combat a creature heals quickly (a tenth of its health a second, a guess), and a hostile one that sees
        -- the player near enough (20 yards, one more or less for each level between them, 5 to 45) attacks
        if enemy.health < enemy.healthMax and time >= (enemy.nextRegenAt or 0) then
            enemy.nextRegenAt = time + 1
            enemy.health = math.min(enemy.healthMax, enemy.health + math.ceil(enemy.healthMax / 10))
            fireUnit(enemy, "UNIT_HEALTH")
        end
        if
            enemy.isAggressive
            and enemy.reaction <= 2
            and not enemy.isTappedByOthers
            and not player.isDead
            and not player.isGhost
        then
            local radius = math.max(5, math.min(45, 20 + enemy.level - (tonumber(game.profile.level) or 1)))
            if enemy.distance <= radius then
                engage(enemy)
            end
        end
        return
    end
    if player.isDead or player.isGhost then
        evade(enemy)
        checkCombatEnd()
        return
    end
    -- Too far from where it was pulled, or the player gone off: it gives up
    local fromPull = math.sqrt(
        (enemy.north - (enemy.pulledNorth or enemy.north)) ^ 2 + (enemy.west - (enemy.pulledWest or enemy.west)) ^ 2
    )
    if fromPull > LEASH or enemy.distance == math.huge or enemy.distance > LEASH + 40 then
        evade(enemy)
        checkCombatEnd()
        return
    end
    if enemy.cast then
        if time >= enemy.cast.endTime then
            finishEnemyCast(enemy)
        end
        return
    end
    if hasAura(enemy, data.AURA.MOD_STUN) then
        return
    end
    local continentId, north, west = playerPosition()
    if hasAura(enemy, data.AURA.MOD_FEAR) then
        -- Running off, away from the player
        moveEnemyToward(
            enemy,
            enemy.north + (enemy.north - north),
            enemy.west + (enemy.west - west),
            RUN_SPEED * 0.6 * dt,
            0
        )
        enemy.distance, enemy.bearing = measure(enemy)
        return
    end
    if enemy.spellId and time >= enemy.nextCastAt and enemy.distance <= 30 then
        startEnemyCast(enemy)
        return
    end
    if enemy.distance > MELEE_RANGE then
        if not hasAura(enemy, data.AURA.MOD_ROOT) and continentId == enemy.continentId then
            local speed = RUN_SPEED * (hasAura(enemy, data.AURA.MOD_DECREASE_SPEED) and 0.5 or 1)
            moveEnemyToward(enemy, north, west, speed * dt, MELEE_RANGE - 1.5)
            enemy.distance, enemy.bearing = measure(enemy)
        end
        return
    end
    if time >= enemy.swingAt then
        enemy.swingAt = time + enemy.swingSpeed
        enemySwing(enemy)
    end
end

-- Regeneration, in the client's two-second ticks: mana from spirit once five seconds have passed without spending
-- any, energy 20 a tick, rage fading out of combat (2 a tick, a guess), health out of combat only (spirit's, and
-- at least 3% a tick, a guess so a rest takes about a minute)
local function regenerate(time)
    if time < player.nextRegenAt then
        return
    end
    player.nextRegenAt = time + 2
    if player.isDead or player.isGhost then
        return
    end
    ensurePlayer()
    local isHealthChanged = false
    local before = player.power
    if player.powerType == POWER.MANA then
        if time - player.lastManaSpend >= 5 then
            local perSecond = G.GetManaRegen and G.GetManaRegen() or 10
            player.power = math.min(player.powerMax, player.power + math.max(1, math.floor(perSecond * 2 + 0.5)))
        end
    elseif player.powerType == POWER.ENERGY then
        player.power = math.min(player.powerMax, player.power + 20)
    elseif player.powerType == POWER.RAGE and not player.inCombat then
        player.power = math.max(0, player.power - 2)
    end
    local isPowerChanged = player.power ~= before
    if not player.inCombat and player.health < player.healthMax then
        local perSecond = G.GetHealthRegen and G.GetHealthRegen() or 1
        player.health = math.min(
            player.healthMax,
            player.health + math.max(math.floor(perSecond * 2 + 0.5), math.ceil(player.healthMax * 0.03))
        )
        isHealthChanged = true
    end
    if isHealthChanged or isPowerChanged then
        playerChanged(isHealthChanged, isPowerChanged)
        if isPowerChanged then
            refreshUsable()
        end
    end
end

-- The action bars: usable or not, in range or not, told as the client tells them (ACTION_USABLE_CHANGED with the
-- slots that changed, ACTION_RANGE_CHECK_UPDATE for the slots the bars asked to watch)
local usableState, rangeState = {}, {}
local function slotSpell(slot)
    local action = require("actions").getSlots(game)[tonumber(slot) or 0]
    return action and action.type == "spell" and action.id or nil
end
local function isSpellUsable(spellId)
    ensurePlayer()
    if player.isDead or player.isGhost then
        return false, false
    end
    local cost, powerType = data.getCost(spellId)
    if cost > 0 then
        local spell = data.getSpell(spellId)
        local fullCost = spell and costOf(spell) or cost
        if powerType ~= player.powerType then
            return false, false
        end
        if player.power < fullCost then
            return false, true
        end
    end
    return true, false
end
refreshUsable = function()
    if not combat.isEngaged then
        return
    end
    local changes = {}
    for slot, action in pairs(require("actions").getSlots(game)) do
        if action.type == "spell" then
            local isUsable, noMana = isSpellUsable(action.id)
            local key = (isUsable and "u" or "-") .. (noMana and "m" or "-")
            if usableState[slot] ~= key then
                usableState[slot] = key
                changes[#changes + 1] = { slot = slot, usable = isUsable, noMana = noMana }
            end
        end
    end
    if #changes > 0 then
        table.sort(changes, function(first, second)
            return first.slot < second.slot
        end)
        fire("ACTION_USABLE_CHANGED", changes)
        fire("SPELL_UPDATE_USABLE")
    end
end

---@return boolean? inRange nil when the spell has no range or there is no target, as IsActionInRange answers
local function spellInRange(spellId, unit)
    local kind, enemy = resolve(unit or "target")
    if kind ~= "enemy" then
        return nil
    end
    local spell = data.getSpell(spellId)
    if not spell or spell.isSelf or spell.isPassive or spell.isAutoAttack then
        return nil
    end
    if not needsEnemy(spell) and not spell.isAutoRepeat then
        return nil
    end
    if spell.isMelee then
        return enemy.distance <= MELEE_RANGE
    end
    return enemy.distance <= spell.rangeMax and enemy.distance >= spell.rangeMin
end
local function refreshRange(isForced)
    for slot in pairs(combat.rangeChecked) do
        local spellId = slotSpell(slot)
        local inRange = spellId and combat.target and spellInRange(spellId, "target")
        local checksRange = inRange ~= nil
        local key = checksRange and (inRange and "in" or "out") or "none"
        if isForced or rangeState[slot] ~= key then
            rangeState[slot] = key
            fire("ACTION_RANGE_CHECK_UPDATE", slot, inRange == true, checksRange)
        end
    end
end

-- Targets
local function setTarget(enemy)
    if combat.target == enemy then
        return
    end
    -- The game's own target (game.pointAt, game.kill) leaves the target slot to this one
    if enemy and game.fighting and game.fighting.unit == "target" then
        game.fighting = nil
    end
    combat.target = enemy
    fire("PLAYER_TARGET_CHANGED")
    fire("UNIT_TARGET", "player")
    if combat.isEngaged then
        refreshRange(true)
    end
    sim.touch()
end

---@return table[] enemies The living ones the player could target with Tab: attackable, within nameplate range,
---nearest first
local function tabCandidates()
    local list = {}
    for _, enemy in ipairs(combat.enemies) do
        if isAttackable(enemy) and enemy.distance <= plateRange() then
            list[#list + 1] = enemy
        end
    end
    table.sort(list, function(first, second)
        if math.abs(first.distance - second.distance) > 0.01 then
            return first.distance < second.distance
        end
        return first.id < second.id
    end)
    return list
end

---Tab: the nearest enemy first, then the next each press (Shift: back), as the client cycles them.
function combat.targetNext(isReverse)
    local list = tabCandidates()
    if #list == 0 then
        return false, "no enemy near"
    end
    local index = 0
    for position, enemy in ipairs(list) do
        if enemy == combat.target then
            index = position
        end
    end
    if isReverse then
        index = index - 1
        if index < 1 then
            index = #list
        end
    else
        index = index + 1
        if index > #list then
            index = 1
        end
    end
    setTarget(list[index])
    return true
end

function combat.setFocus(enemy)
    if combat.focus == enemy then
        return
    end
    combat.focus = enemy
    fire("PLAYER_FOCUS_CHANGED")
    sim.touch()
end

function combat.setMouseover(enemy)
    if combat.mouseover == enemy then
        return
    end
    combat.mouseover = enemy
    fire("UPDATE_MOUSEOVER_UNIT")
    if enemy and G.GameTooltip and G.GameTooltip.SetUnit then
        G.GameTooltip:SetOwner(G.UIParent, "ANCHOR_CURSOR")
        G.GameTooltip:SetUnit("mouseover")
    elseif not enemy and G.GameTooltip and G.GameTooltip:IsShown() then
        -- (only the mouseover's own tooltip: one an addon shows meanwhile stays)
        local _, unit = G.GameTooltip:GetUnit()
        if unit == "mouseover" then
            G.GameTooltip:Hide()
        end
    end
end

-- Death and coming back
playerDies = function()
    player.isDead, player.health, player.diedAt = true, 0, now()
    if player.cast then
        combat.interruptPlayerCast()
    end
    stopAutoAttack()
    player.queuedSpellId = nil
    player.comboPoints, player.comboTarget = 0, nil
    clearAuras(player)
    logEvent("UNIT_DIED", nil, "player", nil, "You die.")
    fire("PLAYER_DEAD")
    for _, enemy in ipairs(combat.enemies) do
        if enemy.inCombat then
            evade(enemy)
        end
    end
    playerLeavesCombat()
    refreshUsable()
    sim.touch()
end

---Releases the spirit: the player is a ghost (PLAYER_ALIVE, as the client sends it then), still where they died.
function combat.release()
    if not player.isDead then
        return false, "not dead"
    end
    player.isDead, player.isGhost, player.health = false, true, 1
    fire("PLAYER_ALIVE")
    fire("UNIT_HEALTH", "player")
    fire("UNIT_FLAGS", "player")
    if G.StaticPopup_Hide then
        sim.call(G.StaticPopup_Hide, "DEATH")
    end
    sim.touch()
    return true
end

---Back to life, from the corpse or as a ghost (PLAYER_UNGHOST then), with half health and mana.
function combat.resurrect()
    ensurePlayer()
    if not player.isDead and not player.isGhost then
        return false, "not dead"
    end
    local wasGhost = player.isGhost
    player.isDead, player.isGhost = false, false
    player.health = math.max(1, math.floor(player.healthMax / 2))
    if player.powerType == POWER.MANA then
        player.power = math.floor(player.powerMax / 2)
    end
    if wasGhost then
        fire("PLAYER_UNGHOST")
    else
        fire("PLAYER_ALIVE")
    end
    if G.StaticPopup_Hide then
        sim.call(G.StaticPopup_Hide, "DEATH")
    end
    playerChanged(true, true)
    fire("UNIT_FLAGS", "player")
    refreshUsable()
    sim.touch()
    return true
end

-- Loot
local function copperText(copper)
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = string.format(text("GOLD_AMOUNT", "%d Gold"), gold)
    end
    if silver > 0 then
        parts[#parts + 1] = string.format(text("SILVER_AMOUNT", "%d Silver"), silver)
    end
    if rest > 0 or #parts == 0 then
        parts[#parts + 1] = string.format(text("COPPER_AMOUNT", "%d Copper"), rest)
    end
    return table.concat(parts, ", ")
end

---Opens a corpse's loot (LOOT_READY, LOOT_OPENED); with auto loot (the autoLootDefault setting) everything is taken
---at once and the window closes.
function combat.openLoot(enemy)
    if not enemy then
        local best
        for _, candidate in ipairs(combat.enemies) do
            if candidate.isDead and candidate.isLootable and (not best or candidate.distance < best.distance) then
                best = candidate
            end
        end
        enemy = best
    end
    if not enemy then
        return false, "nothing to loot"
    end
    if not enemy.isDead or not enemy.isLootable then
        return false, "that has no loot"
    end
    if combat.loot then
        combat.closeLoot()
    end
    combat.loot = { enemy = enemy, slots = enemy.loot }
    local isAutoLoot = G.GetCVar and G.GetCVar("autoLootDefault") == "1"
    fire("LOOT_READY", isAutoLoot)
    fire("LOOT_OPENED", isAutoLoot, false)
    if isAutoLoot then
        for slot = 1, #enemy.loot do
            combat.lootSlot(slot)
        end
    end
    sim.touch()
    return true
end

function combat.lootSlot(slot)
    local loot = combat.loot
    local entry = loot and loot.slots[tonumber(slot) or 0]
    if not entry or entry.isTaken then
        return false, "nothing in that slot"
    end
    entry.isTaken = true
    if entry.isMoney then
        game.profile.money = (game.profile.money or 0) + entry.quantity
        fire(
            "CHAT_MSG_MONEY",
            string.format(text("YOU_LOOT_MONEY", "You loot %s"), copperText(entry.quantity)),
            "",
            "",
            "",
            "",
            "",
            0,
            0,
            "",
            0,
            0,
            "",
            0,
            false,
            false,
            false,
            false
        )
        fire("PLAYER_MONEY")
    else
        game.loot(entry.itemId, entry.quantity)
    end
    fire("LOOT_SLOT_CLEARED", slot)
    local isEmpty = true
    for _, other in ipairs(loot.slots) do
        if not other.isTaken then
            isEmpty = false
        end
    end
    if isEmpty then
        loot.enemy.isLootable, loot.enemy.isLooted = false, true
        combat.closeLoot()
    end
    return true
end

function combat.closeLoot()
    if not combat.loot then
        return false
    end
    combat.loot = nil
    fire("LOOT_CLOSED")
    sim.touch()
    return true
end

function combat.despawn(enemyId)
    local enemy = combat.byId[tonumber(enemyId) or -1]
    if not enemy then
        return false, "no such enemy"
    end
    enemy.isGone = true
    removePlate(enemy)
    if combat.loot and combat.loot.enemy == enemy then
        combat.closeLoot()
    end
    if combat.target == enemy then
        setTarget(nil)
    end
    if combat.focus == enemy then
        combat.setFocus(nil)
    end
    if combat.mouseover == enemy then
        combat.setMouseover(nil)
    end
    if enemy.inCombat then
        enemy.inCombat = false
    end
    for index, other in ipairs(combat.enemies) do
        if other == enemy then
            table.remove(combat.enemies, index)
            break
        end
    end
    combat.byId[enemy.id] = nil
    checkCombatEnd()
    sim.touch()
    return true
end

---Every enemy gone, the player alive and whole, out of combat, the rolls from a seed again.
function combat.reset(seed)
    for index = #combat.enemies, 1, -1 do
        combat.despawn(combat.enemies[index].id)
    end
    if player.cast then
        combat.interruptPlayerCast()
    end
    stopAutoAttack()
    combat.stopFleeing()
    if player.isDead or player.isGhost then
        combat.resurrect()
    end
    ensurePlayer()
    player.health = player.healthMax
    player.power = player.powerType == POWER.RAGE and 0 or player.powerMax
    player.cooldowns, player.gcdStart, player.gcdDuration, player.queuedSpellId = {}, 0, 0, nil
    player.comboPoints, player.comboTarget = 0, nil
    clearAuras(player)
    playerLeavesCombat()
    playerChanged(true, true)
    combat.log = {}
    if seed ~= nil then
        combat.setSeed(seed)
    else
        combat.setSeed(combat.seed)
    end
    sim.touch()
    return true
end

-- The fight's clock: run by the game's own (sim.tickHandlers), after the character has moved
function combat.tick(dt)
    if player.maximaChanged then
        player.maximaChanged = false
        fire("UNIT_MAXHEALTH", "player")
        fire("UNIT_MAXPOWER", "player", powerToken(player.powerType))
        playerChanged(true, true)
    end
    if player.isFleeing then
        combat.keepFleeing()
    end
    if not combat.isEngaged then
        return
    end
    local time = now()
    -- Moving breaks a cast (not a channel's first moment, nor an instant)
    local profile = game.profile
    local position = player.lastPosition
    local isMoved = position
        and (position[1] ~= profile.uiMapId or position[2] ~= profile.x or position[3] ~= profile.y)
    player.lastPosition = { profile.uiMapId, profile.x, profile.y }
    if isMoved and player.cast and time > player.cast.startTime then
        combat.interruptPlayerCast("SPELL_FAILED_MOVING")
    end
    updatePlates()
    -- The player's cast, channel, swings
    local cast = player.cast
    if cast then
        if cast.isChannel then
            if time >= cast.nextTick then
                cast.nextTick = cast.nextTick + 1
                tickChannel(cast)
            end
            if player.cast == cast and time >= cast.endTime then
                player.cast = nil
                fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", cast.castGUID, cast.spellId, nil)
                fire("ACTIONBAR_UPDATE_STATE")
            end
        elseif time >= cast.endTime then
            completeCast()
        end
    end
    if player.gcdDuration > 0 and time >= player.gcdStart + player.gcdDuration then
        player.gcdDuration = 0
        cooldownsChanged()
    end
    for spellId, cooldown in pairs(player.cooldowns) do
        if time >= cooldown.start + cooldown.duration then
            player.cooldowns[spellId] = nil
            cooldownsChanged()
        end
    end
    if player.isAutoAttacking then
        local target = combat.target
        if not isAttackable(target) then
            stopAutoAttack()
        elseif time >= player.swingAt and not (player.cast and player.autoRepeatSpellId) then
            local isRanged = player.autoRepeatSpellId ~= nil
            local spell = isRanged and data.getSpell(player.autoRepeatSpellId)
            local isInRange = isRanged
                    and (target.distance <= (spell and spell.rangeMax or 30) and target.distance >= (spell and spell.rangeMin or 0))
                or (not isRanged and target.distance <= MELEE_RANGE)
            if isInRange then
                player.rangeWarned = false
                local _, speed = playerSwingDamage(isRanged)
                player.swingAt = time + speed
                playerSwing(target, isRanged)
            elseif not player.rangeWarned then
                player.rangeWarned = true
                errorMessage("ERR_BADATTACKPOS", "You are too far away!")
            end
        end
    end
    updateAuras(player, time)
    for index = #combat.enemies, 1, -1 do
        local enemy = combat.enemies[index]
        if enemy then
            updateEnemy(enemy, dt, time)
        end
    end
    regenerate(time)
    refreshRange(false)
    checkCombatEnd()
end

-- What the page shows (src/shared/combat.ts: CombatState)
local function describeCast(cast)
    if not cast then
        return nil
    end
    local spell = cast.spell
    return {
        spellId = cast.spellId,
        name = spell and spell.name or cast.name,
        icon = spell and spell.icon or cast.icon or 136243,
        startTime = cast.startTime,
        endTime = cast.endTime,
        isChannel = cast.isChannel == true,
        notInterruptible = cast.notInterruptible == true,
    }
end
local function describeAuras(holder)
    local list = {}
    for _, aura in ipairs(holder.auras) do
        list[#list + 1] = {
            auraInstanceID = aura.instanceId,
            spellId = aura.spellId,
            name = aura.name,
            icon = aura.icon,
            isHelpful = not aura.isHarmful,
            duration = aura.duration,
            expirationTime = aura.expirationTime,
            applications = aura.stacks or 0,
            sourceUnit = aura.source,
        }
    end
    return list
end
local function threatOf(enemy)
    local own = enemy.threat.player
    if not own then
        return nil, 0
    end
    local top = 0
    for _, value in pairs(enemy.threat) do
        top = math.max(top, value)
    end
    local status = enemy.targetUnit == "player" and 3 or (own >= top and 2 or 0)
    return status, top > 0 and math.floor(own / top * 100 + 0.5) or 100
end

function combat.describe()
    ensurePlayer()
    local enemies = {}
    for _, enemy in ipairs(combat.enemies) do
        local status, percent = threatOf(enemy)
        enemies[#enemies + 1] = {
            id = enemy.id,
            npcId = enemy.npcId,
            guid = enemy.guid,
            name = enemy.name,
            level = enemy.level,
            classification = classificationOf(enemy),
            reaction = enemy.reaction,
            health = enemy.health,
            healthMax = enemy.healthMax,
            power = enemy.power,
            powerMax = enemy.powerMax,
            powerType = powerToken(enemy.powerType),
            isDead = enemy.isDead,
            isLootable = enemy.isLootable == true,
            isTappedByOthers = enemy.isTappedByOthers,
            inCombat = enemy.inCombat,
            isEvading = enemy.isEvading,
            isTarget = combat.target == enemy,
            isFocus = combat.focus == enemy,
            isMouseover = combat.mouseover == enemy,
            unit = plateToken(enemy),
            threat = status,
            threatPercent = percent,
            targetUnit = enemy.targetUnit,
            distance = enemy.distance == math.huge and -1 or math.floor(enemy.distance * 10 + 0.5) / 10,
            bearing = math.floor(math.deg(enemy.bearing) + 0.5),
            casting = describeCast(enemy.cast),
            auras = describeAuras(enemy),
        }
    end
    local cooldowns = {}
    for spellId, cooldown in pairs(player.cooldowns) do
        local spell = data.getSpell(spellId)
        cooldowns[#cooldowns + 1] = {
            spellId = spellId,
            name = spell and spell.name or tostring(spellId),
            endTime = cooldown.start + cooldown.duration,
        }
    end
    table.sort(cooldowns, function(first, second)
        return first.endTime < second.endTime
    end)
    local profile = game.profile
    local loot
    if combat.loot then
        local slots = {}
        for index, entry in ipairs(combat.loot.slots) do
            if not entry.isTaken then
                slots[#slots + 1] = {
                    slot = index,
                    itemId = entry.itemId,
                    name = entry.isMoney and copperText(entry.quantity) or entry.name,
                    icon = entry.isMoney and 133784 or entry.icon,
                    quantity = entry.quantity,
                    quality = entry.isMoney and 0 or entry.quality,
                    isQuestItem = entry.isQuestItem == true,
                    isMoney = entry.isMoney == true,
                }
            end
        end
        loot = { enemyId = combat.loot.enemy.id, name = combat.loot.enemy.name, slots = slots }
    end
    return {
        enemies = enemies,
        player = {
            level = profile.level,
            health = player.health,
            healthMax = player.healthMax,
            power = math.floor(player.power),
            powerMax = player.powerMax,
            powerType = powerToken(player.powerType),
            comboPoints = player.comboPoints,
            inCombat = player.inCombat,
            isLockedDown = sim.inCombat == true,
            isDead = player.isDead,
            isGhost = player.isGhost,
            isAutoAttacking = player.isAutoAttacking,
            isFleeing = player.isFleeing,
            nextSwing = player.isAutoAttacking and player.swingAt or nil,
            swingSpeed = (G.UnitAttackSpeed and G.UnitAttackSpeed("player")) or 2,
            casting = describeCast(player.cast),
            gcdEnd = player.gcdDuration > 0 and (player.gcdStart + player.gcdDuration) or nil,
            cooldowns = cooldowns,
            queuedSpellId = player.queuedSpellId,
            xp = profile.xp or 0,
            xpMax = profile.xpMax or 0,
            auras = describeAuras(player),
        },
        log = combat.log,
        loot = loot,
        seed = combat.seed,
        nameplateRange = plateRange(),
        isCombatLogRestricted = sim.restrictedEvents["COMBAT_LOG_EVENT_UNFILTERED"] == true,
    }
end

-- The page's actions (/api/game: src/shared/combat.ts's CombatAction), each run as the client runs hardware input
local handlers = {}
handlers.combatSpawn = function(request)
    local ids, problem = combat.spawn({
        npcId = request.npcId,
        name = request.name,
        count = request.count,
        distance = request.distance,
        bearing = request.bearing,
        level = request.level,
        aggro = request.aggro,
        spellId = request.spellId,
        isTappedByOthers = request.isTappedByOthers,
        dropChance = request.dropChance,
    })
    return { ok = ids ~= nil, problem = problem, enemyIds = ids }
end
local function enemyFrom(request)
    if request.enemyId == nil then
        return nil
    end
    return combat.byId[tonumber(request.enemyId) or -1], "no such enemy"
end
handlers.combatTarget = function(request)
    if request.clear then
        setTarget(nil)
        return { ok = true }
    end
    if request.next or request.reverse then
        local ok, problem = combat.targetNext(request.reverse == true)
        return { ok = ok, problem = problem }
    end
    local enemy, problem = enemyFrom(request)
    if not enemy then
        return { ok = false, problem = problem or "which enemy?" }
    end
    setTarget(enemy)
    return { ok = true }
end
handlers.combatFocus = function(request)
    if request.clear then
        combat.setFocus(nil)
        return { ok = true }
    end
    local enemy, problem = enemyFrom(request)
    if not enemy then
        return { ok = false, problem = problem or "which enemy?" }
    end
    combat.setFocus(enemy)
    return { ok = true }
end
handlers.combatHover = function(request)
    local enemy = enemyFrom(request)
    combat.setMouseover(enemy)
    return { ok = true }
end
handlers.combatAttack = function(request)
    local enemy = enemyFrom(request)
    if enemy then
        setTarget(enemy)
    end
    local ok, problem = startAutoAttack(data.AUTO_ATTACK)
    return { ok = ok == true, problem = problem }
end
handlers.combatStopAttack = function()
    stopAutoAttack()
    return { ok = true }
end
handlers.combatUseAction = function(request)
    G.UseAction(tonumber(request.slot) or 0, nil, "LeftButton")
    return { ok = true }
end
handlers.combatCastSpell = function(request)
    local ok, problem = combat.castSpell(request.spellId)
    return { ok = ok == true, problem = problem }
end
handlers.combatStop = function()
    if player.cast then
        combat.interruptPlayerCast()
    end
    stopAutoAttack()
    player.queuedSpellId = nil
    combat.stopFleeing()
    return { ok = true }
end
handlers.combatFlee = function()
    local ok, problem = combat.flee()
    return { ok = ok == true, problem = problem }
end
handlers.combatLoot = function(request)
    local ok, problem = combat.openLoot(enemyFrom(request))
    return { ok = ok == true, problem = problem }
end
handlers.combatLootSlot = function(request)
    local ok, problem = combat.lootSlot(tonumber(request.slot))
    return { ok = ok == true, problem = problem }
end
handlers.combatCloseLoot = function()
    combat.closeLoot()
    return { ok = true }
end
handlers.combatRelease = function()
    local ok, problem = combat.release()
    return { ok = ok == true, problem = problem }
end
handlers.combatResurrect = function()
    local ok, problem = combat.resurrect()
    return { ok = ok == true, problem = problem }
end
handlers.combatDamage = function(request)
    local amount = tonumber(request.amount) or 0
    local enemy = enemyFrom(request)
    if request.enemyId ~= nil and not enemy then
        return { ok = false, problem = "no such enemy" }
    end
    combat.isEngaged = true
    if enemy then
        if amount >= 0 then
            damageEnemy(enemy, amount, 1, nil, "HIT", "ENVIRONMENTAL_DAMAGE")
        else
            enemy.health = math.min(enemy.healthMax, enemy.health - amount)
            fireUnit(enemy, "UNIT_HEALTH")
        end
    elseif amount >= 0 then
        damagePlayer(nil, amount, 1, nil, "HIT", "ENVIRONMENTAL_DAMAGE")
    else
        healPlayer(-amount, nil, "HIT")
    end
    return { ok = true }
end
handlers.combatDespawn = function(request)
    if request.enemyId == nil then
        for index = #combat.enemies, 1, -1 do
            combat.despawn(combat.enemies[index].id)
        end
        return { ok = true }
    end
    local ok, problem = combat.despawn(request.enemyId)
    return { ok = ok == true, problem = problem }
end
handlers.combatReset = function(request)
    combat.reset(tonumber(request.seed))
    return { ok = true }
end

---@return table? result The answer for a combat action, nil for an action that is not one
function combat.handleAction(action, request)
    local handler = handlers[action]
    if not handler then
        return nil
    end
    local result = sim.runSecurely(handler, request or {})
    if type(result) ~= "table" then
        return { ok = false, problem = "the action failed (see the Errors tab)" }
    end
    return result
end

-- A click on the world: on a nameplate, its unit becomes the target (a right click attacks it too); elsewhere, with
-- the client's default (deselectOnClick), the target goes. The mouse over a plate makes its unit the mouseover.
local function plateAt(x, y)
    local W = require("widgets")
    for _, enemy in pairs(combat.plates) do
        local frame = G.C_NamePlate.GetNamePlateForUnit(plateToken(enemy))
        local rect = frame and W.computeRect(frame)
        if rect and x >= rect[1] and x <= rect[3] and y >= rect[2] and y <= rect[4] then
            return enemy
        end
    end
    return nil
end
function combat.worldClick(x, y, button)
    if not combat.isEngaged then
        return false
    end
    local enemy = plateAt(x, y)
    if enemy then
        setTarget(enemy)
        if button == "RightButton" and isAttackable(enemy) then
            startAutoAttack(data.AUTO_ATTACK)
        end
        return true
    end
    if button == "LeftButton" and combat.target and G.GetCVar and G.GetCVar("deselectOnClick") ~= "0" then
        setTarget(nil)
    end
    return false
end
function combat.worldHover(x, y, isOverWorld)
    if not combat.isEngaged then
        return
    end
    local enemy = isOverWorld and plateAt(x, y) or nil
    if enemy ~= combat.mouseover then
        sim.runSecurely(combat.setMouseover, enemy)
    end
end

-- The game's functions, for the units here
function combat.install()
    data.readTable = game.readDb2
    local function isPlayerToken(unit)
        return unit == nil or (type(unit) == "string" and unit:lower() == "player")
    end
    ---Wraps a unit function: an enemy's token gets onEnemy's answer, a token that leads back to the player (a
    ---creature's target) the player's, anything else the function before
    local function wrap(name, onEnemy, onPlayer)
        local original = G[name]
        G[name] = function(unit, ...)
            local kind, enemy = resolve(unit)
            if kind == "enemy" then
                return onEnemy(enemy, ...)
            end
            if kind == "none" then
                return nil
            end
            if kind == "player" then
                unit = "player"
            end
            if onPlayer and isPlayerToken(unit) then
                return onPlayer(...)
            end
            if original then
                return original(unit, ...)
            end
        end
    end
    wrap("UnitExists", function()
        return true
    end)
    wrap("UnitIsVisible", function(enemy)
        return enemy.distance <= 100
    end)
    wrap("UnitName", function(enemy)
        return enemy.name, nil
    end)
    wrap("UnitNameUnmodified", function(enemy)
        return enemy.name, nil
    end)
    wrap("GetUnitName", function(enemy)
        return enemy.name
    end)
    wrap("UnitFullName", function(enemy)
        return enemy.name, nil
    end)
    wrap("UnitGUID", function(enemy)
        return sim.hide(enemy.guid, "identity")
    end)
    -- Too high to tell (ten levels over the player, or a boss): ?? on the frames, -1 as the client answers
    local function levelOf(enemy)
        if enemy.rank == 3 or (enemy.reaction <= 4 and enemy.level >= (tonumber(game.profile.level) or 1) + 10) then
            return -1
        end
        return enemy.level
    end
    wrap("UnitLevel", levelOf)
    wrap("UnitEffectiveLevel", levelOf)
    wrap("UnitClassification", classificationOf)
    wrap("UnitIsTrivial", function(enemy)
        return enemy.level <= data.greyLevel(tonumber(game.profile.level) or 1)
    end)
    wrap("UnitHealth", function(enemy)
        return enemy.health
    end, function()
        return ensurePlayer().health
    end)
    wrap("UnitHealthMax", function(enemy)
        return enemy.healthMax
    end, function()
        return ensurePlayer().healthMax
    end)
    local function powerOf(holder, powerType, isMax)
        if powerType == POWER.COMBO_POINTS then
            if holder ~= player then
                return 0
            end
            return isMax and 5
                or ((player.comboTarget and player.comboTarget == combat.target) and player.comboPoints or 0)
        end
        if powerType ~= nil and powerType ~= holder.powerType then
            return 0
        end
        return isMax and holder.powerMax or math.floor(holder.power)
    end
    wrap("UnitPower", function(enemy, powerType)
        return powerOf(enemy, powerType, false)
    end, function(powerType)
        ensurePlayer()
        return powerOf(player, powerType, false)
    end)
    wrap("UnitPowerMax", function(enemy, powerType)
        return powerOf(enemy, powerType, true)
    end, function(powerType)
        ensurePlayer()
        return powerOf(player, powerType, true)
    end)
    wrap("UnitPowerType", function(enemy)
        return enemy.powerType, powerToken(enemy.powerType)
    end)
    wrap("UnitIsDead", function(enemy)
        return enemy.isDead
    end, function()
        return player.isDead
    end)
    wrap("UnitIsDeadOrGhost", function(enemy)
        return enemy.isDead
    end, function()
        return player.isDead or player.isGhost
    end)
    wrap("UnitIsGhost", function()
        return false
    end, function()
        return player.isGhost
    end)
    wrap("UnitAffectingCombat", function(enemy)
        return enemy.inCombat
    end, function()
        return player.inCombat or sim.inCombat == true
    end)
    wrap("UnitIsTapDenied", function(enemy)
        return enemy.isTappedByOthers
    end)
    wrap("UnitIsPlayer", function()
        return false
    end)
    wrap("UnitPlayerControlled", function()
        return false
    end)
    wrap("UnitIsGameObject", function()
        return false
    end)
    wrap("UnitShouldDisplayName", function()
        return true
    end)
    wrap("UnitIsQuestBoss", function()
        return false
    end)
    wrap("UnitRace", function()
        return nil
    end)
    wrap("UnitSex", function()
        return 1
    end)
    -- Creatures have a class too: the casters mages, the rest warriors, as most of the classic world's
    wrap("UnitClass", function(enemy)
        if enemy.spellId then
            return "Mage", "MAGE", 8
        end
        return "Warrior", "WARRIOR", 1
    end)
    wrap("UnitClassBase", function(enemy)
        if enemy.spellId then
            return "MAGE", 8
        end
        return "WARRIOR", 1
    end)
    wrap("UnitAttackSpeed", function(enemy)
        return enemy.swingSpeed, nil
    end)
    wrap("UnitSelectionColor", function(enemy)
        if enemy.reaction <= 2 then
            return 1, 0, 0, 1
        elseif enemy.reaction <= 4 then
            return 1, 1, 0, 1
        end
        return 0, 1, 0, 1
    end)
    wrap("UnitSelectionType", function(enemy)
        if enemy.reaction <= 2 then
            return 0
        elseif enemy.reaction == 3 then
            return 1
        elseif enemy.reaction == 4 then
            return 2
        end
        return 3
    end)
    wrap("UnitCastingInfo", function(enemy)
        local cast = enemy.cast
        if not cast then
            return nil
        end
        return cast.name,
            cast.name,
            cast.icon,
            cast.startTime * 1000,
            cast.endTime * 1000,
            false,
            cast.castGUID,
            cast.notInterruptible,
            cast.spellId,
            nil,
            0
    end, function()
        local cast = player.cast
        if not cast or cast.isChannel then
            return nil
        end
        return cast.spell.name,
            cast.spell.name,
            cast.spell.icon,
            cast.startTime * 1000,
            cast.endTime * 1000,
            false,
            cast.castGUID,
            false,
            cast.spellId,
            nil,
            0
    end)
    wrap("UnitChannelInfo", function()
        return nil
    end, function()
        local cast = player.cast
        if not cast or not cast.isChannel then
            return nil
        end
        return cast.spell.name,
            cast.spell.name,
            cast.spell.icon,
            cast.startTime * 1000,
            cast.endTime * 1000,
            false,
            false,
            cast.spellId,
            false,
            0,
            nil
    end)
    wrap("UnitGetTotalAbsorbs", function()
        return 0
    end, function()
        return math.floor(player.absorb)
    end)
    -- Two units: one of them a creature here
    local function pair(name, answer)
        local original = G[name]
        G[name] = function(first, second, ...)
            local firstKind, firstEnemy = resolve(first)
            local secondKind, secondEnemy = resolve(second)
            if firstKind == "enemy" or secondKind == "enemy" then
                return answer(
                    firstEnemy,
                    secondEnemy,
                    firstKind == "player" or isPlayerToken(first),
                    secondKind == "player" or isPlayerToken(second)
                )
            end
            if original then
                return original(
                    firstKind == "player" and "player" or first,
                    secondKind == "player" and "player" or second,
                    ...
                )
            end
        end
    end
    pair("UnitIsUnit", function(firstEnemy, secondEnemy)
        return firstEnemy ~= nil and firstEnemy == secondEnemy
    end)
    pair("UnitReaction", function(firstEnemy, secondEnemy)
        return (firstEnemy or secondEnemy).reaction
    end)
    pair("UnitCanAttack", function(firstEnemy, secondEnemy, isFirstPlayer, isSecondPlayer)
        local enemy = firstEnemy or secondEnemy
        if firstEnemy and secondEnemy then
            return false
        end
        return (isFirstPlayer or isSecondPlayer) and enemy.reaction <= 4
    end)
    pair("UnitCanAssist", function(firstEnemy, secondEnemy)
        return (firstEnemy or secondEnemy).reaction >= 5
    end)
    pair("UnitIsFriend", function(firstEnemy, secondEnemy)
        return (firstEnemy or secondEnemy).reaction >= 5
    end)
    pair("UnitIsEnemy", function(firstEnemy, secondEnemy)
        return (firstEnemy or secondEnemy).reaction <= 2
    end)
    -- Threat (hidden when the game restricts it): the player's standing on a creature's list
    local unitThreatSituation, unitDetailed = G.UnitThreatSituation, G.UnitDetailedThreatSituation
    G.UnitThreatSituation = function(unit, mobUnit)
        local kind, enemy = resolve(mobUnit)
        local isPlayer = isPlayerToken(unit) or resolve(unit) == "player"
        if kind == "enemy" then
            if not isPlayer or enemy.isDead then
                return nil
            end
            local status = threatOf(enemy)
            return sim.hide(status, "threat")
        end
        if mobUnit == nil and isPlayer then
            local best
            for _, other in ipairs(combat.enemies) do
                local status = not other.isDead and threatOf(other)
                if status and (not best or status > best) then
                    best = status
                end
            end
            if best then
                return sim.hide(best, "threat")
            end
        end
        if unitThreatSituation then
            return unitThreatSituation(unit, mobUnit)
        end
    end
    G.UnitDetailedThreatSituation = function(unit, mobUnit)
        local kind, enemy = resolve(mobUnit)
        if kind == "enemy" then
            if not (isPlayerToken(unit) or resolve(unit) == "player") or enemy.isDead or not enemy.threat.player then
                return nil
            end
            local status, percent = threatOf(enemy)
            local hide = sim.hide
            return hide(enemy.targetUnit == "player", "threat"),
                hide(status, "threat"),
                hide(percent, "threat"),
                hide(percent, "threat"),
                hide(math.floor(enemy.threat.player * 100), "threat")
        end
        if unitDetailed then
            return unitDetailed(unit, mobUnit)
        end
    end
    G.UnitThreatPercentageOfLead = function(unit, mobUnit)
        local kind, enemy = resolve(mobUnit)
        if kind == "enemy" and enemy.threat.player then
            return sim.hide(100, "threat")
        end
        return 0
    end
    local checkInteract = G.CheckInteractDistance
    G.CheckInteractDistance = function(unit, index)
        local kind, enemy = resolve(unit)
        if kind == "enemy" then
            local yards = ({ 28, 11.11, 9.9, 28 })[tonumber(index) or 4] or 28
            return enemy.distance <= yards
        end
        if checkInteract then
            return checkInteract(unit, index)
        end
        return false
    end
    G.GetComboPoints = function(unit, target)
        if not isPlayerToken(unit) then
            return 0
        end
        local kind, enemy = resolve(target or "target")
        return (kind == "enemy" and player.comboTarget == enemy) and player.comboPoints or 0
    end

    -- Targeting and attacking: protected in the client (only the player's own keys and clicks, the game's secure
    -- code, may call them; an addon's call is forbidden)
    local function isForbidden(name)
        if G.issecure() then
            return false
        end
        fire("ADDON_ACTION_FORBIDDEN", sim.getCallingAddon() or "", name .. "()")
        return true
    end
    local function findByName(name)
        local best
        for _, enemy in ipairs(combat.enemies) do
            if
                not enemy.isGone
                and enemy.name:lower() == tostring(name):lower()
                and (not best or enemy.distance < best.distance)
            then
                best = enemy
            end
        end
        return best
    end
    local targetUnit, clearTarget, focusUnit, clearFocus = G.TargetUnit, G.ClearTarget, G.FocusUnit, G.ClearFocus
    G.TargetUnit = function(unit, isExact)
        if isForbidden("TargetUnit") then
            return
        end
        if unit == nil then
            setTarget(nil)
            return
        end
        local kind, enemy = resolve(unit)
        enemy = kind == "enemy" and enemy or findByName(unit)
        if enemy then
            setTarget(enemy)
            return
        end
        if targetUnit then
            return targetUnit(unit, isExact)
        end
    end
    G.ClearTarget = function()
        if isForbidden("ClearTarget") then
            return
        end
        if combat.target then
            setTarget(nil)
            return true
        end
        if game.fighting and game.fighting.unit == "target" then
            game.fighting = nil
            fire("PLAYER_TARGET_CHANGED")
            return true
        end
        if clearTarget then
            return clearTarget()
        end
    end
    local function targetNearest(reverse)
        if not combat.isEngaged then
            return
        end
        combat.targetNext(reverse == true)
    end
    G.TargetNearestEnemy = function(reverse)
        if not isForbidden("TargetNearestEnemy") then
            targetNearest(reverse)
        end
    end
    G.TargetNearest = function(reverse)
        if not isForbidden("TargetNearest") then
            targetNearest(reverse)
        end
    end
    G.TargetPreviousEnemy = function()
        if not isForbidden("TargetPreviousEnemy") then
            targetNearest(true)
        end
    end
    G.FocusUnit = function(unit)
        if isForbidden("FocusUnit") then
            return
        end
        local kind, enemy = resolve(unit or "target")
        if kind == "enemy" then
            combat.setFocus(enemy)
            return
        end
        if focusUnit then
            return focusUnit(unit)
        end
    end
    G.ClearFocus = function()
        if isForbidden("ClearFocus") then
            return
        end
        if combat.focus then
            combat.setFocus(nil)
            return
        end
        if clearFocus then
            return clearFocus()
        end
    end
    G.StartAttack = function(unit)
        if isForbidden("StartAttack") then
            return
        end
        if unit then
            local kind, enemy = resolve(unit)
            if kind == "enemy" then
                setTarget(enemy)
            end
        end
        startAutoAttack(data.AUTO_ATTACK)
    end
    G.AttackTarget = function()
        if isForbidden("AttackTarget") then
            return
        end
        if player.isAutoAttacking and not player.autoRepeatSpellId then
            stopAutoAttack()
        else
            startAutoAttack(data.AUTO_ATTACK)
        end
    end
    G.StopAttack = function()
        if not isForbidden("StopAttack") then
            stopAutoAttack()
        end
    end
    G.SpellStopCasting = function()
        if isForbidden("SpellStopCasting") then
            return
        end
        if player.cast then
            combat.interruptPlayerCast()
            return true
        end
        return false
    end
    local useAction = G.UseAction
    G.UseAction = function(slot, unit, button)
        if isForbidden("UseAction") then
            return
        end
        local spellId = slotSpell(slot)
        if spellId then
            combat.isEngaged = true
            combat.castSpell(spellId, unit)
            refreshUsable()
            return
        end
        if useAction then
            return useAction(slot, unit, button)
        end
    end
    local castById, castByName = G.CastSpellByID, G.CastSpellByName
    G.CastSpellByID = function(spellId, unit)
        if isForbidden("CastSpellByID") then
            return
        end
        if spellOnBars(tonumber(spellId)) then
            combat.isEngaged = true
            combat.castSpell(spellId, unit)
            refreshUsable()
            return
        end
        if castById then
            return castById(spellId, unit)
        end
    end
    G.CastSpellByName = function(name, unit)
        if isForbidden("CastSpellByName") then
            return
        end
        local wanted = tostring(name or ""):gsub("%(.-%)", ""):match("^%s*(.-)%s*$"):lower()
        for _, action in pairs(require("actions").getSlots(game)) do
            local spellName = action.type == "spell" and require("actions").getSpellName(action.id)
            if spellName and spellName:lower() == wanted then
                combat.isEngaged = true
                combat.castSpell(action.id, unit)
                refreshUsable()
                return
            end
        end
        if castByName then
            return castByName(name, unit)
        end
    end

    -- Death and coming back
    G.RepopMe = function()
        combat.release()
    end
    G.RetrieveCorpse = function()
        if player.isGhost then
            combat.resurrect()
        end
    end
    G.AcceptResurrect = function()
        combat.resurrect()
    end
    G.GetReleaseTimeRemaining = function()
        if not player.isDead then
            return 0
        end
        return math.max(0, 360 - (now() - (player.diedAt or now())))
    end
    G.GetCorpseRecoveryDelay = function()
        return 0
    end

    -- Loot
    local function lootEntry(slot)
        local loot = combat.loot
        local entry = loot and loot.slots[tonumber(slot) or 0]
        if entry and not entry.isTaken then
            return entry
        end
    end
    G.GetNumLootItems = function()
        return combat.loot and #combat.loot.slots or 0
    end
    G.GetLootSlotInfo = function(slot)
        local entry = lootEntry(slot)
        if not entry then
            return nil
        end
        if entry.isMoney then
            return 133784, copperText(entry.quantity):gsub(", ", "\n"), 0, nil, 0, false, false, nil, false, true
        end
        return entry.icon,
            entry.name,
            entry.quantity,
            nil,
            entry.quality,
            false,
            entry.isQuestItem == true,
            nil,
            false,
            false
    end
    G.GetLootSlotLink = function(slot)
        local entry = lootEntry(slot)
        if not entry or entry.isMoney then
            return nil
        end
        return string.format("|cffffffff|Hitem:%d::::::::|h[%s]|h|r", entry.itemId, entry.name)
    end
    G.GetLootSlotType = function(slot)
        local entry = lootEntry(slot)
        if not entry then
            return 0
        end
        return entry.isMoney and 2 or 1
    end
    G.LootSlotHasItem = function(slot)
        local entry = lootEntry(slot)
        return entry ~= nil and not entry.isMoney
    end
    G.LootSlot = function(slot)
        combat.lootSlot(slot)
    end
    G.CloseLoot = function()
        combat.closeLoot()
    end
    G.IsFishingLoot = function()
        return false
    end
    -- Whose corpse a slot came from: its GUID and how many (one corpse here)
    G.GetLootSourceInfo = function(slot)
        local entry = lootEntry(slot)
        if not entry then
            return nil
        end
        return sim.hide(combat.loot.enemy.guid, "identity"), entry.quantity
    end
    G.GetLootInfo = function()
        local list = {}
        for index, entry in ipairs(combat.loot and combat.loot.slots or {}) do
            if not entry.isTaken then
                list[#list + 1] = {
                    slot = index,
                    item = entry.isMoney and copperText(entry.quantity) or entry.name,
                    quantity = entry.quantity,
                    quality = entry.quality or 0,
                    locked = false,
                    isQuestItem = entry.isQuestItem == true,
                    texture = entry.isMoney and 133784 or entry.icon,
                }
            end
        end
        return list
    end

    -- Auras (C_UnitAuras), the player's and the creatures'
    local function aurasOf(unit)
        local kind, enemy = resolve(unit)
        if kind == "enemy" then
            return enemy.auras
        end
        if kind == "player" or isPlayerToken(unit) then
            return player.auras
        end
        return nil
    end
    local function matches(aura, filter)
        filter = type(filter) == "string" and filter:upper() or "HELPFUL"
        local wantsHarmful = filter:find("HARMFUL", 1, true) ~= nil
        if aura.isHarmful ~= wantsHarmful then
            return false
        end
        if filter:find("PLAYER", 1, true) and aura.source ~= "player" then
            return false
        end
        return true
    end
    local function filtered(unit, filter)
        local list = {}
        for _, aura in ipairs(aurasOf(unit) or {}) do
            if matches(aura, filter) then
                list[#list + 1] = aura
            end
        end
        return list
    end
    local function byInstance(unit, instanceId)
        for _, aura in ipairs(aurasOf(unit) or {}) do
            if aura.instanceId == instanceId then
                return aura
            end
        end
    end
    local auras = G.C_UnitAuras or {}
    G.C_UnitAuras = auras
    auras.GetAuraDataByIndex = function(unit, index, filter)
        local aura = filtered(unit, filter)[tonumber(index) or 0]
        return aura and auraData(aura) or nil
    end
    auras.GetBuffDataByIndex = function(unit, index, filter)
        return auras.GetAuraDataByIndex(unit, index, "HELPFUL" .. (filter and ("|" .. filter) or ""))
    end
    auras.GetDebuffDataByIndex = function(unit, index, filter)
        return auras.GetAuraDataByIndex(unit, index, "HARMFUL" .. (filter and ("|" .. filter) or ""))
    end
    auras.GetAuraDataByAuraInstanceID = function(unit, instanceId)
        local aura = byInstance(unit, tonumber(instanceId))
        return aura and auraData(aura) or nil
    end
    auras.GetAuraDataBySlot = function(unit, slot)
        return auras.GetAuraDataByAuraInstanceID(unit, slot)
    end
    auras.GetAuraSlots = function(unit, filter, maxSlots)
        local slots = {}
        for _, aura in ipairs(filtered(unit, filter)) do
            if not maxSlots or #slots < maxSlots then
                slots[#slots + 1] = aura.instanceId
            end
        end
        return nil, unpack(slots)
    end
    auras.GetUnitAuras = function(unit, filter, maxCount)
        local list = {}
        for _, aura in ipairs(filtered(unit, filter)) do
            if not maxCount or #list < maxCount then
                list[#list + 1] = auraData(aura)
            end
        end
        return list
    end
    auras.GetUnitAuraInstanceIDs = function(unit, filter, maxCount)
        local list = {}
        for _, aura in ipairs(filtered(unit, filter)) do
            if not maxCount or #list < maxCount then
                list[#list + 1] = aura.instanceId
            end
        end
        return list
    end
    auras.GetAuraDataBySpellName = function(unit, name, filter)
        for _, aura in ipairs(aurasOf(unit) or {}) do
            if aura.name == name and (filter == nil or matches(aura, filter)) then
                return auraData(aura)
            end
        end
    end
    auras.GetUnitAuraBySpellID = function(unit, spellId)
        for _, aura in ipairs(aurasOf(unit) or {}) do
            if aura.spellId == tonumber(spellId) then
                return auraData(aura)
            end
        end
    end
    auras.GetPlayerAuraBySpellID = function(spellId)
        return auras.GetUnitAuraBySpellID("player", spellId)
    end
    auras.IsAuraFilteredOutByInstanceID = function(unit, instanceId, filter)
        local aura = byInstance(unit, tonumber(instanceId))
        return not (aura and matches(aura, filter))
    end
    auras.DoesAuraHaveExpirationTime = function(unit, instanceId)
        local aura = byInstance(unit, tonumber(instanceId))
        return aura ~= nil and aura.expirationTime > 0
    end
    auras.GetAuraApplicationDisplayCount = function(unit, instanceId, minimum)
        local aura = byInstance(unit, tonumber(instanceId))
        local count = aura and aura.stacks or 0
        return count >= (minimum or 2) and tostring(count) or ""
    end

    -- Spells and the action bars: cooldowns, the global cooldown, usable, in range, current
    local function cooldownInfo(spellId)
        local cooldown = player.cooldowns[spellId]
        if cooldown and now() < cooldown.start + cooldown.duration then
            return {
                startTime = cooldown.start,
                duration = cooldown.duration,
                isEnabled = true,
                isActive = true,
                modRate = 1,
                isOnGCD = false,
            }
        end
        if player.gcdDuration > 0 and now() < player.gcdStart + player.gcdDuration then
            local spell = data.getSpell(spellId)
            if spell and spell.gcd > 0 then
                return {
                    startTime = player.gcdStart,
                    duration = player.gcdDuration,
                    isEnabled = true,
                    isActive = true,
                    modRate = 1,
                    isOnGCD = true,
                }
            end
        end
        return { startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1, isOnGCD = false }
    end
    combat.cooldownInfo = cooldownInfo
    G.C_Spell = G.C_Spell or {}
    local spells = G.C_Spell
    local function spellIdOf(identifier)
        if tonumber(identifier) then
            return tonumber(identifier)
        end
        if type(identifier) ~= "string" then
            return nil
        end
        local wanted = identifier:lower()
        for _, action in pairs(require("actions").getSlots(game)) do
            local spellName = action.type == "spell" and require("actions").getSpellName(action.id)
            if spellName and spellName:lower() == wanted then
                return action.id
            end
        end
    end
    spells.GetSpellCooldown = function(identifier)
        local spellId = spellIdOf(identifier)
        if not spellId then
            return nil
        end
        return cooldownInfo(spellId)
    end
    spells.GetSpellPowerCost = function(identifier)
        local spellId = spellIdOf(identifier)
        if not spellId then
            return nil
        end
        local cost, powerType = data.getCost(spellId)
        if cost <= 0 then
            return {}
        end
        local spell = data.getSpell(spellId)
        local full = spell and costOf(spell) or cost
        return {
            {
                type = powerType,
                name = powerToken(powerType),
                cost = full,
                minCost = full,
                costPercent = 0,
                costPerSec = 0,
                requiredAuraID = 0,
                hasRequiredAura = false,
            },
        }
    end
    spells.IsSpellUsable = function(identifier)
        local spellId = spellIdOf(identifier)
        if not spellId then
            return false, false
        end
        return isSpellUsable(spellId)
    end
    spells.IsSpellInRange = function(identifier, unit)
        local spellId = spellIdOf(identifier)
        if not spellId then
            return nil
        end
        return spellInRange(spellId, unit)
    end
    spells.SpellHasRange = function(identifier)
        local spell = data.getSpell(spellIdOf(identifier))
        return spell ~= nil and not spell.isSelf and spell.rangeMax > 0
    end
    local function isCurrent(spellId)
        if not spellId then
            return false
        end
        if player.cast and player.cast.spellId == spellId then
            return true
        end
        if player.queuedSpellId == spellId then
            return true
        end
        if spellId == data.AUTO_ATTACK then
            return player.isAutoAttacking and not player.autoRepeatSpellId
        end
        return player.autoRepeatSpellId == spellId
    end
    spells.IsCurrentSpell = function(identifier)
        return isCurrent(spellIdOf(identifier))
    end
    spells.IsAutoAttackSpell = function(identifier)
        return spellIdOf(identifier) == data.AUTO_ATTACK
    end
    spells.IsRangedAutoAttackSpell = function(identifier)
        local spellId = spellIdOf(identifier)
        return spellId == data.AUTO_SHOT or spellId == data.SHOOT
    end
    local bar = G.C_ActionBar
    local function slotCooldown(slot)
        local spellId = slotSpell(slot)
        if spellId then
            return cooldownInfo(spellId)
        end
        return { startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1 }
    end
    local barUsable, barRange = bar.IsUsableAction, bar.IsActionInRange
    bar.GetActionCooldown = slotCooldown
    bar.IsUsableAction = function(slot)
        local spellId = slotSpell(slot)
        if spellId then
            return isSpellUsable(spellId)
        end
        return barUsable(slot)
    end
    bar.IsActionInRange = function(slot, unit)
        local spellId = slotSpell(slot)
        if spellId and resolve(unit or "target") == "enemy" then
            return spellInRange(spellId, unit)
        end
        return barRange(slot, unit)
    end
    local hasRange = bar.HasRangeRequirements
    bar.HasRangeRequirements = function(slot)
        local spellId = slotSpell(slot)
        if spellId and combat.isEngaged then
            local spell = data.getSpell(spellId)
            return spell ~= nil
                and not spell.isSelf
                and not spell.isPassive
                and not spell.isAutoAttack
                and (needsEnemy(spell) or spell.isAutoRepeat)
        end
        return hasRange(slot)
    end
    bar.IsCurrentAction = function(slot)
        return isCurrent(slotSpell(slot))
    end
    bar.IsAutoRepeatAction = function(slot)
        local spellId = slotSpell(slot)
        return spellId ~= nil and player.autoRepeatSpellId == spellId
    end
    local enableRange = bar.EnableActionRangeCheck
    bar.EnableActionRangeCheck = function(slot, isEnabled)
        combat.rangeChecked[tonumber(slot) or 0] = isEnabled and true or nil
        if enableRange then
            return enableRange(slot, isEnabled)
        end
    end
    -- The old global names the client still has
    G.GetActionCooldown = function(slot)
        local info = slotCooldown(slot)
        return info.startTime, info.duration, info.isEnabled and 1 or 0, info.modRate
    end
    G.IsUsableAction = bar.IsUsableAction
    G.IsActionInRange = bar.IsActionInRange
    G.IsCurrentAction = bar.IsCurrentAction
    G.IsAutoRepeatAction = bar.IsAutoRepeatAction

    -- The game's own target and kill (a scenario's targetCreature, kill): they take the target slot back
    local pointAt, gameKill = game.pointAt, game.kill
    game.pointAt = function(npcId, unit)
        if (unit or "target") == "target" then
            combat.target = nil
        else
            combat.mouseover = nil
        end
        return pointAt(npcId, unit)
    end
    game.kill = function(npcId, options, isTappedByOthers)
        local via = type(options) == "table" and options.via or "target"
        if via == "target" then
            combat.target = nil
        end
        return gameKill(npcId, options, isTappedByOthers)
    end

    -- Tab targets the nearest enemy, as the client's default keys have it
    if sim.bindings and sim.bindings.TAB == nil then
        sim.bindings.TAB = "TARGETNEARESTENEMY"
    end

    -- Clicks and the mouse on the world (scene.lua asks)
    sim.onWorldClick = combat.worldClick
    sim.onWorldHover = combat.worldHover
    sim.tickHandlers = sim.tickHandlers or {}
    table.insert(sim.tickHandlers, combat.tick)
end

-- Running away, as a player does it: back to whoever fights them and auto-run, steering away from them as they
-- chase (as fast as the player runs: they keep up, they do not catch up); each gives up once it is LEASH yards from where it
-- was pulled, and the run stops when the last one has (or when the player stops it: S, or the page's Stop)
local function attackersOf()
    local found = {}
    for _, enemy in ipairs(combat.enemies) do
        if enemy.inCombat and not enemy.isDead and not enemy.isGone then
            found[#found + 1] = enemy
        end
    end
    return found
end
---The facing away from the attackers (each pulls by its direction, the nearer the harder), nil with none about
local function facingAway(attackers)
    local continentId, north, west = playerPosition()
    local awayNorth, awayWest = 0, 0
    for _, enemy in ipairs(attackers) do
        if enemy.continentId == continentId then
            local dNorth, dWest = north - enemy.north, west - enemy.west
            local distance = math.max(1, math.sqrt(dNorth * dNorth + dWest * dWest))
            awayNorth, awayWest = awayNorth + dNorth / distance ^ 2, awayWest + dWest / distance ^ 2
        end
    end
    if awayNorth == 0 and awayWest == 0 then
        return nil
    end
    return math.atan2(awayWest, awayNorth) % (2 * math.pi)
end

---@return boolean ok
---@return string? problem
function combat.flee()
    if player.isDead or player.isGhost then
        return false, "You are dead"
    end
    local attackers = attackersOf()
    if #attackers == 0 or not player.inCombat then
        return false, "Nothing is fighting you"
    end
    if positionCache.continentId == "instance" then
        return false, "There is nowhere to run in here"
    end
    if player.cast then
        combat.interruptPlayerCast()
    end
    stopAutoAttack()
    player.queuedSpellId = nil
    local facing = facingAway(attackers)
    if facing then
        game.profile.facing = facing
    end
    local movement = require("movement")
    if not movement.describe().isAutoRunning then
        movement.toggleAutoRun()
    end
    player.isFleeing = true
    sim.touch()
    return true
end

---Stops running away (the auto-run with it)
function combat.stopFleeing()
    if not player.isFleeing then
        return
    end
    player.isFleeing = false
    local movement = require("movement")
    if movement.describe().isAutoRunning then
        movement.toggleAutoRun()
    end
    sim.touch()
end

---Each tick of a run: done once nothing fights the player (or they died, or the run was stopped by hand: the
---auto-run off), else steered away from the chasers again
function combat.keepFleeing()
    local attackers = attackersOf()
    if player.isDead or #attackers == 0 or not player.inCombat then
        combat.stopFleeing()
        return
    end
    if not require("movement").describe().isAutoRunning then
        player.isFleeing = false
        return
    end
    local facing = facingAway(attackers)
    if facing and facing ~= game.profile.facing then
        game.profile.facing = facing
        sim.touch()
    end
end

---The player turns to face an enemy and walks toward it, at most yards a call, stopping within range yards of it.
---Inside an instance (no world place here) the enemy comes instead.
function combat.approach(enemy, range, yards)
    enemy.distance, enemy.bearing = measure(enemy)
    local step = math.min(yards or math.huge, enemy.distance - (range or MELEE_RANGE - 1))
    if step <= 0 or enemy.distance == math.huge then
        return false
    end
    game.profile.facing = ((game.profile.facing or 0) - enemy.bearing) % (2 * math.pi)
    if positionCache.continentId == "instance" or not game.walk(step, 0) then
        local _, north, west = playerPosition()
        moveEnemyToward(enemy, north, west, step, range)
    end
    enemy.distance, enemy.bearing = measure(enemy)
    sim.touch()
    return true
end

-- Scenario steps (play.lua): fights by script
function combat.addSteps(steps, act)
    local function enemyOf(id)
        if id == nil then
            return combat.target
        end
        if type(id) == "table" then
            return id
        end
        return combat.byId[tonumber(id) or -1]
    end
    ---Creatures near the player: spawn(npcId or name, { count, distance, bearing, level, aggro, spellId, ... })
    ---@return number? id, number[]? ids The first one's id, and all of them
    function steps.spawn(creature, options)
        local spec = {}
        for key, value in pairs(options or {}) do
            spec[key] = value
        end
        if type(creature) == "number" then
            spec.npcId = creature
        else
            spec.name = creature
        end
        local ids, problem = combat.spawn(spec)
        act("spawn " .. tostring(creature), ids ~= nil, problem)
        return ids and ids[1], ids
    end
    ---Targets an enemy (nil: none), as clicking it does
    function steps.target(id)
        if id == nil then
            sim.runSecurely(setTarget, nil)
            act("clear the target", true)
            return
        end
        local enemy = enemyOf(id)
        if enemy then
            sim.runSecurely(setTarget, enemy)
        end
        act("target " .. tostring(id), enemy ~= nil, "no such enemy")
    end
    function steps.targetNext(isReverse)
        act("tab target", sim.runSecurely(combat.targetNext, isReverse))
    end
    function steps.focus(id)
        local enemy = enemyOf(id)
        sim.runSecurely(combat.setFocus, enemy)
        act("focus " .. tostring(id), true)
    end
    function steps.hoverEnemy(id)
        sim.runSecurely(combat.setMouseover, id and enemyOf(id) or nil)
        act("hover enemy " .. tostring(id), true)
    end
    ---Auto-attack on (the target, or this enemy targeted first)
    function steps.attack(id)
        if id ~= nil then
            local enemy = enemyOf(id)
            if not enemy then
                act("attack " .. tostring(id), false, "no such enemy")
                return
            end
            sim.runSecurely(setTarget, enemy)
        end
        act("attack", sim.runSecurely(startAutoAttack, data.AUTO_ATTACK))
    end
    function steps.stopAttack()
        sim.runSecurely(stopAutoAttack)
        act("stop attacking", true)
    end
    ---Runs away from whoever fights the player (the page's Run away): auto-run, steered away, until they give up
    function steps.flee()
        act("run away", combat.flee())
    end
    ---Presses an action button's slot, as its key does (the client's UseAction, run securely)
    function steps.useAction(slot)
        sim.runSecurely(G.UseAction, slot, nil, "LeftButton")
        act("use action " .. tostring(slot), true)
    end
    function steps.cast(spellId)
        act("cast " .. tostring(spellId), sim.runSecurely(combat.castSpell, spellId))
    end
    ---Lets the clock run until check() holds (maxSeconds at most, 60 by default)
    ---@return number seconds How long it took
    function steps.waitUntil(check, maxSeconds, message)
        local seconds = 0
        while not check() and seconds < (maxSeconds or 60) do
            steps.wait(0.1)
            seconds = seconds + 0.1
        end
        act(message or "wait until", check() and true or false, "not so after " .. math.floor(seconds) .. " seconds")
        return seconds
    end
    ---Until an enemy dies (nil: the target; "player": the player)
    function steps.waitUntilDead(id, maxSeconds)
        if id == "player" then
            return steps.waitUntil(function()
                return player.isDead
            end, maxSeconds, "wait until the player dies")
        end
        local enemy = enemyOf(id)
        if not enemy then
            act("wait until dead", false, "no such enemy")
            return 0
        end
        return steps.waitUntil(function()
            return enemy.isDead
        end, maxSeconds, "wait until " .. enemy.name .. " dies")
    end
    ---Fights an enemy to its death or the player's: targets it, attacks, walks up to it (to options.range yards: 3 for a
    ---melee class, 25 for the rest), and presses the slots given whenever usable (options.slots, in order of
    ---preference; options.maxSeconds, 90 by default; options.seconds: fight that long only, whatever comes of it)
    ---@return number seconds How long the fight took
    function steps.fight(id, options)
        options = options or {}
        local enemy = enemyOf(id)
        if not enemy then
            act("fight", false, "no such enemy")
            return 0
        end
        sim.runSecurely(setTarget, enemy)
        local isMelee = data.MELEE_CLASSES[tostring(game.profile.class or ""):upper()] == true
        -- (a caster swings only when told to: options.autoAttack)
        if options.autoAttack ~= false and (isMelee or options.autoAttack) then
            sim.runSecurely(startAutoAttack, data.AUTO_ATTACK)
        end
        local range = options.range or (isMelee and 3 or 25)
        local seconds = 0
        while not enemy.isDead and not player.isDead and seconds < (options.seconds or options.maxSeconds or 90) do
            if enemy.distance > range + 0.5 and not player.cast then
                combat.approach(enemy, range, RUN_SPEED * 0.1)
            end
            for _, slot in ipairs(options.slots or {}) do
                local spellId = slotSpell(slot)
                if
                    spellId
                    and not player.cast
                    and isSpellUsable(spellId)
                    and combat.cooldownInfo(spellId).isActive ~= true
                then
                    sim.runSecurely(G.UseAction, slot, nil, "LeftButton")
                    break
                end
            end
            steps.wait(0.1)
            seconds = seconds + 0.1
        end
        local isOver = enemy.isDead or player.isDead or options.seconds ~= nil -- (options.seconds: a while only, not to the end)
        act("fight " .. enemy.name, isOver, "still fighting after " .. math.floor(seconds) .. " seconds")
        return seconds
    end
    ---Walks up to an enemy at running speed, the clock running, until within range yards (5 by default)
    ---@return number seconds How long it took
    function steps.approach(id, range)
        local enemy = enemyOf(id)
        if not enemy then
            act("approach", false, "no such enemy")
            return 0
        end
        local seconds = 0
        while combat.approach(enemy, range or MELEE_RANGE, RUN_SPEED * 0.1) and seconds < 60 do
            steps.wait(0.1)
            seconds = seconds + 0.1
        end
        act(
            "approach " .. enemy.name,
            enemy.distance <= (range or MELEE_RANGE) + 0.5,
            "still " .. math.floor(enemy.distance) .. " yards off"
        )
        return seconds
    end
    ---Opens a corpse's loot and takes everything in it
    function steps.lootCorpse(id)
        local enemy = id ~= nil and enemyOf(id) or nil
        local isOpened, problem = sim.runSecurely(combat.openLoot, enemy)
        if isOpened then
            for slot = 1, #(combat.loot and combat.loot.slots or {}) do
                sim.runSecurely(combat.lootSlot, slot)
            end
        end
        act("loot", isOpened, problem)
    end
    function steps.release()
        act("release", sim.runSecurely(combat.release))
    end
    function steps.resurrect()
        act("resurrect", sim.runSecurely(combat.resurrect))
    end
    function steps.resetCombat(seed)
        act("reset the fight", sim.runSecurely(combat.reset, seed))
    end
    ---Hurts the player (or an enemy) directly: amount, negative to heal
    function steps.hurt(amount, id)
        act("hurt", (sim.runSecurely(handlers.combatDamage, { amount = amount, enemyId = id }) or {}).ok)
    end
    ---@return table? enemy What the page sees of an enemy (CombatEnemy), nil when there is none
    function steps.enemy(id)
        local enemy = enemyOf(id)
        if not enemy then
            return nil
        end
        for _, described in ipairs(combat.describe().enemies) do
            if described.id == enemy.id then
                return described
            end
        end
    end
    function steps.combatState()
        return combat.describe()
    end
    steps.combat = combat
end

return combat
