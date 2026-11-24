-- The client's additions to Lua's math, string and table libraries, as its documentation describes them
-- (LuaMathExtensions, LuaStringExtensions, LuaTableExtensions). Loaded before the documentation's stand-ins.
local extensions = {}

function extensions.install(G)
    local mathLibrary, stringLibrary, tableLibrary = G.math, G.string, G.table

    -- Halfway values round away from zero
    mathLibrary.round = function(value, decimalPlaces)
        local factor = 10 ^ (decimalPlaces or 0)
        local scaled = value * factor
        local rounded = scaled >= 0 and math.floor(scaled + 0.5) or -math.floor(-scaled + 0.5)
        return rounded / factor
    end
    mathLibrary.clamp = function(value, minimum, maximum)
        return math.min(math.max(value, minimum), maximum)
    end
    mathLibrary.saturate = function(value)
        return math.min(math.max(value, 0), 1)
    end
    mathLibrary.lerp = function(startValue, endValue, amount)
        return startValue + (endValue - startValue) * amount
    end
    mathLibrary.normalize = function(value, minimum, maximum)
        if maximum == minimum then
            return 0
        end
        return (value - minimum) / (maximum - minimum)
    end
    mathLibrary.remap = function(value, sourceMinimum, sourceMaximum, destinationMinimum, destinationMaximum)
        if sourceMaximum == sourceMinimum then
            return destinationMinimum
        end
        return destinationMinimum
            + (value - sourceMinimum) * (destinationMaximum - destinationMinimum) / (sourceMaximum - sourceMinimum)
    end
    mathLibrary.sign = function(value)
        return value > 0 and 1 or value < 0 and -1 or 0
    end
    mathLibrary.wrap = function(value, minimum, maximum)
        local range = maximum - minimum
        if range == 0 then
            return minimum
        end
        return minimum + (value - minimum) % range
    end
    mathLibrary.isnan = function(value)
        return value ~= value
    end
    mathLibrary.isinf = function(value)
        return value == math.huge or value == -math.huge
    end
    mathLibrary.isfinite = function(value)
        return value == value and value ~= math.huge and value ~= -math.huge
    end

    -- Positional arguments in format strings ("%2$s of %1$d"), which the game's Lua takes and localised strings use
    if not stringLibrary.isPositionalFormat then
        local plainFormat = string.format
        local function format(pattern, ...)
            if type(pattern) ~= "string" or not pattern:find("%%%d+%$") then
                return plainFormat(pattern, ...)
            end
            local arguments = { n = select("#", ...), ... }
            local parts, ordered, count, sequence, position, length = {}, {}, 0, 0, 1, #pattern
            while position <= length do
                local percent = pattern:find("%", position, true)
                if not percent then
                    parts[#parts + 1] = pattern:sub(position)
                    break
                end
                parts[#parts + 1] = pattern:sub(position, percent - 1)
                if pattern:sub(percent + 1, percent + 1) == "%" then
                    parts[#parts + 1] = "%%"
                    position = percent + 2
                else
                    local index, spec, finish = pattern:match("^(%d+)%$([-+ #0]*%d*%.?%d*%a)()", percent + 1)
                    if index then
                        index = tonumber(index)
                    else
                        spec, finish = pattern:match("^([-+ #0]*%d*%.?%d*%a)()", percent + 1)
                        sequence = sequence + 1
                        index = sequence
                    end
                    if not spec then
                        return plainFormat(pattern, ...)
                    end
                    parts[#parts + 1] = "%" .. spec
                    count = count + 1
                    ordered[count] = arguments[index]
                    position = finish
                end
            end
            return plainFormat(table.concat(parts), unpack(ordered, 1, count))
        end
        string.format = format
        stringLibrary.format = format
        G.format = format
        stringLibrary.isPositionalFormat = true
    end

    local function characterClass(characters)
        return "[" .. (characters or " \t\r\n"):gsub("[%]%[%^%-%%]", "%%%0") .. "]"
    end
    stringLibrary.ltrim = function(text, characters)
        return (text:gsub("^" .. characterClass(characters) .. "+", ""))
    end
    stringLibrary.rtrim = function(text, characters)
        return (text:gsub(characterClass(characters) .. "+$", ""))
    end
    stringLibrary.trim = function(text, characters)
        return stringLibrary.rtrim(stringLibrary.ltrim(text, characters), characters)
    end
    stringLibrary.contains = function(text, substring)
        return text:find(substring, 1, true) ~= nil
    end
    stringLibrary.startswith = function(text, prefix)
        return text:sub(1, #prefix) == prefix
    end
    stringLibrary.endswith = function(text, suffix)
        return suffix == "" or text:sub(-#suffix) == suffix
    end

    tableLibrary.contains = function(list, value)
        for _, candidate in pairs(list) do
            if candidate == value then
                return true
            end
        end
        return false
    end
    tableLibrary.indexof = function(list, value)
        for index, candidate in ipairs(list) do
            if candidate == value then
                return index
            end
        end
        return nil
    end
    tableLibrary.count = function(list)
        local count = 0
        for _ in pairs(list) do
            count = count + 1
        end
        return count
    end
    tableLibrary.create = function()
        return {}
    end
    tableLibrary.keys = function(list)
        local keys = {}
        for key in pairs(list) do
            keys[#keys + 1] = key
        end
        return keys
    end
    tableLibrary.values = function(list)
        local values = {}
        for _, value in pairs(list) do
            values[#values + 1] = value
        end
        return values
    end
    tableLibrary.isempty = function(list)
        return next(list) == nil
    end
    local frozen = setmetatable({}, { __mode = "k" })
    tableLibrary.freeze = function(list)
        frozen[list] = true
        return list
    end
    tableLibrary.isfrozen = function(list)
        return frozen[list] == true
    end
    tableLibrary.getcountinfo = function(list)
        local arrayCount, hashCount = #list, 0
        for key in pairs(list) do
            if type(key) ~= "number" or key < 1 or key > arrayCount or key % 1 ~= 0 then
                hashCount = hashCount + 1
            end
        end
        return { arrayCount = arrayCount, hashCount = hashCount }
    end
    tableLibrary.removeunordered = function(list, index)
        local last = #list
        local value = list[index]
        list[index] = list[last]
        list[last] = nil
        return value
    end
    tableLibrary.removevalue = function(list, value)
        local removed = 0
        for index = #list, 1, -1 do
            if list[index] == value then
                table.remove(list, index)
                removed = removed + 1
            end
        end
        return removed
    end
end

return extensions
