-- A sampling profile of the running simulator, for finding what a frame of the live game spends its time on:
-- ADDONSIM_PROFILE_FILE=<path> when the server starts, and every few seconds the hottest places (each with the two
-- calls that led to it) are added to that file, the share of samples each took since the last report. LuaJIT's own
-- profiler takes the samples (a millisecond apart); samples in the host's wait for the next request show as host.lua.
local hostprofile = {}

local REPORT_SECONDS = 4
local LISTED = 40

local path = os.getenv("ADDONSIM_PROFILE_FILE")
local counts, total, since = {}, 0, os.clock()

function hostprofile.start()
    if not path then
        return
    end
    local isLoaded, profile = pcall(require, "jit.profile")
    if not isLoaded then
        return
    end
    profile.start("fi1", function(thread, samples)
        local where = profile.dumpstack(thread, "F <", 3)
        counts[where] = (counts[where] or 0) + samples
        total = total + samples
    end)
end

---Adds a report to the file when its time has come (called between requests)
function hostprofile.report()
    if not path or os.clock() - since < REPORT_SECONDS then
        return
    end
    local list = {}
    for where, count in pairs(counts) do
        list[#list + 1] = { where, count }
    end
    table.sort(list, function(first, second)
        return first[2] > second[2]
    end)
    local file = io.open(path, "a")
    if file then
        file:write(string.format("== %s, %d samples\n", os.date("%H:%M:%S"), total))
        for index = 1, math.min(LISTED, #list) do
            file:write(string.format("%5.1f%%  %s\n", list[index][2] * 100 / math.max(total, 1), list[index][1]))
        end
        file:close()
    end
    counts, total, since = {}, 0, os.clock()
end

return hostprofile
