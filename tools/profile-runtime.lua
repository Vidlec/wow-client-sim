-- Where the running simulator's time goes, after the startup: the clock's ticks (every addon's OnUpdate, timers,
-- movement) and the scene's export the page polls, timed and sampled with LuaJIT's profiler.
--   luajit tools/profile-runtime.lua <AddonSim folder> <runtime.json> [open the map: 1]
local root, runtimePath, isMapOpen = arg[1] or ".", arg[2] or "cache/runtime.json", arg[3] == "1"
package.path = root .. "/lua/?.lua;" .. package.path
arg = { [1] = root, [2] = runtimePath }
local runtime = dofile(root .. "/lua/boot.lua")
local sim, handlers = runtime.sim, runtime.handlers
local scene = require("scene")
local clock = sim.clock

-- Settle, as the page would have after loading
for _ = 1, 40 do
    sim.tick(0.05)
end
if isMapOpen then
    sim.call(sim.G.ToggleWorldMap)
    for _ = 1, 40 do
        sim.tick(0.05)
    end
end

local profile = require("jit.profile")
local selfCounts, fileCounts, total = {}, {}, 0
local function sample(thread, samples)
    total = total + samples
    local frame = profile.dumpstack(thread, "pl", 1)
    selfCounts[frame] = (selfCounts[frame] or 0) + samples
    local file = frame:match("^(.-):%d+$") or frame
    fileCounts[file] = (fileCounts[file] or 0) + samples
end

local function measure(label, count, body)
    selfCounts, fileCounts, total = {}, {}, 0
    profile.start("li1", sample)
    local started = clock()
    for _ = 1, count do
        body()
    end
    local ms = (clock() - started) / count
    profile.stop()
    print(("== %s: %.2f ms each"):format(label, ms))
    for _, counts in ipairs({ fileCounts, selfCounts }) do
        local rows = {}
        for name, value in pairs(counts) do
            rows[#rows + 1] = { name, value }
        end
        table.sort(rows, function(a, b)
            return a[2] > b[2]
        end)
        for index = 1, math.min(10, #rows) do
            print(("%6.1f%%  %s"):format(rows[index][2] * 100 / math.max(total, 1), rows[index][1]))
        end
        print("   --")
    end
end

measure("tick (50 ms of game time)", 200, function()
    sim.tick(0.05)
end)
measure("scene export (changed)", 60, function()
    sim.touch()
    scene.export()
end)
measure("scene request as the page asks it", 60, function()
    sim.touch()
    handlers.scene({ op = "scene" })
end)
os.exit(0)
