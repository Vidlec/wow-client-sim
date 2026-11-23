-- Records what happens to the character, for AddonSim to replay: the events addons see (quests, places, fights,
-- loot, groups, quest givers) with the state that goes with them (where the character is, its level, its quest
-- log's counts, the creature it is fighting). Off until "/asrec start"; "/asrec stop" ends the session, and the
-- game writes it to SavedVariables on logout or /reload. Nothing is sent anywhere. "/asrec api" records the client's API
-- itself (its functions and widget methods), for AddonSim to match this client exactly.
AddonSimRecording = AddonSimRecording or { sessions = {} }

local MAX_ENTRIES = 20000
local POSITION_SECONDS = 2
local EVENTS = {
    "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "QUEST_WATCH_LIST_CHANGED",
    "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_LEVEL_UP", "PLAYER_ENTERING_WORLD",
    "GOSSIP_SHOW", "GOSSIP_CLOSED", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED",
    "PLAYER_TARGET_CHANGED", "UNIT_DIED", "NAME_PLATE_UNIT_ADDED", "LOOT_OPENED", "CHAT_MSG_LOOT", "BAG_UPDATE_DELAYED",
    "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
}

local session, startedAt, lastPositionAt = nil, 0, 0
local frame = CreateFrame("Frame")

local function isPlain(value)
    local valueType = type(value)
    if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then return false end
    return not (issecretvalue and issecretvalue(value))
end

local function getPosition()
    local uiMapId = C_Map.GetBestMapForUnit("player")
    local position = uiMapId and C_Map.GetPlayerMapPosition(uiMapId, "player")
    if not position then return nil end
    local x, y = position:GetXY()
    return { uiMapId = uiMapId, x = math.floor(x * 10000 + 0.5) / 10000, y = math.floor(y * 10000 + 0.5) / 10000,
        facing = GetPlayerFacing and GetPlayerFacing() or nil }
end

---The quest log as counts: each quest's id, whether complete, and each objective's type and counts.
local function getQuestLog()
    local quests = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID then
            local objectives = {}
            for objectiveIndex, objective in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
                objectives[objectiveIndex] = { type = objective.type, text = objective.text, fulfilled = objective.numFulfilled,
                    required = objective.numRequired, finished = objective.finished }
            end
            quests[#quests + 1] = { questId = info.questID, isComplete = C_QuestLog.IsComplete(info.questID), objectives = objectives }
        end
    end
    return quests
end

local function getTarget()
    if not UnitExists("target") then return nil end
    local guid = UnitGUID("target")
    if not isPlain(guid) then return nil end
    return { guid = guid, name = isPlain(UnitName("target")) and UnitName("target") or nil, isDead = UnitIsDead("target") == true,
        isTappedByOthers = UnitIsTapDenied("target") == true, canAttack = UnitCanAttack("player", "target") == true }
end

local function record(event, ...)
    if not session or #session.entries >= MAX_ENTRIES then return end
    local args = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        args[index] = isPlain(value) and value or false
    end
    local entry = { t = math.floor((GetTime() - startedAt) * 100 + 0.5) / 100, e = event, a = args, level = UnitLevel("player"),
        position = getPosition() }
    if event:find("^QUEST") or event == "UNIT_QUEST_LOG_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        entry.questLog = getQuestLog()
    end
    if event == "PLAYER_TARGET_CHANGED" or event == "UNIT_DIED" then entry.target = getTarget() end
    session.entries[#session.entries + 1] = entry
end

frame:SetScript("OnEvent", function(_, event, ...) record(event, ...) end)
frame:SetScript("OnUpdate", function()
    if session and GetTime() - lastPositionAt >= POSITION_SECONDS then
        lastPositionAt = GetTime()
        record("POSITION")
    end
end)

local function start()
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    local version, build = GetBuildInfo()
    session = { character = { name = UnitName("player"), realm = GetRealmName(), race = race, class = class, level = UnitLevel("player"),
        faction = UnitFactionGroup("player") }, locale = GetLocale(), client = version, build = build, startedAt = date("%Y-%m-%d %H:%M"),
        entries = {} }
    table.insert(AddonSimRecording.sessions, session)
    startedAt, lastPositionAt = GetTime(), 0
    for _, event in ipairs(EVENTS) do pcall(frame.RegisterEvent, frame, event) end
    record("START")
    print("|cffffd100AddonSim Recorder|r: recording. /asrec stop to end; /reload or log out to save it.")
end

local function stop()
    if not session then return end
    record("STOP")
    frame:UnregisterAllEvents()
    print(string.format("|cffffd100AddonSim Recorder|r: stopped, %d entries. /reload or log out to save it.", #session.entries))
    session = nil
end

-- The client's API, as it really is: every global function, each C_ namespace's functions, and each widget type's
-- methods, with the build they belong to. AddonSim reads it to have exactly this client's functions and no others.
local WIDGET_FRAMES = { "Frame", "Button", "CheckButton", "EditBox", "ScrollFrame", "Slider", "StatusBar", "Cooldown", "GameTooltip",
    "MessageFrame", "Model", "PlayerModel", "ColorSelect", "SimpleHTML" }

local function getMethods(object)
    local methods, meta = {}, getmetatable(object)
    local index = meta and meta.__index
    if type(index) == "table" then
        for name, value in pairs(index) do
            if type(name) == "string" and type(value) == "function" then methods[#methods + 1] = name end
        end
    end
    table.sort(methods)
    return methods
end

local function recordApi()
    local version, build = GetBuildInfo()
    local api = { client = version, build = build, interface = select(4, GetBuildInfo()), recordedAt = date("%Y-%m-%d %H:%M"),
        globals = {}, namespaces = {}, widgets = {} }
    -- The client's numeric constants too (LE_LFG_CATEGORY_LFD, NUM_LE_LFG_CATEGORYS...): numbers and true/false only,
    -- never text (that is the game's strings, which the simulator reads from its own tables)
    api.constants = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and (type(value) == "number" or type(value) == "boolean") then
            api.constants[name] = value
        end
    end
    for name, value in pairs(_G) do
        if type(name) == "string" then
            if type(value) == "function" then
                api.globals[#api.globals + 1] = name
            elseif type(value) == "table" and name:match("^C_") then
                local functions = {}
                for key, member in pairs(value) do
                    if type(key) == "string" and type(member) == "function" then functions[#functions + 1] = key end
                end
                table.sort(functions)
                api.namespaces[name] = functions
            end
        end
    end
    table.sort(api.globals)
    local parent = CreateFrame("Frame")
    for _, widgetType in ipairs(WIDGET_FRAMES) do
        local isMade, widget = pcall(CreateFrame, widgetType, nil, parent)
        if isMade and widget then api.widgets[widgetType] = getMethods(widget) end
    end
    api.widgets.Texture = getMethods(parent:CreateTexture())
    api.widgets.FontString = getMethods(parent:CreateFontString())
    api.widgets.MaskTexture = getMethods(parent:CreateMaskTexture())
    if parent.CreateLine then api.widgets.Line = getMethods(parent:CreateLine()) end
    if Minimap then api.widgets.Minimap = getMethods(Minimap) end
    -- Every console variable with the client's default for it (the interface reads many as it loads: the text
    -- scale, the action bars' settings): only defaults, never what this account has set
    api.cvars = {}
    local cvarCount = 0
    local isListed, commands = pcall(C_Console and C_Console.GetAllCommands)
    if isListed and type(commands) == "table" then
        local cvarType = Enum and Enum.ConsoleCommandType and Enum.ConsoleCommandType.Cvar or 0
        for _, command in ipairs(commands) do
            if command.commandType == cvarType and type(command.command) == "string" then
                local hasDefault, default = pcall(C_CVar.GetCVarDefault, command.command)
                if hasDefault and default ~= nil then
                    api.cvars[command.command] = default
                    cvarCount = cvarCount + 1
                end
            end
        end
    end
    AddonSimRecording.api = api
    local namespaceCount = 0
    for _ in pairs(api.namespaces) do namespaceCount = namespaceCount + 1 end
    print(string.format("|cffffd100AddonSim Recorder|r: recorded this client's API (%s, build %s): %d global functions, %d C_ namespaces, %d CVar defaults. /reload to save it.",
        tostring(version), tostring(build), #api.globals, namespaceCount, cvarCount))
end
-- How the client behaves where its code and documentation do not say, for AddonSim to do the same: small
-- experiments with frames of its own (made, measured, hidden again), and what some functions answer for this
-- character. "/asrec probe"; saved with the rest on /reload (AddonSimRecording.probe). Each check runs on its own:
-- one that fails is noted and the others still run.
local function plainCopy(value, depth)
    depth = depth or 0
    if type(value) == "table" then
        if depth > 4 then return "<table>" end
        local copy = {}
        for key, item in pairs(value) do
            -- (a colour's methods and the like left out: only what it holds)
            if (type(key) == "string" or type(key) == "number") and type(item) ~= "function" then copy[key] = plainCopy(item, depth + 1) end
        end
        return copy
    end
    if type(value) == "function" or type(value) == "userdata" then return "<" .. type(value) .. ">" end
    if not isPlain(value) and value ~= nil then return "<secret>" end
    return value
end
local function pack(...) return { n = select("#", ...), ... } end
local function answers(fn, ...)
    local result = pack(pcall(fn, ...))
    if not result[1] then return { error = tostring(result[2]) } end
    local values = { count = result.n - 1 }
    for index = 2, result.n do values[index - 1] = plainCopy(result[index]) end
    return values
end

local PROBES = {}
-- The order OnShow and OnHide run in: a window and the frames in it (and in those)
PROBES.showOrder = function()
    local order = {}
    local window = CreateFrame("Frame", nil, UIParent)
    window:Hide()
    local child = CreateFrame("Frame", nil, window)
    local grandchild = CreateFrame("Frame", nil, child)
    local secondChild = CreateFrame("Frame", nil, window)
    for name, frame in pairs({ window = window, child = child, grandchild = grandchild, secondChild = secondChild }) do
        frame:SetScript("OnShow", function() order[#order + 1] = "show " .. name end)
        frame:SetScript("OnHide", function() order[#order + 1] = "hide " .. name end)
    end
    window:Show()
    window:Hide()
    -- A child shown inside its OnShow handler's parent run: does the child's OnShow still come?
    local nested = {}
    local outer = CreateFrame("Frame", nil, UIParent)
    outer:Hide()
    local inner = CreateFrame("Frame", nil, outer)
    inner:Hide()
    inner:SetScript("OnShow", function() nested[#nested + 1] = "inner shown" end)
    outer:SetScript("OnShow", function() nested[#nested + 1] = "outer shown"; inner:Show() end)
    outer:Show()
    outer:Hide()
    return { order = order, nested = nested }
end
-- Frame levels: what Raise and Lower do (and to the children), what SetFrameLevel does to children, a toplevel frame
-- shown, a new child's level
PROBES.levels = function()
    local strata = "FULLSCREEN_DIALOG"
    local function highestOther(except)
        local highest, frame = 0, EnumerateFrames()
        while frame do
            if frame ~= except and not frame:IsForbidden() and frame:IsVisible() and frame:GetFrameStrata() == strata then
                highest = math.max(highest, frame:GetFrameLevel())
            end
            frame = EnumerateFrames(frame)
        end
        return highest
    end
    local result = {}
    local low = CreateFrame("Frame", nil, UIParent)
    low:SetFrameStrata(strata)
    low:SetFrameLevel(5)
    local lowChild = CreateFrame("Frame", nil, low)
    local lowChild2 = CreateFrame("Frame", nil, low)
    lowChild2:SetFrameLevel(20)
    local high = CreateFrame("Frame", nil, UIParent)
    high:SetFrameStrata(strata)
    high:SetFrameLevel(100)
    local hiddenHigher = CreateFrame("Frame", nil, UIParent)
    hiddenHigher:SetFrameStrata(strata)
    hiddenHigher:SetFrameLevel(300)
    hiddenHigher:Hide()
    result.newChildLevel = lowChild:GetFrameLevel()
    result.before = { low = low:GetFrameLevel(), lowChild = lowChild:GetFrameLevel(), lowChild2 = lowChild2:GetFrameLevel(), high = high:GetFrameLevel() }
    result.highestOtherShownBefore = highestOther(low)
    low:Raise()
    result.afterRaise = { low = low:GetFrameLevel(), lowChild = lowChild:GetFrameLevel(), lowChild2 = lowChild2:GetFrameLevel(), high = high:GetFrameLevel() }
    low:Lower()
    result.afterLower = { low = low:GetFrameLevel(), lowChild = lowChild:GetFrameLevel(), lowChild2 = lowChild2:GetFrameLevel() }
    low:SetFrameLevel(50)
    result.afterSetLevel50 = { low = low:GetFrameLevel(), lowChild = lowChild:GetFrameLevel(), lowChild2 = lowChild2:GetFrameLevel() }
    local top = CreateFrame("Frame", nil, UIParent)
    top:SetFrameStrata(strata)
    top:SetToplevel(true)
    top:SetFrameLevel(2)
    top:Hide()
    top:Show()
    result.toplevelShownLevel = top:GetFrameLevel()
    for _, frame in ipairs({ low, high, hiddenHigher, top }) do frame:Hide() end
    return result
end
-- Attributes: whether ClearAttribute runs OnAttributeChanged, and with what
PROBES.attributes = function()
    local calls = {}
    local frame = CreateFrame("Frame")
    frame:SetScript("OnAttributeChanged", function(_, name, value) calls[#calls + 1] = { name = name, value = plainCopy(value) } end)
    frame:SetAttribute("probe", 1)
    if frame.ClearAttribute then frame:ClearAttribute("probe") end
    return { calls = calls, afterClear = plainCopy(frame:GetAttribute("probe")) }
end
-- Font strings: ClearText leaves nil or ""; GetFontInfo's shape
PROBES.fonts = function()
    local text = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetText("probe")
    if text.ClearText then text:ClearText() end
    local result = { afterClearText = plainCopy(text:GetText()), afterClearTextType = type(text:GetText()) }
    if GetFontInfo then result.gameFontNormal = answers(GetFontInfo, "GameFontNormal") end
    result.cursorVisible = IsCursorVisible and IsCursorVisible()
    text:Hide()
    return result
end
-- The character: stats as the character window reads them, and what is worn (to tell stats from gear)
PROBES.character = function()
    local result = { race = answers(UnitRace, "player"), class = answers(UnitClass, "player"), level = UnitLevel("player"),
        faction = answers(UnitFactionGroup, "player"), stats = {}, worn = {} }
    for index = 1, 5 do result.stats[index] = answers(UnitStat, "player", index) end
    for name, fn in pairs({ UnitArmor = UnitArmor, UnitAttackPower = UnitAttackPower, UnitRangedAttackPower = UnitRangedAttackPower,
        UnitAttackSpeed = UnitAttackSpeed, UnitDamage = UnitDamage, UnitRangedDamage = UnitRangedDamage, UnitDefenseSkill = UnitDefenseSkill }) do
        result[name] = answers(fn, "player")
    end
    for name, fn in pairs({ GetCritChance = GetCritChance, GetRangedCritChance = GetRangedCritChance, GetDodgeChance = GetDodgeChance,
        GetParryChance = GetParryChance, GetBlockChance = GetBlockChance, GetManaRegen = GetManaRegen, GetExpertise = GetExpertise,
        GetHitModifier = GetHitModifier, GetShieldBlock = GetShieldBlock, GetHealthRegen = GetHealthRegen, GetEffectiveDefenseSkill = GetEffectiveDefenseSkill }) do
        result[name] = answers(fn)
    end
    result.GetSpellCritChance2 = answers(GetSpellCritChance, 2)
    result.GetSpellBonusDamage2 = answers(GetSpellBonusDamage, 2)
    result.GetCombatRatingBonus1 = answers(GetCombatRatingBonus, 1)
    for slot = 0, 30 do
        local itemId = GetInventoryItemID("player", slot)
        if itemId then result.worn[tostring(slot)] = itemId end
    end
    for _, name in ipairs({ "AmmoSlot", "HeadSlot", "Prof0ToolSlot", "Prof1Gear1Slot", "CookingToolSlot", "FishingGear1Slot", "Bag0Slot", "ReagentBag0Slot" }) do
        result["slot " .. name] = answers(GetInventorySlotInfo, name)
    end
    return result
end
-- Classes and races as the client numbers them
PROBES.classes = function()
    local result = { GetNumClasses = answers(GetNumClasses), byIndex = {} }
    for index = 1, 13 do result.byIndex[index] = answers(GetClassInfo, index) end
    result.creatureClass6 = answers(C_CreatureInfo.GetClassInfo, 6)
    result.creatureRace5 = answers(C_CreatureInfo.GetRaceInfo, 5)
    if C_SpecializationInfo and C_SpecializationInfo.GetAllClassIDs then result.allClassIds = answers(C_SpecializationInfo.GetAllClassIDs) end
    return result
end
-- Achievements: which of Forever's two copies of the class achievements this client shows, and the legacy track
PROBES.achievements = function()
    local result = { canShow = answers(CanShowAchievementUI), categories = answers(GetCategoryList),
        completed = answers(GetNumCompletedAchievements), points = answers(GetTotalAchievementPoints) }
    for _, id in ipairs({ 61502, 63972, 61994, 63978 }) do result["achievement " .. id] = answers(GetAchievementInfo, id) end
    result.druidCategory = answers(GetCategoryNumAchievements, 15577)
    for index = 1, 6 do result["druid " .. index] = answers(GetAchievementInfo, 15577, index) end
    result.legacyRenown = answers(C_MajorFactions.GetCurrentRenownLevel, 2802)
    if C_MajorFactions.GetMajorFactionData then result.legacyFaction = answers(C_MajorFactions.GetMajorFactionData, 2802) end
    return result
end
-- The encounter journal and other lookups
PROBES.lookups = function()
    local result = {}
    if EJ_GetNumTiers then result.ejTiers = answers(EJ_GetNumTiers) end
    if EJ_GetInstanceByIndex then result.ejFirstDungeon = answers(EJ_GetInstanceByIndex, 1, false) end
    if EJ_GetCurrentTier then result.ejCurrentTier = answers(EJ_GetCurrentTier) end
    if GetFileIDFromPath then result.questionMark = answers(GetFileIDFromPath, "Interface\\Icons\\INV_Misc_QuestionMark") end
    if UnitExists("party1") then result.party1Range = answers(UnitInRange, "party1"); result.party1Distance = answers(UnitDistanceSquared, "party1") end
    result.playerDistance = answers(UnitDistanceSquared, "player")
    result.actionBarToggles = answers(GetActionBarToggles)
    return result
end

-- The layout cache (layout-local.txt): a named frame of the recorder's own, made as this file loads, watched through
-- the login. "/asrec probe" moves it (StartMoving) to a known place, so after a /reload the client has saved it; the
-- next "/asrec probe" reports when it was put back: right after CreateFrame, at the recorder's ADDON_LOADED, PLAYER_LOGIN,
-- PLAYER_ENTERING_WORLD or a second later, by which point, and whether a SetPoint made at ADDON_LOADED survived.
local PLACED_NAME = "AddonSimRecorderPlacedProbe"
local placedProbe = CreateFrame("Frame", PLACED_NAME, UIParent)
placedProbe:SetSize(40, 40)
placedProbe:SetMovable(true)
local placedTimeline = {}
local function notePlaced(moment)
    local point = pack(placedProbe:GetPoint(1))
    local x, y = placedProbe:GetCenter()
    placedTimeline[#placedTimeline + 1] = { moment = moment, isUserPlaced = placedProbe:IsUserPlaced(), points = placedProbe:GetNumPoints(),
        point = point[1], relativeTo = point[2] and (point[2].GetName and point[2]:GetName() or "?") or nil, relativePoint = point[3],
        x = point[4], y = point[5], centerX = x, centerY = y }
end
notePlaced("created")
do
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("ADDON_LOADED")
    watcher:RegisterEvent("PLAYER_LOGIN")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function(self, event, name)
        if event == "ADDON_LOADED" then
            if name ~= "AddonSimRecorder" then return end
            notePlaced("ADDON_LOADED")
            -- Placed by the addon's own code now: does the client's restore come later and win?
            placedProbe:ClearAllPoints()
            placedProbe:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 7, 9)
            notePlaced("ADDON_LOADED after SetPoint")
        elseif event == "PLAYER_LOGIN" then
            notePlaced("PLAYER_LOGIN")
        else
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            notePlaced("PLAYER_ENTERING_WORLD")
            C_Timer.After(1, function() notePlaced("a second after PLAYER_ENTERING_WORLD") end)
        end
    end)
end
PROBES.userPlaced = function()
    local result = { lastLogin = placedTimeline }
    -- A frame moved: user-placed? named and not? How is it anchored after StopMovingOrSizing?
    for _, name in ipairs({ "AddonSimRecorderMovedProbe", false }) do
        local moved = CreateFrame("Frame", name or nil, UIParent)
        moved:SetSize(30, 30)
        moved:SetPoint("CENTER", UIParent, "CENTER", 50, 60)
        moved:SetMovable(true)
        local key = name and "named" or "unnamed"
        result[key .. "Before"] = moved:IsUserPlaced()
        result[key .. "Start"] = answers(moved.StartMoving, moved)
        result[key .. "DuringIsUserPlaced"] = moved:IsUserPlaced()
        moved:StopMovingOrSizing()
        result[key .. "After"] = moved:IsUserPlaced()
        local point = pack(moved:GetPoint(1))
        result[key .. "PointAfter"] = { point[1], point[2] and (point[2].GetName and point[2]:GetName() or "?") or "nil", point[3], point[4], point[5],
            count = moved:GetNumPoints() }
        moved:SetUserPlaced(false)
        moved:Hide()
    end
    -- Not movable: does StartMoving or SetUserPlaced(true) refuse?
    local fixed = CreateFrame("Frame", nil, UIParent)
    fixed:SetSize(10, 10)
    fixed:SetPoint("CENTER")
    result.notMovableStart = answers(fixed.StartMoving, fixed)
    fixed:StopMovingOrSizing()
    result.notMovableUserPlacedAfterStart = fixed:IsUserPlaced()
    result.notMovableSetUserPlaced = answers(fixed.SetUserPlaced, fixed, true)
    result.notMovableIsUserPlaced = fixed:IsUserPlaced()
    fixed:SetUserPlaced(false)
    fixed:Hide()
    result.dontSaveDefault = answers(fixed.GetDontSavePosition, fixed)
    -- The frame watched at login, moved to a known place for the next /reload to save
    placedProbe:ClearAllPoints()
    placedProbe:SetPoint("CENTER", UIParent, "CENTER", 123, -45)
    placedProbe:StartMoving()
    placedProbe:StopMovingOrSizing()
    result.placedProbeNow = { isUserPlaced = placedProbe:IsUserPlaced(), center = { placedProbe:GetCenter() } }
    return result
end
-- A scroll frame's range: told (OnScrollRangeChanged) at once when its child is set or grows, or at the next frame?
PROBES.scrollRange = function()
    local scroll = CreateFrame("ScrollFrame", nil, UIParent)
    scroll:SetSize(100, 100)
    scroll:SetPoint("CENTER")
    local told = {}
    scroll:SetScript("OnScrollRangeChanged", function(_, x, y) told[#told + 1] = { x = x, y = y } end)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(100, 300)
    scroll:SetScrollChild(child)
    local result = { toldAtSetScrollChild = #told, rangeAtOnce = scroll:GetVerticalScrollRange() }
    child:SetHeight(400)
    result.toldAtGrow = #told
    result.rangeAfterGrow = scroll:GetVerticalScrollRange()
    scroll:SetVerticalScroll(250)
    child:SetHeight(150)
    result.scrollAfterShrink = scroll:GetVerticalScroll() -- (clamped by the client, or left?)
    C_Timer.After(0.05, function() -- (a few frames on)
        result.toldNextFrames = told
        result.scrollAfterShrinkLater = scroll:GetVerticalScroll()
        scroll:Hide()
    end)
    return result
end
-- The world map's zoom: instant (as its OnLoad sets) or gliding; GetTickTime
PROBES.mapZoom = function()
    local result = { tickTime = answers(GetTickTime), framerate = answers(GetFramerate) }
    if WorldMapFrame and WorldMapFrame.ShouldZoomInstantly then result.worldMapInstant = answers(WorldMapFrame.ShouldZoomInstantly, WorldMapFrame) end
    return result
end
-- A tooltip shown with no lines: does it show? With SetAllowShowWithNoLines(true)?
PROBES.tooltips = function()
    local tooltip = CreateFrame("GameTooltip", "AddonSimRecorderProbeTooltip", UIParent, "GameTooltipTemplate")
    tooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    tooltip:Show()
    local result = { emptyShown = tooltip:IsShown(), emptyLines = tooltip:NumLines() }
    tooltip:Hide()
    if tooltip.SetAllowShowWithNoLines then
        tooltip:SetAllowShowWithNoLines(true)
        tooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
        tooltip:Show()
        result.emptyShownWhenAllowed = tooltip:IsShown()
        tooltip:Hide()
    end
    if tooltip.GetCustomLineSpacing then result.customLineSpacingDefault = answers(tooltip.GetCustomLineSpacing, tooltip) end
    tooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
    tooltip:AddLine("probe")
    tooltip:Show()
    tooltip:ClearLines()
    result.shownAfterClearLines = tooltip:IsShown()
    tooltip:Hide()
    return result
end

local function runProbes()
    local version, build = GetBuildInfo()
    local probe = { client = version, build = build, recordedAt = date("%Y-%m-%d %H:%M"), results = {} }
    local failed = 0
    for name, check in pairs(PROBES) do
        local isDone, result = pcall(check)
        probe.results[name] = isDone and result or { error = tostring(result) }
        if not isDone then failed = failed + 1 end
    end
    AddonSimRecording.probe = probe
    print(string.format("|cffffd100AddonSim Recorder|r: probed this client (%d checks, %d failed). /reload to save it.", (function()
        local count = 0
        for _ in pairs(PROBES) do count = count + 1 end
        return count
    end)(), failed))
end

-- What the minimap draws its own icons (the player's arrow, herbs and ores being tracked) over: a square on the
-- arrow, drawn four ways in turn, four seconds each. Whether the arrow and icons show on top of it tells where an
-- addon's marks can go to never hide them. "/asrec under"; nothing is kept.
local function testMinimapLayers()
    if not Minimap then return end
    local steps = {
        { "red", { 1, 0, 0 }, "a texture of the minimap itself, BACKGROUND layer", function() return Minimap:CreateTexture(nil, "BACKGROUND", nil, 7) end },
        { "yellow", { 1, 1, 0 }, "a texture of the minimap itself, ARTWORK layer", function() return Minimap:CreateTexture(nil, "ARTWORK") end },
        { "blue", { 0.2, 0.4, 1 }, "a texture of the minimap itself, OVERLAY layer", function() return Minimap:CreateTexture(nil, "OVERLAY") end },
        { "green", { 0, 1, 0 }, "a frame on the minimap (how addons' marks are drawn now)", function()
            local holder = CreateFrame("Frame", nil, Minimap)
            holder:SetAllPoints(Minimap)
            holder:SetFrameLevel(Minimap:GetFrameLevel() + 1)
            return holder:CreateTexture(nil, "ARTWORK")
        end },
    }
    local function show(index)
        local step = steps[index]
        if not step then
            print("|cffffd100AddonSim Recorder|r: done. Tell Claude which colours the arrow and the herb or ore icons showed on top of.")
            return
        end
        local square = step[4]()
        square:SetColorTexture(step[2][1], step[2][2], step[2][3], 0.85)
        square:SetSize(70, 70)
        square:SetPoint("CENTER", Minimap, "CENTER")
        print(string.format("|cffffd100AddonSim Recorder|r: %d/4 |cff%02x%02x%02x%s|r square: %s.", index,
            step[2][1] * 255, step[2][2] * 255, step[2][3] * 255, step[1], step[3]))
        C_Timer.After(4, function()
            square:Hide()
            show(index + 1)
        end)
    end
    print("|cffffd100AddonSim Recorder|r: stand near a herb or ore with its tracking on. Watch the middle of the minimap: does your arrow (and any herb or ore icon) show on top of each square?")
    C_Timer.After(2, function() show(1) end)
end

SLASH_ADDONSIMRECORDER1 = "/asrec"
SlashCmdList.ADDONSIMRECORDER = function(text)
    text = (text or ""):lower()
    if text == "start" then start()
    elseif text == "stop" then stop()
    elseif text == "clear" then AddonSimRecording.sessions = {}; print("|cffffd100AddonSim Recorder|r: recordings cleared.")
    elseif text == "api" then recordApi()
    elseif text == "probe" then runProbes()
    elseif text == "under" then testMinimapLayers()
    else print("|cffffd100AddonSim Recorder|r: /asrec start | stop | clear | api | probe | under  (" .. #AddonSimRecording.sessions .. " sessions kept)") end
end
