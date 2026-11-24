-- The garbage collector in the time between frames. A frame of the scene makes some hundred kilobytes of short-lived
-- tables (more while a window is dragged: every item of it moved), and with the addons' data the heap holds hundreds
-- of megabytes the collector has to go through each cycle. Left to itself it does that work inside the frames, a step
-- with each allocation, and a dragged window fell to 40 frames a second. Here its work is done after a frame's answer
-- is out, while the server has not asked for the next one yet, a little at a time; between those moments it is
-- stopped. Any other request (a scenario, a reload, the console) has it as usual again, and so do frames when the
-- garbage grows faster than the idle time clears it.
local idlegc = {}

local BUDGET_MS = 2 -- the collector's time after a frame
local GROWTH = 1.5 -- a cycle starts once the heap has grown this much over what the last cycle kept
local OVERFLOW = 2.5 -- past this, the idle time does not keep up: the collector as usual until its cycle ends

local isManaged = false -- stopped between frames, stepped after them
local isBehind = false -- the collector as usual (OVERFLOW), until the cycle it is in ends
local isInCycle = false
local kept = nil -- the heap (KB) after the last cycle ended
local spentMs = 0 -- the collector's time between frames since last asked (handlers.perf)

---After a frame's (or a tick's) answer is out: the collector's work for a moment, then stopped till the next frame
---@param clock fun(): number milliseconds
function idlegc.afterFrame(clock)
    local heap = collectgarbage("count")
    kept = kept or heap
    isManaged = true
    if not isBehind and heap > kept * OVERFLOW then
        isBehind = true
        isInCycle = true
    end
    if isInCycle or heap > kept * GROWTH then
        isInCycle = true
        local begun = clock()
        local deadline = begun + BUDGET_MS
        repeat
            if collectgarbage("step", 0) then
                -- (a cycle ended: what it kept is the measure for the next)
                isInCycle, isBehind = false, false
                kept = collectgarbage("count")
                break
            end
        until clock() >= deadline
        spentMs = spentMs + (clock() - begun)
    end
    if isBehind then
        collectgarbage("restart", -1)
    else
        collectgarbage("stop")
    end
end

---The collector's time between frames since last asked, in milliseconds
function idlegc.takeSpentMs()
    local spent = spentMs
    spentMs = 0
    return spent
end

---Before any other request: the collector as usual (its next cycle when the heap has grown by its pause)
function idlegc.release()
    if isManaged then
        isManaged = false
        collectgarbage("restart", -1)
    end
end

return idlegc
