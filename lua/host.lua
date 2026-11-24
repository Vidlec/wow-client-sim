-- The simulator's process: started by the server with a config file, it builds the game, loads the addons,
-- logs in, then answers requests on stdin, one JSON line each, with one JSON line on stdout.
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

local runtime = dofile(root .. "/lua/boot.lua")
local json, sim, handlers, bootSeconds = runtime.json, runtime.sim, runtime.handlers, runtime.bootSeconds
local idlegc = require("idlegc")
-- (the game's clock: its garbage collected between them, lua/idlegc.lua)
local FRAME_OPS = { frame = true, tick = true }
-- (a sampling profile to a file when ADDONSIM_PROFILE_FILE is set: lua/hostprofile.lua)
local hostprofile = require("hostprofile")
hostprofile.start()
-- (full speed on Windows: not throttled as background work between frames, lua/fullspeed.lua)
require("fullspeed").apply()

-- (binary on Windows: a frame's binary part follows its line as it is, no newline made two bytes)
do
    local ffi = require("ffi")
    if ffi.os == "Windows" then
        pcall(function()
            ffi.cdef("int _setmode(int fd, int mode);")
            ffi.C._setmode(1, 0x8000)
        end)
    end
end
io.stdout:setvbuf("full")
io.stdout:write(json.encode({ ready = true, bootSeconds = bootSeconds, errors = #sim.errors }) .. "\n")
io.stdout:flush()
for line in io.stdin:lines() do
    local isDecoded, request = pcall(json.decode, line)
    local response
    local isFrame = isDecoded and type(request) == "table" and FRAME_OPS[request.op] == true
    if not isFrame then
        idlegc.release()
    end
    if not isDecoded or type(request) ~= "table" then
        response = { error = "bad request" }
    else
        local handler = handlers[request.op]
        if not handler then
            response = { error = "unknown op " .. tostring(request.op) }
        else
            local isDone, result = xpcall(function()
                return handler(request)
            end, debug.traceback)
            response = isDone and result or { error = tostring(result) }
        end
        response.id = request.id
    end
    if type(response.raw) == "string" then
        -- Written as it is (the scene stream's JSON text), with the request's id put in before its closing brace
        local id = response.id == nil and "null" or tostring(response.id)
        io.stdout:write(response.raw:sub(1, -2), ',"id":', id, "}\n")
        -- (a binary part: as many bytes as the line's "bin" says, right after it)
        if response.bin then
            io.stdout:write(response.bin)
        end
    else
        io.stdout:write(json.encode(response) .. "\n")
    end
    io.stdout:flush()
    if isFrame then
        idlegc.afterFrame(sim.clock)
    end
    hostprofile.report()
end
