-- Achievements, from the client's own tables (Achievement, Achievement_Category, CriteriaTree, Criteria, fetched for
-- the build like the others): the categories, each achievement's title, points, icon and criteria, as the game's
-- achievement window and addons read them. Earned as the character earns them, for what the simulator knows of:
-- reaching a level, completing a quest, a number of quests, another achievement; the rest stay to do. What is
-- earned is kept with the character (profile.achievements: the date) and announced (ACHIEVEMENT_EARNED,
-- CRITERIA_UPDATE). Statistics (an achievement with flag 1) show what they count, or "--".
local sim = require("sim")
local bit = require("bit")

local achievements = {}

local CRITERIA = { REACH_LEVEL = 5, COMPLETE_ACHIEVEMENT = 8, COMPLETE_QUEST_COUNT = 9, COMPLETE_QUEST = 27 }
local OPERATOR = { SINGLE = 0, SINGLE_NOT_COMPLETED = 1, ALL = 4, SUM_CHILDREN = 5, MAX_CHILD = 6, COUNT_DIRECT_CHILDREN = 7, ANY = 8, SUM_CHILDREN_WEIGHT = 9 }
local STATISTIC_FLAG = 1
-- Forever's tables hold two whole sets of the class, profession, dungeon, raid and season achievements, one flagged
-- 0x08000000, the other 0x10000000. The client (measured: /asrec probe) finds both by id, but lists and counts the
-- first only. config "achievementSet": "a" (that one, the default) or "b"
local SET_FLAGS = { a = 0x08000000, b = 0x10000000 }
-- Tracking achievements (0x100000): the client neither lists nor counts them (measured: 111 counted of 199)
local TRACKING_FLAG = 0x100000
local MODIFIER = { CLASS = 26 }
local STATISTICS_ROOT, HIDDEN_CATEGORY = 1, 15425

local data -- read on first use
local function load(game)
    if data then return data end
    local read = game.readDb2 or function() return nil end
    data = { byId = {}, categories = {}, categoryById = {}, inCategory = {}, trees = {}, children = {}, criteria = {}, supersededBy = {},
        modifiers = {}, modifierChildren = {} }
    local wantedSet = (sim.config and sim.config.achievementSet == "b") and "b" or "a"
    local otherFlag = SET_FLAGS[wantedSet == "a" and "b" or "a"]
    for _, row in ipairs(read("Achievement_Category") or {}) do
        local category = { id = tonumber(row.ID), parent = tonumber(row.Parent) or -1, order = tonumber(row.Ui_order) or 0, name = row.Name_lang or "" }
        data.categoryById[category.id] = category
        data.categories[#data.categories + 1] = category
    end
    for _, row in ipairs(read("Achievement") or {}) do
        local achievement = {
            id = tonumber(row.ID), name = row.Title_lang or "", description = row.Description_lang or "", reward = row.Reward_lang or "",
            category = tonumber(row.Category) or 0, points = tonumber(row.Points) or 0, flags = tonumber(row.Flags) or 0,
            order = tonumber(row.Ui_order) or 0, icon = tonumber(row.IconFileID) or 0, faction = tonumber(row.Faction) or -1,
            supersedes = tonumber(row.Supercedes) or 0, tree = tonumber(row.Criteria_tree) or 0,
        }
        data.byId[achievement.id] = achievement
        -- (listed, counted and earned: the shown set, no tracking ones)
        achievement.isListed = bit.band(achievement.flags, otherFlag) == 0 and bit.band(achievement.flags, TRACKING_FLAG) == 0
        if achievement.isListed then
            data.inCategory[achievement.category] = data.inCategory[achievement.category] or {}
            table.insert(data.inCategory[achievement.category], achievement)
            if achievement.supersedes ~= 0 then data.supersededBy[achievement.supersedes] = achievement.id end
        end
    end
    for _, list in pairs(data.inCategory) do
        table.sort(list, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
    end
    for _, row in ipairs(read("CriteriaTree") or {}) do
        local tree = { id = tonumber(row.ID), parent = tonumber(row.Parent) or 0, amount = tonumber(row.Amount) or 0,
            operator = tonumber(row.Operator) or 0, criteria = tonumber(row.CriteriaID) or 0, order = tonumber(row.OrderIndex) or 0,
            flags = tonumber(row.Flags) or 0, description = row.Description_lang or "" }
        data.trees[tree.id] = tree
        if tree.parent ~= 0 then
            data.children[tree.parent] = data.children[tree.parent] or {}
            table.insert(data.children[tree.parent], tree)
        end
    end
    for _, list in pairs(data.children) do table.sort(list, function(a, b) return a.order < b.order end) end
    for _, row in ipairs(read("Criteria") or {}) do
        data.criteria[tonumber(row.ID)] = { type = tonumber(row.Type) or -1, asset = tonumber(row.Asset) or 0, modifier = tonumber(row.Modifier_tree_ID) or 0 }
    end
    for _, row in ipairs(read("ModifierTree") or {}) do
        local modifier = { id = tonumber(row.ID), parent = tonumber(row.Parent) or 0, operator = tonumber(row.Operator) or 0,
            type = tonumber(row.Type) or 0, asset = tonumber(row.Asset) or 0 }
        data.modifiers[modifier.id] = modifier
        if modifier.parent ~= 0 then
            data.modifierChildren[modifier.parent] = data.modifierChildren[modifier.parent] or {}
            table.insert(data.modifierChildren[modifier.parent], modifier)
        end
    end
    return data
end

function achievements.install(G, game)
    local profile = function() return game.profile end
    local function factionMatches(achievement)
        if achievement.faction == -1 then return true end
        return (achievement.faction == 0) == (profile().faction == "Horde")
    end
    -- What the character had earned when it logged in is worked out the first time anything asks (not at boot: the
    -- tables are read then), quietly
    local isInitialized, isInitializing = false, false
    local function earned()
        local current = profile()
        current.achievements = current.achievements or {}
        if not isInitialized and not isInitializing then
            isInitializing = true
            achievements.check(true)
            isInitializing, isInitialized = false, true
        end
        return current.achievements
    end

    -- A tree's progress: done, how far, how far it has to go
    local evaluate
    local function completedQuestCount()
        local count = 0
        for _ in pairs(game.completed) do count = count + 1 end
        return count
    end
    -- A criterion's conditions (its modifier tree): a group holds when all its parts do (any, for operator 8); of
    -- the conditions themselves the class is known, the rest (a difficulty, a map, an aura...) are taken as not met,
    -- so nothing is earned that the character could not have
    local function modifierHolds(modifier, depth)
        if not modifier or (depth or 0) > 12 then return false end
        local children = data.modifierChildren[modifier.id]
        if modifier.type == 0 then
            if not children then return true end
            local isAny = modifier.operator == 8
            for _, child in ipairs(children) do
                local holds = modifierHolds(child, (depth or 0) + 1)
                if isAny and holds then return true end
                if not isAny and not holds then return false end
            end
            return not isAny
        elseif modifier.type == MODIFIER.CLASS then
            return modifier.asset == profile().classId
        end
        return false
    end
    local function criteriaProgress(tree)
        local criteria = data.criteria[tree.criteria]
        local needed = math.max(tree.amount, 1)
        if not criteria then return false, 0, needed end
        if criteria.modifier ~= 0 and not modifierHolds(data.modifiers[criteria.modifier]) then return false, 0, needed end
        local quantity = 0
        if criteria.type == CRITERIA.REACH_LEVEL then
            quantity, needed = profile().level or 1, math.max(tree.amount, criteria.asset, 1)
        elseif criteria.type == CRITERIA.COMPLETE_QUEST then
            quantity, needed = game.completed[criteria.asset] and 1 or 0, 1
        elseif criteria.type == CRITERIA.COMPLETE_QUEST_COUNT then
            quantity = completedQuestCount()
        elseif criteria.type == CRITERIA.COMPLETE_ACHIEVEMENT then
            quantity, needed = earned()[tostring(criteria.asset)] and 1 or 0, 1
        end
        return quantity >= needed, quantity, needed
    end
    evaluate = function(tree, depth)
        depth = depth or 0
        if not tree or depth > 12 then return false, 0, 1 end
        local children = data.children[tree.id]
        if not children or #children == 0 then return criteriaProgress(tree) end
        local doneCount, sum, best = 0, 0, 0
        for _, child in ipairs(children) do
            local isDone, quantity = evaluate(child, depth + 1)
            if isDone then doneCount = doneCount + 1 end
            sum, best = sum + quantity, math.max(best, quantity)
        end
        local operator = tree.operator
        if operator == OPERATOR.SUM_CHILDREN or operator == OPERATOR.SUM_CHILDREN_WEIGHT then
            return sum >= math.max(tree.amount, 1), sum, math.max(tree.amount, 1)
        elseif operator == OPERATOR.MAX_CHILD then
            return best >= math.max(tree.amount, 1), best, math.max(tree.amount, 1)
        elseif operator == OPERATOR.ANY then
            return doneCount > 0, doneCount, 1
        elseif operator == OPERATOR.COUNT_DIRECT_CHILDREN then
            local needed = tree.amount > 0 and tree.amount or #children
            return doneCount >= needed, doneCount, needed
        end
        return doneCount == #children, doneCount, #children
    end
    -- The criteria the window lists: the root's children, or the root itself when it is one criterion
    local function criteriaOf(achievement)
        local root = data.trees[achievement.tree]
        if not root then return {} end
        local children = data.children[root.id]
        if children and #children > 0 then return children end
        return { root }
    end
    local function isStatistic(achievement) return bit.band(achievement.flags, STATISTIC_FLAG) ~= 0 end
    local function completionOf(achievement)
        local date = earned()[tostring(achievement.id)]
        if date then return true, date[2], date[3], date[1] % 100 end
        return false
    end

    -- Earned now: what the character has done that it had not (a level, a quest), dated today and announced (not at
    -- login, isQuiet: a character comes in with what it had earned, no toasts)
    function achievements.check(isQuiet)
        load(game)
        local list = earned()
        local changed = true
        local today = os.date("*t")
        while changed do -- (one earned may complete another, "complete these achievements")
            changed = false
            for id, achievement in pairs(data.byId) do
                if not list[tostring(id)] and achievement.isListed and not isStatistic(achievement) and achievement.category ~= HIDDEN_CATEGORY
                    and factionMatches(achievement) and data.trees[achievement.tree] then
                    if evaluate(data.trees[achievement.tree]) then
                        list[tostring(id)] = { today.year, today.month, today.day }
                        changed = true
                        if not isQuiet then sim.fireEvent("ACHIEVEMENT_EARNED", id, false) end
                    end
                end
            end
        end
        if not isQuiet then sim.fireEvent("CRITERIA_UPDATE") end
    end

    local function categoryList(isStatistics)
        load(game)
        local function isUnderStatistics(category)
            local current, depth = category, 0
            while current and depth < 10 do
                if current.id == STATISTICS_ROOT then return true end
                current, depth = data.categoryById[current.parent], depth + 1
            end
            return false
        end
        -- Every category of the kind, by its order and then its id, "Do Not Display" among them: as the client lists
        -- them (measured); the window builds its tree from each one's parent
        local list = {}
        for _, category in ipairs(data.categories) do
            if category.id ~= STATISTICS_ROOT and isUnderStatistics(category) == isStatistics then list[#list + 1] = category end
        end
        table.sort(list, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
        local ordered = {}
        for index, category in ipairs(list) do ordered[index] = category.id end
        return ordered
    end
    local function shownIn(categoryId)
        load(game)
        local shown = {}
        for _, achievement in ipairs(data.inCategory[tonumber(categoryId)] or {}) do
            if factionMatches(achievement) then shown[#shown + 1] = achievement end
        end
        return shown
    end
    local function find(first, second)
        load(game)
        if second ~= nil then return shownIn(first)[tonumber(second)] end
        return data.byId[tonumber(first)]
    end

    G.CanShowAchievementUI = function() return next(load(game).byId) ~= nil end
    G.GetCategoryList = function() return categoryList(false) end
    G.GetStatisticsCategoryList = function() return categoryList(true) end
    G.GetGuildCategoryList = function() return {} end
    G.GetCategoryInfo = function(categoryId)
        local category = load(game).categoryById[tonumber(categoryId)]
        if not category then return nil end
        -- (the statistics' own top categories hang from the hidden root: the window takes them as top ones)
        local parent = category.parent == STATISTICS_ROOT and -1 or category.parent
        return category.name, parent, 0
    end
    G.GetCategoryNumAchievements = function(categoryId, includeAll)
        local total, done = 0, 0
        for _, achievement in ipairs(shownIn(categoryId)) do
            total = total + 1
            if completionOf(achievement) then done = done + 1 end
        end
        return total, done, total - done
    end
    G.GetCategoryAchievementPoints = function(categoryId)
        local points = 0
        for _, achievement in ipairs(shownIn(categoryId)) do if completionOf(achievement) then points = points + achievement.points end end
        return points
    end
    G.GetAchievementInfo = function(first, second)
        local achievement = find(first, second)
        if not achievement then return end -- (no values at all, as the client: not even a nil)
        local isDone, month, day, year = completionOf(achievement)
        return achievement.id, achievement.name, achievement.points, isDone, month, day, year, achievement.description,
            achievement.flags, achievement.icon, achievement.reward, false, isDone, isDone and profile().name or nil, isStatistic(achievement)
    end
    G.GetAchievementCategory = function(id) local achievement = find(id); return achievement and achievement.category end
    G.GetAchievementNumCriteria = function(id)
        local achievement = find(id)
        return achievement and #criteriaOf(achievement) or 0
    end
    G.GetAchievementCriteriaInfo = function(id, index)
        local achievement = find(id)
        local tree = achievement and criteriaOf(achievement)[tonumber(index)]
        if not tree then error("GetAchievementCriteriaInfo: no criterion " .. tostring(index), 2) end
        local isDone, quantity, needed = evaluate(tree)
        local criteria = data.criteria[tree.criteria]
        local text = tree.description ~= "" and tree.description or achievement.name
        return text, criteria and criteria.type or 0, isDone, quantity, needed, profile().name, tree.flags,
            criteria and criteria.asset or 0, string.format("%d / %d", quantity, needed), tree.criteria, true
    end
    G.GetAchievementCriteriaInfoByID = function(id, criteriaId)
        local achievement = find(id)
        for index, tree in ipairs(achievement and criteriaOf(achievement) or {}) do
            if tree.criteria == tonumber(criteriaId) then return G.GetAchievementCriteriaInfo(id, index) end
        end
    end
    G.GetPreviousAchievement = function(id)
        local achievement = find(id)
        return achievement and achievement.supersedes ~= 0 and achievement.supersedes or nil
    end
    G.GetNextAchievement = function(id)
        local nextId = load(game).supersededBy[tonumber(id)]
        if not nextId then return nil end
        return nextId, (completionOf(data.byId[nextId]))
    end
    G.GetAchievementLink = function(id)
        local achievement = find(id)
        if not achievement then return nil end
        local isDone, month, day, year = completionOf(achievement)
        local guid = G.UnitGUID and G.UnitGUID("player") or "Player-0-00000000"
        return string.format("|cffffff00|Hachievement:%d:%s:%d:%d:%d:%d:0:0:0:0|h[%s]|h|r", achievement.id, guid,
            isDone and 1 or 0, month or 0, day or 0, year or 0, achievement.name)
    end
    G.GetStatistic = function(id)
        local achievement = find(id)
        local root = achievement and data.trees[achievement.tree]
        if not root then return "--" end
        local _, quantity = evaluate(root)
        return (quantity and quantity > 0) and tostring(quantity) or "--"
    end
    G.GetTotalAchievementPoints = function()
        load(game)
        local points = 0
        for id in pairs(earned()) do local achievement = data.byId[tonumber(id)]; if achievement then points = points + achievement.points end end
        return points
    end
    G.GetNumCompletedAchievements = function()
        load(game)
        local total, done = 0, 0
        for _, achievement in pairs(data.byId) do
            if achievement.isListed and not isStatistic(achievement) and achievement.category ~= HIDDEN_CATEGORY and factionMatches(achievement) then
                total = total + 1
                if completionOf(achievement) then done = done + 1 end
            end
        end
        return total, done
    end
    G.GetLatestCompletedAchievements = function()
        local list = {}
        for id, date in pairs(earned()) do list[#list + 1] = { tonumber(id), date[1] * 10000 + date[2] * 100 + date[3] } end
        table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] > b[1] end)
        local ids = {}
        for index = 1, math.min(5, #list) do ids[index] = list[index][1] end
        return unpack(ids)
    end
    G.HasCompletedAnyAchievement = function() return next(earned()) ~= nil end

    -- The search (the Legacy window's challenge list, the achievement window's search box): every shown achievement
    -- whose title or description has the text, all of them for none; ready a moment later, as the client says
    -- (ACHIEVEMENT_SEARCH_UPDATED)
    local filtered = {}
    G.SetAchievementSearchString = function(text)
        load(game)
        local wanted = tostring(text or ""):lower()
        filtered = {}
        for _, achievement in pairs(data.byId) do
            if achievement.isListed and not isStatistic(achievement) and achievement.category ~= HIDDEN_CATEGORY and factionMatches(achievement)
                and (wanted == "" or achievement.name:lower():find(wanted, 1, true) or achievement.description:lower():find(wanted, 1, true)) then
                filtered[#filtered + 1] = achievement.id
            end
        end
        table.sort(filtered)
        sim.addTimer(0, function() sim.fireEvent("ACHIEVEMENT_SEARCH_UPDATED") end)
        return true
    end
    G.ClearAchievementSearchString = function() filtered = {} end
    G.GetNumFilteredAchievements = function() return #filtered end
    G.GetFilteredAchievementID = function(index) return filtered[tonumber(index)] end

    -- Forever's Legacy (its reward track is a renown faction): the window, its challenges (the achievements) and
    -- its tree open once the character has a renown level on it. profile.legacyRenown: 0 for a new character
    local LEGACY_FACTION = 2802
    local majorFactions = G.C_MajorFactions or {}
    G.C_MajorFactions = majorFactions
    local originalRenownLevel = majorFactions.GetCurrentRenownLevel
    majorFactions.GetCurrentRenownLevel = function(factionId)
        if tonumber(factionId) == LEGACY_FACTION then return tonumber(profile().legacyRenown) or 0 end
        return originalRenownLevel and originalRenownLevel(factionId) or 0
    end
    local originalFactionData = majorFactions.GetMajorFactionData
    majorFactions.GetMajorFactionData = function(factionId)
        if tonumber(factionId) ~= LEGACY_FACTION then return originalFactionData and originalFactionData(factionId) end
        -- (as the client answers it, measured: /asrec probe)
        local level = tonumber(profile().legacyRenown) or 0
        return { name = "Legacy Track", factionID = LEGACY_FACTION, expansionID = 0, bountySetID = 0, isUnlocked = level > 0,
            description = "", uiPriority = 0, renownLevel = level, renownReputationEarned = tonumber(profile().legacyRenownProgress) or 0,
            renownLevelThreshold = 1, maxLevel = 90, textureKit = "storm", celebrationSoundKit = 0, renownFanfareSoundKitID = 0,
            hideRenownLevelUpToast = true, useJourneyUnlockToast = false, highlights = {}, playerCompanionID = 0,
            factionFontColor = { baseTag = "STORM_MAJOR_FACTION_COLOR", color = G.CreateColor and G.CreateColor(0.2588, 0.5569, 0.9961, 1) or nil } }
    end

    -- Checked when the character gets somewhere: a level, a quest handed in
    -- (the first time, what was earned before it is worked out as things stood just before: the level it had, the
    -- quest not yet handed in, so only what this earns is announced)
    -- (nothing before the login: the character is being set up then, its saved or asked-for level put in)
    local previous = sim.onEventFired
    local isLoggedIn = false
    sim.onEventFired = function(event, ...)
        if previous then previous(event, ...) end
        if event == "PLAYER_LOGIN" then isLoggedIn = true end
        if not isLoggedIn then return end
        if event == "PLAYER_LEVEL_CHANGED" then
            if not isInitialized then
                local oldLevel, level = ..., profile().level
                profile().level = oldLevel or level
                earned()
                profile().level = level
            end
            achievements.check()
        elseif event == "QUEST_TURNED_IN" then
            if not isInitialized then
                local questId = ...
                local wasDone = game.completed[questId]
                game.completed[questId] = nil
                earned()
                game.completed[questId] = wasDone
            end
            achievements.check()
        end
    end
end

return achievements
