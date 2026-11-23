-- The real client's API, as the recorder addon dumped it in the game ("/asrec api": AddonSimRecording.api in its
-- SavedVariables): every global function, each C_ namespace's functions, each widget type's methods. Compared with
-- what the simulator offers, it says what to build next (the client has it, the simulator not) and what the client
-- does not have at all (the simulator offers it, the client not). In strict mode those are taken away, so an addon
-- that calls one gets nil, as in the game: a function renamed or removed in this client fails here first.
local sim = require("sim")

local apisurface = {}
local G = sim.G

---@return table? api The dump, or nil when there is none (no file, or the recorder never ran /asrec api)
local loadedDumps = {} -- by path: the dump is read several times as the simulator starts
function apisurface.load(path)
    if path and loadedDumps[path] ~= nil then return loadedDumps[path] or nil end
    local api = apisurface.read(path)
    if path then loadedDumps[path] = api or false end
    return api
end

function apisurface.read(path)
    local chunk = path and loadfile(path)
    if not chunk then
        return nil
    end
    local saved = {}
    setfenv(chunk, saved)
    if not pcall(chunk) then
        return nil
    end
    return type(saved.AddonSimRecording) == "table" and saved.AddonSimRecording.api or nil
end

---@return string? path The recorder's saved variables beside the game the addons come from (WTF\Account\*\SavedVariables)
function apisurface.findDump(config)
    if config.apiDump then
        return config.apiDump
    end
    if not config.addonsRoot then
        return nil
    end
    local accounts = config.addonsRoot .. "/../../WTF/Account"
    for _, account in ipairs(sim.listDirectory(accounts) or {}) do
        local candidate = accounts .. "/" .. account .. "/SavedVariables/AddonSimRecorder.lua"
        if apisurface.load(candidate) then
            return candidate
        end
    end
    return nil
end

---Stands in for every function the client has and the simulator does not simulate yet: called, it returns nothing and
---is noted (the Errors tab's "Pretended to exist"). For the whole interface, whose code calls many of them as it loads.
---@return number count Stand-ins added
function apisurface.addClientStandIns(api)
    local count = 0
    local function makeStandIn(fullName)
        -- A count or a limit ("GetNumLanguages", "GetMaxBattlefieldID") is a number in the client, never nothing:
        -- none here, so 0 (the game's loops count up to it)
        local functionName = fullName:match("([%w_]+)$") or fullName
        -- A health is a number too (C_PetBattles.GetHealth, formatted with %d by the pet battle frames as they load)
        local isCount = functionName:match("GetNum%u") or functionName:match("^GetMax%u") or functionName:match("^Get%w*Health$")
        return sim.markStandIn(function()
            sim.noteStub(fullName .. " (the client has it; not simulated yet)")
            if isCount then return 0 end
        end)
    end
    for _, name in ipairs(api.globals or {}) do
        if rawget(G, name) == nil then
            rawset(G, name, makeStandIn(name))
            count = count + 1
        end
    end
    -- The client's own numeric constants (the recorder saves them since it records them: /asrec api)
    for name, value in pairs(api.constants or {}) do
        if rawget(G, name) == nil then rawset(G, name, value) end
    end
    for namespace, functions in pairs(api.namespaces or {}) do
        local target = rawget(G, namespace)
        if type(target) ~= "table" then
            target = {}
            rawset(G, namespace, target)
        end
        for _, name in ipairs(functions) do
            if rawget(target, name) == nil then
                rawset(target, name, makeStandIn(namespace .. "." .. name))
                count = count + 1
            end
        end
    end
    return count
end

local function toSet(list)
    local set = {}
    for _, name in ipairs(list or {}) do
        set[name] = true
    end
    return set
end

---@return table<string, boolean> names Every method name the game's own Lua code defines on a mixin ("function X:Name("):
---such a method reaches the game's frames from that code (GameTooltip's SetUnit, from TooltipDataHandler), not from
---the widget itself, so a bare widget made by the recorder does not show it. Read once and kept in the cache folder.
function apisurface.getMixinMethodNames(interfaceRoot, cachePath)
    local names = {}
    local cached = cachePath and io.open(cachePath)
    if cached then
        for name in cached:lines() do names[name] = true end
        cached:close()
        if next(names) then return names end
    end
    local command = sim.isWindows and ('dir /s /b "' .. interfaceRoot:gsub("/", "\\") .. '\\*.lua" 2>nul') or ('find "' .. interfaceRoot .. '" -name "*.lua"')
    local list = io.popen(command)
    for path in list:lines() do
        local file = io.open(path)
        if file then
            for line in file:lines() do
                -- Written out ("function X:Name("), or made from a table of accessors (TooltipDataHandler's
                -- "SetItemByID = "GetItemByID"", each turned into a tooltip method)
                local name = line:match("^%s*function [%w_%.]+:([%w_]+)%(") or line:match('^%s*([%w_]+)%s*=%s*"Get[%w_]+"%s*,')
                if name then names[name] = true end
            end
            file:close()
        end
    end
    list:close()
    local out = cachePath and io.open(cachePath, "w")
    if out then
        for name in pairs(names) do out:write(name, "\n") end
        out:close()
    end
    return names
end
---Compares the simulator's API with the client's.
---@param isStrict boolean Take away what the client does not have
---@return { simOnly: string[], clientOnly: string[], widgetsSimOnly: string[], widgetsClientOnly: string[] } report
---@param mixinMethods table<string, boolean>? Method names the game's Lua mixins add (kept on widgets, see above)
function apisurface.apply(api, isStrict, mixinMethods)
    local report = { simOnly = {}, clientOnly = {}, widgetsSimOnly = {}, widgetsClientOnly = {} }
    local globals = toSet(api.globals)
    -- Global functions
    for name, value in pairs(G) do
        if type(name) == "string" and type(value) == "function" and not globals[name] and not (sim.secureOnlyFunctions and sim.secureOnlyFunctions[name]) then
            report.simOnly[#report.simOnly + 1] = name
            if isStrict then
                rawset(G, name, nil)
            end
        end
    end
    for name in pairs(globals) do
        if rawget(G, name) == nil then
            report.clientOnly[#report.clientOnly + 1] = name
        end
    end
    -- C_ namespaces
    for namespace, value in pairs(G) do
        local isSecureOnly = sim.secureOnlyNamespaces and sim.secureOnlyNamespaces[namespace]
        if type(namespace) == "string" and namespace:match("^C_") and type(value) == "table" and not isSecureOnly then
            local functions = api.namespaces[namespace] and toSet(api.namespaces[namespace])
            for name, member in pairs(value) do
                -- A function only the game's secure code may call (wowless's "secureonly": C_PingSecure.CreateFrame)
                -- is not in an addon's list, yet the game's own code needs it later on
                local isSecureFunction = sim.secureOnlyFunctions and sim.secureOnlyFunctions[namespace .. "." .. tostring(name)]
                if type(name) == "string" and type(member) == "function" and not (functions and functions[name]) and not isSecureFunction then
                    report.simOnly[#report.simOnly + 1] = namespace .. "." .. name
                    if isStrict then
                        rawset(value, name, nil)
                    end
                end
            end
        end
    end
    for namespace, functions in pairs(api.namespaces or {}) do
        local value = rawget(G, namespace)
        for _, name in ipairs(functions) do
            if type(value) ~= "table" or rawget(value, name) == nil then
                report.clientOnly[#report.clientOnly + 1] = namespace .. "." .. name
            end
        end
    end
    -- Widget methods, type by type
    local W = require("widgets")
    for typeName, methods in pairs(api.widgets or {}) do
        local definition = W.types[typeName]
        if definition then
            local clientMethods = toSet(methods)
            for name, method in pairs(definition.methods) do
                if type(method) == "function" and not clientMethods[name] then
                    report.widgetsSimOnly[#report.widgetsSimOnly + 1] = typeName .. ":" .. name
                    if isStrict and not (mixinMethods and mixinMethods[name]) then
                        definition.methods[name] = nil -- each type has its own table: a Frame loses it, a Texture keeps its own
                    end
                end
            end
            for name in pairs(clientMethods) do
                if definition.methods[name] == nil then
                    report.widgetsClientOnly[#report.widgetsClientOnly + 1] = typeName .. ":" .. name
                end
            end
        end
    end
    for _, list in pairs(report) do
        table.sort(list)
    end
    return report
end

---Writes the comparison where a developer can read it: what the client lacks, and what the simulator has yet to do.
function apisurface.writeReport(report, api, path)
    local file = io.open(path, "w")
    if not file then
        return
    end
    file:write(string.format("API of the client %s (build %s), recorded %s\n\n", tostring(api.client), tostring(api.build), tostring(api.recordedAt)))
    local sections = {
        { "In the simulator but NOT in this client (taken away in strict mode)", report.simOnly },
        { "Widget methods in the simulator but NOT in this client (taken away in strict mode)", report.widgetsSimOnly },
        { "In this client but not yet in the simulator (nil there)", report.clientOnly },
        { "Widget methods in this client but not yet in the simulator", report.widgetsClientOnly },
    }
    for _, section in ipairs(sections) do
        file:write(string.format("== %s: %d\n", section[1], #section[2]))
        for _, name in ipairs(section[2]) do
            file:write(name, "\n")
        end
        file:write("\n")
    end
    file:close()
end

return apisurface
