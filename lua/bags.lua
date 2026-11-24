-- The player's bags, as the client keeps them: the backpack (container 0, 16 slots) and the bags equipped in the
-- four bag slots (containers 1-4, inventory slots 31-34: the profile's "bags", each a bag item whose size is its
-- ContainerSlots), holding the character's items (the profile's "items": counts, filled by looting) laid out in
-- stacks of the item's own size, in a steady order. C_Container answers from it (Bagnon, Baganator, Syndicator,
-- the game's own bags read it); a change to the items (BAG_UPDATE) lays them out again.
local sim = require("sim")

local bags = {}

local BACKPACK_SLOTS = 16
local BAG_OFFSET = 30 -- CONTAINER_BAG_OFFSET: bag 1 is inventory slot 31
local NUM_BAGS = 4

local G, game
local layout, layoutKey

---The size of each container: the backpack's, then each equipped bag's
local function containerSizes()
    local sizes = { [0] = BACKPACK_SLOTS }
    local equipped = game.profile.bags or {}
    for bag = 1, NUM_BAGS do
        local itemId = tonumber(equipped[bag])
        local item = itemId and game.items and game.items[itemId]
        sizes[bag] = item and item.containerSlots or 0
    end
    return sizes
end

---The items laid out in the containers: [bag][slot] = { itemId, count }. Kept till the items or the bags change.
local function getLayout()
    local equipped = game.profile.bags or {}
    -- (a profile read back from its saved JSON keys its items by text: "4865" as well as 4865)
    local counts, ids = {}, {}
    for key, count in pairs(game.profile.items or {}) do
        local itemId, amount = tonumber(key), tonumber(count) or 0
        if itemId and amount > 0 then
            if not counts[itemId] then
                ids[#ids + 1] = itemId
            end
            counts[itemId] = (counts[itemId] or 0) + amount
        end
    end
    local items = counts
    table.sort(ids)
    local keyParts = {}
    for _, itemId in ipairs(ids) do
        keyParts[#keyParts + 1] = itemId .. "x" .. items[itemId]
    end
    for bag = 1, NUM_BAGS do
        keyParts[#keyParts + 1] = "b" .. tostring(equipped[bag])
    end
    local key = table.concat(keyParts, ",")
    if layout and key == layoutKey then
        return layout
    end
    local sizes = containerSizes()
    layout = { sizes = sizes }
    for bag = 0, NUM_BAGS do
        layout[bag] = {}
    end
    local bag, slot = 0, 1
    local function nextSlot()
        while bag <= NUM_BAGS and slot > sizes[bag] do
            bag, slot = bag + 1, 1
        end
        if bag > NUM_BAGS then
            return nil
        end
        local at = { bag, slot }
        slot = slot + 1
        return at
    end
    for _, itemId in ipairs(ids) do
        local item = game.items and game.items[itemId]
        local stackSize = math.max(1, item and item.stack or 1)
        local left = items[itemId]
        while left > 0 do
            local at = nextSlot()
            if not at then
                break
            end -- (full: the rest does not fit, as the client would refuse it)
            local count = math.min(left, stackSize)
            layout[at[1]][at[2]] = { itemId = itemId, count = count }
            left = left - count
        end
    end
    layoutKey = key
    return layout
end

local function slotOf(bag, slot)
    bag, slot = tonumber(bag), tonumber(slot)
    if not bag or not slot or bag < 0 or bag > NUM_BAGS then
        return nil
    end
    return getLayout()[bag][slot]
end

local function itemLink(itemId)
    local item = game.items and game.items[itemId]
    local name = item and item.name or ("Item " .. itemId)
    local colors = G.ITEM_QUALITY_COLORS and G.ITEM_QUALITY_COLORS[item and item.quality or 1]
    local hex = colors and colors.hex or "|cffffffff"
    return string.format("%s|Hitem:%d::::::::::::::::|h[%s]|h|r", hex, itemId, name)
end

---Whether a quest in the log asks for this item (the bags mark it, a quest item's border)
local function isQuestItem(itemId)
    for _, entry in ipairs(game.questLog or {}) do
        for _, objective in ipairs(entry.objectives or {}) do
            if objective.kind == "item" and objective.id == itemId then
                return true, entry.questId
            end
        end
    end
    return false
end

function bags.install(globals, theGame)
    G, game = globals, theGame
    local container = G.C_Container or {}
    G.C_Container = container
    -- The bags' search box: the text kept, the bags told to look again (they grey what does not match)
    local searchText = ""
    container.SetItemSearch = function(text)
        searchText = tostring(text or "")
        sim.fireEvent("INVENTORY_SEARCH_UPDATE")
    end
    container.GetItemSearch = function()
        return searchText
    end
    -- Items new in the bags (the glow on them): none the simulated character just looted
    G.C_NewItems = G.C_NewItems or {}
    G.C_NewItems.IsNewItem = G.C_NewItems.IsNewItem or function()
        return false
    end
    G.C_NewItems.RemoveNewItem = G.C_NewItems.RemoveNewItem or function() end
    G.C_NewItems.ClearAll = function() end
    container.GetContainerNumSlots = function(bag)
        bag = tonumber(bag)
        if not bag or bag < 0 or bag > NUM_BAGS then
            return 0
        end
        return getLayout().sizes[bag] or 0
    end
    container.GetContainerItemID = function(bag, slot)
        local held = slotOf(bag, slot)
        return held and held.itemId or nil
    end
    container.GetContainerItemLink = function(bag, slot)
        local held = slotOf(bag, slot)
        return held and itemLink(held.itemId) or nil
    end
    container.HasContainerItem = function(bag, slot)
        return slotOf(bag, slot) ~= nil
    end
    container.GetContainerItemInfo = function(bag, slot)
        local held = slotOf(bag, slot)
        if not held then
            return nil
        end
        local item = game.items and game.items[held.itemId] or {}
        return {
            iconFileID = item.icon or 134400,
            stackCount = held.count,
            isLocked = false,
            quality = item.quality or 1,
            isReadable = false,
            hasLoot = false,
            hyperlink = itemLink(held.itemId),
            isFiltered = false,
            hasNoValue = (item.sellPrice or 0) == 0,
            itemID = held.itemId,
            isBound = false,
            itemName = item.name or "",
        }
    end
    container.GetContainerItemQuestInfo = function(bag, slot)
        local held = slotOf(bag, slot)
        local isQuest, questId = false, nil
        if held then
            isQuest, questId = isQuestItem(held.itemId)
        end
        return { isQuestItem = isQuest, questID = nil, isActive = false, questIDForItem = questId }
    end
    container.GetContainerItemCooldown = function()
        return 0, 0, 1
    end
    container.GetContainerItemDurability = function()
        return nil
    end
    local function freeSlots(bag)
        local free = {}
        for slot = 1, container.GetContainerNumSlots(bag) do
            if not slotOf(bag, slot) then
                free[#free + 1] = slot
            end
        end
        return free
    end
    container.GetContainerFreeSlots = function(bag)
        return freeSlots(bag)
    end
    container.GetContainerNumFreeSlots = function(bag)
        return #freeSlots(bag), 0
    end
    container.CalculateTotalNumberOfFreeBagSlots = function()
        local total = 0
        for bag = 0, NUM_BAGS do
            total = total + #freeSlots(bag)
        end
        return total
    end
    -- A bag's place among the equipment slots (bag 1 is slot 31...; the backpack has none)
    container.ContainerIDToInventoryID = function(bag)
        bag = tonumber(bag)
        if not bag or bag < 1 then
            return nil
        end
        return BAG_OFFSET + bag
    end
    container.GetBagName = function(bag)
        bag = tonumber(bag)
        if bag == 0 then
            return G.BACKPACK_TOOLTIP or "Backpack"
        end
        local itemId = tonumber((game.profile.bags or {})[bag or -1])
        local item = itemId and game.items and game.items[itemId]
        return item and item.name or nil
    end
    container.PlayerHasHearthstone = function()
        return (game.profile.items or {})[6948] ~= nil and 6948 or nil
    end
    container.UseContainerItem = function(bag, slot)
        local held = slotOf(bag, slot)
        if held and game.useItem then
            game.useItem(held.itemId)
        end
    end
    container.PickupContainerItem = function() end
    container.SortBags = function()
        G.C_Timer.After(0, function()
            require("sim").fireEvent("BAG_UPDATE_DELAYED")
        end)
    end
end

return bags
