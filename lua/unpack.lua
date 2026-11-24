-- The native store's binary frames read back in Lua (native/src/store.rs's format, lua/pack.lua's values): for
-- ADDONSIM_CHECK_SCENE=1, which compares the scene the native walk made with the one lua/scene.lua exports.
local ffi = require("ffi")
local pack = require("pack")

local unpack = {}

local function reader(bytes)
    local data = ffi.cast("const uint8_t*", bytes)
    local at = 0
    local r = {}
    function r.u8()
        local value = data[at]
        at = at + 1
        return value
    end
    function r.u16()
        local value = ffi.cast("const uint16_t*", data + at)[0]
        at = at + 2
        return value
    end
    function r.u32()
        local value = ffi.cast("const uint32_t*", data + at)[0]
        at = at + 4
        return tonumber(value)
    end
    function r.i32()
        local value = ffi.cast("const int32_t*", data + at)[0]
        at = at + 4
        return tonumber(value)
    end
    function r.f64()
        local value = ffi.cast("const double*", data + at)[0]
        at = at + 8
        return tonumber(value)
    end
    function r.text(length)
        local value = ffi.string(data + at, length)
        at = at + length
        return value
    end
    function r.box()
        return { r.f64(), r.f64(), r.f64(), r.f64() }
    end
    function r.seek(position)
        at = position
    end
    function r.position()
        return at
    end
    return r
end

local function readValue(r)
    local tag = r.u8()
    if tag == 0 then
        return nil
    elseif tag == 1 then
        return false
    elseif tag == 2 then
        return true
    elseif tag == 3 then
        return r.i32()
    elseif tag == 4 then
        return r.f64()
    elseif tag == 5 then
        return r.text(r.u32())
    elseif tag == 6 then
        local list = {}
        for index = 1, r.u32() do
            list[index] = readValue(r)
        end
        return list
    elseif tag == 7 then
        local map = {}
        for _ = 1, r.u32() do
            local keyTag = r.u8()
            local key = keyTag == 8 and pack.FIELDS[r.u8() + 1] or r.text(r.u32())
            map[key] = readValue(r)
        end
        return map
    end
    error("a packed value of unknown kind " .. tostring(tag))
end

---A whole scene's binary frame read into the items, in order, with the moved ones' boxes on them
function unpack.whole(bytes)
    local r = reader(bytes)
    r.u8() -- (2: whole)
    local keys = {}
    for _ = 1, r.u32() do
        local id = r.u32()
        keys[id] = r.text(r.u16())
    end
    local order = {}
    if r.u8() == 1 then
        for index = 1, r.u32() do
            order[index] = r.u32()
        end
    end
    local itemOf = {}
    for _ = 1, r.u32() do
        local id = r.u32()
        local length = r.u32()
        local finish = length + r.position()
        if length > 0 then
            itemOf[id] = readValue(r)
        end
        r.seek(finish)
    end
    for _ = 1, r.u32() do
        local item = itemOf[r.u32()]
        local own = r.box()
        local clip = r.u8() == 1 and r.box() or nil
        local masks = {}
        for index = 1, r.u8() do
            masks[index] = r.box()
        end
        if item then
            item.x, item.y, item.w, item.h = own[1], own[2], own[3], own[4]
            item.cl = clip
            for index, mask in ipairs(item.mk or {}) do
                mask.b = masks[index] or mask.b
            end
        end
    end
    local items = {}
    for index, id in ipairs(order) do
        items[index] = itemOf[id] or { missing = keys[id] }
    end
    return items
end

return unpack
