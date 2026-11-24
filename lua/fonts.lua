-- Fonts: the game's font objects, text measurement and word wrapping. Widths come from metrics the browser
-- measured with the real fonts (per character, at 1px), so what Lua lays out is what the page draws.
local sim = require("sim")

local fonts = { metrics = {}, objects = {} }
-- What the font objects say moves on with any change to one (a string drawn in it, or in one taking after it, is laid
-- out again: lua/scene.lua keeps a string's items while this and the string itself stand)
fonts.version = 0
function fonts.changed()
    fonts.version = fonts.version + 1
    sim.touch()
end

local FRIZ, ARIALN, MORPHEUS, SKURRI =
    "Fonts\\FRIZQT__.TTF", "Fonts\\ARIALN.TTF", "Fonts\\MORPHEUS.TTF", "Fonts\\skurri.ttf"
fonts.FILES = { FRIZ, ARIALN, MORPHEUS, SKURRI }
local DEFAULT_WIDTH = 0.55 -- of the size, for a character never measured

local fontKeys = {} -- [path] = key: a few paths, asked for by every string at every export
function fonts.key(path)
    path = path or FRIZ
    local key = fontKeys[path]
    if not key then
        key = tostring(path):gsub("/", "\\"):lower()
        fontKeys[path] = key
    end
    return key
end

function fonts.setMetrics(metrics)
    fonts.metrics = metrics or {}
    fonts.changed()
end

-- Font objects
local fontMethods = {}
local fontMeta = { __index = fontMethods }

function fonts.createFont(name, path, size, flags, color, justifyH, shadow)
    local font = setmetatable({
        name = name,
        path = path or FRIZ,
        size = size or 12,
        flags = flags or "",
        color = color or { 1, 1, 1, 1 },
        justifyH = justifyH,
        shadowOffset = shadow and { 1, -1 } or nil,
        shadowColor = { 0, 0, 0, 1 },
    }, fontMeta)
    if name then
        fonts.objects[name] = font
        sim.G[name] = font
    end
    return font
end

function fontMethods:SetFont(path, size, flags)
    self.path, self.size, self.flags = path or self.path, size or self.size, flags or ""
    fonts.changed()
    return true
end
function fontMethods:GetFont()
    return self.path, self.size, self.flags
end
function fontMethods:SetTextColor(r, g, b, a)
    self.color = { r or 1, g or 1, b or 1, a or 1 }
    fonts.changed()
end
function fontMethods:GetTextColor()
    return unpack(self.color)
end
function fontMethods:SetShadowOffset(x, y)
    self.shadowOffset = { x or 0, y or 0 }
    fonts.changed()
end
function fontMethods:GetShadowOffset()
    local offset = self.shadowOffset or { 0, 0 }
    return offset[1], offset[2]
end
function fontMethods:SetShadowColor(r, g, b, a)
    self.shadowColor = { r or 0, g or 0, b or 0, a or 1 }
end
function fontMethods:GetShadowColor()
    return unpack(self.shadowColor or { 0, 0, 0, 1 })
end
function fontMethods:SetJustifyH(justify)
    self.justifyH = justify
end
function fontMethods:GetJustifyH()
    return self.justifyH or "CENTER"
end
function fontMethods:SetJustifyV(justify)
    self.justifyV = justify
end
function fontMethods:SetSpacing(spacing)
    self.spacing = spacing
end
function fontMethods:GetSpacing()
    return self.spacing or 0
end
function fontMethods:GetName()
    return self.name
end
function fontMethods:GetObjectType()
    return "Font"
end
function fontMethods:IsObjectType(typeName)
    return typeName == "Font"
end
function fontMethods:SetFontObject(other)
    if type(other) == "string" then
        other = sim.G[other]
    end
    if other then
        self:CopyFontObject(other)
    end
end
function fontMethods:CopyFontObject(other)
    if type(other) == "string" then
        other = sim.G[other]
    end
    if not other then
        return
    end
    self.path, self.size, self.flags = other.path, other.size, other.flags
    self.color = { unpack(other.color or { 1, 1, 1, 1 }) }
    self.justifyH, self.shadowOffset, self.spacing = other.justifyH, other.shadowOffset, other.spacing
    fonts.changed()
end
-- The client's alphabet, by its locale: the one a font family draws with
local LOCALE_ALPHABETS = { koKR = "korean", zhCN = "simplifiedchinese", zhTW = "traditionalchinese", ruRU = "russian" }
function fonts.clientAlphabet()
    local locale = sim.G and sim.G.GetLocale and sim.G.GetLocale() or "enUS"
    return LOCALE_ALPHABETS[locale] or "roman"
end
-- A font's member for an alphabet (a font family's: CreateFontFamily): the client's own alphabet's is the font itself,
-- what its text is drawn with; any other is a font of its own, so setting it never changes what is drawn (EllesmereUI
-- sets its chat font family's every member in turn: the last, a Chinese font at 16, was drawn)
function fontMethods:GetFontObjectForAlphabet(alphabet)
    if alphabet == nil or alphabet == (self.activeAlphabet or fonts.clientAlphabet()) then
        return self
    end
    self.alphabetMembers = self.alphabetMembers or {}
    local member = self.alphabetMembers[alphabet]
    if not member then
        member = fonts.createFont(nil, self.path, self.size, self.flags, self.color, self.justifyH)
        self.alphabetMembers[alphabet] = member
    end
    return member
end
function fontMethods:SetIndentedWordWrap() end
function fontMethods:GetFontObject()
    return self
end
function fontMethods:SetAlpha() end
function fontMethods:GetAlpha()
    return 1
end
-- (every change to a font object, whether or not its setter says so: SetJustifyH, SetSpacing, SetShadowColor...)
for name, method in pairs(fontMethods) do
    if name:match("^Set") or name == "CopyFontObject" then
        fontMethods[name] = function(...)
            local results = { method(...) }
            -- (the strings using it measure and draw anew: the fonts' cache, the layout, the native mirror's)
            fonts.changed()
            return unpack(results, 1, table.maxn(results))
        end
    end
end

local GOLD, WHITE, GREY, BLACK = { 1, 0.82, 0, 1 }, { 1, 1, 1, 1 }, { 0.5, 0.5, 0.5, 1 }, { 0, 0, 0, 1 }

---The game's font objects, by name: sizes and colours as the default interface sets them.
function fonts.installDefaults()
    local function add(name, path, size, color, flags, shadow)
        fonts.createFont(name, path, size, flags, color, nil, shadow)
    end
    for _, spec in ipairs({
        { "GameFontNormal", FRIZ, 12, GOLD },
        { "GameFontNormalSmall", FRIZ, 10, GOLD },
        { "GameFontNormalSmall2", FRIZ, 11, GOLD },
        { "GameFontNormalMed1", FRIZ, 13, GOLD },
        { "GameFontNormalMed2", FRIZ, 14, GOLD },
        { "GameFontNormalMed3", FRIZ, 14, GOLD },
        { "GameFontNormalLarge", FRIZ, 16, GOLD },
        { "GameFontNormalLarge2", FRIZ, 18, GOLD },
        { "GameFontNormalHuge", FRIZ, 20, GOLD },
        { "GameFontNormalHuge2", FRIZ, 24, GOLD },
        { "GameFontNormalOutline", FRIZ, 12, GOLD, "OUTLINE" },
        { "GameFontHighlight", FRIZ, 12, WHITE },
        { "GameFontHighlightSmall", FRIZ, 10, WHITE },
        { "GameFontHighlightSmall2", FRIZ, 11, WHITE },
        { "GameFontHighlightMedium", FRIZ, 14, WHITE },
        { "GameFontHighlightLarge", FRIZ, 16, WHITE },
        { "GameFontHighlightHuge", FRIZ, 20, WHITE },
        { "GameFontHighlightOutline", FRIZ, 12, WHITE, "OUTLINE" },
        { "GameFontHighlightLeft", FRIZ, 12, WHITE },
        { "GameFontHighlightSmallLeft", FRIZ, 10, WHITE },
        { "GameFontHighlightSmallOutline", FRIZ, 10, WHITE, "OUTLINE" },
        { "GameFontDisable", FRIZ, 12, GREY },
        { "GameFontDisableSmall", FRIZ, 10, GREY },
        { "GameFontDisableLarge", FRIZ, 16, GREY },
        { "GameFontGreen", FRIZ, 12, { 0.1, 1, 0.1, 1 } },
        { "GameFontGreenSmall", FRIZ, 10, { 0.1, 1, 0.1, 1 } },
        { "GameFontRed", FRIZ, 12, { 1, 0.1, 0.1, 1 } },
        { "GameFontRedSmall", FRIZ, 10, { 1, 0.1, 0.1, 1 } },
        { "GameFontWhite", FRIZ, 12, WHITE },
        { "GameFontWhiteSmall", FRIZ, 10, WHITE },
        { "GameFontBlack", FRIZ, 12, BLACK },
        { "GameFontBlackMedium", FRIZ, 14, BLACK },
        { "GameFontBlackSmall", FRIZ, 10, BLACK },
        { "GameTooltipText", FRIZ, 12, WHITE },
        { "GameTooltipTextSmall", FRIZ, 10, WHITE },
        { "GameTooltipHeaderText", FRIZ, 14, WHITE },
        { "QuestFont", FRIZ, 13, { 0.18, 0.12, 0.06, 1 } },
        { "QuestFontNormalSmall", FRIZ, 12, { 0.18, 0.12, 0.06, 1 } },
        { "QuestFontHighlight", FRIZ, 13, { 0.18, 0.12, 0.06, 1 } },
        { "QuestFontLeft", FRIZ, 13, { 0.18, 0.12, 0.06, 1 } },
        { "QuestTitleFont", MORPHEUS, 18, { 0, 0, 0, 1 } },
        { "QuestTitleFontBlackShadow", MORPHEUS, 18, GOLD },
        { "QuestFont_Large", FRIZ, 15, { 0.18, 0.12, 0.06, 1 } },
        { "QuestFont_Huge", FRIZ, 18, { 0.18, 0.12, 0.06, 1 } },
        { "ChatFontNormal", ARIALN, 14, WHITE },
        { "ChatFontSmall", ARIALN, 12, WHITE },
        { "NumberFontNormal", ARIALN, 14, WHITE, "OUTLINE" },
        { "NumberFontNormalSmall", ARIALN, 12, WHITE, "OUTLINE" },
        { "NumberFontNormalLarge", ARIALN, 16, WHITE, "OUTLINE" },
        { "NumberFontNormalHuge", SKURRI, 30, WHITE, "THICKOUTLINE" },
        { "NumberFontNormalSmallGray", ARIALN, 12, GREY, "OUTLINE" },
        { "NumberFontNormalRight", ARIALN, 14, WHITE, "OUTLINE" },
        { "SystemFont_Tiny", FRIZ, 9, WHITE },
        { "SystemFont_Small", FRIZ, 10, WHITE },
        { "SystemFont_Med1", FRIZ, 12, WHITE },
        { "SystemFont_Med2", FRIZ, 13, WHITE },
        { "SystemFont_Med3", FRIZ, 14, WHITE },
        { "SystemFont_Large", FRIZ, 16, WHITE },
        { "SystemFont_Huge1", FRIZ, 20, WHITE },
        { "SystemFont_Huge2", FRIZ, 24, WHITE },
        { "SystemFont_Shadow_Small", FRIZ, 10, WHITE, nil, true },
        { "SystemFont_Shadow_Med1", FRIZ, 12, WHITE, nil, true },
        { "SystemFont_Shadow_Med2", FRIZ, 14, WHITE, nil, true },
        { "SystemFont_Shadow_Med3", FRIZ, 16, WHITE, nil, true },
        { "SystemFont_Shadow_Large", FRIZ, 16, WHITE, nil, true },
        { "SystemFont_Shadow_Huge1", FRIZ, 20, WHITE, nil, true },
        { "SystemFont_OutlineThick_Huge2", FRIZ, 22, WHITE, "THICKOUTLINE" },
        { "SystemFont_Outline_Small", ARIALN, 10, WHITE, "OUTLINE" },
        { "SubZoneTextFont", MORPHEUS, 26, GOLD },
        { "ZoneTextFont", MORPHEUS, 32, GOLD },
        { "PVPInfoTextFont", FRIZ, 20, GOLD },
        { "ObjectiveFont", FRIZ, 12, { 0.8, 0.8, 0.8, 1 } },
        { "ObjectiveTrackerHeaderFont", FRIZ, 14, GOLD },
        { "ObjectiveTrackerLineFont", FRIZ, 12, { 0.8, 0.8, 0.8, 1 } },
        { "DestinyFontLarge", MORPHEUS, 18, GOLD },
        { "DestinyFontHuge", MORPHEUS, 32, GOLD },
        { "Fancy12Font", MORPHEUS, 12, GOLD },
        { "Fancy14Font", MORPHEUS, 14, GOLD },
        { "Fancy16Font", MORPHEUS, 16, GOLD },
        { "Fancy18Font", MORPHEUS, 18, GOLD },
        { "Fancy20Font", MORPHEUS, 20, GOLD },
        { "Fancy22Font", MORPHEUS, 22, GOLD },
        { "Fancy24Font", MORPHEUS, 24, GOLD },
        { "Fancy27Font", MORPHEUS, 27, GOLD },
        { "Fancy30Font", MORPHEUS, 30, GOLD },
        { "Fancy32Font", MORPHEUS, 32, GOLD },
        { "Fancy48Font", MORPHEUS, 48, GOLD },
        { "Game10Font_o1", FRIZ, 10, WHITE, "OUTLINE" },
        { "Game11Font", FRIZ, 11, WHITE },
        { "Game12Font", FRIZ, 12, WHITE },
        { "Game13Font", FRIZ, 13, WHITE },
        { "Game13FontShadow", FRIZ, 13, WHITE, nil, true },
        { "Game15Font", FRIZ, 15, WHITE },
        { "Game16Font", FRIZ, 16, WHITE },
        { "Game18Font", FRIZ, 18, WHITE },
        { "Game20Font", FRIZ, 20, WHITE },
        { "Game24Font", FRIZ, 24, WHITE },
        { "Game27Font", FRIZ, 27, WHITE },
        { "Game30Font", FRIZ, 30, WHITE },
        { "Game32Font", FRIZ, 32, WHITE },
        { "Game36Font", FRIZ, 36, WHITE },
        { "Game40Font", FRIZ, 40, WHITE },
        { "Game42Font", FRIZ, 42, WHITE },
        { "Game46Font", FRIZ, 46, WHITE },
        { "Game48Font", FRIZ, 48, WHITE },
        { "Game48FontShadow", FRIZ, 48, WHITE, nil, true },
        { "Game60Font", FRIZ, 60, WHITE },
        { "Game72Font", FRIZ, 72, WHITE },
        { "GameFont72Normal", FRIZ, 72, GOLD },
        { "GameFont72Highlight", FRIZ, 72, WHITE },
        { "Tooltip_Med", FRIZ, 12, WHITE },
        { "Tooltip_Small", FRIZ, 10, WHITE },
        { "MailFont_Large", MORPHEUS, 15, { 0.18, 0.12, 0.06, 1 } },
        { "InvoiceFont_Med", FRIZ, 12, { 0.18, 0.12, 0.06, 1 } },
        { "AchievementFont_Small", FRIZ, 10, WHITE },
        { "SpellFont_Small", FRIZ, 10, WHITE },
        { "FriendsFont_Normal", FRIZ, 12, WHITE },
        { "FriendsFont_Small", FRIZ, 10, WHITE },
        { "FriendsFont_Large", FRIZ, 14, WHITE },
        { "WhiteNormalNumberFont", ARIALN, 14, WHITE, "OUTLINE" },
        { "TextStatusBarText", ARIALN, 12, WHITE, "OUTLINE" },
        { "CombatTextFont", FRIZ, 25, WHITE },
        { "ErrorFont", FRIZ, 16, { 1, 0.1, 0.1, 1 } },
        { "BossEmoteNormalHuge", FRIZ, 25, WHITE },
        { "SplashHeaderFont", MORPHEUS, 24, GOLD },
        { "GameFontNormalCenter", FRIZ, 12, GOLD },
    }) do
        add(spec[1], spec[2], spec[3], spec[4], spec[5], spec[6])
    end
    for _, name in ipairs({ "GameFontHighlightLeft", "GameFontHighlightSmallLeft" }) do
        fonts.objects[name].justifyH = "LEFT"
    end
end

-- The game's own fonts: every FontFamily and Font in Blizzard_Fonts_Shared, in its TOC's order, inheritance
-- resolved. They replace the defaults above (which stay for anything the files do not define).
local function readColor(element, namedColors)
    if not element then
        return nil
    end
    if element.attrs.color then
        local named = namedColors[element.attrs.color]
        return named and { named[1], named[2], named[3], named[4] } or nil
    end
    return {
        tonumber(element.attrs.r) or 1,
        tonumber(element.attrs.g) or 1,
        tonumber(element.attrs.b) or 1,
        tonumber(element.attrs.a) or 1,
    }
end

local function readFontElement(element, definition, namedColors)
    local xml = require("xml")
    local attrs = element.attrs
    definition.path = attrs.font or definition.path
    definition.size = tonumber(attrs.height) or definition.size
    if attrs.outline then
        definition.flags = attrs.outline == "THICK" and "THICKOUTLINE" or attrs.outline == "NORMAL" and "OUTLINE" or ""
    end
    if attrs.monochrome == "true" then
        definition.flags = ((definition.flags or "") ~= "" and (definition.flags .. ",") or "") .. "MONOCHROME"
    end
    definition.justifyH = attrs.justifyH or definition.justifyH
    definition.justifyV = attrs.justifyV or definition.justifyV
    definition.spacing = tonumber(attrs.spacing) or definition.spacing
    local color = readColor(xml.child(element, "Color"), namedColors)
    if color then
        definition.color = color
    end
    local shadow = xml.child(element, "Shadow")
    if shadow then
        local offset = xml.child(shadow, "Offset")
        local dimension = offset and (xml.child(offset, "AbsDimension") or offset)
        definition.shadowOffset = {
            tonumber(shadow.attrs.x or (dimension and dimension.attrs.x)) or 1,
            tonumber(shadow.attrs.y or (dimension and dimension.attrs.y)) or -1,
        }
        definition.shadowColor = readColor(xml.child(shadow, "Color"), namedColors) or { 0, 0, 0, 1 }
    end
    local height = xml.child(element, "FontHeight")
    local value = height and xml.child(height, "AbsValue")
    if value then
        definition.size = tonumber(value.attrs.val) or definition.size
    end
end

local definitions, order = {}, {}

---Font and FontFamily elements, from the game's font files or any addon's XML: definitions kept, inheritance
---resolved, font objects made.
---@return number count Font objects made
function fonts.loadGameFontElements(elements, namedColors)
    local xml = require("xml")
    namedColors = namedColors or fonts.namedColors or {}
    do
        for _, element in ipairs(elements) do
            local name = element.attrs.name
            if name and (element.tag == "Font" or element.tag == "FontFamily") then
                local definition = definitions[name] or {}
                if not definitions[name] then
                    order[#order + 1] = name
                end
                definitions[name] = definition
                definition.inherits = element.attrs.inherits or definition.inherits
                if element.tag == "FontFamily" then
                    for _, member in ipairs(element.children) do
                        if member.tag == "Member" and member.attrs.alphabet == "roman" then
                            local fontElement = xml.child(member, "Font")
                            if fontElement then
                                readFontElement(fontElement, definition, namedColors)
                            end
                        end
                    end
                else
                    readFontElement(element, definition, namedColors)
                end
            end
        end
    end
    local resolved = {}
    local function resolve(name, depth)
        if resolved[name] then
            return resolved[name]
        end
        local definition = definitions[name]
        if not definition or (depth or 0) > 20 then
            return nil
        end
        local base = definition.inherits and resolve(definition.inherits, (depth or 0) + 1) or {}
        local result = {}
        for key, value in pairs(base) do
            result[key] = value
        end
        for key, value in pairs(definition) do
            if key ~= "inherits" then
                result[key] = value
            end
        end
        resolved[name] = result
        return result
    end
    local count = 0
    for _, name in ipairs(order) do
        local definition = resolve(name)
        if definition and definition.path then
            local font = fonts.objects[name] or fonts.createFont(name)
            font.path, font.size, font.flags = definition.path, definition.size or 12, definition.flags or ""
            font.color = definition.color or { 1, 1, 1, 1 }
            font.shadowOffset, font.shadowColor = definition.shadowOffset, definition.shadowColor
            font.justifyH, font.justifyV, font.spacing = definition.justifyH, definition.justifyV, definition.spacing
            fonts.objects[name] = font
            sim.G[name] = font
            count = count + 1
        end
    end
    fonts.changed()
    return count
end

---@param files string[] The font XML files, in load order
function fonts.loadGameFonts(files, namedColors)
    local xml = require("xml")
    fonts.namedColors = namedColors
    local elements = {}
    for _, path in ipairs(files) do
        local root = xml.parseFile(path)
        for _, element in ipairs(root and root.children[1] and root.children[1].children or {}) do
            elements[#elements + 1] = element
        end
    end
    return fonts.loadGameFontElements(elements, namedColors)
end

---The font a font string draws with: its own, else its font object's, else the default. (Read only: the answer is
---kept for the string's font, or its font object, until the layout changes, which every font setter does.)
local fontCache, fontCacheVersion = setmetatable({}, { __mode = "k" }), nil
local DEFAULT_FONT
function fonts.getFont(s)
    if fontCacheVersion ~= sim.layoutVersion then
        fontCache, fontCacheVersion = setmetatable({}, { __mode = "k" }), sim.layoutVersion
    end
    if s.font then
        local cached = fontCache[s.font]
        if cached and cached.fontObject == s.fontObject then
            return cached
        end
        cached = {
            path = s.font.path,
            size = s.font.size,
            flags = s.font.flags,
            justifyH = s.fontObject and s.fontObject.justifyH,
            fontObject = s.fontObject,
        }
        fontCache[s.font] = cached
        return cached
    end
    local object = s.fontObject
    if type(object) == "string" then
        object = sim.G[object]
    end
    if type(object) == "table" and object.path then
        local cached = fontCache[object]
        if cached then
            return cached
        end
        cached = {
            path = object.path,
            size = object.size,
            flags = object.flags,
            justifyH = object.justifyH,
            justifyV = object.justifyV,
            color = object.color,
            shadowOffset = object.shadowOffset,
            shadowColor = object.shadowColor,
            spacing = object.spacing,
        }
        fontCache[object] = cached
        return cached
    end
    DEFAULT_FONT = DEFAULT_FONT or { path = FRIZ, size = 12, flags = "" }
    return DEFAULT_FONT
end

function fonts.getColor(s)
    if s.textColor then
        return s.textColor
    end
    local font = fonts.getFont(s)
    return font.color or { 1, 1, 1, 1 }
end

-- Text: escape sequences, measurement, wrapping
local function getCodepoint(character)
    local byte = character:byte(1)
    if byte < 0x80 then
        return byte
    end
    if byte < 0xE0 then
        return (byte - 0xC0) * 64 + (character:byte(2) - 0x80)
    end
    if byte < 0xF0 then
        return (byte - 0xE0) * 4096 + (character:byte(2) - 0x80) * 64 + (character:byte(3) - 0x80)
    end
    return 0x10000
end

---@return string? hex "aarrggbb" for a named colour: the game's GlobalColor table (fonts.namedColors, filled at boot)
---or a colour object of that name the interface made (GetRGBA)
function fonts.getNamedColorHex(name)
    local color = fonts.namedColors and fonts.namedColors[name]
    if not color then
        local object = rawget(sim.G, name)
        if type(object) == "table" and type(object.GetRGBA) == "function" then
            local ok, r, g, b, a = pcall(object.GetRGBA, object)
            if ok and r then
                color = { r, g, b, a or 1 }
            end
        end
    end
    if not color then
        return nil
    end
    local function byte(value)
        return math.max(0, math.min(255, math.floor((value or 1) * 255 + 0.5)))
    end
    return string.format("%02x%02x%02x%02x", byte(color[4]), byte(color[1]), byte(color[2]), byte(color[3]))
end

---The game's grammar code "|4singular:plural;" (DEATH's "%d |4Minute:Minutes;"): the form for the last number before
---it, singular for 1. Locales with more forms list them all ("|4a:b:c;"); past the first, the second stands for any
---other number here (enough for every enUS string).
local function resolveGrammar(text)
    if not text:find("|4", 1, true) then
        return text
    end
    local resolved, from = {}, 1
    while true do
        local start, finish, forms = text:find("|4([^;]*);", from)
        if not start then
            break
        end
        local before = text:sub(from, start - 1)
        resolved[#resolved + 1] = before
        local number = (table.concat(resolved)):match("(%d[%d,%.]*)%D*$")
        local singular, plural = forms:match("^([^:]*):([^:]*)")
        local isOne = number and tonumber((number:gsub(",", ""))) == 1
        resolved[#resolved + 1] = (isOne and singular or plural) or forms
        from = finish + 1
    end
    resolved[#resolved + 1] = text:sub(from)
    return table.concat(resolved)
end

---Splits text into tokens: characters (with widths), zero-width codes (colours, links) and inline icons.
local function tokenize(text, metricsTable, size)
    text = resolveGrammar(text)
    local tokens, index, length = {}, 1, #text
    local average = metricsTable and metricsTable.avg or DEFAULT_WIDTH
    local function addCharacter(character)
        local width = (metricsTable and metricsTable[tostring(getCodepoint(character))] or average) * size
        tokens[#tokens + 1] = { kind = character == " " and "space" or "char", text = character, width = width }
    end
    while index <= length do
        local character = text:sub(index, index)
        if character == "|" then
            local code = text:sub(index + 1, index + 1)
            if code == "c" and text:sub(index + 2, index + 2) == "n" then
                -- "|cnNAME:": a colour by its name (the game's named colours, or a colour object of that name)
                local stop = text:find(":", index + 3, true) or length
                local hex = fonts.getNamedColorHex(text:sub(index + 3, stop - 1)) or "ffffffff"
                tokens[#tokens + 1] = { kind = "code", text = "|c" .. hex, width = 0 }
                index = stop + 1
            elseif code == "c" then
                tokens[#tokens + 1] = { kind = "code", text = text:sub(index, index + 9), width = 0 }
                index = index + 10
            elseif code == "r" then
                tokens[#tokens + 1] = { kind = "code", text = "|r", width = 0 }
                index = index + 2
            elseif code == "H" then
                local stop = text:find("|h", index + 2, true)
                stop = stop or length
                tokens[#tokens + 1] = { kind = "code", text = text:sub(index, stop + 1), width = 0 }
                index = stop + 2
            elseif code == "h" then
                tokens[#tokens + 1] = { kind = "code", text = "|h", width = 0 }
                index = index + 2
            elseif code == "T" or code == "A" then
                local stop = text:find(code == "T" and "|t" or "|a", index + 2, true) or length
                local raw = text:sub(index, stop + 1)
                local width, height
                if code == "A" then
                    -- |A:name:height:width:...|a (the game's CreateAtlasMarkup): 0 is the line's height
                    local tall, wide = raw:match("^|A:?[^:|]*:(%d+):?(%d*)")
                    tall, wide = tonumber(tall) or 0, tonumber(wide) or 0
                    height = tall > 0 and tall or size
                    width = wide > 0 and wide or height
                else
                    local iconSize = tonumber(raw:match("^|T[^:]*:(%d+)")) or 0
                    width = iconSize > 0 and iconSize or size
                    height = width
                end
                -- (an icon taller than the text makes its line as tall: the tooltip's button prompts)
                tokens[#tokens + 1] = { kind = "icon", text = raw, width = width, height = height }
                index = stop + 2
            elseif code == "n" then
                tokens[#tokens + 1] = { kind = "newline" }
                index = index + 2
            elseif code == "|" then
                addCharacter("|")
                index = index + 2
            else
                index = index + 1
            end
        elseif character == "\n" then
            tokens[#tokens + 1] = { kind = "newline" }
            index = index + 1
        else
            local stop = index
            local byte = character:byte()
            if byte >= 0xF0 then
                stop = index + 3
            elseif byte >= 0xE0 then
                stop = index + 2
            elseif byte >= 0xC0 then
                stop = index + 1
            end
            addCharacter(text:sub(index, stop))
            index = stop + 1
        end
    end
    return tokens
end

local function getMetrics(font)
    return fonts.metrics[fonts.key(font.path)]
end

local wrapLines

-- Each text's lines, kept by everything they come from (the text, its font, size and flags, its scale, the width,
-- wrapping and the most lines): the scene's export laid every text on the screen out again, character by character,
-- many times a second. Handed out as a fresh list (callers cut it); the lines in it are not changed by anyone.
local wrapped, wrappedCount = {}, 0
local WRAPPED_KEPT = 6000

---Lays the text out in lines no wider than the width (nil: no wrapping). Lines keep their codes.
---@return { text: string, width: number }[] lines
function fonts.wrap(s, width)
    local text = s.text
    if not text or text == "" then
        return {}
    end
    local font = fonts.getFont(s)
    local key = table.concat({
        text,
        font.path or "",
        font.size or 0,
        font.flags or "",
        s.textScale or 1,
        width or -1,
        tostring(s.wordWrap),
        s.maxLines or 0,
    }, "\1")
    local lines = wrapped[key]
    if not lines then
        lines = wrapLines(s, width)
        if wrappedCount >= WRAPPED_KEPT then
            wrapped, wrappedCount = {}, 0
        end
        wrapped[key], wrappedCount = lines, wrappedCount + 1
    end
    local copy = {}
    for index = 1, #lines do
        copy[index] = lines[index]
    end
    return copy
end

wrapLines = function(s, width)
    local text = s.text
    local font = fonts.getFont(s)
    local size = font.size * (s.textScale or 1)
    local tokens = tokenize(text, getMetrics(font), size)
    local lines = {}
    local current, currentWidth, currentTallest = {}, 0, 0
    local word, wordWidth, wordTallest = {}, 0, 0
    local pendingSpace, pendingSpaceWidth = {}, 0
    local isWrapping = width and width > 0 and s.wordWrap ~= false
    local function finishLine()
        lines[#lines + 1] = {
            text = table.concat(current),
            width = currentWidth,
            iconHeight = currentTallest > 0 and currentTallest or nil,
        }
        current, currentWidth, currentTallest = {}, 0, 0
    end
    local function flushWord()
        if #word == 0 then
            return
        end
        -- Half a pixel of slack: text anchored to exactly its own width stays on one line, as in the game
        if isWrapping and currentWidth > 0 and currentWidth + pendingSpaceWidth + wordWidth > width + 0.5 then
            finishLine()
            pendingSpace, pendingSpaceWidth = {}, 0
        end
        for _, piece in ipairs(pendingSpace) do
            current[#current + 1] = piece
        end
        currentWidth = currentWidth + pendingSpaceWidth
        pendingSpace, pendingSpaceWidth = {}, 0
        for _, piece in ipairs(word) do
            current[#current + 1] = piece
        end
        currentWidth = currentWidth + wordWidth
        currentTallest = math.max(currentTallest, wordTallest)
        word, wordWidth, wordTallest = {}, 0, 0
    end
    for _, token in ipairs(tokens) do
        if token.kind == "space" then
            flushWord()
            pendingSpace[#pendingSpace + 1] = token.text
            pendingSpaceWidth = pendingSpaceWidth + token.width
        elseif token.kind == "newline" then
            flushWord()
            pendingSpace, pendingSpaceWidth = {}, 0
            finishLine()
        else
            if
                isWrapping
                and token.kind ~= "code"
                and wordWidth + token.width > width + 0.5
                and currentWidth == 0
                and #word > 0
            then
                -- A word longer than the line breaks where it must
                for _, piece in ipairs(word) do
                    current[#current + 1] = piece
                end
                currentWidth = wordWidth
                currentTallest = math.max(currentTallest, wordTallest)
                word, wordWidth, wordTallest = {}, 0, 0
                finishLine()
            end
            word[#word + 1] = token.text
            wordWidth = wordWidth + token.width
            if token.height then
                wordTallest = math.max(wordTallest, token.height)
            end
        end
    end
    flushWord()
    if #current > 0 or #lines == 0 then
        finishLine()
    end
    if s.maxLines and s.maxLines > 0 and #lines > s.maxLines then
        for index = #lines, s.maxLines + 1, -1 do
            lines[index] = nil
        end
        lines[#lines].text = lines[#lines].text .. "..."
    elseif isWrapping == false and width and width > 0 and #lines == 1 and lines[1].width > width + 0.5 then
        lines[1].isTruncated = true
        -- The game ends a single line cut short with "...": as many characters as fit, then the dots
        local function measure(part)
            return fonts.measureWidth(setmetatable({ text = part, maxLines = false }, { __index = s }))
        end
        local cut, dotsWidth = lines[1].text, measure("...")
        while #cut > 0 do
            cut = cut:gsub("[%z\1-\127\194-\244][\128-\191]*$", "") -- the last character, whole
            if measure(cut) + dotsWidth <= width + 0.5 then
                break
            end
        end
        lines[1].text, lines[1].width = cut .. "...", measure(cut) + dotsWidth
    end
    return lines
end

function fonts.getLineHeight(s)
    local font = fonts.getFont(s)
    return font.size * (s.textScale or 1)
end

---The width of the text unwrapped: its widest line.
function fonts.measureWidth(s)
    local widest = 0
    for _, line in ipairs(fonts.wrap(s, nil)) do
        widest = math.max(widest, line.width)
    end
    return widest
end

function fonts.measureHeight(s, width)
    local lines = fonts.wrap(s, width)
    if #lines == 0 then
        return 0
    end
    local spacing = s.spacing or fonts.getFont(s).spacing or 0
    local lineHeight = fonts.getLineHeight(s)
    local height = (#lines - 1) * spacing
    for _, line in ipairs(lines) do
        height = height + math.max(lineHeight, line.iconHeight or 0)
    end
    return height
end

return fonts
