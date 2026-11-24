-- C_EncodingUtil, as the client does it: base64 (RFC 4648, the standard and the URL-safe alphabet), hex, CBOR
-- (RFC 8949, the subset the client writes and reads), and deflate, zlib and gzip (deflate itself by LibDeflate).
--
-- CBOR as the client has it: nil is null; booleans; a whole number in the shortest integer form, any other number
-- in the narrowest float that holds it exactly (half, single, double); a string is a byte string; a table whose keys
-- are all positive whole numbers is an array when at least half its slots up to the largest key are filled (a gap
-- is null), any other table a map. Reading takes definite lengths only, no tags; null and undefined read as nil.
-- With ignoreSerializationErrors a value CBOR cannot hold (a function, a frame) becomes undefined instead of an
-- error. Written for AddonSim from the RFCs and the client's documented behaviour.
local ffi = require("ffi")
local bit = require("bit")
local LibDeflate = require("vendor.LibDeflate")

local encoding = {}

local byte, char, concat, floor = string.byte, string.char, table.concat, math.floor
local band, lshift, rshift = bit.band, bit.lshift, bit.rshift

local LIMIT = 104857600 -- EncodingDecompressSizeLimit and EncodingDeserializeSizeLimit (100 MB)
local STACK_LIMIT = 100 -- EncodingStackSizeLimit: how deep tables nest

---------------------------------------------------------------------------------------------------------------
-- Base64

local ALPHABETS = {
    [0] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    [1] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
}
local encodeTables, decodeTables = {}, {}
for variant, alphabet in pairs(ALPHABETS) do
    local encodeTable, decodeTable = {}, {}
    for code = 0, 255 do
        decodeTable[code] = -1
    end
    for index = 1, 64 do
        local code = byte(alphabet, index)
        encodeTable[index - 1] = char(code)
        decodeTable[code] = index - 1
    end
    encodeTables[variant], decodeTables[variant] = encodeTable, decodeTable
end

local function getVariant(variant, functionName)
    variant = variant == nil and 0 or variant
    if not ALPHABETS[variant] then
        error(functionName .. ": invalid Base64Variant " .. tostring(variant), 3)
    end
    return variant
end

---@param source string
---@param variant number? Enum.Base64Variant: 0 standard, 1 URL-safe
function encoding.encodeBase64(source, variant)
    if type(source) ~= "string" then
        error("C_EncodingUtil.EncodeBase64: expected a string", 2)
    end
    local alphabet = encodeTables[getVariant(variant, "C_EncodingUtil.EncodeBase64")]
    local length = #source
    local parts, count = {}, 0
    for index = 1, length - 2, 3 do
        local a, b, c = byte(source, index, index + 2)
        local value = a * 65536 + b * 256 + c
        count = count + 1
        parts[count] = alphabet[floor(value / 262144)]
            .. alphabet[floor(value / 4096) % 64]
            .. alphabet[floor(value / 64) % 64]
            .. alphabet[value % 64]
    end
    local rest = length % 3
    if rest == 1 then
        local value = byte(source, length) * 65536
        parts[count + 1] = alphabet[floor(value / 262144)] .. alphabet[floor(value / 4096) % 64] .. "=="
    elseif rest == 2 then
        local a, b = byte(source, length - 1, length)
        local value = a * 65536 + b * 256
        parts[count + 1] = alphabet[floor(value / 262144)]
            .. alphabet[floor(value / 4096) % 64]
            .. alphabet[floor(value / 64) % 64]
            .. "="
    end
    return concat(parts)
end

---Decodes into a byte buffer, four characters at a time (the client decodes in C: an addon may decode megabytes at
---login, a database baked into its files).
---@param source string
---@param variant number? Enum.Base64Variant
function encoding.decodeBase64(source, variant)
    if type(source) ~= "string" then
        error("C_EncodingUtil.DecodeBase64: expected a string", 2)
    end
    local values = decodeTables[getVariant(variant, "C_EncodingUtil.DecodeBase64")]
    local length = #source
    if length == 0 then
        return ""
    end
    if length % 4 ~= 0 then
        error("C_EncodingUtil.DecodeBase64: invalid length", 2)
    end
    local padding = 0
    if byte(source, length) == 61 then
        padding = byte(source, length - 1) == 61 and 2 or 1
    end
    local size = length / 4 * 3
    local buffer = ffi.new("uint8_t[?]", size)
    local at = 0
    for index = 1, length, 4 do
        local a, b, c, d = byte(source, index, index + 3)
        local va, vb, vc, vd = values[a], values[b], values[c], values[d]
        if index + 3 == length and padding > 0 then
            vd = 0
            if padding == 2 then
                vc = 0
            end
        end
        if va < 0 or vb < 0 or vc < 0 or vd < 0 then
            error("C_EncodingUtil.DecodeBase64: invalid encoding", 2)
        end
        local value = lshift(va, 18) + lshift(vb, 12) + lshift(vc, 6) + vd
        buffer[at] = rshift(value, 16)
        buffer[at + 1] = band(rshift(value, 8), 255)
        buffer[at + 2] = band(value, 255)
        at = at + 3
    end
    return ffi.string(buffer, size - padding)
end

---------------------------------------------------------------------------------------------------------------
-- Hex

local HEX = "0123456789abcdef"
function encoding.encodeHex(source)
    if type(source) ~= "string" then
        error("C_EncodingUtil.EncodeHex: expected a string", 2)
    end
    return (
        source:gsub(".", function(character)
            local code = byte(character)
            local high, low = floor(code / 16) + 1, code % 16 + 1
            return HEX:sub(high, high) .. HEX:sub(low, low)
        end)
    )
end

function encoding.decodeHex(source)
    if type(source) ~= "string" then
        error("C_EncodingUtil.DecodeHex: expected a string", 2)
    end
    if #source % 2 ~= 0 or source:find("[^%x]") then
        error("C_EncodingUtil.DecodeHex: invalid hex string", 2)
    end
    return (source:gsub("%x%x", function(pair)
        return char(tonumber(pair, 16))
    end))
end

---------------------------------------------------------------------------------------------------------------
-- CBOR

ffi.cdef([[
typedef union { double value; uint8_t bytes[8]; } AddonSimDouble;
typedef union { float value; uint8_t bytes[4]; } AddonSimSingle;
]])
local doubleBox, singleBox = ffi.new("AddonSimDouble"), ffi.new("AddonSimSingle")
local isLittleEndian = ffi.abi("le")

---@return string bytes The value's bytes, most significant first, as CBOR writes them
local function bigEndian(box, size)
    local out = {}
    for index = 0, size - 1 do
        out[index + 1] = isLittleEndian and box.bytes[size - 1 - index] or box.bytes[index]
    end
    return char(unpack(out))
end

-- Floats read by plain arithmetic on their bytes (an FFI union filled byte by byte is slow in LuaJIT's interpreter,
-- and a database baked into an addon's files holds many thousands of them)
local ldexp = math.ldexp

local function readDouble(source, position)
    local a, b, c, d, e, f, g, h = byte(source, position, position + 7)
    local sign = a >= 128 and -1 or 1
    local exponent = (a % 128) * 16 + floor(b / 16)
    local mantissa = ((((((b % 16) * 256 + c) * 256 + d) * 256 + e) * 256 + f) * 256 + g) * 256 + h
    if exponent == 0 then
        return sign * ldexp(mantissa, -1074)
    end
    if exponent == 2047 then
        return mantissa == 0 and sign * math.huge or 0 / 0
    end
    return sign * ldexp(mantissa + 4503599627370496, exponent - 1075)
end

local function readSingle(source, position)
    local a, b, c, d = byte(source, position, position + 3)
    local sign = a >= 128 and -1 or 1
    local exponent = (a % 128) * 2 + floor(b / 128)
    local mantissa = ((b % 128) * 256 + c) * 256 + d
    if exponent == 0 then
        return sign * ldexp(mantissa, -149)
    end
    if exponent == 255 then
        return mantissa == 0 and sign * math.huge or 0 / 0
    end
    return sign * ldexp(mantissa + 8388608, exponent - 150)
end

---A head: the major type and its argument, in the shortest form.
local function head(major, value)
    local base = major * 32
    if value < 24 then
        return char(base + value)
    end
    if value < 256 then
        return char(base + 24, value)
    end
    if value < 65536 then
        return char(base + 25, floor(value / 256), value % 256)
    end
    if value < 4294967296 then
        return char(
            base + 26,
            floor(value / 16777216) % 256,
            floor(value / 65536) % 256,
            floor(value / 256) % 256,
            value % 256
        )
    end
    local high, low = floor(value / 4294967296), value % 4294967296
    return char(
        base + 27,
        floor(high / 16777216) % 256,
        floor(high / 65536) % 256,
        floor(high / 256) % 256,
        high % 256,
        floor(low / 16777216) % 256,
        floor(low / 65536) % 256,
        floor(low / 256) % 256,
        low % 256
    )
end

---@return number? bits The value as a half float's bits, when a half holds it exactly
local function toHalf(value)
    if value ~= value then
        return 0x7E00
    end
    local sign = (value < 0 or (value == 0 and 1 / value < 0)) and 0x8000 or 0
    local magnitude = math.abs(value)
    if magnitude == math.huge then
        return sign + 0x7C00
    end
    if magnitude == 0 then
        return sign
    end
    local mantissa, exponent = math.frexp(magnitude) -- magnitude = mantissa * 2^exponent, mantissa in [0.5, 1)
    local halfExponent = exponent + 14 -- the half's biased exponent (bias 15) for 1.xxx * 2^(exponent - 1)
    if halfExponent >= 31 then
        return nil
    end
    if halfExponent >= 1 then
        local fraction = (mantissa * 2 - 1) * 1024
        if fraction ~= floor(fraction) then
            return nil
        end
        return sign + halfExponent * 1024 + fraction
    end
    local subnormal = magnitude * 16777216 -- magnitude / 2^-24
    if subnormal ~= floor(subnormal) or subnormal >= 1024 then
        return nil
    end
    return sign + subnormal
end

local function encodeNumber(value)
    if value == floor(value) and value >= -9007199254740992 and value <= 9007199254740992 then -- (exact in a double: up to 2^53)
        if value >= 0 then
            return head(0, value)
        end
        return head(1, -1 - value)
    end
    local half = toHalf(value)
    if half then
        return char(0xF9, floor(half / 256), half % 256)
    end
    singleBox.value = value
    if singleBox.value == value or value ~= value then
        return char(0xFA) .. bigEndian(singleBox, 4)
    end
    doubleBox.value = value
    return char(0xFB) .. bigEndian(doubleBox, 8)
end

local encodeValue

---@return number? size The table as an array: its length (gaps up to it as null); nil when it is a map
local function getArraySize(value)
    local largest, count = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= floor(key) then
            return nil
        end
        count = count + 1
        if key > largest then
            largest = key
        end
    end
    if count * 2 < largest then
        return nil
    end
    return largest
end

local function encodeTable(value, state, depth)
    if depth > STACK_LIMIT then
        error("C_EncodingUtil.SerializeCBOR: tables nest too deep", 0)
    end
    if state.open[value] then
        error("C_EncodingUtil.SerializeCBOR: a table contains itself", 0)
    end
    state.open[value] = true
    local parts
    local size = getArraySize(value)
    if size then
        parts = { head(4, size) }
        for index = 1, size do
            local item = value[index]
            parts[index + 1] = item == nil and char(0xF6) or encodeValue(item, state, depth + 1)
        end
    else
        local count = 0
        parts = { "" }
        for key, item in pairs(value) do
            count = count + 1
            parts[#parts + 1] = encodeValue(key, state, depth + 1)
            parts[#parts + 1] = encodeValue(item, state, depth + 1)
        end
        parts[1] = head(5, count)
    end
    state.open[value] = nil
    return concat(parts)
end

encodeValue = function(value, state, depth)
    local kind = type(value)
    if kind == "nil" then
        return char(0xF6)
    end
    if kind == "boolean" then
        return char(value and 0xF5 or 0xF4)
    end
    if kind == "number" then
        return encodeNumber(value)
    end
    if kind == "string" then
        return head(2, #value) .. value
    end
    if kind == "table" and not (type(rawget(value, 0)) == "userdata") then
        return encodeTable(value, state, depth)
    end
    if state.isLenient then
        return char(0xF7)
    end
    error("C_EncodingUtil.SerializeCBOR: cannot serialize a " .. kind, 0)
end

---@param value any
---@param options { ignoreSerializationErrors: boolean? }?
function encoding.serializeCBOR(value, options)
    local state = { open = {}, isLenient = type(options) == "table" and options.ignoreSerializationErrors == true }
    local isDone, result = pcall(encodeValue, value, state, 0)
    if not isDone then
        error(result, 2)
    end
    return result
end

local decodeValue

local function readArgument(source, position, info)
    if info < 24 then
        return info, position
    end
    if info == 24 then
        return byte(source, position), position + 1
    end
    if info == 25 then
        local a, b = byte(source, position, position + 1)
        return a * 256 + b, position + 2
    end
    if info == 26 then
        local a, b, c, d = byte(source, position, position + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d, position + 4
    end
    if info == 27 then
        local value = 0
        for index = 0, 7 do
            value = value * 256 + byte(source, position + index)
        end
        return value, position + 8
    end
    error("C_EncodingUtil.DeserializeCBOR: indefinite lengths are not supported", 0)
end

local function fromHalf(bits)
    local sign = bits >= 0x8000 and -1 or 1
    local exponent, fraction = floor(bits / 1024) % 32, bits % 1024
    if exponent == 0 then
        return sign * fraction * 2 ^ -24
    end
    if exponent == 31 then
        return fraction == 0 and sign * math.huge or 0 / 0
    end
    return sign * (1 + fraction / 1024) * 2 ^ (exponent - 15)
end

decodeValue = function(source, position, depth)
    if depth > STACK_LIMIT then
        error("C_EncodingUtil.DeserializeCBOR: items nest too deep", 0)
    end
    local initial = byte(source, position)
    if not initial then
        error("C_EncodingUtil.DeserializeCBOR: unexpected end of data", 0)
    end
    position = position + 1
    local major, info = floor(initial / 32), initial % 32
    if major == 7 then
        if info == 20 then
            return false, position
        end
        if info == 21 then
            return true, position
        end
        if info == 22 or info == 23 then
            return nil, position
        end
        if info == 25 then
            local a, b = byte(source, position, position + 1)
            return fromHalf(a * 256 + b), position + 2
        end
        if info == 26 then
            return readSingle(source, position), position + 4
        end
        if info == 27 then
            return readDouble(source, position), position + 8
        end
        error("C_EncodingUtil.DeserializeCBOR: unsupported simple value " .. info, 0)
    end
    if major == 6 then
        error("C_EncodingUtil.DeserializeCBOR: tags are not supported", 0)
    end
    local argument
    argument, position = readArgument(source, position, info)
    if major == 0 then
        return argument, position
    end
    if major == 1 then
        return -1 - argument, position
    end
    if major == 2 or major == 3 then
        local finish = position + argument - 1
        if finish > #source then
            error("C_EncodingUtil.DeserializeCBOR: unexpected end of data", 0)
        end
        return source:sub(position, finish), finish + 1
    end
    local result = {}
    if major == 4 then
        for index = 1, argument do
            result[index], position = decodeValue(source, position, depth + 1)
        end
        return result, position
    end
    -- major 5: a map
    for _ = 1, argument do
        local key, item
        key, position = decodeValue(source, position, depth + 1)
        item, position = decodeValue(source, position, depth + 1)
        if key ~= nil and key == key then
            result[key] = item
        end
    end
    return result, position
end

---@param source string
function encoding.deserializeCBOR(source)
    if type(source) ~= "string" then
        error("C_EncodingUtil.DeserializeCBOR: expected a string", 2)
    end
    if #source > LIMIT then
        error("C_EncodingUtil.DeserializeCBOR: data over the size limit", 2)
    end
    if #source == 0 then
        return nil
    end
    local isDone, value, position = pcall(decodeValue, source, 1, 0)
    if not isDone then
        error(value, 2)
    end
    if position <= #source then
        error("C_EncodingUtil.DeserializeCBOR: data left over after the item", 2)
    end
    return value
end

---------------------------------------------------------------------------------------------------------------
-- Compression: Enum.CompressionMethod 0 deflate, 1 zlib, 2 gzip; Enum.CompressionLevel 0 default, 1 speed, 2 size

local LEVELS = { [0] = 6, [1] = 1, [2] = 9 }

local crcTable
local function crc32(data)
    if not crcTable then
        crcTable = {}
        for index = 0, 255 do
            local value = index
            for _ = 1, 8 do
                if band(value, 1) == 1 then
                    value = bit.bxor(rshift(value, 1), 0xEDB88320)
                else
                    value = rshift(value, 1)
                end
            end
            crcTable[index] = value
        end
    end
    local crc = 0xFFFFFFFF
    for index = 1, #data do
        crc = bit.bxor(crcTable[band(bit.bxor(crc, byte(data, index)), 255)], rshift(crc, 8))
    end
    crc = bit.bnot(crc)
    return crc < 0 and crc + 4294967296 or crc
end

local function littleEndian32(value)
    return char(value % 256, floor(value / 256) % 256, floor(value / 65536) % 256, floor(value / 16777216) % 256)
end

function encoding.compressString(source, method, level)
    if type(source) ~= "string" then
        error("C_EncodingUtil.CompressString: expected a string", 2)
    end
    local configs = { level = LEVELS[level or 0] or 6 }
    method = method or 0
    if method == 1 then
        return LibDeflate:CompressZlib(source, configs)
    end
    local deflated = LibDeflate:CompressDeflate(source, configs)
    if method == 2 then
        -- RFC 1952: the header (deflate, no name, no time, unknown system), the data, its CRC-32 and size
        return char(0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF)
            .. deflated
            .. littleEndian32(crc32(source))
            .. littleEndian32(#source % 4294967296)
    end
    return deflated
end

---@return string data A gzip member's deflated data (the header and its optional fields passed over)
local function gzipBody(source)
    local id1, id2, method, flags = byte(source, 1, 4)
    if id1 ~= 0x1F or id2 ~= 0x8B or method ~= 8 then
        return nil
    end
    local position = 11
    if band(flags, 4) ~= 0 then -- FEXTRA
        local low, high = byte(source, position, position + 1)
        position = position + 2 + low + high * 256
    end
    if band(flags, 8) ~= 0 then
        position = source:find("\0", position, true) + 1
    end -- FNAME
    if band(flags, 16) ~= 0 then
        position = source:find("\0", position, true) + 1
    end -- FCOMMENT
    if band(flags, 2) ~= 0 then
        position = position + 2
    end -- FHCRC
    return source:sub(position, #source - 8)
end

function encoding.decompressString(source, method)
    if type(source) ~= "string" then
        error("C_EncodingUtil.DecompressString: expected a string", 2)
    end
    local output
    method = method or 0
    if method == 1 then
        output = LibDeflate:DecompressZlib(source)
    elseif method == 2 then
        local body = gzipBody(source)
        output = body and LibDeflate:DecompressDeflate(body)
    else
        output = LibDeflate:DecompressDeflate(source)
    end
    if output == nil then
        error("C_EncodingUtil.DecompressString: invalid compressed data", 2)
    end
    if #output > LIMIT then
        error("C_EncodingUtil.DecompressString: data over the size limit", 2)
    end
    return output
end

return encoding
