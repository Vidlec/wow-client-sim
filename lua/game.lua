-- The game's state for addons: the character, the quest log, the map. Driven from the page (accept a quest,
-- kill toward it, move on the map) and told to addons with the game's own events and APIs. Quest titles and
-- objectives come from QuestieDB when it is loaded; maps and areas from the game's DB2 tables (wago.tools).
local sim = require("sim")
local W = require("widgets")

local game = {}
local G = sim.G

game.profile = {
    name = "Simmy", realm = "Simland", level = 30, race = "Scourge", raceName = "Undead", raceId = 5, class = "MAGE",
    className = "Mage", classId = 8, faction = "Horde", sex = 2, money = 123456, xp = 1000, xpMax = 20000,
    uiMapId = 1421, x = 0.45, y = 0.45, facing = 0, isInInstance = false, instanceType = "none", instanceId = 0,
    groupSize = 0, professions = {}, spells = {}, reputations = {}, items = {},
}
game.questLog = {} -- { questId, title, level, objectives, isComplete, isFailed }
game.completed = {}
game.watched = {} -- [questId] = true
game.selectedQuestId = nil

local RACES = {
    Human = { 1, "Human", "Alliance" }, Orc = { 2, "Orc", "Horde" }, Dwarf = { 3, "Dwarf", "Alliance" }, NightElf = { 4, "Night Elf", "Alliance" },
    Scourge = { 5, "Undead", "Horde" }, Tauren = { 6, "Tauren", "Horde" }, Gnome = { 7, "Gnome", "Alliance" }, Troll = { 8, "Troll", "Horde" },
}
local CLASSES = { WARRIOR = { 1, "Warrior" }, PALADIN = { 2, "Paladin" }, HUNTER = { 3, "Hunter" }, ROGUE = { 4, "Rogue" }, PRIEST = { 5, "Priest" },
    SHAMAN = { 7, "Shaman" }, MAGE = { 8, "Mage" }, WARLOCK = { 9, "Warlock" }, DRUID = { 11, "Druid" } }
game.RACES, game.CLASSES = RACES, CLASSES

function game.setProfile(changes)
    local profile = game.profile
    local oldLevel = profile.level
    for key, value in pairs(changes or {}) do
        profile[key] = value
    end
    local race = RACES[profile.race]
    if race then
        profile.raceId, profile.raceName, profile.faction = race[1], race[2], race[3]
    end
    local class = CLASSES[profile.class]
    if class then
        profile.classId, profile.className = class[1], class[2]
    end
    -- Another class, or other actions: every action button reads its slot again (0: all of them), as the client
    -- tells the bars when a character's actions arrive
    if changes and (changes.class or changes.actions) and sim.fireEvent then
        sim.fireEvent("ACTIONBAR_SLOT_CHANGED", 0)
    end
    -- Another race or sex: the portraits are drawn again (the player frame's, the character button's)
    if changes and (changes.race or changes.sex) and sim.fireEvent then
        sim.fireEvent("UNIT_PORTRAIT_UPDATE", "player")
        sim.fireEvent("PORTRAITS_UPDATED")
    end
    -- Another level: the unit frames show it (the player frame's number). Not a level gained in play ("real" false)
    if changes and changes.level and changes.level ~= oldLevel and sim.fireEvent then
        sim.fireEvent("PLAYER_LEVEL_CHANGED", oldLevel, profile.level, false)
        sim.fireEvent("UNIT_LEVEL", "player")
    end
    sim.touch()
end

-- DB2 tables (CSV from wago.tools, read by the host from the cache)
local function parseCsvLine(line, limit)
    local fields, position, length = {}, 1, #line
    limit = limit or math.huge
    -- A line without quotes: split at the commas, up to the last field wanted
    if not line:find('"', 1, true) then
        local find, sub = string.find, string.sub
        local count = 0
        while count < limit do
            local comma = find(line, ",", position, true)
            count = count + 1
            if not comma then fields[count] = sub(line, position); break end
            fields[count] = sub(line, position, comma - 1)
            position = comma + 1
        end
        return fields
    end
    while position <= length + 1 and #fields < limit do
        if line:sub(position, position) == '"' then
            local parts, index = {}, position + 1
            while true do
                local quote = line:find('"', index, true)
                if not quote then parts[#parts + 1] = line:sub(index); position = length + 2; break end
                parts[#parts + 1] = line:sub(index, quote - 1)
                if line:sub(quote + 1, quote + 1) == '"' then
                    parts[#parts + 1] = '"'
                    index = quote + 2
                else
                    position = quote + 2
                    break
                end
            end
            fields[#fields + 1] = table.concat(parts)
        else
            local comma = line:find(",", position, true) or (length + 1)
            fields[#fields + 1] = line:sub(position, comma - 1)
            position = comma + 1
        end
    end
    return fields
end

---@param columns string[]? Only these columns, for a wide table (ItemSparse has a hundred)
function game.readTable(path, columns)
    if not path then return nil end
    -- Read once and kept between runs (bootcache): the rows of these columns of this file as it is now
    local name = "db2-" .. (path:match("([^/\\]+)%.csv$") or "table") .. (columns and ("-" .. table.concat(columns, "-")) or "")
    return require("bootcache").rememberFile(name, path, function()
        local file = io.open(path, "rb")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        return content
    end, function() return game.parseTable(path, columns) end)
end

---Reads a DB2 table's CSV: a row per line, by column name.
function game.parseTable(path, columns)
    local file = path and io.open(path, "r")
    if not file then
        return nil
    end
    local header, rows, wanted, pending, limit = nil, {}, nil, nil, nil
    for line in file:lines() do
        if line:byte(-1) == 13 then line = line:sub(1, -2) end
        -- A quoted field may hold line breaks: keep reading until its quotes close
        if pending then line = pending .. "\n" .. line; pending = nil end
        local quotes = 0
        if line:find('"', 1, true) then quotes = select(2, line:gsub('"', "")) end
        if quotes % 2 == 1 then
            pending = line
        elseif not header then
            header = parseCsvLine(line)
            if columns then
                wanted, limit = {}, 0
                for index, name in ipairs(header) do
                    for _, column in ipairs(columns) do
                        if name == column then wanted[#wanted + 1] = index; limit = math.max(limit, index) end
                    end
                end
            end
        elseif line ~= "" then
            local fields, row = parseCsvLine(line, limit), {}
            if wanted then
                for _, index in ipairs(wanted) do row[header[index]] = fields[index] end
            else
                for index, name in ipairs(header) do row[name] = fields[index] end
            end
            rows[#rows + 1] = row
        end
    end
    file:close()
    return rows
end

game.maps, game.mapChildren, game.assignments, game.areas = {}, {}, {}, {}

function game.loadData(readTable)
    -- Item classes and their subclasses by number, as the client names them (C_Item.GetItemClassInfo)
    game.itemClasses, game.itemSubClasses = {}, {}
    for _, row in ipairs(readTable("ItemClass") or {}) do
        local classId = tonumber(row.ClassID)
        if classId then game.itemClasses[classId] = row.ClassName_lang end
    end
    for _, row in ipairs(readTable("ItemSubClass") or {}) do
        local classId, subClassId = tonumber(row.ClassID), tonumber(row.SubClassID)
        if classId and subClassId then
            game.itemSubClasses[classId] = game.itemSubClasses[classId] or {}
            -- The long name where there is one ("One-Handed Axes", not "Axe"), as the client gives it
            local name = row.VerboseName_lang
            if name == nil or name == "" then name = row.DisplayName_lang end
            game.itemSubClasses[classId][subClassId] = name
        end
    end
    for _, row in ipairs(readTable("UiMap") or {}) do
        local id = tonumber(row.ID)
        if id then
            game.maps[id] = { mapID = id, name = row.Name_lang, parentMapID = tonumber(row.ParentUiMapID) or 0, mapType = tonumber(row.Type) or 3, flags = tonumber(row.Flags) or 0 }
            local parent = tonumber(row.ParentUiMapID) or 0
            game.mapChildren[parent] = game.mapChildren[parent] or {}
            table.insert(game.mapChildren[parent], id)
        end
    end
    for _, row in ipairs(readTable("UiMapAssignment") or {}) do
        local id = tonumber(row.UiMapID)
        if id then
            local function number(...) for _, key in ipairs({ ... }) do if row[key] then return tonumber(row[key]) end end end
            local assignment = {
                uiMin = { number("UiMin_0", "UiMin[0]"), number("UiMin_1", "UiMin[1]") },
                uiMax = { number("UiMax_0", "UiMax[0]"), number("UiMax_1", "UiMax[1]") },
                region = { number("Region_0", "Region[0]"), number("Region_1", "Region[1]"), number("Region_2", "Region[2]"),
                    number("Region_3", "Region[3]"), number("Region_4", "Region[4]"), number("Region_5", "Region[5]") },
                mapId = tonumber(row.MapID), orderIndex = tonumber(row.OrderIndex) or 0, areaId = tonumber(row.AreaID),
            }
            if assignment.uiMin[1] and assignment.region[1] then
                game.assignments[id] = game.assignments[id] or {}
                table.insert(game.assignments[id], assignment)
            end
        end
    end
    -- Items: their icon from Item, their name, quality and levels from ItemSparse
    game.items = {}
    for _, row in ipairs(readTable("Item", { "ID", "ClassID", "SubclassID", "IconFileDataID", "InventoryType" }) or {}) do
        local id = tonumber(row.ID)
        if id then
            game.items[id] = { icon = tonumber(row.IconFileDataID), classId = tonumber(row.ClassID) or 15, subclassId = tonumber(row.SubclassID) or 0,
                inventoryType = tonumber(row.InventoryType) or 0 }
        end
    end
    for _, row in ipairs(readTable("ItemSparse", { "ID", "Display_lang", "OverallQualityID", "ItemLevel", "RequiredLevel", "SellPrice", "Stackable" }) or {}) do
        local id = tonumber(row.ID)
        local item = id and game.items[id]
        if item then
            item.name, item.quality = row.Display_lang, tonumber(row.OverallQualityID) or 1
            item.level, item.requiredLevel = tonumber(row.ItemLevel) or 1, tonumber(row.RequiredLevel) or 0
            item.sellPrice, item.stack = tonumber(row.SellPrice) or 0, tonumber(row.Stackable) or 1
        end
    end
    -- Items that can be used (an on-use effect): what the game offers as a quest's item button
    local effects = {}
    for _, row in ipairs(readTable("ItemEffect", { "ID", "TriggerType", "Charges", "CoolDownMSec", "SpellID" }) or {}) do
        effects[tonumber(row.ID) or 0] = { trigger = tonumber(row.TriggerType) or 0, charges = tonumber(row.Charges) or 0,
            cooldown = (tonumber(row.CoolDownMSec) or 0) / 1000, spellId = tonumber(row.SpellID) or 0 }
    end
    for _, row in ipairs(readTable("ItemXItemEffect", { "ItemEffectID", "ItemID" }) or {}) do
        local item, effect = game.items[tonumber(row.ItemID) or 0], effects[tonumber(row.ItemEffectID) or 0]
        if item and effect and effect.trigger == 0 then item.useEffect = effect end -- 0: on use
    end
    -- Quest categories (cooking, a class, a holiday): the quest log heads such quests with these names
    game.questSorts = {}
    for _, row in ipairs(readTable("QuestSort") or {}) do
        local id = tonumber(row.ID)
        if id then game.questSorts[id] = row.SortName_lang end
    end
    for _, row in ipairs(readTable("AreaTable") or {}) do
        local id = tonumber(row.ID)
        if id then
            game.areas[id] = row.AreaName_lang or row.ZoneName
        end
    end
end

-- Positions: map coordinates to the world and back, through the map's assignment to a world region
local function getAssignment(uiMapId)
    local list = game.assignments[uiMapId]
    if not list then return nil end
    table.sort(list, function(first, second) return first.orderIndex < second.orderIndex end)
    for _, assignment in ipairs(list) do
        if assignment.uiMin[1] == 0 and assignment.uiMax[1] == 1 then
            return assignment
        end
    end
    return list[1]
end

function game.mapToWorld(uiMapId, x, y)
    local assignment = getAssignment(uiMapId)
    if not assignment then return nil end
    local region, uiMin, uiMax = assignment.region, assignment.uiMin, assignment.uiMax
    local u = (x - uiMin[1]) / math.max(uiMax[1] - uiMin[1], 1e-9)
    local v = (y - uiMin[2]) / math.max(uiMax[2] - uiMin[2], 1e-9)
    local worldX = region[4] - v * (region[4] - region[1]) -- north
    local worldY = region[5] - u * (region[5] - region[2]) -- west
    return assignment.mapId, worldX, worldY
end

-- A map can show parts of several continents (the world map: Kalimdor on its left, the Eastern Kingdoms on its right),
-- one assignment each: the one of the continent asked for, holding the place where there are several
local function getAssignmentFor(uiMapId, continentId, worldX, worldY)
    local list = game.assignments[uiMapId]
    if not list or not continentId then return getAssignment(uiMapId) end
    local first
    for _, assignment in ipairs(list) do
        if assignment.mapId == continentId then
            local region = assignment.region
            if worldX >= region[1] and worldX <= region[4] and worldY >= region[2] and worldY <= region[5] then return assignment end
            first = first or assignment
        end
    end
    return first
end

function game.worldToMap(uiMapId, continentId, worldX, worldY, assignment)
    assignment = assignment or getAssignmentFor(uiMapId, continentId, worldX, worldY)
    if not assignment or (continentId and assignment.mapId ~= continentId) then return nil end
    local region, uiMin, uiMax = assignment.region, assignment.uiMin, assignment.uiMax
    local v = (region[4] - worldX) / math.max(region[4] - region[1], 1e-9)
    local u = (region[5] - worldY) / math.max(region[5] - region[2], 1e-9)
    return uiMin[1] + u * (uiMax[1] - uiMin[1]), uiMin[2] + v * (uiMax[2] - uiMin[2])
end

-- Where one map lies on another, { minX, maxX, minY, maxY }: its corners through the world's coordinates; nil when
-- either is not placed in the world
function game.getMapRectOnMap(uiMapId, topMapId)
    local continentId, leftX, topY = game.mapToWorld(uiMapId, 0, 0)
    local otherContinentId, rightX, bottomY = game.mapToWorld(uiMapId, 1, 1)
    if not continentId or continentId ~= otherContinentId then return nil end
    -- (the middle picks the part of the top map: a continent's corners can lie outside its part of the world map)
    local middleX, middleY = (leftX + rightX) / 2, (topY + bottomY) / 2
    local part = getAssignmentFor(topMapId, continentId, middleX, middleY)
    local minX, minY = game.worldToMap(topMapId, continentId, leftX, topY, part)
    local maxX, maxY = game.worldToMap(topMapId, continentId, rightX, bottomY, part)
    if not minX or not maxX then return nil end
    return { math.min(minX, maxX), math.max(minX, maxX), math.min(minY, maxY), math.max(minY, maxY) }
end

-- The highlight art of each map (the server reads it from the game's files: server.build_map_highlights), and how
-- much of the texture the map's rectangle takes: the art keeps the map's own shape (a 3:2 map in a square texture
-- fills its top two thirds), its width the texture's
game.mapHighlights = {}
local function getHighlight(uiMapId)
    local highlight = game.mapHighlights[tostring(uiMapId)]
    if highlight and not highlight.texPercentX then
        local layer = G.C_Map.GetMapArtLayers(uiMapId)[1]
        local mapShape = layer and layer.layerWidth > 0 and layer.layerHeight / layer.layerWidth or (2 / 3)
        highlight.texPercentX = 1
        highlight.texPercentY = math.min(1, mapShape * highlight.width / highlight.height)
    end
    return highlight
end

---@return number? childId, table? rect, table? highlight The child map whose shape holds a place on a map, the smallest
function game.getChildMapAt(uiMapId, x, y)
    if not (uiMapId and x and y) then return nil end
    local bestId, bestRect, bestHighlight, bestArea
    for _, childId in ipairs(game.mapChildren[uiMapId] or {}) do
        local highlight = getHighlight(childId)
        local rect = highlight and game.getMapRectOnMap(childId, uiMapId)
        if rect and x >= rect[1] and x <= rect[2] and y >= rect[3] and y <= rect[4] then
            local u = (x - rect[1]) / math.max(rect[2] - rect[1], 1e-9) * highlight.texPercentX
            local v = (y - rect[3]) / math.max(rect[4] - rect[3], 1e-9) * highlight.texPercentY
            local column = math.min(highlight.columns - 1, math.floor(u * highlight.columns))
            local row = math.min(highlight.rows - 1, math.floor(v * highlight.rows))
            local index = row * highlight.columns + column + 1
            if highlight.mask:sub(index, index) == "1" then
                local area = (rect[2] - rect[1]) * (rect[4] - rect[3])
                if not bestArea or area < bestArea then
                    bestId, bestRect, bestHighlight, bestArea = childId, rect, highlight, area
                end
            end
        end
    end
    return bestId, bestRect, bestHighlight
end

-- Quests, from QuestieDB when it is there
local function questField(questId, field)
    local database = G.LibQuestieDB
    if type(database) == "table" and database.Quest and database.Quest.Get then
        local isRead, value = pcall(database.Quest.Get, questId, field)
        if isRead then return value end
    end
end

local function entityName(kind, id)
    local database = G.LibQuestieDB
    if type(database) == "table" and database[kind] and database[kind].Get then
        local isRead, value = pcall(database[kind].Get, id, "name")
        if isRead then return value end
    end
end

---The objectives a quest asks for, as the game lists them: from the quest database, with counts from the
---quest's own text when it names one ("kill 6 Rockjaw Troggs"), else 1.
function game.composeObjectives(questId)
    local objectives = {}
    local data = questField(questId, "objectives") or {}
    local text = table.concat(questField(questId, "objectivesText") or {}, " ")
    local function countFor(name)
        -- "kill 6 Rockjaw Troggs", "bring 10 pieces of Turtle Meat": a number, a few words at most, the name
        -- The words between are few (not "10 pieces of Turtle Meat and some Soothing Spices", which counts the meat)
        local escaped = name and name:gsub("%p", "%%%0")
        -- The text may give the name in the plural: "20 Hearts of Zeal" for Heart of Zeal, "8 Voodoo Trolls"
        local plural = name and table.concat((function()
            local words = {}
            for word in name:gmatch("%S+") do words[#words + 1] = word:gsub("%p", "%%%0") .. "e?s?" end
            return words
        end)(), " ")
        for _, pattern in ipairs({ escaped, plural }) do
            for wordCount = 0, 3 do
                local count = pattern and text:match("(%d+) " .. string.rep("%a+ ", wordCount) .. pattern)
                if count then return tonumber(count) end
            end
        end
        return 1
    end
    for _, creature in ipairs(data[1] or {}) do
        local name = creature[2] or entityName("Npc", creature[1]) or ("Creature " .. creature[1])
        objectives[#objectives + 1] = { kind = "monster", name = name, required = countFor(name), fulfilled = 0, id = creature[1] }
    end
    for _, object in ipairs(data[2] or {}) do
        local name = object[2] or entityName("Object", object[1]) or ("Object " .. object[1])
        objectives[#objectives + 1] = { kind = "object", name = name, required = countFor(name), fulfilled = 0, id = object[1] }
    end
    for _, item in ipairs(data[3] or {}) do
        local name = item[2] or entityName("Item", item[1]) or ("Item " .. item[1])
        objectives[#objectives + 1] = { kind = "item", name = name, required = countFor(name), fulfilled = 0, id = item[1] }
    end
    for _, credit in ipairs(data[5] or {}) do
        local name = credit[3] or credit[2] or "Objective"
        objectives[#objectives + 1] = { kind = "monster", name = tostring(name), required = 1, fulfilled = 0, creditIds = credit[1] }
    end
    local trigger = questField(questId, "triggerEnd")
    if type(trigger) == "table" and trigger[1] then
        objectives[#objectives + 1] = { kind = "event", name = tostring(trigger[1]), required = 1, fulfilled = 0 }
    end
    return objectives
end

---An objective's line as the game words it, from its own strings (in the client's language):
---QUEST_MONSTERS_KILLED "%2$d/%3$d %1$s slain", QUEST_ITEMS_NEEDED and QUEST_OBJECTS_FOUND "%2$d/%3$d %1$s".
local function objectiveText(objective)
    if objective.kind == "event" then
        return objective.name
    end
    local pattern = objective.kind == "monster" and G.QUEST_MONSTERS_KILLED
        or objective.kind == "object" and G.QUEST_OBJECTS_FOUND or G.QUEST_ITEMS_NEEDED
    if type(pattern) ~= "string" then pattern = objective.kind == "monster" and "%2$d/%3$d %1$s slain" or "%2$d/%3$d %1$s" end
    return string.format(pattern, objective.name, objective.fulfilled, objective.required)
end
game.objectiveText = objectiveText

local function findEntry(questId)
    for index, entry in ipairs(game.questLog) do
        if entry.questId == questId then return entry, index end
    end
end
game.findEntry = findEntry

local function isEntryComplete(entry)
    for _, objective in ipairs(entry.objectives) do
        if objective.fulfilled < objective.required then return false end
    end
    return true
end

local function fireLogChanged(questId)
    sim.fireEvent("QUEST_LOG_UPDATE")
    sim.fireEvent("UNIT_QUEST_LOG_CHANGED", "player")
    if questId then
        sim.fireEvent("QUEST_WATCH_UPDATE", questId)
    end
end

function game.acceptQuest(questId, objectives)
    if findEntry(questId) then return false, "already in the log" end
    local entry = {
        questId = questId, title = questField(questId, "name") or ("Quest " .. questId),
        level = questField(questId, "questLevel") or game.profile.level, objectives = objectives or game.composeObjectives(questId),
        zoneOrSort = questField(questId, "zoneOrSort") or 0, acceptedAt = sim.now,
    }
    entry.isComplete = #entry.objectives > 0 and isEntryComplete(entry) or #entry.objectives == 0
    table.insert(game.questLog, entry)
    if (G.GetCVar and G.GetCVar("autoQuestWatch") == "1") then
        game.watched[questId] = true
    end
    sim.fireEvent("QUEST_ACCEPTED", questId)
    if game.watched[questId] then
        sim.fireEvent("QUEST_WATCH_LIST_CHANGED", questId, true)
    end
    fireLogChanged()
    return true
end

function game.progressQuest(questId, objectiveIndex, amount)
    local entry = findEntry(questId)
    if not entry then return false, "not in the log" end
    local objective = entry.objectives[objectiveIndex or 1]
    if not objective then return false, "no such objective" end
    objective.fulfilled = math.max(0, math.min(objective.required, objective.fulfilled + (amount or 1)))
    local wasComplete = entry.isComplete
    entry.isComplete = isEntryComplete(entry)
    sim.fireEvent("UI_INFO_MESSAGE", 0, objectiveText(objective))
    fireLogChanged(questId)
    if entry.isComplete and not wasComplete then
        sim.fireEvent("QUEST_COMPLETE")
    end
    return true
end

function game.completeQuest(questId)
    local entry = findEntry(questId)
    if not entry then return false, "not in the log" end
    for _, objective in ipairs(entry.objectives) do objective.fulfilled = objective.required end
    entry.isComplete = true
    fireLogChanged(questId)
    return true
end

function game.turnInQuest(questId)
    local entry, index = findEntry(questId)
    if not entry then return false, "not in the log" end
    table.remove(game.questLog, index)
    game.completed[questId] = true
    game.watched[questId] = nil
    local xp, money = 1000, 500
    if G.GetQuestReward then
        -- the game calls this as the reward is taken; addons hook it
    end
    sim.fireEvent("QUEST_TURNED_IN", questId, xp, money)
    sim.fireEvent("QUEST_REMOVED", questId)
    fireLogChanged()
    return true
end

function game.abandonQuest(questId)
    local entry, index = findEntry(questId)
    if not entry then return false, "not in the log" end
    table.remove(game.questLog, index)
    game.watched[questId] = nil
    sim.fireEvent("QUEST_REMOVED", questId)
    fireLogChanged()
    return true
end

function game.setPosition(uiMapId, x, y)
    local profile = game.profile
    local zoneChanged = uiMapId and uiMapId ~= profile.uiMapId
    profile.uiMapId, profile.x, profile.y = uiMapId or profile.uiMapId, x or profile.x, y or profile.y
    sim.touch()
    if zoneChanged then
        sim.fireEvent("ZONE_CHANGED_NEW_AREA")
        sim.fireEvent("ZONE_CHANGED")
    end
end

---@return number? continentId, number? north, number? west The player's place in world yards; nil inside instances
function game.getPlayerWorldPosition()
    local profile = game.profile
    if profile.isInInstance then return nil end
    return game.mapToWorld(profile.uiMapId, profile.x, profile.y)
end

---@return number? uiMapId, number? x, number? y The zone a world point lies in: the current one while it is inside
---it, else the smallest zone on that continent that holds it
function game.findZoneAt(continentId, north, west, preferredUiMapId)
    local x, y = game.worldToMap(preferredUiMapId, continentId, north, west)
    if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return preferredUiMapId, x, y end
    local best, bestX, bestY, bestArea
    for uiMapId, map in pairs(game.maps) do
        if map.mapType == 3 then
            local assignment = getAssignment(uiMapId)
            if assignment and assignment.mapId == continentId then
                local mapX, mapY = game.worldToMap(uiMapId, continentId, north, west)
                if mapX and mapX >= 0 and mapX <= 1 and mapY >= 0 and mapY <= 1 then
                    local region = assignment.region
                    local area = math.abs((region[4] - region[1]) * (region[5] - region[2]))
                    if not bestArea or area < bestArea then best, bestX, bestY, bestArea = uiMapId, mapX, mapY, area end
                end
            end
        end
    end
    return best, bestX, bestY
end

---Walks the player: forward (negative: back) and sideways (positive: right) in yards, as the facing points.
---Facing is the game's: radians, 0 north, turning left adds.
---@return boolean isMoved
function game.walk(forward, right)
    local continentId, north, west = game.getPlayerWorldPosition()
    if not continentId then return false end
    local facing = game.profile.facing or 0
    -- Ahead is the facing's direction; right is a quarter turn clockwise from it (facing north, right is east)
    north = north + math.cos(facing) * (forward or 0) + math.sin(facing) * (right or 0)
    west = west + math.sin(facing) * (forward or 0) - math.cos(facing) * (right or 0)
    local uiMapId, x, y = game.findZoneAt(continentId, north, west, game.profile.uiMapId)
    if not uiMapId then return false end
    game.setPosition(uiMapId, x, y)
    return true
end

---Turns the player by radians: positive turns left, as the game's facing grows.
function game.turn(radians)
    game.profile.facing = ((game.profile.facing or 0) + radians) % (2 * math.pi)
    sim.touch()
end

-- Searching the quest database, as the page's finders do
local function getDatabase(kind)
    local database = G.LibQuestieDB
    return type(database) == "table" and database[kind] or nil
end

local nameLists = {}
---@return { id: number, name: string, lower: string }[] entries Every quest's or creature's name, read once
local function getNames(kind)
    if nameLists[kind] then return nameLists[kind] end
    local database, list = getDatabase(kind), {}
    if database and database.GetAllIds then
        for _, id in ipairs(database.GetAllIds() or {}) do
            local isRead, name = pcall(database.Get, id, "name")
            if isRead and type(name) == "string" then list[#list + 1] = { id = id, name = name, lower = name:lower() } end
        end
    end
    nameLists[kind] = list
    return list
end

local function find(kind, text, limit)
    text = tostring(text or ""):lower():match("^%s*(.-)%s*$")
    local results, wantedId = {}, tonumber(text)
    if text == "" then return results end
    for _, entry in ipairs(getNames(kind)) do
        if entry.id == wantedId or (not wantedId and entry.lower:find(text, 1, true)) then
            results[#results + 1] = entry
            if #results >= (limit or 40) then break end
        end
    end
    return results
end

function game.findQuests(text, limit)
    local results = {}
    for _, entry in ipairs(find("Quest", text, limit)) do
        local sort = questField(entry.id, "zoneOrSort") or 0
        results[#results + 1] = { id = entry.id, name = entry.name, level = questField(entry.id, "questLevel") or 0,
            requiredLevel = questField(entry.id, "requiredLevel") or 0, zone = sort > 0 and (game.areas[sort] or ("zone " .. sort)) or "",
            isDone = game.completed[entry.id] == true, isInLog = findEntry(entry.id) ~= nil }
    end
    return results
end

function game.findNpcs(text, limit)
    local results, npcs = {}, getDatabase("Npc")
    for _, entry in ipairs(find("Npc", text, limit)) do
        local starts = npcs and select(2, pcall(npcs.Get, entry.id, "questStarts")) or nil
        local minLevel = npcs and select(2, pcall(npcs.Get, entry.id, "minLevel")) or nil
        results[#results + 1] = { id = entry.id, name = entry.name, level = type(minLevel) == "number" and minLevel or nil,
            questCount = type(starts) == "table" and #starts or 0 }
    end
    return results
end

---Who to kill or what to open for each objective in the log: the creatures it names, the creatures and objects
---that drop the item it asks for.
function game.getObjectiveSources()
    local items, npcs, objects = getDatabase("Item"), getDatabase("Npc"), getDatabase("Object")
    local function getField(database, id, field)
        if not database then return nil end
        local isRead, value = pcall(database.Get, id, field)
        return isRead and value or nil
    end
    local result = {}
    for _, entry in ipairs(game.questLog) do
        local objectives = {}
        for index, objective in ipairs(entry.objectives) do
            local sources = {}
            if objective.kind == "monster" then
                for _, npcId in ipairs(objective.creditIds or (objective.id and { objective.id }) or {}) do
                    sources[#sources + 1] = { kind = "npc", id = npcId, name = getField(npcs, npcId, "name") or ("Creature " .. npcId) }
                end
            elseif objective.kind == "item" and objective.id then
                for _, npcId in ipairs(getField(items, objective.id, "npcDrops") or {}) do
                    if #sources < 8 then sources[#sources + 1] = { kind = "npc", id = npcId, name = getField(npcs, npcId, "name") or ("Creature " .. npcId) } end
                end
                for _, objectId in ipairs(getField(items, objective.id, "objectDrops") or {}) do
                    if #sources < 12 then sources[#sources + 1] = { kind = "object", id = objectId, name = getField(objects, objectId, "name") or ("Object " .. objectId) } end
                end
            end
            objectives[index] = { text = objectiveText(objective), sources = sources, itemId = objective.kind == "item" and objective.id or nil }
        end
        result[#result + 1] = { questId = entry.questId, objectives = objectives }
    end
    return result
end

-- Kills and loot, as the game reports them

local function creatureGuid(npcId) return string.format("Creature-0-1-0-1-%d-0000%06X", npcId, math.random(0, 0xFFFFFF)) end

local function getItemName(itemId)
    if game.items and game.items[itemId] and game.items[itemId].name then return game.items[itemId].name end
    local items = getDatabase("Item")
    if not items then return "Item " .. itemId end
    local isRead, name = pcall(items.Get, itemId, "name") -- not "items and pcall(...)": that keeps one result
    return isRead and name or ("Item " .. itemId)
end

---An item comes into the bags: the loot message, the bags change, and objectives asking for it move on.
function game.loot(itemId, count)
    itemId, count = tonumber(itemId), count or 1
    if not itemId then return false, "no item" end
    local profile = game.profile
    profile.items[itemId] = (profile.items[itemId] or 0) + count
    local name = getItemName(itemId)
    sim.fireEvent("CHAT_MSG_LOOT", string.format("You receive loot: |cffffffff|Hitem:%d::::::::|h[%s]|h|r%s.", itemId, name, count > 1 and ("x" .. count) or ""),
        "", "", "", game.profile.name)
    sim.fireEvent("BAG_UPDATE", 0)
    sim.fireEvent("BAG_UPDATE_DELAYED")
    for _, entry in ipairs(game.questLog) do
        for index, objective in ipairs(entry.objectives) do
            if objective.kind == "item" and objective.id == itemId and objective.fulfilled < objective.required then
                game.progressQuest(entry.questId, index, count)
            end
        end
    end
    return true
end

---A creature dies by the player's hand: the combat log's kill, objectives naming it move on, and with
---shouldLoot, every quest item it drops for the log comes along.
---@param isTappedByOthers boolean? Someone outside the group tapped it first: it dies, but is not the player's
---@param options { loot: boolean?, isTappedByOthers: boolean?, via: string?, dropChance: number? }|boolean? How the
---fight went. via: "target" (the default), "nameplate" (fought as one of the nameplates, not targeted), or
---"unseen" (killed without ever being a unit the player sees, as with area damage and nameplates off).
---dropChance: how likely each quest item it can drop drops (1 by default: always). The old form, (npcId,
---shouldLoot, isTappedByOthers), still works.
---Points at a living creature, as targeting it or hovering it in the world does: it becomes the "target" (with
---PLAYER_TARGET_CHANGED) or the "mouseover" (with UPDATE_MOUSEOVER_UNIT and its tooltip, as the game shows).
---@param unit "target"|"mouseover"
function game.pointAt(npcId, unit)
    npcId = tonumber(npcId)
    if not npcId then return false, "no creature" end
    local npcs = getDatabase("Npc")
    local isRead, name = false, nil
    if npcs then isRead, name = pcall(npcs.Get, npcId, "name") end
    game.fighting = { guid = creatureGuid(npcId), npcId = npcId, name = isRead and name or ("Creature " .. npcId), isDead = false, unit = unit or "target" }
    if game.fighting.unit == "mouseover" then
        sim.fireEvent("UPDATE_MOUSEOVER_UNIT")
        if G.GameTooltip and G.GameTooltip.SetUnit then
            G.GameTooltip:SetOwner(G.UIParent, "ANCHOR_CURSOR")
            G.GameTooltip:SetUnit("mouseover")
        end
    else
        sim.fireEvent("PLAYER_TARGET_CHANGED")
    end
    sim.touch()
    return true
end

-- Nameplates, as the client keeps them: a base frame for each plate (NamePlate1...), made the first time one is needed
-- and announced with NAME_PLATE_CREATED, then given to a unit (NAME_PLATE_UNIT_ADDED) and taken back. The game's own
-- nameplate driver dresses the base frames; addons find them with C_NamePlate.GetNamePlateForUnit.
local namePlateFrames, namePlatesByUnit = {}, {}

local function takeNamePlate(unit)
    local W = require("widgets")
    for _, frame in ipairs(namePlateFrames) do
        if not frame.namePlateUnitToken then return frame end
    end
    local frame = W.createFrame("NamePlate", "NamePlate" .. (#namePlateFrames + 1), sim.G.WorldFrame)
    frame:SetSize(110, 45)
    frame:SetPoint("CENTER", sim.G.WorldFrame, "CENTER", 0, 120 + 50 * #namePlateFrames)
    frame:Hide()
    namePlateFrames[#namePlateFrames + 1] = frame
    sim.fireEvent("NAME_PLATE_CREATED", frame)
    return frame
end

---A unit comes into nameplate range: its plate, then NAME_PLATE_UNIT_ADDED.
function game.addNamePlate(unit)
    if namePlatesByUnit[unit] then return namePlatesByUnit[unit] end
    local frame = takeNamePlate(unit)
    frame.namePlateUnitToken = unit
    namePlatesByUnit[unit] = frame
    frame:Show()
    sim.fireEvent("NAME_PLATE_UNIT_ADDED", unit)
    return frame
end

---A unit leaves: NAME_PLATE_UNIT_REMOVED while its plate still has it, then the plate is free again.
function game.removeNamePlate(unit)
    local frame = namePlatesByUnit[unit]
    if not frame then return end
    sim.fireEvent("NAME_PLATE_UNIT_REMOVED", unit)
    namePlatesByUnit[unit] = nil
    frame.namePlateUnitToken = nil
    frame:Hide()
end

function game.kill(npcId, options, isTappedByOthers)
    if type(options) ~= "table" then options = { loot = options, isTappedByOthers = isTappedByOthers } end
    npcId = tonumber(npcId)
    if not npcId then return false, "no creature" end
    local npcs = getDatabase("Npc")
    local isRead, name = false, nil
    if npcs then isRead, name = pcall(npcs.Get, npcId, "name") end
    name = isRead and name or ("Creature " .. npcId)
    local guid = creatureGuid(npcId)
    local via = options.via or "target"
    -- What an addon sees of a fight now that the combat log is secure only: the creature as a unit (the target,
    -- or a nameplate), in combat and tapped by the player (or by others), its health falling, then the game
    -- saying it died
    game.fighting = { guid = guid, npcId = npcId, name = name, isDead = false, isTappedByOthers = options.isTappedByOthers == true,
        unit = via == "nameplate" and "nameplate1" or via == "target" and "target" or nil }
    local unit = game.fighting.unit
    if unit == "target" then
        sim.fireEvent("PLAYER_TARGET_CHANGED")
    elseif unit then
        game.addNamePlate(unit)
    end
    if unit then sim.fireEvent("UNIT_HEALTH", unit) end
    game.fighting.isDead = true
    if unit then sim.fireEvent("UNIT_HEALTH", unit) end
    sim.fireEvent("UNIT_DIED", sim.hide(guid, "identity"))
    if unit and unit ~= "target" then
        game.removeNamePlate(unit)
        game.fighting.unit = nil
    end
    if options.isTappedByOthers then return true end -- no credit and no loot: someone else's kill
    game.creditKill(npcId)
    if options.loot ~= false then
        game.rollQuestDrops(npcId, options.dropChance, function(itemId) game.loot(itemId, 1) end)
    end
    return true
end

---The player's kill of a creature counts: every objective naming it (or crediting it) moves on by one.
function game.creditKill(npcId)
    for _, entry in ipairs(game.questLog) do
        for index, objective in ipairs(entry.objectives) do
            local isNamed = objective.kind == "monster" and objective.id == npcId
            for _, creditId in ipairs(objective.creditIds or {}) do
                isNamed = isNamed or creditId == npcId
            end
            if isNamed and objective.fulfilled < objective.required then
                game.progressQuest(entry.questId, index, 1)
            end
        end
    end
end

---The quest items a creature drops for the log, each at the chance given (1: always), rolled from the scenario's
---fixed seed: onDrop(itemId) for each that drops (game.kill puts it in the bags, a fight's corpse in its loot).
function game.rollQuestDrops(npcId, dropChance, onDrop)
    local items = getDatabase("Item")
    if not items then return end
    for _, entry in ipairs(game.questLog) do
        for _, objective in ipairs(entry.objectives) do
            if objective.kind == "item" and objective.id and objective.fulfilled < objective.required then
                local isDropRead, drops = pcall(items.Get, objective.id, "npcDrops")
                for _, dropperId in ipairs(isDropRead and drops or {}) do
                    if dropperId == npcId then
                        if game.random() < (dropChance or 1) then onDrop(objective.id) end
                        break
                    end
                end
            end
        end
    end
end

---Sets the state a recording holds at one moment (AddonSimRecorder), quietly: level, place, the quest log's counts,
---the creature targeted. The recorded event is fired afterwards by the replay, so addons see it as in the game.
function game.applyRecordedState(entry)
    local profile = game.profile
    if entry.level then profile.level = entry.level end
    if entry.position then
        profile.uiMapId, profile.x, profile.y = entry.position.uiMapId, entry.position.x, entry.position.y
        if entry.position.facing then profile.facing = entry.position.facing end
    end
    if entry.questLog then
        local byQuestId = {}
        for _, recorded in ipairs(entry.questLog) do byQuestId[recorded.questId] = recorded end
        -- Quests that left the log, gone; quests that came in, added; every count as recorded
        for index = #game.questLog, 1, -1 do
            if not byQuestId[game.questLog[index].questId] then table.remove(game.questLog, index) end
        end
        for _, recorded in ipairs(entry.questLog) do
            local logEntry = findEntry(recorded.questId)
            if not logEntry then
                logEntry = { questId = recorded.questId, title = questField(recorded.questId, "name") or ("Quest " .. recorded.questId),
                    level = questField(recorded.questId, "questLevel") or profile.level, objectives = game.composeObjectives(recorded.questId),
                    zoneOrSort = questField(recorded.questId, "zoneOrSort") or 0, acceptedAt = sim.now }
                table.insert(game.questLog, logEntry)
            end
            for index, objective in ipairs(recorded.objectives or {}) do
                local own = logEntry.objectives[index]
                if own then own.fulfilled, own.required = objective.fulfilled or own.fulfilled, objective.required or own.required end
            end
            logEntry.isComplete = recorded.isComplete == true
        end
    end
    if entry.e == "PLAYER_TARGET_CHANGED" or entry.e == "UNIT_DIED" then
        local target = entry.target
        local npcId = target and tonumber((target.guid or ""):match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
        game.fighting = target and npcId and { guid = target.guid, npcId = npcId, name = target.name, isDead = target.isDead == true,
            isTappedByOthers = target.isTappedByOthers == true, unit = "target" } or nil
    end
    sim.touch()
end

---Uses an item, as clicking it does: one with an on-use effect casts its spell (UNIT_SPELLCAST_SUCCEEDED) and starts
---its cooldown. target: an item id, link or name.
---@return boolean isUsed, string? problem
function game.useItem(target)
    local itemId = tonumber(target) or tonumber(tostring(target or ""):match("item:(%d+)"))
    if not itemId and type(target) == "string" then
        for id, item in pairs(game.items or {}) do
            if item.name == target then itemId = id; break end
        end
    end
    local item = itemId and game.items and game.items[itemId]
    if not item or not item.useEffect then return false, "that item cannot be used" end
    game.itemUsedAt = game.itemUsedAt or {}
    local usedAt = game.itemUsedAt[itemId]
    if usedAt and sim.now - usedAt < item.useEffect.cooldown then
        sim.fireEvent("UI_ERROR_MESSAGE", 0, "Item is not ready yet.")
        return false, "not ready yet"
    end
    game.itemUsedAt[itemId] = sim.now
    game.lastUsedItemId = itemId
    sim.fireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-0-0-0-" .. item.useEffect.spellId .. "-0000000001", item.useEffect.spellId)
    sim.fireEvent("BAG_UPDATE_COOLDOWN")
    return true
end

-- Rolls for drops: a fixed seed, so a scenario plays the same every time
local randomState = 20261116
function game.random()
    randomState = (randomState * 1103515245 + 12345) % 2147483648
    return randomState / 2147483648
end
function game.setRandomSeed(seed) randomState = seed end

-- Quest givers: talking opens their dialog, the way addons read the quests offered
game.npc = nil
function game.talkTo(npcId)
    npcId = tonumber(npcId)
    local npcs = getDatabase("Npc")
    if not npcId or not npcs then return false, "no creature" end
    local function getField(field) local isRead, value = pcall(npcs.Get, npcId, field); return isRead and value or nil end
    local offers, active = {}, {}
    for _, questId in ipairs(getField("questStarts") or {}) do
        if not game.completed[questId] and not findEntry(questId) then
            offers[#offers + 1] = { questID = questId, title = questField(questId, "name") or ("Quest " .. questId), questLevel = questField(questId, "questLevel") or 0,
                isTrivial = false, frequency = 0, repeatable = false, isComplete = false, isLegendary = false, isIgnored = false }
        end
    end
    for _, questId in ipairs(getField("questEnds") or {}) do
        local entry = findEntry(questId)
        if entry then
            active[#active + 1] = { questID = questId, title = entry.title, questLevel = entry.level, isComplete = entry.isComplete == true, isTrivial = false }
        end
    end
    game.npc = { id = npcId, name = getField("name") or ("Creature " .. npcId), guid = creatureGuid(npcId), offers = offers, active = active }
    if G.GossipFrame then G.GossipFrame:Show() end
    sim.fireEvent("GOSSIP_SHOW")
    return true, nil, { name = game.npc.name, offers = offers, active = active }
end

function game.closeDialog()
    if not game.npc then return true end
    game.npc = nil
    if G.GossipFrame then G.GossipFrame:Hide() end
    sim.fireEvent("GOSSIP_CLOSED")
    return true
end

---Into an instance and out: the game's own instance number, its type and name, and the loading screen's events.
function game.setInstance(instanceId, instanceType, name)
    local profile = game.profile
    profile.isInInstance = instanceId ~= nil and instanceId ~= 0
    profile.instanceId = profile.isInInstance and tonumber(instanceId) or 0
    profile.instanceType = profile.isInInstance and (instanceType or "party") or "none"
    profile.instanceName = profile.isInInstance and name or nil
    sim.fireEvent("PLAYER_ENTERING_WORLD", false, false)
    sim.fireEvent("ZONE_CHANGED_NEW_AREA")
    sim.touch()
    return true
end

function game.install()
    local profile = game.profile
    -- Nameplates (game.addNamePlate): the plate of a unit, and every plate shown
    G.C_NamePlate = G.C_NamePlate or {}
    G.C_NamePlate.GetNamePlateForUnit = function(unit) return unit and namePlatesByUnit[unit] or nil end
    G.C_NamePlate.GetNamePlates = function()
        local plates = {}
        for _, frame in ipairs(namePlateFrames) do
            if frame.namePlateUnitToken then plates[#plates + 1] = frame end
        end
        return plates
    end
    -- Units
    local function isPlayer(unit) return unit == "player" or unit == nil end
    local function isNpc(unit) return (unit == "npc" or unit == "target") and game.npc ~= nil end
    -- The creature being fought (game.kill), as the target
    local function fighting(unit) return unit ~= nil and game.fighting ~= nil and game.fighting.unit == unit and game.fighting or nil end
    G.UnitName = function(unit)
        if isPlayer(unit) then return profile.name, nil end
        if fighting(unit) then return game.fighting.name end
        if isNpc(unit) then return game.npc.name end
    end
    G.UnitNameUnmodified = G.UnitName
    G.GetUnitName = function(unit, showServer) if isPlayer(unit) then return profile.name end end
    G.UnitFullName = function(unit) if isPlayer(unit) then return profile.name, profile.realm end end
    -- How far below a character a quest turns grey, as the classic client answers: 5 up to level 5, then a tenth
    -- of the level and 5, from 40 a fifth and 1
    G.UnitQuestTrivialLevelRange = function(unit)
        local level = G.UnitLevel(unit) or 1
        if level <= 5 then return 5 end
        if level < 40 then return math.floor(level / 10) + 5 end
        return math.floor(level / 5) + 1
    end
    G.UnitLevel = function(unit)
        if isPlayer(unit) then return profile.level end
        if fighting(unit) then
            local npcs = getDatabase("Npc")
            local isRead, level = false, nil
            if npcs then isRead, level = pcall(npcs.Get, game.fighting.npcId, "minLevel") end
            return isRead and level or 1
        end
        return 0
    end
    G.UnitEffectiveLevel = G.UnitLevel
    -- A creature's rank, as the game names it (the database's rank: 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare):
    -- the nameplate's elite or rare ornament and the target frame's dragon go by it
    local CLASSIFICATIONS = { [0] = "normal", [1] = "elite", [2] = "rareelite", [3] = "worldboss", [4] = "rare" }
    G.UnitClassification = function(unit)
        if isPlayer(unit) then return "normal" end
        local npcId = fighting(unit) and game.fighting.npcId or isNpc(unit) and game.npc.npcId or nil
        if not npcId then return nil end
        local npcs = getDatabase("Npc")
        local isRead, rank = false, nil
        if npcs then isRead, rank = pcall(npcs.Get, npcId, "rank") end
        return CLASSIFICATIONS[isRead and rank or 0] or "normal"
    end
    G.UnitRace = function(unit) if isPlayer(unit) then return profile.raceName, profile.race, profile.raceId end end
    G.UnitClass = function(unit) if isPlayer(unit) then return profile.className, profile.class, profile.classId end end
    G.UnitClassBase = function(unit) if isPlayer(unit) then return profile.class, profile.classId end end
    G.UnitFactionGroup = function(unit) if isPlayer(unit) then return profile.faction, profile.faction end end
    -- The classes and races this client has, by number, as the game's windows look them up (the spellbook's
    -- portrait, the collections' class filter): numbers without one (6, 10) give nothing, as in the client
    local classById, raceById = {}, {}
    for file, class in pairs(CLASSES) do classById[class[1]] = { className = class[2], classFile = file, classID = class[1] } end
    for file, race in pairs(RACES) do raceById[race[1]] = { raceName = race[2], clientFileString = file, raceID = race[1], faction = race[3] } end
    local function copyOf(info) local copy = {}; for key, value in pairs(info) do copy[key] = value end; return copy end
    G.C_CreatureInfo = G.C_CreatureInfo or {}
    G.C_CreatureInfo.GetClassInfo = function(classId) local info = classById[tonumber(classId)]; return info and copyOf(info) end
    G.C_CreatureInfo.GetRaceInfo = function(raceId)
        local info = raceById[tonumber(raceId)]
        return info and { raceName = info.raceName, clientFileString = info.clientFileString, raceID = info.raceID }
    end
    G.C_CreatureInfo.GetFactionInfo = function(raceId)
        local info = raceById[tonumber(raceId)]
        if not info then return nil end
        local name = info.faction == "Horde" and (rawget(G, "FACTION_HORDE") or "Horde") or (rawget(G, "FACTION_ALLIANCE") or "Alliance")
        return { name = name, groupTag = info.faction }
    end
    G.GetClassInfo = function(classId)
        local info = classById[tonumber(classId)]
        if info then return info.className, info.classFile, info.classID end
    end
    -- (9, the classes there are, though their numbers go to 11: the client's answer, measured; a loop to it misses
    -- the druid, as in the game)
    G.GetNumClasses = function() return 9 end
    -- Achievements: the simulator has none of the client's achievement tables yet, so no categories and nothing
    -- earned (the achievement window opens empty, rather than failing as it loads)
    G.GetCategoryList = function() return {} end
    G.GetStatisticsCategoryList = function() return {} end
    G.GetGuildCategoryList = function() return {} end
    G.GetCategoryNumAchievements = function() return 0, 0, 0 end
    G.GetTotalAchievementPoints = function() return 0 end
    G.GetNumCompletedAchievements = function() return 0, 0 end
    G.GetLatestCompletedAchievements = function() return end
    G.C_SpecializationInfo = G.C_SpecializationInfo or {}
    G.C_SpecializationInfo.GetAllClassIDs = function()
        local ids = {}
        for id in pairs(classById) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids
    end
    G.UnitSex = function() return profile.sex end
    -- No group role picked, as the client says it ("NONE", never empty)
    G.UnitGroupRolesAssigned = function() return "NONE" end
    -- A unit's portrait: the game draws the face from the 3D model, which the simulator cannot; the player's race icon
    -- stands in for it (other units keep what the texture had)
    local RACE_ICONS = { Scourge = "undead", NightElf = "nightelf", BloodElf = "bloodelf" }
    G.SetPortraitTexture = function(texture, unit)
        if type(texture) ~= "table" or not texture.SetAtlas or not isPlayer(unit) then return end
        local race = RACE_ICONS[profile.race] or tostring(profile.race or "human"):lower()
        texture:SetAtlas("raceicon128-" .. race .. (profile.sex == 3 and "-female" or "-male"))
    end
    G.UnitGUID = function(unit)
        if isPlayer(unit) then return "Player-1-00000001" end
        if fighting(unit) then return sim.hide(game.fighting.guid, "identity") end
        if isNpc(unit) then return game.npc.guid end
    end
    G.UnitExists = function(unit) return isPlayer(unit) or fighting(unit) ~= nil or isNpc(unit) end
    -- Seen by the client: every unit the simulator knows is near enough to be
    G.UnitIsVisible = function(unit) return G.UnitExists(unit) end
    -- The minimap's shape, as the client answers it for its own round minimap (an addon that makes it square defines
    -- its own GetMinimapShape, as on the client)
    G.GetMinimapShape = G.GetMinimapShape or function() return "ROUND" end
    -- The input the interface is styled for: keyboard and mouse (Enum.InputDeviceInterfaceType.Mkb)
    -- (C_InputInterfaceStyle: the gamepad module's, from the InputDeviceInterfaceStyle setting)
    G.UnitIsUnit = function(first, second) return first == second end
    G.UnitIsPlayer = function(unit) return isPlayer(unit) end
    G.UnitIsDeadOrGhost = function(unit) return fighting(unit) ~= nil and game.fighting.isDead end
    G.UnitIsDead = function(unit) return fighting(unit) ~= nil and game.fighting.isDead end
    G.UnitIsGhost = function() return false end
    G.UnitAffectingCombat = function(unit)
        if fighting(unit) then return not game.fighting.isDead end
        return sim.inCombat == true
    end
    -- Threat: hidden when the game restricts it; the creature being fought has the player at the top
    G.UnitThreatSituation = function(unit, target)
        if not fighting(target) or game.fighting.isDead then return nil end
        return sim.hide(game.fighting.isTappedByOthers and 0 or 3, "threat")
    end
    G.UnitIsTapDenied = function(unit) return fighting(unit) ~= nil and game.fighting.isTappedByOthers end
    G.UnitHealth, G.UnitHealthMax = function() return 1000 end, function() return 1000 end
    -- The player's power by class, as in the game: warriors rage (empty out of combat), rogues energy (full), the
    -- rest mana; other units mana
    local POWER = { WARRIOR = { 1, "RAGE", 0, 100 }, ROGUE = { 3, "ENERGY", 100, 100 } }
    local NO_POWER = { 0, "MANA", 0, 0 }
    local function getPower(unit)
        -- (a creature: none, as most beasts have none and the database tells no creature's; its frame shows no bar)
        if fighting(unit) then return NO_POWER end
        return isPlayer(unit) and POWER[tostring(profile.class or ""):upper()] or { 0, "MANA", 1000, 1000 }
    end
    G.UnitPowerType = function(unit)
        local power = getPower(unit)
        return power[1], power[2]
    end
    G.UnitPower = function(unit) return getPower(unit)[3] end
    G.UnitPowerMax = function(unit) return getPower(unit)[4] end
    G.UnitXP, G.UnitXPMax = function() return profile.xp end, function() return profile.xpMax end
    G.GetXPExhaustion = function() return nil end
    G.UnitInParty = function() return false end
    G.UnitInRaid = function() return nil end
    G.UnitIsConnected = function() return true end
    G.UnitIsAFK = function() return false end
    G.UnitReaction = function() return 4 end
    G.UnitCanAttack = function(_, unit) return fighting(unit) ~= nil end
    G.UnitIsFriend = function(_, unit) return fighting(unit) == nil end
    -- Where a unit stands in the world, in yards, with the continent: the same reckoning as the map's
    -- (C_Map.GetWorldPosFromMapPos of the player's place on their map); nothing inside an instance
    G.UnitPosition = function(unit)
        if (unit ~= "player" and unit ~= nil) or profile.isInInstance then return nil end
        local continentId, worldX, worldY = game.mapToWorld(profile.uiMapId, profile.x, profile.y)
        if not continentId then return nil end
        return worldX, worldY, 0, continentId
    end
    G.UnitOnTaxi = function() return false end
    G.UnitIsMounted = function() return false end
    G.IsMounted = function() return false end
    G.IsFlying = function() return false end
    G.IsSwimming = function() return false end
    G.IsResting = function() return false end
    G.GetPlayerFacing = function() return profile.facing end
    G.GetRealmName = function() return profile.realm end
    G.GetNormalizedRealmName = function() return profile.realm end
    G.GetMoney = function() return profile.money end
    G.Ambiguate = function(name) return (name or ""):match("^[^-]+") or name end
    G.IsInGroup = function() return profile.groupSize > 0 end
    G.IsInRaid = function() return false end
    G.GetNumGroupMembers = function() return profile.groupSize end
    G.GetNumSubgroupMembers = function() return profile.groupSize end
    G.IsInGuild = function() return false end
    G.UnitIsGroupLeader = function() return false end
    G.IsInInstance = function() return profile.isInInstance, profile.instanceType end
    G.GetInstanceInfo = function()
        local map = game.maps[profile.uiMapId]
        return profile.instanceName or (map and map.name) or "", profile.instanceType, 0, "", 5, 0, false, profile.instanceId, 0, 0
    end
    local function zoneName()
        local map = game.maps[profile.uiMapId]
        return map and map.name or "Unknown"
    end
    G.GetRealZoneText = zoneName
    G.GetZoneText = zoneName
    G.GetSubZoneText = function() return "" end
    G.GetMinimapZoneText = zoneName
    G.GetZonePVPInfo = function() return nil end

    -- The map
    G.C_Map = {
        GetBestMapForUnit = function(unit) if isPlayer(unit) then return profile.uiMapId end end,
        GetPlayerMapPosition = function(uiMapId, unit)
            if not isPlayer(unit) or profile.isInInstance then return nil end
            if uiMapId == profile.uiMapId then return G.CreateVector2D(profile.x, profile.y) end
            local continentId, worldX, worldY = game.mapToWorld(profile.uiMapId, profile.x, profile.y)
            if not continentId then return nil end
            local x, y = game.worldToMap(uiMapId, continentId, worldX, worldY)
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return G.CreateVector2D(x, y) end
        end,
        GetMapInfo = function(uiMapId)
            local map = game.maps[uiMapId]
            if map then return { mapID = map.mapID, name = map.name, parentMapID = map.parentMapID, mapType = map.mapType, flags = map.flags } end
        end,
        GetMapChildrenInfo = function(uiMapId, mapType, isAllDescendants)
            local results = {}
            local function collect(parent)
                for _, childId in ipairs(game.mapChildren[parent] or {}) do
                    local child = game.maps[childId]
                    if not mapType or child.mapType == mapType then
                        results[#results + 1] = { mapID = child.mapID, name = child.name, parentMapID = child.parentMapID, mapType = child.mapType, flags = child.flags }
                    end
                    if isAllDescendants then collect(childId) end
                end
            end
            collect(uiMapId)
            return results
        end,
        GetWorldPosFromMapPos = function(uiMapId, position)
            local x, y = position.x, position.y
            if position.GetXY then x, y = position:GetXY() end
            local continentId, worldX, worldY = game.mapToWorld(uiMapId, x, y)
            if continentId then return continentId, G.CreateVector2D(worldX, worldY) end
        end,
        GetMapPosFromWorldPos = function(continentId, position, overrideMapId)
            local worldX, worldY = position.x, position.y
            if position.GetXY then worldX, worldY = position:GetXY() end
            local x, y = game.worldToMap(overrideMapId, continentId, worldX, worldY)
            if x then return overrideMapId, G.CreateVector2D(x, y) end
        end,
        GetAreaInfo = function(areaId) return game.areas[areaId] end,
        GetMapLevels = function() return 0, 0, 0, 0 end,
        -- The map's art layer with its zoom range (UiMapArtStyleLayer): the map zooms from minScale to maxScale
        GetMapArtLayers = function(uiMapId)
            local art = require("ui").mapArt and require("ui").mapArt[uiMapId]
            local layer = art and art.layer
            if layer then
                return { { layerWidth = layer.layerWidth, layerHeight = layer.layerHeight, tileWidth = layer.tileWidth, tileHeight = layer.tileHeight,
                    minScale = layer.minScale, maxScale = layer.maxScale, additionalZoomSteps = layer.additionalZoomSteps } }
            end
            return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256, minScale = 1, maxScale = 1, additionalZoomSteps = 0 } }
        end,
        -- The layer's tile files, row by row as the game's map canvas lays them out (UiMapArtTile)
        GetMapArtLayerTextures = function(uiMapId, layerIndex)
            local art = require("ui").mapArt and require("ui").mapArt[uiMapId]
            if not art or (layerIndex or 1) ~= 1 then return {} end
            local columns = math.ceil(art.layer.layerWidth / art.layer.tileWidth)
            local textures = {}
            for _, tile in ipairs(art.tiles) do
                textures[tile.row * columns + tile.column + 1] = tile.fileId
            end
            return textures
        end,
        GetMapGroupID = function() return nil end,
        GetMapGroupMembersInfo = function() return nil end,
        GetMapLinksForMap = function() return {} end,
        -- Where one map lies on another (minX, maxX, minY, maxY), from both maps' places in the world: their
        -- corners through the world's coordinates; the whole map when either is not placed in the world
        GetMapRectOnMap = function(uiMapId, topMapId)
            local rect = game.getMapRectOnMap(uiMapId, topMapId)
            if not rect then return 0, 1, 0, 1 end
            return rect[1], rect[2], rect[3], rect[4]
        end,
        GetMapDisplayInfo = function() return false end,
        CanSetUserWaypointOnMap = function() return true end,
        SetUserWaypoint = function(point) game.waypoint = point; sim.fireEvent("USER_WAYPOINT_UPDATED") end,
        ClearUserWaypoint = function() game.waypoint = nil; sim.fireEvent("USER_WAYPOINT_UPDATED") end,
        HasUserWaypoint = function() return game.waypoint ~= nil end,
        GetUserWaypoint = function() return game.waypoint end,
        -- Where the player's map pin stands on a map: on its own map as set, on another (its continent, a
        -- neighbouring zone) through the world's coordinates; nil where it is not on that map
        GetUserWaypointPositionForMap = function(uiMapId)
            local point = game.waypoint
            if not point or not uiMapId then return nil end
            local x, y = point.position.x, point.position.y
            if point.uiMapID == uiMapId then return G.CreateVector2D(x, y) end
            local continentId, worldX, worldY = game.mapToWorld(point.uiMapID, x, y)
            if not continentId then return nil end
            local mapX, mapY = game.worldToMap(uiMapId, continentId, worldX, worldY)
            if mapX and mapX >= 0 and mapX <= 1 and mapY >= 0 and mapY <= 1 then return G.CreateVector2D(mapX, mapY) end
        end,
        -- The pin as a chat link, as the client writes it: |Hworldmap:map:x:y| with x and y in ten-thousandths
        GetUserWaypointHyperlink = function()
            local point = game.waypoint
            if not point then return nil end
            return string.format("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r", point.uiMapID,
                math.floor(point.position.x * 10000 + 0.5), math.floor(point.position.y * 10000 + 0.5), G.MAP_PIN_HYPERLINK or "Map Pin Location")
        end,
        OpenWorldMap = function(uiMapId) if G.WorldMapFrame then G.WorldMapFrame:Show(); if uiMapId then G.WorldMapFrame:SetMapID(uiMapId) end end end,
        GetFallbackWorldMapID = function() return 947 end,
        -- A continent or zone, as the map's nav bar lists them in a button's dropdown (its siblings); not the world, a
        -- dungeon or a floor of one
        IsMapValidForNavBarDropdown = function(uiMapId)
            local map = game.maps[uiMapId]
            return map ~= nil and map.parentMapID > 0 and (map.mapType == 2 or map.mapType == 3)
        end,
        MapHasArt = function() return true end,
        GetMapBannersForMap = function() return {} end,
        -- The child map under a place on a map (a zone on its continent, a continent on the world), by the shape of its
        -- highlight art, as the game lights it: clicking it opens that map, the cursor over it names it and lights it
        GetMapInfoAtPosition = function(uiMapId, x, y)
            local childId = game.getChildMapAt(uiMapId, x, y)
            return childId and G.C_Map.GetMapInfo(childId)
        end,
        GetMapHighlightInfoAtPosition = function(uiMapId, x, y)
            local childId, rect, highlight = game.getChildMapAt(uiMapId, x, y)
            if not childId or not highlight then return nil end
            return highlight.fileId, nil, highlight.texPercentX, highlight.texPercentY, rect[2] - rect[1], rect[4] - rect[3], rect[1], rect[3]
        end,
        GetMapHighlightPulseInfo = function() return nil end,
    }
    G.UiMapPoint = { CreateFromCoordinates = function(uiMapId, x, y) return { uiMapID = uiMapId, position = G.CreateVector2D(x, y) } end,
        CreateFromVector2D = function(uiMapId, vector) return { uiMapID = uiMapId, position = vector } end }
    G.MapUtil = {
        GetMapParentInfo = function(uiMapId, mapType, isTopMost)
            local map, found = game.maps[uiMapId], nil
            while map do
                if map.mapType == mapType then found = map; if not isTopMost then break end end
                map = game.maps[map.parentMapID]
            end
            return found and G.C_Map.GetMapInfo(found.mapID)
        end,
        GetDisplayableMapForPlayer = function() return profile.uiMapId end,
        IsChildMap = function(uiMapId, ancestorId)
            local map = game.maps[uiMapId]
            while map do
                if map.parentMapID == ancestorId then return true end
                map = game.maps[map.parentMapID]
            end
            return false
        end,
        GetMapCenterOnMap = function() return 0.5, 0.5 end,
    }
    G.C_Minimap = { GetViewRadius = function() return 200 end, IsRotateMinimapIgnored = function() return false end,
        GetNumTrackingTypes = function() return 0 end, ShouldUseHybridMinimap = function() return false end }
    G.C_SuperTrack = { SetSuperTrackedQuestID = function(questId) game.superTracked = questId; sim.fireEvent("SUPER_TRACKING_CHANGED") end,
        GetSuperTrackedQuestID = function() return game.superTracked or 0 end, SetSuperTrackedUserWaypoint = function() end,
        IsSuperTrackingQuest = function() return game.superTracked ~= nil end, IsSuperTrackingUserWaypoint = function() return false end,
        ClearAllSuperTracked = function() game.superTracked = nil end, IsSuperTrackingAnything = function() return game.superTracked ~= nil end }

    -- The quest log
    local function headerFor(entry)
        local sort = entry.zoneOrSort or 0
        if sort > 0 then
            return game.areas[sort] or ("Zone " .. sort)
        end
        return game.questSorts and game.questSorts[-sort] or "Miscellaneous"
    end
    local function buildRows()
        local groups, order = {}, {}
        for _, entry in ipairs(game.questLog) do
            local header = headerFor(entry)
            if not groups[header] then
                groups[header] = {}
                order[#order + 1] = header
            end
            table.insert(groups[header], entry)
        end
        local rows = {}
        for _, header in ipairs(order) do
            rows[#rows + 1] = { isHeader = true, title = header }
            for _, entry in ipairs(groups[header]) do
                rows[#rows + 1] = { entry = entry }
            end
        end
        return rows
    end
    game.buildRows = buildRows
    local function getIndex(questId)
        for index, row in ipairs(buildRows()) do
            if row.entry and row.entry.questId == questId then return index end
        end
    end
    G.C_QuestLog = {
        GetNumQuestLogEntries = function()
            local rows = buildRows()
            return #rows, #game.questLog
        end,
        GetInfo = function(index)
            local row = buildRows()[index]
            if not row then return nil end
            if row.isHeader then
                return { title = row.title, questLogIndex = index, questID = 0, isHeader = true, isCollapsed = false, level = 0,
                    difficultyLevel = 0, suggestedGroup = 0, frequency = 0, isHidden = false, isOnMap = false, hasLocalPOI = false,
                    isTask = false, isBounty = false, isStory = false, isScaling = false, startEvent = false, overridesSortOrder = false }
            end
            local entry = row.entry
            return { title = entry.title, questLogIndex = index, questID = entry.questId, isHeader = false, isCollapsed = false,
                level = entry.level, difficultyLevel = entry.level, suggestedGroup = 0, frequency = 0, isHidden = false,
                isOnMap = true, hasLocalPOI = false, isTask = false, isBounty = false, isStory = false, isScaling = false,
                startEvent = false, overridesSortOrder = false, readyForTranslation = true, isComplete = entry.isComplete and 1 or nil }
        end,
        GetLogIndexForQuestID = getIndex,
        GetQuestIDForLogIndex = function(index) local row = buildRows()[index]; return row and row.entry and row.entry.questId or 0 end,
        GetQuestObjectives = function(questId)
            local entry = findEntry(questId)
            if not entry then return {} end
            local result = {}
            for _, objective in ipairs(entry.objectives) do
                result[#result + 1] = { text = objectiveText(objective), type = objective.kind, finished = objective.fulfilled >= objective.required,
                    numFulfilled = objective.fulfilled, numRequired = objective.required }
            end
            return result
        end,
        GetTitleForQuestID = function(questId)
            local entry = findEntry(questId)
            return entry and entry.title or questField(questId, "name")
        end,
        IsComplete = function(questId) local entry = findEntry(questId); return entry ~= nil and entry.isComplete == true end,
        IsFailed = function(questId) local entry = findEntry(questId); return entry ~= nil and entry.isFailed == true end,
        IsOnQuest = function(questId) return findEntry(questId) ~= nil end,
        IsQuestFlaggedCompleted = function(questId) return game.completed[questId] == true end,
        GetAllCompletedQuestIDs = function() local list = {}; for questId in pairs(game.completed) do list[#list + 1] = questId end; table.sort(list); return list end,
        GetQuestTagInfo = function() return nil end,
        GetQuestDifficultyLevel = function(questId) local entry = findEntry(questId); return entry and entry.level or 0 end,
        GetSuggestedGroupSize = function() return 0 end,
        GetTimeAllowed = function() return nil end,
        GetMaxNumQuestsCanAccept = function() return 20 end,
        GetMaxNumQuests = function() return 20 end,
        GetNumQuestWatches = function() local count = 0; for _ in pairs(game.watched) do count = count + 1 end; return count end,
        GetQuestIDForQuestWatchIndex = function(index)
            local ids = {}
            for _, entry in ipairs(game.questLog) do if game.watched[entry.questId] then ids[#ids + 1] = entry.questId end end
            return ids[index]
        end,
        AddQuestWatch = function(questId)
            if not findEntry(questId) then return false end
            game.watched[questId] = true
            sim.fireEvent("QUEST_WATCH_LIST_CHANGED", questId, true)
            return true
        end,
        RemoveQuestWatch = function(questId)
            game.watched[questId] = nil
            sim.fireEvent("QUEST_WATCH_LIST_CHANGED", questId, false)
            return true
        end,
        GetQuestWatchType = function(questId) return game.watched[questId] and 1 or nil end,
        IsQuestWatched = function(questId) return game.watched[questId] == true end,
        SetSelectedQuest = function(questId) game.selectedQuestId = questId end,
        GetSelectedQuest = function() return game.selectedQuestId or 0 end,
        SetAbandonQuest = function() game.abandonQuestId = game.selectedQuestId end,
        GetAbandonQuest = function() return game.abandonQuestId or 0 end,
        AbandonQuest = function() if game.abandonQuestId then game.abandonQuest(game.abandonQuestId) end end,
        IsPushableQuest = function() return true end,
        IsUnitOnQuest = function(unit, questId) return isPlayer(unit) and findEntry(questId) ~= nil end,
        RequestLoadQuestByID = function(questId) sim.addTimer(0.05, function() sim.fireEvent("QUEST_DATA_LOAD_RESULT", questId, true) end) end,
        GetQuestLogPortraitGiver = function() return 0 end,
        ShouldShowQuestRewards = function() return true end,
        GetQuestAdditionalHighlights = function() return 0, 0, 0, 0 end,
        IsQuestTask = function() return false end,
        IsWorldQuest = function() return false end,
        IsAccountQuest = function() return false end,
        IsRepeatableQuest = function() return false end,
        IsLegendaryQuest = function() return false end,
        IsQuestTrivial = function() return false end,
        GetRequiredMoney = function() return 0 end,
        GetDistanceSqToQuest = function() return 10000, true end,
        GetQuestsOnMap = function() return {} end,
        ReadyForTurnIn = function(questId) local entry = findEntry(questId); return entry ~= nil and entry.isComplete == true end,
        GetNextWaypoint = function() return nil end,
        GetQuestType = function() return 0 end,
        GetHeaderIndexForQuest = function() return nil end,
        SortQuestWatches = function() end,
        GetActiveThreatMaps = function() return {} end,
        GetBountySetInfoForMapID = function() return nil end,
        GetZoneStoryInfo = function() return nil end,
        IsQuestCalling = function() return false end,
        QuestHasQuestSessionBonus = function() return false end,
        GetQuestDetailsTheme = function() return nil end,
    }
    G.GetQuestTagInfo = function() return nil end
    G.GetNumQuestLogEntries = function() return G.C_QuestLog.GetNumQuestLogEntries() end
    G.GetQuestLogTitle = function(index)
        local info = G.C_QuestLog.GetInfo(index)
        if not info then return nil end
        return info.title, info.level, nil, info.isHeader, info.isCollapsed, info.isComplete, info.frequency, info.questID
    end
    G.GetQuestLogIndexByID = function(questId) return G.C_QuestLog.GetLogIndexForQuestID(questId) or 0 end
    G.SelectQuestLogEntry = function(index) local row = buildRows()[index]; game.selectedQuestId = row and row.entry and row.entry.questId end
    G.GetQuestLogSelection = function() return getIndex(game.selectedQuestId) or 0 end
    G.GetNumQuestLeaderBoards = function(index) local row = buildRows()[index or getIndex(game.selectedQuestId) or 0]; return row and row.entry and #row.entry.objectives or 0 end
    G.GetQuestLogLeaderBoard = function(objectiveIndex, index)
        local row = buildRows()[index or getIndex(game.selectedQuestId) or 0]
        local objective = row and row.entry and row.entry.objectives[objectiveIndex]
        if objective then return objectiveText(objective), objective.kind, objective.fulfilled >= objective.required end
    end
    G.GetQuestLogQuestText = function() local questId = game.selectedQuestId; return questField(questId or 0, "name") or "", table.concat(questField(questId or 0, "objectivesText") or {}, " ") end
    G.GetQuestLogRewardXP = function() return 1000 end
    G.GetQuestLogRewardMoney = function() return 500 end
    -- (no artifacts in this game: no artifact power, as the client answers; the quest details compare it with 0)
    G.GetQuestLogRewardArtifactXP = function() return 0, 0 end
    G.GetRewardArtifactXP = function() return 0, 0 end
    G.GetNumQuestLogRewards = function() return 0 end
    G.GetNumQuestLogChoices = function() return 0 end
    G.GetQuestLogRewardInfo = function() return nil end
    G.GetQuestLogChoiceInfo = function() return nil end
    -- A quest's item button: the item it hands out, when that item can be used (an on-use effect), as the game shows it
    local function getSpecialItem(logIndex)
        local row = game.buildRows()[logIndex or 0]
        local questId = row and row.entry and row.entry.questId
        local itemId = questId and questField(questId, "sourceItemId")
        local item = type(itemId) == "number" and game.items and game.items[itemId]
        if not item or not item.useEffect then return nil end
        return itemId, item
    end
    G.GetQuestLogSpecialItemInfo = function(logIndex)
        local itemId, item = getSpecialItem(logIndex)
        if not itemId then return nil end
        local _, link = G.C_Item.GetItemInfo(itemId) -- the modern one: this client has no global GetItemInfo
        return link, item.icon, item.useEffect.charges, false
    end
    G.GetQuestLogSpecialItemCooldown = function(logIndex)
        local itemId, item = getSpecialItem(logIndex)
        if not itemId then return nil end
        local usedAt = game.itemUsedAt and game.itemUsedAt[itemId]
        if usedAt and sim.now - usedAt < item.useEffect.cooldown then return usedAt, item.useEffect.cooldown, 1 end
        return 0, 0, 1
    end
    G.HaveQuestRewardData = function() return true end
    G.HaveQuestData = function() return true end
    G.GetQuestsCompleted = function() local copy = {}; for questId in pairs(game.completed) do copy[questId] = true end; return copy end
    G.QuestLogPushQuest = function() end
    G.GetQuestDifficultyColor = function(level)
        local difference = (level or 0) - profile.level
        if difference >= 5 then return { r = 1, g = 0.1, b = 0.1, font = G.QuestDifficulty_Impossible }
        elseif difference >= 3 then return { r = 1, g = 0.5, b = 0.25 }
        elseif difference >= -2 then return { r = 1, g = 1, b = 0 }
        elseif difference >= -8 then return { r = 0.25, g = 0.75, b = 0.25 } end
        return { r = 0.5, g = 0.5, b = 0.5 }
    end
    G.GetQuestGreenRange = function() return 8 end
    G.IsQuestComplete = function(questId) return G.C_QuestLog.IsComplete(questId) end
    G.GetQuestReward = function() end
    G.GetQuestItemLink = function() return nil end
    -- Quest givers' dialogs (empty unless the page opens one)
    G.GetQuestID = function() return game.dialogQuestId or 0 end
    G.GetTitleText = function() return game.dialogQuestId and questField(game.dialogQuestId, "name") or "" end
    G.GetNumAvailableQuests = function() return 0 end
    G.GetNumActiveQuests = function() return 0 end
    G.GetAvailableTitle = function() return nil end
    G.GetAvailableQuestInfo = function() return false, 0, false, false, 0 end
    G.C_GossipInfo = { GetAvailableQuests = function() return game.npc and game.npc.offers or {} end,
        GetActiveQuests = function() return game.npc and game.npc.active or {} end, GetOptions = function() return {} end,
        GetText = function() return "" end, GetNumAvailableQuests = function() return 0 end, GetNumActiveQuests = function() return 0 end }
    G.C_QuestLine = { GetAvailableQuestLines = function() return {} end, RequestQuestLinesForMap = function() end,
        GetQuestLineInfo = function() return nil end, GetQuestLineQuests = function() return {} end }
    G.C_TooltipInfo = { GetQuestPartyProgress = function() return nil end, GetItemByID = function() return nil end, GetHyperlink = function() return nil end,
        GetSpellByID = function() return nil end }
    -- A unit's tooltip data, as the client gives it to the game's tooltip code (GameTooltip:SetUnit is its Lua, which
    -- draws these lines and then runs the post-calls addons add): the name, then the level line
    local tooltipDataCount = 0
    G.C_TooltipInfo.GetUnit = function(unit)
        local name = unit and G.UnitName(unit)
        if not name then return nil end
        local enum, makeColor = G.Enum or {}, G.CreateColor
        local lineTypes, dataTypes = enum.TooltipDataLineType or {}, enum.TooltipDataType or {}
        local isPlayerUnit = G.UnitIsPlayer and G.UnitIsPlayer(unit)
        local nameColor = makeColor and (isPlayerUnit and makeColor(1, 1, 1) or makeColor(1, 0.82, 0)) or nil
        local level = G.UnitLevel and G.UnitLevel(unit)
        tooltipDataCount = tooltipDataCount + 1
        local lines = {
            { type = lineTypes.UnitName or 2, leftText = name, leftColor = nameColor, unitToken = unit },
        }
        if type(level) == "number" and level > 0 then
            lines[#lines + 1] = { type = lineTypes.None or 0, leftText = string.format(G.TOOLTIP_UNIT_LEVEL or "Level %s", level), leftColor = makeColor and makeColor(1, 1, 1) or nil }
        end
        return { type = dataTypes.Unit or 2, guid = G.UnitGUID and G.UnitGUID(unit) or nil, lines = lines, dataInstanceID = tooltipDataCount }
    end

    -- Items, spells, skills, reputations: from the profile, names from QuestieDB when it knows them
    -- Items from the game's own tables (Item, ItemSparse): name, quality, levels, icon, price
    local QUALITY_HEX = { [0] = "ff9d9d9d", "ffffffff", "ff1eff00", "ff0070dd", "ffa335ee", "ffff8000", "ffe6cc80", "ff00ccff" }
    local CLASS_NAMES = { [0] = "Consumable", "Container", "Weapon", "Gem", "Armor", "Reagent", "Projectile", "Trade Goods", "Item Enhancement",
        "Recipe", "Money", "Quiver", "Quest", "Key", "Permanent", "Miscellaneous" }
    local QUESTION_MARK = 134400
    local function getItem(itemId)
        itemId = tonumber(type(itemId) == "string" and itemId:match("item:(%d+)") or itemId)
        return itemId, itemId and game.items and game.items[itemId]
    end
    local function itemInfo(target)
        local itemId, item = getItem(target)
        if not itemId then return nil end
        local name = item and item.name or entityName("Item", itemId) or ("Item " .. itemId)
        local quality = item and item.quality or 1
        local link = "|c" .. (QUALITY_HEX[quality] or "ffffffff") .. "|Hitem:" .. itemId .. "::::::::|h[" .. name .. "]|h|r"
        local classId = item and item.classId or 15
        return name, link, quality, item and item.level or 1, item and item.requiredLevel or 0, CLASS_NAMES[classId] or "Miscellaneous", "",
            item and item.stack or 1, "", item and item.icon or QUESTION_MARK, item and item.sellPrice or 0, classId, item and item.subclassId or 0
    end
    G.GetItemInfo = itemInfo
    G.GetItemInfoInstant = function(target)
        local itemId, item = getItem(target)
        if not itemId then return nil end
        local classId = item and item.classId or 15
        return itemId, CLASS_NAMES[classId] or "Miscellaneous", "", "", item and item.icon or QUESTION_MARK, classId, item and item.subclassId or 0
    end
    G.GetItemIcon = function(target) local _, item = getItem(target); return item and item.icon or QUESTION_MARK end
    G.ITEM_QUALITY_COLORS = {}
    for quality, hex in pairs(QUALITY_HEX) do
        local r, g, b = tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255
        G.ITEM_QUALITY_COLORS[quality] = { r = r, g = g, b = b, hex = "|c" .. hex, color = G.CreateColor(r, g, b) }
    end
    G.GetItemCount = function(itemId) return profile.items[tonumber(itemId) or 0] or 0 end
    G.GetItemSpell = function() return nil end
    G.GetItemCooldown = function(target)
        local itemId = tonumber(target) or tonumber(tostring(target or ""):match("item:(%d+)"))
        local item = itemId and game.items and game.items[itemId]
        local usedAt = itemId and game.itemUsedAt and game.itemUsedAt[itemId]
        if item and item.useEffect and usedAt and sim.now - usedAt < item.useEffect.cooldown then return usedAt, item.useEffect.cooldown, 1 end
        return 0, 0, 1
    end
    G.IsQuestItem = function() return false end
    local getItemCooldown = G.GetItemCooldown -- held here: the client (and so strict mode) has no global one
    G.C_Item = { GetItemInfo = itemInfo, GetItemInfoInstant = G.GetItemInfoInstant, GetItemIconByID = G.GetItemIcon,
        GetItemCount = G.GetItemCount, GetItemSpell = function() return nil end, GetItemCooldown = function(target) local start, duration = getItemCooldown(target); return start, duration, true end,
        RequestLoadItemDataByID = function(itemId) sim.addTimer(0.05, function() sim.fireEvent("ITEM_DATA_LOAD_RESULT", itemId, true) end) end,
        IsItemDataCachedByID = function() return true end, GetItemNameByID = function(itemId) return (itemInfo(itemId)) end,
        GetItemQualityByID = function(target) local _, item = getItem(target); return item and item.quality or 1 end, DoesItemExistByID = function() return true end,
        -- Using an item by its link, id or name, as the game's secure buttons do (type "item": SecureCmdUseItem)
        UseItemByName = function(target)
            local itemId = getItem(target)
            if not itemId and type(target) == "string" then
                for id, item in pairs(game.items or {}) do
                    if item.name == target then itemId = id; break end
                end
            end
            if itemId then game.useItem(itemId) end
        end,
        -- Weapons and armour are put on, not used
        IsEquippableItem = function(target) local _, item = getItem(target); return item ~= nil and (item.classId == 2 or item.classId == 4) end,
        IsEquippedItem = function() return false end,
        -- An item class's name ("Weapon"), and a subclass's with whether it is a kind of armour one wears
        -- (cloth, leather, mail, plate)
        GetItemClassInfo = function(classId) return game.itemClasses and game.itemClasses[classId] or nil end,
        GetItemSubClassInfo = function(classId, subClassId)
            local name = game.itemSubClasses and game.itemSubClasses[classId] and game.itemSubClasses[classId][subClassId]
            if name == nil then return nil end
            return name, classId == 4 and subClassId >= 1 and subClassId <= 4
        end }
    -- An item's tooltip data, as the client gives it to the game's tooltip code (GameTooltip:SetItemByID and
    -- SetHyperlink are its Lua): the name in its quality's colour, "Quest Item" for one, its use, and its price
    local function itemTooltip(itemId)
        local name, link, quality, _, requiredLevel, _, _, _, _, _, sellPrice, classId = itemInfo(itemId)
        if not name then return nil end
        local enum, makeColor = G.Enum or {}, G.CreateColor
        local lineTypes, dataTypes = enum.TooltipDataLineType or {}, enum.TooltipDataType or {}
        local hex = QUALITY_HEX[quality] or "ffffffff"
        local qualityColor = makeColor and makeColor(tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, tonumber(hex:sub(7, 8), 16) / 255) or nil
        local white = makeColor and makeColor(1, 1, 1) or nil
        local lines = { { type = lineTypes.ItemName or 0, leftText = name, leftColor = qualityColor } }
        if classId == 12 then lines[#lines + 1] = { type = lineTypes.None or 0, leftText = G.ITEM_BIND_QUEST or "Quest Item", leftColor = white } end
        if (requiredLevel or 0) > 1 then lines[#lines + 1] = { type = lineTypes.None or 0, leftText = string.format(G.ITEM_MIN_LEVEL or "Requires Level %d", requiredLevel), leftColor = white } end
        local item = game.items and game.items[itemId]
        if item and item.useEffect then
            lines[#lines + 1] = { type = lineTypes.None or 0, leftText = (G.ITEM_SPELL_TRIGGER_ONUSE or "Use:") .. " " .. tostring(item.useEffect.text or "Use the item."), leftColor = makeColor and makeColor(0, 1, 0) or nil, wrapText = true }
        end
        tooltipDataCount = tooltipDataCount + 1
        return { type = dataTypes.Item or 0, id = itemId, hyperlink = link, lines = lines, dataInstanceID = tooltipDataCount }
    end
    G.C_TooltipInfo.GetItemByID = function(itemId) return itemTooltip(tonumber(itemId)) end
    G.C_TooltipInfo.GetHyperlink = function(link)
        local itemId = type(link) == "string" and tonumber(link:match("item:(%d+)"))
        if itemId then return itemTooltip(itemId) end
        local questId = type(link) == "string" and tonumber(link:match("quest:(%d+)"))
        if questId then
            local title = G.C_QuestLog.GetTitleForQuestID and G.C_QuestLog.GetTitleForQuestID(questId) or ("Quest " .. questId)
            tooltipDataCount = tooltipDataCount + 1
            local lineTypes, dataTypes = (G.Enum or {}).TooltipDataLineType or {}, (G.Enum or {}).TooltipDataType or {}
            return { type = dataTypes.Quest or 0, id = questId, lines = { { type = lineTypes.QuestTitle or 0, leftText = title, leftColor = G.CreateColor and G.CreateColor(1, 0.82, 0) or nil } }, dataInstanceID = tooltipDataCount }
        end
        return nil
    end
    G.C_Container = { GetContainerNumSlots = function() return 16 end, GetContainerItemInfo = function() return nil end,
        GetContainerItemID = function() return nil end, GetContainerNumFreeSlots = function() return 16, 0 end }
    -- Spells: their real names and icons (the game's SpellName and SpellMisc tables, as the action bars read them);
    -- known: the profile's, and the class's own (those its action bars hold)
    local actions = require("actions")
    local function spellName(spellId) return actions.getSpellName(spellId) or ("Spell " .. tostring(spellId)) end
    local function spellIcon(spellId) return actions.getSpellIcon(spellId) or 136243 end
    G.GetSpellInfo = function(spellId) return spellName(spellId), nil, spellIcon(spellId), 0, 0, 0, spellId end
    G.C_Spell = { GetSpellName = spellName, GetSpellInfo = function(spellId) return { name = spellName(spellId), spellID = spellId, iconID = spellIcon(spellId) } end,
        GetSpellTexture = spellIcon, IsSpellDataCached = function() return true end, RequestLoadSpellData = function() end }
    G.IsSpellKnown = function(spellId)
        spellId = tonumber(spellId)
        return spellId ~= nil and (profile.spells[spellId] == true or actions.isClassSpell(profile.class, spellId))
    end
    G.C_SpellBook = G.C_SpellBook or {}
    G.C_SpellBook.IsSpellKnown = G.IsSpellKnown
    G.C_SpellBook.IsSpellInSpellBook = G.IsSpellKnown
    G.IsPlayerSpell = G.IsSpellKnown
    G.IsSpellKnownOrOverridesKnown = G.IsSpellKnown
    G.C_SkillInfo = {
        GetSkillLineInfoByID = function(skillId) local rank = profile.professions[skillId]; if rank then return { skillLineRank = rank, rank = rank, maxRank = 300 } end end,
        GetNumSkillLines = function() local count = 0; for _ in pairs(profile.professions) do count = count + 1 end; return count end,
        GetSkillLineInfo = function() return nil end,
    }
    G.GetNumSkillLines = G.C_SkillInfo.GetNumSkillLines
    G.GetSkillLineInfo = function() return nil end
    G.GetProfessions = function() return nil end
    G.C_TradeSkillUI = { GetProfessionInfoBySkillLineID = function(skillId) local rank = profile.professions[skillId]; return { skillLevel = rank or 0, maxSkillLevel = 300, professionName = "" } end,
        GetTradeSkillLine = function() return 0, "", 0, 0 end }
    G.C_Reputation = { GetFactionDataByID = function(factionId)
        local value = profile.reputations[factionId] or 0
        return { factionID = factionId, name = "Faction " .. factionId, reaction = value >= 3000 and 5 or 4, currentStanding = value, currentReactionThreshold = 0, nextReactionThreshold = 3000 }
    end, GetNumFactions = function() return 0 end, IsFactionParagon = function() return false end }
    G.GetFactionInfoByID = function(factionId)
        local data = G.C_Reputation.GetFactionDataByID(factionId)
        return data.name, "", data.reaction, 0, 3000, data.currentStanding
    end
    G.C_Seasons = { HasActiveSeason = function() return false end, GetActiveSeason = function() return nil end }
    G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix) game.prefixes = game.prefixes or {}; game.prefixes[prefix] = true; return true end,
        IsAddonMessagePrefixRegistered = function(prefix) return game.prefixes ~= nil and game.prefixes[prefix] == true end,
        SendAddonMessage = function(prefix, text, channel, target)
            sim.addonMessages = sim.addonMessages or {}
            table.insert(sim.addonMessages, { prefix = prefix, text = text, channel = channel, target = target, time = sim.now })
            return true
        end,
        SendAddonMessageLogged = function(...) return G.C_ChatInfo.SendAddonMessage(...) end,
        GetChannelName = function() return 0 end,
    }
    G.RegisterAddonMessagePrefix = G.C_ChatInfo.RegisterAddonMessagePrefix
    G.SendAddonMessage = G.C_ChatInfo.SendAddonMessage
    -- Said aloud: the message as the game shows it, and CHAT_MSG_SAY for addons
    -- (with the game's whole interface its chat windows show it, from the event; without, the simulator's chat does)
    local chatLineId = 0
    G.SendChatMessage = function(text, chatType, languageId)
        text = tostring(text or "")
        local name = game.profile.name or "You"
        if not sim.isWholeInterface then sim.print(string.format("[%s] says: %s", name, text)) end
        chatLineId = chatLineId + 1
        -- text, sender, language, channel, target, flags, zone channel, channel index, channel name, language id,
        -- line id, sender's GUID: as the client sends a message's echo
        sim.fireEvent("CHAT_MSG_" .. tostring(chatType or "SAY"):upper(), text, name .. "-" .. (game.profile.realm or ""), "", "", name,
            "", 0, 0, "", languageId or 0, chatLineId, G.UnitGUID and G.UnitGUID("player") or "")
    end
    G.C_ChatInfo.SendChatMessage = G.SendChatMessage
    -- No CombatLogGetCurrentEventInfo: on this client the combat log is secure only (C_CombatLogSecure)
    G.C_Texture = { GetAtlasInfo = function(atlas) return W.getAtlasInfo and W.getAtlasInfo(atlas) end }
    G.C_PartyInfo = { IsPartyFull = function() return false end, GetMinLevel = function() return 1 end }
    G.C_LFGList = {}
    G.C_PvP = { IsWarModeDesired = function() return false end,
        -- No outdoor PvP battle on any map here: nil, whatever the docs say, or the map shows "Next Battle: 00:00:00"
        GetOutdoorPvPWaitTime = function() return nil end }
    G.C_EventUtils = { IsEventValid = function(event) return type(event) == "string" and sim.isEventKnown(event) end }
    -- The calendar, as a realm with no events in it shows it: the month viewed (moved by SetMonth and SetAbsMonth,
    -- this month at first), each month's days and the weekday of its 1st (1 Sunday), the dates it can show (a year
    -- back, a year on), and no events, holidays or invites. Asked to open, it answers with CALENDAR_UPDATE_EVENT_LIST.
    local viewedMonth, viewedYear
    local function today() return G.C_DateAndTime.GetCurrentCalendarTime() end
    local function monthInfo(month, year)
        while month > 12 do month, year = month - 12, year + 1 end
        while month < 1 do month, year = month + 12, year - 1 end
        local first = os.date("*t", os.time({ year = year, month = month, day = 1, hour = 12 }))
        local nextFirst = os.time({ year = month == 12 and year + 1 or year, month = month == 12 and 1 or month + 1, day = 1, hour = 12 })
        local last = os.date("*t", nextFirst - 86400)
        return { month = month, year = year, numDays = last.day, firstWeekday = first.wday }
    end
    local function viewed()
        if not viewedMonth then
            local now = today()
            viewedMonth, viewedYear = now.month, now.year
        end
        return viewedMonth, viewedYear
    end
    local function dateOffsetYears(years)
        local now = today()
        local date = { year = now.year + years, month = now.month, monthDay = now.monthDay, weekday = now.weekday, hour = 0, minute = 0 }
        return date
    end
    G.C_Calendar = {
        GetDate = G.C_DateAndTime.GetCurrentCalendarTime,
        GetMonthInfo = function(offset)
            local month, year = viewed()
            return monthInfo(month + (offset or 0), year)
        end,
        SetMonth = function(offset)
            local month, year = viewed()
            local info = monthInfo(month + (offset or 0), year)
            viewedMonth, viewedYear = info.month, info.year
        end,
        SetAbsMonth = function(month, year) viewedMonth, viewedYear = month, year end,
        GetMinDate = function() return dateOffsetYears(-1) end,
        GetMaxDate = function() return dateOffsetYears(1) end,
        GetMaxCreateDate = function() return dateOffsetYears(1) end,
        GetNumDayEvents = function() return 0 end,
        GetDayEvent = function() return nil end,
        GetHolidayInfo = function() return nil end,
        GetNumPendingInvites = function() return 0 end,
        GetFirstPendingInvite = function() return nil end,
        GetNumGuildEvents = function() return 0 end,
        GetEventIndex = function() return nil end,
        GetEventInfo = function() return nil end,
        GetRaidInfo = function() return nil end,
        IsEventOpen = function() return false end,
        IsActionPending = function() return false end,
        AreNamesReady = function() return true end,
        CanAddEvent = function() return false end,
        OpenCalendar = function()
            sim.addTimer(0, function() sim.fireEvent("CALENDAR_UPDATE_EVENT_LIST") end)
        end,
    }
    G.C_StorePublic = { IsEnabled = function() return false end }
    G.C_AchievementInfo = {}
    G.C_PlayerInfo = { GetPlayerMythicPlusRatingSummary = function() return nil end, IsPlayerNPERestricted = function() return false end }
    G.C_Debug = {}
end

return game
