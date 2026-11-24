-- C_StringUtil's text functions, as the client documents them (Blizzard_APIDocumentationGenerated/
-- StringUtilDocumentation.lua): escaping for patterns, format strings, quoted codes and the error window's
-- non-printables, links stripped to their text, numbers rounded to strings. They stood in giving "" (the error window
-- showed every error without its message; chat and talent tooltips stripped of their links read empty).
local stringutil = {}

local floor, byte, format = math.floor, string.byte, string.format

---Control characters (but newline, carriage return and tab) and bytes that are not UTF-8, as "\ddd"
function stringutil.escapeDecimalNonPrintables(text)
    text = tostring(text or "")
    local out, index, length = {}, 1, #text
    while index <= length do
        local first = byte(text, index)
        local size = first < 0x80 and 1
            or (first >= 0xC2 and first <= 0xDF) and 2
            or (first >= 0xE0 and first <= 0xEF) and 3
            or (first >= 0xF0 and first <= 0xF4) and 4
            or 0
        local isValid = size > 0 and index + size - 1 <= length
        for offset = 1, size - 1 do
            local next = isValid and byte(text, index + offset)
            if not next or next < 0x80 or next > 0xBF then
                isValid = false
            end
        end
        if size == 1 and ((first < 32 and first ~= 10 and first ~= 13 and first ~= 9) or first == 127) then
            isValid = false
        end
        if isValid then
            out[#out + 1] = text:sub(index, index + size - 1)
            index = index + size
        else
            out[#out + 1] = "\\" .. first
            index = index + 1
        end
    end
    return table.concat(out)
end

function stringutil.escapeLuaFormatString(text)
    return (tostring(text or ""):gsub("%%", "%%%%"))
end

function stringutil.escapeLuaPatterns(text)
    return (tostring(text or ""):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

function stringutil.escapeQuotedCodes(text)
    return (tostring(text or ""):gsub("|", "||"))
end

function stringutil.floorToNearestString(number)
    return format("%d", floor(tonumber(number) or 0))
end

function stringutil.roundToNearestString(number)
    return format("%d", floor((tonumber(number) or 0) + 0.5))
end

function stringutil.truncateWhenZero(number)
    local whole = floor(tonumber(number) or 0)
    return whole == 0 and "" or format("%d", whole)
end

function stringutil.removeContiguousSpaces(text, maxAllowedSpaces)
    local most = math.max(tonumber(maxAllowedSpaces) or 1, 0)
    return (tostring(text or ""):gsub(" +", function(spaces)
        return spaces:sub(1, most)
    end))
end

function stringutil.wrapString(infix, prefix, suffix)
    infix = tostring(infix or "")
    if infix == "" then
        return ""
    end
    return tostring(prefix or "") .. infix .. tostring(suffix or "")
end

---A link's text, without the link (|H...|h and |h), its colour (|c...|r), brackets, textures and atlases, unless
---asked to keep them; |n stays unless asked to go
function stringutil.stripHyperlinks(
    text,
    maintainColor,
    maintainBrackets,
    stripNewlines,
    maintainAtlases,
    maintainTextures
)
    text = tostring(text or "")
    text = text:gsub("|H.-|h", ""):gsub("|h", "")
    if not maintainColor then
        text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
    end
    if not maintainBrackets then
        text = text:gsub("[%[%]]", "")
    end
    if stripNewlines then
        text = text:gsub("|n", "")
    end
    if not maintainAtlases then
        text = text:gsub("|A.-|a", "")
    end
    if not maintainTextures then
        text = text:gsub("|T.-|t", "")
    end
    return text
end

---Texture markup naming a file by its path (a loose file, not one of the game's by its number) taken out
function stringutil.stripTextureMarkupForLooseFiles(text)
    return (
        tostring(text or ""):gsub("|T([^:|]*)[^|]*|t", function(path)
            if path:match("^%d+$") then
                return nil
            end
            return ""
        end)
    )
end

---Fills in the game's namespace: these functions over its stand-ins (the formatters stay stand-ins)
function stringutil.install(namespace)
    namespace.EscapeDecimalNonPrintables = stringutil.escapeDecimalNonPrintables
    namespace.EscapeLuaFormatString = stringutil.escapeLuaFormatString
    namespace.EscapeLuaPatterns = stringutil.escapeLuaPatterns
    namespace.EscapeQuotedCodes = stringutil.escapeQuotedCodes
    namespace.FloorToNearestString = stringutil.floorToNearestString
    namespace.RoundToNearestString = stringutil.roundToNearestString
    namespace.TruncateWhenZero = stringutil.truncateWhenZero
    namespace.RemoveContiguousSpaces = stringutil.removeContiguousSpaces
    namespace.WrapString = stringutil.wrapString
    namespace.StripHyperlinks = stringutil.stripHyperlinks
    namespace.StripTextureMarkupForLooseFiles = stringutil.stripTextureMarkupForLooseFiles
    return namespace
end

return stringutil
