-- The game's general API for addons: Lua as the game offers it, timers, slash commands, bindings, CVars,
-- mixins, LibStub, colours and the many small helpers FrameXML adds. Game state (character, quests, map) is
-- in game.lua; the interface's own frames (UIParent, tooltips, menus) in ui.lua.
local sim = require("sim")
local W = require("widgets")

local api = {}
local G = sim.G

function api.install(config)
    -- Lua, as the game has it
    for _, name in ipairs({
        "assert",
        "error",
        "ipairs",
        "next",
        "pairs",
        "pcall",
        "print",
        "rawequal",
        "rawget",
        "rawset",
        "select",
        "setmetatable",
        "getmetatable",
        "tonumber",
        "tostring",
        "type",
        "unpack",
        "xpcall",
        "collectgarbage",
        "gcinfo",
    }) do
        G[name] = _G[name]
    end
    G._G = G
    G._VERSION = "Lua 5.1"
    G.string, G.table, G.math, G.coroutine = string, table, math, coroutine
    G.bit = bit
    G.os = { time = os.time, date = os.date, clock = os.clock, difftime = os.difftime }
    G.date, G.time, G.difftime = os.date, os.time, os.difftime
    G.getfenv = function(target)
        if target == nil or target == 0 then
            return G
        end
        -- (a level counts from the caller, not from this stand-in; the simulator's own globals are never handed out)
        local env = getfenv(type(target) == "number" and target + 1 or target)
        return env == _G and G or env
    end
    G.setfenv = setfenv
    G.loadstring = function(code, chunkName)
        local chunk, problem = loadstring(code, chunkName)
        if chunk then
            setfenv(chunk, G)
        end
        return chunk, problem
    end
    G.newproxy = newproxy
    G.print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(index, ...)))
        end
        sim.print(table.concat(parts, " "))
    end
    -- String helpers the game puts in the global scope
    for name, fn in pairs({
        strlen = string.len,
        strsub = string.sub,
        strfind = string.find,
        strmatch = string.match,
        strupper = string.upper,
        strlower = string.lower,
        strrep = string.rep,
        strbyte = string.byte,
        strchar = string.char,
        strrev = string.reverse,
        format = string.format,
        gsub = string.gsub,
        gmatch = string.gmatch,
        strgsub = string.gsub,
    }) do
        G[name] = fn
    end
    G.string.split = nil
    G.strtrim = function(text, characters)
        characters = characters and ("[" .. characters:gsub("[%]%-%^]", "%%%0") .. "]") or "%s"
        return (text:gsub("^" .. characters .. "+", ""):gsub(characters .. "+$", ""))
    end
    -- Characters, not bytes: every byte that does not continue a UTF-8 character (the guild finder's search box)
    G.strlenutf8 = function(text)
        text = tostring(text or "")
        local count = 0
        for index = 1, #text do
            local byte = text:byte(index)
            if byte < 0x80 or byte >= 0xC0 then
                count = count + 1
            end
        end
        return count
    end
    -- Large numbers shortened, as the game's own Lua long did it: 1234567 -> "1234K", 123456789 -> "123M"
    G.AbbreviateLargeNumbers = function(value)
        local text = tostring(math.floor(tonumber(value) or 0))
        if #text > 8 then
            return text:sub(1, -7) .. (rawget(G, "SECOND_NUMBER_CAP") or "M")
        end
        if #text > 5 then
            return text:sub(1, -4) .. (rawget(G, "FIRST_NUMBER_CAP") or "K")
        end
        return text
    end
    -- 1500 -> "1.5K", 25000 -> "25K", 2400000 -> "2.4M" (the game's breakpoints)
    G.AbbreviateNumbers = function(value)
        value = tonumber(value) or 0
        local thousand, million, billion =
            rawget(G, "FIRST_NUMBER_CAP_NO_SPACE") or "K",
            rawget(G, "SECOND_NUMBER_CAP_NO_SPACE") or "M",
            rawget(G, "THIRD_NUMBER_CAP_NO_SPACE") or "B"
        local steps = {
            { 1e10, billion, 1e9, 1 },
            { 1e9, billion, 1e8, 10 },
            { 1e7, million, 1e6, 1 },
            { 1e6, million, 1e5, 10 },
            { 1e4, thousand, 1e3, 1 },
            { 1e3, thousand, 1e2, 10 },
        }
        for _, step in ipairs(steps) do
            if value >= step[1] then
                local shown = math.floor(value / step[3]) / step[4]
                return (shown == math.floor(shown) and string.format("%d", shown) or tostring(shown)) .. step[2]
            end
        end
        return tostring(value)
    end
    G.strsplit = function(delimiter, text, limit)
        local results, start = {}, 1
        while true do
            if limit and #results == limit - 1 then
                results[#results + 1] = text:sub(start)
                break
            end
            local from, to = text:find("[" .. delimiter:gsub("[%]%-%^%%]", "%%%0") .. "]", start)
            if not from then
                results[#results + 1] = text:sub(start)
                break
            end
            results[#results + 1] = text:sub(start, from - 1)
            start = to + 1
        end
        return unpack(results)
    end
    G.strsplittable = function(delimiter, text, limit)
        return { G.strsplit(delimiter, text, limit) }
    end
    G.strjoin = function(delimiter, ...)
        return table.concat({ ... }, delimiter)
    end
    G.strconcat = function(...)
        return table.concat({ ... })
    end
    G.strcmputf8i = function(first, second)
        return first:lower() < second:lower() and -1 or (first:lower() == second:lower() and 0 or 1)
    end
    G.string.trim = G.strtrim
    -- The client puts these on the string library too ("|":join(...), string.split)
    G.string.join, G.string.split, G.string.concat = G.strjoin, G.strsplit, G.strconcat
    G.tostringall = function(...)
        local values = { ... }
        for index = 1, select("#", ...) do
            values[index] = tostring(values[index])
        end
        return unpack(values, 1, select("#", ...))
    end
    -- Table helpers
    G.tinsert, G.tremove, G.sort, G.getn =
        table.insert, table.remove, table.sort, function(list)
            return #list
        end
    G.table.wipe = function(target)
        for key in pairs(target) do
            target[key] = nil
        end
        return target
    end
    G.wipe = G.table.wipe
    G.tContains = function(list, value)
        for _, item in ipairs(list) do
            if item == value then
                return true
            end
        end
        return false
    end
    G.tInvert = function(list)
        local result = {}
        for key, value in pairs(list) do
            result[value] = key
        end
        return result
    end
    G.tIndexOf = function(list, value)
        for index, item in ipairs(list) do
            if item == value then
                return index
            end
        end
    end
    G.tDeleteItem = function(list, value)
        for index = #list, 1, -1 do
            if list[index] == value then
                table.remove(list, index)
            end
        end
    end
    G.tAppendAll = function(target, source)
        for _, value in ipairs(source) do
            target[#target + 1] = value
        end
    end
    G.tFilter = function(list, predicate)
        local result = {}
        for _, value in ipairs(list) do
            if predicate(value) then
                result[#result + 1] = value
            end
        end
        return result
    end
    G.CopyTable = function(source, isShallow)
        local copy = {}
        for key, value in pairs(source) do
            copy[key] = (type(value) == "table" and not isShallow) and G.CopyTable(value) or value
        end
        return copy
    end
    G.table.count = function(target)
        local count = 0
        for _ in pairs(target) do
            count = count + 1
        end
        return count
    end
    G.Clamp = function(value, minimum, maximum)
        return math.max(minimum, math.min(maximum, value))
    end
    G.Lerp = function(from, to, amount)
        return from + (to - from) * amount
    end
    G.Round = function(value)
        return math.floor(value + 0.5)
    end
    G.Saturate = function(value)
        return math.max(0, math.min(1, value))
    end
    G.PercentageBetween = function(value, low, high)
        return (value - low) / (high - low)
    end
    G.ClampedPercentageBetween = function(value, low, high)
        return math.max(0, math.min(1, (value - low) / (high - low)))
    end
    G.FormatPercentage = function(value)
        return string.format("%d%%", math.floor(value * 100 + 0.5))
    end
    G.BreakUpLargeNumbers = function(value)
        local text = tostring(math.floor(value or 0))
        local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (formatted:gsub("^,", ""):gsub("^%-,", "-"))
    end
    G.GetMoneyString = function(copper)
        copper = math.floor(copper or 0)
        local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
        local parts = {}
        if gold > 0 then
            parts[#parts + 1] = G.BreakUpLargeNumbers(gold) .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
        end
        if silver > 0 then
            parts[#parts + 1] = silver .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
        end
        if rest > 0 or #parts == 0 then
            parts[#parts + 1] = rest .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
        end
        return table.concat(parts, " ")
    end
    G.GetCoinTextureString = G.GetMoneyString
    G.SecondsToTime = function(seconds)
        seconds = math.floor(seconds or 0)
        if seconds >= 3600 then
            return string.format("%d Hr %d Min", seconds / 3600, (seconds % 3600) / 60)
        end
        if seconds >= 60 then
            return string.format("%d Min %d Sec", seconds / 60, seconds % 60)
        end
        return seconds .. " Sec"
    end

    -- Frames and fonts
    G.CreateFrame = function(frameType, name, parent, template, id)
        return W.createFrame(frameType, name, parent, template, id)
    end
    -- A forbidden frame (the secure UI's: the store, its card pools): made as any frame, and says it is forbidden
    G.CreateForbiddenFrame = function(frameType, name, parent, template, id)
        local frame = W.createFrame(frameType, name, parent, template, id)
        frame:SetForbidden()
        return frame
    end
    -- A font object made by code starts left-justified: the client's message frames make theirs so (CreateFont, then
    -- CopyFontObject) and draw their lines with it, left-aligned with no SetJustifyH (the developer console's; an
    -- addon's chat window given a font family: EllesmereUI's, centred here before). The game's XML fonts set none.
    G.CreateFont = function(name)
        local fonts = require("fonts")
        return fonts.createFont(name, "Fonts\\FRIZQT__.TTF", 12, "", { 1, 1, 1, 1 }, "LEFT")
    end
    -- A font family (CreateFontFamilyMemberInfo members: alphabet, file, height, flags): it draws with the member for
    -- the client's alphabet (roman here); the others are kept as members of their own (GetFontObjectForAlphabet)
    G.CreateFontFamily = function(name, members)
        local fonts = require("fonts")
        local family = G.CreateFont(name)
        local active = fonts.clientAlphabet()
        family.activeAlphabet = active
        members = type(members) == "table" and members or {}
        local own = members[1]
        for _, member in ipairs(members) do
            if member.alphabet == active then
                own = member
            end
        end
        if own and own.file then
            family:SetFont(own.file, own.height or 12, own.flags or "")
        end
        for _, member in ipairs(members) do
            if member ~= own and member.alphabet and member.file then
                family
                    :GetFontObjectForAlphabet(member.alphabet)
                    :SetFont(member.file, member.height or 12, member.flags or "")
            end
        end
        return family
    end
    G.GetFonts = function()
        local list = {}
        for name in pairs(require("fonts").objects) do
            list[#list + 1] = name
        end
        return list
    end
    -- A font object's look (FontScriptInfo): its height, outline, colour and shadow, as the friends list and the
    -- text size setting read them. None here is scaled by that setting (canBeUserScaled false)
    G.GetFontInfo = function(fontObject)
        if type(fontObject) == "string" then
            fontObject = require("fonts").objects[fontObject] or rawget(G, fontObject)
        end
        if type(fontObject) ~= "table" or not fontObject.GetFont then
            return nil
        end
        local _, height, outline = fontObject:GetFont()
        local r, g, b, a = 1, 1, 1, 1
        if fontObject.GetTextColor then
            r, g, b, a = fontObject:GetTextColor()
        end
        local info = {
            height = height or 12,
            outline = outline or "",
            fontObject = fontObject,
            canBeUserScaled = false,
            color = G.CreateColor(r or 1, g or 1, b or 1, a or 1),
        }
        if fontObject.GetShadowOffset then
            local x, y = fontObject:GetShadowOffset()
            if (x and x ~= 0) or (y and y ~= 0) then
                local sr, sg, sb, sa = 0, 0, 0, 1
                if fontObject.GetShadowColor then
                    sr, sg, sb, sa = fontObject:GetShadowColor()
                end
                info.shadow = { x = x or 0, y = y or 0, color = G.CreateColor(sr or 0, sg or 0, sb or 0, sa or 1) }
            end
        end
        return info
    end
    -- The mouse cursor is on screen (the page's own); the gamepad's reticle hides itself while it is
    G.IsCursorVisible = function()
        return true
    end
    G.EnumerateFrames = function(previous)
        local frames = W.frames
        if not previous then
            return frames[1]
        end
        for index, frame in ipairs(frames) do
            if frame == previous then
                return frames[index + 1]
            end
        end
    end

    -- Encoding, as C_EncodingUtil does it (lua/encoding.lua): base64, hex, CBOR, deflate, zlib and gzip (an addon may
    -- read a database baked into its files so, QuestieDB among them)
    local encoding = require("encoding")
    G.C_ColorUtil = require("colorutil").namespace() -- (the text colour codes: GenerateHexColor, the class colours' colorStr)
    G.C_StringUtil = require("stringutil").install(G.C_StringUtil or {}) -- (escaping, links stripped to their text)
    G.C_EncodingUtil = {
        EncodeBase64 = encoding.encodeBase64,
        DecodeBase64 = encoding.decodeBase64,
        EncodeHex = encoding.encodeHex,
        DecodeHex = encoding.decodeHex,
        SerializeCBOR = encoding.serializeCBOR,
        DeserializeCBOR = encoding.deserializeCBOR,
        CompressString = encoding.compressString,
        DecompressString = encoding.decompressString,
        SerializeJSON = function(value)
            return require("json").encode(value)
        end,
        DeserializeJSON = function(text)
            return require("json").decode(text)
        end,
    }

    -- Time
    G.GetTime = function()
        return sim.now
    end
    G.GetTimePreciseSec = G.GetTime
    -- The game's clock, in milliseconds: not real time, though the client's is. Addons spend time budgets by it (a
    -- little work each frame); measured in real time, how much gets done a frame would hang on the machine's speed
    -- and load, and the scenarios would not play the same twice. Here a budget is never spent within a frame.
    G.debugprofilestop = function()
        return sim.now * 1000
    end
    -- The client's AddOn profiler, from what the simulator measured (sim.profiler): an addon's time a tick, in
    -- milliseconds, as each metric reads it (Enum.AddOnProfilerMetric: 0 session average, 1 the last 60 ticks'
    -- average, 2 an encounter's (none here: the session's), 3 the last tick, 4 the peak, 5-11 ticks over 1 to 1000 ms)
    local function metricOf(entry, metric)
        if not entry then
            return 0
        end
        metric = tonumber(metric) or 0
        local ticks = math.max(sim.profiler.ticks, 1)
        if metric == 0 or metric == 2 then
            return entry.total / ticks
        end
        if metric == 1 then
            local sum, count = 0, 0
            for _, spent in ipairs(entry.recent) do
                sum, count = sum + spent, count + 1
            end
            return count > 0 and sum / count or 0
        end
        if metric == 3 then
            return entry.last
        end
        if metric == 4 then
            return entry.peak
        end
        if metric >= 5 and metric <= 11 then
            return entry.over[metric - 4] or 0
        end
        return 0
    end
    local function findEntry(name)
        if type(name) ~= "string" then
            return nil
        end
        local entry = sim.profiler.byAddon[name]
        if entry then
            return entry
        end
        for addon, candidate in pairs(sim.profiler.byAddon) do
            if addon:lower() == name:lower() then
                return candidate
            end
        end
    end
    local function sumOf(metric, isGameIncluded)
        local sum = 0
        for addon, entry in pairs(sim.profiler.byAddon) do
            if isGameIncluded or not addon:match("^Blizzard_") then
                sum = sum + metricOf(entry, metric)
            end
        end
        return sum
    end
    G.C_AddOnProfiler = {
        IsEnabled = function()
            return sim.profiler.isOn == true
        end,
        GetAddOnMetric = function(name, metric)
            return metricOf(findEntry(name), metric)
        end,
        -- Every addon together (not the game's own); the application: everything measured
        GetOverallMetric = function(metric)
            return sumOf(metric, false)
        end,
        GetApplicationMetric = function(metric)
            return sumOf(metric, true)
        end,
        GetTopKAddOnsForMetric = function(metric, count)
            local results = {}
            for addon, entry in pairs(sim.profiler.byAddon) do
                if not addon:match("^Blizzard_") then
                    results[#results + 1] = { addOnName = addon, metricValue = metricOf(entry, metric) }
                end
            end
            table.sort(results, function(first, second)
                return first.metricValue > second.metricValue
            end)
            for index = #results, (tonumber(count) or #results) + 1, -1 do
                results[index] = nil
            end
            return results
        end,
        GetTicksPerSecond = function()
            return 1000
        end,
        CheckForPerformanceMessage = function()
            return nil
        end,
    }
    G.debugprofilestart = function() end
    G.GetServerTime = function()
        return os.time()
    end
    -- The frame just played, as the client measures it: its length (GetTickTime, which the game's FrameDeltaLerp eases
    -- by: the map's glide, scroll boxes' interpolation stood still while it answered 0) and the rate it makes
    G.GetTickTime = function()
        return sim.lastElapsed or 0
    end
    -- The encounter journal has no data in this client (measured, /asrec probe: no tiers, the first dungeon of the
    -- first tier nothing at all): its own answers, not stand-ins
    G.EJ_GetNumTiers = function()
        return 0
    end
    G.EJ_GetInstanceByIndex = function() end
    G.GetFramerate = function()
        return (sim.lastElapsed or 0) > 0 and 1 / sim.lastElapsed or 60
    end
    -- Bandwidth in and out (KB/s), then the home and world latencies (ms): the documentation gives the latencies as
    -- a list, the client always returns the two
    G.GetNetStats = function()
        return 0, 0, 40, 40
    end
    G.C_DateAndTime = {
        GetCurrentCalendarTime = function()
            local now = os.date("*t")
            return {
                year = now.year,
                month = now.month,
                monthDay = now.day,
                weekday = now.wday,
                hour = now.hour,
                minute = now.min,
            }
        end,
        GetServerTimeLocal = function()
            return os.time()
        end,
    }

    -- Errors and security
    -- The simulator reports every error caught in addon code itself (sim.call). An addon's own handler, set in front
    -- of the game's, is called too, where the error happened, as in the client (sim.addonErrorHandler: sim.call's
    -- traceback); the game's handlers (Blizzard_ScriptErrors sets one at load) are not: they would only show the
    -- error frame. A handler reached down the chain while sim.call reports (sim.erroredStack) adds nothing.
    local defaultHandler = function(message)
        if not sim.erroredStack then
            sim.reportError(message, debug.traceback("", 2))
        end
    end
    local errorHandler = defaultHandler
    -- Code that catches its own errors and hands them on (xpcall(fn, geterrorhandler()), CallErrorHandler: Syndicator)
    -- reaches the handler without sim.call: what it is handed reports the error too, then calls the handler set (the
    -- game's error frame shows it, as in the client)
    local reporting = setmetatable({}, { __mode = "k" })
    G.geterrorhandler = function()
        if errorHandler == defaultHandler or type(errorHandler) ~= "function" then
            return errorHandler
        end
        local wrapper = reporting[errorHandler]
        if not wrapper then
            local handler = errorHandler
            wrapper = function(message, ...)
                if not sim.erroredStack then
                    sim.reportError(message, debug.traceback("", 2))
                end
                return handler(message, ...)
            end
            reporting[handler] = wrapper
        end
        return wrapper
    end
    G.seterrorhandler = function(handler)
        errorHandler = handler
        local source = type(handler) == "function" and debug.getinfo(handler, "S").source or ""
        local isGame = handler == defaultHandler or source:find("Blizzard_") or source:find("FrameXML")
        sim.addonErrorHandler = not isGame and type(handler) == "function" and handler or nil
    end
    -- debugstack([thread,] [start [, count1 [, count2]]]): a coroutine's stack too, as the client's (an addon's error
    -- handler passes the one that failed)
    -- The stack as the client gives it: from start (1, the function calling debugstack; 2, its caller...), count1
    -- lines from the top and count2 from the bottom (12 and 10), one "file:line: in ..." a line, no header. Levels
    -- are counted from debugstack's own place on the stack, wrappers round it or not: EllesmereUI finds the addon
    -- calling its RegisterModule from debugstack(2, 1, 0), and with a level off and the whole stack it refused
    -- every options page (an empty settings panel)
    -- One line of the stack, as debug.traceback writes it but with the file's whole path: LuaJIT cuts a name past
    -- 60 characters to "...ddOns/EllesmereUIOptions/...", and the client does not (EllesmereUI then found no
    -- folder for its Cooldown Manager page and dropped it: a sidebar entry that did nothing)
    local function fullSource(info)
        if type(info.source) == "string" and info.source:sub(1, 1) == "@" then
            return info.source:sub(2)
        end
        return info.short_src or "?"
    end
    local function stackLine(info)
        local where = info.what == "C" and "[C]" or fullSource(info)
        if (info.currentline or -1) > 0 then
            where = where .. ":" .. info.currentline
        end
        local what
        if info.what == "main" then
            what = "in main chunk"
        elseif info.name then
            what = "in function '" .. info.name .. "'"
        elseif info.what == "C" then
            what = "?"
        else
            what = "in function <" .. fullSource(info) .. ":" .. tostring(info.linedefined) .. ">"
        end
        return where .. ": " .. what
    end
    local function stackLines(thread, from)
        local lines = {}
        for level = from, from + 200 do
            local info
            if thread then
                info = debug.getinfo(thread, level, "Sln")
            else
                info = debug.getinfo(level, "Sln")
            end
            if not info then
                break
            end
            lines[#lines + 1] = stackLine(info)
        end
        return lines
    end
    local debugstack
    debugstack = function(first, ...)
        local thread, start, count1, count2
        if type(first) == "thread" then
            thread = first
            start, count1, count2 = ...
        else
            start, count1, count2 = first, ...
        end
        start, count1, count2 = tonumber(start) or 1, tonumber(count1) or 12, tonumber(count2) or 10
        local lines
        if thread then
            lines = stackLines(thread, start)
        else
            local base = 1
            for level = 1, 64 do
                local info = debug.getinfo(level, "f")
                if not info then
                    break
                end
                if info.func == debugstack then
                    base = level
                    break
                end
            end
            -- (base is debugstack's level counted from here; stackLines adds a level of its own)
            lines = stackLines(nil, base + start + 1)
        end
        local kept = {}
        if #lines <= count1 + count2 then
            kept = lines
        else
            for index = 1, count1 do
                kept[#kept + 1] = lines[index]
            end
            if count2 > 0 then
                kept[#kept + 1] = "..."
                for index = #lines - count2 + 1, #lines do
                    kept[#kept + 1] = lines[index]
                end
            end
        end
        return #kept > 0 and (table.concat(kept, "\n") .. "\n") or ""
    end
    G.debugstack = debugstack
    G.debuglocals = function()
        return ""
    end
    G.securecall = function(fn, ...)
        if type(fn) == "string" then
            fn = G[fn]
        end
        return sim.runSecurely(fn, ...)
    end
    G.securecallfunction = G.securecall
    G.securecallmethod = function(object, methodName, ...)
        return G.securecall(object[methodName], object, ...)
    end
    G.secureexecuterange = function(list, fn, ...)
        for key, value in pairs(list) do
            sim.call(fn, key, value, ...)
        end
    end
    -- Private auras (the secure environment's own namespace, which addons never see): there are none here
    G.C_UnitAurasPrivate = {
        GetAllPrivateAuras = function()
            return {}
        end,
        GetAllPrivateAuraInstanceIDs = function()
            return {}
        end,
        GetAuraDataByAuraInstanceIDPrivate = function()
            return nil
        end,
        GetPrivateAuraCasterGUID = function()
            return nil
        end,
        GetPrivateAuraAnchors = function()
            return {}
        end,
        IsPrivateAuraFilteredOutByInstanceID = function()
            return true
        end,
        AddPrivateAuraUpdateCallback = function() end,
        RemovePrivateAuraUpdateCallback = function() end,
        SetPrivateWarningTextFrame = function() end,
        SetPrivateRaidBossMessageCallback = function() end,
        SetPrivateAuraAnchorAddedCallback = function() end,
        SetPrivateAuraAnchorRemovedCallback = function() end,
    }
    -- Kept in strict mode: the game's own code goes on using them after load, though addons cannot
    sim.secureOnlyNamespaces = { C_UnitAurasPrivate = true }

    -- The game's secure environment (UseSecureEnvironment addons) shares with the global one through these. The
    -- simulator runs everything in the global environment, so both are that, and a copy is a deep copy
    G.GetGlobalEnvironment = function()
        return G
    end
    G.GetCurrentEnvironment = G.GetCurrentEnvironment or function()
        return G
    end
    local function copyDeep(value, seen)
        if type(value) ~= "table" then
            return value
        end
        seen = seen or {}
        if seen[value] then
            return seen[value]
        end
        local copy = {}
        seen[value] = copy
        for key, item in pairs(value) do
            copy[copyDeep(key, seen)] = copyDeep(item, seen)
        end
        return setmetatable(copy, getmetatable(value))
    end
    G.securecopy = function(value)
        return copyDeep(value)
    end

    -- The game's own code wraps functions it hands to addons (UnitFrameUtil's PvP indicator): a function calling the
    -- original. Only the game's code has it: strict mode takes it away once that code has loaded (boot)
    G.CreateSecureDelegate = function(fn)
        if type(fn) ~= "function" then
            return nil
        end
        return function(...)
            return fn(...)
        end
    end
    -- Whether a variable is untainted: the simulator keeps no taint on values, so every one is. The client asks a
    -- name (or an index) only: a table or a frame as the key is its usage error, as here (an addon walking a table's
    -- keys into it crashed in the client)
    G.issecurevariable = function(container, key)
        if key == nil then
            key = container
        end
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            error('Usage: issecurevariable([table,] "variable")', 2)
        end
        return true, nil
    end
    -- Secure as long as only the game's own code is running: any addon's code (or a scenario's) on the way here
    -- taints it, as in the client. Blizzard's secure helper refuses work otherwise ("Interface action failed")
    -- Each function on the stack is judged once by where it was written (kept, weakly): an addon's or a scenario's
    -- taints, the game's and the simulator's do not. The stack is walked by function only (its source text is not
    -- fetched again), the game's secure helpers asking this many times a frame.
    local getinfo = debug.getinfo
    local isTainting = setmetatable({}, { __mode = "k" })
    local function judge(fn)
        local info = getinfo(fn, "S")
        local source = info and info.source or ""
        local verdict = (
            source:find("Interface/AddOns/", 1, true) and not source:find("Interface/AddOns/Blizzard_", 1, true)
        )
            or source:find("scenarios[/\\]")
            or source == "=console"
            or source == "console"
            or source:find("^=%[string")
        verdict = verdict and true or false
        isTainting[fn] = verdict
        return verdict
    end
    G.issecure = function()
        local level = 2
        local runSecurely = sim.runSecurely
        while true do
            local info = getinfo(level, "f")
            if not info then
                return true
            end
            local fn = info.func
            if fn == runSecurely then
                return true
            end
            local verdict = isTainting[fn]
            if verdict == nil then
                verdict = judge(fn)
            end
            if verdict then
                return false
            end
            level = level + 1
        end
    end
    G.forceinsecure = function() end
    -- The restricted environment compiles its snippets with it (secure handlers' "self:SetAttribute(...)" bodies:
    -- action bars, state drivers); loadstring without taint, the chunk's environment set by the caller
    G.loadstring_untainted = function(code, chunkName)
        local chunk, problem = loadstring(code, chunkName)
        if chunk then
            setfenv(chunk, G)
        end
        return chunk, problem
    end
    -- Its values as they are when plain (a string, number, boolean or nil), else nil: the restricted environment reads
    -- every attribute through it (a stand-in giving nothing made each read nil: EllesmereUI's bars set theirs forever)
    G.scrub = function(...)
        local count = select("#", ...)
        local values = { ... }
        for index = 1, count do
            local kind = type(values[index])
            if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
                values[index] = nil
            end
        end
        return unpack(values, 1, count)
    end
    -- (secure code's only: the client's API list, read by addon code, does not show it; kept when the strict API
    -- takes away what the list lacks)
    sim.secureOnlyFunctions = sim.secureOnlyFunctions or {}
    sim.secureOnlyFunctions.loadstring_untainted = true
    -- An object's table on the secure side: the client keeps a public and a forbidden one per object; the simulator
    -- one, the object itself (the game's aura containers check that what an addon hands back is it)
    G.GetForbiddenObjectTable = function(object)
        return object
    end
    sim.secureOnlyFunctions.GetForbiddenObjectTable = true
    -- Spectating: the game's Escape handler asks (Blizzard_Game/Mainline/Game.lua) though neither the client's
    -- documentation nor wowless lists it yet: a player never spectates here
    G.C_SpectatingUI = G.C_SpectatingUI or {}
    G.C_SpectatingUI.IsSpectating = G.C_SpectatingUI.IsSpectating
        or sim.markStandIn(function()
            return false
        end)
    -- A game rule as a frame strata: the world map's is HIGH, so it opens over unit frames and bars (it asks as it
    -- shows; with "UNKNOWN" it kept MEDIUM, under EllesmereUI's player frame); the rest are not set
    G.C_GameRules = G.C_GameRules or {}
    G.C_GameRules.GetGameRuleAsFrameStrata = function(rule)
        local rules = G.Enum and G.Enum.GameRule
        if rules and rule ~= nil and rule == rules.WorldMapFrameStrata then
            return "HIGH"
        end
        return "UNKNOWN"
    end
    G.InCombatLockdown = function()
        return sim.inCombat == true
    end
    G.hooksecurefunc = function(target, name, hook)
        if type(target) == "string" then
            target, name, hook = G, target, name
        end
        local original = target[name]
        if original == nil and target == G then
            -- A function of the game's own windows the simulator does not load (the mailbox, the profession
            -- tracker): the hook is kept on a stand-in, and noted
            sim.noteStub("game function " .. tostring(name) .. " (hooked)")
            original = function() end
        end
        if type(original) ~= "function" then
            error("hooksecurefunc(): " .. tostring(name) .. " is not a function", 2)
        end
        -- (every answer of the original's kept, a nil among them too)
        local function pack(...)
            return { n = select("#", ...), ... }
        end
        target[name] = function(...)
            local results = pack(original(...))
            sim.call(hook, ...)
            return unpack(results, 1, results.n)
        end
    end

    -- Timers
    local function makeHandle(timer)
        local handle = { timer = timer }
        function handle:Cancel()
            self.timer.cancelled = true
        end
        function handle:IsCancelled()
            return self.timer.cancelled
        end
        timer.handle = handle
        return handle
    end
    G.C_Timer = {
        After = function(seconds, callback)
            sim.addTimer(seconds, callback, 1)
        end,
        NewTimer = function(seconds, callback)
            return makeHandle(sim.addTimer(seconds, callback, 1))
        end,
        NewTicker = function(seconds, callback, iterations)
            return makeHandle(sim.addTimer(seconds, callback, iterations or -1))
        end,
    }

    -- Mixins and colours
    G.Mixin = function(object, ...)
        for index = 1, select("#", ...) do
            for key, value in pairs((select(index, ...)) or {}) do
                object[key] = value
            end
        end
        return object
    end
    G.CreateFromMixins = function(...)
        return G.Mixin({}, ...)
    end
    G.CreateAndInitFromMixin = function(mixin, ...)
        local object = G.CreateFromMixins(mixin)
        if object.Init then
            object:Init(...)
        end
        return object
    end
    local colorMixin = {}
    function colorMixin:GetRGB()
        return self.r, self.g, self.b
    end
    function colorMixin:GetRGBA()
        return self.r, self.g, self.b, self.a
    end
    function colorMixin:SetRGB(r, g, b)
        self.r, self.g, self.b = r, g, b
    end
    function colorMixin:SetRGBA(r, g, b, a)
        self.r, self.g, self.b, self.a = r, g, b, a
    end
    function colorMixin:GenerateHexColor()
        return string.format("ff%02x%02x%02x", self.r * 255, self.g * 255, self.b * 255)
    end
    function colorMixin:GenerateHexColorMarkup()
        return "|c" .. self:GenerateHexColor()
    end
    function colorMixin:WrapTextInColorCode(text)
        return "|c" .. self:GenerateHexColor() .. tostring(text) .. "|r"
    end
    function colorMixin:IsEqualTo(other)
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a
    end
    G.ColorMixin = colorMixin
    G.CreateColor = function(r, g, b, a)
        return G.Mixin({ r = r, g = g, b = b, a = a or 1 }, colorMixin)
    end
    G.WrapTextInColorCode = function(text, hex)
        return "|c" .. hex .. tostring(text) .. "|r"
    end
    G.WrapTextInColor = function(text, color)
        return color:WrapTextInColorCode(text)
    end
    G.NORMAL_FONT_COLOR = G.CreateColor(1, 0.82, 0)
    G.HIGHLIGHT_FONT_COLOR = G.CreateColor(1, 1, 1)
    G.RED_FONT_COLOR = G.CreateColor(1, 0.1, 0.1)
    G.GREEN_FONT_COLOR = G.CreateColor(0.1, 1, 0.1)
    G.GRAY_FONT_COLOR = G.CreateColor(0.5, 0.5, 0.5)
    G.DISABLED_FONT_COLOR = G.GRAY_FONT_COLOR
    G.YELLOW_FONT_COLOR = G.CreateColor(1, 1, 0)
    G.ORANGE_FONT_COLOR = G.CreateColor(1, 0.5, 0.25)
    G.WHITE_FONT_COLOR = G.HIGHLIGHT_FONT_COLOR
    G.NORMAL_FONT_COLOR_CODE, G.HIGHLIGHT_FONT_COLOR_CODE, G.RED_FONT_COLOR_CODE =
        "|cffffd100", "|cffffffff", "|cffff2020"
    G.GREEN_FONT_COLOR_CODE, G.GRAY_FONT_COLOR_CODE, G.FONT_COLOR_CODE_CLOSE = "|cff20ff20", "|cff808080", "|r"
    G.RAID_CLASS_COLORS = {}
    for class, color in pairs({
        WARRIOR = { 0.78, 0.61, 0.43 },
        PALADIN = { 0.96, 0.55, 0.73 },
        HUNTER = { 0.67, 0.83, 0.45 },
        ROGUE = { 1, 0.96, 0.41 },
        PRIEST = { 1, 1, 1 },
        SHAMAN = { 0, 0.44, 0.87 },
        MAGE = { 0.25, 0.78, 0.92 },
        WARLOCK = { 0.53, 0.53, 0.93 },
        DRUID = { 1, 0.49, 0.04 },
    }) do
        local classColor = G.CreateColor(color[1], color[2], color[3])
        classColor.colorStr = classColor:GenerateHexColor()
        G.RAID_CLASS_COLORS[class] = classColor
    end
    G.CLASS_ICON_TCOORDS = {
        WARRIOR = { 0, 0.25, 0, 0.25 },
        MAGE = { 0.25, 0.49609375, 0, 0.25 },
        ROGUE = { 0.49609375, 0.7421875, 0, 0.25 },
        DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
        HUNTER = { 0, 0.25, 0.25, 0.5 },
        SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
        PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 },
        WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
        PALADIN = { 0, 0.25, 0.5, 0.75 },
    }
    G.CreateVector2D = function(x, y)
        local vector = { x = x, y = y }
        function vector:GetXY()
            return self.x, self.y
        end
        function vector:SetXY(newX, newY)
            self.x, self.y = newX, newY
        end
        function vector:Clone()
            return G.CreateVector2D(self.x, self.y)
        end
        return vector
    end
    G.CreateVector3D = function(x, y, z)
        return {
            x = x,
            y = y,
            z = z,
            GetXYZ = function(self)
                return self.x, self.y, self.z
            end,
        }
    end

    -- LibStub, so addons that embed libraries find it (each library may still bring its own)
    local libraries, minors = {}, {}
    local libStub = { libs = libraries, minors = minors, minor = 2 }
    function libStub:NewLibrary(major, minor)
        minor = tonumber(tostring(minor):match("%d+")) or 0
        if minors[major] and minors[major] >= minor then
            return nil
        end
        local old = minors[major]
        minors[major] = minor
        libraries[major] = libraries[major] or {}
        return libraries[major], old
    end
    function libStub:GetLibrary(major, isSilent)
        if not libraries[major] and not isSilent then
            error(("Cannot find a library instance of %q."):format(tostring(major)), 2)
        end
        return libraries[major], minors[major]
    end
    function libStub:IterateLibraries()
        return pairs(libraries)
    end
    setmetatable(libStub, { __call = libStub.GetLibrary })
    G.LibStub = libStub

    -- Slash commands
    G.SlashCmdList = {}
    G.hash_SlashCmdList = {}
    -- Key bindings
    sim.bindings, sim.overrideBindings = {}, {}
    G.SetBinding = function(key, command)
        if key then
            sim.bindings[key:upper()] = command
        end
        return true
    end
    G.SetBindingClick = function(key, buttonName, mouseButton)
        return G.SetBinding(key, "CLICK " .. buttonName .. ":" .. (mouseButton or "LeftButton"))
    end
    -- Override bindings as the client keeps them: one per owner for each key; the key does what the latest priority
    -- one says, else the latest of the others, and an owner clearing its own leaves the others' standing (the game's
    -- gamepad bindings and an addon's on the same keys). sim.overrideBindings[key] is the one in effect.
    local overrideStacks, overrideOrder = {}, 0
    local function chooseOverride(key)
        local best
        for _, entry in ipairs(overrideStacks[key] or {}) do
            if
                not best
                or (entry.isPriority and not best.isPriority)
                or (entry.isPriority == best.isPriority and entry.order > best.order)
            then
                best = entry
            end
        end
        sim.overrideBindings[key] = best
    end
    G.SetOverrideBinding = function(owner, isPriority, key, command)
        if not key then
            return
        end
        key = key:upper()
        local stack = overrideStacks[key] or {}
        overrideStacks[key] = stack
        for index = #stack, 1, -1 do
            if stack[index].owner == owner then
                table.remove(stack, index)
            end
        end
        if command and command ~= "" then
            overrideOrder = overrideOrder + 1
            stack[#stack + 1] =
                { owner = owner, command = command, isPriority = isPriority == true, order = overrideOrder }
        end
        chooseOverride(key)
    end
    G.SetOverrideBindingClick = function(owner, isPriority, key, buttonName, mouseButton)
        G.SetOverrideBinding(owner, isPriority, key, "CLICK " .. buttonName .. ":" .. (mouseButton or "LeftButton"))
    end
    G.ClearOverrideBindings = function(owner)
        for key, stack in pairs(overrideStacks) do
            local hadOwner = false
            for index = #stack, 1, -1 do
                if stack[index].owner == owner then
                    table.remove(stack, index)
                    hadOwner = true
                end
            end
            if hadOwner then
                chooseOverride(key)
            end
        end
    end
    -- A command's keys, each it is bound to (the client gives them in a steady order: here by name)
    G.GetBindingKey = function(command)
        local keys = {}
        for key, bound in pairs(sim.bindings) do
            if bound == command then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        return unpack(keys)
    end
    -- The key bindings window's list: every binding the game's and the addons' Bindings.xml define, in their order
    -- (addons.readBindings), with its category and its keys
    G.GetNumBindings = function()
        return #(sim.bindingList or {})
    end
    -- (the settings' Controls and Action Bars pages show a few bindings by their place in the list)
    G.C_KeyBindings = G.C_KeyBindings or {}
    G.C_KeyBindings.GetBindingIndex = function(action)
        for index, binding in ipairs(sim.bindingList or {}) do
            if binding.command == action then
                return index
            end
        end
        return nil
    end
    G.GetBinding = function(index)
        local binding = (sim.bindingList or {})[tonumber(index) or 0]
        if not binding then
            return nil
        end
        return binding.command, binding.category, G.GetBindingKey(binding.command)
    end
    G.GetBindingAction = function(key)
        local override = sim.overrideBindings[key]
        return override and override.command or sim.bindings[key] or ""
    end
    G.GetBindingByKey = G.GetBindingAction
    -- The game's default keys for the first action bar: 1 to 0, then - and =
    for index, key in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }) do
        if sim.bindings[key] == nil then
            sim.bindings[key] = "ACTIONBUTTON" .. index
        end
    end
    G.SaveBindings = function() end
    G.LoadBindings = function() end
    G.GetCurrentBindingSet = function()
        return 1
    end
    for key, command in pairs({
        M = "TOGGLEWORLDMAP",
        L = "TOGGLEQUESTLOG",
        ESCAPE = "TOGGLEGAMEMENU",
        C = "TOGGLECHARACTER0",
        B = "OPENALLBAGS",
        ENTER = "OPENCHAT",
        W = "MOVEFORWARD",
        S = "MOVEBACKWARD",
        A = "TURNLEFT",
        D = "TURNRIGHT",
        Q = "STRAFELEFT",
        E = "STRAFERIGHT",
        UP = "MOVEFORWARD",
        DOWN = "MOVEBACKWARD",
        LEFT = "TURNLEFT",
        RIGHT = "TURNRIGHT",
        NUMLOCK = "TOGGLEAUTORUN",
        NUMPADDIVIDE = "TOGGLERUN",
        -- The client's other default keys for the windows (run by the game's own bindings with the whole interface)
        P = "TOGGLESPELLBOOK",
        N = "TOGGLETALENTS",
        O = "TOGGLESOCIAL",
        U = "TOGGLECHARACTER2",
        H = "TOGGLECHARACTER4",
        F12 = "TOGGLEBACKPACK",
        Z = "TOGGLESHEATH",
        -- and the enemy nameplates on and off (the game's NAMEPLATES binding; they start off in this client)
        V = "NAMEPLATES",
    }) do
        sim.bindings[key] = command
    end
    -- Modifier keys and the cursor
    sim.modifiers = { shift = false, ctrl = false, alt = false }
    G.IsShiftKeyDown = function()
        return sim.modifiers.shift
    end
    G.IsControlKeyDown = function()
        return sim.modifiers.ctrl
    end
    G.IsAltKeyDown = function()
        return sim.modifiers.alt
    end
    G.IsModifierKeyDown = function()
        return sim.modifiers.shift or sim.modifiers.ctrl or sim.modifiers.alt
    end
    -- The modifier keys each modified click takes (the Bindings XML's ModifiedClick defaults, addons.readBindings;
    -- the settings change them): "SHIFT", "ALT-CTRL", "NONE". A click is that click when all its keys are held.
    local FALLBACK_CLICKS = { CHATLINK = "SHIFT", DRESSUP = "CTRL" }
    local function getModifiedClick(action)
        return (sim.modifiedClicks or {})[action] or FALLBACK_CLICKS[action] or "NONE"
    end
    G.GetModifiedClick = getModifiedClick
    G.SetModifiedClick = function(action, binding)
        sim.modifiedClicks = sim.modifiedClicks or {}
        sim.modifiedClicks[action] = binding or "NONE"
    end
    -- (a binding's mouse button: BUTTON1 the left; it must be the click's, while one is under way, sim.clickingButton)
    local MOUSE_BUTTONS = {
        BUTTON1 = "LeftButton",
        BUTTON2 = "RightButton",
        BUTTON3 = "MiddleButton",
        BUTTON4 = "Button4",
        BUTTON5 = "Button5",
    }
    G.IsModifiedClick = function(action)
        local binding = getModifiedClick(action)
        if binding == "NONE" or binding == "" then
            return false
        end
        for part in binding:gmatch("[^%-]+") do
            local mouseButton = MOUSE_BUTTONS[part:upper()]
            if mouseButton then
                if sim.clickingButton and sim.clickingButton ~= mouseButton then
                    return false
                end
            elseif not sim.modifiers[part:lower()] then
                return false
            end
        end
        return true
    end
    G.IsMouseButtonDown = function()
        return sim.mouseDown ~= nil
    end
    G.GetCursorPosition = function()
        local mouse = sim.mouse or { x = 0, y = 0 }
        return mouse.x, mouse.y
    end
    G.GetCursorInfo = function()
        return nil
    end
    G.ClearCursor = function() end
    -- The pointer the page shows (handlers' stream header "cursor"): the game's own (nil: Interface\Cursor\Point), or
    -- one set: a cursor's name ("ATTACK_CURSOR": Interface\Cursor\Attack), a texture path, a file id
    G.ResetCursor = function()
        if sim.cursor ~= nil then
            sim.cursor = nil
            sim.touchVisual()
        end
    end
    G.SetCursor = function(cursor)
        local path
        if type(cursor) == "number" then
            path = cursor
        elseif type(cursor) == "string" and cursor:find("[\\/]") then
            path = cursor
        elseif type(cursor) == "string" and cursor ~= "" then
            -- LOOT_ALL_CURSOR: Interface\Cursor\LootAll
            local name = cursor:gsub("_CURSOR$", ""):lower():gsub("^%l", string.upper):gsub("_(%l)", string.upper)
            path = "Interface\\Cursor\\" .. name
        end
        if sim.cursor ~= path then
            sim.cursor = path
            sim.touchVisual()
        end
        return path ~= nil
    end
    G.GetMouseFocus = function()
        return sim.motionFocus
    end
    G.GetMouseFoci = function()
        return { sim.motionFocus }
    end
    -- The screen in the interface's own units (UIParent's), and in pixels
    local function getUiScale()
        return G.UIParent and G.UIParent:GetScale() or 1
    end
    G.GetScreenWidth = function()
        return sim.screenWidth / getUiScale()
    end
    G.GetScreenHeight = function()
        return sim.screenHeight / getUiScale()
    end
    G.GetPhysicalScreenSize = function()
        return sim.physicalWidth or sim.screenWidth, sim.physicalHeight or sim.screenHeight
    end

    -- CVars
    sim.cvars = {
        uiScale = "1",
        useUiScale = "0",
        autoQuestWatch = "1",
        Sound_EnableSFX = "1",
        colorblindMode = "0",
        rotateMinimap = "0",
        showTutorials = "0",
        scriptErrors = "1",
        miniWorldMap = "1", -- the map opens in its window beside the quest panels, not over the whole screen
        userFontScale = "1",
        userFontScaleGlue = "1",
    }
    -- The client's own default for every other one, from the recorder's dump (boot fills it: /asrec api)
    sim.cvarDefaults = sim.cvarDefaults or {}
    -- The client's names are case-blind: wowless's defaults (lua/wowless.lua) are kept in lower case
    local function getDefault(name)
        local value = sim.cvarDefaults[name]
        if value == nil and type(name) == "string" and sim.cvarDefaultsLower then
            value = sim.cvarDefaultsLower[name:lower()]
        end
        return value
    end
    local function getCVar(name)
        local value = sim.cvars[name]
        if value == nil then
            value = getDefault(name)
        end
        return value
    end
    G.GetCVar = getCVar
    G.GetCVarBool = function(name)
        return getCVar(name) == "1"
    end
    G.SetCVar = function(name, value)
        sim.cvars[name] = tostring(value == true and "1" or value == false and "0" or value)
        return true
    end
    G.GetCVarDefault = function(name)
        local default = getDefault(name)
        if default == nil then
            default = sim.cvars[name]
        end
        return default
    end
    G.C_CVar = {
        GetCVar = G.GetCVar,
        SetCVar = G.SetCVar,
        GetCVarBool = G.GetCVarBool,
        RegisterCVar = function(name, value)
            sim.cvars[name] = sim.cvars[name] or tostring(value)
        end,
    }
    G.RegisterCVar = G.C_CVar.RegisterCVar

    -- Breath, fatigue and feign death bars: none running ("UNKNOWN", as the client says for an idle one)
    G.GetMirrorTimerInfo = function()
        return "UNKNOWN", 0, 0, 0, false, ""
    end
    G.GetMirrorTimerProgress = function()
        return 0
    end

    -- Whether the gamepad's stick moves the cursor (the game's smart navigation turns it off and on); no gamepad here
    local isGamePadCursorControl = false
    G.SetGamePadCursorControl = function(isOn)
        isGamePadCursorControl = isOn == true
    end
    G.IsGamePadCursorControlEnabled = function()
        return isGamePadCursorControl
    end

    -- Edit Mode's layouts, as the client keeps them for the account: none saved, so one of Blizzard's presets is the
    -- active one (1 Modern, 2 Classic, 3 Gamepad: config "editModeLayout"). The game's Edit Mode places the player
    -- and target frames, the action bars and the rest from it (EDIT_MODE_LAYOUTS_UPDATED at login, boot)
    local presetIndexes = { modern = 1, classic = 2, gamepad = 3 }
    local function getActiveLayout()
        local wanted = sim.config and sim.config.editModeLayout
        return presetIndexes[tostring(wanted or "modern"):lower()] or 1
    end
    G.C_EditMode = G.C_EditMode or {}
    -- A layout of the player's own, once a frame of the preset was moved: the client then makes one (a copy of the
    -- preset with the frame's new place) and makes it the active layout
    local savedLayouts, savedActiveLayout = {}, nil
    G.C_EditMode.GetLayouts = function()
        return { layouts = savedLayouts, activeLayout = savedActiveLayout or getActiveLayout() }
    end
    ---Keeps a system's new place (an Edit Mode drag) in the player's own layout, made from the preset the first time.
    ---@return boolean isKept The game's Edit Mode is loaded, and the place is kept for it to apply
    function sim.keepEditModePlace(system, point, relativePoint, offsetX, offsetY)
        local presets = G.EditModePresetLayoutManager
        local enum = G.Enum and G.Enum.EditModeLayoutType
        if not (presets and presets.GetCopyOfPresetLayouts and enum) then
            return false
        end
        if #savedLayouts == 0 then
            local copies = presets:GetCopyOfPresetLayouts()
            local layout = copies[getActiveLayout()] or copies[1]
            if not layout then
                return false
            end
            layout.layoutType, layout.layoutName = enum.Account, "AddonSim"
            savedLayouts[1] = layout
            savedActiveLayout = #copies + 1
        end
        for _, info in ipairs(savedLayouts[1].systems or {}) do
            if info.system == system then
                info.anchorInfo = {
                    point = point,
                    relativeTo = "UIParent",
                    relativePoint = relativePoint,
                    offsetX = offsetX,
                    offsetY = offsetY,
                }
                info.isInDefaultPosition = false
            end
        end
        return true
    end
    G.C_EditMode.GetEditModeDefaultLayout = function()
        local presets = G.Enum and G.Enum.EditModePresetLayouts
        return presets and presets.Modern or 0
    end
    -- The account's settings (which frames Edit Mode shows while it is open, snapping, the grid...): off until set,
    -- then kept, as the client keeps them for the account
    local accountSettingValues = {}
    G.C_EditMode.GetAccountSettings = function()
        local settings = {}
        for _, value in pairs(G.Enum and G.Enum.EditModeAccountSetting or {}) do
            settings[#settings + 1] = { setting = value, value = accountSettingValues[value] or 0 }
        end
        table.sort(settings, function(a, b)
            return a.setting < b.setting
        end)
        return settings
    end
    G.C_EditMode.SetAccountSetting = function(setting, value)
        if type(setting) == "number" then
            accountSettingValues[setting] = tonumber(value) or (value and 1 or 0)
        end
    end
    -- What Edit Mode's Save button sends: every layout of the player's (a preset copied and changed: places,
    -- sizes, the bars' settings) and the active one; the next GetLayouts answers with them, as the client does
    local function copyTable(value)
        if type(value) ~= "table" then
            return value
        end
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = copyTable(item)
        end
        return copy
    end
    G.C_EditMode.SaveLayouts = function(layoutInfo)
        if type(layoutInfo) ~= "table" then
            return
        end
        -- (only the player's own: the presets come with the layouts the game sends, and it puts them in front again
        -- whenever it reads them, as the client keeps only the others)
        local presetType = G.Enum and G.Enum.EditModeLayoutType and G.Enum.EditModeLayoutType.Preset
        savedLayouts = {}
        for _, layout in ipairs(layoutInfo.layouts or {}) do
            if layout.layoutType ~= presetType then
                savedLayouts[#savedLayouts + 1] = copyTable(layout)
            end
        end
        if type(layoutInfo.activeLayout) == "number" then
            savedActiveLayout = layoutInfo.activeLayout
        end
        if sim.onStateChanged then
            sim.onStateChanged()
        end
    end

    -- Action bars 2 to 8, shown or not (the game's Settings, Action Bars; Edit Mode shows the ones turned on): off for a
    -- new character, kept from then on. The game's bars follow at once (MultiActionBar_Update, as its settings
    -- callback runs it), however the toggles were set
    local barToggles = { false, false, false, false, false, false, false }
    G.GetActionBarToggles = function()
        return unpack(barToggles, 1, 7)
    end
    G.SetActionBarToggles = function(...)
        for index = 1, 7 do
            barToggles[index] = (select(index, ...)) and true or false
        end
        if G.MultiActionBar_Update then
            sim.runSecurely(G.MultiActionBar_Update)
        end
        if G.EventRegistry and G.EventRegistry.TriggerEvent then
            sim.runSecurely(G.EventRegistry.TriggerEvent, G.EventRegistry, "ActionBarShownSettingUpdated")
        end
        if sim.onStateChanged then
            sim.onStateChanged()
        end
    end

    ---Edit Mode's saved state, for the simulator's own saves (kept between runs, as the account's are in the client).
    function sim.getEditModeState()
        local settings = {}
        for setting, value in pairs(accountSettingValues) do
            settings[#settings + 1] = { setting = setting, value = value }
        end
        return {
            layouts = copyTable(savedLayouts),
            activeLayout = savedActiveLayout,
            accountSettings = settings,
            actionBars = { unpack(barToggles, 1, 7) },
        }
    end
    function sim.setEditModeState(state)
        if type(state) ~= "table" then
            return
        end
        if type(state.layouts) == "table" then
            savedLayouts = copyTable(state.layouts)
        end
        if type(state.activeLayout) == "number" then
            savedActiveLayout = state.activeLayout
        end
        for _, entry in ipairs(state.accountSettings or {}) do
            accountSettingValues[entry.setting] = entry.value
        end
        for index = 1, 7 do
            barToggles[index] = state.actionBars and state.actionBars[index] == true or false
        end
    end
    -- The active layout (a preset by its index, 1 Modern, 2 Classic, 3 Gamepad, or the player's own): the game's Edit
    -- Mode places everything again from it, as the client tells it (the gamepad mode switches to its preset and back)
    G.C_EditMode.SetActiveLayout = function(index)
        if type(index) ~= "number" or index == (savedActiveLayout or getActiveLayout()) then
            return
        end
        savedActiveLayout = index
        if sim.onStateChanged then
            sim.onStateChanged()
        end
        sim.fireEvent("EDIT_MODE_LAYOUTS_UPDATED", G.C_EditMode.GetLayouts(), false)
    end
    G.C_EditMode.OnEditModeExit = function() end
    -- A layout made (Edit Mode's Save on a preset, a new or imported one): the client makes it the active one when
    -- asked and sends the layouts again, which the game applies
    G.C_EditMode.OnLayoutAdded = function(layoutIndex, activateNewLayout)
        if activateNewLayout and type(layoutIndex) == "number" then
            savedActiveLayout = layoutIndex
        end
        if sim.onStateChanged then
            sim.onStateChanged()
        end
        sim.fireEvent("EDIT_MODE_LAYOUTS_UPDATED", G.C_EditMode.GetLayouts(), false)
    end
    -- A layout deleted (the game has saved the others already): the active one falls back to the first preset when
    -- it was the one deleted, and the ones after it move up
    G.C_EditMode.OnLayoutDeleted = function(layoutIndex)
        local active = savedActiveLayout or getActiveLayout()
        if active == layoutIndex then
            savedActiveLayout = 1
        elseif type(layoutIndex) == "number" and active > layoutIndex then
            savedActiveLayout = active - 1
        end
        if sim.onStateChanged then
            sim.onStateChanged()
        end
        sim.fireEvent("EDIT_MODE_LAYOUTS_UPDATED", G.C_EditMode.GetLayouts(), false)
    end
    G.C_EditMode.IsValidLayoutName = function(name)
        return type(name) == "string" and name ~= ""
    end

    -- Chat windows, as a new character has them: General and Combat Log docked, the rest unused. Each window's
    -- background is black at a quarter alpha (the chat frame colours its background from these)
    local chatWindows = { { name = "General", docked = 1 }, { name = "Combat Log", docked = 2 } }
    G.GetChatWindowInfo = function(id)
        local window = chatWindows[id]
        -- name, fontSize, r, g, b, alpha, shown, locked, docked, uninteractable
        return window and window.name or "",
            14,
            0,
            0,
            0,
            0.25,
            window ~= nil,
            window ~= nil,
            window and window.docked or nil,
            false
    end
    G.GetChatWindowMessages = function()
        return
    end
    G.GetChatWindowChannels = function()
        return
    end
    G.GetChatWindowSavedPosition = function()
        return nil
    end
    G.GetChatWindowSavedDimensions = function()
        return nil
    end

    -- Sound: kits, files, music, each on its channel and handle, played by the page (lua/sound.lua)
    require("sound").install(G)
    G.SOUNDKIT = setmetatable({}, {
        __index = function(_, key)
            return key
        end,
    })
    G.ReloadUI = function()
        sim.requestReload = true
    end
    -- (UIManagerDocumentation: the frames are never nil; the ping UI scales the cursor by UIParent's scale. No display
    -- with a notch: its safe regions are the whole screen)
    G.C_UI = {
        Reload = G.ReloadUI,
        GetUIParent = function()
            return G.UIParent
        end,
        GetWorldFrame = function()
            return G.WorldFrame
        end,
        DoesAnyDisplayHaveNotch = function()
            return false
        end,
        ShouldUIParentAvoidNotch = function()
            return false
        end,
        GetTopLeftNotchSafeRegion = function()
            return 0, 0, 0, 0
        end,
        GetTopRightNotchSafeRegion = function()
            return 0, 0, 0, 0
        end,
    }
    G.Logout = function() end
    G.Quit = function() end
    G.Screenshot = function() end
    G.GetLocale = function()
        return config.locale or "enUS"
    end
    -- The languages the client offers, as the communities' language menu reads them: the one it runs in
    local LOCALE_IDS = {
        enUS = 0,
        koKR = 1,
        frFR = 2,
        deDE = 3,
        zhCN = 4,
        zhTW = 5,
        esES = 6,
        esMX = 7,
        ruRU = 8,
        ptBR = 10,
        itIT = 11,
    }
    G.GetAvailableLocaleInfo = function()
        local name = config.locale or "enUS"
        return { { localeId = LOCALE_IDS[name] or 0, localeName = name } }
    end
    -- The group's members by role: none chosen in the simulator, so each counts under NOROLE (the player too)
    G.GetGroupMemberCounts = function()
        local members = G.GetNumGroupMembers and G.GetNumGroupMembers() or 0
        return { TANK = 0, HEALER = 0, DAMAGER = 0, NOROLE = math.max(members, 1) }
    end
    G.GetBuildInfo = function()
        return config.version or "1.60.1",
            config.buildNumber or config.build or "70009",
            config.buildDate or "Nov 1 2026",
            config.interface or 16001
    end
    G.IsTestBuild = function()
        return false
    end
    G.IsPublicBuild = function()
        return true
    end
    G.WOW_PROJECT_ID, G.WOW_PROJECT_MAINLINE, G.WOW_PROJECT_CLASSIC = config.projectId or 1, 1, 2
    G.LE_EXPANSION_LEVEL_CURRENT = 0
    G.GetExpansionLevel = function()
        return 0
    end
    G.GetClientDisplayExpansionLevel = function()
        return 0
    end
    G.GetMaxLevelForPlayerExpansion = function()
        return 60
    end
    G.GetMaxPlayerLevel = function()
        return 60
    end
    -- Enumerations and constants the client has but its documentation leaves out (Enum.GameMode...): each unknown
    -- value is a distinct made-up number, so tables keyed by them still build; every one is noted
    local madeUpValue = -1000
    local function makeUnknownValues(groupName)
        return setmetatable({}, {
            __index = function(target, key)
                if type(key) ~= "string" or key:match("^__") then
                    return nil
                end
                madeUpValue = madeUpValue - 1
                sim.noteStub(groupName .. "." .. key)
                rawset(target, key, madeUpValue)
                return madeUpValue
            end,
        })
    end
    sim.makeUnknownValues = makeUnknownValues
    local function makeUnknownGroups(rootName)
        return function(target, key)
            if type(key) ~= "string" then
                return nil
            end
            local value = makeUnknownValues(rootName .. "." .. key)
            rawset(target, key, value)
            return value
        end
    end
    G.Constants = setmetatable({}, { __index = makeUnknownGroups("Constants") })
    G.Enum = setmetatable({
        UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 },
        QuestTag = {
            Group = 1,
            PvP = 41,
            Raid = 62,
            Dungeon = 81,
            Legendary = 83,
            Heroic = 85,
            Raid10 = 88,
            Raid25 = 89,
        },
        QuestFrequency = { Default = 0, Daily = 1, Weekly = 2 },
        ItemQuality = {
            Poor = 0,
            Common = 1,
            Uncommon = 2,
            Rare = 3,
            Epic = 4,
            Legendary = 5,
            Artifact = 6,
            Heirloom = 7,
        },
        QuestWatchType = { Automatic = 0, Manual = 1 },
        SuperTrackingType = { Quest = 0, UserWaypoint = 1 },
        TooltipDataType = { Item = 0, Spell = 1, Unit = 2, Quest = 23 },
        CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 },
        ItemClass = {
            Consumable = 0,
            Container = 1,
            Weapon = 2,
            Armor = 4,
            Reagent = 5,
            Tradegoods = 7,
            Recipe = 9,
            Questitem = 12,
            Miscellaneous = 15,
        },
    }, { __index = makeUnknownGroups("Enum") })
    G.LE_PARTY_CATEGORY_HOME, G.LE_PARTY_CATEGORY_INSTANCE = 1, 2
    G.LE_QUEST_FREQUENCY_DEFAULT, G.LE_QUEST_FREQUENCY_DAILY, G.LE_QUEST_FREQUENCY_WEEKLY = 0, 1, 2
    G.MAX_QUESTS = 20
    G.MAX_WATCHABLE_QUESTS = 25
    G.MAX_QUESTLOG_QUESTS = 20
    G.OBJECTIVES_WATCH_TOO_MANY = "You are already tracking the maximum number of quests."
    G.SEARCH, G.OKAY, G.CANCEL, G.YES, G.NO, G.ACCEPT, G.DECLINE, G.CLOSE =
        "Search", "Okay", "Cancel", "Yes", "No", "Accept", "Decline", "Close"
    G.QUEST_COMPLETE, G.COMPLETE, G.FAILED, G.ABANDON_QUEST = "Quest Complete", "Complete", "Failed", "Abandon Quest"
    G.TRACK_QUEST, G.UNTRACK_QUEST, G.SHARE_QUEST = "Track", "Untrack", "Share"
    G.LEVEL, G.TRACKER_HEADER_QUESTS = "Level", "Quests"
    setmetatable(G, {
        __index = function(_, key)
            -- Global strings the game defines in their thousands: a missing one reads as its own name, noted
            -- The client's LE_ constants the documentation leaves out: distinct made-up numbers, noted
            if type(key) == "string" and key:match("^LE_[A-Z0-9_]+$") then
                madeUpValue = madeUpValue - 1
                sim.noteStub(key)
                rawset(G, key, madeUpValue)
                return madeUpValue
            end
            -- (with the whole interface the game's code and its string table are all here: a name neither has is not
            -- the client's either, an addon's own probe (EUI_CLIENT_BLOCKED), nothing to add)
            if
                type(key) == "string"
                and key:match("^[A-Z][A-Z0-9_]+$")
                and #key > 3
                and not key:match("^C_")
                and not (sim.isWholeInterface and sim.hasGlobalStrings)
            then
                sim.noteStub("global string " .. key)
                return nil
            end
            return nil
        end,
    })
end

return api
