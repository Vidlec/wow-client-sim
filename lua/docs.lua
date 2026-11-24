-- The client's own API documentation (Blizzard_APIDocumentationGenerated): every enumeration and constant the
-- game defines, exactly, and a stand-in for each documented function the simulator does not implement yet. A
-- stand-in returns the empty value of each documented return type and is noted, so it is never silently real.
local sim = require("sim")

local docs = {}
local G = sim.G

local NUMBER_TYPES = {
    number = true,
    luaIndex = true,
    time_t = true,
    BigInteger = true,
    BigUInteger = true,
    size = true,
    fileID = true,
    uiMapID = true,
    TBFFlags = true,
    TBFStyleFlags = true,
    SingleColorValue = true,
    uiUnit = true,
    normalizedValue = true,
    textureAtlas = false,
}
local STRING_TYPES = {
    string = true,
    cstring = true,
    WOWGUID = true,
    textureAtlas = true,
    kstringClubMessage = true,
    ClubId = true,
    mouseButton = true,
}

-- The client's documented script objects that are not widgets (a seconds formatter, a curve, a timed signal map),
-- by type name: their methods, as documented. A function returning one hands out a fresh object of stand-ins.
local objectFunctions = {}
local makeObject

local function emptyValue(returned)
    if returned.Nilable then
        return nil
    end
    local valueType = returned.Type
    if objectFunctions[valueType] then
        return makeObject(valueType)
    end
    if valueType == "bool" then
        return false
    end
    if NUMBER_TYPES[valueType] then
        return 0
    end
    if STRING_TYPES[valueType] then
        return ""
    end
    if returned.Mixin == "ColorMixin" and G.CreateColor then
        return G.CreateColor(1, 1, 1, 1)
    end
    if returned.Mixin == "Vector2DMixin" and G.CreateVector2D then
        return G.CreateVector2D(0, 0)
    end
    if valueType == "table" then
        return {}
    end
    -- A structure or an enumeration value: nothing is safer than a made-up one. The documentation's "never nil"
    -- is not to be trusted for structures: C_AddOnProfiler.CheckForPerformanceMessage is documented so, and the
    -- game's code checks it for nil (an empty message made from its fields broke that code)
    return nil
end

local function makeStub(fullName, returns)
    return sim.markStandIn(function()
        sim.noteStub(fullName)
        -- Only up to the last value that is not nil: "returns nothing" is what a nilable result most often means
        local values, count = {}, 0
        for index, returned in ipairs(returns or {}) do
            values[index] = emptyValue(returned)
            if values[index] ~= nil then
                count = index
            end
        end
        return unpack(values, 1, count)
    end)
end

---@return boolean known The documentation describes this script object type (SecondsFormatter, LuaCurveObject...)
function docs.knowsObject(typeName)
    return objectFunctions[typeName] ~= nil
end

---@return table object An object of a documented type, each method a noted stand-in (setters do nothing, getters
---give the empty value of what they return)
makeObject = function(typeName)
    local object = {}
    for _, documented in ipairs(objectFunctions[typeName] or {}) do
        local stub = makeStub(typeName .. ":" .. documented.Name, documented.Returns)
        object[documented.Name] = function(_, ...)
            return stub(...)
        end
    end
    return object
end

-- Which simulator widget type each documented script object's methods belong to
local WIDGET_TYPES = {
    SimpleObjectAPI = "Object",
    SimpleFrameScriptObjectAPI = "Object",
    SimpleScriptRegionAPI = "Region",
    SimpleScriptRegionResizingAPI = "Region",
    SimpleRegionAPI = "Region",
    SimpleTextureBaseAPI = "Texture",
    SimpleTextureAPI = "Texture",
    SimpleMaskTextureAPI = "MaskTexture",
    SimpleLineAPI = "Line",
    SimpleFontStringAPI = "FontString",
    SimpleFrameAPI = "Frame",
    SimpleButtonAPI = "Button",
    SimpleCheckboxAPI = "CheckButton",
    SimpleEditBoxAPI = "EditBox",
    SimpleScrollFrameAPI = "ScrollFrame",
    SimpleSliderAPI = "Slider",
    SimpleStatusBarAPI = "StatusBar",
    FrameAPICooldown = "Cooldown",
    SimpleMessageFrameAPI = "MessageFrame",
    SimpleModelAPI = "Model",
    FrameAPIModelSceneFrame = "ModelScene",
    SimpleColorSelectAPI = "ColorSelect",
    SimpleHTMLAPI = "SimpleHTML",
    MinimapFrameAPI = "Minimap",
    FrameAPITooltip = "GameTooltip",
    FrameAPIFogOfWarFrame = "FogOfWarFrame",
    FrameAPIQuestPOI = "QuestPOIFrame",
    FrameAPIScenarioPOI = "ScenarioPOIFrame",
    FrameAPIUnitPositionFrame = "UnitPositionFrame",
    FrameAPIArchaeologyDigSiteFrame = "ArchaeologyDigSiteFrame",
    FrameAPIBlob = "Blob",
    FrameAPINamePlate = "NamePlate",
}

---Every documented widget method the simulator's widgets lack, as a noted stand-in, on that type and all built on it.
local function addWidgetMethods(systems)
    local W = require("widgets")
    local count = 0
    for _, system in ipairs(systems) do
        local typeName = WIDGET_TYPES[system.Name]
        if typeName and W.types[typeName] then
            for _, documented in ipairs(system.Functions or {}) do
                local stub
                for _, definition in pairs(W.types) do
                    if definition.chain[typeName] and definition.methods[documented.Name] == nil then
                        stub = stub or makeStub(typeName .. ":" .. documented.Name, documented.Returns)
                        definition.methods[documented.Name] = stub
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

---@return number enums, number functions Enumerations defined; stand-ins added
function docs.load(folder)
    local files = {}
    for _, fileName in ipairs(require("sim").listDirectory(folder)) do
        if fileName:match("Documentation%.lua$") then
            files[#files + 1] = folder .. "/" .. fileName
        end
    end
    local systems
    local chunks = {} -- (each file compiled once, run for each reading)
    local bootcache = require("bootcache")
    for index, path in ipairs(files) do
        chunks[index] = bootcache.compileFile(path, "@" .. path, function()
            local file = io.open(path, "rb")
            if not file then
                return nil
            end
            local content = file:read("*a")
            file:close()
            return content
        end) or false
    end
    local function readAll()
        systems = {}
        local collector = {
            AddDocumentationTable = function(_, documentation)
                systems[#systems + 1] = documentation
            end,
        }
        for _, chunk in ipairs(chunks) do
            if chunk then
                setfenv(
                    chunk,
                    setmetatable(
                        { APIDocumentation = collector, Enum = rawget(G, "Enum"), Constants = rawget(G, "Constants") },
                        { __index = _G }
                    )
                )
                pcall(chunk)
            end
        end
    end
    -- Twice: constants refer to enumerations' metadata (Enum.LFGRoleMeta.NumValues), which the first reading makes
    readAll()
    for _, system in ipairs(systems) do
        for _, documented in ipairs(system.Tables or {}) do
            if documented.Type == "Enumeration" and documented.Name then
                -- (documented whole: a value it does not name is not this client's, nil as in the game: an addon's
                -- Enum.ItemWeaponSubclass.Bow, a later client's name for Bows)
                local values = {}
                for _, field in ipairs(documented.Fields or {}) do
                    rawset(values, field.Name, field.EnumValue)
                end
                rawset(rawget(G, "Enum"), documented.Name, values)
                rawset(
                    rawget(G, "Enum"),
                    documented.Name .. "Meta",
                    { NumValues = documented.NumValues, MinValue = documented.MinValue, MaxValue = documented.MaxValue }
                )
            end
        end
    end
    readAll()
    -- The documented objects that are not widgets: "SecondsFormatterAPI" is the SecondsFormatter type, and a
    -- "...BaseAPI" system's methods belong to the type built on it as well (LuaCurveObjectBaseAPI, LuaCurveObject)
    for _, system in ipairs(systems) do
        if system.Type == "ScriptObject" and system.Name and not WIDGET_TYPES[system.Name] then
            local typeName = system.Name:gsub("API$", "")
            local baseOwner = typeName:gsub("Base$", "")
            for _, owner in ipairs(baseOwner ~= typeName and { typeName, baseOwner } or { typeName }) do
                objectFunctions[owner] = objectFunctions[owner] or {}
                for _, documented in ipairs(system.Functions or {}) do
                    table.insert(objectFunctions[owner], documented)
                end
            end
        end
    end
    local enumCount, stubCount = 0, 0
    local enum, constants = rawget(G, "Enum"), rawget(G, "Constants")
    for _, system in ipairs(systems) do
        for _, documented in ipairs(system.Tables or {}) do
            if documented.Type == "Enumeration" and documented.Name then
                local values = rawget(enum, documented.Name) or {}
                for _, field in ipairs(documented.Fields or {}) do
                    rawset(values, field.Name, field.EnumValue)
                end
                rawset(enum, documented.Name, values)
                rawset(
                    enum,
                    documented.Name .. "Meta",
                    { NumValues = documented.NumValues, MinValue = documented.MinValue, MaxValue = documented.MaxValue }
                )
                enumCount = enumCount + 1
            elseif documented.Type == "Constants" and documented.Name then
                local values = rawget(constants, documented.Name)
                    or sim.makeUnknownValues("Constants." .. documented.Name)
                for _, value in ipairs(documented.Values or {}) do
                    rawset(values, value.Name, value.Value)
                end
                rawset(constants, documented.Name, values)
            end
        end
        -- Every event the client has, so registering one it has not fails as in the game; and those addons may not
        -- register (the combat log): noted when an addon tries, and never sent to it
        for _, documented in ipairs(system.Events or {}) do
            if documented.LiteralName then
                sim.knownEvents[documented.LiteralName] = true
            end
            if documented.HasRestrictions and documented.LiteralName then
                sim.restrictedEvents[documented.LiteralName] = true
            end
        end
        local namespace = system.Namespace
        for _, documented in ipairs(system.Type ~= "ScriptObject" and system.Functions or {}) do
            if namespace then
                local target = rawget(G, namespace)
                if type(target) ~= "table" then
                    target = {}
                    rawset(G, namespace, target)
                end
                if target[documented.Name] == nil then
                    target[documented.Name] = makeStub(namespace .. "." .. documented.Name, documented.Returns)
                    stubCount = stubCount + 1
                end
            elseif documented.Name and rawget(G, documented.Name) == nil then
                rawset(G, documented.Name, makeStub(documented.Name, documented.Returns))
                stubCount = stubCount + 1
            end
        end
    end
    -- Constants given as sums of others (NUM_SLOTS_PER_GAMEPAD_ACTION_BAR = GROUP * GROUPS) were worked out before
    -- those others were set, from made-up stand-in numbers: read again now that they are, twice for chains of them
    for _ = 1, 2 do
        readAll()
        for _, system in ipairs(systems) do
            for _, documented in ipairs(system.Tables or {}) do
                if documented.Type == "Constants" and documented.Name then
                    local values = rawget(constants, documented.Name)
                    for _, value in ipairs(values and documented.Values or {}) do
                        rawset(values, value.Name, value.Value)
                    end
                end
            end
        end
    end
    docs.methodCount = addWidgetMethods(systems)
    return enumCount, stubCount
end

docs.makeObject = function(typeName)
    return makeObject(typeName)
end

return docs
