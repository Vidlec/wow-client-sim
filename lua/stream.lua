-- The scene as a stream for the page: after the first whole scene, each frame sends only the items that changed and,
-- when it changed, the drawing order. The frames are binary, made by the native walk (lua/scenesync.lua) and its item
-- store (lua/native.lua), which keeps what the page holds; this side keeps which version of the simulator the page's
-- items are of, and hands out the whole scene for a page that joins or fell behind (src/ui/engine/binaryFrame.ts).
local ffi = require("ffi")
local native = require("native")

local stream = {}

local sentVersion = nil -- the simulator's version the page's items are of (nil: nothing sent yet)

function stream.getVersion()
    return sentVersion
end
function stream.setVersion(version)
    sentVersion = version
end

local lengthOut = ffi.new("size_t[1]")
---The whole scene the page should hold, as a binary frame (a page that joins or fell behind)
function stream.encodeWholeBinary()
    local bytes = native.load().sc_whole(native.handle(), lengthOut)
    return ffi.string(bytes, tonumber(lengthOut[0]))
end

return stream
