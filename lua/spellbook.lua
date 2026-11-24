-- The player's spellbook, from the game's own tables, as a character of this race and class has it at their level:
--
--   General   the race's abilities (its racial skill line's spells granted with it: SkillLineAbility AcquireMethod 2),
--             and the class's basic attacks the action bars hold (Attack, Shoot) that belong to no school
--   one tab a class skill line (Arcane, Fire, Frost...: SkillLine CategoryID 7, in name order, as the talent tabs),
--             every rank of its spells trained by this level (SpellLevels BaseLevel), talent spells left out (Talent)
--
-- Spells a profile lists ("spells") join their school's tab, or General. Lower ranks are marked (the book hides them
-- unless asked), passives too (SpellMisc Attributes_0 0x40); spells the client never shows (0x80) are left out.
-- C_SpellBook answers from it; the book is worked out again when the class, race, level or spells change.
local spellbook = {}

local bit = require("bit")
local band, lshift = bit.band, bit.lshift

local CATEGORY_CLASS, CATEGORY_RACIAL = 7, 9
local ACQUIRE_TRAINED, ACQUIRE_WITH_SKILL = 0, 2
local ATTR0_PASSIVE, ATTR0_HIDDEN = 0x40, 0x80
local GENERAL_ICON = "Interface\\Icons\\INV_Misc_Book_09"

local data -- the tables, read once: lines, abilities by line, levels, attributes, talent spells

local function readData(readTable)
    if data then
        return data
    end
    data = { lines = {}, abilities = {}, levels = {}, attributes = {}, talents = {} }
    for _, row in ipairs(readTable("SkillLine", { "ID", "DisplayName_lang", "CategoryID", "SpellIconFileID" }) or {}) do
        local id = tonumber(row.ID)
        if id then
            data.lines[id] = {
                id = id,
                name = row.DisplayName_lang or "",
                category = tonumber(row.CategoryID),
                icon = tonumber(row.SpellIconFileID),
            }
        end
    end
    for _, row in
        ipairs(
            readTable(
                "SkillLineAbility",
                { "SkillLine", "Spell", "ClassMask", "RaceMasks_0", "AcquireMethod", "NumSkillUps" }
            ) or {}
        )
    do
        local line, spellId = tonumber(row.SkillLine), tonumber(row.Spell)
        if line and spellId then
            data.abilities[line] = data.abilities[line] or {}
            table.insert(data.abilities[line], {
                spellId = spellId,
                classMask = tonumber(row.ClassMask) or 0,
                raceMask = tonumber(row.RaceMasks_0) or 0,
                acquire = tonumber(row.AcquireMethod) or 0,
                skillUps = tonumber(row.NumSkillUps) or 0,
            })
        end
    end
    for _, row in ipairs(readTable("SpellLevels", { "SpellID", "BaseLevel", "DifficultyID" }) or {}) do
        local spellId = tonumber(row.SpellID)
        if spellId and (tonumber(row.DifficultyID) or 0) == 0 then
            data.levels[spellId] = tonumber(row.BaseLevel) or 0
        end
    end
    for _, row in ipairs(readTable("SpellMisc", { "SpellID", "Attributes_0", "DifficultyID" }) or {}) do
        local spellId = tonumber(row.SpellID)
        if spellId and (tonumber(row.DifficultyID) or 0) == 0 then
            data.attributes[spellId] = tonumber(row.Attributes_0) or 0
        end
    end
    local rankColumns = { "SpellID" }
    for rank = 0, 8 do
        rankColumns[#rankColumns + 1] = "SpellRank_" .. rank
    end
    for _, row in ipairs(readTable("Talent", rankColumns) or {}) do
        for _, column in ipairs(rankColumns) do
            local spellId = tonumber(row[column])
            if spellId and spellId > 0 then
                data.talents[spellId] = true
            end
        end
    end
    return data
end

local function matches(mask, id)
    return mask == 0 or (id ~= nil and band(mask, lshift(1, id - 1)) ~= 0)
end

---@param profile table The character: classId, raceId, level, class, spells
---@param basicSpells number[] The class's spells its action bars hold (General takes those no school has)
---@param getName fun(spellId: number): string?
---@param getIcon fun(spellId: number): number?
---@return table book { lines = { { name, icon, spells = { { spellId, name, subName, icon, isPassive, isLowRank, level } } } }, slots, bySpell }
function spellbook.build(readTable, profile, basicSpells, getName, getIcon)
    local tables = readData(readTable)
    local level = tonumber(profile.level) or 1
    local classId, raceId = tonumber(profile.classId), tonumber(profile.raceId)
    local extra = profile.spells or {}
    local general = { name = "General", icon = GENERAL_ICON, spells = {} }
    local schools = {}
    local placed = {}
    -- A talent's spells need the talent: every spell of a talent's name is left out (its ranks a trainer teaches too)
    local talentNames = {}
    for spellId in pairs(tables.talents) do
        local name = getName(spellId)
        if name then
            talentNames[name] = true
        end
    end

    local function add(line, spellId, spellLevel)
        if placed[spellId] then
            return
        end
        local attributes = tables.attributes[spellId] or 0
        if band(attributes, ATTR0_HIDDEN) ~= 0 then
            return
        end
        local name = getName(spellId)
        if not name then
            return
        end
        placed[spellId] = true
        table.insert(line.spells, {
            spellId = spellId,
            name = name,
            icon = getIcon(spellId) or 136243,
            level = spellLevel or 1,
            isPassive = band(attributes, ATTR0_PASSIVE) ~= 0,
        })
    end

    for lineId, line in pairs(tables.lines) do
        local abilities = tables.abilities[lineId] or {}
        if line.category == CATEGORY_CLASS then
            local school = { name = line.name, icon = line.icon, spells = {} }
            -- Taught by a trainer: a spell that comes with the skill, or at a level past the first; its other ranks are
            -- taught too (Arcane Intellect's first, at level 1). An effect no trainer teaches has neither (Chilled).
            local taughtNames = {}
            for _, ability in ipairs(abilities) do
                if
                    ability.acquire == ACQUIRE_WITH_SKILL
                    or (ability.acquire == ACQUIRE_TRAINED and (tables.levels[ability.spellId] or 0) > 1)
                then
                    taughtNames[getName(ability.spellId) or ""] = true
                end
            end
            for _, ability in ipairs(abilities) do
                local spellId = ability.spellId
                local spellLevel = tables.levels[spellId] or 1
                -- Trained: the class's, by this level; not a talent's, not an effect no trainer teaches, not a rune's
                -- (no skill-ups: engraved, not trained)
                local isTaught = (ability.acquire == ACQUIRE_WITH_SKILL or ability.acquire == ACQUIRE_TRAINED)
                    and taughtNames[getName(spellId) or ""] == true
                    and tables.levels[spellId] ~= nil
                local isTrained = ability.classMask ~= 0
                    and matches(ability.classMask, classId)
                    and matches(ability.raceMask, raceId)
                    and isTaught
                    and ability.skillUps > 0
                    and spellLevel <= level
                    and not tables.talents[spellId]
                    and not talentNames[getName(spellId) or ""]
                if isTrained or extra[spellId] then
                    add(school, spellId, spellLevel)
                end
            end
            if #school.spells > 0 then
                schools[#schools + 1] = school
            end
        elseif line.category == CATEGORY_RACIAL then
            for _, ability in ipairs(abilities) do
                if
                    ability.raceMask ~= 0
                    and matches(ability.raceMask, raceId)
                    and matches(ability.classMask, classId)
                    and ability.acquire == ACQUIRE_WITH_SKILL
                then
                    add(general, ability.spellId, tables.levels[ability.spellId])
                end
            end
        end
    end
    add(general, 6603, 1) -- Attack: every class's
    for _, spellId in ipairs(basicSpells or {}) do
        if not placed[spellId] and spellId ~= 6948 then
            add(general, spellId, 1)
        end -- (not the Hearthstone: an item)
    end
    for spellId in pairs(extra) do
        if type(spellId) == "number" and not placed[spellId] then
            add(general, spellId, tables.levels[spellId])
        end
    end

    table.sort(schools, function(a, b)
        return a.name < b.name
    end)
    local book = { lines = { general }, slots = {}, bySpell = {} }
    for _, school in ipairs(schools) do
        book.lines[#book.lines + 1] = school
    end
    for lineIndex, line in ipairs(book.lines) do
        -- Ranks: the same spell's ranks by the level they come at; every one below the highest is a lower rank
        local byName = {}
        for _, spell in ipairs(line.spells) do
            byName[spell.name] = byName[spell.name] or {}
            table.insert(byName[spell.name], spell)
        end
        for _, ranks in pairs(byName) do
            table.sort(ranks, function(a, b)
                return a.level < b.level or (a.level == b.level and a.spellId < b.spellId)
            end)
            for rank, spell in ipairs(ranks) do
                spell.subName = #ranks > 1 and ("Rank " .. rank) or (spell.isPassive and "Passive" or "")
                spell.isLowRank = rank < #ranks
            end
        end
        -- The book's order: by name, each spell's ranks together, lowest first (as the classic book lists them)
        table.sort(line.spells, function(a, b)
            if a.name ~= b.name then
                return a.name < b.name
            end
            return a.level < b.level or (a.level == b.level and a.spellId < b.spellId)
        end)
        line.offset = #book.slots
        for _, spell in ipairs(line.spells) do
            book.slots[#book.slots + 1] = spell
            spell.slot, spell.lineIndex = #book.slots, lineIndex
            book.bySpell[spell.spellId] = spell
        end
    end
    return book
end

return spellbook
