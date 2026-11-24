-- Addons: TOC files (metadata, file lists, dependencies), loading each file into the game's global table with
-- the addon's name and private table, XML <Script>/<Include> files, and SavedVariables kept between runs.
local sim = require("sim")

local addons = { list = {}, byName = {}, loaded = {}, order = {} }
local G = sim.G

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end -- a byte order mark
    return content
end
addons.readFile = readFile

local listDirectory = sim.listDirectory

---Finds a file by its path in the game's spelling (backslashes, any case).
-- (each folder's names come from its listing, kept for the process: no file opened to try a spelling, which on
-- Windows also failed for every folder along the way)
local function findPath(root, relative)
    local current = root
    for part in relative:gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then
            current = current:match("^(.*)/[^/]+$") or current
        elseif part ~= "." then
            local name = sim.getDirectoryIndex(current)[part:lower()]
            if not name then
                return nil
            end
            current = current .. "/" .. name
        end
    end
    return current
end
addons.findPath = findPath

---Picks the TOC the game would: the client's own suffix first, then the plain one.
local function findToc(folder, name, suffixes)
    local names = listDirectory(folder)
    local byLower = {}
    for _, fileName in ipairs(names) do
        byLower[fileName:lower()] = fileName
    end
    for _, suffix in ipairs(suffixes) do
        local candidate = byLower[(name .. suffix .. ".toc"):lower()]
        if candidate then
            return folder .. "/" .. candidate
        end
    end
    for _, fileName in ipairs(names) do
        if fileName:lower():match("%.toc$") then
            return folder .. "/" .. fileName
        end
    end
end

---Whether a TOC line's load conditions hold for this client: [AllowLoadGameType camelot, vanilla],
---[ExcludeLoadGameType ...], and [AllowLoad Glue] (the login screens, never loaded in the game).
local function isLoadAllowed(line, gameTypes)
    local function matches(list)
        for wanted in list:gmatch("[^,%s]+") do
            for _, gameType in ipairs(gameTypes) do
                if wanted:lower() == gameType:lower() then
                    return true
                end
            end
        end
        return false
    end
    local allowed = line:match("%[AllowLoadGameType%s+([^%]]+)%]")
    if allowed and not matches(allowed) then
        return false
    end
    local excluded = line:match("%[ExcludeLoadGameType%s+([^%]]+)%]")
    if excluded and matches(excluded) then
        return false
    end
    local environment = line:match("%[AllowLoad%s+(%a+)%]")
    if environment and environment:lower() == "glue" then
        return false
    end
    return true
end

-- Spaces off both ends, in one pass ("(.-)%s*$" tries the end at every character)
local function trim(text)
    return text:match("^%s*(.*%S)") or ""
end

local function parseTocContent(content, gameTypes)
    local metadata, files = {}, {}
    -- (QuestieDB's baked TOC: 19 MB of "## X-...: data" lines, read here with plain finds)
    local byte, find, sub = string.byte, string.find, string.sub
    for line in content:gmatch("[^\r\n]+") do
        local key, value
        local first, second = byte(line, 1, 2)
        if first == 35 and second == 35 then -- "##"
            local colon = find(line, ":", 3, true)
            if colon and colon > 3 then
                key, value = sub(line, 3, colon - 1), sub(line, colon + 1)
                local keyStart = byte(key, 1)
                if keyStart == 32 or keyStart == 9 then
                    key = key:match("^%s*(.*)")
                end
                local valueStart, valueEnd = byte(value, 1), byte(value, -1)
                if valueStart == 32 or valueStart == 9 or valueEnd == 32 or valueEnd == 9 then
                    value = trim(value)
                end
                if key == "" then
                    key = nil
                end
            end
        end
        if key then
            key = key:lower()
            -- Every spelling the client reads: Dependencies, RequiredDeps, RequiredDep (the world map's), Dep, Deps
            if key == "requireddep" or key == "deps" or key == "dependency" then
                key = "dep"
            end
            if key == "optionaldep" then
                key = "optionaldeps"
            end
            local isDependencyKey = key == "dependencies"
                or key == "requireddeps"
                or key == "dep"
                or key == "optionaldeps"
            if isDependencyKey then
                -- "## Dep: X [AllowLoadGameType mainline]": kept only when this client meets the condition; the
                -- line may come several times, each adding to the list
                if isLoadAllowed(value, gameTypes) then
                    value = value:gsub("%s*%[[^%]]*%]", "")
                    metadata[key] = metadata[key] and (metadata[key] .. "," .. value) or value
                end
            elseif not (key == "allowloadgametype" or key == "excludeloadgametype") or not metadata[key] then
                metadata[key] = value
            end
        elseif not line:match("^%s*#") and line:match("%S") and isLoadAllowed(line, gameTypes) then
            -- Path variables are filled in as this client fills them; load conditions were checked above
            local file = line:gsub("%[Family%]", addons.family or "Mainline")
                :gsub("%[Game%]", addons.game or "Camelot")
                :gsub("%[TextLocale%]", "enUS")
                :gsub("%s*%[[^%]]*%]", "")
            file = trim(file)
            if file ~= "" then
                files[#files + 1] = file
                -- "File.lua [Bootstrap]": run at login though the addon is loaded on demand (its loader function,
                -- RaidFrame_LoadUI), and not again when the addon loads
                if line:lower():find("[bootstrap]", 1, true) then
                    metadata.bootstrapFiles = metadata.bootstrapFiles or {}
                    metadata.bootstrapFiles[file] = true
                end
            end
        end
    end
    -- The whole addon may be for other clients only
    local allowed, excluded = metadata.allowloadgametype, metadata.excludeloadgametype
    if allowed and not isLoadAllowed("[AllowLoadGameType " .. allowed .. "]", gameTypes) then
        metadata.isNotForClient = true
    end
    if excluded and not isLoadAllowed("[ExcludeLoadGameType " .. excluded .. "]", gameTypes) then
        metadata.isNotForClient = true
    end
    -- Only on test clients (the PTR issue reporter): this one is a live build
    if tostring(metadata.onlybetaandptr or ""):match("^%s*1") then
        metadata.isNotForClient = true
    end
    return metadata, files
end

---A TOC as this client reads it: its metadata and files, kept between runs while the file is unchanged (bootcache;
---QuestieDB's baked TOC is 19 MB).
local function parseToc(path, gameTypes)
    local variant = table.concat(gameTypes, ",") .. "-" .. tostring(addons.family) .. "-" .. tostring(addons.game)
    local parsed = require("bootcache").rememberFile(
        "toc-" .. (path:match("([^/\\]+)$") or "toc") .. "-" .. variant,
        path,
        function()
            return readFile(path) or ""
        end,
        function(content)
            local metadata, files = parseTocContent(content, gameTypes)
            return { metadata, files }
        end
    )
    return parsed[1], parsed[2]
end

local function splitList(value)
    local list = {}
    for item in (value or ""):gmatch("[^,%s]+") do
        list[#list + 1] = item
    end
    return list
end

---Whether the client lists an addon by its TOC's "## Interface" (one number or several): not when every number is
---another game line's (120105 is Retail's, 50504 MoP Classic's: a Forever client of 16001 is line 1), as one
---download for every game ships modules only some can run (DBM's Midnight raids, whose LAIR type no Forever tab
---takes). An older number of the same line (11509) is an out-of-date addon: listed. No Interface line: listed.
---@param interface string?
function addons.isForThisGame(interface)
    if not interface or not interface:match("%d") then
        return true
    end
    local line = math.floor((addons.clientInterface or 16001) / 10000)
    for number in interface:gmatch("%d+") do
        if math.floor(tonumber(number) / 10000) == line then
            return true
        end
    end
    return false
end

---One addon's folder, read but not loaded (nothing when it has no TOC). An addon of the same name found before
---(the AddOns folder's copy of a project's own addon) gives way to it, keeping its place in the list.
---@return table? addon
function addons.discoverFolder(folder, suffixes)
    local folderName = folder:match("([^/\\]+)/*$")
    local toc = folderName and findToc(folder, folderName, suffixes)
    if not toc then
        return nil
    end
    local metadata, files = parseToc(toc, addons.gameTypes or { "mainline", "camelot" })
    if not addons.isForThisGame(metadata.interface) then
        return nil
    end
    local earlier = addons.byName[folderName:lower()]
    local addon = {
        name = folderName,
        folder = folder,
        toc = toc,
        metadata = metadata,
        files = files,
        index = earlier and earlier.index or #addons.list + 1,
        title = metadata.title or folderName,
        notes = metadata.notes or "",
        enabled = true,
        dependencies = splitList(
            (metadata.dependencies or "") .. "," .. (metadata.requireddeps or "") .. "," .. (metadata.dep or "")
        ),
        -- (any spelling the client reads: OptionalDeps, OptionalDep (the game's own TOCs), OptionalDependencies (DBM))
        optionalDependencies = splitList(
            (metadata.optionaldeps or "")
                .. ","
                .. (metadata.optionaldep or "")
                .. ","
                .. (metadata.optionaldependencies or "")
        ),
        savedVariables = splitList(metadata.savedvariables),
        savedPerCharacter = splitList(metadata.savedvariablespercharacter),
        loadOnDemand = metadata.loadondemand == "1",
        private = {},
    }
    addons.list[addon.index] = addon
    addons.byName[folderName:lower()] = addon
    return addon
end

---Every addon in the folder, read but not loaded.
function addons.discover(root, suffixes)
    addons.root = addons.root or root
    for _, folderName in ipairs(listDirectory(root)) do
        addons.discoverFolder(root .. "/" .. folderName, suffixes)
    end
end

-- Modules: what each file returns, for the game's import(".Module") (relative to the importing addon) and
-- import("Addon.Module")
local modules, importingAddon, importingFolder = {}, nil, nil
G.import = function(name)
    local addonName, moduleName = name:match("^([^%.]*)%.(.+)$")
    if not addonName then
        return nil
    end
    if addonName == "" then
        addonName = importingAddon
    end
    local addonModules = modules[addonName or ""]
    -- ".Shared" from TargetActionBars\FriendlyTargetingActionBar.lua is TargetActionBars.Shared: beside the importing
    -- file first, then from the addon's own folder
    -- (an "if", not "a and b": that gives false for "Addon.Module", which then never looked further)
    local value
    if addonModules and name:sub(1, 1) == "." and importingFolder then
        value = addonModules[(importingFolder .. "." .. moduleName):lower()]
    end
    if value == nil and addonModules then
        value = addonModules[moduleName:lower()]
    end
    if value == nil then
        sim.reportError("import: no module " .. name, "")
    end
    return value
end

---Runs a Lua file of an addon (compiled once and kept: bootcache), with the addon's name and table.
local function runChunk(path, chunkName, addon)
    if not path then
        return sim.reportError("Couldn't open " .. chunkName, "")
    end
    local chunk, problem = require("bootcache").compileFile(path, "@" .. chunkName, function()
        return readFile(path)
    end)
    if not chunk then
        sim.reportError(problem, "")
        return
    end
    setfenv(chunk, G)
    local previousAddon, previousFolder = importingAddon, importingFolder
    importingAddon = addon.name
    importingFolder = (chunkName:match("^Interface/AddOns/[^/]+/(.+)/[^/]+%.lua$") or ""):gsub("/", ".")
    if importingFolder == "" then
        importingFolder = nil
    end
    local returned
    sim.call(function(...)
        returned = chunk(...)
    end, addon.name, addon.private)
    importingAddon, importingFolder = previousAddon, previousFolder
    -- Interface/AddOns/Addon/Folder/File.lua is module Folder.File of the addon
    local moduleName = chunkName:match("^Interface/AddOns/[^/]+/(.+)%.lua$")
    if moduleName and returned ~= nil then
        modules[addon.name] = modules[addon.name] or {}
        modules[addon.name][moduleName:gsub("/", "."):lower()] = returned
    end
end

local function loadXml(addon, path, relativeFolder)
    local xmlui = require("xmlui")
    xmlui.loadFile(path, {
        folder = addon.folder,
        name = addon.name,
        private = addon.private,
        findPath = findPath,
        runLua = function(target, relative)
            runChunk(target, "Interface/AddOns/" .. addon.name .. "/" .. relative:gsub("\\", "/"), addon)
        end,
    }, relativeFolder)
end

-- Saved variables: written as Lua, read back by running them
local function serialize(value, indent, seen)
    local valueType = type(value)
    if valueType == "string" then
        return string.format("%q", value)
    end
    if valueType == "number" then
        if value ~= value then
            return "0/0"
        end
        if value == math.huge then
            return "math.huge"
        end
        if value == -math.huge then
            return "-math.huge"
        end
        return string.format("%.17g", value)
    end
    if valueType == "boolean" or valueType == "nil" then
        return tostring(value)
    end
    if valueType ~= "table" or seen[value] then
        return "nil"
    end
    seen[value] = true
    local parts, padding = { "{\n" }, string.rep("\t", indent + 1)
    local keys = {}
    for key in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" or keyType == "boolean" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(first, second)
        if type(first) == type(second) then
            return first < second
        end
        return type(first) == "number"
    end)
    for _, key in ipairs(keys) do
        local item = value[key]
        if type(item) ~= "function" and type(item) ~= "userdata" then
            parts[#parts + 1] = padding
                .. "["
                .. serialize(key, 0, seen)
                .. "] = "
                .. serialize(item, indent + 1, seen)
                .. ",\n"
        end
    end
    seen[value] = nil
    parts[#parts + 1] = string.rep("\t", indent) .. "}"
    return table.concat(parts)
end

function addons.savedPath(addon)
    return addons.savedRoot .. "/" .. addon.name .. ".lua"
end

local function loadSaved(addon)
    local content = readFile(addons.savedPath(addon))
    if content then
        local chunk, problem = loadstring(content, "@SavedVariables/" .. addon.name)
        if chunk then
            setfenv(chunk, G)
            sim.call(chunk)
        else
            sim.reportError(problem, "")
        end
    end
end

function addons.saveAll()
    for _, addon in ipairs(addons.order) do
        local names = {}
        for _, name in ipairs(addon.savedVariables) do
            names[#names + 1] = name
        end
        for _, name in ipairs(addon.savedPerCharacter) do
            names[#names + 1] = name
        end
        if #names > 0 then
            local parts = {}
            for _, name in ipairs(names) do
                parts[#parts + 1] = name .. " = " .. serialize(rawget(G, name), 0, {}) .. "\n"
            end
            local file = io.open(addons.savedPath(addon), "wb")
            if file then
                file:write(table.concat(parts))
                file:close()
            end
        end
    end
end

---Loads an addon and, first, what it depends on.
---Runs single files of one of the game's addons whose whole would pull in far more than is wanted
---(the slash-command registry of Blizzard_ChatFrameBase, without the chat frames).
function addons.runFiles(name, files)
    local addon = addons.byName[name:lower()]
    if not addon then
        return sim.reportError("No addon " .. name, "")
    end
    for _, file in ipairs(files) do
        local path = findPath(addon.folder, file)
        if path and file:lower():match("%.xml$") then
            loadXml(addon, path, (file:gsub("/", "\\")):match("^(.*)\\[^\\]+$") or "") -- either slash: "[Family]/ChannelButton.xml"
        elseif path then
            runChunk(path, "Interface/AddOns/" .. addon.name .. "/" .. file:gsub("\\", "/"), addon)
        else
            sim.reportError("Couldn't open " .. name .. "\\" .. file, "")
        end
    end
end

---@param isGameAddon boolean? One of the game's own: no saved variables, no ADDON_LOADED wait
---Reads a Bindings XML (the game's Bindings_Camelot.xml, or an addon's Bindings.xml): each <Binding name="X">Lua
---</Binding> becomes the command's code, compiled once, which the keys run (scene's runBindingCommand). The code
---sees `keystate` ("down" or "up"), as in the client.
---@return number count Bindings read
function addons.readBindings(path, chunkPrefix)
    local root = require("xml").parseFile(path)
    if not root then
        return 0
    end
    sim.bindingCode = sim.bindingCode or {}
    -- Every binding in the order the files list them, with its category: the key bindings window (GetBinding)
    sim.bindingList, sim.bindingListed = sim.bindingList or {}, sim.bindingListed or {}
    local count = 0
    local function visit(element)
        -- The modifier keys the game's clicks take by default (Shift for auto loot, Alt for self-cast): GetModifiedClick
        if element.tag == "ModifiedClick" and element.attrs.action then
            sim.modifiedClicks = sim.modifiedClicks or {}
            if sim.modifiedClicks[element.attrs.action] == nil then
                sim.modifiedClicks[element.attrs.action] = element.attrs.default or "NONE"
            end
        end
        if element.tag == "Binding" and element.attrs.name and not sim.bindingListed[element.attrs.name] then
            sim.bindingListed[element.attrs.name] = true
            table.insert(sim.bindingList, { command = element.attrs.name, category = element.attrs.category })
        end
        if element.tag == "Binding" and element.attrs.name and element.text and element.text:match("%S") then
            local chunk, problem =
                loadstring("local keystate = ...\n" .. element.text, "@" .. chunkPrefix .. ":" .. element.attrs.name)
            if chunk then
                setfenv(chunk, G)
                sim.bindingCode[element.attrs.name] = chunk
                -- (run on the key's release too, with keystate "up": the gamepad's buttons and modifiers)
                sim.bindingRunsOnUp = sim.bindingRunsOnUp or {}
                sim.bindingRunsOnUp[element.attrs.name] = element.attrs.runOnUp == "true" or nil
                count = count + 1
            else
                sim.reportError(problem, "")
            end
        end
        for _, child in ipairs(element.children or {}) do
            visit(child)
        end
    end
    visit(root)
    return count
end

---Runs the "[Bootstrap]" files of the game's addons loaded on demand, as the client does at login: each defines
---how its addon is loaded when wanted (Blizzard_RaidUI's RaidFrame_LoadUI), with the addon's name and table.
function addons.runBootstraps(isForGame)
    for _, addon in ipairs(addons.list) do
        local bootstraps = addon.metadata.bootstrapFiles
        if
            bootstraps
            and addon.loadOnDemand
            and not addons.loaded[addon.name]
            and not addon.isBootstrapped
            and not addon.metadata.isNotForClient
            and (not isForGame or addon.name:match("^Blizzard_"))
        then
            addon.isBootstrapped = true
            for _, file in ipairs(addon.files) do
                local path = bootstraps[file] and file:lower():match("%.lua$") and findPath(addon.folder, file)
                if path then
                    runChunk(path, "Interface/AddOns/" .. addon.name .. "/" .. file:gsub("\\", "/"), addon)
                end
            end
        end
    end
end

function addons.load(name, isDependency, isGameAddon)
    local addon = addons.byName[name:lower()]
    if not addon then
        if not isDependency then
            sim.reportError("Addon not found: " .. name, "")
        end
        return false
    end
    if addons.loaded[addon.name] then
        return true
    end
    if addon.isLoading then
        return false
    end
    addon.isLoading = true
    for _, dependency in ipairs(addon.dependencies) do
        local isGameDependency = dependency:match("^Blizzard_") ~= nil
        if isGameDependency then
            -- The game's own: with the whole interface (blizzardAddons "all"), one of the game's addons loads the
            -- game's addons it needs first, as the client does; otherwise those the simulator loads are there already,
            -- and the rest of the game's interface (the objective tracker, edit mode...) it does not run
            if addons.loadsGameDependencies and isGameAddon then
                addons.load(dependency, true, true)
            end
        elseif not addons.load(dependency, true) then
            sim.reportError(addon.name .. " needs " .. dependency .. ", which is not installed", "")
        end
    end
    -- Optional dependencies come first when they are among the addons asked for; they are not pulled in
    -- (the game's own, with the whole interface: those of the game's it names that load at login, as the client
    -- orders them; Blizzard_EnvironmentCleanup takes loadstring_untainted away after the restricted environment
    -- keeps it, so that one first)
    for _, dependency in ipairs(addon.optionalDependencies) do
        local optional = addons.byName[dependency:lower()]
        local isGameOne = addons.loadsGameDependencies
            and isGameAddon
            and dependency:match("^Blizzard_") ~= nil
            and optional ~= nil
            and (addons.loginGameAddons or {})[dependency:lower()] == true
        -- (one loaded on demand is not loaded for it: an optional dependency only orders the two)
        local isOnDemand = optional ~= nil and optional.loadOnDemand and not isGameOne
        if ((addons.wanted and addons.wanted[dependency:lower()]) or isGameOne) and not isOnDemand then
            addons.load(dependency, true, isGameOne or nil)
        end
    end
    local startedAt = os.clock()
    for _, file in ipairs(addon.files) do
        local path = findPath(addon.folder, file)
        if addon.isBootstrapped and (addon.metadata.bootstrapFiles or {})[file] then
            -- (run at login already: addons.runBootstraps)
        elseif not path then
            sim.reportError("Couldn't open " .. addon.name .. "\\" .. file, "")
        elseif file:lower():match("%.lua$") then
            runChunk(path, "Interface/AddOns/" .. addon.name .. "/" .. file:gsub("\\", "/"), addon)
        elseif file:lower():match("%.xml$") then
            loadXml(addon, path, (file:gsub("/", "\\")):match("^(.*)\\[^\\]+$") or "") -- either slash: "[Family]/ChannelButton.xml"
        end
    end
    -- An addon's Bindings.xml is read with it, as the client reads it: its key commands
    local bindingsPath = findPath(addon.folder, "Bindings.xml")
    if bindingsPath then
        addons.readBindings(bindingsPath, "Interface/AddOns/" .. addon.name .. "/Bindings.xml")
    end
    if not isGameAddon then
        loadSaved(addon)
    end
    addon.isGameAddon = isGameAddon
    addons.loaded[addon.name] = true
    addon.loadSeconds = os.clock() - startedAt
    addon.isLoading = false
    addons.order[#addons.order + 1] = addon
    sim.fireEvent("ADDON_LOADED", addon.name)
    return true
end

function addons.install()
    local function find(target)
        if type(target) == "number" then
            return addons.list[target]
        end
        return target and addons.byName[tostring(target):lower()]
    end
    local function getMetadata(target, key)
        local addon = find(target)
        return addon and addon.metadata[tostring(key):lower()] or nil
    end
    local function getInfo(target)
        local addon = find(target)
        if not addon then
            return nil
        end
        return addon.name,
            addon.title,
            addon.notes,
            addon.enabled,
            addon.enabled and nil or "DISABLED",
            "INSECURE",
            false
    end
    G.C_AddOns = {
        GetAddOnMetadata = getMetadata,
        GetNumAddOns = function()
            return #addons.list
        end,
        GetAddOnInfo = getInfo,
        -- Loaded or loading (its files running now), and loaded: as the client answers while an addon loads
        -- (EllesmereUI accepts its settings pages only while its options addon is loading or just logged in)
        IsAddOnLoaded = function(target)
            local addon = find(target)
            local isLoaded = addon ~= nil and addons.loaded[addon.name] == true
            return isLoaded or (addon ~= nil and addon.isLoading == true), isLoaded
        end,
        IsAddOnLoadOnDemand = function(target)
            local addon = find(target)
            return addon ~= nil and addon.loadOnDemand
        end,
        -- One of the game's own loaded on demand (ProfessionsFrame_LoadUI) loads the game's addons it depends on
        -- first, as the client does (Blizzard_Professions needs Blizzard_ProfessionsTemplates)
        LoadAddOn = function(target)
            local addon = find(target)
            if not addon then
                return false, "MISSING"
            end
            return addons.load(addon.name, false, addon.isGameAddon or addon.name:match("^Blizzard_") ~= nil), nil
        end,
        EnableAddOn = function(target)
            local addon = find(target)
            if addon then
                addon.enabled = true
            end
        end,
        DisableAddOn = function(target)
            local addon = find(target)
            if addon then
                addon.enabled = false
                addons.disabled = addons.disabled or {}
                addons.disabled[addon.name] = true
            end
        end,
        GetAddOnEnableState = function(target)
            local addon = find(target)
            return addon and addon.enabled and 2 or 0
        end,
        DoesAddOnExist = function(target)
            return find(target) ~= nil
        end,
        -- Whether it can be loaded: there, for this game, switched on (and why not)
        IsAddOnLoadable = function(target)
            local addon = find(target)
            if not addon then
                return false, "MISSING"
            end
            if not addon.enabled then
                return false, "DISABLED"
            end
            return true, nil
        end,
        GetAddOnDependencies = function(target)
            local addon = find(target)
            return unpack(addon and addon.dependencies or {})
        end,
        GetAddOnOptionalDependencies = function(target)
            local addon = find(target)
            return unpack(addon and addon.optionalDependencies or {})
        end,
        IsAddonVersionCheckEnabled = function()
            return false
        end,
        SaveAddOns = function() end,
        ResetAddOns = function() end,
    }
    G.GetAddOnMetadata = getMetadata
    G.GetNumAddOns = G.C_AddOns.GetNumAddOns
    G.GetAddOnInfo = getInfo
    G.IsAddOnLoaded = G.C_AddOns.IsAddOnLoaded
    G.LoadAddOn = G.C_AddOns.LoadAddOn
    G.EnableAddOn = G.C_AddOns.EnableAddOn
    G.DisableAddOn = G.C_AddOns.DisableAddOn
    G.GetAddOnEnableState = function(_, target)
        return G.C_AddOns.GetAddOnEnableState(target)
    end
end

sim.stackBoundaries[addons.load] = true -- (a stack walk for the calling addon stops here)

return addons
