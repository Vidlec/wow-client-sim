-- The player's action slots, as the client keeps them (1-12 the first bar, 13-24 its second page, 61-72 the bottom left
-- bar...): what is in each (a spell, an item, a macro) and everything the action bars ask about it. A new character's
-- bar holds its class's first spells and the Hearthstone; a scenario or the profile can put others ("actions").
-- Spell names and icons come from the game's own tables (SpellName, SpellMisc).
local sim = require("sim")

local actions = {}

-- Each class's basic spells as they sit on its first bar (WoW: Forever's spell numbers), then the Hearthstone
local HEARTHSTONE = 6948
local CLASS_SPELLS = {
    WARRIOR = { 6603, 78, 100, 772, 6343, 1715, 2457, 71 },
    PALADIN = { 6603, 635, 20154, 465, 19740, 853, 498, 1152 },
    HUNTER = { 75, 2973, 3044, 1978, 1130, 13163, 2974, 5116 },
    ROGUE = { 6603, 1752, 2098, 1784, 53, 1776, 1766, 921 },
    PRIEST = { 585, 2050, 589, 17, 1243, 8092, 139, 5019 },
    SHAMAN = { 403, 331, 8017, 8042, 324, 2484, 8071, 5019 },
    MAGE = { 133, 116, 2136, 122, 168, 1459, 5504, 5019 },
    WARLOCK = { 686, 172, 702, 687, 688, 348, 5782, 5019 },
    DRUID = { 5176, 5185, 1126, 8921, 774, 467, 339, 6603 },
}
local SLOTS = 180

-- Spell names and icons, read once on first use (the tables are large and most runs never need them)
local spellNames, spellIcons
local function loadSpells()
    if spellNames then return end
    spellNames, spellIcons = {}, {}
    local readTable = actions.readTable
    if not readTable then return end
    for _, row in ipairs(readTable("SpellName", { "ID", "Name_lang" }) or {}) do
        local id = tonumber(row.ID)
        if id then spellNames[id] = row.Name_lang end
    end
    for _, row in ipairs(readTable("SpellMisc", { "SpellID", "SpellIconFileDataID" }) or {}) do
        local id, icon = tonumber(row.SpellID), tonumber(row.SpellIconFileDataID)
        if id and icon and icon > 0 and not spellIcons[id] then spellIcons[id] = icon end
    end
end

---@return string? name The spell's name in the game's tables
function actions.getSpellName(spellId)
    loadSpells()
    return spellNames[tonumber(spellId) or 0]
end

---@return number? icon The spell's icon file
function actions.getSpellIcon(spellId)
    loadSpells()
    return spellIcons[tonumber(spellId) or 0]
end

---@return table slots slot -> { type = "spell"|"item"|"macro", id = number }
---@return boolean isKnown The class's own spells (those its action bars hold) are known to a character of it
function actions.isClassSpell(class, spellId)
    for _, known in ipairs(CLASS_SPELLS[tostring(class or ""):upper()] or {}) do
        if known == spellId then return true end
    end
    return false
end

function actions.getSlots(game)
    if game.profile.actions then return game.profile.actions end
    -- The class's own bar, made again when the character becomes another class (a scenario's login)
    local class = tostring(game.profile.class or ""):upper()
    if actions.defaultSlots and actions.defaultClass == class then return actions.defaultSlots end
    local slots = {}
    for index, spellId in ipairs(CLASS_SPELLS[class] or {}) do
        slots[index] = { type = "spell", id = spellId }
    end
    slots[12] = { type = "item", id = HEARTHSTONE }
    actions.defaultSlots, actions.defaultClass = slots, class
    return slots
end

function actions.install(G, game)
    local function get(slot) return actions.getSlots(game)[tonumber(slot) or 0] end
    local function getTexture(slot)
        local action = get(slot)
        if not action then return nil end
        if action.type == "spell" then return actions.getSpellIcon(action.id) or 136243 end
        if action.type == "item" then
            local item = game.items and game.items[action.id]
            return item and item.icon or 134400
        end
        return action.icon or 134400
    end
    local function getItemCount(itemId)
        return G.C_Item and G.C_Item.GetItemCount and G.C_Item.GetItemCount(itemId) or 0
    end
    local function noCooldown()
        return { startTime = 0, duration = 0, isEnabled = true, isActive = false, modRate = 1 }
    end

    -- The global ones the action buttons still call
    G.GetActionInfo = function(slot)
        local action = get(slot)
        if not action then return nil end
        if action.type == "spell" then return "spell", action.id, "spell" end
        return action.type, action.id
    end
    G.GetActionTexture = getTexture
    G.HasAction = function(slot) return get(slot) ~= nil end
    G.GetBindingText = function(key) return key and tostring(key) or "" end

    local bar = G.C_ActionBar or {}
    G.C_ActionBar = bar
    bar.HasAction = function(slot) return get(slot) ~= nil end
    bar.GetActionTexture = getTexture
    bar.GetActionText = function(slot)
        local action = get(slot)
        return action and action.type == "macro" and action.name or ""
    end
    bar.GetActionDisplayCount = function(slot)
        local action = get(slot)
        if action and action.type == "item" then
            local count = getItemCount(action.id)
            return count > 1 and tostring(count) or ""
        end
        return ""
    end
    bar.GetActionUseCount = function(slot)
        local action = get(slot)
        return action and action.type == "item" and getItemCount(action.id) or 0
    end
    bar.IsUsableAction = function(slot)
        local action = get(slot)
        if not action then return false, false end
        if action.type == "item" then return getItemCount(action.id) > 0 or action.id == HEARTHSTONE, false end
        return true, false
    end
    bar.GetActionCooldown = function() return noCooldown() end
    bar.GetActionCharges = function()
        return { currentCharges = 0, maxCharges = 0, cooldownStartTime = 0, cooldownDuration = 0, chargeModRate = 1, isActive = false }
    end
    bar.GetActionLossOfControlCooldownInfo = function()
        return { startTime = 0, duration = 0, modRate = 1, isActive = false, shouldReplaceNormalCooldown = false }
    end
    bar.GetActionBarPage = function() return actions.page or 1 end
    bar.SetActionBarPage = function(page)
        actions.page = tonumber(page) or 1
        sim.fireEvent("ACTIONBAR_PAGE_CHANGED")
    end
    bar.GetBonusBarOffset = function() return 0 end
    bar.GetBonusBarIndex = function() return 0 end
    bar.GetMultiCastBarIndex = function() return 0 end
    bar.GetOverrideBarIndex = function() return 18 end
    bar.GetVehicleBarIndex = function() return 16 end
    bar.GetTempShapeshiftBarIndex = function() return 17 end
    bar.GetExtraBarIndex = function() return 19 end
    for _, name in ipairs({ "HasBonusActionBar", "HasOverrideActionBar", "HasVehicleActionBar", "HasTempShapeshiftActionBar",
        "HasExtraActionBar", "IsPossessBarVisible", "IsCurrentAction", "IsAutoRepeatAction", "IsEquippedAction",
        "IsEquippedGearOutfitAction", "UsesActionText", "IsAssistedCombatAction", "IsAutoCastPetAction", "IsEnabledAutoCastPetAction",
        "IsConsumableAction", "IsStackableAction", "IsHarmfulAction", "IsHelpfulAction", "IsInterruptAction",
        "IsMacroActionWithShowTooltip", "HasAssistedCombatActionButtons", "HasFlyoutActionButtons", "HasPetActionButtons",
        "HasPetActionPetBarIndices", "ShouldOverrideBarShowHealthBar", "ShouldOverrideBarShowManaBar", "ShouldShowKeyring" }) do
        bar[name] = function() return false end
    end
    bar.IsAttackAction = function(slot)
        local action = get(slot)
        return action ~= nil and action.type == "spell" and action.id == 6603
    end
    bar.IsItemAction = function(slot)
        local action = get(slot)
        return action ~= nil and action.type == "item"
    end
    bar.IsActionInRange = function() return nil end
    bar.HasRangeRequirements = function() return false end
    bar.GetSpell = function(slot)
        local action = get(slot)
        return action and action.type == "spell" and action.id or nil
    end
    bar.FindSpellActionButtons = function(spellId)
        local found = {}
        for slot, action in pairs(actions.getSlots(game)) do
            if action.type == "spell" and action.id == spellId then found[#found + 1] = slot end
        end
        return found
    end
    bar.HasSpellActionButtons = function(spellId) return #bar.FindSpellActionButtons(spellId) > 0 end
    bar.FindFlyoutActionButtons = function() return {} end
    bar.FindPetActionButtons = function() return {} end
    bar.FindAssistedCombatActionButtons = function() return {} end
    bar.GetPetActionPetBarIndices = function() return {} end
    bar.IsOnBarOrSpecialBar = function(spellId) return bar.HasSpellActionButtons(spellId) end
    bar.PutActionInSlot = function(slot)
        sim.fireEvent("ACTIONBAR_SLOT_CHANGED", slot)
    end
    bar.RegisterActionUIButton = function() end
    bar.UnregisterActionUIButton = function() end
    bar.EnableActionRangeCheck = function() end
    bar.ForceUpdateAction = function(slot) sim.fireEvent("ACTIONBAR_SLOT_CHANGED", slot) end
    bar.GetProfessionQualityInfo = function() return nil end
    bar.GetProfessionQuality = function() return nil end

    -- Spells by their real names and icons, where the game's tables have them
    if G.C_Spell then
        local oldGetInfo, oldGetName = G.C_Spell.GetSpellInfo, G.C_Spell.GetSpellName
        G.C_Spell.GetSpellName = function(spellId)
            return actions.getSpellName(spellId) or (oldGetName and oldGetName(spellId))
        end
        G.C_Spell.GetSpellInfo = function(spellId)
            local info = oldGetInfo and oldGetInfo(spellId) or { spellID = spellId }
            info.name = actions.getSpellName(spellId) or info.name
            info.iconID = actions.getSpellIcon(spellId) or info.iconID
            info.originalIconID = info.iconID
            return info
        end
        G.C_Spell.GetSpellTexture = function(spellId)
            local icon = actions.getSpellIcon(spellId)
            return icon, icon
        end
    end
end

actions.SLOTS = SLOTS
return actions
