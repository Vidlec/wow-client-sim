-- The simulator's process at full speed on Windows. A process with no window that waits on a pipe between requests,
-- as this one does between frames, is taken for background work: Windows 11 throttles it (EcoQoS: lower clocks, the
-- efficiency cores of a hybrid processor), and a frame measured at 7 ms in a scenario took 12 to 14 in the server.
-- Asking out of power throttling (SetProcessInformation, ProcessPowerThrottling) keeps it on full speed. Elsewhere,
-- or if the call is not there, nothing changes.
local fullspeed = {}

function fullspeed.apply()
    local isLoaded, ffi = pcall(require, "ffi")
    if not isLoaded or ffi.os ~= "Windows" then
        return false
    end
    local isDeclared = pcall(
        ffi.cdef,
        [[
        typedef struct { unsigned long Version; unsigned long ControlMask; unsigned long StateMask; }
            ADDONSIM_PROCESS_POWER_THROTTLING_STATE;
        void* GetCurrentProcess(void);
        int SetProcessInformation(void* process, int informationClass, void* information, unsigned long size);
        ]]
    )
    if not isDeclared then
        return false
    end
    local PROCESS_POWER_THROTTLING = 4 -- (ProcessPowerThrottling)
    local CURRENT_VERSION = 1
    local EXECUTION_SPEED = 0x1
    local IGNORE_TIMER_RESOLUTION = 0x4
    local state = ffi.new("ADDONSIM_PROCESS_POWER_THROTTLING_STATE")
    state.Version = CURRENT_VERSION
    -- (control the throttling of execution speed and of timer resolution; state 0: neither throttled)
    state.ControlMask = EXECUTION_SPEED + IGNORE_TIMER_RESOLUTION
    state.StateMask = 0
    local isDone, result = pcall(function()
        return ffi.C.SetProcessInformation(
            ffi.C.GetCurrentProcess(),
            PROCESS_POWER_THROTTLING,
            state,
            ffi.sizeof(state)
        )
    end)
    -- (its priority left as it is: raised above normal, LuaJIT's profiler, whose sampling thread runs at normal
    -- priority, could no longer get a sample in and the process hung)
    return isDone and result ~= 0
end

return fullspeed
