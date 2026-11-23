-- JSON for the pipe between the Lua host and the server: compact encode, strict-enough decode.
local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- Bytes that are not valid UTF-8 (binary addon messages, such as Questie's) become \u00XX, so the line stays
-- valid JSON whatever an addon sends
local function makeValidUtf8(text)
    if not text:find("[\128-\255]") then return text end
    local parts, position, length = {}, 1, #text
    while position <= length do
        local byte = text:byte(position)
        local size = byte < 0x80 and 1 or (byte >= 0xC2 and byte <= 0xDF) and 2 or (byte >= 0xE0 and byte <= 0xEF) and 3
            or (byte >= 0xF0 and byte <= 0xF4) and 4 or 0
        local isValid = size > 0 and position + size - 1 <= length
        for offset = 1, size - 1 do
            local continuation = isValid and text:byte(position + offset)
            if not continuation or continuation < 0x80 or continuation > 0xBF then isValid = false end
        end
        if isValid then
            parts[#parts + 1] = text:sub(position, position + size - 1)
            position = position + size
        else
            parts[#parts + 1] = string.format("\\u%04x", byte)
            position = position + 1
        end
    end
    return table.concat(parts)
end

local find, format, match = string.find, string.format, string.match
local escapedKeys = {} -- the keys of the scene's items ("x", "atlas"...): the same few, escaped once

local function escapeString(text)
    -- Most text needs nothing escaped: quoted as it is
    if not find(text, '[%c"\\\128-\255]') then return '"' .. text .. '"' end
    -- Quotes, backslashes and control characters first; then the invalid bytes, whose escapes must stay as they are
    local escaped = text:gsub('[%c"\\]', function(character)
        return escapes[character] or string.format("\\u%04x", character:byte())
    end)
    return '"' .. makeValidUtf8(escaped) .. '"'
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end
    return true, count
end

local encodeValue
local function encodeTable(value, parts, seen)
    if seen[value] then
        parts[#parts + 1] = "null"
        return
    end
    seen[value] = true
    local array, count = isArray(value)
    if array and (count > 0 or next(value) == nil) then
        parts[#parts + 1] = "["
        for index = 1, count do
            if index > 1 then
                parts[#parts + 1] = ","
            end
            encodeValue(value[index], parts, seen)
        end
        parts[#parts + 1] = "]"
    else
        parts[#parts + 1] = "{"
        local isFirst = true
        for key, item in pairs(value) do
            local keyType = type(key)
            if (keyType == "string" or keyType == "number") and type(item) ~= "function" and type(item) ~= "userdata" then
                if not isFirst then
                    parts[#parts + 1] = ","
                end
                isFirst = false
                local escapedKey = escapedKeys[key]
                if not escapedKey then
                    escapedKey = escapeString(tostring(key))
                    if keyType == "string" and #key < 40 then escapedKeys[key] = escapedKey end
                end
                parts[#parts + 1] = escapedKey
                parts[#parts + 1] = ":"
                encodeValue(item, parts, seen)
            end
        end
        parts[#parts + 1] = "}"
    end
    seen[value] = nil
end

encodeValue = function(value, parts, seen)
    local valueType = type(value)
    if valueType == "nil" then
        parts[#parts + 1] = "null"
    elseif valueType == "boolean" then
        parts[#parts + 1] = value and "true" or "false"
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            parts[#parts + 1] = "null"
        elseif value % 1 == 0 and value < 1e14 and value > -1e14 then
            -- (a whole number this size prints exactly as it is: no format, which the game's string library wraps)
            parts[#parts + 1] = tostring(value)
        elseif value % 1 == 0 and math.abs(value) < 1e15 then
            parts[#parts + 1] = string.format("%d", value)
        else
            -- Four places, the zeros after the point dropped: rounded as a number and printed as one (%.14g, exact at
            -- this size), not formatted through the game's wrapped string.format and trimmed by a pattern
            local rounded = math.floor(value * 10000 + 0.5) / 10000
            if rounded < 1e14 and rounded > -1e14 then
                parts[#parts + 1] = tostring(rounded)
            else
                parts[#parts + 1] = match(format("%.4f", value), "^(.-)%.?0*$")
            end
        end
    elseif valueType == "string" then
        parts[#parts + 1] = escapeString(value)
    elseif valueType == "table" then
        encodeTable(value, parts, seen)
    else
        parts[#parts + 1] = escapeString(tostring(value))
    end
end

function json.encode(value)
    local parts = {}
    encodeValue(value, parts, {})
    return table.concat(parts)
end

---The value's JSON added to a list of parts, to be joined with others once (the scene stream writes many so)
function json.encodeInto(value, parts)
    encodeValue(value, parts, {})
end

-- Decoding
local function decodeError(text, position, message)
    error(string.format("json: %s at %d near %q", message, position, text:sub(position, position + 20)), 0)
end

local decodeAt
local function skipSpace(text, position)
    return text:find("[^ \t\r\n]", position) or #text + 1
end

local function decodeString(text, position)
    local parts, index = {}, position + 1
    while true do
        local character = text:sub(index, index)
        if character == "" then
            decodeError(text, index, "unfinished string")
        elseif character == '"' then
            return table.concat(parts), index + 1
        elseif character == "\\" then
            local nextCharacter = text:sub(index + 1, index + 1)
            if nextCharacter == "u" then
                local code = tonumber(text:sub(index + 2, index + 5), 16) or 63
                if code >= 0xD800 and code <= 0xDBFF and text:sub(index + 6, index + 7) == "\\u" then
                    local low = tonumber(text:sub(index + 8, index + 11), 16) or 0xDC00
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    index = index + 6
                end
                if code < 0x80 then
                    parts[#parts + 1] = string.char(code)
                elseif code < 0x800 then
                    parts[#parts + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                elseif code < 0x10000 then
                    parts[#parts + 1] = string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                else
                    parts[#parts + 1] = string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
                        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                end
                index = index + 6
            else
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                parts[#parts + 1] = map[nextCharacter] or nextCharacter
                index = index + 2
            end
        else
            local stop = text:find('["\\]', index) or #text + 1
            parts[#parts + 1] = text:sub(index, stop - 1)
            index = stop
        end
    end
end

decodeAt = function(text, position)
    position = skipSpace(text, position)
    local character = text:sub(position, position)
    if character == "{" then
        local result = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == "}" then
            return result, position + 1
        end
        while true do
            local key
            key, position = decodeString(text, skipSpace(text, position))
            position = skipSpace(text, position)
            if text:sub(position, position) ~= ":" then
                decodeError(text, position, "expected ':'")
            end
            result[key], position = decodeAt(text, position + 1)
            position = skipSpace(text, position)
            local separator = text:sub(position, position)
            if separator == "}" then
                return result, position + 1
            elseif separator ~= "," then
                decodeError(text, position, "expected ',' or '}'")
            end
            position = position + 1
        end
    elseif character == "[" then
        local result = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == "]" then
            return result, position + 1
        end
        while true do
            result[#result + 1], position = decodeAt(text, position)
            position = skipSpace(text, position)
            local separator = text:sub(position, position)
            if separator == "]" then
                return result, position + 1
            elseif separator ~= "," then
                decodeError(text, position, "expected ',' or ']'")
            end
            position = position + 1
        end
    elseif character == '"' then
        return decodeString(text, position)
    elseif text:sub(position, position + 3) == "true" then
        return true, position + 4
    elseif text:sub(position, position + 4) == "false" then
        return false, position + 5
    elseif text:sub(position, position + 3) == "null" then
        return nil, position + 4
    end
    local numberText = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", position)
    if not numberText or numberText == "" then
        decodeError(text, position, "unexpected character")
    end
    return tonumber(numberText), position + #numberText
end

function json.decode(text)
    local value = decodeAt(text, 1)
    return value
end

return json
