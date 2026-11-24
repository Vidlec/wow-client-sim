-- A scene item packed into bytes for the native store and the page (lua/native.lua, src/ui/engine/binaryFrame.ts):
-- the same values the JSON stream sends, without making text. Written into one buffer kept between items (LuaJIT's FFI),
-- so packing makes no garbage.
--
-- A value: a tag byte, then
--   0 nil, 1 false, 2 true
--   3 a whole number (i32), 4 any other number (f64, rounded to four places as the JSON stream rounds it)
--   5 a string (u32 length, its bytes)
--   6 an array (u32 count, the values)
--   7 a map (u32 count, then each key and value; a key is 8 and a byte, a known name's number (FIELDS), or 5 and the
--     name's string)
-- An array is a table whose keys run 1..n without a hole, as the JSON stream decides; any other table is a map, a
-- number key written as its text.
local ffi = require("ffi")

local pack = {}

-- The names every item's fields come from, numbered from 0 in this order (src/ui/engine/binaryFrame.ts has the same
-- list: a name added here is added there)
pack.FIELDS = {
    "k",
    "i",
    "x",
    "y",
    "w",
    "h",
    "a",
    "c",
    "vc",
    "tc",
    "tcTurned",
    "tex",
    "atlas",
    "sc",
    "sl",
    "slm",
    "wr",
    "bl",
    "ds",
    "rot",
    "gr",
    "tile",
    "mk",
    "b",
    "poly",
    "pie",
    "seam",
    "cl",
    "fg",
    "fa",
    "lines",
    "f",
    "fs",
    "fl",
    "jh",
    "jv",
    "lh",
    "sp",
    "sh",
    "shc",
    "ag",
    "cursor",
    "bg",
    "edge",
    "es",
    "ins",
    "ts",
    "bc",
    "x1",
    "y1",
    "x2",
    "y2",
    "th",
    "unit",
    "orientation",
    "from",
    "to",
    "left",
    "right",
    "top",
    "bottom",
}
local fieldNumbers = {}
for index, name in ipairs(pack.FIELDS) do
    fieldNumbers[name] = index - 1
end

local capacity = 65536
local buffer = ffi.new("uint8_t[?]", capacity)
local length = 0

local function ensure(more)
    if length + more <= capacity then
        return
    end
    local grown = capacity
    while length + more > grown do
        grown = grown * 2
    end
    local bigger = ffi.new("uint8_t[?]", grown)
    ffi.copy(bigger, buffer, length)
    buffer, capacity = bigger, grown
end

local function putByte(value)
    ensure(1)
    buffer[length] = value
    length = length + 1
end
local function putU32(value)
    ensure(4)
    ffi.cast("uint32_t*", buffer + length)[0] = value
    length = length + 4
end
local function putString(text)
    local size = #text
    ensure(5 + size)
    buffer[length] = 5
    ffi.cast("uint32_t*", buffer + length + 1)[0] = size
    ffi.copy(buffer + length + 5, text, size)
    length = length + 5 + size
end

local function putNumber(value)
    if value ~= value or value == math.huge or value == -math.huge then
        putByte(0)
    elseif value % 1 == 0 and value >= -2147483648 and value <= 2147483647 then
        ensure(5)
        buffer[length] = 3
        ffi.cast("int32_t*", buffer + length + 1)[0] = value
        length = length + 5
    else
        if value % 1 ~= 0 then
            value = math.floor(value * 10000 + 0.5) / 10000
        end
        ensure(9)
        buffer[length] = 4
        ffi.cast("double*", buffer + length + 1)[0] = value
        length = length + 9
    end
end

---Whether a table is an array as the JSON stream decides it (keys 1..n, no hole), and n
local function arrayCount(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return nil
        end
    end
    return count
end

local putValue
local seen = {}
local function putTable(value)
    if seen[value] then
        putByte(0)
        return
    end
    seen[value] = true
    local count = arrayCount(value)
    if count then
        putByte(6)
        putU32(count)
        for index = 1, count do
            putValue(value[index])
        end
    else
        putByte(7)
        local countAt = length
        putU32(0)
        local entries = 0
        for key, item in pairs(value) do
            local keyType, itemType = type(key), type(item)
            if (keyType == "string" or keyType == "number") and itemType ~= "function" and itemType ~= "userdata" then
                local number = keyType == "string" and fieldNumbers[key]
                if number then
                    putByte(8)
                    putByte(number)
                else
                    putString(tostring(key))
                end
                putValue(item)
                entries = entries + 1
            end
        end
        ffi.cast("uint32_t*", buffer + countAt)[0] = entries
    end
    seen[value] = nil
end

putValue = function(value)
    local valueType = type(value)
    if valueType == "nil" then
        putByte(0)
    elseif valueType == "boolean" then
        putByte(value and 2 or 1)
    elseif valueType == "number" then
        putNumber(value)
    elseif valueType == "string" then
        putString(value)
    elseif valueType == "table" then
        putTable(value)
    else
        putString(tostring(value))
    end
end

---An item packed: the buffer and its length, valid until the next item is packed
---@return ffi.cdata* bytes, integer length
function pack.item(item)
    length = 0
    putValue(item)
    return buffer, length
end

return pack
