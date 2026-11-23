-- What the character wears: an item in each equipment slot (profile.equipment, kept with the character), from the
-- game's item tables (names, quality, icons), as the character window and addons read it: GetInventoryItemID, Link,
-- Texture, Quality, Durability, the item locations of equipment slots (C_Item.DoesItemExist, GetItemID...), and
-- EquipItemByName. A new character wears nothing; game.equip / the scenarios' equip(itemId) put things on.
local sim = require("sim")

local equipment = {}

-- Where an item goes by its inventory type (Item.InventoryType), the second slot for rings and trinkets
local SLOT_BY_TYPE = {
    [1] = { 1 }, [2] = { 2 }, [3] = { 3 }, [4] = { 4 }, [5] = { 5 }, [6] = { 6 }, [7] = { 7 }, [8] = { 8 }, [9] = { 9 },
    [10] = { 10 }, [11] = { 11, 12 }, [12] = { 13, 14 }, [13] = { 16, 17 }, [14] = { 17 }, [15] = { 18 }, [16] = { 15 },
    [17] = { 16 }, [19] = { 19 }, [20] = { 5 }, [21] = { 16 }, [22] = { 17 }, [23] = { 17 }, [24] = { 0 }, [25] = { 18 },
    [26] = { 18 }, [28] = { 18 },
}
local DURABLE_CLASSES = { [2] = true, [4] = true } -- weapons and armour wear down

function equipment.install(G, game)
    local function worn()
        local profile = game.profile
        profile.equipment = profile.equipment or {}
        return profile.equipment
    end
    local function itemIn(slot) return tonumber(worn()[tostring(tonumber(slot) or -1)]) end
    local function isPlayer(unit) return unit == nil or unit == "player" or (G.UnitIsUnit and G.UnitIsUnit(unit, "player")) end

    ---Puts an item on: in the slot given, else where its kind goes (a free one of two, else the first).
    ---@return number? slot Where it went (nil: it is not something worn)
    function game.equip(itemId, slot)
        itemId = tonumber(itemId)
        local item = itemId and game.items and game.items[itemId]
        if not item then return nil end
        local slots = SLOT_BY_TYPE[item.inventoryType]
        if not slot then
            if not slots then return nil end
            slot = slots[1]
            for _, candidate in ipairs(slots) do
                if not itemIn(candidate) then slot = candidate; break end
            end
        end
        worn()[tostring(slot)] = itemId
        sim.fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, false)
        sim.fireEvent("UNIT_INVENTORY_CHANGED", "player")
        sim.touch()
        return slot
    end
    function game.unequip(slot)
        if not itemIn(slot) then return false end
        worn()[tostring(slot)] = nil
        sim.fireEvent("PLAYER_EQUIPMENT_CHANGED", slot, true)
        sim.fireEvent("UNIT_INVENTORY_CHANGED", "player")
        sim.touch()
        return true
    end

    -- (all of GetItemInfo's values: "itemId and f()" would keep the first only)
    local function info(itemId)
        if not itemId then return nil end
        return G.C_Item.GetItemInfo(itemId)
    end
    -- (the client has no global GetItemIcon: strict mode takes the simulator's away)
    local function iconOf(itemId) return G.C_Item.GetItemIconByID(itemId) end
    G.GetInventoryItemID = function(unit, slot) if isPlayer(unit) then return itemIn(slot) end end
    G.GetInventoryItemLink = function(unit, slot)
        local itemId = isPlayer(unit) and itemIn(slot)
        if itemId then return (select(2, info(itemId))) end
    end
    G.GetInventoryItemTexture = function(unit, slot)
        local itemId = isPlayer(unit) and itemIn(slot)
        return itemId and iconOf(itemId) or nil
    end
    G.GetInventoryItemQuality = function(unit, slot)
        local itemId = isPlayer(unit) and itemIn(slot)
        if itemId then return (select(3, info(itemId))) end
    end
    G.GetInventoryItemCount = function(unit, slot) return (isPlayer(unit) and itemIn(slot)) and 1 or 0 end
    G.GetInventoryItemDurability = function(slot)
        local itemId = itemIn(slot)
        local item = itemId and game.items[itemId]
        if item and DURABLE_CLASSES[item.classId] then return 100, 100 end
    end
    G.GetInventoryItemBroken = function() return false end
    G.GetInventoryItemCooldown = function() return 0, 0, 0 end
    G.IsInventoryItemLocked = function() return false end
    G.GetInventoryItemsForSlot = function(slot, returnTable) return returnTable or {} end
    G.EquipItemByName = function(target, slot)
        local itemId = tonumber(target) or tonumber(tostring(target or ""):match("item:(%d+)"))
        if not itemId and type(target) == "string" then
            for id, item in pairs(game.items or {}) do if item.name == target then itemId = id; break end end
        end
        if itemId then game.equip(itemId, tonumber(slot)) end
    end

    -- Item locations (ItemLocation): those of equipment slots point at what is worn; bags are not simulated yet
    local function slotOf(location)
        if type(location) ~= "table" then return nil end
        if location.IsEquipmentSlot and location:IsEquipmentSlot() then return location:GetEquipmentSlot() end
        return location.equipmentSlotIndex
    end
    local C_Item = G.C_Item
    C_Item.DoesItemExist = function(location) local slot = slotOf(location); return slot ~= nil and itemIn(slot) ~= nil end
    C_Item.GetItemID = function(location) local slot = slotOf(location); return slot and itemIn(slot) end
    C_Item.GetItemIcon = function(location) local itemId = C_Item.GetItemID(location); return itemId and iconOf(itemId) end
    C_Item.GetItemLink = function(location) local itemId = C_Item.GetItemID(location); return itemId and (select(2, info(itemId))) end
    C_Item.GetItemName = function(location) local itemId = C_Item.GetItemID(location); return itemId and (info(itemId)) end
    C_Item.GetItemQuality = function(location) local itemId = C_Item.GetItemID(location); return itemId and (select(3, info(itemId))) end
    C_Item.GetCurrentItemLevel = function(location) local itemId = C_Item.GetItemID(location); return itemId and (select(4, info(itemId))) end
    C_Item.IsBound = function(location) return C_Item.DoesItemExist(location) end
    C_Item.IsLocked = function() return false end
    C_Item.IsEquippedItem = function(target)
        local itemId = tonumber(target) or tonumber(tostring(target or ""):match("item:(%d+)"))
        for _, worn_ in pairs(worn()) do if tonumber(worn_) == itemId then return true end end
        return false
    end
end

return equipment
