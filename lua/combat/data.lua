-- What the battle simulator knows of spells and creatures, from the game's own tables where it has them: a spell's
-- cast time, range, cost, cooldowns and effects (SpellMisc, SpellCastTimes, SpellRange, SpellPower, SpellCooldowns,
-- SpellEffect, SpellDuration, SpellRadius, SpellLevels), a creature's name, level, rank, health and side (QuestieDB's
-- NPC data, the game's FactionTemplate). Each table is read the first time a fight needs it; without one the numbers
-- below are guesses (said so where they are made).
local data = {}

-- The tables, read through the game's reader (boot.lua's readTable: bootcache keeps the rows between runs)
data.readTable = nil

local function number(value) return tonumber(value) or 0 end

-- Rows by spell, the first of a spell's rows for the normal difficulty (DifficultyID 0), read once per table
local tables = {}
local function bySpell(name, columns)
    if tables[name] then return tables[name] end
    local rows = {}
    for _, row in ipairs(data.readTable and data.readTable(name, columns) or {}) do
        local spellId = tonumber(row.SpellID)
        if spellId and number(row.DifficultyID) == 0 and not rows[spellId] then rows[spellId] = row end
    end
    tables[name] = rows
    return rows
end
local function byId(name, columns)
    if tables[name] then return tables[name] end
    local rows = {}
    for _, row in ipairs(data.readTable and data.readTable(name, columns) or {}) do
        local id = tonumber(row.ID)
        if id then rows[id] = row end
    end
    tables[name] = rows
    return rows
end
-- Every effect of a spell, in its order
local function effectsBySpell()
    if tables.SpellEffect then return tables.SpellEffect end
    local rows = {}
    for _, row in ipairs(data.readTable and data.readTable("SpellEffect", { "EffectAura", "DifficultyID", "EffectIndex", "Effect",
        "EffectAuraPeriod", "EffectPointsPerResource", "EffectRealPointsPerLevel", "Variance", "EffectBasePointsF", "EffectMiscValue_0",
        "EffectRadiusIndex_0", "ImplicitTarget_0", "ImplicitTarget_1", "SpellID" }) or {}) do
        local spellId = tonumber(row.SpellID)
        if spellId and number(row.DifficultyID) == 0 then
            rows[spellId] = rows[spellId] or {}
            table.insert(rows[spellId], {
                index = number(row.EffectIndex), effect = number(row.Effect), aura = number(row.EffectAura), period = number(row.EffectAuraPeriod) / 1000,
                base = number(row.EffectBasePointsF), variance = number(row.Variance), perLevel = number(row.EffectRealPointsPerLevel),
                perResource = number(row.EffectPointsPerResource), misc = number(row.EffectMiscValue_0), radiusIndex = number(row.EffectRadiusIndex_0),
                target = number(row.ImplicitTarget_0), target2 = number(row.ImplicitTarget_1),
            })
        end
    end
    for _, list in pairs(rows) do table.sort(list, function(first, second) return first.index < second.index end) end
    tables.SpellEffect = rows
    return rows
end

-- The game's numbers for what an effect does (SpellEffect.Effect) and what an aura does (EffectAura), those the
-- simulator acts on
data.EFFECT = { SCHOOL_DAMAGE = 2, HEAL = 10, WEAPON_DAMAGE_NOSCHOOL = 17, APPLY_AURA = 6, ENERGIZE = 30, WEAPON_PERCENT_DAMAGE = 31,
    APPLY_AREA_AURA_PARTY = 35, WEAPON_DAMAGE = 58, INTERRUPT_CAST = 68, ATTACK = 78, CHARGE = 96, NORMALIZED_WEAPON_DMG = 121 }
data.AURA = { PERIODIC_DAMAGE = 3, MOD_FEAR = 7, PERIODIC_HEAL = 8, MOD_STUN = 12, MOD_ROOT = 26, MOD_DECREASE_SPEED = 33,
    PERIODIC_LEECH = 53, SCHOOL_ABSORB = 69 }
-- Where an effect lands (ImplicitTarget): the caster, an enemy, a friend, enemies around the caster
data.TARGET = { CASTER = 1, ENEMY = 6, AREA_ENEMY_AROUND_SOURCE = 15, AREA_ENEMY = 16, FRIEND = 21, SOURCE_CASTER = 22, ANY = 25, CASTER_AREA = 22 }
-- Power types, as the client numbers them (Enum.PowerType)
data.POWER = { MANA = 0, RAGE = 1, FOCUS = 2, ENERGY = 3, COMBO_POINTS = 4 }
data.POWER_NAMES = { [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY", [4] = "COMBO_POINTS" }

local AUTO_ATTACK, AUTO_SHOT, SHOOT = 6603, 75, 5019
data.AUTO_ATTACK, data.AUTO_SHOT, data.SHOOT = AUTO_ATTACK, AUTO_SHOT, SHOOT

local spellCache = {}
---@return table? spell What the simulator knows of a spell: nil for none the game's tables name
function data.getSpell(spellId)
    spellId = tonumber(spellId)
    if not spellId then return nil end
    local cached = spellCache[spellId]
    if cached ~= nil then return cached or nil end
    local actions = require("actions")
    local name = actions.getSpellName(spellId)
    if not name then spellCache[spellId] = false; return nil end
    local misc = bySpell("SpellMisc", { "Attributes_0", "Attributes_1", "DifficultyID", "CastingTimeIndex", "DurationIndex", "RangeIndex", "SchoolMask", "SpellID" })[spellId]
    local power = bySpell("SpellPower", { "OrderIndex", "ManaCost", "PowerType", "PowerCostPct", "SpellID" })[spellId]
    local cooldown = bySpell("SpellCooldowns", { "DifficultyID", "CategoryRecoveryTime", "RecoveryTime", "StartRecoveryTime", "SpellID" })[spellId]
    local levels = bySpell("SpellLevels", { "DifficultyID", "MaxLevel", "BaseLevel", "SpellLevel", "SpellID" })[spellId]
    local castTimes = byId("SpellCastTimes")
    local ranges = byId("SpellRange", { "ID", "RangeMin_0", "RangeMax_0" })
    local durations = byId("SpellDuration", { "ID", "Duration" })
    local attributes0, attributes1 = misc and number(misc.Attributes_0) or 0, misc and number(misc.Attributes_1) or 0
    local castTime = misc and castTimes[number(misc.CastingTimeIndex)]
    local range = misc and ranges[number(misc.RangeIndex)]
    local duration = misc and durations[number(misc.DurationIndex)]
    local powerType = power and number(power.PowerType) or data.POWER.MANA
    local cost = power and number(power.ManaCost) or 0
    -- Rage and the like are kept in tenths in the tables (Heroic Strike's 150 is 15 rage)
    if powerType == data.POWER.RAGE then cost = cost / 10 end
    local spell = {
        id = spellId, name = name, icon = actions.getSpellIcon(spellId) or 136243,
        castTime = castTime and number(castTime.Base) / 1000 or 0,
        rangeMin = range and number(range.RangeMin_0) or 0, rangeMax = range and number(range.RangeMax_0) or 5,
        -- "Combat Range" (index 2, 5 yards in the table): melee, the reach of both added in the client (guessed as 5)
        isMelee = misc ~= nil and number(misc.RangeIndex) == 2,
        isSelf = misc ~= nil and number(misc.RangeIndex) == 1,
        cost = cost, powerType = powerType, costPercent = power and number(power.PowerCostPct) or 0,
        cooldown = cooldown and number(cooldown.RecoveryTime) / 1000 or 0,
        categoryCooldown = cooldown and number(cooldown.CategoryRecoveryTime) / 1000 or 0,
        gcd = cooldown and number(cooldown.StartRecoveryTime) / 1000 or 0,
        school = misc and number(misc.SchoolMask) or 1,
        -- SPELL_ATTR0_ON_NEXT_SWING (0x4): Heroic Strike, Raptor Strike wait for the next swing
        isOnNextSwing = bit and bit.band(attributes0, 0x4) ~= 0 or false,
        -- SPELL_ATTR0_PASSIVE (0x40)
        isPassive = bit and bit.band(attributes0, 0x40) ~= 0 or false,
        -- SPELL_ATTR1_CHANNELED_1 (0x4): Arcane Missiles, Drain Life, Mind Flay
        isChanneled = bit and bit.band(attributes1, 0x4) ~= 0 or false,
        duration = duration and number(duration.Duration) / 1000 or 0,
        baseLevel = levels and number(levels.BaseLevel) or 1, maxLevel = levels and number(levels.MaxLevel) or 0,
        spellLevel = levels and number(levels.SpellLevel) or 1,
        effects = effectsBySpell()[spellId] or {},
        isAutoAttack = spellId == AUTO_ATTACK, isAutoRepeat = spellId == AUTO_SHOT or spellId == SHOOT,
        hasData = misc ~= nil,
    }
    if spell.duration < 0 then spell.duration = 0 end -- (-1: until cancelled, as auras and stances are)
    spell.isUntilCancelled = duration ~= nil and number(duration.Duration) < 0
    -- Without the tables: a guess from nothing, an instant spell at 30 yards on the global cooldown
    if not misc then spell.rangeMax, spell.gcd = 30, 1.5 end
    if spell.isAutoRepeat then spell.gcd = 0 end
    spellCache[spellId] = spell
    return spell
end

---@return number cost, number powerType What a spell costs, from SpellPower alone (the action bars ask it for every
---button: the rest of the spell's tables are read only when one is cast)
function data.getCost(spellId)
    spellId = tonumber(spellId)
    local cached = spellId and spellCache[spellId]
    if cached then return cached.cost, cached.powerType end
    local power = spellId and bySpell("SpellPower", { "OrderIndex", "ManaCost", "PowerType", "PowerCostPct", "SpellID" })[spellId]
    if not power then return 0, data.POWER.MANA end
    local powerType, cost = number(power.PowerType), number(power.ManaCost)
    if powerType == data.POWER.RAGE then cost = cost / 10 end
    return cost, powerType
end

---@return number radius The radius of an effect's area, in yards (SpellRadius); 10 when the table does not say (a guess)
function data.getRadius(radiusIndex)
    local row = byId("SpellRadius", { "ID", "Radius" })[radiusIndex or 0]
    return row and number(row.Radius) or 10
end

-- Creatures: the game's FactionTemplate rows, for the side a creature takes
local function templateOf(id) return byId("FactionTemplate")[tonumber(id) or -1] end
local function listHas(row, prefix, faction)
    for index = 0, 7 do
        local value = number(row[prefix .. index])
        if value ~= 0 and value == faction then return true end
    end
    return false
end
local function isHostileTo(row, other)
    if number(row.Faction) == number(other.Faction) then return false end
    if listHas(row, "Enemies_", number(other.Faction)) then return true end
    if listHas(row, "Friend_", number(other.Faction)) then return false end
    return bit.band(number(row.EnemyGroup), number(other.FactionGroup)) ~= 0
end
local function isFriendlyTo(row, other)
    if number(row.Faction) == number(other.Faction) then return true end
    if listHas(row, "Enemies_", number(other.Faction)) then return false end
    if listHas(row, "Friend_", number(other.Faction)) then return true end
    return bit.band(number(row.FriendGroup), number(other.FactionGroup)) ~= 0 or bit.band(number(other.FriendGroup), number(row.FactionGroup)) ~= 0
end
-- The player's own template, by race (ChrRaces' faction templates: the classic ones)
local RACE_TEMPLATES = { Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Scourge = 5, Tauren = 6, Gnome = 115, Troll = 116 }

---@return number reaction How a creature of this faction template stands to the player, as UnitReaction counts:
---2 hostile, 4 neutral, 5 friendly. The game's own rule (FactionTemplate's groups and lists); nil without the table
function data.getReaction(factionTemplateId, race)
    local row, player = templateOf(factionTemplateId), templateOf(RACE_TEMPLATES[race] or 1)
    if not row or not player then return nil end
    if isHostileTo(row, player) or isHostileTo(player, row) then return 2 end
    if isFriendlyTo(row, player) then return 5 end
    return 4
end

local function npcField(npcId, field)
    local database = require("sim").G.LibQuestieDB
    local npcs = type(database) == "table" and database.Npc
    if not npcs or not npcs.Get then return nil end
    local isRead, value = pcall(npcs.Get, npcId, field)
    if isRead then return value end
end
data.npcField = npcField

---@return number? npcId The creature a name stands for (QuestieDB's names, the exact name first, then a part of one)
function data.findNpc(name)
    local found = require("game").findNpcs(name, 50) or {}
    local wanted = tostring(name or ""):lower()
    for _, result in ipairs(found) do
        if tostring(result.name or ""):lower() == wanted then return result.id end
    end
    return found[1] and found[1].id or nil
end

-- The ranks as UnitClassification names them (QuestieDB's rank: cmangos' creature_template ranks)
data.CLASSIFICATIONS = { [0] = "normal", [1] = "elite", [2] = "rareelite", [3] = "worldboss", [4] = "rare" }

-- Names that cast: the creature's first spell, by what it calls itself (a guess: the NPC data has no spells). Fire,
-- frost, shadow, nature and holy bolts at rank 1, cast in 2 to 3 seconds
local CASTER_WORDS = {
    { "pyromancer", 133 }, { "fire", 133 }, { "flame", 133 }, { "mage", 133 }, { "sorcer", 133 }, { "conjurer", 116 }, { "evoker", 116 },
    { "frost", 116 }, { "ice", 116 }, { "hydromancer", 116 }, { "necromancer", 686 }, { "warlock", 686 }, { "cultist", 686 },
    { "shadow", 686 }, { "acolyte", 686 }, { "witch", 686 }, { "dark", 686 }, { "summoner", 686 }, { "shaman", 403 }, { "mystic", 403 },
    { "oracle", 403 }, { "seer", 403 }, { "geomancer", 403 }, { "storm", 403 }, { "druid", 5176 }, { "priest", 585 }, { "cleric", 585 },
    { "adept", 585 }, { "neophyte", 585 }, { "augur", 403 }, { "channeler", 686 }, { "apprentice", 133 }, { "invoker", 133 },
}

---@return table? creature What a creature of the game is: name, levels, rank, health, side, the spell it casts
function data.getCreature(npcId)
    npcId = tonumber(npcId)
    if not npcId then return nil end
    local name = npcField(npcId, "name")
    if not name then return nil end
    local lowered = name:lower()
    local spellId
    for _, word in ipairs(CASTER_WORDS) do
        if lowered:find(word[1], 1, true) then spellId = word[2]; break end
    end
    return {
        npcId = npcId, name = name, subName = npcField(npcId, "subName"),
        minLevel = npcField(npcId, "minLevel") or 1, maxLevel = npcField(npcId, "maxLevel") or npcField(npcId, "minLevel") or 1,
        minHealth = npcField(npcId, "minLevelHealth"), maxHealth = npcField(npcId, "maxLevelHealth"),
        rank = npcField(npcId, "rank") or 0, factionId = npcField(npcId, "factionID"), friendlyTo = npcField(npcId, "friendlyToFaction"),
        spellId = spellId,
    }
end

-- Numbers for a fight, from levels and classes. None is measured in the client: they are made so a fight with a
-- creature of the player's level takes about 20 seconds and the player wins it with half their health or so,
-- as a classic fight goes (guesses, said so)

---@return number health A creature's health at a level without the database's (about classic's: 42 at 1, 1000 at 30)
function data.guessCreatureHealth(level, rank)
    local health = 15 * level + 0.6 * level * level + 30
    if rank == 1 or rank == 2 then health = health * 3 elseif rank == 3 then health = health * 20 end
    return math.floor(health)
end

---@return number damage A creature's average melee swing (2 seconds): 17 at level 10, 70 at 30, 200 at 60
function data.guessCreatureSwing(level, rank)
    local damage = 1.2 * level + 0.035 * level * level + 2
    if rank == 1 or rank == 2 then damage = damage * 2 elseif rank == 3 then damage = damage * 4 end
    return damage
end

---@return number dps The damage a character of a level deals a second: 15 at level 10, 60 at 30, 185 at 60
function data.playerDps(level) return 0.04 * level * level + 0.6 * level + 5 end

-- The classes that fight in melee: their swings carry most of their damage (the rest their spells)
data.MELEE_CLASSES = { WARRIOR = true, ROGUE = true, PALADIN = true, SHAMAN = true, DRUID = true, HUNTER = true }

---@return number factor How much stronger a spell is at a level than at its own (the bars hold rank 1): as if the
---character had the rank of its level, near enough (Fireball's 18 becomes 210 at level 30; 590 at 60, a guess)
function data.rankFactor(spell, level, exponent)
    local base = math.max(1, spell.baseLevel or 1)
    return math.max(1, ((level + 5) / (base + 5)) ^ (exponent or 1.4))
end

-- A character's base health and mana by class at levels 1 and 60 (near classic's tables; between them a curve,
-- a guess): health and mana then gain from stamina and intellect as the client counts (the first 20 points one
-- each, the rest 10 health or 15 mana)
local BASE = {
    WARRIOR = { 60, 1689, 0, 0 }, PALADIN = { 58, 1381, 80, 1512 }, HUNTER = { 46, 1467, 85, 1720 }, ROGUE = { 45, 1523, 0, 0 },
    PRIEST = { 52, 1397, 110, 1436 }, SHAMAN = { 47, 1423, 70, 1520 }, MAGE = { 32, 1365, 120, 1273 }, WARLOCK = { 43, 1414, 110, 1373 },
    DRUID = { 44, 1483, 60, 1244 },
}
function data.playerMaxima(class, race, level)
    local base = BASE[class] or BASE.WARRIOR
    local climb = (math.max(0, math.min(59, (level or 1) - 1)) / 59) ^ 1.3
    local values = require("stats").base(race, class, level)
    local stamina, intellect = values[3], values[4]
    local health = base[1] + (base[2] - base[1]) * climb + math.min(stamina, 20) + math.max(0, stamina - 20) * 10
    local mana = 0
    if base[4] > 0 then mana = base[3] + (base[4] - base[3]) * climb + math.min(intellect, 20) + math.max(0, intellect - 20) * 15 end
    return math.floor(health), math.floor(mana)
end

-- Experience, as classic counts it (wowpedia's formulas): a kill gives 45 + 5 x its level, more for a higher one,
-- less for a lower one down to the grey level, twice for an elite
local function zeroDifference(level)
    if level < 8 then return 5 elseif level < 10 then return 6 elseif level < 12 then return 7 elseif level < 16 then return 8
    elseif level < 20 then return 9 elseif level < 30 then return 11 elseif level < 40 then return 12 elseif level < 45 then return 13
    elseif level < 50 then return 14 elseif level < 55 then return 15 elseif level < 60 then return 16 end
    return 17
end
function data.greyLevel(level)
    if level <= 5 then return 0 elseif level < 40 then return level - math.floor(level / 10) - 5 end
    return level - math.floor(level / 5) - 1
end
function data.killExperience(playerLevel, creatureLevel, rank)
    if creatureLevel <= data.greyLevel(playerLevel) then return 0 end
    local base = 45 + 5 * creatureLevel
    local xp
    if creatureLevel >= playerLevel then
        xp = base * (1 + 0.05 * math.min(creatureLevel - playerLevel, 4))
    else
        xp = base * (1 - (playerLevel - creatureLevel) / zeroDifference(playerLevel))
    end
    if rank == 1 or rank == 2 then xp = xp * 2 end
    return math.max(0, math.floor(xp + 0.5))
end

---@return number xp What a level takes to the next, as classic's table has it ((8 x level + difference) x (45 + 5 x
---level), to the hundred: 400 at 1, 900 at 2...)
function data.levelExperience(level)
    local difference = 0
    if level == 29 then difference = 1 elseif level == 30 then difference = 3 elseif level == 31 then difference = 6
    elseif level >= 32 then difference = 5 * (level - 30) end
    return math.floor(((8 * level + difference) * (45 + 5 * level)) / 100 + 0.5) * 100
end

---@return number rageFactor Classic's rage conversion for a level (damage / factor x 7.5 dealt, x 2.5 taken)
function data.rageFactor(level) return 0.0091107836 * level * level + 3.225598133 * level + 4.2652911 end

return data
