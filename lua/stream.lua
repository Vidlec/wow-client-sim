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
-- [key] = the export's own item table last time: the scene keeps a region's items while nothing they come from
-- changed (lua/scene.lua), and the same table again is the same item, not compared field by field
local lastTables = {}
-- (checked, ADDONSIM_CHECK_SCENE=1: a kept item compared all the same, any change found in it reported: a region's
-- own table changed in place by something that did not say so)
local isChecking = os.getenv("ADDONSIM_CHECK_SCENE") == "1"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, inner in pairs(value) do
        result[key] = copy(inner)
    end
    return result
end

local function isEqual(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        local other = b[key]
        if value ~= other and not isEqual(value, other) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function keyOf(item)
    return item.k .. item.i
end

-- [key] = the item's move count as last sent: a kept item given new boxes in place (scene.moveCounts) goes out as a
-- move, its key and boxes, not the whole item
local lastMoves = {}
---A moved item's boxes, as the page puts them on the item it holds: [key, x, y, w, h, clip box or 0, mask boxes or 0]
local function moveOf(key, item)
    local masks = 0
    if item.mk then
        masks = {}
        for index, mask in ipairs(item.mk) do
            masks[index] = mask.b
        end
    end
    return { key, item.x, item.y, item.w, item.h, item.cl or 0, masks }
end
---The copy last sent given the moved item's boxes
local function moveSent(previous, item)
    previous.x, previous.y, previous.w, previous.h = item.x, item.y, item.w, item.h
    previous.cl = item.cl and copy(item.cl) or nil
    if item.mk and previous.mk then
        for index, mask in ipairs(item.mk) do
            if previous.mk[index] then
                previous.mk[index].b = copy(mask.b)
            end
        end
    end
end

---The changes since the last frame sent, as the JSON object's fields (no braces): "o" the order when it changed, "u"
---the items new or changed. Nothing changed: nil.
---@param items table[] the scene as exported (scene.export)
---@param parts string[] where the fields' JSON goes
---@return boolean changed
function stream.encodeChanges(items, parts)
    local order, isOrderChanged = {}, #items ~= #sentOrder
    local changed, moved = {}, {}
    local scene = package.loaded["scene"]
    local moveCounts = scene and scene.moveCounts or {}
    local seen = {}
    for index, item in ipairs(items) do
        local key = keyOf(item)
        if seen[key] then
            -- (two items of one key would be drawn as one on the page: the later one keeps the key with a suffix)
            local suffix = 2
            while seen[key .. "#" .. suffix] do
                suffix = suffix + 1
            end
            key = key .. "#" .. suffix
            item.i = item.i .. "#" .. suffix
        end
        seen[key] = true
        order[index] = key
        if not isOrderChanged and sentOrder[index] ~= key then
            isOrderChanged = true
        end
        local previous = sent[key]
        if previous and lastTables[key] == item then
            -- (kept by the scene: unchanged, or moved)
            local moveCount = moveCounts[item] or 0
            if moveCount ~= lastMoves[key] then
                moved[#moved + 1] = moveOf(key, item)
                moveSent(previous, item)
                lastMoves[key] = moveCount
            end
            if isChecking and not isEqual(item, previous) then
                require("sim").reportError("A kept scene item changed in place: " .. key, "")
                changed[#changed + 1] = item
                sent[key] = copy(item)
            end
        else
            if not previous or not isEqual(item, previous) then
                changed[#changed + 1] = item
                sent[key] = copy(item)
            end
            lastMoves[key] = moveCounts[item] or 0
        end
        lastTables[key] = item
    end
    for key in pairs(sent) do
        if not seen[key] then
            sent[key] = nil
            lastTables[key] = nil
            lastMoves[key] = nil
        end
    end
    if not isOrderChanged and #changed == 0 and #moved == 0 then
        return false
    end
    if isOrderChanged then
        parts[#parts + 1] = '"o":'
        json.encodeInto(order, parts)
        parts[#parts + 1] = ","
        sentOrder = order
    end
    if #moved > 0 then
        parts[#parts + 1] = '"mv":'
        json.encodeInto(moved, parts)
        parts[#parts + 1] = ","
    end
    parts[#parts + 1] = '"u":['
    for index, item in ipairs(changed) do
        if index > 1 then
            parts[#parts + 1] = ","
        end
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
        if index > 1 then
            parts[#parts + 1] = ","
        end
        json.encodeInto(sent[key], parts)
    end
    parts[#parts + 1] = "]"
end

function stream.getVersion()
    return sentVersion
end
function stream.setVersion(version)
    sentVersion = version
end

-- The binary stream: the native store keeps what the page holds (lua/native.lua), this side tells it each frame's
-- items in order (a new or changed one packed, lua/pack.lua; a kept one by its key; a moved one by its key and
-- boxes). Used when the server asks for binary frames and the store is built; else the JSON one above.
local ffi = require("ffi")
local store, library
local lengthOut = ffi.new("size_t[1]")
local boxes, boxesCapacity = ffi.new("double[?]", 64), 64
local NAN = 0 / 0

---The native handle (shared with the walk, lua/scenesync.lua); nil without the native core
local function getStore()
    if store == nil then
        local native = require("native")
        library = native.load()
        store = native.handle() or false
    end
    return store or nil
end
function stream.isBinaryAvailable()
    return getStore() ~= nil
end

local function putBox(at, box)
    boxes[at], boxes[at + 1], boxes[at + 2], boxes[at + 3] = box[1], box[2], box[3], box[4]
end
---A moved item's boxes into the numbers the store takes: its own, its clip's (NaN: none), each mask's
local function moveBoxes(item)
    local masks = item.mk
    local count = 8 + (masks and #masks or 0) * 4
    if count > boxesCapacity then
        boxesCapacity = count * 2
        boxes = ffi.new("double[?]", boxesCapacity)
    end
    boxes[0], boxes[1], boxes[2], boxes[3] = item.x, item.y, item.w, item.h
    if item.cl then
        putBox(4, item.cl)
    else
        boxes[4], boxes[5], boxes[6], boxes[7] = NAN, NAN, NAN, NAN
    end
    if masks then
        for index, mask in ipairs(masks) do
            putBox(4 + index * 4, mask.b)
        end
    end
    return count
end

---The changes since the last frame as a binary frame (src/ui/engine/binaryFrame.ts): its bytes as a string, or nil
---when nothing changed
function stream.encodeBinary(items)
    local scenes = getStore()
    local scene = package.loaded["scene"]
    local moveCounts = scene and scene.moveCounts or {}
    local pack = require("pack")
    library.sc_begin(scenes)
    local seen = {}
    for _, item in ipairs(items) do
        local key = keyOf(item)
        if seen[key] then
            -- (two items of one key: the later one keeps the key with a suffix, as in the JSON stream)
            local suffix = 2
            while seen[key .. "#" .. suffix] do
                suffix = suffix + 1
            end
            key = key .. "#" .. suffix
            item.i = item.i .. "#" .. suffix
        end
        seen[key] = true
        if lastTables[key] == item then
            local moveCount = moveCounts[item] or 0
            if moveCount ~= lastMoves[key] then
                library.sc_move(scenes, key, #key, boxes, moveBoxes(item))
                lastMoves[key] = moveCount
            else
                library.sc_same(scenes, key, #key)
            end
        else
            local bytes, length = pack.item(item)
            library.sc_item(scenes, key, #key, bytes, length)
            lastMoves[key] = moveCounts[item] or 0
            lastTables[key] = item
        end
    end
    for key in pairs(lastTables) do
        if not seen[key] then
            lastTables[key] = nil
            lastMoves[key] = nil
        end
    end
    local bytes = library.sc_end(scenes, lengthOut)
    local length = tonumber(lengthOut[0])
    if length == 0 then
        return nil
    end
    return ffi.string(bytes, length)
end

---The whole scene the page should hold, as a binary frame (a page that joins or fell behind)
function stream.encodeWholeBinary()
    local scenes = getStore() -- (first: it loads the library)
    local bytes = library.sc_whole(scenes, lengthOut)
    return ffi.string(bytes, tonumber(lengthOut[0]))
end

return stream
