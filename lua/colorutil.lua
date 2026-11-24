-- C_ColorUtil, as the client has it (Blizzard_APIDocumentationGenerated/ColorUtilDocumentation.lua): the text colour
-- codes ColorMixin's GenerateHexColor and WrapTextInColorCode are made of (the class colours' colorStr, every
-- "|cff...|r" the game's own code writes), and the conversions between RGB, HSV and HSL. Hue in degrees (0 to 360),
-- the rest from 0 to 1, as the game's colour picker gives them.
local colorutil = {}

local floor, max, min, format = math.floor, math.max, math.min, string.format

local function toByte(value)
    value = tonumber(value) or 0
    return floor(max(0, min(1, value)) * 255 + 0.5)
end

---@return string code "ff" and the colour's red, green and blue as hex: alpha always ff ("ff3fc7eb" for a mage)
function colorutil.generateTextColorCode(color)
    if type(color) ~= "table" then
        error("Usage: C_ColorUtil.GenerateTextColorCode(color)", 2)
    end
    return format("ff%02x%02x%02x", toByte(color.r), toByte(color.g), toByte(color.b))
end

function colorutil.wrapTextInColorCode(text, code)
    return "|c" .. tostring(code or "ffffffff") .. tostring(text or "") .. "|r"
end

function colorutil.wrapTextInColor(text, color)
    return colorutil.wrapTextInColorCode(text, colorutil.generateTextColorCode(color))
end

function colorutil.convertRGBToHSV(r, g, b)
    r, g, b = tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0
    local high, low = max(r, g, b), min(r, g, b)
    local delta = high - low
    local h = 0
    if delta > 0 then
        if high == r then
            h = 60 * (((g - b) / delta) % 6)
        elseif high == g then
            h = 60 * ((b - r) / delta + 2)
        else
            h = 60 * ((r - g) / delta + 4)
        end
    end
    return h, high > 0 and delta / high or 0, high
end

function colorutil.convertHSVToRGB(h, s, v)
    h, s, v = (tonumber(h) or 0) % 360, tonumber(s) or 0, tonumber(v) or 0
    local chroma = v * s
    local x = chroma * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - chroma
    local r, g, b
    if h < 60 then
        r, g, b = chroma, x, 0
    elseif h < 120 then
        r, g, b = x, chroma, 0
    elseif h < 180 then
        r, g, b = 0, chroma, x
    elseif h < 240 then
        r, g, b = 0, x, chroma
    elseif h < 300 then
        r, g, b = x, 0, chroma
    else
        r, g, b = chroma, 0, x
    end
    return r + m, g + m, b + m
end

function colorutil.convertHSVToHSL(h, s, v)
    s, v = tonumber(s) or 0, tonumber(v) or 0
    local l = v * (1 - s / 2)
    local saturation = (l == 0 or l == 1) and 0 or (v - l) / min(l, 1 - l)
    return tonumber(h) or 0, saturation, l
end

function colorutil.convertHSLToHSV(h, s, l)
    s, l = tonumber(s) or 0, tonumber(l) or 0
    local v = l + s * min(l, 1 - l)
    return tonumber(h) or 0, v == 0 and 0 or 2 * (1 - l / v), v
end

---The namespace for the game's globals
function colorutil.namespace()
    return {
        GenerateTextColorCode = colorutil.generateTextColorCode,
        WrapTextInColor = colorutil.wrapTextInColor,
        WrapTextInColorCode = colorutil.wrapTextInColorCode,
        ConvertRGBToHSV = colorutil.convertRGBToHSV,
        ConvertHSVToRGB = colorutil.convertHSVToRGB,
        ConvertHSVToHSL = colorutil.convertHSVToHSL,
        ConvertHSLToHSV = colorutil.convertHSLToHSV,
    }
end

return colorutil
