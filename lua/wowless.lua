-- The client's API as wowless knows it (github.com/wowless/wowless, MIT; fetched by `bun run wowless` into
-- cache/wowless/<product>/). wowless reads the client itself, so it knows what the game's documentation gets wrong:
-- which functions may return nothing (C_AddOnProfiler.CheckForPerformanceMessage, documented never nil), what a
-- stand-in should give (C_Scenario.GetInfo's 0 stages, GetNetStats's two latencies), every console variable's
-- default, the client's constants, and the namespaces only the game's own secure addons see.
--
-- What it changes: each function that only stands in for the client's (sim.standIns) gets a stand-in made from
-- wowless's description; a function the simulator really does is never touched. Console variable defaults and
-- constants fill what the simulator and the recorder's dump do not have.
local sim = require("sim")
local json = require("json")

local wowless = {}
local G = sim.G

-- (kept decoded between runs while the file is unchanged: bootcache)
local function readJson(path)
    local function read()
        local file = io.open(path, "rb")
        if not file then
            return nil
        end
        local content = file:read("*a")
        file:close()
        return content
    end
    local kept = require("bootcache").rememberFile(
        "wowless-" .. (path:match("([^/\\]+)$") or "json"),
        path,
        read,
        function(content)
            local isRead, value = pcall(json.decode, content)
            return { value = isRead and value or nil }
        end
    )
    return kept and kept.value
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local structures = {}

---One of the client's Lua objects (a seconds formatter, a timed signal map, a duration): as the documentation
---describes it when it does (wowless and the documentation name some differently: LuaTimedSignalMapObject), else
---an object whose every method is a noted stand-in doing nothing
local function makeLuaObject(typeName)
    local docs = require("docs")
    for _, name in ipairs({
        typeName,
        (typeName:gsub("^Lua", "")),
        (typeName:gsub("Object$", "")),
        (typeName:gsub("^Lua", ""):gsub("Object$", "")),
    }) do
        if docs.knowsObject and docs.knowsObject(name) then
            return docs.makeObject(name)
        end
    end
    return setmetatable({}, {
        __index = function(object, key)
            local method = function()
                sim.noteStub(typeName .. ":" .. tostring(key))
            end
            rawset(object, key, method)
            return method
        end,
    })
end

---The value a stand-in gives for one of wowless's described values: its stub when it names one, else the empty
---value of its type (a structure with its fields that are always there, an enumeration's lowest value)
local function defaultFor(spec, depth)
    if type(spec) ~= "table" or spec.nilable then
        return nil
    end
    -- A list wowless stubs as nil is still a list in the client: the game's code walks C_NamePlate.GetNamePlates with
    -- pairs as it loads
    if spec.stubnil then
        return type(spec.type) == "table" and spec.type.arrayof and {} or nil
    end
    if spec.stub ~= nil then
        return copy(spec.stub)
    end
    local valueType = spec.type
    if valueType == "number" then
        return 0
    end
    if valueType == "boolean" then
        return false
    end
    if valueType == "string" then
        return ""
    end
    if valueType == "table" then
        return {}
    end
    if type(valueType) == "table" then
        if valueType.arrayof then
            return {}
        end
        if valueType.enum then
            local values, lowest = rawget(G.Enum or {}, valueType.enum), nil
            for _, value in pairs(type(values) == "table" and values or {}) do
                if type(value) == "number" and (lowest == nil or value < lowest) then
                    lowest = value
                end
            end
            return lowest
        end
        if valueType.luaobject then
            return makeLuaObject(valueType.luaobject)
        end
        local structure = valueType.structure and structures[valueType.structure]
        if structure and (depth or 0) < 5 then
            local value = {}
            local isColor = structure.mixin == "ColorMixin"
            for name, field in pairs(type(structure.fields) == "table" and structure.fields or {}) do
                -- A colour stands in as white, as the game's code most often draws with it
                value[name] = isColor and 1 or defaultFor(field, (depth or 0) + 1)
            end
            -- With its mixin's methods, as the client hands it out (a colour's GenerateHexColorMarkup, a vector's GetXY)
            local mixin = structure.mixin and rawget(G, structure.mixin)
            if type(mixin) == "table" then
                for name, method in pairs(mixin) do
                    if value[name] == nil then
                        value[name] = method
                    end
                end
            end
            return value
        end
    end
    return nil -- a widget, "any": nothing is safer than a made-up one
end

local function makeStandIn(fullName, spec)
    local outputs = type(spec.outputs) == "table" and spec.outputs or {}
    -- Values given as a repeated list at the end ("outstride"): as many times as wowless's stub says, else none
    local strideLength = tonumber(spec.outstride) or 0
    local strideCount = tonumber(spec.stuboutstrides) or 0
    return sim.markStandIn(function()
        sim.noteStub(fullName)
        -- Nothing when the client may give nothing: for a character with nothing going on that is its answer (an
        -- alternate power bar's info, an aura), and a made-up something makes the game show bars for it
        if spec.stubnothing or spec.mayreturnnothing then
            return
        end
        local values, count = {}, 0
        local fixedCount = #outputs - (strideLength > 0 and strideLength or 0)
        for index = 1, fixedCount do
            count = count + 1
            values[count] = defaultFor(outputs[index])
        end
        for _ = 1, strideLength > 0 and strideCount or 0 do
            for index = fixedCount + 1, #outputs do
                count = count + 1
                values[count] = defaultFor(outputs[index])
            end
        end
        return unpack(values, 1, count)
    end)
end

-- Fields of widgets that wowless's getters and setters read and write (GetDoBlend, SetKeepModelOnHide...), per object
local fieldValues = setmetatable({}, { __mode = "k" })

---@return table methods Every method of a wowless widget type and the types it is built on, by name
local function collectMethods(uiobjects, typeName, methods, fields, seen)
    methods, fields, seen = methods or {}, fields or {}, seen or {}
    local spec = uiobjects[typeName]
    if type(spec) ~= "table" or seen[typeName] then
        return methods, fields
    end
    seen[typeName] = true
    -- (an empty map reads as true from wowless's YAML)
    for name, method in pairs(type(spec.methods) == "table" and spec.methods or {}) do
        if methods[name] == nil then
            methods[name] = method
        end
    end
    for name, field in pairs(type(spec.fields) == "table" and spec.fields or {}) do
        if fields[name] == nil then
            fields[name] = field
        end
    end
    for parentName in pairs(type(spec.inherits) == "table" and spec.inherits or {}) do
        collectMethods(uiobjects, parentName, methods, fields, seen)
    end
    return methods, fields
end

---A widget method from wowless's spec: a field's getter or setter works on the object's own value; any other
---method is a noted stand-in giving wowless's default answer.
local function makeWidgetMethod(typeName, methodName, spec, fields)
    local impl = type(spec.impl) == "table" and spec.impl or {}
    if type(impl.getter) == "table" then
        local names = {}
        for index, entry in ipairs(impl.getter) do
            names[index] = entry.name
        end
        return function(self)
            local values = fieldValues[self] or {}
            local results = {}
            for index, name in ipairs(names) do
                local value = values[name]
                if value == nil and fields[name] then
                    value = fields[name].init
                end
                results[index] = value
            end
            return unpack(results, 1, #names)
        end
    elseif type(impl.setter) == "table" then
        local names = {}
        for index, entry in ipairs(impl.setter) do
            names[index] = entry.name
        end
        return function(self, ...)
            local values = fieldValues[self] or {}
            fieldValues[self] = values
            for index, name in ipairs(names) do
                values[name] = (select(index, ...))
            end
        end
    end
    return makeStandIn(typeName .. ":" .. methodName, spec)
end

---Every method the client's widgets have and the simulator's lack (wowless's uiobjects: PlayerModel:RefreshCamera
---that the game's model frames call), on each simulator type whose counterpart, or a type it is built on, has it.
---@return number count Methods added
local function addWidgetMethods(uiobjects)
    local W = require("widgets")
    local count = 0
    for typeName, definition in pairs(W.types) do
        -- A simulator type the client does not name (ScrollingMessageFrame, DropdownButton): its nearest ancestor's
        local counterpart = typeName
        while counterpart and not uiobjects[counterpart] do
            counterpart = W.types[counterpart] and W.types[counterpart].parent
        end
        if counterpart then
            local methods, fields = collectMethods(uiobjects, counterpart)
            for methodName, spec in pairs(methods) do
                if definition.methods[methodName] == nil and type(spec) == "table" then
                    definition.methods[methodName] = makeWidgetMethod(typeName, methodName, spec, fields)
                    count = count + 1
                end
            end
        end
    end
    return count
end

---@return string folder Where `bun run wowless` keeps the product's data
function wowless.folder(root, config)
    return root .. "/cache/wowless/" .. (config.wowlessProduct or "wowf")
end

---Applies wowless's data, when it was fetched. With the game's whole interface loaded (isWholeInterface), every
---function the client has and the simulator lacks is added as a stand-in too, and the secure addons' namespaces.
---@return table? summary What was applied, or nil when there is no data
function wowless.apply(root, config, isWholeInterface)
    local folder = wowless.folder(root, config)
    local apis = readJson(folder .. "/apis.json")
    if not apis then
        return nil
    end
    for name, structure in pairs(readJson(folder .. "/structures.json") or {}) do
        structures[name] = structure
    end
    local summary = { replaced = 0, added = 0, cvars = 0, constants = 0, secureNamespaces = 0 }

    -- Console variables: the client's names are case-blind, wowless writes them in lower case
    sim.cvarDefaultsLower = sim.cvarDefaultsLower or {}
    for name, cvar in pairs(readJson(folder .. "/cvars.json") or {}) do
        if type(cvar) == "table" and type(cvar.default) == "string" then
            sim.cvarDefaultsLower[name:lower()] = cvar.default
            summary.cvars = summary.cvars + 1
        end
    end

    -- Constants: what is missing, never over what the simulator or the documentation set
    for name, value in pairs(readJson(folder .. "/globals.json") or {}) do
        local existing = rawget(G, name)
        if existing == nil then
            rawset(G, name, copy(value))
            summary.constants = summary.constants + 1
        elseif type(existing) == "table" and type(value) == "table" then
            for key, item in pairs(value) do
                local inner = rawget(existing, key)
                if inner == nil then
                    rawset(existing, key, copy(item))
                    summary.constants = summary.constants + 1
                elseif type(inner) == "table" and type(item) == "table" then
                    -- The client's own values win over the documentation's for Constants: it gives some as sums of
                    -- others (NUM_SLOTS_PER_GAMEPAD_ACTION_BAR = GROUP * GROUPS), which read as made-up numbers
                    local isConstants = name == "Constants"
                    for innerKey, innerItem in pairs(item) do
                        if isConstants and type(innerItem) ~= "table" and rawget(inner, innerKey) ~= innerItem then
                            rawset(inner, innerKey, copy(innerItem))
                            summary.constants = summary.constants + 1
                        elseif rawget(inner, innerKey) == nil then
                            rawset(inner, innerKey, copy(innerItem))
                            summary.constants = summary.constants + 1
                        end
                    end
                end
            end
        end
    end

    -- The secure addons' own namespaces (the store, the WoW token, authentication): the game's capsule addons
    -- use them; ordinary addons never see them
    local secureNamespaces = {}
    local config_ = readJson(folder .. "/config.json")
    local capsule = config_ and config_.addon and config_.addon.capsule
    for namespace in pairs(capsule and capsule.apinamespaces or {}) do
        secureNamespaces[namespace] = true
        if isWholeInterface then
            -- wowless lists few of their functions: any other is a noted stand-in giving nothing
            local target = rawget(G, namespace)
            if type(target) ~= "table" then
                target = {}
                rawset(G, namespace, target)
            end
            if getmetatable(target) == nil then
                setmetatable(target, {
                    __index = function(_, key)
                        return sim.markStandIn(function()
                            sim.noteStub(namespace .. "." .. tostring(key))
                        end)
                    end,
                })
            end
            sim.secureOnlyNamespaces = sim.secureOnlyNamespaces or {}
            sim.secureOnlyNamespaces[namespace] = true
            summary.secureNamespaces = summary.secureNamespaces + 1
        end
    end

    sim.secureOnlyFunctions = sim.secureOnlyFunctions or {}
    for fullName, spec in pairs(apis) do
        if type(spec) == "table" and spec.secureonly and type(fullName) == "string" then
            sim.secureOnlyFunctions[fullName] = true
        end
        if type(spec) == "table" and type(fullName) == "string" then
            local namespace, functionName = fullName:match("^([%w_]+)%.([%w_]+)$")
            local target = G
            if namespace then
                target = rawget(G, namespace)
                if target == nil and isWholeInterface and (secureNamespaces[namespace] or namespace:match("^C_")) then
                    target = {}
                    rawset(G, namespace, target)
                    if secureNamespaces[namespace] then
                        sim.secureOnlyNamespaces = sim.secureOnlyNamespaces or {}
                        sim.secureOnlyNamespaces[namespace] = true
                        summary.secureNamespaces = summary.secureNamespaces + 1
                    end
                end
            else
                functionName = fullName
            end
            if type(target) == "table" and functionName then
                local existing = rawget(target, functionName)
                if existing ~= nil and sim.standIns[existing] then
                    rawset(target, functionName, makeStandIn(fullName, spec))
                    summary.replaced = summary.replaced + 1
                elseif existing == nil and isWholeInterface then
                    rawset(target, functionName, makeStandIn(fullName, spec))
                    summary.added = summary.added + 1
                end
            end
        end
    end
    -- The client's widget methods the simulator lacks
    local uiobjects = readJson(folder .. "/uiobjects.json")
    summary.widgetMethods = uiobjects and addWidgetMethods(uiobjects) or 0
    local source = readJson(folder .. "/source.json")
    summary.commit = source and source.commit
    return summary
end

return wowless
