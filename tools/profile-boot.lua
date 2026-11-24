-- Where the simulator's startup goes: runs the boot (lua/boot.lua, as the server's host does) under LuaJIT's sampling
-- profiler and prints the functions, files and VM states the samples fell in, self and inclusive.
--   luajit tools/profile-boot.lua <AddonSim folder> <runtime.json>      (cache/runtime.json, written by the server)
local root, runtimePath = arg[1] or ".", arg[2] or "cache/runtime.json"
package.path = root .. "/lua/?.lua;" .. package.path
arg = { [1] = root, [2] = runtimePath }

local profile = require("jit.profile")
local selfCounts, inclusiveCounts, fileCounts, states = {}, {}, {}, {}
local total = 0
local STATE_NAMES = { N = "compiled", I = "interpreted", C = "C code", G = "garbage collector", J = "JIT compiler" }

profile.start("fi1", function(thread, samples, vmstate)
    total = total + samples
    states[vmstate] = (states[vmstate] or 0) + samples
    local stack = profile.dumpstack(thread, "pl\n", 40)
    local seen, isTop = {}, true
    for frame in stack:gmatch("[^\n]+") do
        if isTop then
            selfCounts[frame] = (selfCounts[frame] or 0) + samples
            local file = frame:match("^(.-):%d+$") or frame
            fileCounts[file] = (fileCounts[file] or 0) + samples
            isTop = false
        end
        if not seen[frame] then
            seen[frame] = true
            inclusiveCounts[frame] = (inclusiveCounts[frame] or 0) + samples
        end
    end
end)
local started = os.clock()
dofile(root .. "/lua/boot.lua")
local seconds = os.clock() - started
profile.stop()

local function top(counts, limit, title)
    local rows = {}
    for name, count in pairs(counts) do
        rows[#rows + 1] = { name, count }
    end
    table.sort(rows, function(a, b)
        return a[2] > b[2]
    end)
    print(("== %s"):format(title))
    for index = 1, math.min(limit, #rows) do
        print(("%6.1f%%  %s"):format(rows[index][2] * 100 / total, rows[index][1]))
    end
end
print(("boot: %.1f s, %d samples"):format(seconds, total))
local stateRows = {}
for state, count in pairs(states) do
    stateRows[#stateRows + 1] = ("%s %.1f%%"):format(STATE_NAMES[state] or state, count * 100 / total)
end
print("VM: " .. table.concat(stateRows, ", "))
top(fileCounts, 25, "files (self)")
top(selfCounts, 30, "lines (self)")
top(inclusiveCounts, 60, "lines (inclusive)")
os.exit(0)
