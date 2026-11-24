-- A spell's description as the client shows it (an aura's tooltip: "Increases Intellect by 2."): the game's Spell
-- table's texts with their tokens filled from SpellEffect, read once when first asked:
--   $s1 / $m1   effect 1's value             $o1   its total over the duration (a damage over time)
--   $w1         the aura's own value (its points, else effect 1's)
--   $t1         its tick period, in seconds  $d    the duration
--   $12345s1    another spell's value        $/1000;S1   a value divided
--   $lsingular:plural;   the word for the number before it
local spelltext = {}

local game -- (lua/game.lua: its table reader, game.readNamedTable)
local descriptions, effects

local function load()
    if descriptions then
        return
    end
    descriptions, effects = {}, {}
    local read = game and game.readNamedTable
    if not read then
        return
    end
    for _, row in ipairs(read("Spell", { "ID", "Description_lang", "AuraDescription_lang" }) or {}) do
        local id = tonumber(row.ID)
        if id then
            descriptions[id] = { spell = row.Description_lang, aura = row.AuraDescription_lang }
        end
    end
    local columns = { "SpellID", "EffectIndex", "EffectBasePointsF", "EffectAuraPeriod", "DifficultyID" }
    for _, row in ipairs(read("SpellEffect", columns) or {}) do
        local id = tonumber(row.SpellID)
        if id and (tonumber(row.DifficultyID) or 0) == 0 then
            effects[id] = effects[id] or {}
            effects[id][(tonumber(row.EffectIndex) or 0) + 1] = {
                points = tonumber(row.EffectBasePointsF) or 0,
                period = tonumber(row.EffectAuraPeriod) or 0,
            }
        end
    end
end

local function number(value)
    if math.abs(value - math.floor(value + 0.5)) < 0.001 then
        return tostring(math.floor(value + 0.5))
    end
    return string.format("%.1f", value)
end

local function durationText(seconds)
    if not seconds or seconds <= 0 then
        return nil
    end
    if seconds >= 3600 then
        return number(seconds / 3600) .. " hr"
    elseif seconds >= 60 then
        return number(seconds / 60) .. " min"
    end
    return number(seconds) .. " sec"
end

---The spell's own description, or its aura's (a buff's tooltip), with its tokens filled
---@param spellId number
---@param isAura boolean the aura's text (AuraDescription), else the spell's (Description)
---@param duration number? the aura's duration in seconds, for $d and $o
---@param points number[]? the aura's own values (C_UnitAuras' points), for $w
---@return string? text nil when the game's tables have none
function spelltext.describe(spellId, isAura, duration, points)
    load()
    local entry = descriptions[tonumber(spellId) or 0]
    local text = entry and (isAura and entry.aura or entry.spell)
    if not text or text == "" then
        return nil
    end
    local function effect(id, index)
        local list = effects[(id ~= "" and tonumber(id)) or spellId]
        return list and list[tonumber(index) or 1]
    end
    local lastValue
    local function remember(value)
        lastValue = value
        return number(math.abs(value))
    end
    text = text:gsub("%$/(%d+);(%d*)[sSmM](%d)", function(divisor, id, index)
        local found = effect(id, index)
        return found and remember(found.points / tonumber(divisor)) or ""
    end)
    text = text:gsub("%$(%d*)[wW](%d)", function(id, index)
        local own = id == "" and points and tonumber(points[tonumber(index)])
        if own and own ~= 0 then
            return remember(own)
        end
        local found = effect(id, index)
        return found and remember(found.points) or ""
    end)
    text = text:gsub("%$(%d*)[sSmM](%d)", function(id, index)
        local found = effect(id, index)
        return found and remember(found.points) or ""
    end)
    text = text:gsub("%$(%d*)[oO](%d)", function(id, index)
        local found = effect(id, index)
        if not (found and found.period > 0 and duration and duration > 0) then
            return found and remember(found.points) or ""
        end
        return remember(found.points * duration / (found.period / 1000))
    end)
    text = text:gsub("%$(%d*)[tT](%d)", function(id, index)
        local found = effect(id, index)
        return found and number(found.period / 1000) or ""
    end)
    text = text:gsub("%$[dD]", function()
        return durationText(duration) or ""
    end)
    text = text:gsub("%$[lL]([^:;]*):([^;]*);", function(singular, plural)
        return lastValue == 1 and singular or plural
    end)
    -- What is left unfilled (formulas, other spells' durations): left out rather than shown raw
    text = text:gsub("%${[^}]*}", ""):gsub("%$%d*%a%d*", "")
    return text
end

function spelltext.install(theGame)
    game = theGame
    descriptions, effects = nil, nil
end

return spelltext
