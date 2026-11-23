-- The scene as a stream for the page: after the first whole scene, each frame sends only the items that changed and,
-- when it changed, the drawing order (as the items' keys). The page keeps the items it was sent and puts each frame
-- together from them. The whole scene with the map open is 120 KB of JSON and 6 ms to write; a frame of it with the
-- mouse moving over the map is a few items.
--
-- What was sent is kept as copies (an item holds the region's own colour tables, which a setter could change in
-- place), compared field by field with the new export: equal means not sent.
local json = require("json")

local stream = {}

local sent = {} -- [key] = the item as it was last sent (a copy)
local sentOrder = {} -- the keys in drawing order, as last sent
local sentVersion = nil -- the simulator's version the page's items are of (nil: nothing sent yet)

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, inner in pairs(value) do result[key] = copy(inner) end
    return result
end

local function isEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key, value in pairs(a) do
        local other = b[key]
        if value ~= other and not isEqual(value, other) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function keyOf(item)
    return item.k .. item.i
end

---The changes since the last frame sent, as the JSON object's fields (no braces): "o" the order when it changed, "u"
---the items new or changed. Nothing changed: nil.
---@param items table[] the scene as exported (scene.export)
---@param parts string[] where the fields' JSON goes
---@return boolean changed
function stream.encodeChanges(items, parts)
    local order, isOrderChanged = {}, #items ~= #sentOrder
    local changed = {}
    local seen = {}
    for index, item in ipairs(items) do
        local key = keyOf(item)
        if seen[key] then
            -- (two items of one key would be drawn as one on the page: the later one keeps the key with a suffix)
            local suffix = 2
            while seen[key .. "#" .. suffix] do suffix = suffix + 1 end
            key = key .. "#" .. suffix
            item.i = item.i .. "#" .. suffix
        end
        seen[key] = true
        order[index] = key
        if not isOrderChanged and sentOrder[index] ~= key then isOrderChanged = true end
        local previous = sent[key]
        if not previous or not isEqual(item, previous) then
            changed[#changed + 1] = item
            sent[key] = copy(item)
        end
    end
    for key in pairs(sent) do
        if not seen[key] then sent[key] = nil end
    end
    if not isOrderChanged and #changed == 0 then return false end
    if isOrderChanged then
        parts[#parts + 1] = '"o":'
        json.encodeInto(order, parts)
        parts[#parts + 1] = ","
        sentOrder = order
    end
    parts[#parts + 1] = '"u":['
    for index, item in ipairs(changed) do
        if index > 1 then parts[#parts + 1] = "," end
        json.encodeInto(item, parts)
    end
    parts[#parts + 1] = "]"
    return true
end

---Everything the page holds now, as a whole scene: the items last sent, in their order (a page that joins, or one
---that fell behind, starts again from this; the frames after it are changes to it).
function stream.encodeWhole(parts)
    parts[#parts + 1] = '"items":['
    for index, key in ipairs(sentOrder) do
        if index > 1 then parts[#parts + 1] = "," end
        json.encodeInto(sent[key], parts)
    end
    parts[#parts + 1] = "]"
end

function stream.getVersion() return sentVersion end
function stream.setVersion(version) sentVersion = version end

return stream
