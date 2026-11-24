-- The SDK's runner (src/sdk/): lua/play.lua itself, booted before it knows what to play, and able to stay a live game
-- that takes commands. The SDK keeps such processes booted ahead (a warm pool), so a scenario starts at once instead
-- of after the 2 s boot, and the game a run ends in stays up to be looked at and poked.
--   luajit lua/sdkplay.lua <root> <runtime.json>
-- Once booted it writes a line {"ready":true,...} and reads its job, one JSON line:
--   { "path": "<scenario>", "env": { NAME = value } }
-- path names the scenario (its saved scenes and snapshots are named after it; one that is not there is a live game
-- with nothing played yet), env what os.getenv answers besides the process's own (ADDONSIM_UPDATE...). Then it takes
-- commands, one JSON line each, and answers each with one line; the answers start with \30, any other line on stdout
-- is what was printed. Commands ({ id, op, ... }):
--   eval { code | file }   Lua in the scenario's environment (its steps, G, require); answers what it returned, the
--                          failed checks, Lua errors and chat lines it caused, and what it printed
--   frames { filter, creators, limit }, findFrame { ref }, state, scene   what is on screen (lua/sdkui.lua)
--   host { request }       one of the simulator's own requests (lua/boot.lua's handlers: inspect, frameInfo...)
--   finish                 the scenario ends: play.lua's report is written and the process ends
-- The steps are play.lua's own, so what works here works the same in a scenario file. The game's clock moves only
-- when a step moves it (wait, and the short wait after each step), never between commands.
local root, runtimePath = arg[1] or ".", arg[2]
package.path = root .. "/lua/?.lua;" .. package.path
local json = require("json")
local out, stdin = io.stdout, io.stdin
local ANSWER = "\30"

local function writeAnswer(text)
    out:write(ANSWER, text, "\n")
    out:flush()
end

-- What os.getenv answers for the job (the runner's switches, set per scenario)
local realGetenv, overrides = os.getenv, {}
os.getenv = function(name)
    local value = overrides[name]
    if value ~= nil then
        return value
    end
    return realGetenv(name)
end

local runtime -- boot.lua's answer, again after each reload (play.lua's steps.reload boots it afresh)
local livePath -- the scenario's path, which play.lua loads; the live game's commands are served in its place
local serve -- (below)

local realDofile, realLoadfile = dofile, loadfile
local isFirstBoot = true
local function waitForJob()
    writeAnswer(json.encode({ ready = true, bootSeconds = runtime.bootSeconds, errors = #runtime.sim.errors }))
    local line = stdin:read("*l")
    if not line then
        os.exit(0)
    end -- (a warm process no longer wanted)
    local job = json.decode(line)
    for name, value in pairs(job.env or {}) do
        overrides[name] = tostring(value)
    end
    livePath = job.path or (root .. "/live.lua")
    arg[3] = livePath
end
dofile = function(path, ...)
    if type(path) == "string" and path:match("[/\\]lua[/\\]boot%.lua$") then
        runtime = realDofile(path, ...)
        if isFirstBoot then
            isFirstBoot = false
            waitForJob()
        end
        return runtime
    end
    return realDofile(path, ...)
end
-- play.lua loads the scenario by its path: in its place, the commands (the scenario itself is the first command)
loadfile = function(path, ...)
    if livePath and path == livePath then
        livePath = nil
        local getfenv = getfenv
        return function()
            return serve(getfenv(1))
        end
    end
    return realLoadfile(path, ...)
end

-- Upvalues of play.lua's steps: its failed checks and its count of steps, read where play.lua keeps them (in the
-- step itself, or in a helper it calls)
local function upvalue(fn, wanted, depth)
    if type(fn) ~= "function" then
        return nil
    end
    for index = 1, 200 do
        local name, value = debug.getupvalue(fn, index)
        if not name then
            break
        end
        if name == wanted then
            return value
        end
    end
    if (depth or 1) > 0 then
        for index = 1, 200 do
            local name, value = debug.getupvalue(fn, index)
            if not name then
                break
            end
            if type(value) == "function" then
                local found = upvalue(value, wanted, 0)
                if found ~= nil then
                    return found
                end
            end
        end
    end
end

-- Where a step was called from: the first frame on the stack in the user's own code (a scenario file run, or eval)
local userSources = { ["=eval"] = "eval" }
local function whereCalled(level)
    for depth = level, 60 do
        local info = debug.getinfo(depth, "Sl")
        if not info then
            return nil
        end
        local file = userSources[info.source]
        if file then
            return file, info.currentline
        end
    end
end

-- Each step wrapped once: a check it fails is told with the line of the command that called it, as play.lua tells a
-- scenario file's (a line "  at file:line" under it; play.lua finds lines in files only, not in a command's code)
local wrapped, stepDepth = setmetatable({}, { __mode = "k" }), 0
-- Where a failed check is told to be when no frame says (a command of one expression: its step was a tail call, which
-- leaves no frame behind; it is on the command's first line)
local currentDefault
local function pack(...)
    return { n = select("#", ...), ... }
end
local UNWRAPPED = { find = true, forShard = true, mapZoomLevelCount = true, enemy = true, combatState = true }
local function wrapSteps(env, failures)
    for name, fn in pairs(env) do
        if type(fn) == "function" and not wrapped[fn] and not UNWRAPPED[name] then
            local step = fn
            local wrapper = function(...)
                if stepDepth > 0 then
                    return step(...)
                end
                stepDepth = 1
                local before = #failures
                local file, line = whereCalled(3)
                if not file and currentDefault then
                    file, line = currentDefault, 1
                end
                local results = pack(step(...))
                stepDepth = 0
                if file then
                    for index = before + 1, #failures do
                        local text = failures[index]
                        if not text:find("\n  at ", 1, true) then
                            failures[index] = text .. "\n  at " .. file .. ":" .. line
                        end
                    end
                end
                return unpack(results, 1, results.n)
            end
            wrapped[wrapper] = true
            env[name] = wrapper
        end
    end
end

-- Values as JSON can carry them: frames by their label, tables a few levels deep, functions by kind
local function toData(value, depth, seen)
    local kind = type(value)
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return tostring(value)
        end
        return value
    elseif kind == "string" or kind == "boolean" or kind == "nil" then
        return value
    elseif kind ~= "table" then
        return "<" .. kind .. ">"
    end
    local W = runtime.W
    local state = W.state[value]
    if state then
        return "<"
            .. state.type
            .. " "
            .. runtime.scene.frameLabel(value)
            .. " #"
            .. state.id
            .. ((value.IsShown and not value:IsShown()) and ", hidden" or "")
            .. ">"
    end
    if seen[value] then
        return "<cycle>"
    end
    if depth <= 0 then
        return "<table>"
    end
    seen[value] = true
    local result, count, isArray = {}, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then
            isArray = false
        end
    end
    if isArray and count > 0 then
        for index = 1, math.min(#value, 100) do
            result[index] = toData(value[index], depth - 1, seen)
        end
        if #value > 100 then
            result[101] = "... " .. (#value - 100) .. " more"
        end
    else
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for index, key in ipairs(keys) do
            if index > 60 then
                result["..."] = (#keys - 60) .. " more"
                break
            end
            result[tostring(key)] = toData(value[key], depth - 1, seen)
        end
    end
    seen[value] = nil
    return result
end

local sdkui -- (required at the first command: play.lua's reload forgets the simulator's modules, this among them)

-- A command's chunk run: what it returned, and what it caused
local function runUser(chunk, env, failures, act)
    local sim = runtime.sim
    local failureCount, chatCount = #failures, #sim.chat
    local errorCounts = {}
    for _, entry in ipairs(sim.errors) do
        errorCounts[entry] = entry.count
    end
    local stepsBefore = upvalue(act, "stepCount") or 0
    local nowBefore = sim.now
    local printed = {}
    local realWrite, realPrint = io.write, print
    io.write = function(...)
        local text = table.concat({ ... })
        for line in (text:gsub("\n$", "") .. "\n"):gmatch("(.-)\n") do
            printed[#printed + 1] = (line:gsub("^  ", ""))
        end
    end
    print = function(...)
        local parts = {}
        for index = 1, select("#", ...) do
            parts[index] = tostring((select(index, ...)))
        end
        printed[#printed + 1] = table.concat(parts, "\t")
    end
    stepDepth = 0
    setfenv(chunk, env)
    local started = os.clock()
    local where, traceback
    local results = {
        xpcall(chunk, function(problem)
            local file, line = whereCalled(2)
            where = file and { file = file, line = line }
            -- The frames above the command (the code's own, the addons' and the game's), not this runner's and play.lua's
            local frames = {}
            for frame in debug.traceback("", 2):gmatch("[^\n]+") do
                if frame:find("sdkplay%.lua") or frame:find("[/\\]lua[/\\]play%.lua") then
                    break
                end
                if frame ~= "stack traceback:" and frame:find("%S") then
                    frames[#frames + 1] = (frame:gsub("^%s+", ""))
                end
            end
            traceback = table.concat(frames, "\n")
            return tostring(problem)
        end),
    }
    io.write, print = realWrite, realPrint
    sim = runtime.sim -- (a reload in the chunk: the new game's)
    local answer =
        { ok = results[1], output = printed, seconds = math.floor((os.clock() - started) * 1000 + 0.5) / 1000 }
    if results[1] then
        local values = {}
        for index = 2, table.maxn(results) do
            values[index - 1] = toData(results[index], 4, {})
        end
        answer.result = #values <= 1 and values[1] or values
        if table.maxn(results) == 1 then
            answer.result = nil
        end
    else
        answer.error = tostring(results[2])
        if traceback ~= "" then
            answer.traceback = traceback
        end
        if where then
            answer.file, answer.line = where.file, where.line
        end
    end
    local newFailures = {}
    for index = failureCount + 1, #failures do
        newFailures[#newFailures + 1] = failures[index]
    end
    answer.failures = newFailures
    local newErrors = {}
    for _, entry in ipairs(sim.errors) do
        local before = errorCounts[entry]
        if not before or entry.count > before then
            newErrors[#newErrors + 1] =
                { message = entry.message, stack = entry.stack, count = entry.count - (before or 0) }
        end
    end
    answer.errors = newErrors
    local chat = {}
    for index = math.min(chatCount, #sim.chat) + 1, #sim.chat do
        chat[#chat + 1] = sdkui.plain(sim.chat[index].text)
    end
    answer.chat = chat
    answer.steps = (upvalue(act, "stepCount") or 0) - stepsBefore
    answer.gameSeconds = math.floor(((sim.now or 0) - (nowBefore or 0)) * 100 + 0.5) / 100
    return answer
end

local function compile(command)
    if command.file then
        local chunk, problem = realLoadfile(command.file)
        if chunk then
            userSources["@" .. command.file] = command.file
        end
        return chunk, problem
    end
    local code = command.code or ""
    local chunk = loadstring("return " .. code, "=eval")
    if chunk then
        return chunk, nil, "eval"
    end
    return loadstring(code, "=eval")
end

serve = function(env)
    sdkui = require("sdkui")
    local failures = upvalue(env.expect, "failures", 1) or {}
    local act = upvalue(env.accept, "act") or function() end
    while true do
        local line = stdin:read("*l")
        if not line then
            break
        end
        local isDecoded, command = pcall(json.decode, line)
        if not isDecoded or type(command) ~= "table" then
            writeAnswer(json.encode({ error = "bad command" }))
        elseif command.op == "finish" then
            writeAnswer(json.encode({ id = command.id, ok = true }))
            break
        else
            sdkui = package.loaded.sdkui or require("sdkui")
            wrapSteps(env, failures)
            local isDone, answer = xpcall(function()
                local op = command.op
                if op == "eval" then
                    local chunk, problem, default = compile(command)
                    if not chunk then
                        return {
                            ok = false,
                            error = tostring(problem),
                            output = {},
                            failures = {},
                            errors = {},
                            chat = {},
                        }
                    end
                    currentDefault = default
                    local result = runUser(chunk, env, failures, act)
                    currentDefault = nil
                    -- A scenario run whole: drawn once at its end, as play.lua does, so drawing errors surface too
                    if command.draw then
                        runtime.scene.export()
                    end
                    return result
                elseif op == "frames" then
                    return sdkui.frames(runtime, command)
                elseif op == "findFrame" then
                    local frame = sdkui.findFrame(runtime, command.ref)
                    if not frame then
                        return { error = "no frame " .. tostring(command.ref) }
                    end
                    local s = runtime.W.state[frame]
                    return runtime.handlers.frameInfo({ frameId = s.id })
                elseif op == "state" then
                    return sdkui.state(runtime)
                elseif op == "scene" then
                    local sim = runtime.sim
                    return { width = sim.screenWidth, height = sim.screenHeight, items = runtime.scene.export() }
                elseif op == "host" then
                    local request = command.request or {}
                    local handler = runtime.handlers[request.op]
                    if not handler then
                        return { error = "unknown op " .. tostring(request.op) }
                    end
                    return handler(request)
                end
                return { error = "unknown command " .. tostring(op) }
            end, debug.traceback)
            if not isDone then
                answer = { error = tostring(answer) }
            end
            if type(answer.raw) == "string" then
                writeAnswer(answer.raw:sub(1, -2) .. ',"id":' .. tostring(command.id) .. "}")
            else
                answer.id = command.id
                writeAnswer(json.encode(answer))
            end
        end
    end
end

arg = { [0] = root .. "/lua/play.lua", root, runtimePath }
realDofile(root .. "/lua/play.lua")
