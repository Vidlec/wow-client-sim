-- Boots the simulator: builds the game from the config file (arg[2]), loads the addons, logs in, and returns
-- the request handlers. The server's host (host.lua) and the scripted runner (play.lua) both start here.
local root = arg[1] or "."
require("sim").root = root

local json = require("json")
local sim = require("sim")
local W = require("widgets")
local fonts = require("fonts")
require("templates")
local api = require("api")
local game = require("game")
local ui = require("ui")
local addons = require("addons")
local scene = require("scene")

local configPath = arg[2]
local bootcache = require("bootcache")
local function readBytes(path)
    local file = path and io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end
local function readJson(path)
    local content = readBytes(path)
    if not content then return nil end
    local isRead, value = pcall(json.decode, content)
    return isRead and value or nil
end
-- A large JSON file the server writes (the atlases, the map's highlights): kept decoded between runs (bootcache)
local function readKeptJson(path)
    if not path then return nil end
    return bootcache.rememberFile("json-" .. (path:match("([^/\\]+)$") or "file"), path, function() return readBytes(path) end,
        function(content) local isRead, value = pcall(json.decode, content); return isRead and value or {} end)
end
local config = readJson(configPath) or {}
-- A project's Lua module folders (its addonsim.config.ts luaPath), searched before the simulator's own: what its
-- scenarios and plugins require() (put in once: a reload boots again in the same process)
for index = #(config.luaPath or {}), 1, -1 do
    local entry = (config.luaPath[index]:gsub("\\", "/")) .. "/?.lua;"
    if not package.path:find(entry, 1, true) then package.path = entry .. package.path end
end
-- What the boot works out from unchanged files, kept between runs (cache/boot)
bootcache.setFolder(config.bootCacheDir or (root .. "/cache/boot"))
sim.screenWidth, sim.screenHeight = config.screenWidth or 1366, config.screenHeight or 768

-- The game's tables, read from the asset cache
local function readTable(name, columns)
    return game.readTable(config.db2Dir and (config.db2Dir .. "/" .. name .. ".csv"), columns)
end

-- Atlases: the server writes their info once; SetAtlas and C_Texture.GetAtlasInfo read it
local atlases = readKeptJson(config.atlasFile) or {}
-- The flavour's atlas variant (config.atlasVariant, false for none; Forever's "-c60" when the config does not say)
local atlasVariant = config.atlasVariant
if atlasVariant == nil then atlasVariant = "-c60" end
atlasVariant = atlasVariant and tostring(atlasVariant):lower() or nil
local atlasVariantEnd = atlasVariant and (atlasVariant:gsub("%p", "%%%0") .. "$")
function W.getAtlasInfo(name)
    -- The client picks an atlas's high-resolution member ("...-2x") when asked for the plain name
    local key = name and tostring(name):lower()
    -- WoW Forever's client (Camelot) answers a plain name with its own "-c60" variant where it has one, and does
    -- not know the "-c60" names themselves: the game's code asks for "common-stat-bar-BG", never "...-c60"
    if key and atlasVariant and key:find(atlasVariantEnd) then return nil end
    -- (its "-c60" variant may exist only in high resolution, "...-c60-2x", as the frames' metal edges do: sized by the
    -- modern atlas but drawn with the -c60 art, an edge left a see-through strip under the title)
    if key and atlasVariant and (atlases[key .. atlasVariant] or atlases[key .. atlasVariant .. "-2x"]) then key = key .. atlasVariant end
    local atlas, sizeFactor = key and atlases[key], 1
    if key and not atlas and atlases[key .. "-2x"] then
        atlas, sizeFactor = atlases[key .. "-2x"], 0.5 -- twice the pixels for the same size on screen
    end
    if not atlas then return nil end
    return { width = atlas.width * sizeFactor, height = atlas.height * sizeFactor, leftTexCoord = atlas.left, rightTexCoord = atlas.right,
        topTexCoord = atlas.top, bottomTexCoord = atlas.bottom, tilesHorizontally = atlas.tilesH, tilesVertically = atlas.tilesV,
        file = atlas.fdid, filename = atlas.fdid }
end

-- The startup runs most of its code once: compiled, it only cost the compiling (a fifth of the startup), and the
-- collector stepping through tables still being built (another). Both as usual again once the game runs (below)
local isJitOn = jit and jit.status and jit.status()
if isJitOn then jit.off() end
collectgarbage("setpause", 400)
local startedAt = os.clock()
api.install(config)
game.install()
-- The character's stats (the character window's): from race, class and level
require("stats").install(sim.G, game)
-- Achievements from the client's tables (read on first use), earned as the character goes
game.readDb2 = readTable
require("achievements").install(sim.G, game)
-- What the character wears (profile.equipment): the character window's slots, the inventory functions
require("equipment").install(sim.G, game)
-- The gamepad (C_GamePad, the interface style, binding contexts): after the game's stand-ins, which it replaces
require("gamepad").install()
-- The player's action slots
local actions = require("actions")
actions.install(sim.G, game)
addons.install()
fonts.installDefaults()
sim.config = config
-- The whole interface (blizzardAddons "all"): the game's own frames, so none of the simulator's stand-ins for them
sim.isWholeInterface = config.blizzardAddons == "all"
ui.install()
fonts.setMetrics(readJson(config.metricsFile) or {})
game.loadData(readTable)
game.mapHighlights = readKeptJson(config.mapHighlightsFile) or {}
-- The spells on the player's action slots: SpellName and SpellMisc, read on first use
actions.readTable = readTable
-- The character logging in, when the runner names one (bun run play --each-character): set before any addon loads,
-- as a login is; "race=Dwarf,class=WARRIOR,level=1"
local login = os.getenv("ADDONSIM_LOGIN")
if login and login ~= "" then
    local changes = {}
    for key, value in login:gmatch("(%w+)=([^,]+)") do changes[key] = tonumber(value) or value end
    game.setProfile(changes)
end
-- Class colours from the game's class table (ChrClasses), for C_ClassColor and the RAID_CLASS_COLORS made from it
local classColors = {}
for _, row in ipairs(readTable("ChrClasses", { "Filename", "ClassColorR", "ClassColorG", "ClassColorB" }) or {}) do
    if row.Filename and tonumber(row.ClassColorR) then
        classColors[row.Filename:upper()] = { tonumber(row.ClassColorR) / 255, tonumber(row.ClassColorG) / 255, tonumber(row.ClassColorB) / 255 }
    end
end
sim.G.C_ClassColor = sim.G.C_ClassColor or {}
sim.G.C_ClassColor.GetClassColor = function(className)
    local color = classColors[tostring(className or ""):upper()]
    if not color then return nil end
    return sim.G.CreateColor(color[1], color[2], color[3], 1)
end
for className, color in pairs(classColors) do
    local classColor = sim.G.CreateColor(color[1], color[2], color[3], 1)
    classColor.colorStr = classColor:GenerateHexColor()
    sim.G.RAID_CLASS_COLORS[className] = classColor
end

-- The party, and the minimap with the land from the game's tiles (continent folders from Map.db2)
local party = require("party")
party.install()
-- The plugin API (lua/plugins.lua) and what is registered through it: the simulator's own party addons (Questie's
-- member), then the project's plugins, which see every module of the simulator made
local plugins = require("plugins")
require("questiemember")
local movement = require("movement")
movement.install()
local continentDirectories = {}
for _, row in ipairs(readTable("Map", { "ID", "Directory" }) or {}) do
    if tonumber(row.ID) then continentDirectories[tonumber(row.ID)] = row.Directory end
end
-- The land on the minimap: on the simulator's own now, or on the game's once its interface has loaded (below)
if not sim.isWholeInterface then require("minimap").install(continentDirectories) end

-- The game's interface strings (GlobalStrings), as its Lua escapes them; they replace the simulator's stand-ins
local LUA_ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
local stringCount = 0
for _, row in ipairs(readTable("GlobalStrings", { "BaseTag", "TagText_lang" }) or {}) do
    if row.BaseTag and row.BaseTag ~= "" then
        sim.G[row.BaseTag] = (row.TagText_lang or ""):gsub("\\(.)", function(character) return LUA_ESCAPES[character] or ("\\" .. character) end)
        stringCount = stringCount + 1
    end
end
sim.globalStringCount = stringCount

-- The game's named colours (GlobalColor: ARGB as a signed number) as its colour objects, then its fonts
local namedColors = {}
fonts.namedColors = namedColors -- for "|cnNAME:" in text
for _, row in ipairs(readTable("GlobalColor") or {}) do
    local value = tonumber(row.Color)
    if value and row.LuaConstantName then
        if value < 0 then value = value + 4294967296 end
        local a, r = math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256
        local g, b = math.floor(value / 256) % 256, value % 256
        namedColors[row.LuaConstantName] = { r / 255, g / 255, b / 255, a / 255 }
        if not rawget(sim.G, row.LuaConstantName) or row.LuaConstantName:match("_COLOR$") then
            sim.G[row.LuaConstantName] = sim.G.CreateColor(r / 255, g / 255, b / 255, a / 255)
        end
    end
end
-- The core functions the game's own code leans on, then everything else its API documentation names
sim.G.GetCurrentEnvironment = function() return sim.G end
sim.G.AddSourceLocationExclude = function() end
sim.G.issecretvalue = function(value) return sim.isSecret(value) end
sim.G.issecrettable = function(value) return sim.isSecret(value) end
sim.G.canaccesstable = function() return true end
sim.G.canaccessvalue = function() return true end
sim.G.canaccessallvalues = function() return true end
sim.G.canaccesssecrets = function() return true end
sim.G.scrubsecretvalues = function(...) return ... end
sim.G.secretwrap = function(...) return ... end
sim.G.secretunwrap = function(...) return ... end
sim.G.dropsecretaccess = function() end
---Each value through a function, as many out as went in (the game's tooltip code cleans its arguments with it)
sim.G.mapvalues = function(func, ...)
    local count = select("#", ...)
    local values = { ... }
    for index = 1, count do values[index] = func(values[index]) end
    return unpack(values, 1, count)
end
sim.G.hasanysecretvalues = function(...)
    for index = 1, select("#", ...) do
        if sim.isSecret((select(index, ...))) then return true end
    end
    return false
end
-- Whether the code calling may do protected things to an object: always, unless the object is protected, the player is
-- in combat and the code is not the game's own (tooltips are not protected: GameTooltip:SetUnit asks this first)
sim.G.C_RestrictedActions = sim.G.C_RestrictedActions or {}
sim.G.C_RestrictedActions.CheckAllowProtectedFunctions = function(object)
    if type(object) ~= "table" or not object.IsProtected then return true end
    local isProtected = object:IsProtected()
    if not isProtected then return true end
    return not (sim.G.InCombatLockdown and sim.G.InCombatLockdown()) or (sim.G.issecure and sim.G.issecure())
end
sim.G.IsOnGlueScreen = function() return false end
sim.G.IsGMClient = function() return false end
sim.G.RegisterStaticConstants = function(constants) return constants end
-- Engine functions of the quest map that have no documentation: noted, doing nothing
sim.G.SortQuestSortTypes = function() sim.noteStub("SortQuestSortTypes") end
sim.G.QuestMapUpdateAllQuests = function() sim.noteStub("QuestMapUpdateAllQuests"); return 0 end
local function makeNotedStandIn(name, ...)
    local values = { n = select("#", ...), ... }
    return sim.markStandIn(function() sim.noteStub(name); return unpack(values, 1, values.n) end)
end
for name, returned in pairs({ QuestPOIUpdateIcons = {}, SortQuests = {}, TriggerTutorial = {}, RunBinding = {}, CollapseQuestHeader = {},
    ExpandQuestHeader = {}, IsQuestSequenced = { false }, QuestLogShouldShowPortrait = { false }, GetQuestUiMapID = { 0 },
    GetQuestLogCompletionText = {}, GetAchievementNumCriteria = { 0 }, GetAchievementCriteriaInfo = {},
    CanAutoSetGamePadCursorControl = { false }, GetNumBattlefieldFlagPositions = { 0 } }) do
    if rawget(sim.G, name) == nil then sim.G[name] = makeNotedStandIn(name, unpack(returned)) end
end
-- A quest's chat link, as the game makes it
sim.G.GetQuestLink = sim.G.GetQuestLink or function(questId)
    local title = sim.G.C_QuestLog.GetTitleForQuestID(questId)
    if not title then return nil end
    return ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(questId, -1, title)
end
-- Game functions with no documentation that addons call: noted stand-ins
for name, returned in pairs({ GetAutoCompleteRealms = { {} }, MuteSoundFile = {}, UnmuteSoundFile = {} }) do
    if rawget(sim.G, name) == nil then sim.G[name] = makeNotedStandIn(name, unpack(returned)) end
end
-- No scenarios in this game; the map asks anyway
sim.G.C_Scenario = sim.G.C_Scenario or {}
setmetatable(sim.G.C_Scenario, { __index = function(_, key) return makeNotedStandIn("C_Scenario." .. key) end })
-- What the client answers for systems with nothing going on for the character: in no scenario (no stages), no
-- power bar timers, no spell prompts, no friends online, no initiative tasks, no PvP match. The documentation
-- calls some of these never nil, but the client gives nil where there is none (the game's loops stop on it)
rawset(sim.G.C_Scenario, "GetInfo", function() return "", 0, 0, 0 end)
sim.G.UnitPowerBarTimerInfo = function() return nil end
sim.G.GetSpellConfirmationPromptsInfo = function() return {} end
sim.G.GetTasksTable = function() return {} end -- no bonus objectives or world quests under way
-- The character's equipment slots by name, as the client numbers them, with the empty slot's picture
do
    local SLOTS = {
        AMMOSLOT = { 0, "Ranged" }, HEADSLOT = { 1, "Head" }, NECKSLOT = { 2, "Neck" }, SHOULDERSLOT = { 3, "Shoulder" },
        SHIRTSLOT = { 4, "Shirt" }, CHESTSLOT = { 5, "Chest" }, WAISTSLOT = { 6, "Waist" }, LEGSSLOT = { 7, "Legs" },
        FEETSLOT = { 8, "Feet" }, WRISTSLOT = { 9, "Wrists" }, HANDSSLOT = { 10, "Hands" }, FINGER0SLOT = { 11, "Finger" },
        FINGER1SLOT = { 12, "Finger" }, TRINKET0SLOT = { 13, "Trinket" }, TRINKET1SLOT = { 14, "Trinket" },
        BACKSLOT = { 15, "Chest" }, MAINHANDSLOT = { 16, "MainHand" }, SECONDARYHANDSLOT = { 17, "SecondaryHand" },
        RANGEDSLOT = { 18, "Ranged" }, TABARDSLOT = { 19, "Tabard" },
        -- Bags after CONTAINER_BAG_OFFSET (30), the reagent bag last, as this client numbers them
        BAG0SLOT = { 31, "Generic" }, BAG1SLOT = { 32, "Generic" }, BAG2SLOT = { 33, "Generic" }, BAG3SLOT = { 34, "Generic" },
        REAGENTBAG0SLOT = { 35, "Generic" },
        -- The profession tools and gear (the professions window's slots), numbered as the game's code has them
        -- (Blizzard_Tutorials_Professions: 20 the first profession's tool ... 30)
        PROF0TOOLSLOT = { 20, "Generic" }, PROF0GEAR0SLOT = { 21, "Generic" }, PROF0GEAR1SLOT = { 22, "Generic" },
        PROF1TOOLSLOT = { 23, "Generic" }, PROF1GEAR0SLOT = { 24, "Generic" }, PROF1GEAR1SLOT = { 25, "Generic" },
        COOKINGTOOLSLOT = { 26, "Generic" }, COOKINGGEAR0SLOT = { 27, "Generic" }, FISHINGTOOLSLOT = { 28, "Generic" },
        FISHINGGEAR0SLOT = { 29, "Generic" }, FISHINGGEAR1SLOT = { 30, "Generic" },
    }
    local function getInventorySlotInfo(name)
        local slot = type(name) == "string" and SLOTS[name:upper()]
        if not slot then return nil end
        -- The empty slot's picture by its file id, as the client gives it (measured: the ammo slot shows the ranged
        -- one, bags and profession slots the generic one)
        local path = "Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. (slot[2] or "Generic")
        local texture = sim.G.GetFileIDFromPath and sim.G.GetFileIDFromPath(path) or path
        return slot[1], texture, false
    end
    sim.G.GetInventorySlotInfo = getInventorySlotInfo
    sim.G.C_PaperDollInfo = sim.G.C_PaperDollInfo or {}
    sim.G.C_PaperDollInfo.GetInventorySlotInfo = getInventorySlotInfo
end
-- A file's ID from its path ("Interface\\Icons\\INV_Misc_QuestionMark", with or without its extension), as the
-- client knows its files: looked up in the listfile's paths the server writes sorted (cache/file-ids.tsv), by
-- binary search in the file, nothing loaded; nil for a path it does not know, as in the client
do
    local file, size
    local cache = {}
    -- The first line starting at or after offset: its start and its text
    local function lineAt(offset)
        if offset <= 0 then
            file:seek("set", 0)
        else
            file:seek("set", offset - 1)
            file:read("*l") -- (the rest of the line before: empty when offset is a line's start)
        end
        local start = file:seek()
        return start, file:read("*l")
    end
    local function lookUp(key)
        if not file then
            file = config.fileIdsFile and io.open(config.fileIdsFile, "rb")
            if not file then return nil end
            size = file:seek("end")
        end
        local low, high = 0, size
        while low < high do
            local middle = math.floor((low + high) / 2)
            local start, line = lineAt(middle)
            local lineKey = line and line:match("^([^\t]*)")
            if not line or lineKey >= key then
                high = middle
            else
                low = start + #line + 1
            end
        end
        local _, line = lineAt(low)
        local lineKey, id = (line or ""):match("^([^\t]*)\t(%d+)")
        return lineKey == key and tonumber(id) or nil
    end
    sim.G.GetFileIDFromPath = function(path)
        if type(path) ~= "string" or path == "" then return nil end
        local key = path:gsub("\\", "/"):gsub("^/+", ""):lower()
        if cache[key] == nil then cache[key] = lookUp(key) or false end
        return cache[key] or nil
    end
end
-- No unit is casting or channelling (else the game shows its cast bar)
sim.G.UnitCastingInfo = function() return nil end
sim.G.UnitChannelInfo = function() return nil end
-- The battle simulator (lua/combat.lua): creatures as units, targeting, attacks, spells, threat, death and loot. After
-- the stand-ins above, before the game's interface loads (its code keeps some of these functions as it loads)
require("combat").install()
sim.G.GetActiveLootRollIDs = function() return {} end -- no group loot being rolled for
sim.G.BNGetNumFriends = function() return 0, 0, 0, 0 end
sim.G.C_NeighborhoodInitiative = sim.G.C_NeighborhoodInitiative or {}
sim.G.C_NeighborhoodInitiative.GetTrackedInitiativeTasks = function() return { trackedIDs = {} } end
sim.G.C_PvP = sim.G.C_PvP or {}
sim.G.C_PvP.GetActiveMatchState =function() return sim.G.Enum.PvPMatchState and sim.G.Enum.PvPMatchState.Inactive or 0 end
-- A console variable's default: the value it started with in the simulator (one value, possibly nil, as the game gives)
sim.G.C_CVar.GetCVarDefault = function(name)
    -- The client's default (the recorder's dump, else wowless's), else the value it started with in the simulator
    local value = sim.cvarDefaults[name]
    if value == nil and type(name) == "string" and sim.cvarDefaultsLower then value = sim.cvarDefaultsLower[name:lower()] end
    if value == nil then value = sim.cvars[name] end
    return value
end
sim.G.GetCVarDefault = sim.G.C_CVar.GetCVarDefault
-- Kiosk mode (demo stations) is never on
sim.G.Kiosk = setmetatable({}, { __index = function(_, key) return makeNotedStandIn("Kiosk." .. key, false) end })
sim.G.IsTutorialFlagged = function() return true end -- a seasoned player: the game's tutorials are done
sim.G.IsInGlobalEnvironment = function() return true end
sim.G.GetTimePreciseSec = sim.G.GetTime
-- Curves: points and a value read off them, as C_CurveUtil's objects do
sim.G.C_CurveUtil = sim.G.C_CurveUtil or {}
sim.G.C_CurveUtil.CreateCurve = function()
    local curve = { points = {} }
    function curve:AddPoint(x, y) table.insert(self.points, { x, y }); table.sort(self.points, function(a, b) return a[1] < b[1] end) end
    function curve:ClearPoints() self.points = {} end
    function curve:SetType() end
    function curve:Evaluate(x)
        local points = self.points
        if #points == 0 then return 0 end
        if x <= points[1][1] then return points[1][2] end
        for index = 2, #points do
            local a, b = points[index - 1], points[index]
            if x <= b[1] then return a[2] + (b[2] - a[2]) * (x - a[1]) / math.max(b[1] - a[1], 1e-9) end
        end
        return points[#points][2]
    end
    return curve
end
sim.G.C_CurveUtil.CreateColorCurve = sim.G.C_CurveUtil.CreateCurve
require("xmlui")
require("luaextensions").install(sim.G)
-- The widget types' own metatables, as the client hands them out: the game's code calls a widget's original method
-- past any override (SecureUtil: GetFontStringMetatable().__index.SetText)
for _, typeName in ipairs({ "Frame", "Button", "EditBox", "FontString", "Texture" }) do
    sim.G["Get" .. typeName .. "Metatable"] = function() return W.types[typeName].meta end
end
if config.interfaceRoot then
    local docs = require("docs")
    docs.enumCount, docs.stubCount = docs.load(config.interfaceRoot .. "/AddOns/Blizzard_APIDocumentationGenerated")
    sim.addInterfaceEvents(config.interfaceRoot, root .. "/cache/interface-events-" .. tostring(config.build) .. ".txt")
end
if config.interfaceRoot then
    local fontFolder = config.interfaceRoot .. "/AddOns/Blizzard_Fonts_Shared/"
    local fontFiles = {}
    for _, name in ipairs({ "Mainline/Fonts.xml", "Shared/Fonts.xml", "Shared/GameFonts.xml", "Mainline/GameFonts.xml",
        "Shared/FontStyles.xml", "Mainline/FontStyles.xml", "Mainline/GameFontStyles.xml", "Shared/GameFontStyles.xml" }) do
        fontFiles[#fontFiles + 1] = fontFolder .. name
    end
    fonts.gameFontCount = fonts.loadGameFonts(fontFiles, namedColors)
end
ui.loadMapArt(readTable)

plugins.load(config.plugins)

-- The simulated character and quest log carry over between runs
local simStatePath = config.savedDir and (config.savedDir .. "/_sim.json")
local savedState = readJson(simStatePath)
if savedState then
    if savedState.profile then game.setProfile(savedState.profile) end
    -- Edit Mode's layouts and settings and the action bars turned on: before the login's events, which apply them
    if savedState.editMode and sim.setEditModeState then sim.setEditModeState(savedState.editMode) end
    for _, entry in ipairs(savedState.questLog or {}) do table.insert(game.questLog, entry) end
    for _, questId in ipairs(savedState.completed or {}) do game.completed[questId] = true end
    for _, questId in ipairs(savedState.watched or {}) do game.watched[questId] = true end
    -- The party as it was, quests and counts too
    for _, saved in ipairs(savedState.party or {}) do
        local member = party.add(saved)
        if member then
            for questIdText, quest in pairs(saved.quests or {}) do member.quests[tonumber(questIdText)] = quest end
        end
    end
    -- The screen picked on the page: its size, and the UI scale when one is switched on
    local screen = savedState.screen
    if screen and tonumber(screen.width) and tonumber(screen.height) and sim.setScreen then
        sim.setScreen(tonumber(screen.width), tonumber(screen.height), tonumber(screen.uiScale))
    end
    if savedState.minimapZoom and sim.G.Minimap then sim.G.Minimap:SetZoom(savedState.minimapZoom) end
    if savedState.minimapPlace then
        local place = savedState.minimapPlace
        sim.placeMinimap(place.point, place.x, place.y)
    end
end
---Where the minimap is: its point and offset from the screen, as Edit Mode keeps it
local function getMinimapPlace()
    local cluster = sim.G.MinimapCluster
    if not cluster or cluster:GetNumPoints() == 0 then return nil end
    local point, _, _, x, y = cluster:GetPoint(1)
    return { point = point, x = x, y = y }
end

local function saveState()
    if not simStatePath then return end
    local completed, watched = {}, {}
    for questId in pairs(game.completed) do completed[#completed + 1] = questId end
    for questId in pairs(game.watched) do watched[#watched + 1] = questId end
    local file = io.open(simStatePath, "wb")
    if file then
        local members = {}
        for index, member in ipairs(party.members) do
            local quests = {}
            for questId, quest in pairs(member.quests) do quests[tostring(questId)] = quest end
            members[index] = { name = member.name, class = member.classFile, level = member.level, race = member.race, addon = member.addon,
                isOnline = member.isOnline, uiMapId = member.uiMapId, x = member.x, y = member.y, quests = quests,
                doneQuestIds = member.doneQuestIds }
        end
        file:write(json.encode({ profile = game.profile, questLog = game.questLog, completed = completed, watched = watched,
            party = members, minimapZoom = sim.G.Minimap and sim.G.Minimap:GetZoom() or 0, minimapPlace = getMinimapPlace(),
            screen = sim.physicalWidth and { width = sim.physicalWidth, height = sim.physicalHeight,
                uiScale = sim.G.GetCVar("useUiScale") == "1" and tonumber(sim.G.GetCVar("uiScale")) or nil } or nil,
            interfaceStyle = require("gamepad").getStyle(), editMode = sim.getEditModeState and sim.getEditModeState() or nil }))
        file:close()
    end
end
-- Edit Mode's layouts saved, action bars turned on or off: kept at once, as the client keeps them for the account
sim.onStateChanged = saveState

-- Slash commands, as the chat box runs them
local function runSlashCommand(text)
    local command, rest = text:match("^(/%S+)%s*(.-)$")
    if not command then return false end
    command = command:lower()
    for key, handler in pairs(sim.G.SlashCmdList) do
        local index = 1
        while true do
            local alias = rawget(sim.G, "SLASH_" .. key .. index)
            if not alias then break end
            if alias:lower() == command then
                sim.call(handler, rest, sim.G.DEFAULT_CHAT_FRAME)
                return true
            end
            index = index + 1
        end
    end
    if command == "/reload" or command == "/rl" then sim.requestReload = true; return true end
    sim.print("Unknown command: " .. command, 1, 0.3, 0.3)
    return false
end
sim.runSlashCommand = runSlashCommand -- for macro buttons

-- Log in: load the addons, then the events of entering the world
addons.savedRoot = config.savedDir or (root .. "/saved")
-- Forever is the Camelot game within the Mainline family: lines for either load, as Startup.lua's conditions show
addons.gameTypes, addons.family, addons.game = config.gameTypes or { "mainline", "camelot" }, config.family or "Mainline", config.game or "Camelot"
addons.discover(config.addonsRoot or (root .. "/addons"), config.tocSuffixes or { "_Forever", "_Camelot", "_Mainline", "" })
-- A project's own addon folders, wherever they are: one of the same name in the AddOns folder gives way to it
for _, folder in ipairs(config.addonDirs or {}) do
    addons.discoverFolder((folder:gsub("\\", "/")), config.tocSuffixes or { "_Forever", "_Camelot", "_Mainline", "" })
end
-- The game's own interface addons (shared templates, menus, frames), loaded first as the client does
if config.interfaceRoot then
    addons.discover(config.interfaceRoot .. "/AddOns", config.interfaceTocSuffixes or { "_Camelot", "_Mainline", "" })
    local blizzardStarted = os.clock()
    -- "all": the whole interface, as the client loads it at login: every one of the game's addons that is not loaded
    -- on demand and is for this client, each after the game's addons it depends on
    local blizzardNames = config.blizzardAddons
    if blizzardNames == "all" then
        addons.loadsGameDependencies = true
        sim.isWholeInterface = true -- the game's own world map among it: none of the simulator's stand-ins for it
        blizzardNames = {}
        local interfaceFolder = (config.interfaceRoot .. "/AddOns"):gsub("\\", "/"):lower()
        for _, addon in ipairs(addons.list) do
            local isGame = addon.name:match("^Blizzard_") and addon.folder:gsub("\\", "/"):lower():find(interfaceFolder, 1, true) == 1
            -- Not those of the login screens ("## AllowLoad: Glue"): they run before a character enters the world
            local allowLoad = (addon.metadata.allowload or ""):lower():gsub("%s*%[.*", "")
            if isGame and not addon.loadOnDemand and not addon.metadata.isNotForClient and allowLoad ~= "glue" then
                blizzardNames[#blizzardNames + 1] = addon.name
            end
        end
        -- The secure environment's addons first ("## UseSecureEnvironment: 1"): they define frame types and tables the
        -- rest is built with (Blizzard_AuraContainer's <AuraContainer>, which the target frame's XML uses though
        -- nothing lists it as a dependency); then by name
        local isSecureEnvironment = {}
        for _, addon in ipairs(addons.list) do
            if tostring(addon.metadata.usesecureenvironment or ""):match("^%s*1") then isSecureEnvironment[addon.name] = true end
        end
        table.sort(blizzardNames, function(first, second)
            if (isSecureEnvironment[first] or false) ~= (isSecureEnvironment[second] or false) then return isSecureEnvironment[first] == true end
            return first < second
        end)
        -- Its code calls many of the client's functions as it loads: those not simulated yet stand in, noted
        local apisurface = require("apisurface")
        local api = apisurface.load(apisurface.findDump(config))
        local standIns = api and apisurface.addClientStandIns(api) or 0
        io.stderr:write(string.format("The whole interface: %d of the game's addons, %d of the client's functions standing in\n", #blizzardNames, standIns))
    end
    -- Every console variable's default in this client, from the recorder's dump (the text scale, the action bars'
    -- settings): read as the interface loads
    do
        local apisurface = require("apisurface")
        local dump = apisurface.load(apisurface.findDump(config))
        for name, value in pairs(dump and dump.cvars or {}) do sim.cvarDefaults[name] = value end
    end
    -- wowless's knowledge of the client (bun run wowless fetches it): better stand-ins, every console variable's
    -- default, the client's constants
    do
        local summary = require("wowless").apply(root, config, sim.isWholeInterface == true)
        if summary then
            io.stderr:write(string.format("wowless %s: %d stand-ins improved, %d added, %d widget methods, %d console variables, %d constants\n",
                tostring(summary.commit):sub(1, 10), summary.replaced, summary.added, summary.widgetMethods or 0, summary.cvars, summary.constants))
        elseif config.interfaceRoot then
            io.stderr:write("No wowless data: run `bun run wowless` for better stand-ins and the client's defaults\n")
        end
    end
    for _, name in ipairs(blizzardNames or { "Blizzard_SharedXMLBase", "Blizzard_SharedXML", "Blizzard_SharedXMLGame",
        "Blizzard_Menu", "Blizzard_UIPanelTemplates", "Blizzard_GamepadSmartNavigation",
        -- The game's panel manager: it places windows such as the map, and widens room for what addons add
        "Blizzard_ManagedFrameSystem", "Blizzard_GameMenuEsc", "Blizzard_UIParentPanelManager",
        -- Money frames and inputs, which addons build on (Auctionator's price boxes)
        "Blizzard_MoneyFrame",
        -- The edit and search boxes' narration mixins, which addons' boxes inherit (a search box's)
        "Blizzard_Narration" }) do
        addons.load(name, false, true)
    end
    -- The bootstraps of the game's addons loaded on demand: their loaders, which the rest of the interface calls
    if sim.isWholeInterface then addons.runBootstraps(true) end
    -- The game's key bindings for this client (Bindings_Camelot.xml): every key command runs the game's own code
    if sim.isWholeInterface then
        local folder = config.interfaceRoot .. "/AddOns/Blizzard_FrameXML/"
        local game = addons.game or "Camelot"
        local path = folder .. "Bindings_" .. game .. ".xml"
        if not sim.fileExists or sim.fileExists(path) then addons.readBindings(path, "Interface/AddOns/Blizzard_FrameXML/Bindings_" .. game .. ".xml") end
    end
    -- The game's chat windows write with its own Lua (ScrollingMessageFrameMixin), not the simulator's message frame:
    -- what they show is noted in the simulator's chat as well (the page's chat, a scenario's expectChat)
    if sim.isWholeInterface then
        for index = 1, (sim.G.NUM_CHAT_WINDOWS or 10) do
            local frame = rawget(sim.G, "ChatFrame" .. index)
            local addMessage = frame and frame.AddMessage
            if type(addMessage) == "function" then
                frame.AddMessage = function(self, text, r, g, b, ...)
                    if self == sim.G.DEFAULT_CHAT_FRAME or index == 1 then sim.print(text, r, g, b) end
                    return addMessage(self, text, r, g, b, ...)
                end
            end
        end
    end
    if config.gameWorldMap and not sim.isWholeInterface then
        addons.runFiles("Blizzard_ChatFrameBase", { "Shared\\SlashCommandsRegistry.lua", "Shared\\SlashCommands.lua" })
        for _, name in ipairs({ "Blizzard_FrameXMLBase", "Blizzard_POIButton", "Blizzard_GamepadSoftCursor",
            "Blizzard_UIParentPanelManager", "Blizzard_MapCanvasSecureUtil", "Blizzard_MapCanvas", "Blizzard_SharedMapDataProviders",
            "Blizzard_HelpPlate" }) do
            addons.load(name, false, true)
        end
        -- The world map's own parts of the game's panels, without the rest of the game's interface
        addons.runFiles("Blizzard_UIPanels_Game", { "Shared\\WorldMapPOIQuantizer.lua", "Mainline\\UnitPositionFrameTemplates.lua", "Mainline\\UnitPositionFrameTemplates.xml", "Mainline\\WorldMapBountyBoard.lua", "Mainline\\WorldMapActionButton.lua", "Mainline\\WorldMapFrameTemplates.xml", "Mainline\\FogOfWarFrameTemplates.lua", "Mainline\\FogOfWarFrameTemplates.xml",
            "Camelot\\QuestMapFrameOverrides.lua", "Mainline\\QuestMapFrame.lua", "Mainline\\QuestMapFrame.xml", "Camelot\\QuestMapFrameUtils.lua" })
        addons.runFiles("Blizzard_FrameXMLUtil", { "Camelot\\QuestUtilsOverrides.lua", "Mainline\\QuestUtils.lua", "Mainline\\MapUtil.lua", "Mainline\\Blizzard_QuestSuperTracking.lua" })
        addons.runFiles("Blizzard_FrameXML", { "Mainline\\NavigationBar.lua", "Mainline\\NavigationBar.xml" })
        addons.load("Blizzard_WorldMap", false, true)
    end
    if not config.gameWorldMap and not sim.isWholeInterface then
        -- The world map's breadcrumb bar and its templates, for the simulator's own map window
        addons.runFiles("Blizzard_FrameXML", { "Mainline\\NavigationBar.lua", "Mainline\\NavigationBar.xml" })
        addons.runFiles("Blizzard_WorldMap", { "Blizzard_WorldMapTemplates.lua", "Blizzard_WorldMapTemplates.xml" })
        -- Forever's map tops out at the world, as Camelot/Blizzard_WorldMap.lua sets
        sim.G.WorldMapNavBarMixin.GetTopMostUIMapType = function() return sim.G.Enum.UIMapType.World end
    end
    addons.blizzardSeconds = os.clock() - blizzardStarted
end
if sim.isWholeInterface then require("minimap").install(continentDirectories) end

-- The real client's API, dumped in the game by the recorder (/asrec api): what this client lacks is reported, and in
-- strict mode taken away. Only now, once the game's own interface code has loaded: the client gives that code some
-- functions (CreateSecureDelegate) and takes them out of the global table before any addon runs, so the addons see
-- exactly what the recorder, itself an addon, saw
do
    local apisurface = require("apisurface")
    local api = apisurface.load(apisurface.findDump(config))
    if api then
        local mixinMethods = config.interfaceRoot and apisurface.getMixinMethodNames(config.interfaceRoot, root .. "/cache/mixin-methods-" .. tostring(api.build) .. ".txt")
        local report = apisurface.apply(api, config.strictApi == true, mixinMethods)
        apisurface.writeReport(report, api, root .. "/api-report.txt")
        sim.apiReport = report
        -- To stderr: the server reads the simulator's stdout as its own messages, the first being "ready"
        io.stderr:write(string.format("API of client build %s: %d simulator functions it lacks%s, %d of its functions not simulated yet (api-report.txt)\n",
            tostring(api.build), #report.simOnly, config.strictApi and " (taken away)" or "", #report.clientOnly))
    end
end
if not config.gameWorldMap and not sim.isWholeInterface then ui.installWorldMap(sim.G.UIParent) end
ui.installTooltipData()
-- The plugins' last word before the addons: the game's interface is in
plugins.runBootHooks()
addons.wanted = {}
for _, name in ipairs(config.addons or {}) do addons.wanted[name:lower()] = true end
for _, name in ipairs(config.addons or {}) do
    addons.load(name)
end
sim.fireEvent("SPELLS_CHANGED")
sim.fireEvent("VARIABLES_LOADED")
sim.fireEvent("PLAYER_LOGIN")
-- The account's settings are in (the action bars turned on among them): the game shows those bars now
sim.fireEvent("SETTINGS_LOADED")
-- The account's Edit Mode layouts: the game's Edit Mode places its frames from them
sim.fireEvent("EDIT_MODE_LAYOUTS_UPDATED", sim.G.C_EditMode.GetLayouts(), false)
-- The account's chat windows (GetChatWindowInfo): the chat frames load their names, colours and docking from them
sim.fireEvent("UPDATE_CHAT_WINDOWS")
sim.fireEvent("UPDATE_FLOATING_CHAT_WINDOWS")
sim.fireEvent("PLAYER_ENTERING_WORLD", true, false)
sim.fireEvent("ZONE_CHANGED_NEW_AREA")
sim.fireEvent("QUEST_LOG_UPDATE")
sim.fireEvent("UPDATE_BINDINGS")
-- The interface picked on the page (the game's gamepad interface), switched to once everything has loaded, as a
-- player switches after logging in: set before, the game's addons loading ahead of Blizzard_Gamepad set themselves
-- up for it without it (Blizzard_SecureTransferUI)
if savedState and savedState.interfaceStyle == 1 then require("gamepad").setStyle(1) end
local bootSeconds = os.clock() - startedAt
if isJitOn then jit.on() end
collectgarbage("setpause", 200)

-- Requests
local handlers = {}

function handlers.scene(request)
    if request.since and request.since == sim.version then
        return { version = sim.version, unchanged = true, errors = #sim.errors, chat = #sim.chat }
    end
    return { version = sim.version, items = scene.export(), errors = #sim.errors, chat = #sim.chat,
        width = sim.screenWidth, height = sim.screenHeight }
end

-- The scene as a stream (stream.lua): a tick when the clock moves (dt), then what changed in the scene since the
-- last frame, written straight as JSON text (host.lua sends a { raw = text } answer as it is)
local stream = require("stream")
local function streamHeader(parts)
    parts[#parts + 1] = '{"version":' .. tostring(stream.getVersion() or sim.version) .. ',"errors":' .. #sim.errors .. ',"chat":' .. #sim.chat
        .. ',"width":' .. sim.screenWidth .. ',"height":' .. sim.screenHeight
    if sim.requestReload then parts[#parts + 1] = ',"reload":true' end
end
-- The slowest frame since asked (handlers.perf): where its time went, for the page's readout
local worstFrame
function handlers.frame(request)
    local started = os.clock()
    local heapBefore = collectgarbage("count")
    -- The page's input since the last frame, in order, then the tick
    for _, event in ipairs(request.inputs or {}) do
        local isDone, problem = xpcall(function() scene.input(event) end, debug.traceback)
        if not isDone then sim.reportError(problem) end
    end
    if request.dt then sim.tick(math.min(request.dt, 0.5)) end
    local ticked = os.clock()
    local changes = {}
    local isChanged = false
    local exported = ticked
    if request.scene ~= false and stream.getVersion() ~= sim.version then
        local items = scene.export()
        exported = os.clock()
        isChanged = stream.encodeChanges(items, changes)
        stream.setVersion(sim.version)
    end
    local ended = os.clock()
    if not worstFrame or ended - started > worstFrame.total then
        -- (the heap smaller after than before: the garbage collector ran in this frame)
        worstFrame = { total = ended - started, tick = ticked - started, export = exported - ticked, encode = ended - exported,
            collected = collectgarbage("count") < heapBefore }
    end
    local parts = {}
    streamHeader(parts)
    if isChanged then
        parts[#parts + 1] = ',"delta":true,'
        for _, part in ipairs(changes) do parts[#parts + 1] = part end
    end
    parts[#parts + 1] = "}"
    return { raw = table.concat(parts) }
end

function handlers.perf()
    local worst = worstFrame
    worstFrame = nil
    if not worst then return {} end
    local function ms(seconds) return math.floor(seconds * 10000 + 0.5) / 10 end
    return { worst = { total = ms(worst.total), tick = ms(worst.tick), export = ms(worst.export), encode = ms(worst.encode), collected = worst.collected },
        heapMb = math.floor(collectgarbage("count") / 1024) }
end

-- The whole scene the stream stands at, for a page that joins it (the frames after are changes to this)
function handlers.sceneWhole()
    if stream.getVersion() == nil then
        stream.encodeChanges(scene.export(), {})
        stream.setVersion(sim.version)
    end
    local parts = {}
    streamHeader(parts)
    parts[#parts + 1] = ',"whole":true,'
    stream.encodeWhole(parts)
    parts[#parts + 1] = "}"
    return { raw = table.concat(parts) }
end

function handlers.input(request)
    scene.input(request.event or {})
    return { version = sim.version }
end

function handlers.tick(request)
    sim.tick(math.min(request.dt or 0.033, 0.5))
    return { version = sim.version, reload = sim.requestReload or nil }
end

function handlers.exec(request)
    local output = {}
    local print = sim.G.print
    sim.G.print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
        output[#output + 1] = table.concat(parts, " ")
    end
    local code = request.code or ""
    local chunk, problem = loadstring("return " .. code, "=console")
    if not chunk then chunk, problem = loadstring(code, "=console") end
    local results
    if chunk then
        setfenv(chunk, sim.G)
        results = { pcall(chunk) }
    end
    sim.G.print = print
    if not chunk then return { output = output, error = problem } end
    if not results[1] then return { output = output, error = tostring(results[2]) } end
    local shown = {}
    for index = 2, #results do
        local value = results[index]
        if type(value) == "table" then
            local parts, count = {}, 0
            for key, item in pairs(value) do
                count = count + 1
                if count > 40 then parts[#parts + 1] = "..."; break end
                parts[#parts + 1] = tostring(key) .. " = " .. tostring(item)
            end
            shown[#shown + 1] = "{ " .. table.concat(parts, ", ") .. " }"
        else
            shown[#shown + 1] = tostring(value)
        end
    end
    return { output = output, result = table.concat(shown, ", ") }
end

function handlers.slash(request)
    return { ok = runSlashCommand(request.text or "") }
end

function handlers.event(request)
    sim.fireEvent(request.name, unpack(request.args or {}))
    return { version = sim.version }
end

function handlers.game(request)
    local action, ok, problem = request.action
    if action == "accept" then ok, problem = game.acceptQuest(tonumber(request.questId))
    elseif action == "progress" then ok, problem = game.progressQuest(tonumber(request.questId), request.objective, request.amount)
    elseif action == "complete" then ok, problem = game.completeQuest(tonumber(request.questId))
    elseif action == "turnIn" then ok, problem = game.turnInQuest(tonumber(request.questId))
    elseif action == "abandon" then ok, problem = game.abandonQuest(tonumber(request.questId))
    elseif action == "markDone" then game.completed[tonumber(request.questId)] = true; sim.fireEvent("QUEST_LOG_UPDATE"); ok = true
    elseif action == "profile" then game.setProfile(request.profile); sim.fireEvent("PLAYER_LEVEL_UP", game.profile.level); sim.fireEvent("QUEST_LOG_UPDATE"); ok = true
    elseif action == "position" then game.setPosition(request.uiMapId, request.x, request.y); ok = true
    elseif action == "kill" then
        ok, problem = game.kill(request.npcId, { loot = request.loot ~= false, via = request.via, isTappedByOthers = request.isTappedByOthers == true,
            dropChance = tonumber(request.dropChance) })
    elseif action == "loot" then ok, problem = game.loot(request.itemId, request.count)
    elseif action == "talk" then
        local dialog
        ok, problem, dialog = game.talkTo(request.npcId)
        saveState()
        return { ok = ok == true, problem = problem, dialog = dialog }
    elseif action == "closeDialog" then ok = game.closeDialog()
    elseif action == "instance" then ok = game.setInstance(request.instanceId, request.instanceType, request.name)
    -- The party
    elseif action == "partyAdd" then
        local member
        member, problem = party.add({ name = request.name, class = request.class, level = tonumber(request.level), addon = request.addon,
            race = request.race, doneQuestIds = request.doneQuestIds })
        ok = member ~= nil
    elseif action == "partyRemove" then ok, problem = party.remove(request.name)
    elseif action == "partyAccept" then ok, problem = party.acceptQuest(request.name, tonumber(request.questId))
    elseif action == "partyCopyLog" then
        -- The member takes every quest the player has, with nothing done
        ok = true
        for _, entry in ipairs(game.questLog) do
            local member = party.findMember(request.name)
            if member and not member.quests[entry.questId] then party.acceptQuest(request.name, entry.questId) end
        end
    elseif action == "partyProgress" then ok, problem = party.progress(request.name, tonumber(request.questId), tonumber(request.objective), tonumber(request.amount) or 1)
    elseif action == "partyComplete" then ok, problem = party.complete(request.name, tonumber(request.questId))
    elseif action == "partyAbandon" then ok, problem = party.abandonQuest(request.name, tonumber(request.questId))
    elseif action == "partyMove" then
        if request.isHere then
            -- Near the player: 20 yards off, so their blip shows beside the arrow
            ok, problem = party.placeNear(request.name, tonumber(request.yards) or 20)
        else
            ok, problem = party.moveTo(request.name, tonumber(request.uiMapId), tonumber(request.x), tonumber(request.y))
        end
    elseif action == "partyOnline" then ok, problem = party.setOnline(request.name, request.isOnline ~= false)
    -- Moving about, and the minimap's zoom
    elseif action == "walk" then ok = game.walk(tonumber(request.forward) or 0, tonumber(request.right) or 0)
    elseif action == "turn" then game.turn(math.rad(tonumber(request.degrees) or 0)); ok = true
    elseif action == "walkTo" then ok, problem = movement.walkTo(tonumber(request.uiMapId) or game.profile.uiMapId, tonumber(request.x), tonumber(request.y))
    elseif action == "autoRun" then movement.toggleAutoRun(); ok = true
    elseif action == "walkMode" then movement.setWalking(request.isWalking == true); ok = true
    elseif action == "stopMoving" then movement.stop(); ok = true
    elseif action == "clickToWalk" then sim.clickToWalk = request.isOn == true; ok = true
    elseif action == "zoom" then
        local minimapFrame = sim.G.Minimap
        minimapFrame:SetZoom(request.level ~= nil and tonumber(request.level) or (minimapFrame:GetZoom() + (tonumber(request.delta) or 0)))
        ok = true
    elseif action == "editMode" then
        -- The game's own Edit Mode where the whole interface runs, as the game menu opens it; turned off as its X
        -- closes it (unsaved changes: the game asks first). Else the simulator's (the minimap dragged)
        local manager = sim.isWholeInterface and sim.G.EditModeManagerFrame
        if manager then
            if request.isOn == true then
                if not manager:IsShown() then sim.runSecurely(sim.G.ShowUIPanel, manager) end
            elseif manager:IsShown() then
                if manager.CloseButton then sim.runSecurely(W.clickButton, manager.CloseButton, "LeftButton") else sim.runSecurely(sim.G.HideUIPanel, manager) end
            end
        else
            sim.setEditMode(request.isOn == true)
        end
        ok = true
    elseif action == "placeMinimap" then sim.placeMinimap(request.point, tonumber(request.x), tonumber(request.y)); ok = true
    elseif action == "screen" then
        local width, height = tonumber(request.width) or 1366, tonumber(request.height) or 768
        local uiScale = tonumber(request.uiScale)
        -- The game's own limits: a screen at least 640 by 480 at most 8K; a UI scale from 0.64 to 1.15
        width, height = math.max(640, math.min(7680, math.floor(width))), math.max(480, math.min(4320, math.floor(height)))
        if uiScale then uiScale = math.max(0.64, math.min(1.15, uiScale)) end
        sim.setScreen(width, height, uiScale)
        saveState()
        ok = true
    elseif action == "interfaceStyle" then
        require("gamepad").setStyle(tonumber(request.style) == 1 and 1 or 0)
        saveState()
        ok = true
    elseif action == "cvar" then
        sim.G.SetCVar(request.name, request.value)
        ok = true
    elseif action == "restrict" then
        sim.restrictions.identity, sim.restrictions.threat = request.identity == true, request.threat == true
        ok = true
    elseif type(action) == "string" and action:match("^combat%u") then
        -- A fight's actions (lua/combat.lua; src/shared/combat.ts says what each takes and answers)
        local result = require("combat").handleAction(action, request) or { ok = false, problem = "no such action: " .. action }
        saveState()
        return result
    elseif action == "combat" then
        sim.inCombat = request.inCombat == true
        sim.fireEvent(sim.inCombat and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
        ok = true
    end
    saveState()
    return { ok = ok == true, problem = problem }
end

function handlers.findQuests(request) return { results = game.findQuests(request.text, request.limit) } end
function handlers.findNpcs(request) return { results = game.findNpcs(request.text, request.limit) } end
function handlers.sources() return { quests = game.getObjectiveSources() } end

-- The stand-ins addons and the game's code reached, as JSON: a long list (2 000 entries) whose counts only the page's
-- list shows, written again every few seconds rather than at every state asked for
local stubsText, stubsWrittenAt = nil, -math.huge
local function getStubsText()
    if stubsText and os.clock() - stubsWrittenAt < 5 then return stubsText end
    local stubs = {}
    for name, count in pairs(sim.stubs) do
        local callers = {}
        for addon in pairs(sim.stubCallers[name] or {}) do callers[#callers + 1] = addon end
        table.sort(callers)
        stubs[#stubs + 1] = { name = name, count = count, addons = callers }
    end
    -- What addons reach first, then by how often
    table.sort(stubs, function(first, second)
        if (#first.addons > 0) ~= (#second.addons > 0) then return #first.addons > 0 end
        return first.count > second.count
    end)
    stubsText, stubsWrittenAt = json.encode(stubs), os.clock()
    return stubsText
end

-- The page's state, written as JSON text (host.lua sends it as it is): the stand-ins' list put in as kept
function handlers.state()
    local log = {}
    for _, entry in ipairs(game.questLog) do
        local objectives = {}
        for _, objective in ipairs(entry.objectives) do
            objectives[#objectives + 1] = { text = game.objectiveText(objective), fulfilled = objective.fulfilled, required = objective.required }
        end
        log[#log + 1] = { questId = entry.questId, title = entry.title, level = entry.level, isComplete = entry.isComplete, objectives = objectives, watched = game.watched[entry.questId] == true }
    end
    local addonList = {}
    for _, addon in ipairs(addons.list) do
        -- Its time a game tick since login, the last 60 ticks' and its worst (ms), as the AddOn profiler measured it
        local measured = sim.profiler.byAddon[addon.name]
        local cpu
        if measured then
            local recentSum, recentCount = 0, 0
            for _, spent in ipairs(measured.recent) do recentSum, recentCount = recentSum + spent, recentCount + 1 end
            local function round(value) return math.floor(value * 1000 + 0.5) / 1000 end
            cpu = { average = round(measured.total / math.max(sim.profiler.ticks, 1)), recent = round(recentCount > 0 and recentSum / recentCount or 0),
                peak = round(measured.peak), total = round(measured.total) }
        end
        addonList[#addonList + 1] = { name = addon.name, title = addon.title, loaded = addons.loaded[addon.name] == true,
            seconds = addon.loadSeconds and math.floor(addon.loadSeconds * 1000) / 1000 or nil, cpu = cpu }
    end
    local events = {}
    for index = math.max(1, #sim.eventHistory - 60), #sim.eventHistory do
        local entry = sim.eventHistory[index]
        local args = {}
        for _, value in ipairs(entry.args) do args[#args + 1] = tostring(value) end
        events[#events + 1] = { event = entry.event, time = math.floor(entry.time * 100) / 100, args = args }
    end
    local completedCount = 0
    for _ in pairs(game.completed) do completedCount = completedCount + 1 end
    local state = { errors = sim.errors, chat = sim.chat, profile = game.profile, questLog = log, completedCount = completedCount,
        npc = game.npc and { id = game.npc.id, name = game.npc.name, offers = game.npc.offers, active = game.npc.active } or nil,
        addons = addonList, events = events, bootSeconds = bootSeconds, version = sim.version, now = sim.now,
        rotateMinimap = sim.G.GetCVar("rotateMinimap") == "1", editMode = sim.editMode == true or (sim.isWholeInterface and sim.G.EditModeManagerFrame ~= nil and sim.G.EditModeManagerFrame:IsShown()) or false,
        gamepad = require("gamepad").describe(),
        screen = { width = sim.physicalWidth or sim.screenWidth, height = sim.physicalHeight or sim.screenHeight,
            uiScale = sim.G.GetCVar("useUiScale") == "1" and tonumber(sim.G.GetCVar("uiScale")) or nil },
        restrictions = sim.restrictions, party = party.describe(), partyAddons = plugins.describePartyAddons(), combat = require("combat").describe(), minimapZoom = sim.G.Minimap and sim.G.Minimap:GetZoom() or 0,
        facing = math.floor(math.deg(game.profile.facing or 0) + 0.5) % 360, viewRadius = sim.G.C_Minimap.GetViewRadius(),
        movement = movement.describe(), clickToWalk = sim.clickToWalk == true,
        -- For the header: which client this is, how strictly its API is kept, and where the character stands
        client = { build = config.build, isStrictApi = config.strictApi == true,
            simOnly = sim.apiReport and #sim.apiReport.simOnly or nil, clientOnly = sim.apiReport and #sim.apiReport.clientOnly or nil },
        zoneName = sim.G.GetRealZoneText and sim.G.GetRealZoneText() or nil, simulatorPerf = handlers.perf() }
    local text = json.encode(state)
    return { raw = text:sub(1, -2) .. ',"stubs":' .. getStubsText() .. "}" }
end

function handlers.inspect(request)
    return { frames = scene.inspect(request.x or 0, request.y or 0, request.drawnOnly ~= false) }
end

---One frame, for the page's inspector: what it is, where it hangs (its parents, by name or by the key its parent
---holds it under), its anchors, scripts, attributes, the addon that made it, and its children.
function handlers.frameInfo(request)
    local W = require("widgets")
    local S = W.state
    local frame = W.byId[tonumber(request.frameId) or -1] -- (not "id": the host pairs requests and answers by it)
    local s = frame and S[frame]
    if not s then return { error = "no such frame" } end
    local label = scene.frameLabel
    local path, current, depth = {}, s.parent, 0
    while current and S[current] and depth < 30 do
        table.insert(path, 1, { id = S[current].id, name = label(current) })
        current, depth = S[current].parent, depth + 1
    end
    local points = {}
    for _, anchor in ipairs(s.points or {}) do
        local relative = anchor.relative
        points[#points + 1] = { point = anchor.point, relative = type(relative) == "table" and label(relative) or tostring(relative),
            relativePoint = anchor.relativePoint, x = anchor.x, y = anchor.y }
    end
    local scripts = {}
    for name in pairs(s.scripts or {}) do scripts[#scripts + 1] = name end
    table.sort(scripts)
    local attributes = {}
    for key, value in pairs(s.attributes or {}) do
        if #attributes < 40 then attributes[#attributes + 1] = { key = tostring(key), value = tostring(value) } end
    end
    table.sort(attributes, function(first, second) return first.key < second.key end)
    local children = {}
    for _, child in ipairs(s.children or {}) do
        local state = S[child]
        if state and #children < 80 then
            children[#children + 1] = { id = state.id, name = label(child), type = state.type, shown = state.shown == true }
        end
    end
    local rect = W.computeRect(frame)
    local regions = { textures = 0, fontStrings = 0 }
    for _, region in ipairs(s.regions or {}) do
        local state = S[region]
        if state and state.type == "FontString" then regions.fontStrings = regions.fontStrings + 1
        elseif state then regions.textures = regions.textures + 1 end
    end
    return {
        frameId = s.id, name = label(frame), type = s.type, creator = s.creator, path = path, points = points, scripts = scripts,
        attributes = attributes, children = children, regions = regions,
        shown = s.shown == true, visible = s.isFrame and frame:IsVisible() or nil, alpha = frame.GetAlpha and frame:GetAlpha() or nil,
        scale = frame.GetEffectiveScale and math.floor(frame:GetEffectiveScale() * 1000 + 0.5) / 1000 or nil,
        strata = s.isFrame and W.getStrata(frame) or nil, level = s.level,
        mouse = s.mouse == true, wheel = s.mouseWheel == true, keyboard = s.keyboard == true,
        rect = rect and { math.floor(rect[1] + 0.5), math.floor(sim.screenHeight - rect[4] + 0.5), math.floor(rect[3] - rect[1] + 0.5), math.floor(rect[4] - rect[2] + 0.5) } or nil,
    }
end

function handlers.metrics(request)
    fonts.setMetrics(request.metrics or {})
    return { ok = true }
end

function handlers.save()
    sim.fireEvent("PLAYER_LOGOUT")
    addons.saveAll()
    require("layout").save() -- (the frames the player moved: after PLAYER_LOGOUT, which may unflag them)
    saveState()
    return { ok = true }
end

function handlers.clearErrors()
    sim.errors, sim.errorIndex = {}, {}
    sim.version = sim.version + 1
    return { ok = true }
end

return { handlers = handlers, sim = sim, game = game, scene = scene, addons = addons, W = W, json = json,
    saveState = saveState, runSlashCommand = runSlashCommand, bootSeconds = bootSeconds }
