-- The simulator's shared state: the game's globals for addons, time, errors, chat, events and timers.
local sim = {
    G = {}, -- the addons' global table (the game's _G)
    now = 0, -- game seconds since start (GetTime)
    version = 0, -- bumped on every change that can alter the picture
    errors = {}, -- { message, stack, count, time }
    errorIndex = {},
    chat = {}, -- { text, r, g, b, time }
    stubs = {}, -- ["Type:Method"] = count, for methods and functions the simulator only pretends to have
    nextId = 0,
    timers = {}, -- { at, callback, interval, iterations, cancelled }
    eventFrames = {}, -- [event] = { [frame] = true }
    allEventFrames = {}, -- frames that called RegisterAllEvents
    onUpdateFrames = {}, -- [frame] = true (changed through sim.setOnUpdate)
    onUpdateVersion = 0,
    restrictedEvents = {}, -- [event] = true: the client keeps these from addons (docs.lua fills it)
    knownEvents = {}, -- [event] = true: every event the client has, from its API documentation (docs.lua fills it)
    screenWidth = 1366,
    screenHeight = 768,
}

-- Folders through the system's own shell: cmd.exe on Windows, sh elsewhere
sim.isWindows = package.config:sub(1, 1) == "\\"

local function toSystemPath(path)
    return sim.isWindows and path:gsub("/", "\\") or path
end

-- Listing a folder on Windows through the system itself (FindFirstFileW, LuaJIT's FFI): a shell started for each
-- folder ("dir /b") took a third of the startup, the game's interface having thousands of folders and files
local findFiles
if sim.isWindows then
    local isLoaded, ffi = pcall(require, "ffi")
    if isLoaded and pcall(ffi.cdef, [[
        typedef struct { uint32_t low, high; } AddonSimFileTime;
        typedef struct {
            uint32_t attributes; AddonSimFileTime created, accessed, written; uint32_t sizeHigh, sizeLow, reserved0, reserved1;
            uint16_t name[260]; uint16_t shortName[14];
        } AddonSimFindData;
        void* FindFirstFileW(const uint16_t* pattern, AddonSimFindData* data);
        int FindNextFileW(void* handle, AddonSimFindData* data);
        int FindClose(void* handle);
        int MultiByteToWideChar(unsigned int page, uint32_t flags, const char* text, int length, uint16_t* wide, int wideLength);
        int WideCharToMultiByte(unsigned int page, uint32_t flags, const uint16_t* wide, int wideLength, char* text, int length, const char* fallback, int* isFallbackUsed);
    ]]) then
        local kernel = ffi.C
        local UTF8 = 65001
        local INVALID = ffi.cast("void*", -1)
        local data = ffi.new("AddonSimFindData")
        local nameBuffer = ffi.new("char[1040]")
        findFiles = function(path)
            local pattern = toSystemPath(path):gsub("\\$", "") .. "\\*"
            local wideLength = kernel.MultiByteToWideChar(UTF8, 0, pattern, #pattern + 1, nil, 0)
            local wide = ffi.new("uint16_t[?]", wideLength)
            kernel.MultiByteToWideChar(UTF8, 0, pattern, #pattern + 1, wide, wideLength)
            local handle = kernel.FindFirstFileW(wide, data)
            local names = {}
            if handle == INVALID then return names end
            repeat
                local length = kernel.WideCharToMultiByte(UTF8, 0, data.name, -1, nameBuffer, 1040, nil, nil)
                local name = length > 0 and ffi.string(nameBuffer, length - 1) or nil
                if name and name ~= "." and name ~= ".." then names[#names + 1] = name end
            until kernel.FindNextFileW(handle, data) == 0
            kernel.FindClose(handle)
            table.sort(names, function(a, b) return a:lower() < b:lower() end) -- (as "dir /b" gives them)
            return names
        end
    end
end

-- A folder's names, kept for the process's life: the game's interface and the addons do not change under a running
-- simulator (a changed addon restarts it). sim.forgetDirectories() lets them go (a folder made, files written)
local listings = {}

---@return string[] names The names in a folder (files and folders), none when it is missing
function sim.listDirectory(path)
    local kept = listings[path]
    if kept then return kept end
    local names = findFiles and findFiles(path)
    if not names then
        names = {}
        local command = sim.isWindows and ('dir /b "' .. toSystemPath(path) .. '" 2>nul')
            or ('ls -1 "' .. path:gsub('"', '\\"') .. '" 2>/dev/null')
        local handle = io.popen(command)
        if handle then
            for name in handle:lines() do names[#names + 1] = name end
            handle:close()
        end
    end
    listings[path] = names
    return names
end

---@return table? byLower A folder's names by their lower-case spelling: [lower] = name
function sim.getDirectoryIndex(path)
    local names = sim.listDirectory(path)
    local index = listings[path .. "|index"]
    if not index then
        index = {}
        for _, name in ipairs(names) do index[name:lower()] = name end
        listings[path .. "|index"] = index
    end
    return index
end

function sim.forgetDirectories() listings = {} end

---Makes a folder and the folders above it, when they are missing.
function sim.makeDirectory(path)
    if sim.isWindows then
        os.execute('if not exist "' .. toSystemPath(path) .. '" mkdir "' .. toSystemPath(path) .. '"')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end

---@return string? path The newest file named `fileName` in the folders under `root`, one level down
---(`root/*/sub/fileName`), or nil
function sim.findNewestFile(root, sub, fileName)
    local command
    if sim.isWindows then
        -- Every match below the root, newest first within each folder; one account is the usual case
        command = 'dir /b /s /o-d "' .. toSystemPath(root) .. '\\' .. fileName .. '" 2>nul'
    else
        command = 'ls -t "' .. root .. '/"*/' .. sub .. '/' .. fileName .. ' 2>/dev/null'
    end
    local handle = io.popen(command)
    local path = handle and handle:read("*l")
    if handle then handle:close() end
    return path ~= "" and path or nil
end

function sim.newId()
    sim.nextId = sim.nextId + 1
    return sim.nextId
end

function sim.touch()
    sim.version = sim.version + 1
    sim.layoutVersion = (sim.layoutVersion or 0) + 1
end

-- A change to how something looks that moves nothing (a colour, an alpha, the mouse over a button, shown or hidden):
-- the scene is drawn again, but the rectangles worked out stay (no setter of size, anchor, scale, text or font)
function sim.touchVisual()
    sim.version = sim.version + 1
end

-- Bumped at every change to any rectangle, the whole layout's (sim.touch) or one object's (W.touchLayoutOf): what
-- watches sizes (OnSizeChanged) looks again after either
sim.layoutChanges = 0

function sim.reportError(message, stack)
    message = tostring(message)
    local key = message .. "\n" .. (stack or "")
    local entry = sim.errorIndex[key]
    if entry then
        entry.count = entry.count + 1
        entry.time = sim.now
    else
        entry = { message = message, stack = stack or "", count = 1, time = sim.now, id = #sim.errors + 1 }
        sim.errorIndex[key] = entry
        sim.errors[#sim.errors + 1] = entry
    end
    sim.version = sim.version + 1
    return entry
end

---The whole stack from a level up, as debug.traceback writes it but without its cut in the middle ("..."): a deep
---error in the game's own code (an OnHide set off while a frame is built) is found by what called what.
function sim.fullStack(level)
    local lines = { "stack traceback:" }
    level = (level or 1) + 1
    while #lines <= 80 do
        local info = debug.getinfo(level, "Sln")
        if not info then
            return table.concat(lines, "\n")
        end
        local where = info.what == "C" and "[C]" or (info.short_src .. ":" .. (info.currentline or 0))
        local what = info.name and ("in function '" .. info.name .. "'")
            or (info.what == "main" and "in main chunk")
            or (info.what == "C" and "?")
            or ("in function <" .. info.short_src .. ":" .. (info.linedefined or 0) .. ">")
        lines[#lines + 1] = "\t" .. where .. ": " .. what
        level = level + 1
    end
    lines[#lines + 1] = "\t..."
    return table.concat(lines, "\n")
end

local function traceback(message)
    local stack = sim.fullStack(2)
    -- Only the addons' frames are of interest: drop the simulator's own lines
    local lines = {}
    for line in stack:gmatch("[^\n]+") do
        -- (the simulator's own files by either slash: Windows writes its paths with backslashes)
        if not line:find("^stack traceback") and not line:find("AddonSim[/\\]lua[/\\]") and not line:find("%[C%]: in function 'xpcall'") then
            lines[#lines + 1] = line
        end
    end
    local problem = { message = message, stack = table.concat(lines, "\n") }
    -- An addon's error handler (seterrorhandler) is called where the error happened, as the client does: its
    -- debugstack sees the failing code. The error is reported all the same (finishCall)
    local handler = sim.addonErrorHandler
    if handler then
        sim.erroredStack = problem.stack
        pcall(handler, message)
        sim.erroredStack = nil
    end
    return problem
end

---Calls a function the way the game calls addon code: errors are caught and reported, never fatal.
---Runs a function as the client runs a secure entry point (securecall, a secure frame's attribute handler): issecure()
---looks no further back than this, so the game's code is secure here though an addon set it off.
function sim.runSecurely(fn, ...)
    local results = { sim.call(fn, ...) } -- not a tail call: this function stays on the stack while fn runs
    return unpack(results, 2, table.maxn(results))
end

-- A clock for measuring, in milliseconds: the processor's counter through LuaJIT's FFI where it can be had (os.clock
-- counts whole milliseconds on Windows, too coarse for a handler that takes a tenth of one)
local function makeClock()
    local isLoaded, ffi = pcall(require, "ffi")
    if isLoaded and ffi.os == "Windows" then
        local isDeclared = pcall(ffi.cdef, "int QueryPerformanceCounter(int64_t *count); int QueryPerformanceFrequency(int64_t *frequency);")
        if isDeclared then
            local counter, frequency = ffi.new("int64_t[1]"), ffi.new("int64_t[1]")
            ffi.C.QueryPerformanceFrequency(frequency)
            local perMillisecond = tonumber(frequency[0]) / 1000
            return function()
                ffi.C.QueryPerformanceCounter(counter)
                return tonumber(counter[0]) / perMillisecond
            end
        end
    elseif isLoaded then
        local isDeclared = pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } addonsim_timespec; int clock_gettime(int clock, addonsim_timespec *time);")
        if isDeclared then
            local time = ffi.new("addonsim_timespec")
            return function()
                ffi.C.clock_gettime(1, time) -- monotonic
                return tonumber(time.tv_sec) * 1000 + tonumber(time.tv_nsec) / 1e6
            end
        end
    end
    return function() return os.clock() * 1000 end
end
sim.clock = makeClock()

-- The time each addon's code takes, as the client's AddOn profiler measures it (C_AddOnProfiler): every call the
-- simulator makes into code (a handler, a timer, a hook) counts for the addon whose file defines the function, its
-- own time only (a call it makes into another addon counts for that one); a game tick's sums make the metrics.
sim.profiler = { byAddon = {}, ticks = 0, isOn = true }
local functionAddons = setmetatable({}, { __mode = "k" }) -- [function] = its addon's name, or false
local function getFunctionAddon(fn)
    local known = functionAddons[fn]
    if known ~= nil then return known end
    local info = debug.getinfo(fn, "S")
    local addon = info and info.source and info.source:match("^@Interface/AddOns/([^/]+)/") or false
    functionAddons[fn] = addon
    return addon
end
local runningAddons, chargedFrom = {}, 0
local function chargeRunning(now)
    local addon = runningAddons[#runningAddons]
    if addon then
        local entry = sim.profiler.byAddon[addon]
        if not entry then
            entry = { tick = 0, total = 0, peak = 0, last = 0, recent = {}, recentIndex = 0, over = {} }
            sim.profiler.byAddon[addon] = entry
        end
        entry.tick = entry.tick + (now - chargedFrom)
    end
    chargedFrom = now
end

---A game tick is over: each addon's time in it goes into its metrics (last, peak, the averages, the counts over).
local OVER_LIMITS = { 1, 5, 10, 50, 100, 500, 1000 }
function sim.endProfilerTick()
    local profiler = sim.profiler
    profiler.ticks = profiler.ticks + 1
    for _, entry in pairs(profiler.byAddon) do
        local spent = entry.tick
        entry.tick, entry.last = 0, spent
        entry.total = entry.total + spent
        if spent > entry.peak then entry.peak = spent end
        entry.recentIndex = entry.recentIndex % 60 + 1
        entry.recent[entry.recentIndex] = spent
        for index, limit in ipairs(OVER_LIMITS) do
            if spent > limit then entry.over[index] = (entry.over[index] or 0) + 1 end
        end
    end
end

-- (the results passed straight through: no table or closure made a call, this being every handler, timer and hook)
local function finishCall(addon, isDone, ...)
    if addon then
        chargeRunning(sim.clock())
        runningAddons[#runningAddons] = nil
    end
    if not isDone then
        local problem = ...
        if type(problem) == "table" then
            sim.reportError(problem.message, problem.stack)
        else
            sim.reportError(problem)
        end
        return false
    end
    return isDone, ...
end

---A frame starts (an OnUpdate script set or hooked) or stops updating each tick.
function sim.setOnUpdate(frame, isUpdating)
    isUpdating = isUpdating and true or nil
    if sim.onUpdateFrames[frame] ~= isUpdating then
        sim.onUpdateFrames[frame] = isUpdating
        sim.onUpdateVersion = sim.onUpdateVersion + 1
    end
end
local updating, updatingVersion = {}, -1

function sim.call(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    local addon = sim.profiler.isOn and getFunctionAddon(fn)
    if addon then
        chargeRunning(sim.clock())
        runningAddons[#runningAddons + 1] = addon
    end
    return finishCall(addon, xpcall(fn, traceback, ...)) -- (LuaJIT's xpcall passes the arguments on)
end

function sim.print(text, r, g, b)
    sim.chat[#sim.chat + 1] = { text = tostring(text), r = r or 1, g = g or 1, b = b or 1, time = sim.now }
    if #sim.chat > 400 then
        table.remove(sim.chat, 1)
    end
    sim.version = sim.version + 1
end

-- Values the game hides from addons (secret values): in restricted situations, such as PvP, some unit
-- identities and threat come back as secrets. A secret here is a value of its own that issecretvalue knows and
-- that fails when indexed, joined or compared by size, as the game's fail for addon code.
sim.restrictions = { identity = false, threat = false }
local secretValues = setmetatable({}, { __mode = "k" })
local secretMeta = {
    __index = function() error("attempt to index a secret value", 2) end,
    __newindex = function() error("attempt to index a secret value", 2) end,
    __concat = function() error("attempt to concatenate a secret value", 2) end,
    __lt = function() error("attempt to compare a secret value", 2) end,
    __le = function() error("attempt to compare a secret value", 2) end,
    __len = function() error("attempt to get the length of a secret value", 2) end,
    __call = function() error("attempt to call a secret value", 2) end,
    __tostring = function() return "<secret>" end,
}
---@return any value The value as a secret, when the game would hide it in the current situation
function sim.hide(value, restriction)
    if value == nil or not sim.restrictions[restriction] then return value end
    local secret = setmetatable({}, secretMeta)
    secretValues[secret] = true
    return secret
end
function sim.isSecret(value) return type(value) == "table" and secretValues[value] == true end

sim.stubCallers = {} -- [name] = { [addon] = true }: the addons (not the game's own code) that reached it
-- The functions that only stand in for the client's (made from its documentation or the recorder's list): a better
-- stand-in may take their place (lua/wowless.lua), a real implementation never
sim.standIns = setmetatable({}, { __mode = "k" })
---@return function standIn The function, marked as a stand-in
function sim.markStandIn(standIn)
    sim.standIns[standIn] = true
    return standIn
end

---Notes a stand-in: something the simulator does not do as the game would. Which addons reached it is kept, so
---a report can show what matters to them apart from what only the game's own interface code touched.
---@return string? addon The addon whose code is running (the nearest on the stack), Blizzard's included
-- Each function's addon, worked out once (its source names the addon's folder): the stack is walked by function,
-- which is cheap, rather than by source, which builds strings at every level. The walk stops at a depth no addon's
-- code lies under (the game's XML being built has none on the stack at all, and walked it whole for each region)
local functionAddons = setmetatable({}, { __mode = "k" }) -- [function] = addon folder, or false
local MAX_STACK_WALK = 40
local getinfo = debug.getinfo
local function getFunctionAddon(fn)
    local addon = functionAddons[fn]
    if addon == nil then
        local info = getinfo(fn, "S")
        addon = info and info.source and info.source:match("^@Interface/AddOns/([^/]+)/") or false
        functionAddons[fn] = addon
    end
    return addon
end
sim.getFunctionFolderAddon = getFunctionAddon

-- The simulator's own ways in (an addon's files loaded, an XML file built): no addon's code lies above them, so a
-- walk that reaches one stops (the regions of the game's XML were each walked the whole way up)
sim.stackBoundaries = setmetatable({}, { __mode = "k" })
local boundaries = sim.stackBoundaries

function sim.getCallingAddon()
    for level = 3, MAX_STACK_WALK do
        local info = getinfo(level, "f")
        if not info then return nil end
        local fn = info.func
        if boundaries[fn] then return nil end
        local addon = fn and getFunctionAddon(fn)
        if addon then return addon end
    end
    return nil
end

function sim.noteStub(name)
    sim.stubs[name] = (sim.stubs[name] or 0) + 1
    -- The addon whose own code called it: the nearest addon code on the stack. When that is the game's own (its world
    -- map, opened by an addon's call), the game's code reached it, not the addon
    for level = 2, MAX_STACK_WALK do
        local info = getinfo(level, "f")
        if not info or boundaries[info.func] then break end
        local addon = info.func and getFunctionAddon(info.func)
        if addon then
            if not addon:match("^Blizzard_") then
                sim.stubCallers[name] = sim.stubCallers[name] or {}
                sim.stubCallers[name][addon] = true
            end
            break
        end
    end
end

-- Events
-- The units a frame registered an event for (RegisterUnitEvent): [frame] = { [event] = { [unit token] = true } }
sim.unitEventFilters = setmetatable({}, { __mode = "k" })
function sim.registerEvent(frame, event)
    sim.eventFrames[event] = sim.eventFrames[event] or {}
    sim.eventFrames[event][frame] = true
    local filters = sim.unitEventFilters[frame]
    if filters then filters[event] = nil end
end

function sim.setUnitEventFilter(frame, event, ...)
    local units = {}
    for index = 1, select("#", ...) do
        local unit = select(index, ...)
        if type(unit) == "string" and unit ~= "" then units[unit:lower()] = true end
    end
    if next(units) == nil then return end
    sim.unitEventFilters[frame] = sim.unitEventFilters[frame] or {}
    sim.unitEventFilters[frame][event] = units
end

function sim.unregisterEvent(frame, event)
    if sim.eventFrames[event] then
        sim.eventFrames[event][frame] = nil
    end
    local filters = sim.unitEventFilters[frame]
    if filters then filters[event] = nil end
end

function sim.unregisterAllEvents(frame)
    for _, frames in pairs(sim.eventFrames) do
        frames[frame] = nil
    end
    sim.allEventFrames[frame] = nil
    sim.unitEventFilters[frame] = nil
end

sim.eventHistory = {}

---Fires an event to every frame registered for it, in the order they were created, as the game does.
function sim.fireEvent(event, ...)
    sim.eventHistory[#sim.eventHistory + 1] = { event = event, time = sim.now, args = { ... } }
    if #sim.eventHistory > 200 then
        table.remove(sim.eventHistory, 1)
    end
    local frames = {}
    for frame in pairs(sim.eventFrames[event] or {}) do
        frames[#frames + 1] = frame
    end
    for frame in pairs(sim.allEventFrames) do
        if not (sim.eventFrames[event] or {})[frame] then
            frames[#frames + 1] = frame
        end
    end
    table.sort(frames, function(first, second) return sim.getId(first) < sim.getId(second) end)
    local unit = ...
    local filters = sim.unitEventFilters
    for _, frame in ipairs(frames) do
        -- A frame that registered it for some units (RegisterUnitEvent) hears it only for those
        local filter = filters[frame]
        filter = filter and filter[event]
        if not filter or (type(unit) == "string" and filter[unit:lower()]) then
            -- (from the game, never an addon's code: a handler of the game's runs secure, whoever fired it here, a
            -- scenario's step among them; an addon's handler taints by its own code, as ever)
            sim.runSecurely(sim.runScript, frame, "OnEvent", event, ...)
        end
    end
    if sim.onEventFired then
        sim.onEventFired(event, ...)
    end
end

-- Timers
function sim.addTimer(seconds, callback, iterations)
    local timer = { at = sim.now + math.max(seconds or 0, 0), callback = callback, interval = math.max(seconds or 0, 0), iterations = iterations or 1, cancelled = false }
    sim.timers[#sim.timers + 1] = timer
    return timer
end

---Moves the game's clock on: timers due run, then every visible frame's OnUpdate.
-- A frame of the game's clock. The engine runs it, so what it runs (timers, OnUpdate) starts secure, as in the client,
-- even when a scenario's wait() set it going (issecure() looks no further back than sim.runSecurely)
local tickFrame
function sim.tick(elapsed)
    return sim.runSecurely(tickFrame, elapsed)
end
tickFrame = function(elapsed)
    sim.now = sim.now + elapsed
    sim.lastElapsed = elapsed -- (GetTickTime)
    -- The world moves on first (the character walking), then timers and OnUpdate see where it is
    for _, handler in ipairs(sim.tickHandlers or {}) do sim.call(handler, elapsed) end
    local due = {}
    for index = #sim.timers, 1, -1 do
        local timer = sim.timers[index]
        if timer.cancelled then
            table.remove(sim.timers, index)
        elseif timer.at <= sim.now then
            due[#due + 1] = timer
            if timer.iterations == 1 then
                table.remove(sim.timers, index)
                timer.isDone = true
            else
                timer.iterations = timer.iterations > 1 and timer.iterations - 1 or timer.iterations
                timer.at = sim.now + math.max(timer.interval, 0.01)
            end
        end
    end
    table.sort(due, function(first, second) return first.at < second.at end)
    for _, timer in ipairs(due) do
        if not timer.cancelled then
            sim.call(timer.callback, timer.handle)
        end
    end
    -- In the order they were made, sorted again only when one starts or stops updating
    if updatingVersion ~= sim.onUpdateVersion then
        updatingVersion = sim.onUpdateVersion
        updating = {}
        for frame in pairs(sim.onUpdateFrames) do
            updating[#updating + 1] = frame
        end
        table.sort(updating, function(first, second) return sim.getId(first) < sim.getId(second) end)
    end
    for _, frame in ipairs(updating) do
        if frame:IsVisible() then
            sim.runScript(frame, "OnUpdate", elapsed)
        end
    end
    local W = package.loaded["widgets"]
    if W and W.fireSizeChanges then W.fireSizeChanges() end
    sim.endProfilerTick()
end

---Every event name the game's own interface code uses: the documentation leaves some out (TRIAL_STATUS_UPDATE,
---SHOW_SERVER_ALERT), but what the client's own code registers the client has. Read once from the interface's Lua
---(quoted names in capitals with an underscore) and kept in the cache folder.
function sim.addInterfaceEvents(interfaceRoot, cachePath)
    local names = {}
    local cached = cachePath and io.open(cachePath)
    if cached then
        for name in cached:lines() do names[#names + 1] = name end
        cached:close()
    else
        local seen = {}
        local command = sim.isWindows and ('dir /s /b "' .. interfaceRoot:gsub("/", "\\") .. '\\*.lua" 2>nul') or ('find "' .. interfaceRoot .. '" -name "*.lua"')
        local list = io.popen(command)
        for path in list:lines() do
            local file = io.open(path)
            if file then
                local text = file:read("*a")
                file:close()
                for name in text:gmatch('"([%u][%u%d]*_[%u%d_]+)"') do
                    if not seen[name] then seen[name], names[#names + 1] = true, name end
                end
            end
        end
        list:close()
        local out = cachePath and io.open(cachePath, "w")
        if out then
            for _, name in ipairs(names) do out:write(name, "\n") end
            out:close()
        end
    end
    for _, name in ipairs(names) do sim.knownEvents[name] = true end
    return #names
end

---@return boolean isKnown The client has this event: in its API documentation, or listed in the config's extraEvents
---(real events the documentation leaves out). With no documentation loaded, every name is taken.
function sim.isEventKnown(event)
    if sim.knownEvents[event] then
        return true
    end
    for _, extra in ipairs(sim.config and sim.config.extraEvents or {}) do
        if extra == event then
            return true
        end
    end
    return next(sim.knownEvents) == nil
end

return sim
