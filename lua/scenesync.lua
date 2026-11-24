-- The scene's native walk (native/): its mirror of the widgets kept up to date, and each frame walked and laid out
-- there, with the Lua side making only what the walk asks for.
--
-- The mirror is told only what changed since the last frame: the objects whose setters said so (sim.markChanged,
-- through W.onChanged: their whole state again, anchors too), the drawing order when it changed, and every frame what
-- the whole scene depends on (the frame under the mouse, the one pressed, the focus, the font objects, the screen) and
-- the animations playing. The native side lays the objects out itself (native/src/layout.rs, asking this side to
-- measure texts), walks the scene and decides each region's fate (kept, moved, made again); for those made again
-- lua/scene.lua's own builders make the items, packed (lua/pack.lua) and handed back. ADDONSIM_NATIVE_WALK=0 keeps the
-- export in Lua (lua/stream.lua's binary path).
local ffi = require("ffi")
local sim = require("sim")
local W = require("widgets")

local scenesync = {}
local S = W.state

-- flags (native/src/graph.rs has the same)
local SHOWN = 0x1
local IS_ROOT = 0x2
local IGNORE_PARENT_ALPHA = 0x4
local CLIPS = 0x8
local FLATTENS = 0x10
local USE_PARENT_LEVEL = 0x20
local ENABLED = 0x40
local CHECKED = 0x80
local BUTTON_PUSHED = 0x100
local HAS_PUSHED = 0x200
local HAS_DISABLED = 0x400
local MOTION_WHILE_DISABLED = 0x800
local HIGHLIGHT_LOCKED = 0x1000
local DISABLED_CHECKED = 0x2000
local HAS_BACKDROP = 0x4000
local HAS_MESSAGES = 0x8000
local IS_UNITS = 0x10000
local IS_LIVE_COOLDOWN = 0x20000
local TIMER_BAR = 0x40000
local MAP_CANVAS = 0x80000
local PARENT_MAP_CANVAS = 0x100000
local EDIT_TEXT = 0x200000
local HIGHLIGHT_LAYER = 0x400000
local HAS_ART = 0x800000
local IGNORE_PARENT_SCALE = 0x1000000
local MADE_BY_CODE = 0x2000000
local COLLAPSES_LAYOUT = 0x4000000
local CLAMPED = 0x8000000
local HAS_ATLAS_SIZE = 0x10000000

local KINDS = { Texture = 2, FontString = 3, Line = 4, MaskTexture = 5 }
local ROLES = {
    normal = 1,
    pushed = 2,
    disabled = 3,
    highlight = 4,
    checkedTexture = 5,
    disabledChecked = 6,
    bar = 7,
    thumb = 8,
}
local POINTS = {
    TOPLEFT = 1,
    TOP = 2,
    TOPRIGHT = 3,
    LEFT = 4,
    CENTER = 5,
    RIGHT = 6,
    BOTTOMLEFT = 7,
    BOTTOM = 8,
    BOTTOMRIGHT = 9,
}
local EFFECT_ANY, EFFECT_TRANSFORM, EFFECT_ALPHA = 1, 2, 4

local library, handle
local record
local points, pointsCapacity = nil, 0
local dirty = {}
local isStarted = false
local toldOrder -- (the sorted list last told)
local orderIds, orderGroups, orderCapacity = nil, nil, 0
local kindOut, idOut = ffi.new("uint32_t[1]"), ffi.new("uint32_t[1]")
local lengthOut = ffi.new("size_t[1]")
local countsOut = ffi.new("uint32_t[4]")
local rectOut = ffi.new("double[4]")
local measure -- (the callback the native layout measures texts with: kept alive here)

---Whether the native walk makes the scene (the native core is built, and not turned off)
function scenesync.isAvailable()
    if os.getenv("ADDONSIM_NATIVE_WALK") == "0" then
        return false
    end
    local native = require("native")
    library = library or native.load()
    handle = handle or native.handle()
    return handle ~= nil
end

local function idOf(object)
    local s = object and S[object]
    return s and s.id or 0
end

local function flagsOf(s)
    local flags = 0
    if s.shown then
        flags = flags + SHOWN
    end
    if s.isRoot then
        flags = flags + IS_ROOT
    end
    if s.ignoreParentAlpha then
        flags = flags + IGNORE_PARENT_ALPHA
    end
    if s.ignoreParentScale then
        flags = flags + IGNORE_PARENT_SCALE
    end
    if s.isMadeByCode then
        flags = flags + MADE_BY_CODE
    end
    if s.collapsesLayout then
        flags = flags + COLLAPSES_LAYOUT
    end
    if s.isFrame then
        if s.clamped then
            flags = flags + CLAMPED
        end
        if s.clips then
            flags = flags + CLIPS
        end
        if s.flattensRenderLayers then
            flags = flags + FLATTENS
        end
        if s.useParentLevel then
            flags = flags + USE_PARENT_LEVEL
        end
        if s.enabled ~= false then
            flags = flags + ENABLED
        end
        if s.checked == true then
            flags = flags + CHECKED
        end
        if s.buttonState == "PUSHED" then
            flags = flags + BUTTON_PUSHED
        end
        if s.pushed then
            flags = flags + HAS_PUSHED
        end
        if s.disabled then
            flags = flags + HAS_DISABLED
        end
        if s.motionWhileDisabled then
            flags = flags + MOTION_WHILE_DISABLED
        end
        if s.highlightLocked == true then
            flags = flags + HIGHLIGHT_LOCKED
        end
        if s.disabledChecked then
            flags = flags + DISABLED_CHECKED
        end
        if s.backdrop then
            flags = flags + HAS_BACKDROP
        end
        if s.messages and s.isChat == nil and #s.messages > 0 then
            flags = flags + HAS_MESSAGES
        end
        if s.type == "UnitPositionFrame" then
            flags = flags + IS_UNITS
        end
        if (s.cooldown or s.blingAt) and s.type == "Cooldown" then
            flags = flags + IS_LIVE_COOLDOWN
        end
        if s.timer then
            flags = flags + TIMER_BAR
        end
        if s.isMapCanvas then
            flags = flags + MAP_CANVAS
        end
        local parentState = s.parent and S[s.parent]
        if parentState and parentState.isMapCanvas then
            flags = flags + PARENT_MAP_CANVAS
        end
    else
        if s.isEditText then
            flags = flags + EDIT_TEXT
        end
        if s.layer == "HIGHLIGHT" then
            flags = flags + HIGHLIGHT_LAYER
        end
        if s.texture or s.atlas then
            flags = flags + HAS_ART
        end
    end
    return flags
end

local function number(value)
    return tonumber(value) or 0
end

---An object's anchors, told
local function tellPoints(s)
    local list = s.points or {}
    local count = #list
    if count > pointsCapacity then
        pointsCapacity = count * 2
        points = ffi.new("AddonSimPoint[?]", pointsCapacity)
    end
    for index = 1, count do
        local anchor = list[index]
        local point = points[index - 1]
        point.relative = idOf(anchor.relative)
        point.point = POINTS[anchor.point] or 0
        point.relativePoint = POINTS[anchor.relativePoint] or 0
        point.x, point.y = number(anchor.x), number(anchor.y)
    end
    library.sg_points(handle, s.id, points, count)
end

---An object's whole state, told
local function tellObject(object)
    local s = S[object]
    if not s or not s.id then
        return
    end
    record.id = s.id
    record.parent = idOf(s.parent)
    record.scrollChildOf = idOf(s.scrollChildOf)
    record.visualVersion = s.visualVersion or 0
    local flags = flagsOf(s)
    record.sublevel = math.max(-2147483648, math.min(2147483647, math.floor(number(s.sublevel))))
    record.artOrder = s.artOrder or 0
    record.kind = s.isFrame and 1 or KINDS[s.type] or 6
    record.layer = W.LAYER_RANK[s.layer or "ARTWORK"] or 3
    record.role = s.role and (ROLES[s.role] or 9) or 0
    local masks = s.masks
    local maskCount = 0
    if masks then
        for index = 1, math.min(3, #masks) do
            record.masks[index - 1] = idOf(masks[index])
            maskCount = index
        end
    end
    record.maskCount = maskCount
    record.alpha = s.alpha or 1
    record.scale = s.scale or 1
    record.width, record.height = number(s.width), number(s.height)
    record.atlasWidth, record.atlasHeight = 0, 0
    -- (an atlas sizes a texture given no size of its own)
    if s.atlas and number(s.width) == 0 and number(s.height) == 0 and W.getAtlasInfo then
        local info = W.getAtlasInfo(s.atlas)
        if info then
            record.atlasWidth, record.atlasHeight = info.width, info.height
            flags = flags + HAS_ATLAS_SIZE
        end
    end
    record.flags = flags
    record.scrollX, record.scrollY = number(s.horizontalScroll), number(s.verticalScroll)
    library.sg_object(handle, record)
    tellPoints(s)
end

local function tellOrder(frames, groups)
    local count = #frames
    if count > orderCapacity then
        orderCapacity = count * 2
        orderIds = ffi.new("uint32_t[?]", orderCapacity)
        orderGroups = ffi.new("uint32_t[?]", orderCapacity)
    end
    for index = 1, count do
        orderIds[index - 1] = idOf(frames[index])
        orderGroups[index - 1] = groups[index]
    end
    library.sg_order(handle, orderIds, orderGroups, count)
    toldOrder = frames
end

---A text measured for the native layout: 1 its width, 2 its height (for a width, or none: NaN)
local function measureText(id, kind, width)
    local object = W.byId[id]
    local s = object and S[object]
    if not s then
        return 0
    end
    local fonts = require("fonts")
    local isDone, value = pcall(function()
        if kind == 1 then
            return fonts.measureWidth(s)
        end
        return fonts.measureHeight(s, width == width and width or nil)
    end)
    return isDone and tonumber(value) or 0
end

local function start()
    isStarted = true
    record = ffi.new("AddonSimObject")
    measure = ffi.cast("AddonSimMeasure", measureText)
    library.sg_set_measure(handle, measure)
    W.onChanged = function(object)
        dirty[object] = true
    end
    -- everything there is, told once
    for _, object in pairs(W.byId) do
        tellObject(object)
    end
    for object in pairs(dirty) do
        dirty[object] = nil
    end
end

local function sync()
    if not isStarted then
        start()
    end
    for object in pairs(dirty) do
        dirty[object] = nil
        tellObject(object)
    end
    local frames, groups = require("scene").getFrameGroups()
    if frames ~= toldOrder then
        tellOrder(frames, groups)
    end
    local mouseDown = sim.mouseDown
    library.sg_globals(
        handle,
        idOf(sim.motionFocus),
        mouseDown and idOf(mouseDown.frame) or 0,
        idOf(W.focus),
        require("fonts").version,
        sim.screenWidth,
        sim.screenHeight
    )
    library.sg_effects_clear(handle)
    for target, effect in pairs(require("animation").targets()) do
        local id = idOf(target)
        if id ~= 0 then
            local flags = EFFECT_ANY
            if effect.dx ~= 0 or effect.dy ~= 0 or effect.scaleX ~= 1 or effect.scaleY ~= 1 or effect.radians ~= 0 then
                flags = flags + EFFECT_TRANSFORM
            end
            local alpha = 1
            if effect.alpha then
                flags = flags + EFFECT_ALPHA
                alpha = effect.alpha
            end
            library.sg_effect(handle, id, flags, alpha)
        end
    end
end

-- Where the walk's frames spent their time since last asked (scenesync.takeTimes), in milliseconds: the mirror told,
-- the walk in Rust, the items made here, the frame put together; and how many regions were kept, moved, made
local times = { frames = 0, sync = 0, walk = 0, make = 0, finish = 0, kept = 0, moved = 0, made = 0 }
function scenesync.takeTimes()
    local taken = times
    times = { frames = 0, sync = 0, walk = 0, make = 0, finish = 0, kept = 0, moved = 0, made = 0 }
    return taken
end

---The last walk's counts: regions (and backdrops) kept, moved, made again; items dropped as a second of one key
function scenesync.counts()
    library.sg_counts(handle, countsOut, countsOut + 1, countsOut + 2, countsOut + 3)
    return countsOut[0], countsOut[1], countsOut[2], countsOut[3]
end

local items = {}
---A frame of the scene made by the walk: the binary frame of what changed (its bytes as a string), or nil
function scenesync.frame()
    local scene = require("scene")
    local pack = require("pack")
    local clock = sim.clock
    local started = clock()
    scene.beginExport()
    sync()
    local synced = clock()
    local count = library.sg_walk(handle)
    local walked = clock()
    for index = 0, count - 1 do
        library.sg_request(handle, index, kindOut, idOut)
        local object = W.byId[idOut[0]]
        for slot = #items, 1, -1 do
            items[slot] = nil
        end
        if object then
            local kind = kindOut[0]
            if kind == 1 then
                scene.buildRegion(items, object)
            elseif kind == 2 then
                scene.buildBefore(items, object)
            else
                scene.buildAfter(items, object)
            end
        end
        for _, item in ipairs(items) do
            local key = item.k .. item.i
            local bytes, length = pack.item(item)
            library.sg_submit(handle, index, key, #key, bytes, length)
        end
    end
    local made = clock()
    local bytes = library.sg_finish(handle, lengthOut)
    local length = tonumber(lengthOut[0])
    local finished = clock()
    local kept, moved, madeCount = scenesync.counts()
    times.frames = times.frames + 1
    times.sync = times.sync + (synced - started)
    times.walk = times.walk + (walked - synced)
    times.make = times.make + (made - walked)
    times.finish = times.finish + (finished - made)
    times.kept, times.moved, times.made = times.kept + kept, times.moved + moved, times.made + madeCount
    if length == 0 then
        return nil
    end
    return ffi.string(bytes, length)
end

---The native layout against the Lua one (ADDONSIM_CHECK_SCENE=1): every shown frame's and its regions' rectangles,
---the first that differs described, or nil
function scenesync.checkLayout()
    for _, frame in ipairs(require("scene").getSortedFrames()) do
        local s = S[frame]
        local objects = { frame }
        for _, region in ipairs(s and s.regions or {}) do
            objects[#objects + 1] = region
        end
        for _, object in ipairs(objects) do
            local state = S[object]
            local luaRect = W.computeRect(object)
            local hasNative = library.sg_layout_rect(handle, state.id, rectOut)
            if (luaRect ~= nil) ~= hasNative then
                return string.format(
                    "%s: %s in Lua, %s natively",
                    tostring(object.GetDebugName and object:GetDebugName() or state.id),
                    luaRect and "a rectangle" or "none",
                    hasNative and "a rectangle" or "none"
                )
            end
            if luaRect then
                for index = 1, 4 do
                    if math.abs(luaRect[index] - rectOut[index - 1]) > 0.001 then
                        return string.format(
                            "%s: edge %d %.4f in Lua, %.4f natively",
                            tostring(object.GetDebugName and object:GetDebugName() or state.id),
                            index,
                            luaRect[index],
                            rectOut[index - 1]
                        )
                    end
                end
            end
        end
    end
end

-- (the walk calls the text measure back into Lua: LuaJIT allows that only from a call it did not compile)
jit.off(scenesync.frame)
jit.off(scenesync.checkLayout)

return scenesync
