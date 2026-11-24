-- Runs the recorder's "/asrec probe" inside the simulator, and compares its answers with the real client's (the
-- recorder's SavedVariables, found as the API dump is, or given): every answer that differs, by its path.
--   luajit tools/probe-sim.lua <root> <runtime.json> [out.json] [AddonSimRecorder.lua saved variables]
-- Without the client's answers it only writes the simulator's (out.json) and says what it found.
local root = arg[1]
package.path = root .. "/lua/?.lua;" .. package.path
local runtime = dofile(root .. "/lua/boot.lua")
local sim, handlers = runtime.sim, runtime.handlers
local G = sim.G
local json = require("json")
for _ = 1, 30 do
    handlers.frame({ dt = 1 / 60 })
end
local file = assert(io.open(root .. "/recorder/AddonSimRecorder/AddonSimRecorder.lua", "rb"))
local chunk = assert(loadstring(file:read("*a"), "@Interface/AddOns/AddonSimRecorder/AddonSimRecorder.lua"))
file:close()
setfenv(chunk, G)
sim.call(chunk, "AddonSimRecorder", {})
G.SlashCmdList.ADDONSIMRECORDER("probe")
for _ = 1, 5 do
    handlers.frame({ dt = 1 / 60 })
end
local simulated = G.AddonSimRecording.probe
if arg[3] and arg[3] ~= "" then
    local out = assert(io.open(arg[3], "wb"))
    out:write(json.encode(simulated))
    out:close()
end
for index = 1, #sim.errors do
    io.stderr:write("Lua error in the simulator: " .. sim.errors[index].message .. "\n")
end

-- The client's answers: the recorder's saved variables
local configFile = io.open(arg[2], "rb")
local config = configFile and json.decode(configFile:read("*a")) or {}
if configFile then
    configFile:close()
end
local savedPath = arg[4] or require("apisurface").findDump(config)
local real
if savedPath then
    local savedChunk = loadfile(savedPath)
    if savedChunk then
        local saved = {}
        setfenv(savedChunk, saved)
        if pcall(savedChunk) and type(saved.AddonSimRecording) == "table" then
            real = saved.AddonSimRecording.probe
        end
    end
end
if not real then
    print("No probe from the client yet: in the game, /asrec probe and then /reload (" .. tostring(savedPath) .. ")")
    return
end
print(
    string.format(
        "The client (%s, build %s, %s) against the simulator:",
        tostring(real.client),
        tostring(real.build),
        tostring(real.recordedAt)
    )
)

-- Every leaf that differs, by path
local differences = 0
local function show(value)
    if type(value) == "table" then
        return json.encode(value):sub(1, 160)
    end
    return tostring(value)
end
local function compare(path, clientValue, simValue)
    if type(clientValue) == "table" and type(simValue) == "table" then
        local keys = {}
        for key in pairs(clientValue) do
            keys[key] = true
        end
        for key in pairs(simValue) do
            keys[key] = true
        end
        local sorted = {}
        for key in pairs(keys) do
            sorted[#sorted + 1] = key
        end
        table.sort(sorted, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, key in ipairs(sorted) do
            compare(path .. "." .. tostring(key), clientValue[key], simValue[key])
        end
        return
    end
    local isSame = clientValue == simValue
    if not isSame and type(clientValue) == "number" and type(simValue) == "number" then
        isSame = math.abs(clientValue - simValue) < 1e-6
    end
    if not isSame then
        differences = differences + 1
        print(string.format("  %-60s client %-30s sim %s", path, show(clientValue), show(simValue)))
    end
end
compare("probe", real.results, simulated.results)
print(differences == 0 and "No differences." or (differences .. " differences."))
