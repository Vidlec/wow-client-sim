-- A party of simulated players: the game's unit functions answer for party1..party4, members have a place on
-- the map and a quest log, and the game's own party progress (C_TooltipInfo.GetQuestPartyProgress) lists their
-- counts. A member may run an addon that talks to the player's addons on its channel: those are registered through
-- the plugin API (lua/plugins.lua), by a project's
-- plugins; the party tells a member's addon when it joins, its quests change, it leaves, or the player's addons send
-- the group a message.
local sim = require("sim")
local game = require("game")
local plugins = require("plugins")

local party = { members = {} }
local G = sim.G

local MAX_MEMBERS = 4

-- The classic classes: the game's file token, name and id
local CLASSES = {
    WARRIOR = { "Warrior", 1 },
    PALADIN = { "Paladin", 2 },
    HUNTER = { "Hunter", 3 },
    ROGUE = { "Rogue", 4 },
    PRIEST = { "Priest", 5 },
    SHAMAN = { "Shaman", 7 },
    MAGE = { "Mage", 8 },
    WARLOCK = { "Warlock", 9 },
    DRUID = { "Druid", 11 },
}
party.CLASSES = CLASSES

---@return table? member The member a unit token ("party2") or name stands for
local function findMember(unit)
    if type(unit) ~= "string" then
        return nil
    end
    local index = tonumber(unit:match("^party(%d)$") or unit:match("^raid(%d+)$") or "")
    if index then
        return party.members[index]
    end
    local name = unit:match("^[^-]+")
    for _, member in ipairs(party.members) do
        if member.name == name then
            return member
        end
    end
    return nil
end
party.findMember = findMember

-- What a member's addon does is its own (lua/plugins.lua: party addons registered by the simulator and by a
-- project's plugins); the party only tells it what happened
local function questChanged(member, questId)
    if member.isOnline then
        plugins.callPartyAddon(member, "onQuestChanged", questId)
    end
end

local function rosterChanged()
    game.profile.groupSize = #party.members
    sim.fireEvent("GROUP_ROSTER_UPDATE")
    sim.touch()
end

---Adds a member. Unset fields take the player's: realm, level, place.
---@param spec { name: string, class: string?, level: number?, race: string?, addon: string?, uiMapId: number?, x: number?, y: number? }
---addon: a registered party addon ("Questie", or a project's), or "none"; left out, the default one registered
---(plugins.defaultPartyAddon), else "none"
---@return table? member, string? problem
function party.add(spec)
    if #party.members >= MAX_MEMBERS then
        return nil, "the party is full"
    end
    if type(spec.name) ~= "string" or spec.name == "" or findMember(spec.name) or spec.name == game.profile.name then
        return nil, "needs a name nobody in the group has"
    end
    local classFile = (spec.class or "WARRIOR"):upper()
    if not CLASSES[classFile] then
        return nil, "unknown class " .. tostring(spec.class)
    end
    local profile = game.profile
    local member = {
        name = spec.name,
        realm = spec.realm,
        classFile = classFile,
        level = spec.level or profile.level,
        race = spec.race or "Orc",
        addon = spec.addon or plugins.defaultPartyAddon(),
        isOnline = spec.isOnline ~= false,
        uiMapId = spec.uiMapId or profile.uiMapId,
        x = spec.x or (profile.x + 0.01),
        y = spec.y or (profile.y + 0.01),
        quests = {},
        guid = string.format("Player-1-%08X", 0x100 + #party.members),
        doneQuestIds = spec.doneQuestIds or {}, -- quests they handed in (a member's addon may tell of them)
        data = {}, -- the member's addon's own
    }
    table.insert(party.members, member)
    rosterChanged()
    -- Their addon greets the group as it does on joining (its hello, its log)
    plugins.callPartyAddon(member, "onJoin")
    return member
end

function party.remove(name)
    for index, member in ipairs(party.members) do
        if member.name == name then
            table.remove(party.members, index)
            rosterChanged()
            plugins.callPartyAddon(member, "onLeave")
            return true
        end
    end
    return false, "no such member"
end

---Gives a member a quest, with nothing done yet.
function party.acceptQuest(name, questId)
    local member = findMember(name)
    if not member then
        return false, "no such member"
    end
    local objectives = game.composeObjectives(questId)
    member.quests[questId] = { objectives = objectives, isComplete = #objectives == 0 }
    questChanged(member, questId)
    sim.fireEvent("UNIT_QUEST_LOG_CHANGED", "party" .. party.indexOf(member))
    sim.fireEvent("QUEST_LOG_UPDATE")
    return true
end

function party.abandonQuest(name, questId)
    local member = findMember(name)
    if not member or not member.quests[questId] then
        return false, "not in their log"
    end
    member.quests[questId] = nil
    questChanged(member, questId)
    sim.fireEvent("UNIT_QUEST_LOG_CHANGED", "party" .. party.indexOf(member))
    sim.fireEvent("QUEST_LOG_UPDATE")
    return true
end

---Moves a member's count on one objective (by default the first unfinished one).
function party.progress(name, questId, objectiveIndex, amount)
    local member = findMember(name)
    local quest = member and member.quests[questId]
    if not quest then
        return false, "not in their log"
    end
    local objective = quest.objectives[objectiveIndex or 1]
    if not objectiveIndex then
        for _, candidate in ipairs(quest.objectives) do
            if candidate.fulfilled < candidate.required then
                objective = candidate
                break
            end
        end
    end
    if not objective then
        return false, "no such objective"
    end
    objective.fulfilled = math.max(0, math.min(objective.required, objective.fulfilled + (amount or 1)))
    local isComplete = true
    for _, candidate in ipairs(quest.objectives) do
        if candidate.fulfilled < candidate.required then
            isComplete = false
        end
    end
    quest.isComplete = isComplete
    questChanged(member, questId)
    sim.fireEvent("UNIT_QUEST_LOG_CHANGED", "party" .. party.indexOf(member))
    sim.fireEvent("QUEST_LOG_UPDATE")
    return true
end

function party.complete(name, questId)
    local member = findMember(name)
    local quest = member and member.quests[questId]
    if not quest then
        return false, "not in their log"
    end
    for index, objective in ipairs(quest.objectives) do
        party.progress(name, questId, index, objective.required)
    end
    quest.isComplete = true
    questChanged(member, questId)
    return true
end

function party.moveTo(name, uiMapId, x, y)
    local member = findMember(name)
    if not member then
        return false, "no such member"
    end
    member.uiMapId, member.x, member.y = uiMapId or member.uiMapId, x or member.x, y or member.y
    sim.touch()
    return true
end

---Puts a member some yards from the player (north-west by default), wherever the zone boundary falls.
function party.placeNear(name, yards, angle)
    local member = findMember(name)
    if not member then
        return false, "no such member"
    end
    local continentId, north, west = game.getPlayerWorldPosition()
    if not continentId then
        return false, "the player has no place on a map"
    end
    angle = angle or math.rad(45)
    local uiMapId, x, y = game.findZoneAt(
        continentId,
        north + math.cos(angle) * (yards or 20),
        west + math.sin(angle) * (yards or 20),
        game.profile.uiMapId
    )
    if not uiMapId then
        return false, "no zone there"
    end
    return party.moveTo(name, uiMapId, x, y)
end

function party.setOnline(name, isOnline)
    local member = findMember(name)
    if not member then
        return false, "no such member"
    end
    member.isOnline = isOnline ~= false
    sim.fireEvent("UNIT_CONNECTION", "party" .. party.indexOf(member), member.isOnline)
    sim.fireEvent("GROUP_ROSTER_UPDATE")
    return true
end

function party.indexOf(member)
    for index, candidate in ipairs(party.members) do
        if candidate == member then
            return index
        end
    end
end

---What the page shows and edits.
function party.describe()
    local list = {}
    for index, member in ipairs(party.members) do
        local quests = {}
        for questId, quest in pairs(member.quests) do
            local counts = {}
            for objectiveIndex, objective in ipairs(quest.objectives) do
                counts[objectiveIndex] = {
                    text = game.objectiveText(objective),
                    fulfilled = objective.fulfilled,
                    required = objective.required,
                }
            end
            quests[#quests + 1] = {
                questId = questId,
                title = G.C_QuestLog.GetTitleForQuestID(questId) or ("Quest " .. questId),
                isComplete = quest.isComplete,
                objectives = counts,
            }
        end
        table.sort(quests, function(first, second)
            return first.questId < second.questId
        end)
        list[index] = {
            unit = "party" .. index,
            name = member.name,
            class = member.classFile,
            level = member.level,
            addon = member.addon,
            isOnline = member.isOnline,
            uiMapId = member.uiMapId,
            x = member.x,
            y = member.y,
            quests = quests,
        }
    end
    return list
end

function party.install()
    local original = {}
    for _, name in ipairs({
        "UnitExists",
        "UnitName",
        "UnitNameUnmodified",
        "GetUnitName",
        "UnitFullName",
        "UnitClass",
        "UnitClassBase",
        "UnitLevel",
        "UnitEffectiveLevel",
        "UnitRace",
        "UnitGUID",
        "UnitIsConnected",
        "UnitIsPlayer",
        "UnitInParty",
        "UnitInRaid",
        "UnitIsGroupLeader",
        "UnitIsDeadOrGhost",
        "UnitIsUnit",
        "IsInGroup",
        "IsInRaid",
        "GetNumGroupMembers",
        "GetNumSubgroupMembers",
        "UnitFactionGroup",
        "UnitPlayerOrPetInParty",
    }) do
        original[name] = G[name]
    end
    local function memberOr(name, handler)
        G[name] = function(unit, ...)
            local member = findMember(unit)
            if member then
                return handler(member, unit, ...)
            end
            if original[name] then
                return original[name](unit, ...)
            end
        end
    end
    -- How far a member is: the squared distance in yards on the same continent (unknown elsewhere, or offline), and
    -- in range within 40 yards, as the party frames fade the ones further off
    local function distanceSquaredTo(member)
        if not member.isOnline and member.isOnline ~= nil then
            return nil
        end
        local continentId, north, west = game.getPlayerWorldPosition()
        local memberContinent, memberNorth, memberWest = game.mapToWorld(member.uiMapId, member.x, member.y)
        if not continentId or continentId ~= memberContinent then
            return nil
        end
        return (north - memberNorth) ^ 2 + (west - memberWest) ^ 2
    end
    G.UnitDistanceSquared = function(unit)
        if unit == "player" then
            return 0, true
        end
        local member = findMember(unit)
        local distanceSquared = member and distanceSquaredTo(member)
        if distanceSquared then
            return distanceSquared, true
        end
        return 0, false
    end
    G.UnitInRange = function(unit)
        local member = findMember(unit)
        if not member then
            return false, false
        end
        local distanceSquared = distanceSquaredTo(member)
        if not distanceSquared then
            return false, true
        end
        return distanceSquared <= 40 * 40, true
    end
    memberOr("UnitExists", function()
        return true
    end)
    memberOr("UnitName", function(member)
        return member.name, member.realm
    end)
    memberOr("UnitNameUnmodified", function(member)
        return member.name, member.realm
    end)
    memberOr("GetUnitName", function(member, _, showServer)
        return (showServer and member.realm) and (member.name .. "-" .. member.realm) or member.name
    end)
    memberOr("UnitFullName", function(member)
        return member.name, member.realm or game.profile.realm
    end)
    memberOr("UnitClass", function(member)
        local class = CLASSES[member.classFile]
        return class[1], member.classFile, class[2]
    end)
    memberOr("UnitClassBase", function(member)
        return member.classFile, CLASSES[member.classFile][2]
    end)
    memberOr("UnitLevel", function(member)
        return member.level
    end)
    memberOr("UnitEffectiveLevel", function(member)
        return member.level
    end)
    -- (as the client names them: the name shown, the race's file, its id; "Scourge" is shown as "Undead")
    memberOr("UnitRace", function(member)
        local race = require("game").RACES[member.race]
        if race then
            return race[2], member.race, race[1]
        end
        return member.race, member.race
    end)
    memberOr("UnitGUID", function(member)
        return member.guid
    end)
    memberOr("UnitIsConnected", function(member)
        return member.isOnline
    end)
    memberOr("UnitIsPlayer", function()
        return true
    end)
    memberOr("UnitInParty", function()
        return true
    end)
    memberOr("UnitInRaid", function()
        return nil
    end)
    memberOr("UnitIsGroupLeader", function()
        return false
    end)
    memberOr("UnitIsDeadOrGhost", function()
        return false
    end)
    memberOr("UnitPlayerOrPetInParty", function()
        return true
    end)
    -- A member's portrait, as the player's: their race's round icon (the game's party frames show it)
    local RACE_ICONS = { Scourge = "undead", NightElf = "nightelf", BloodElf = "bloodelf" }
    local setPortraitTexture = G.SetPortraitTexture
    G.SetPortraitTexture = function(texture, unit, ...)
        local member = findMember(unit)
        if member and type(texture) == "table" and texture.SetAtlas then
            local race = RACE_ICONS[member.race] or tostring(member.race or "orc"):lower()
            texture:SetAtlas("raceicon128-" .. race .. (member.sex == 3 and "-female" or "-male"))
            return
        end
        if setPortraitTexture then
            return setPortraitTexture(texture, unit, ...)
        end
    end
    memberOr("UnitFactionGroup", function()
        return G.UnitFactionGroup("player")
    end)
    G.UnitIsUnit = function(first, second)
        local firstMember, secondMember = findMember(first), findMember(second)
        if firstMember or secondMember then
            return firstMember == secondMember
        end
        return original.UnitIsUnit(first, second)
    end
    G.UnitInParty = function(unit)
        return unit == "player" and #party.members > 0 or findMember(unit) ~= nil
    end
    G.IsInGroup = function(category)
        if category == G.LE_PARTY_CATEGORY_INSTANCE then
            return false
        end
        return #party.members > 0 or (game.profile.groupSize or 0) > 0
    end
    G.IsInRaid = function()
        return false
    end
    -- In a party (never a raid here), every member is in the player's subgroup, as is the player
    G.UnitInSubgroup = function(unit)
        return findMember(unit) ~= nil or unit == "player" or (G.UnitIsUnit and G.UnitIsUnit(unit, "player")) == true
    end
    -- The player counts as one of the group, as in the game
    G.GetNumGroupMembers = function()
        return #party.members > 0 and #party.members + 1 or (game.profile.groupSize or 0)
    end
    G.GetNumSubgroupMembers = function()
        return #party.members > 0 and #party.members or (game.profile.groupSize or 0)
    end

    -- Where members are
    local getPlayerMapPosition = G.C_Map.GetPlayerMapPosition
    G.C_Map.GetPlayerMapPosition = function(uiMapId, unit)
        local member = findMember(unit)
        if not member then
            return getPlayerMapPosition(uiMapId, unit)
        end
        if uiMapId == member.uiMapId then
            return G.CreateVector2D(member.x, member.y)
        end
        local continentId, worldX, worldY = game.mapToWorld(member.uiMapId, member.x, member.y)
        if not continentId then
            return nil
        end
        local x, y = game.worldToMap(uiMapId, continentId, worldX, worldY) -- (both: "a and f()" keeps only f's first)
        if x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
            return G.CreateVector2D(x, y)
        end
    end

    -- Their quests, as the game tells them
    local isUnitOnQuest = G.C_QuestLog.IsUnitOnQuest
    G.C_QuestLog.IsUnitOnQuest = function(unit, questId)
        local member = findMember(unit)
        if member then
            return member.quests[questId] ~= nil
        end
        return isUnitOnQuest(unit, questId)
    end
    -- Their progress as the game's quest tooltip words it: a member's name, then their objectives. The game
    -- withholds it inside dungeons and raids. Its colors are the game's color objects, as the client's tooltip data
    -- has them (the tooltip calls :GetRGB() on them)
    G.C_TooltipInfo.GetQuestPartyProgress = function(questId)
        if game.profile.isInInstance then
            return nil
        end
        local lines = {}
        for _, member in ipairs(party.members) do
            local quest = member.quests[questId]
            if quest and member.isOnline then
                local class = G.RAID_CLASS_COLORS and G.RAID_CLASS_COLORS[member.classFile]
                lines[#lines + 1] = {
                    leftText = member.name,
                    leftColor = class and G.CreateColor(class.r, class.g, class.b) or G.CreateColor(1, 1, 1),
                }
                for _, objective in ipairs(quest.objectives) do
                    local isDone = objective.fulfilled >= objective.required
                    local shade = isDone and 0.5 or 1
                    lines[#lines + 1] = {
                        leftText = " - " .. game.objectiveText(objective),
                        leftColor = G.CreateColor(shade, shade, shade),
                    }
                end
            end
        end
        if #lines == 0 then
            return nil
        end
        return { type = G.Enum.TooltipDataType and G.Enum.TooltipDataType.Quest or 23, id = questId, lines = lines }
    end

    -- The player's addon messages: echoed back, as the game does, and heard by the members' addons
    local sendAddonMessage = G.C_ChatInfo.SendAddonMessage
    G.C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
        sendAddonMessage(prefix, text, channel, target)
        local isGroupChannel = channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT"
        if isGroupChannel and #party.members > 0 then
            G.C_Timer.After(0, function()
                sim.fireEvent(
                    "CHAT_MSG_ADDON",
                    prefix,
                    text,
                    channel,
                    game.profile.name .. "-" .. game.profile.realm,
                    ""
                )
            end)
        end
        -- Heard by the members' addons: the group's channels reach every member, a whisper only the one it names
        if isGroupChannel or channel == "WHISPER" then
            local message = { prefix = prefix, text = text, channel = channel, target = target }
            for _, member in ipairs(party.members) do
                local isHeard = isGroupChannel or (type(target) == "string" and target:match("^[^-]+") == member.name)
                if isHeard and member.isOnline then
                    plugins.callPartyAddon(member, "onMessage", message)
                end
            end
        end
        return true
    end
    G.SendAddonMessage = G.C_ChatInfo.SendAddonMessage
end

return party
