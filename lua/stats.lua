-- The character's stats, as the character window shows them: strength, agility, stamina, intellect and spirit from
-- the race, class and level (the game's starting values and an even climb to level 60's, near enough to the
-- client's tables for the window and an addon's sums), and what follows from them as Classic works it out: armor,
-- attack power, damage, the chances to crit, dodge, parry and block, mana regeneration. No gear, buffs or talents
-- yet: each is a value the client would give a naked character. Units other than the player get the same shape of
-- answer with zeros.
local stats = {}

local STRENGTH, AGILITY, STAMINA, INTELLECT, SPIRIT = 1, 2, 3, 4, 5

-- At level 1: every race starts from 20 of each, with its own differences
local RACE_OFFSETS = {
    Human = { 0, 0, 0, 0, 0 }, Orc = { 3, -3, 1, -3, 3 }, Dwarf = { 2, -4, 3, -1, -1 }, NightElf = { -3, 5, -1, 0, 0 },
    Scourge = { -1, -2, 0, -2, 5 }, Tauren = { 5, -5, 1, -5, 2 }, Gnome = { -5, 3, -1, 4, 0 }, Troll = { 1, 2, 0, -4, 1 },
}
-- Each class: what it adds at level 1, and what it gains by level 60
local CLASS_STATS = {
    WARRIOR = { start = { 3, 0, 2, 0, 0 }, gain = { 97, 60, 88, 10, 27 } },
    PALADIN = { start = { 2, 0, 2, 0, 1 }, gain = { 83, 37, 78, 45, 49 } },
    HUNTER = { start = { 0, 3, 1, 0, 1 }, gain = { 37, 92, 69, 40, 46 } },
    ROGUE = { start = { 1, 3, 1, 0, 0 }, gain = { 64, 107, 54, 15, 30 } },
    PRIEST = { start = { 0, 0, 0, 2, 3 }, gain = { 15, 20, 30, 98, 102 } },
    SHAMAN = { start = { 1, 0, 1, 1, 2 }, gain = { 64, 32, 71, 69, 78 } },
    MAGE = { start = { 0, 0, 0, 3, 2 }, gain = { 14, 17, 29, 102, 101 } },
    WARLOCK = { start = { 0, 0, 1, 2, 2 }, gain = { 35, 30, 54, 83, 83 } },
    DRUID = { start = { 1, 0, 0, 2, 2 }, gain = { 49, 35, 50, 83, 83 } },
}
local USES_MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true }

---@return number[] values Strength, agility, stamina, intellect and spirit for this race, class and level
function stats.base(race, class, level)
    local offsets = RACE_OFFSETS[race] or RACE_OFFSETS.Human
    local classStats = CLASS_STATS[class] or CLASS_STATS.WARRIOR
    local climb = math.max(0, math.min(59, (tonumber(level) or 1) - 1)) / 59
    local values = {}
    for index = 1, 5 do
        values[index] = math.floor(20 + offsets[index] + classStats.start[index] + classStats.gain[index] * climb + 0.5)
    end
    return values
end

function stats.install(G, game)
    local function isPlayer(unit) return unit == "player" or (unit and G.UnitIsUnit and G.UnitIsUnit(unit, "player")) end
    local function current()
        local profile = game.profile
        return stats.base(profile.race, profile.class, profile.level), profile.class or "WARRIOR", profile.level or 1
    end
    -- base, effective, gained, lost: as UnitStat answers
    G.UnitStat = function(unit, index)
        if not isPlayer(unit) then return 0, 0, 0, 0 end
        local value = current()[tonumber(index) or 0] or 0
        return value, value, 0, 0
    end
    G.UnitArmor = function(unit)
        -- (base, effective, armor, bonus armor: four, as the client answers)
        if not isPlayer(unit) then return 0, 0, 0, 0 end
        local armor = current()[AGILITY] * 2
        return armor, armor, armor, 0
    end
    local function attackPower()
        local values, class, level = current()
        local strength, agility = values[STRENGTH], values[AGILITY]
        if class == "WARRIOR" or class == "PALADIN" or class == "SHAMAN" then return level * 3 - 20 + strength * 2 end
        if class == "ROGUE" or class == "HUNTER" then return level * 2 - 20 + strength + agility end
        if class == "DRUID" then return strength * 2 - 20 end
        return strength - 10
    end
    G.UnitAttackPower = function(unit)
        if not isPlayer(unit) then return 0, 0, 0 end
        return math.max(0, attackPower()), 0, 0
    end
    G.UnitRangedAttackPower = function(unit)
        if not isPlayer(unit) then return 0, 0, 0 end
        local values, class, level = current()
        local power = class == "HUNTER" and (level * 2 - 10 + values[AGILITY] * 2)
            or ((class == "WARRIOR" or class == "ROGUE") and (level - 10 + values[AGILITY])) or 0
        return math.max(0, power), 0, 0
    end
    G.GetAttackPowerForStat = function(statIndex, amount)
        local _, class = current()
        amount = tonumber(amount) or 0
        if statIndex == STRENGTH then
            if class == "WARRIOR" or class == "PALADIN" or class == "SHAMAN" or class == "DRUID" then return amount * 2 end
            return amount
        end
        if statIndex == AGILITY and (class == "ROGUE" or class == "HUNTER") then return amount end
        return 0
    end
    -- Bare hands: 2 seconds a swing, attack power adding a 14th of itself a second
    G.UnitAttackSpeed = function(unit) return 2, nil, nil end
    G.UnitDamage = function(unit)
        if not isPlayer(unit) then return 0, 0, nil, nil, 0, 0, 1 end
        local bonus = math.max(0, attackPower()) / 14 * 2
        return 1 + bonus, 2 + bonus, nil, nil, 0, 0, 1
    end
    G.UnitRangedDamage = function(unit) return 0, 0, 0, 0, 0, 1 end
    G.UnitResistance = function(unit, school) return 0, 0, 0, 0 end
    G.GetCritChance = function() return 5 + current()[AGILITY] / 20 end
    G.GetRangedCritChance = function() return 5 + current()[AGILITY] / 20 end
    G.GetSpellCritChance = function(school) return 1 + current()[INTELLECT] / 60 end
    G.GetDodgeChance = function() return current()[AGILITY] / 20 end
    G.GetParryChance = function()
        local _, class = current()
        return (class == "WARRIOR" or class == "PALADIN" or class == "ROGUE" or class == "HUNTER") and 5 or 0
    end
    G.GetBlockChance = function()
        local _, class = current()
        return (class == "WARRIOR" or class == "PALADIN" or class == "SHAMAN") and 5 or 0
    end
    G.GetShieldBlock = function() return 0 end
    -- Mana a second from spirit, out of casting and in it (none for a class without mana)
    G.GetManaRegen = function()
        local values, class = current()
        if not USES_MANA[class] then return 0, 0 end
        local perSecond = (values[SPIRIT] / 5 + 15) / 2
        return perSecond, 0
    end
    G.GetCombatRating = function() return 0 end
    G.GetCombatRatingBonus = function() return 0 end
    G.GetSpellBonusDamage = function() return 0 end
    G.GetSpellBonusHealing = function() return 0 end
    G.GetHitModifier = function() return 0 end
    G.GetSpellHitModifier = function() return 0 end
    G.GetExpertise = function() return 0, 0, 0 end -- (main hand, off hand, ranged)
    G.GetArmorPenetration = function() return 0 end
    G.GetSpellPenetration = function() return 0 end
    -- Defense: five points a level, nothing added
    G.UnitDefenseSkill = function(unit)
        local level = isPlayer(unit) and (game.profile.level or 1) or (G.UnitLevel and G.UnitLevel(unit) or 1)
        return (tonumber(level) or 1) * 5, 0
    end
    G.GetEffectiveDefenseSkill = function()
        local skill = (game.profile.level or 1) * 5
        return skill, skill, 0
    end
    G.GetEnemySkillDifference = function() return 0 end
    -- What one point of a stat gives: the window's tooltips
    G.GetDodgeChanceFromAttribute = function() return current()[AGILITY] / 20 end
    G.GetCritChanceFromStat = function() return current()[AGILITY] / 20 end
    G.GetSpellCritChanceFromStat = function() return current()[INTELLECT] / 60 end
    G.GetRangedAttackPowerForStat = function(statIndex, amount)
        local _, class = current()
        if statIndex == AGILITY then return (tonumber(amount) or 0) * (class == "HUNTER" and 2 or 1) end
        return 0
    end
    G.GetManaRegenFromSpirit = function()
        local values, class = current()
        return USES_MANA[class] and (values[SPIRIT] / 5 + 15) / 2 or 0
    end
    G.GetHealthRegen = function() return current()[SPIRIT] / 10, 0 end -- (out of combat, in combat)
    G.GetHealthRegenFromSpirit = function() return current()[SPIRIT] / 10 end
end

return stats
