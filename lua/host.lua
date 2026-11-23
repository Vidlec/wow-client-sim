-- The simulator's process: started by the server with a config file, it builds the game, loads the addons,
-- logs in, then answers requests on stdin, one JSON line each, with one JSON line on stdout.
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

local runtime = dofile(root .. "/lua/boot.lua")
local json, sim, handlers, bootSeconds = runtime.json, runtime.sim, runtime.handlers, runtime.bootSeconds

io.stdout:setvbuf("full")
io.stdout:write(json.encode({ ready = true, bootSeconds = bootSeconds, errors = #sim.errors }) .. "\n")
io.stdout:flush()
for line in io.stdin:lines() do
    local isDecoded, request = pcall(json.decode, line)
    local response
    if not isDecoded or type(request) ~= "table" then
        response = { error = "bad request" }
    else
        local handler = handlers[request.op]
        if not handler then
            response = { error = "unknown op " .. tostring(request.op) }
        else
            local isDone, result = xpcall(function() return handler(request) end, debug.traceback)
            response = isDone and result or { error = tostring(result) }
        end
        response.id = request.id
    end
    if type(response.raw) == "string" then
        -- Written as it is (the scene stream's JSON text), with the request's id put in before its closing brace
        io.stdout:write(response.raw:sub(1, -2), ',"id":', tostring(response.id), "}\n")
    else
        io.stdout:write(json.encode(response) .. "\n")
    end
    io.stdout:flush()
end
