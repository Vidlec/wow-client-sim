-- The game's widgets: frames, textures, font strings and their kin, with anchors resolved into rectangles.
-- Each object is a plain table the addon owns; the simulator keeps its own state beside it (W.state), so an
-- addon's fields never meet ours. A missing method is nil, as in the game: calling it is an error, reported.
local sim = require("sim")
local fonts = require("fonts")

local W = {}
local state = setmetatable({}, { __mode = "k" })
W.state = state
-- (an object's visual version: what the scene's kept items of it were built at, lua/scene.lua)
-- (and the native walk's mirror is told: lua/scenesync.lua sets W.onChanged)
W.onChanged = nil
sim.markChanged = function(object)
    local s = state[object]
    if s then
        s.visualVersion = (s.visualVersion or 0) + 1
        local onChanged = W.onChanged
        if onChanged then
            onChanged(object)
        end
    end
end
W.byId = setmetatable({}, { __mode = "v" })
W.frames = {} -- every frame, in creation order (strong: frames live forever in the game)
function sim.getId(object)
    local s = state[object]
    return s and s.id or 0
end

local STRATA =
    { "WORLD", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
W.STRATA_RANK = {}
for index, name in ipairs(STRATA) do
    W.STRATA_RANK[name] = index
end
W.LAYER_RANK = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }

local touchLayoutOf -- (below, with the rectangle cache)

local POINT_X = {
    TOPLEFT = 0,
    LEFT = 0,
    BOTTOMLEFT = 0,
    TOP = 0.5,
    CENTER = 0.5,
    BOTTOM = 0.5,
    TOPRIGHT = 1,
    RIGHT = 1,
    BOTTOMRIGHT = 1,
}
local POINT_Y = {
    TOPLEFT = 1,
    TOP = 1,
    TOPRIGHT = 1,
    LEFT = 0.5,
    CENTER = 0.5,
    RIGHT = 0.5,
    BOTTOMLEFT = 0,
    BOTTOM = 0,
    BOTTOMRIGHT = 0,
}
-- Where two points set the same edge (the character window's right pane: TOPLEFT at the left pane's right edge,
-- BOTTOMLEFT at its left one), the client keeps the point that comes first in its order of points, not the one set last
local POINT_RANK =
    { TOPLEFT = 1, TOP = 2, TOPRIGHT = 3, LEFT = 4, CENTER = 5, RIGHT = 6, BOTTOMLEFT = 7, BOTTOM = 8, BOTTOMRIGHT = 9 }

local types = {} -- [name] = { methods, parent }
W.types = types

local function defineType(name, parentName, methods)
    local merged = {}
    if parentName then
        for key, value in pairs(types[parentName].methods) do
            merged[key] = value
        end
    end
    for key, value in pairs(methods or {}) do
        merged[key] = value
    end
    local chain = { [name] = true }
    if parentName then
        for typeName in pairs(types[parentName].chain) do
            chain[typeName] = true
        end
    end
    types[name] = {
        methods = merged,
        parent = parentName,
        chain = chain,
        meta = {
            __index = merged,
            __tostring = function()
                return name
            end,
        },
    }
    return merged
end
W.defineType = defineType

---The level a frame is drawn at: its own, or, inside a raised frame of its strata, that frame's raised level and as
---far above it as the frame is above that frame; and the raise it is drawn with (0: none)
function W.drawLevel(frame)
    local s = state[frame]
    local level = s and s.level or 0
    local current, depth = frame, 0
    local strata
    while current and depth < 60 do
        local cs = state[current]
        if not cs or cs.isRoot then
            break
        end
        if cs.raised then
            strata = strata or W.getStrata(frame)
            if W.getStrata(current) == strata then
                return (cs.raisedLevel and (cs.raisedLevel + level - (cs.level or 0))) or level, cs.raised
            end
        end
        current, depth = cs.parent, depth + 1
    end
    return level, 0
end

---Whether a frame takes clicks, and the mouse's movement (OnEnter, OnLeave): each channel as set on its own, else as
---the mouse as a whole (EnableMouse)
function W.takesClicks(s)
    if s.mouseClick ~= nil then
        return s.mouseClick
    end
    return s.mouse == true
end
function W.takesMotion(s)
    if s.mouseMotion ~= nil then
        return s.mouseMotion
    end
    return s.mouse == true
end

---A texture's wrap mode as SetTexture or the XML names it, in capitals; nil for none (the client's default, CLAMP).
---A true (the old API's "repeat") is REPEAT
function W.wrapMode(mode)
    if mode == true then
        return "REPEAT"
    end
    if type(mode) ~= "string" or mode == "" then
        return nil
    end
    return mode:upper()
end

---Whether a button acts on this click ("Up" or "Down"): what it registered (lower case: RegisterForClicks), the
---left button's release when it registered nothing
function W.isClickRegistered(s, button, phase)
    local clicks = s.clicks or { leftbuttonup = true }
    return clicks[(tostring(button) .. phase):lower()] == true or clicks["any" .. phase:lower()] == true
end

local function S(object)
    -- (else a stand-in for a frame: { [0] = frame[0], [1] = frame } with the frame's methods, as the restricted
    -- environment makes for its frame handles; the client finds the frame by its [0], so here too)
    return state[object] or (type(object) == "table" and state[rawget(object, 0)]) or nil
end

local function getCreator()
    local xmlui = package.loaded["xmlui"]
    if xmlui then
        local isBuilding, creator = xmlui.getBuild()
        if isBuilding then
            return creator
        end
    end
    return sim.getCallingAddon()
end

local function newObject(typeName, name, parent)
    local definition = types[typeName]
    local object = setmetatable({}, definition.meta)
    local id = sim.newId()
    state[object] = {
        id = id,
        type = typeName,
        name = name,
        parent = parent,
        points = {},
        shown = true,
        alpha = 1,
        scale = 1,
        scripts = {},
        children = {},
        regions = {},
        creator = getCreator(), -- the addon whose code made it (nil: the simulator's own)
    }
    object[0] = object -- the game puts its userdata here; some addons look for it
    W.byId[id] = object
    sim.markChanged(object) -- (new: the native walk's mirror learns of it)
    return object, state[object]
end
W.newObject = newObject

local function resolveRelative(relative)
    if type(relative) == "string" then
        return sim.G[relative]
    end
    return relative
end

-- Object
local objectMethods = {
    GetName = function(self)
        return S(self).name
    end,
    GetObjectType = function(self)
        return S(self).type
    end,
    -- The object's public table (the game's aura containers hand it to an addon's initializeFrame): the simulator's
    -- objects are their own
    GetObjectTable = function(self)
        return self
    end,
    IsObjectType = function(self, typeName)
        return types[S(self).type].chain[typeName] == true
    end,
    GetParent = function(self)
        return S(self).parent
    end,
    GetDebugName = function(self)
        return S(self).name or (S(self).type .. "#" .. S(self).id)
    end,
    IsForbidden = function(self)
        return S(self).isForbidden == true
    end,
    SetForbidden = function(self)
        S(self).isForbidden = true
    end,
    -- Art the simulator draws is there at once (the map canvas waits on this before showing its tiles)
    IsObjectLoaded = function()
        return true
    end,
    -- (protected, explicitly): a frame of a protected template (SecureFrameTemplate...) is both; the rest neither
    IsProtected = function(self)
        local state = S(self)
        local isProtected = state ~= nil and state.isProtected == true
        return isProtected, isProtected
    end,
}
defineType("Object", nil, objectMethods)

-- Region: anything placed on screen
local function setPoint(self, point, relative, relativePoint, x, y)
    local s = S(self)
    point = (point or "CENTER"):upper()
    if type(relative) == "number" then
        relative, relativePoint, x, y = nil, nil, relative, relativePoint
    elseif type(relativePoint) == "number" then
        -- SetPoint(point, relativeTo, x, y): the same point on the other frame
        relativePoint, x, y = nil, relativePoint, x
    end
    if type(relative) == "string" and POINT_X[relative:upper()] and relativePoint == nil then
        relative, relativePoint = nil, relative
    end
    relative = resolveRelative(relative)
    if relative == nil then
        -- With no frame named: the parent, else UIParent, else (UIParent itself, which the game moves down from the
        -- screen's top for a notch) the screen
        relative = s.parent or sim.G.UIParent
        if relative == self then
            relative = nil
        end
    end
    if relative ~= nil and relative == self then
        error("Cannot anchor to itself", 2)
    end
    relativePoint = (relativePoint or point):upper()
    for index, existing in ipairs(s.points) do
        if existing.point == point then
            table.remove(s.points, index)
            break
        end
    end
    s.points[#s.points + 1] =
        { point = point, relative = relative, relativePoint = relativePoint, x = x or 0, y = y or 0 }
    touchLayoutOf(self)
end

---Keeps the children drawn at their parent's level (useParentLevel) at it, and theirs.
function W.liftChildren(frame)
    local s = S(frame)
    local level = s.level or 0
    for _, child in ipairs(s.children or {}) do
        local childState = S(child)
        if childState and childState.useParentLevel then
            -- (drawn at its parent's level: its layers among the parent's, a tooltip's border and background under
            -- the tooltip's text)
            if childState.level ~= level then
                childState.level = level
                W.touchOrder()
            end
            W.liftChildren(child)
        elseif childState then
            -- (any other child keeps its own level, even at or below its parent's, as in the client: EllesmereUI's
            -- minimap indicators hold a backdrop one level below the button, behind its icon; its game menu buttons a
            -- frame of their own level, behind their text. Measured: a parent's level change moves its children by
            -- as much, nothing more)
            W.liftChildren(child)
        end
    end
end

-- (kept while the layout stands: scale, parent and ignoreParentScale change it, and their setters touch the layout)
local scaleCache, scaleCacheVersion = {}, -1
---The scale the object is drawn at, against the screen.
local function getEffectiveScale(object)
    if scaleCacheVersion ~= sim.layoutVersion then
        scaleCache, scaleCacheVersion = {}, sim.layoutVersion
    end
    local cached = scaleCache[object]
    if cached then
        return cached
    end
    local s = S(object)
    if not s then
        return 1
    end
    local result
    if s.isRoot then
        result = s.scale
    else
        local parent = s.parent
        local parentScale = parent and getEffectiveScale(parent) or 1
        if s.ignoreParentScale then
            parentScale = 1
        end
        result = s.scale * parentScale
    end
    scaleCache[object] = result
    return result
end
W.getEffectiveScale = getEffectiveScale

-- Rectangles, in screen units with y up: { left, bottom, right, top }. Cached until anything changes.
local rectCache, rectCacheVersion, computing = {}, -1, {}
-- [object] = { [object worked out from its rectangle] = true }, recorded as rectangles are computed: an object
-- changed throws away its own and theirs (and theirs, on down), and every other rectangle stays
local dependents = {}
local function addDependent(source, object)
    local list = dependents[source]
    if not list then
        list = {}
        dependents[source] = list
    end
    list[object] = true
end
-- The objects whose rectangles were thrown away since the size watchers were last looked at (W.fireSizeChanges): only
-- those can have changed size, and only those are measured again
local droppedRects = {}
local function invalidateRect(object)
    rectCache[object] = nil
    droppedRects[object] = true
    local list = dependents[object]
    if list then
        dependents[object] = nil
        for dependent in pairs(list) do
            invalidateRect(dependent)
        end
    end
end
touchLayoutOf = function(object)
    sim.version = sim.version + 1
    sim.layoutChanges = sim.layoutChanges + 1
    sim.markChanged(object)
    if rectCacheVersion == sim.layoutVersion then
        invalidateRect(object)
    end
end
W.touchLayoutOf = touchLayoutOf

local computeRect
local function getNaturalSize(object)
    local s = S(object)
    -- A region that collapses the layout takes no room while hidden: what is anchored to it closes up, as in the
    -- client (a nameplate's raid mark: with none, the elite ornament stands right against the bar)
    if s.collapsesLayout and not s.shown then
        return 0, 0
    end
    local scale = getEffectiveScale(object)
    if s.type == "FontString" and (not s.width or s.width == 0) then
        local width = fonts.measureWidth(s)
        return width * scale, (s.height and s.height > 0 and s.height or fonts.measureHeight(s, nil)) * scale
    end
    if s.type == "FontString" and (not s.height or s.height == 0) then
        return s.width * scale, fonts.measureHeight(s, s.width) * scale
    end
    -- A texture given no size takes its atlas's, as in the client (the action button's icon mask: an atlas and one
    -- anchor, nothing else)
    if (not s.width or s.width == 0) and (not s.height or s.height == 0) and s.atlas and W.getAtlasInfo then
        local info = W.getAtlasInfo(s.atlas)
        if info then
            return info.width * scale, info.height * scale
        end
    end
    return (s.width or 0) * scale, (s.height or 0) * scale
end

local NO_POINTS = {}
computeRect = function(object)
    if rectCacheVersion ~= sim.layoutVersion then
        -- (computing too: an object whose working out failed, a bad anchor say, is not "in a circle" for good)
        rectCache, rectCacheVersion, dependents, computing = {}, sim.layoutVersion, {}, {}
    end
    local cached = rectCache[object]
    if cached ~= nil then
        return cached or nil
    end
    local s = S(object)
    if not s then
        return nil
    end
    -- A texture an addon's code makes (CreateTexture, no template) has no place until it is given points: it is not
    -- drawn meanwhile, as in the client (EllesmereUI makes its title-bar glyphs so and places them only once a theme
    -- box is painted: over the whole window, they were three white blurs across its settings)
    if s.isMadeByCode and #s.points == 0 then
        rectCache[object] = false
        return nil
    end
    if s.isRoot then
        local rect = { 0, 0, sim.screenWidth, sim.screenHeight }
        rectCache[object] = rect
        return rect
    end
    if computing[object] then
        return nil -- anchored in a circle
    end
    computing[object] = true
    local scale = getEffectiveScale(object)
    local left, right, centerX, bottom, top, centerY
    local leftRank, rightRank, centerXRank, bottomRank, topRank, centerYRank = 99, 99, 99, 99, 99, 99
    if s.scrollChildOf then
        -- A scroll frame's child hangs from its top left, moved by the scroll
        local frameRect = computeRect(s.scrollChildOf)
        addDependent(s.scrollChildOf, object)
        local frameState = S(s.scrollChildOf)
        if frameRect then
            left = frameRect[1] - (frameState.horizontalScroll or 0) * scale
            top = frameRect[4] + (frameState.verticalScroll or 0) * scale
        end
    end
    -- (the scroll frame alone places its child, as in the client: the child's own anchors are not used, the world map's
    -- canvas has a TOPLEFT one that would pin it in place whatever the scroll)
    for _, anchor in ipairs((s.scrollChildOf and left) and NO_POINTS or s.points) do
        local relativeRect = anchor.relative and computeRect(anchor.relative)
        if anchor.relative then
            addDependent(anchor.relative, object)
        end
        if relativeRect then
            local x = relativeRect[1]
                + (relativeRect[3] - relativeRect[1]) * POINT_X[anchor.relativePoint]
                + anchor.x * scale
            local y = relativeRect[2]
                + (relativeRect[4] - relativeRect[2]) * POINT_Y[anchor.relativePoint]
                + anchor.y * scale
            local pointX, pointY = POINT_X[anchor.point], POINT_Y[anchor.point]
            local rank = POINT_RANK[anchor.point] or 9
            if pointX == 0 then
                if rank < leftRank then
                    left, leftRank = x, rank
                end
            elseif pointX == 1 then
                if rank < rightRank then
                    right, rightRank = x, rank
                end
            elseif rank < centerXRank then
                centerX, centerXRank = x, rank
            end
            if pointY == 0 then
                if rank < bottomRank then
                    bottom, bottomRank = y, rank
                end
            elseif pointY == 1 then
                if rank < topRank then
                    top, topRank = y, rank
                end
            elseif rank < centerYRank then
                centerY, centerYRank = y, rank
            end
        end
    end
    -- A texture given no anchors is drawn on its parent, as the client does: centred at its own size, or over the
    -- whole parent when it has none (the minimap's zone button draws its bar so, an atlas sized by useAtlasSize)
    -- (a font string too: the gamepad's button legend writes each label in a string with no anchors, over its frame)
    local objectType = #s.points == 0 and object.GetObjectType and object:GetObjectType()
    if
        #s.points == 0
        and not s.scrollChildOf
        and s.parent
        and (objectType == "Texture" or objectType == "FontString")
    then
        local parentRect = computeRect(s.parent)
        addDependent(s.parent, object)
        if parentRect then
            -- (a size set, or its atlas's when asked for, useAtlasSize; an atlas alone does not size it: the gamepad's
            -- focus glow, a nine-slice atlas over its whole frame)
            local width, height = (s.width or 0) * scale, (s.height or 0) * scale
            if (width or 0) > 0 and (height or 0) > 0 then
                -- Its own size (set, or its atlas's) round the parent's centre
                centerX, centerY = (parentRect[1] + parentRect[3]) / 2, (parentRect[2] + parentRect[4]) / 2
            else
                left, bottom, right, top = parentRect[1], parentRect[2], parentRect[3], parentRect[4]
            end
        end
    end
    local hasHorizontal = left or right or centerX
    local hasVertical = top or bottom or centerY
    local rect
    if hasHorizontal and hasVertical then
        local naturalWidth, naturalHeight
        local function getNatural()
            if not naturalWidth then
                naturalWidth, naturalHeight = getNaturalSize(object)
            end
            return naturalWidth, naturalHeight
        end
        if left and right then
            -- width from the anchors; a font string then wraps to it
        else
            local width = getNatural()
            if left then
                right = left + width
            elseif right then
                left = right - width
            else
                left, right = centerX - width / 2, centerX + width / 2
            end
        end
        if not (top and bottom) then
            local height
            if s.type == "FontString" and not (s.height and s.height > 0) then
                height = fonts.measureHeight(s, (right - left) / scale) * scale
            else
                local _, naturalHeightValue = getNatural()
                height = naturalHeightValue
            end
            if top then
                bottom = top - height
            elseif bottom then
                top = bottom + height
            else
                bottom, top = centerY - height / 2, centerY + height / 2
            end
        end
        rect = { left, bottom, right, top }
        -- Kept on the screen when clamped, as the client keeps it (a tall tooltip over a row near the top: moved
        -- down whole rather than cut off); what hangs from it moves with it
        if s.clamped and s.isFrame then
            local dx, dy = 0, 0
            if right > sim.screenWidth then
                dx = sim.screenWidth - right
            end
            if left + dx < 0 then
                dx = -left
            end
            if top > sim.screenHeight then
                dy = sim.screenHeight - top
            end
            if bottom + dy < 0 and top - bottom <= sim.screenHeight then
                dy = -bottom
            end
            if dx ~= 0 or dy ~= 0 then
                rect = { left + dx, bottom + dy, right + dx, top + dy }
            end
        end
    end
    computing[object] = nil
    rectCache[object] = rect or false
    return rect
end
W.computeRect = computeRect

local function getRectInOwnUnits(self)
    local rect = computeRect(self)
    if not rect then
        return nil
    end
    local scale = getEffectiveScale(self)
    return rect[1] / scale, rect[2] / scale, rect[3] / scale, rect[4] / scale
end

-- Shown, and every parent too: worked out once while nothing is shown, hidden or given another parent
-- (W.touchVisibility). The game's clock asks it of every frame with an OnUpdate each frame, and addons ask it often:
-- walking up the parents each time was half of a frame's tick with EllesmereUI.
local visibleCache, visibleVersion, visibleCacheVersion = {}, 0, -1
function W.touchVisibility()
    visibleVersion = visibleVersion + 1
end
local isVisible
isVisible = function(object)
    if visibleCacheVersion ~= visibleVersion then
        visibleCache, visibleCacheVersion = {}, visibleVersion
    end
    local cached = visibleCache[object]
    if cached ~= nil then
        return cached
    end
    local s = S(object)
    local result
    if not s then
        result = true
    elseif not s.shown then
        result = false
    elseif s.isRoot or not s.parent then
        result = true
    else
        result = isVisible(s.parent)
    end
    visibleCache[object] = result
    return result
end
W.isVisible = isVisible

-- The frames' drawing order changed (one shown or hidden, made, moved to another parent, another strata or level,
-- raised): the scene's sorted list of frames is made again (scene.getSortedFrames), not at every change of a texture
function W.touchOrder()
    sim.orderVersion = (sim.orderVersion or 0) + 1
end

local function setShown(self, isShown)
    local s = S(self)
    isShown = isShown and true or false
    if s.shown == isShown then
        return
    end
    local wasVisible = isVisible(self)
    s.shown = isShown
    W.touchVisibility()
    sim.touchVisual(self)
    if s.collapsesLayout then
        touchLayoutOf(self)
    end -- (its room comes or goes: what hangs from it moves)
    local nowVisible = isVisible(self)
    -- (the frames drawn change only when it comes into sight or goes: under a hidden parent, nothing does)
    if s.isFrame and wasVisible ~= nowVisible then
        W.touchOrder()
    end
    -- A toplevel frame comes to the front of its strata as it is shown (the map, a panel), as in the client
    if isShown and s.toplevel and s.isFrame then
        self:Raise()
    end
    if wasVisible ~= nowVisible then
        W.propagateVisibility(self, nowVisible)
    end
end

---The nearest toplevel frame from this one up, which a click brings to the front.
function W.raiseToplevelOf(frame)
    local current, depth = frame, 0
    while current and depth < 60 do
        local state = S(current)
        if not state then
            return
        end
        if state.toplevel and state.isFrame then
            current:Raise()
            return
        end
        current, depth = state.parent, depth + 1
    end
end

---OnShow and OnHide run for a frame and every child whose visibility changed with it, as in the game.
function W.propagateVisibility(object, isNowVisible)
    local s = S(object)
    if s.isFrame then
        -- An edit box that is hidden lets go of the keyboard, as in the game (a report closed with Escape from its
        -- copy box: the next key goes to the game again)
        if not isNowVisible and W.focus == object then
            W.setFocus(nil)
        end
        -- The children shown as it changed, taken before its own script runs: a child its OnHide hides in turn (the
        -- map's hiding an addon's window) was visible when the parent went, and hears its OnHide, as in the client
        -- The children's scripts run before the frame's own, deepest first, showing and hiding alike, as the client
        -- runs them (measured in the game: /asrec probe, a window, its child and grandchild -> grandchild, child,
        -- window). The guild window's OnShow reads the list its child filled in its own OnShow.
        local shownChildren = {}
        for _, child in ipairs(s.children) do
            if S(child).shown then
                shownChildren[#shownChildren + 1] = child
            end
        end
        for _, child in ipairs(shownChildren) do
            if isNowVisible == false or S(child).shown then
                W.propagateVisibility(child, isNowVisible)
            end
        end
        -- (its textures' and font strings' own, those that have them)
        for _, region in ipairs(s.regions or {}) do
            local rs = S(region)
            if rs and rs.scripts and rs.shown then
                W.propagateVisibility(region, isNowVisible)
            end
        end
        sim.runScript(object, isNowVisible and "OnShow" or "OnHide")
    elseif s.scripts then
        local handler = s.scripts[isNowVisible and "OnShow" or "OnHide"]
        if handler then
            sim.call(handler, object)
        end
    end
end

local regionMethods = {
    SetPoint = setPoint,
    ClearAllPoints = function(self)
        local s = S(self)
        if #s.points == 0 then
            return
        end
        s.points = {}
        touchLayoutOf(self)
    end,
    ClearPoint = function(self, point)
        local s = S(self)
        for index, anchor in ipairs(s.points) do
            if anchor.point == point then
                table.remove(s.points, index)
                break
            end
        end
        touchLayoutOf(self)
    end,
    SetAllPoints = function(self, relative, doResize)
        relative = resolveRelative(relative) or S(self).parent or sim.G.UIParent
        local s = S(self)
        s.points = {}
        setPoint(self, "TOPLEFT", relative, "TOPLEFT", 0, 0)
        setPoint(self, "BOTTOMRIGHT", relative, "BOTTOMRIGHT", 0, 0)
    end,
    GetPoint = function(self, index)
        local anchor = S(self).points[index or 1]
        if anchor then
            return anchor.point, anchor.relative, anchor.relativePoint, anchor.x, anchor.y
        end
    end,
    GetPointByName = function(self, point)
        for _, anchor in ipairs(S(self).points) do
            if anchor.point == point then
                return anchor.point, anchor.relative, anchor.relativePoint, anchor.x, anchor.y
            end
        end
    end,
    GetNumPoints = function(self)
        return #S(self).points
    end,
    AdjustPointsOffset = function(self, x, y)
        for _, anchor in ipairs(S(self).points) do
            anchor.x, anchor.y = anchor.x + (x or 0), anchor.y + (y or 0)
        end
        touchLayoutOf(self)
    end,
    SetPointsOffset = function(self, x, y)
        for _, anchor in ipairs(S(self).points) do
            anchor.x, anchor.y = x or 0, y or 0
        end
        touchLayoutOf(self)
    end,
    SetSize = function(self, width, height)
        local s = S(self)
        height = height or width
        if s.width == width and s.height == height then
            return
        end
        s.width, s.height = width, height
        touchLayoutOf(self)
    end,
    SetWidth = function(self, width)
        local s = S(self)
        if s.width == width then
            return
        end
        s.width = width
        touchLayoutOf(self)
    end,
    SetHeight = function(self, height)
        local s = S(self)
        if s.height == height then
            return
        end
        s.height = height
        touchLayoutOf(self)
    end,
    GetWidth = function(self)
        -- A font string with no anchors and no width set measures its own text, as in the client, though it is
        -- drawn over its parent: the gamepad's prompts size their label's frame from it (it measured the frame, so
        -- a longer label kept the shorter one's room and ran into the next prompt)
        local s = S(self)
        if s.type == "FontString" and #s.points == 0 and not (s.width and s.width > 0) then
            local width = getNaturalSize(self)
            return width / getEffectiveScale(self)
        end
        local left, _, right = getRectInOwnUnits(self)
        if left then
            return right - left
        end
        local width = getNaturalSize(self)
        return width / getEffectiveScale(self)
    end,
    GetHeight = function(self)
        local _, bottom, _, top = getRectInOwnUnits(self)
        if bottom then
            return top - bottom
        end
        local _, height = getNaturalSize(self)
        return height / getEffectiveScale(self)
    end,
    GetSize = function(self)
        return self:GetWidth(), self:GetHeight()
    end,
    GetLeft = function(self)
        local left = getRectInOwnUnits(self)
        return left
    end,
    GetRight = function(self)
        local _, _, right = getRectInOwnUnits(self)
        return right
    end,
    GetTop = function(self)
        local _, _, _, top = getRectInOwnUnits(self)
        return top
    end,
    GetBottom = function(self)
        local _, bottom = getRectInOwnUnits(self)
        return bottom
    end,
    GetCenter = function(self)
        local left, bottom, right, top = getRectInOwnUnits(self)
        if left then
            return (left + right) / 2, (bottom + top) / 2
        end
    end,
    GetRect = function(self)
        local left, bottom, right, top = getRectInOwnUnits(self)
        if left then
            return left, bottom, right - left, top - bottom
        end
    end,
    GetScaledRect = function(self)
        local rect = computeRect(self)
        if rect then
            return rect[1], rect[2], rect[3] - rect[1], rect[4] - rect[2]
        end
    end,
    IsRectValid = function(self)
        return computeRect(self) ~= nil
    end,
    IsAnchoringRestricted = function()
        return false
    end,
    Show = function(self)
        setShown(self, true)
    end,
    Hide = function(self)
        setShown(self, false)
    end,
    SetShown = function(self, isShown)
        setShown(self, isShown)
    end,
    SetCollapsesLayout = function(self, isCollapsing)
        S(self).collapsesLayout = isCollapsing and true or nil
        touchLayoutOf(self)
    end,
    GetCollapsesLayout = function(self)
        return S(self).collapsesLayout == true
    end,
    IsShown = function(self)
        return S(self).shown
    end,
    IsVisible = function(self)
        return isVisible(self)
    end,
    SetAlpha = function(self, alpha)
        S(self).alpha = math.max(0, math.min(1, alpha or 1))
        sim.touchVisual(self)
    end,
    -- (an Alpha animation's while one plays on it: measured, a frame of 0.5 reads 0.6 at 40% of a fade from 1 to 0)
    GetAlpha = function(self)
        local animation = package.loaded["animation"]
        local live = animation and animation.liveAlphaOf(self)
        return live or S(self).alpha
    end,
    GetEffectiveAlpha = function(self)
        local alpha, object = 1, self
        local animation = package.loaded["animation"]
        while object and S(object) do
            alpha = alpha * ((animation and animation.liveAlphaOf(object)) or S(object).alpha)
            if S(object).ignoreParentAlpha then
                break
            end
            object = S(object).parent
        end
        return alpha
    end,
    SetIgnoreParentAlpha = function(self, isIgnored)
        S(self).ignoreParentAlpha = isIgnored
        sim.touchVisual(self)
    end,
    IsIgnoringParentAlpha = function(self)
        return S(self).ignoreParentAlpha == true
    end,
    IsIgnoringParentScale = function(self)
        return S(self).ignoreParentScale == true
    end,
    -- One alpha or another by a boolean (the client's way round a secret value)
    SetAlphaFromBoolean = function(self, value, alphaIfTrue, alphaIfFalse)
        self:SetAlpha(value and (alphaIfTrue or 1) or (alphaIfFalse or 0))
    end,
    -- The mouse: clicks and movement passed on to what is under it as well (kept: the simulator gives each to the
    -- topmost frame alone)
    SetPropagateMouseClicks = function(self, isOn)
        S(self).propagateClicks = isOn and true or false
    end,
    GetPropagateMouseClicks = function(self)
        return S(self).propagateClicks == true
    end,
    SetPropagateMouseMotion = function(self, isOn)
        S(self).propagateMotion = isOn and true or false
    end,
    GetPropagateMouseMotion = function(self)
        return S(self).propagateMotion == true
    end,
    EnableMouseMotion = function(self, isOn)
        S(self).mouseMotion = isOn and true or false
    end,
    -- A texture's or font string's scripts (OnShow, OnHide; a frame has its own, below)
    SetScript = function(self, script, handler)
        local s = S(self)
        s.scripts = s.scripts or {}
        s.scripts[script] = handler
    end,
    GetScript = function(self, script)
        local scripts = S(self).scripts
        return scripts and scripts[script]
    end,
    HookScript = function(self, script, handler)
        local s = S(self)
        s.scripts = s.scripts or {}
        local before = s.scripts[script]
        s.scripts[script] = before and function(...)
            before(...)
            handler(...)
        end or handler
        return true
    end,
    HasScript = function(_, script)
        return script == "OnShow" or script == "OnHide"
    end,
    SetIgnoreParentScale = function(self, isIgnored)
        isIgnored = isIgnored and true or false
        if (S(self).ignoreParentScale or false) == isIgnored then
            return
        end
        S(self).ignoreParentScale = isIgnored
        sim.touch(self)
    end,
    -- A number written as text is taken, as by the client (the game's XML gives KeyValue scales as text: ".75")
    SetScale = function(self, scale)
        scale = tonumber(scale)
        scale = (scale and scale > 0) and scale or 1
        -- (the same again changes nothing: EllesmereUI's pixel-perfect code sets its scales over and over, and each
        -- time every rectangle was worked out anew)
        if S(self).scale == scale then
            return
        end
        S(self).scale = scale
        sim.touch(self)
    end,
    GetScale = function(self)
        return S(self).scale
    end,
    GetEffectiveScale = function(self)
        return getEffectiveScale(self)
    end,
    -- The key the object has on its parent (parent[key] = object), as parentKey in XML gives it; set from Lua too
    -- (the raid frame manager's raid marker buttons are found so: raidMarkers["raidMarker" .. i])
    SetParentKey = function(self, key, clearOtherKeys)
        local s = S(self)
        local parent = s.parent
        if parent and clearOtherKeys then
            for otherKey, value in pairs(parent) do
                if value == self and type(otherKey) == "string" then
                    parent[otherKey] = nil
                end
            end
        end
        s.parentKey = key
        if parent and key then
            parent[key] = self
        end
    end,
    GetParentKey = function(self)
        return S(self).parentKey
    end,
    SetParent = function(self, parent)
        parent = resolveRelative(parent)
        local s = S(self)
        -- The game refuses a parent that is the object itself or one of its own children
        local ancestor = parent
        while ancestor do
            if ancestor == self then
                error("SetParent: Cannot set parent to itself or a descendant", 2)
            end
            ancestor = S(ancestor) and S(ancestor).parent
        end
        local old = s.parent
        if old and S(old) then
            local list = s.isFrame and S(old).children or S(old).regions
            for index, item in ipairs(list) do
                if item == self then
                    table.remove(list, index)
                    break
                end
            end
        end
        s.parent = parent
        W.touchVisibility()
        if parent and S(parent) then
            local list = s.isFrame and S(parent).children or S(parent).regions
            list[#list + 1] = self
            if s.isFrame and not s.levelSet then
                s.level = (S(parent).level or 0) + 1
            end
            if s.isFrame then
                W.liftChildren(parent)
            end
        end
        W.touchOrder()
        sim.parentVersion = (sim.parentVersion or 0) + 1 -- (the scene's walk from the top frames, scene.getSortedFrames)
        sim.touch(self)
    end,
    -- The offsets move each edge, as the client takes them: (10, -10, -10, 10) grows the area by 10 all round
    IsMouseOver = function(self, top, bottom, left, right)
        local rect = computeRect(self)
        local mouse = sim.mouse
        if not rect or not mouse then
            return false
        end
        return mouse.x >= rect[1] + (left or 0)
            and mouse.x <= rect[3] + (right or 0)
            and mouse.y >= rect[2] + (bottom or 0)
            and mouse.y <= rect[4] + (top or 0)
    end,
    IsMouseMotionFocus = function(self)
        return sim.motionFocus == self
    end,
    CreateAnimationGroup = function(self, name, template)
        local group = W.createAnimationGroup(self, name)
        local state = S(self)
        state.animationGroups = state.animationGroups or {}
        table.insert(state.animationGroups, group)
        local xmlui = template and package.loaded["xmlui"]
        if xmlui then
            xmlui.applyAnimationGroupTemplates(group, template)
        end
        return group
    end,
    GetAnimationGroups = function(self)
        return unpack(S(self).animationGroups or {})
    end,
    -- Every group it owns stopped (the client: and its children's, for a frame)
    StopAnimating = function(self)
        for _, group in ipairs(S(self).animationGroups or {}) do
            if group:IsPlaying() or group:IsPaused() then
                group:Stop()
            end
        end
    end,
    IsAnimating = function(self)
        for _, group in ipairs(S(self).animationGroups or {}) do
            if group:IsPlaying() then
                return true
            end
        end
        return false
    end,
    SetSnapToPixelGrid = function() end,
    SetTexelSnappingBias = function() end,
    GetSourceLocation = function()
        return nil
    end,
}
defineType("Region", "Object", regionMethods)

-- Layered regions: textures, font strings, lines
local layeredMethods = {
    SetDrawLayer = function(self, layer, sublevel)
        local s = S(self)
        s.layer, s.sublevel = layer or "ARTWORK", sublevel or 0
        sim.touchVisual(self) -- (the order its frame's regions are drawn in, sorted as the scene is drawn)
    end,
    GetDrawLayer = function(self)
        return S(self).layer, S(self).sublevel
    end,
    SetVertexColor = function(self, r, g, b, a)
        S(self).vertexColor = { r or 1, g or 1, b or 1, a or 1 }
        sim.touchVisual(self)
    end,
    GetVertexColor = function(self)
        local color = S(self).vertexColor or { 1, 1, 1, 1 }
        return color[1], color[2], color[3], color[4]
    end,
}
defineType("LayeredRegion", "Region", layeredMethods)

local function unpackColor(r, g, b, a)
    if type(r) == "table" then
        return r.r or r[1] or 1, r.g or r[2] or 1, r.b or r[3] or 1, r.a or r[4] or 1
    end
    return r or 1, g or 1, b or 1, a or 1
end
W.unpackColor = unpackColor

-- When a texture last got new art: of two in the same layer and sublevel, the one given its art later is drawn on top,
-- as the client draws an action button's icon (set when the slot fills) over the empty-slot art made with the button
local artCounter = 0
local function noteArt(s, isChanged)
    if isChanged then
        artCounter = artCounter + 1
        s.artOrder = artCounter
    end
end

local textureMethods = {
    SetTexture = function(self, texture, horizontalWrap, verticalWrap, filter)
        local s = S(self)
        noteArt(s, texture ~= s.texture)
        local hadAtlas = s.atlas ~= nil
        s.texture, s.color, s.atlas = texture, nil, nil
        -- How it is read past its edges (CLAMP, REPEAT, MIRROR, CLAMPTOBLACKADDITIVE, CLAMPTOWHITE): a mask cuts what
        -- lies beyond its box, or lets it be, by it (EllesmereUI's borders: a rounded hole that is white outside)
        s.wrapH, s.wrapV = W.wrapMode(horizontalWrap), W.wrapMode(verticalWrap)
        if hadAtlas then
            touchLayoutOf(self)
        else
            sim.touchVisual(self)
        end
        return texture ~= nil
    end,
    GetTexture = function(self)
        return S(self).texture
    end,
    GetTextureFilePath = function(self)
        return S(self).texture
    end,
    GetTextureFileID = function(self)
        local texture = S(self).texture
        return type(texture) == "number" and texture or nil
    end,
    SetColorTexture = function(self, r, g, b, a)
        local s = S(self)
        noteArt(s, s.color == nil)
        local hadAtlas = s.atlas ~= nil
        s.color, s.texture, s.atlas = { unpackColor(r, g, b, a) }, nil, nil
        if hadAtlas then
            touchLayoutOf(self)
        else
            sim.touchVisual(self)
        end
    end,
    SetAtlas = function(self, atlas, useAtlasSize)
        local s = S(self)
        noteArt(s, atlas ~= s.atlas)
        s.atlas, s.texture, s.color = atlas, nil, nil
        s.texCoord = nil
        local info = W.getAtlasInfo and W.getAtlasInfo(atlas)
        if useAtlasSize and info then
            s.width, s.height = info.width, info.height
        end
        touchLayoutOf(self)
        return info ~= nil or atlas ~= nil
    end,
    GetAtlas = function(self)
        return S(self).atlas
    end,
    -- A corner moved off its place (1 upper left, 2 lower left, 3 upper right, 4 lower right), in the texture's
    -- units with y up: the texture is drawn as the shape its corners make, a triangle when two meet
    SetVertexOffset = function(self, vertexIndex, x, y)
        local s = S(self)
        s.vertexOffsets = s.vertexOffsets or {}
        s.vertexOffsets[vertexIndex] = { x or 0, y or 0 }
        sim.touchVisual(self)
    end,
    GetVertexOffset = function(self, vertexIndex)
        local offset = S(self).vertexOffsets and S(self).vertexOffsets[vertexIndex]
        if offset then
            return offset[1], offset[2]
        end
        return 0, 0
    end,
    SetTexCoord = function(self, ...)
        local count = select("#", ...)
        local values = { ... }
        if count == 8 then
            -- ULx, ULy, LLx, LLy, URx, URy, LRx, LRy (the texture's point at each screen corner). Straight, it is
            -- left, right, top, bottom; turned a quarter (the game's backdrop edges), u runs down the screen
            local isTurned = values[1] == values[5] and values[2] == values[6]
            if not isTurned and values[1] == values[5] and values[3] ~= values[1] then
                isTurned = true
            end
            if isTurned then
                S(self).texCoord = { values[1], values[3], values[2], values[6] } -- u top to bottom, v left to right
                S(self).isTexCoordTurned = true
            else
                S(self).texCoord = { values[1], values[5], values[2], values[4] }
                S(self).isTexCoordTurned = nil
            end
        else
            S(self).isTexCoordTurned = nil
            S(self).texCoord = { values[1] or 0, values[2] or 1, values[3] or 0, values[4] or 1 }
        end
        sim.touchVisual(self)
    end,
    GetTexCoord = function(self)
        local coord = S(self).texCoord or { 0, 1, 0, 1 }
        return coord[1], coord[3], coord[1], coord[4], coord[2], coord[3], coord[2], coord[4]
    end,
    -- A radial progress bar: the texture shown only over a sweep clockwise from the top, as far as the percent (from a
    -- start offset, to an end one, in turns; reversed: counter-clockwise), as the client's gamepad hold rings and
    -- addons' round bars draw
    SetRadialProgressBarPercent = function(self, percent)
        local s = S(self)
        s.radial = s.radial or { startOffset = 0, endOffset = 0, reverse = false, feather = 0 }
        s.radial.percent = math.max(0, math.min(1, tonumber(percent) or 0))
        sim.touchVisual(self)
    end,
    GetRadialProgressBarPercent = function(self)
        local radial = S(self).radial
        return radial and radial.percent or 0
    end,
    SetRadialProgressBarStartOffset = function(self, offset)
        local s = S(self)
        s.radial = s.radial or { percent = 1, endOffset = 0, reverse = false, feather = 0 }
        s.radial.startOffset = tonumber(offset) or 0
        sim.touchVisual(self)
    end,
    GetRadialProgressBarStartOffset = function(self)
        local radial = S(self).radial
        return radial and radial.startOffset or 0
    end,
    SetRadialProgressBarEndOffset = function(self, offset)
        local s = S(self)
        s.radial = s.radial or { percent = 1, startOffset = 0, reverse = false, feather = 0 }
        s.radial.endOffset = tonumber(offset) or 0
        sim.touchVisual(self)
    end,
    GetRadialProgressBarEndOffset = function(self)
        local radial = S(self).radial
        return radial and radial.endOffset or 0
    end,
    SetRadialProgressBarReverse = function(self, isReversed)
        local s = S(self)
        s.radial = s.radial or { percent = 1, startOffset = 0, endOffset = 0, feather = 0 }
        s.radial.reverse = isReversed and true or false
        sim.touchVisual(self)
    end,
    GetRadialProgressBarReverse = function(self)
        local radial = S(self).radial
        return radial and radial.reverse or false
    end,
    SetRadialProgressBarFeather = function(self, feather)
        local s = S(self)
        s.radial = s.radial or { percent = 1, startOffset = 0, endOffset = 0, reverse = false }
        s.radial.feather = tonumber(feather) or 0
    end,
    GetRadialProgressBarFeather = function(self)
        local radial = S(self).radial
        return radial and radial.feather or 0
    end,
    ClearRadialProgressBar = function(self)
        S(self).radial = nil
        sim.touchVisual(self)
    end,
    ResetTexCoord = function(self)
        local s = S(self)
        s.texCoord, s.isTexCoordTurned = nil, nil
        sim.touchVisual(self)
    end,
    GetDesaturation = function(self)
        return S(self).desaturation or (S(self).desaturated and 1 or 0)
    end,
    -- One cell of a sheet of rows × columns (counted from 1, a row at a time from the upper left): the unit menu's raid
    -- target icons. A cell's own width and height, when given, are fractions of the sheet
    SetSpriteSheetCell = function(self, cell, rows, columns, cellWidth, cellHeight)
        rows, columns = math.max(1, tonumber(rows) or 1), math.max(1, tonumber(columns) or 1)
        local index = math.max(0, (tonumber(cell) or 1) - 1)
        local column, row = index % columns, math.floor(index / columns)
        local width = (tonumber(cellWidth) and cellWidth <= 1) and cellWidth or 1 / columns
        local height = (tonumber(cellHeight) and cellHeight <= 1) and cellHeight or 1 / rows
        local s = S(self)
        s.isTexCoordTurned = nil
        s.texCoord = { column / columns, column / columns + width, row / rows, row / rows + height }
        sim.touchVisual(self)
    end,
    SetDesaturated = function(self, isDesaturated)
        S(self).desaturated = isDesaturated and true or nil
        S(self).desaturation = nil
        sim.touchVisual(self)
    end,
    -- (greyed at all: any amount, measured)
    IsDesaturated = function(self)
        local s = S(self)
        return s.desaturated == true or (s.desaturation or 0) > 0
    end,
    SetDesaturation = function(self, amount)
        S(self).desaturation = math.max(0, math.min(1, tonumber(amount) or 0))
        S(self).desaturated = (tonumber(amount) or 0) >= 0.999 or nil
        sim.touchVisual(self)
    end,
    SetBlendMode = function(self, mode)
        S(self).blend = mode
        sim.touchVisual(self)
    end,
    GetBlendMode = function(self)
        return S(self).blend or "BLEND"
    end,
    SetRotation = function(self, radians)
        S(self).rotation = radians
        sim.touchVisual(self)
    end,
    GetRotation = function(self)
        return S(self).rotation or 0
    end,
    SetGradient = function(self, orientation, fromColor, toColor)
        local fr, fg, fb, fa = unpackColor(fromColor)
        local tr, tg, tb, ta = unpackColor(toColor)
        S(self).gradient = { orientation = orientation, from = { fr, fg, fb, fa }, to = { tr, tg, tb, ta } }
        sim.touchVisual(self)
    end,
    SetGradientAlpha = function(self, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
        S(self).gradient = { orientation = orientation, from = { r1, g1, b1, a1 }, to = { r2, g2, b2, a2 } }
        sim.touchVisual(self)
    end,
    SetHorizTile = function(self, isTiled)
        S(self).horizTile = isTiled
        sim.touchVisual(self)
    end,
    SetVertTile = function(self, isTiled)
        S(self).vertTile = isTiled
        sim.touchVisual(self)
    end,
    GetHorizTile = function(self)
        return S(self).horizTile == true
    end,
    GetVertTile = function(self)
        return S(self).vertTile == true
    end,
    -- Up to three masks, each cutting the texture by its alpha (as the client: a fourth is not taken)
    AddMaskTexture = function(self, mask)
        local s = S(self)
        s.masks = s.masks or {}
        for _, each in ipairs(s.masks) do
            if each == mask then
                return
            end
        end
        if #s.masks >= 3 then
            return
        end
        s.masks[#s.masks + 1] = mask
        sim.touchVisual(self)
    end,
    RemoveMaskTexture = function(self, mask)
        local masks = S(self).masks
        for index = #(masks or {}), 1, -1 do
            if masks[index] == mask then
                table.remove(masks, index)
                sim.touchVisual(self)
            end
        end
    end,
    GetNumMaskTextures = function(self)
        return #(S(self).masks or {})
    end,
    GetMaskTexture = function(self, index)
        local masks = S(self).masks
        return masks and masks[index]
    end,
    SetMask = function(self, path)
        S(self).maskPath = path
        sim.touchVisual(self)
    end,
    -- Nine-sliced (texels of its file: left, top, right, bottom): corners at their own size, the edges and middle
    -- stretched (mode 0) or tiled (1), as the client draws it. EllesmereUI's rounded corners are a tiny mask sliced so;
    -- stretched whole, every rounded button was a blurred ellipse
    SetTextureSliceMargins = function(self, left, top, right, bottom)
        local s = S(self)
        s.slice = { tonumber(left) or 0, tonumber(top) or 0, tonumber(right) or 0, tonumber(bottom) or 0 }
        sim.touchVisual(self)
    end,
    GetTextureSliceMargins = function(self)
        local slice = S(self).slice
        if slice then
            return slice[1], slice[2], slice[3], slice[4]
        end
        return 0, 0, 0, 0
    end,
    SetTextureSliceMode = function(self, mode)
        S(self).sliceMode = tonumber(mode) or (mode == "Tiled" and 1) or 0
        sim.touchVisual(self)
    end,
    GetTextureSliceMode = function(self)
        return S(self).sliceMode or 0
    end,
    ClearTextureSlice = function(self)
        S(self).slice = nil
        sim.touchVisual(self)
    end,
    SetNonBlocking = function() end,
    IsBlockingLoadRequested = function()
        return false
    end,
}
defineType("Texture", "LayeredRegion", textureMethods)
defineType("MaskTexture", "Texture", {})

defineType("Line", "Texture", {
    SetStartPoint = function(self, point, relative, x, y)
        S(self).startPoint = {
            point = point or "CENTER",
            relative = resolveRelative(relative) or S(self).parent,
            x = x or 0,
            y = y or 0,
        }
        sim.touchVisual(self)
    end,
    SetEndPoint = function(self, point, relative, x, y)
        S(self).endPoint = {
            point = point or "CENTER",
            relative = resolveRelative(relative) or S(self).parent,
            x = x or 0,
            y = y or 0,
        }
        sim.touchVisual(self)
    end,
    SetThickness = function(self, thickness)
        S(self).thickness = thickness
        sim.touchVisual(self)
    end,
    GetThickness = function(self)
        return S(self).thickness or 1
    end,
})
-- The game's lines take no mask (calling AddMaskTexture on one is "attempt to call a nil value")
types.Line.methods.AddMaskTexture, types.Line.methods.RemoveMaskTexture = nil, nil

function W.getLineEnds(object)
    local s = S(object)
    local function resolve(endPoint)
        if not endPoint or not endPoint.relative then
            return nil
        end
        local rect = computeRect(endPoint.relative)
        if not rect then
            return nil
        end
        local scale = getEffectiveScale(object)
        return rect[1] + (rect[3] - rect[1]) * POINT_X[endPoint.point:upper()] + endPoint.x * scale,
            rect[2] + (rect[4] - rect[2]) * POINT_Y[endPoint.point:upper()] + endPoint.y * scale
    end
    local x1, y1 = resolve(s.startPoint)
    local x2, y2 = resolve(s.endPoint)
    if x1 and x2 then
        return x1, y1, x2, y2
    end
end

-- Font strings
---A font object given by name ("GameFontNormal") as the object itself, as the client keeps it
function W.resolveFontObject(fontObject)
    if type(fontObject) == "string" then
        return sim.G[fontObject]
    end
    return fontObject
end

local function applyFontObject(s, fontObject)
    s.fontObject = W.resolveFontObject(fontObject)
end

local fontStringMethods = {
    SetText = function(self, text)
        local s = S(self)
        text = text ~= nil and tostring(text) or nil
        if s.text == text then
            return
        end
        s.text = text
        touchLayoutOf(self)
    end,
    GetText = function(self)
        return S(self).text
    end,
    SetFormattedText = function(self, pattern, ...)
        self:SetText(string.format(pattern, ...))
    end,
    SetFont = function(self, path, size, flags)
        local s = S(self)
        s.font = { path = path, size = size or 12, flags = flags or "" }
        touchLayoutOf(self)
        return true
    end,
    GetFont = function(self)
        local font = fonts.getFont(S(self))
        return font.path, font.size, font.flags
    end,
    -- The font's size alone, its face and outline kept (the game's unit frames size their health text so)
    SetFontHeight = function(self, height)
        local path, _, flags = self:GetFont()
        self:SetFont(path, height, flags)
    end,
    ClearText = function(self)
        self:SetText(nil)
    end,
    SetFontObject = function(self, fontObject)
        local s = S(self)
        applyFontObject(s, fontObject)
        s.font = nil
        touchLayoutOf(self)
    end,
    GetFontObject = function(self)
        return S(self).fontObject
    end,
    SetTextColor = function(self, r, g, b, a)
        S(self).textColor = { unpackColor(r, g, b, a) }
        sim.touchVisual(self)
    end,
    GetTextColor = function(self)
        local color = fonts.getColor(S(self))
        return color[1], color[2], color[3], color[4]
    end,
    SetJustifyH = function(self, justify)
        S(self).justifyH = justify
        sim.touchVisual(self) -- (where the text sits in its box; the box stays)
    end,
    GetJustifyH = function(self)
        return S(self).justifyH or fonts.getFont(S(self)).justifyH or "CENTER"
    end,
    SetJustifyV = function(self, justify)
        S(self).justifyV = justify
        sim.touchVisual(self)
    end,
    GetJustifyV = function(self)
        return S(self).justifyV or "MIDDLE"
    end,
    SetWordWrap = function(self, isWrapped)
        S(self).wordWrap = isWrapped and true or false
        touchLayoutOf(self) -- (its height, and what hangs from it)
    end,
    CanWordWrap = function(self)
        return S(self).wordWrap ~= false
    end,
    SetNonSpaceWrap = function(self, isWrapped)
        S(self).nonSpaceWrap = isWrapped
        touchLayoutOf(self)
    end,
    SetIndentedWordWrap = function() end,
    SetMaxLines = function(self, lines)
        S(self).maxLines = lines
        touchLayoutOf(self)
    end,
    GetMaxLines = function(self)
        return S(self).maxLines or 0
    end,
    SetSpacing = function(self, spacing)
        S(self).spacing = spacing
        touchLayoutOf(self)
    end,
    GetSpacing = function(self)
        return S(self).spacing or 0
    end,
    SetShadowColor = function(self, r, g, b, a)
        S(self).shadowColor = { unpackColor(r, g, b, a) }
        sim.touchVisual(self)
    end,
    GetShadowColor = function(self)
        local color = S(self).shadowColor or { 0, 0, 0, 1 }
        return unpack(color)
    end,
    SetShadowOffset = function(self, x, y)
        S(self).shadowOffset = { x or 0, y or 0 }
        sim.touchVisual(self)
    end,
    GetShadowOffset = function(self)
        local offset = S(self).shadowOffset or { 0, 0 }
        return offset[1], offset[2]
    end,
    GetStringWidth = function(self)
        local s = S(self)
        local width = fonts.measureWidth(s)
        if s.width and s.width > 0 and s.wordWrap ~= false then
            return math.min(width, s.width)
        end
        local rect = computeRect(self)
        if rect and s.wordWrap ~= false and #s.points >= 2 then
            return math.min(width, (rect[3] - rect[1]) / getEffectiveScale(self))
        end
        return width
    end,
    GetUnboundedStringWidth = function(self)
        return fonts.measureWidth(S(self))
    end,
    GetStringHeight = function(self)
        local s = S(self)
        local rect = computeRect(self)
        local width = s.width
        if rect then
            width = (rect[3] - rect[1]) / getEffectiveScale(self)
        end
        return fonts.measureHeight(s, (width and width > 0) and width or nil)
    end,
    GetNumLines = function(self)
        local s = S(self)
        local rect = computeRect(self)
        local width = rect and (rect[3] - rect[1]) / getEffectiveScale(self) or s.width
        return #fonts.wrap(s, (width and width > 0) and width or nil)
    end,
    IsTruncated = function(self)
        local s = S(self)
        if s.maxLines ~= nil and s.maxLines > 0 and self:GetNumLines() > s.maxLines then
            return true
        end
        -- One line, cut short at the width it has
        local rect = computeRect(self)
        local width = rect and (rect[3] - rect[1]) / getEffectiveScale(self) or s.width
        local lines = fonts.wrap(s, (width and width > 0) and width or nil)
        return lines[1] ~= nil and lines[1].isTruncated == true
    end,
    SetTextScale = function(self, scale)
        S(self).textScale = scale
        touchLayoutOf(self)
    end,
    GetTextScale = function(self)
        return S(self).textScale or 1
    end,
    -- The text fading out from a character on over a width (in units): a typewriter's reveal (the quest window's).
    -- True while that character is within the text: the quest window reveals until it is not
    SetAlphaGradient = function(self, start, length)
        local s = S(self)
        start, length = tonumber(start) or 0, tonumber(length) or 0
        local shown = tostring(s.text or "")
            :gsub("|c%x%x%x%x%x%x%x%x", "")
            :gsub("|r", "")
            :gsub("|T.-|t", "x")
            :gsub("|A.-|a", "x")
            :gsub("|H.-|h", "")
            :gsub("|h", "")
            :gsub("||", "|")
        local _, characters = shown:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
        local isWithin = start < characters
        s.alphaGradient = (isWithin and length > 0) and { start, length } or nil
        sim.touchVisual(self)
        return isWithin
    end,
    GetAlphaGradient = function(self)
        local gradient = S(self).alphaGradient
        return gradient and gradient[1] or 0, gradient and gradient[2] or 0
    end,
    ClearAlphaGradient = function(self)
        S(self).alphaGradient = nil
        sim.touchVisual(self)
    end,
    GetLineHeight = function(self)
        return fonts.getFont(S(self)).size
    end,
    SetTextToFit = function(self, text)
        self:SetText(text)
        S(self).width = fonts.measureWidth(S(self))
        touchLayoutOf(self)
    end,
    SetTextHeight = function(self, height)
        local s = S(self)
        local font = fonts.getFont(s)
        s.font = { path = font.path, size = height, flags = font.flags }
        touchLayoutOf(self)
    end,
}
defineType("FontString", "LayeredRegion", fontStringMethods)

---@return string? name What "$parent" in a name stands for: the parent's name, or, when it has none, its nearest named
---ancestor's (as the client does: a template's "$parentActionButton1" inside an unnamed bar takes the bar's owner's)
function W.getParentNameFor(parent)
    local depth = 0
    while parent and depth < 50 do
        local state = S(parent)
        if not state then
            return nil
        end
        if state.name then
            return state.name
        end
        parent, depth = state.parent, depth + 1
    end
    return nil
end

-- Frames
local function createRegion(frame, typeName, name, layer, template, sublevel)
    if type(name) == "string" then
        name = name:gsub("%$parent", W.getParentNameFor(frame) or "")
    end
    local region, s = newObject(typeName, name, frame)
    s.layer, s.sublevel = layer or "ARTWORK", sublevel or 0
    if typeName == "FontString" then
        s.layer = layer or "OVERLAY"
        if template then
            applyFontObject(s, template)
        end
    end
    local regions = S(frame).regions
    regions[#regions + 1] = region
    if name then
        sim.G[name] = region
    end
    -- (a redraw only: nothing has a rectangle of it yet, nor is worked out from it; touching the layout here threw
    -- every rectangle away each time an addon made a texture, several times a frame with EllesmereUI)
    sim.touchVisual()
    return region
end
W.createRegion = createRegion

local scriptTypes = {} -- [script] = true for every script a frame may hold
for _, script in ipairs({
    "OnEvent",
    "OnUpdate",
    "OnShow",
    "OnHide",
    "OnLoad",
    "OnEnter",
    "OnLeave",
    "OnMouseDown",
    "OnMouseUp",
    "OnMouseWheel",
    "OnClick",
    "PreClick",
    "PostClick",
    "OnDoubleClick",
    "OnDragStart",
    "OnDragStop",
    "OnReceiveDrag",
    "OnSizeChanged",
    "OnValueChanged",
    "OnMinMaxChanged",
    "OnTextChanged",
    "OnEnterPressed",
    "OnEscapePressed",
    "OnTabPressed",
    "OnSpacePressed",
    "OnEditFocusGained",
    "OnEditFocusLost",
    "OnChar",
    "OnKeyDown",
    "OnKeyUp",
    "OnAttributeChanged",
    "OnVerticalScroll",
    "OnHorizontalScroll",
    "OnScrollRangeChanged",
    "OnTooltipSetItem",
    "OnTooltipCleared",
    "OnTooltipSetUnit",
    "OnTooltipSetSpell",
    "OnHyperlinkClick",
    "OnHyperlinkEnter",
    "OnHyperlinkLeave",
    "OnCursorChanged",
    "OnInputLanguageChanged",
    "OnEnable",
    "OnDisable",
    "OnCooldownDone",
    "OnFinished",
    "OnPlay",
    "OnStop",
    "OnLoop",
    "OnUpdateModel",
    "OnModelLoaded",
    "OnArrowPressed",
    "OnTextSet",
    "OnMouseDownSecure",
    "OnGamePadButtonDown",
    "OnGamePadButtonUp",
    "OnGamePadStick",
}) do
    scriptTypes[script] = true
end
-- Script names are case-blind in the client: the game's gamepad code sets "OnGamepadStick" for OnGamePadStick
local canonicalScripts = {}
for script in pairs(scriptTypes) do
    canonicalScripts[script:lower()] = script
end
local function canonicalScript(script)
    return type(script) == "string" and canonicalScripts[script:lower()] or script
end
W.canonicalScript = canonicalScript

---OnSizeChanged, as the game fires it: once the laid-out size of a frame differs from the size last reported,
---whether it was set or follows from anchors. Repeated while handlers keep changing sizes.
-- The frames with an OnSizeChanged handler (their own, an intrinsic type's or a hook), in the order they got one: only
-- these are measured after a layout change (every frame was, tens of thousands, a third of each tick's time)
local sizeWatchers, isSizeWatched = {}, {}
-- Scroll frames, measured at the same time: the client works a scroll frame's range out again when its scroll child's
-- rectangle changes and tells it (OnScrollRangeChanged) at that layout, without the addon calling
-- UpdateScrollChildRect. The game's ScrollUtil.InitScrollFrameWithScrollBar sizes its bar's thumb only from there.
local scrollWatchers, isScrollWatched = {}, {}
-- (watchers to look at whatever changed: new ones, and scroll frames changed while hidden, told once on show)
local pendingWatchers = {}
function W.watchScript(frame, script)
    if script == "OnSizeChanged" and not isSizeWatched[frame] then
        isSizeWatched[frame] = true
        sizeWatchers[#sizeWatchers + 1] = frame
        pendingWatchers[frame] = true
    elseif script == "OnScrollRangeChanged" then
        W.watchScrollRange(frame)
    end
end
function W.watchScrollRange(frame)
    if not isScrollWatched[frame] then
        isScrollWatched[frame] = true
        scrollWatchers[#scrollWatchers + 1] = frame
        pendingWatchers[frame] = true
    end
end
-- Looked at after a layout change: every watcher when the whole layout was thrown away (sim.touch), else only those
-- whose rectangles were (a window dragged moved its own, and a pass over every watcher took 4 ms a tick)
local checkedVersion, checkedLayoutVersion
function W.fireSizeChanges()
    for _ = 1, 8 do
        local changes = sim.layoutVersion * 1000003 + sim.layoutChanges
        if checkedVersion == changes then
            return
        end
        checkedVersion = changes
        local isAll = checkedLayoutVersion ~= sim.layoutVersion
        checkedLayoutVersion = sim.layoutVersion
        local counts = sim.sizeCounts
        counts.passes = counts.passes + 1
        if isAll then
            counts.whole = counts.whole + 1
        end
        local dropped, pending = droppedRects, pendingWatchers
        droppedRects, pendingWatchers = {}, {}
        -- (only those on show: a hidden frame is laid out, and told, once it shows)
        for _, frame in ipairs(scrollWatchers) do
            local s = S(frame)
            local child = s.scrollChild
            if child and (isAll or pending[frame] or dropped[frame] or dropped[child]) then
                if frame:IsVisible() then
                    counts.scrolls = counts.scrolls + 1
                    frame:UpdateScrollChildRect()
                else
                    pendingWatchers[frame] = true
                end
            end
        end
        for _, frame in ipairs(sizeWatchers) do
            local s = S(frame)
            if
                (isAll or pending[frame] or dropped[frame])
                and (
                    s.scripts.OnSizeChanged
                    or (s.intrinsicScripts and s.intrinsicScripts.OnSizeChanged)
                    or (s.hooks and s.hooks.OnSizeChanged)
                )
            then
                counts.measured = counts.measured + 1
                local width, height = frame:GetWidth(), frame:GetHeight()
                -- (a size changed by more than rounding: a frame moved has its width worked out as right less left
                -- at another place, and 664 came back 663.9999999999999, an OnSizeChanged for every frame of a
                -- dragged window at every step)
                local reportedWidth, reportedHeight = s.reportedWidth, s.reportedHeight
                if
                    not reportedWidth
                    or math.abs(width - reportedWidth) > 0.001
                    or math.abs(height - reportedHeight) > 0.001
                then
                    counts.fired = counts.fired + 1
                    s.reportedWidth, s.reportedHeight = width, height
                    sim.runScript(frame, "OnSizeChanged", width, height)
                end
            end
        end
    end
end

function sim.runScript(frame, script, ...)
    local s = S(frame)
    if not s then
        return
    end
    -- An intrinsic type's own handlers (DropdownButton's OnLoad_Intrinsic...) run first and survive SetScript
    local intrinsicHandler = s.intrinsicScripts and s.intrinsicScripts[script]
    if intrinsicHandler then
        sim.call(intrinsicHandler, frame, ...)
    end
    local handler = s.scripts[script]
    if handler then
        sim.call(handler, frame, ...)
    end
    local hooks = s.hooks and s.hooks[script]
    if hooks then
        for _, hook in ipairs(hooks) do
            sim.call(hook, frame, ...)
        end
    end
end

-- The scripts that take the mouse: a frame given one (in its XML, or by SetScript or HookScript) gets the mouse, as in
-- the client, unless it said otherwise itself (EnableMouse). The game's side tabs (LargeSideTabButtonTemplate, a Frame
-- with OnMouseDown and OnMouseUp) are clickable by that alone; an addon's HookScript("OnEnter") on a plain frame makes
-- it catch the clicks, as players know it to.
local MOUSE_SCRIPTS = { OnEnter = true, OnLeave = true, OnMouseDown = true, OnMouseUp = true }
W.MOUSE_SCRIPTS = MOUSE_SCRIPTS -- (the XML's scripts too: xmlui)

local frameMethods = {
    SetScript = function(self, script, handler)
        local s = S(self)
        script = canonicalScript(script)
        s.scripts[script] = handler
        if handler then
            W.watchScript(self, script)
        end
        if s.hooks then
            s.hooks[script] = nil
        end
        if script == "OnUpdate" then
            sim.setOnUpdate(self, handler)
        end
        -- A wheel handler takes the wheel, as in the client (the game's map scroll container sets only its script)
        if script == "OnMouseWheel" and handler and s.mouseWheel == nil then
            s.mouseWheel = true
        end
        if MOUSE_SCRIPTS[script] and handler and s.mouse == nil then
            s.mouse = true
        end
    end,
    GetScript = function(self, script)
        return S(self).scripts[canonicalScript(script)]
    end,
    HookScript = function(self, script, handler)
        local s = S(self)
        script = canonicalScript(script)
        W.watchScript(self, script)
        if not s.scripts[script] then
            s.scripts[script] = handler
            if script == "OnUpdate" then
                sim.setOnUpdate(self, true)
            end
            if script == "OnMouseWheel" and s.mouseWheel == nil then
                s.mouseWheel = true
            end
            if MOUSE_SCRIPTS[script] and s.mouse == nil then
                s.mouse = true
            end
            return
        end
        s.hooks = s.hooks or {}
        s.hooks[script] = s.hooks[script] or {}
        table.insert(s.hooks[script], handler)
    end,
    HasScript = function(self, script)
        return scriptTypes[canonicalScript(script)] == true
    end,
    CreateTexture = function(self, name, layer, template, sublevel)
        local texture = createRegion(self, "Texture", name, layer, nil, sublevel)
        if template and W.applyTemplate then
            W.applyTemplate(texture, template)
        else
            -- (made by code, no template: no points, no place; see computeRect)
            S(texture).isMadeByCode = true
        end
        return texture
    end,
    CreateMaskTexture = function(self, name, layer)
        return createRegion(self, "MaskTexture", name, layer)
    end,
    CreateFontString = function(self, name, layer, template)
        local fontString = createRegion(self, "FontString", name, layer, template)
        -- (made by code: no points, no place, as a texture so made; an addon's measuring string on UIParent, "Hide
        -- Dungeons", filled the screen)
        S(fontString).isMadeByCode = true
        return fontString
    end,
    CreateLine = function(self, name, layer, template, sublevel)
        return createRegion(self, "Line", name, layer, nil, sublevel)
    end,
    GetChildren = function(self)
        return unpack(S(self).children)
    end,
    -- Every texture of the frame and the frames under it greyed by an amount (0 to 1), the frame's own left out when
    -- excludeRoot, as the client does it
    DesaturateHierarchy = function(self, desaturation, excludeRoot)
        local function visit(frame, isRoot)
            local state = S(frame)
            if not state then
                return
            end
            if not (isRoot and excludeRoot) then
                for _, region in ipairs(state.regions or {}) do
                    if region.SetDesaturation then
                        region:SetDesaturation(desaturation or 0)
                    end
                end
            end
            for _, child in ipairs(state.children or {}) do
                visit(child, false)
            end
        end
        visit(self, true)
    end,
    GetNumChildren = function(self)
        return #S(self).children
    end,
    GetRegions = function(self)
        return unpack(S(self).regions)
    end,
    GetNumRegions = function(self)
        return #S(self).regions
    end,
    RegisterEvent = function(self, event)
        -- An event this client does not have fails as it does in the game (one renamed in another version of it)
        if type(event) ~= "string" or event == "" or not sim.isEventKnown(event) then
            error('Frame:RegisterEvent(): Attempt to register unknown event "' .. tostring(event) .. '"', 2)
        end
        if sim.restrictedEvents[event] then
            -- Kept from addons by this client (the combat log): it never arrives
            sim.noteStub("restricted event " .. event .. " (never sent to addons)")
            return false
        end
        S(self).events = S(self).events or {}
        S(self).events[event] = true
        sim.registerEvent(self, event)
        return true
    end,
    -- For one or two units only, as the client keeps it: the frame hears the event fired for those unit tokens alone
    -- (a plain RegisterEvent afterwards hears every unit again: sim.registerEvent)
    RegisterUnitEvent = function(self, event, ...)
        local isRegistered = self:RegisterEvent(event)
        if isRegistered and select("#", ...) > 0 then
            sim.setUnitEventFilter(self, event, ...)
        end
        return isRegistered
    end,
    UnregisterEvent = function(self, event)
        if S(self).events then
            S(self).events[event] = nil
        end
        sim.unregisterEvent(self, event)
    end,
    UnregisterAllEvents = function(self)
        S(self).events = {}
        sim.unregisterAllEvents(self)
    end,
    RegisterAllEvents = function(self)
        sim.allEventFrames[self] = true
    end,
    IsEventRegistered = function(self, event)
        return S(self).events ~= nil and S(self).events[event] == true
    end,
    -- Both channels at once, clicks and motion (each set on its own after, by SetMouseClickEnabled and
    -- SetMouseMotionEnabled, as in the client: EllesmereUI's chat overlay turns the mouse off, then motion alone on)
    EnableMouse = function(self, isEnabled)
        local s = S(self)
        s.mouse = isEnabled and true or false
        s.mouseClick, s.mouseMotion = nil, nil
    end,
    -- A press and release of a mouse button on the frame, as the game's gamepad navigation presses the control under
    -- its cursor (A): its OnMouseDown and OnMouseUp, an edit box takes the keyboard, and a button clicks as it would
    -- under the mouse (on the press or the release it registered for)
    MouseDown = function(self, button)
        button = button or "LeftButton"
        local s = S(self)
        if W.types[s.type].chain.EditBox then
            W.setFocus(self)
        end
        sim.runScript(self, "OnMouseDown", button)
        if W.types[s.type].chain.Button then
            if W.isClickRegistered(s, button, "Down") then
                W.clickButton(self, button, true)
            end
        end
        sim.touchVisual(self)
    end,
    -- The mouse coming onto the frame and leaving it, as the gamepad's cursor selecting a control does: its OnEnter
    -- and OnLeave run (a tooltip shows as under the mouse)
    FocusEnter = function(self, fromMouseMotion)
        sim.runScript(self, "OnEnter", fromMouseMotion ~= false)
    end,
    FocusExit = function(self, fromMouseMotion)
        sim.runScript(self, "OnLeave", fromMouseMotion ~= false)
    end,
    MouseUp = function(self, button)
        button = button or "LeftButton"
        local s = S(self)
        sim.runScript(self, "OnMouseUp", button, true)
        if W.types[s.type].chain.Button then
            if W.isClickRegistered(s, button, "Up") then
                W.clickButton(self, button, false)
            end
        end
        sim.touchVisual(self)
    end,
    IsMouseEnabled = function(self)
        return S(self).mouse == true
    end,
    SetMouseClickEnabled = function(self, isEnabled)
        S(self).mouseClick = isEnabled and true or false
    end,
    IsMouseClickEnabled = function(self)
        return W.takesClicks(S(self))
    end,
    SetMouseMotionEnabled = function(self, isEnabled)
        S(self).mouseMotion = isEnabled and true or false
    end,
    IsMouseMotionEnabled = function(self)
        return W.takesMotion(S(self))
    end,
    EnableMouseWheel = function(self, isEnabled)
        S(self).mouseWheel = isEnabled == nil and true or (isEnabled and true or false)
    end,
    IsMouseWheelEnabled = function(self)
        return S(self).mouseWheel == true
    end,
    SetPassThroughButtons = function() end,
    EnableKeyboard = function(self, isEnabled)
        S(self).keyboard = isEnabled and true or false
    end,
    IsKeyboardEnabled = function(self)
        return S(self).keyboard == true
    end,
    SetPropagateKeyboardInput = function(self, isPropagated)
        S(self).propagateKeyboard = isPropagated
    end,
    GetPropagateKeyboardInput = function(self)
        return S(self).propagateKeyboard == true
    end,
    EnableGamePadButton = function(self, isEnabled)
        S(self).gamePadButton = isEnabled ~= false
    end,
    IsGamePadButtonEnabled = function(self)
        return S(self).gamePadButton == true
    end,
    EnableGamePadStick = function(self, isEnabled)
        S(self).gamePadStick = isEnabled ~= false
    end,
    IsGamePadStickEnabled = function(self)
        return S(self).gamePadStick == true
    end,
    SetFrameStrata = function(self, strata)
        local s = S(self)
        if W.STRATA_RANK[strata] then
            local isChanged = s.strata ~= strata
            s.strata = strata
            -- Everything it holds goes with it, as in the client: a child's own strata (one its XML gave it) gives
            -- way, unless it is fixed (SetFixedFrameStrata, fixedFrameStrata="true"). The gamepad's navigation
            -- pointer is a HIGH child of a frame set to TOOLTIP, and draws over the windows it points into.
            local function carry(frame)
                for _, child in ipairs(S(frame).children or {}) do
                    local childState = S(child)
                    if childState and childState.isFrame and not childState.isStrataFixed then
                        isChanged = isChanged or childState.strata ~= nil
                        childState.strata = nil
                        carry(child)
                    end
                end
            end
            carry(self)
            -- (the same strata again, with nothing it holds changed: the order stands)
            if isChanged then
                W.touchOrder()
                sim.touchVisual(self) -- (the drawing order; nothing moves)
            end
        end
    end,
    GetFrameStrata = function(self)
        return W.getStrata(self)
    end,
    SetFrameLevel = function(self, level)
        local s = S(self)
        -- Its children move by as much, keeping their places above it, as in the client (measured: a child at 6
        -- and one at 20 of a frame at 5 are at 51 and 65 once it is set to 50)
        local delta = (tonumber(level) or 0) - (s.level or 0)
        -- (the same level again: nothing moves, the drawing order stands; EllesmereUI sets its levels over and over)
        if delta == 0 and s.levelSet and s.level == level then
            return
        end
        if delta ~= 0 then
            local function shift(frame)
                for _, child in ipairs(S(frame).children or {}) do
                    local childState = S(child)
                    if childState and childState.isFrame then
                        childState.level = math.max(0, (childState.level or 0) + delta)
                        shift(child)
                    end
                end
            end
            shift(self)
        end
        s.level, s.levelSet = level, true
        -- Children stay above their parent, as in the game
        W.liftChildren(self)
        W.touchOrder()
        sim.touchVisual(self) -- (the drawing order; nothing moves)
    end,
    GetFrameLevel = function(self)
        return S(self).level or 0
    end,
    SetFixedFrameStrata = function(self, isFixed)
        S(self).isStrataFixed = isFixed == true
    end,
    SetFixedFrameLevel = function() end,
    SetToplevel = function(self, isTop)
        S(self).toplevel = isTop
    end,
    IsToplevel = function(self)
        return S(self).toplevel == true
    end,
    -- Raise and Lower leave the frame's level as it is, as the client does (measured: /asrec probe): among the
    -- frames of its strata and level it, and all it holds, comes in front of (or behind) the others. A frame at a
    -- higher level stays in front of it (Edit Mode's dialogs, at 100, over its window raised as it opened)
    -- Drawn over every frame of its strata, with all it holds, its level as read unchanged: the client draws a raised
    -- frame at a level of its own, one above the highest in its strata as it is raised, its children as far above
    -- that as they are above it (measured in Forever, /asrec probe: a toplevel window of level 2 shown comes over a
    -- frame of level 30 in its strata, GetFrameLevel still 2; Edit Mode's name dialog, level 100, still comes over
    -- the raised Edit Mode window)
    Raise = function(self)
        W.raiseCounter = (W.raiseCounter or 0) + 1
        local s = S(self)
        s.raised = W.raiseCounter
        local strata = W.getStrata(self)
        local own = {}
        local function mark(frame)
            own[frame] = true
            for _, child in ipairs(S(frame).children or {}) do
                if S(child) and S(child).isFrame then
                    mark(child)
                end
            end
        end
        mark(self)
        -- (the highest of the frames on show: the scene's ordered list, a few hundred, rather than every frame made)
        local highest = require("scene").highestDrawLevel(strata, own)
        s.raisedLevel = highest >= (s.level or 0) and highest + 1 or nil
        W.touchOrder()
        sim.touchVisual(self)
    end,
    Lower = function(self)
        W.raiseCounter = (W.raiseCounter or 0) + 1
        S(self).raised = -W.raiseCounter
        W.touchOrder()
        sim.touchVisual(self)
    end,
    SetMovable = function(self, isMovable)
        S(self).movable = isMovable
    end,
    IsMovable = function(self)
        return S(self).movable == true
    end,
    SetResizable = function(self, isResizable)
        S(self).resizable = isResizable
    end,
    IsResizable = function(self)
        return S(self).resizable == true
    end,
    SetResizeBounds = function() end,
    SetMinResize = function() end,
    SetMaxResize = function() end,
    -- Moved by the player, the frame is user-placed from then on: the client keeps its place in the layout cache
    -- (layout.lua) unless it is told not to (SetDontSavePosition, or SetUserPlaced(false) before the logout)
    StartMoving = function(self)
        S(self).userPlaced = true
        W.startMoving(self)
    end,
    StartSizing = function() end,
    StopMovingOrSizing = function()
        W.stopMoving()
    end,
    RegisterForDrag = function(self, ...)
        S(self).dragButtons = { ... }
    end,
    SetClampedToScreen = function(self, isClamped)
        local s = S(self)
        if (s.clamped == true) ~= (isClamped == true) then
            s.clamped = isClamped
            touchLayoutOf(self) -- (its place may move: kept on the screen, or let off it)
        end
    end,
    IsClampedToScreen = function(self)
        return S(self).clamped == true
    end,
    SetClampRectInsets = function(self, left, right, top, bottom)
        S(self).clampInsets = { left or 0, right or 0, top or 0, bottom or 0 }
    end,
    GetClampRectInsets = function(self)
        return unpack(S(self).clampInsets or { 0, 0, 0, 0 })
    end,
    ClearAttribute = function(self, key)
        local attributes = S(self).attributes
        if attributes then
            attributes[key] = nil
        end
    end,
    SetUserPlaced = function(self, isUserPlaced)
        S(self).userPlaced = isUserPlaced
    end,
    IsUserPlaced = function(self)
        return S(self).userPlaced == true
    end,
    SetDontSavePosition = function(self, isNotSaved)
        S(self).dontSavePosition = isNotSaved and true or nil
    end,
    SetHitRectInsets = function(self, left, right, top, bottom)
        S(self).hitInsets = { left or 0, right or 0, top or 0, bottom or 0 }
    end,
    GetHitRectInsets = function(self)
        local insets = S(self).hitInsets or { 0, 0, 0, 0 }
        return unpack(insets)
    end,
    SetID = function(self, id)
        S(self).frameId = id
    end,
    GetID = function(self)
        return S(self).frameId or 0
    end,
    SetAttribute = function(self, key, value)
        S(self).attributes = S(self).attributes or {}
        S(self).attributes[key] = value
        -- A secure frame's handler runs securely, whoever set the attribute (Blizzard's SecureHelper relies on it)
        sim.runSecurely(sim.runScript, self, "OnAttributeChanged", key, value)
    end,
    -- One name, or the client's three-part asking (prefix, name, suffix) the game's secure buttons use: the most
    -- specific attribute set wins, "*" standing for any modifiers or any button (shift-type1, *type1, shift-type*,
    -- *type*), then the plain name
    GetAttribute = function(self, prefix, name, suffix)
        local attributes = S(self).attributes
        if not attributes then
            return nil
        end
        if name == nil then
            return attributes[prefix]
        end
        prefix, suffix = prefix or "", suffix or ""
        local value = attributes[prefix .. name .. suffix]
        if value == nil then
            value = attributes["*" .. name .. suffix]
        end
        if value == nil then
            value = attributes[prefix .. name .. "*"]
        end
        if value == nil then
            value = attributes["*" .. name .. "*"]
        end
        if value == nil then
            value = attributes[name]
        end
        return value
    end,
    -- The function an attribute holds, run with the arguments (the secure buttons' "menu" action runs "menu-function":
    -- a unit frame's right-click menu); a snippet of text (the restricted environment's) is not run here
    ExecuteAttribute = function(self, name, ...)
        local attributes = S(self).attributes
        local value = attributes and attributes[name]
        if type(value) == "function" then
            return value(...)
        end
        return nil
    end,
    SetAttributeNoHandler = function(self, key, value)
        S(self).attributes = S(self).attributes or {}
        S(self).attributes[key] = value
    end,
    SetClipsChildren = function(self, isClipping)
        S(self).clips = isClipping and true or false
        sim.touchVisual(self) -- (the clip is worked out as the scene is drawn; nothing moves)
    end,
    DoesClipChildren = function(self)
        return S(self).clips == true
    end,
    -- Its regions drawn as one layer, its alpha given to the whole (a fading frame's overlapping parts do not show
    -- through each other)
    SetFlattensRenderLayers = function(self, isOn)
        S(self).flattensRenderLayers = isOn and true or nil
        sim.touchVisual(self)
    end,
    GetFlattensRenderLayers = function(self)
        return S(self).flattensRenderLayers == true
    end,
    SetFrameBuffer = function() end,
    IgnoreDepth = function() end,
    SetDepth = function() end,
    SetHyperlinksEnabled = function(self, isEnabled)
        S(self).hyperlinks = isEnabled
    end,
    EnableDrawLayer = function() end,
    DisableDrawLayer = function() end,
    GetBoundsRect = function(self)
        return self:GetRect()
    end,
    CanChangeProtectedState = function()
        return true
    end,
    SetHighlightLocked = function(self, isLocked)
        S(self).highlightLocked = isLocked and true or nil
        sim.touchVisual(self)
    end,
    RegisterForWidgetSet = function() end,
    UnregisterForWidgetSet = function() end,
    GetDontSavePosition = function(self)
        return S(self).dontSavePosition == true
    end,
    SetUsingParentLevel = function(self, isUsing)
        local s = S(self)
        s.useParentLevel = isUsing and true or nil
        local parentState = isUsing and s.parent and S(s.parent)
        if parentState then
            s.level = parentState.level or 0
        end
        sim.touchVisual(self)
        W.touchOrder()
    end,
    SetWindow = function() end,
}
defineType("Frame", "Region", frameMethods)

function W.getStrata(frame)
    local object = frame
    while object and S(object) do
        if S(object).strata then
            return S(object).strata
        end
        object = S(object).parent
    end
    return "MEDIUM"
end

-- Buttons
local function getButtonFontString(self)
    local s = S(self)
    if not s.fontString then
        s.fontString = createRegion(self, "FontString", nil, "OVERLAY", s.normalFontObject or "GameFontNormal")
        s.fontString:SetPoint("CENTER", self, "CENTER", 0, 0)
    end
    return s.fontString
end

local function setButtonTexture(kind, layer)
    return function(self, texture, ...)
        local s = S(self)
        local region = s[kind]
        if type(texture) == "table" and S(texture) then
            if region and region ~= texture then
                region:Hide()
            end
            region = texture
            S(region).parent = self
            if #S(region).points == 0 then
                region:SetAllPoints(self)
            end
        else
            if texture == nil or texture == "" then
                if region then
                    S(region).texture, S(region).atlas = nil, nil
                    sim.markChanged(region)
                    sim.touch(self)
                end
                return
            end
            if not region then
                region = createRegion(self, "Texture", nil, layer)
                region:SetAllPoints(self)
            end
            region:SetTexture(texture)
        end
        S(region).role = kind
        if kind == "highlight" then
            S(region).layer = "HIGHLIGHT"
            S(region).blend = ... or S(region).blend or "ADD"
        end
        s[kind] = region
        sim.markChanged(region) -- (its own state was set here, not by its setters)
        sim.touch(self)
    end
end

local function setButtonAtlas(kind, layer)
    return function(self, atlas)
        local s = S(self)
        if not s[kind] then
            s[kind] = createRegion(self, "Texture", nil, layer)
            s[kind]:SetAllPoints(self)
        end
        s[kind]:SetAtlas(atlas)
        S(s[kind]).role = kind
        if kind == "highlight" then
            S(s[kind]).layer = "HIGHLIGHT"
        end
        -- (the button now has this state's art: which of its textures show is decided anew)
        sim.touch(self)
    end
end

local buttonMethods = {
    SetText = function(self, text)
        getButtonFontString(self):SetText(text)
    end,
    GetText = function(self)
        return S(self).fontString and S(self).fontString:GetText()
    end,
    SetFormattedText = function(self, pattern, ...)
        self:SetText(string.format(pattern, ...))
    end,
    GetFontString = function(self)
        return getButtonFontString(self)
    end,
    SetFontString = function(self, fontString)
        S(self).fontString = fontString
    end,
    GetTextWidth = function(self)
        return getButtonFontString(self):GetStringWidth()
    end,
    GetTextHeight = function(self)
        return getButtonFontString(self):GetStringHeight()
    end,
    -- A font object given by its name (the XML's <NormalFont style="GameFontNormal"/>, or an addon's string) is kept as
    -- the object: the getters hand back a font object, as the client's (an addon copies it: CopyFontObject, GetFont)
    SetNormalFontObject = function(self, fontObject)
        fontObject = W.resolveFontObject(fontObject)
        S(self).normalFontObject = fontObject
        getButtonFontString(self):SetFontObject(fontObject)
    end,
    GetNormalFontObject = function(self)
        return S(self).normalFontObject
    end,
    SetHighlightFontObject = function(self, fontObject)
        S(self).highlightFontObject = W.resolveFontObject(fontObject)
    end,
    SetDisabledFontObject = function(self, fontObject)
        S(self).disabledFontObject = W.resolveFontObject(fontObject)
    end,
    GetHighlightFontObject = function(self)
        return S(self).highlightFontObject
    end,
    GetDisabledFontObject = function(self)
        return S(self).disabledFontObject
    end,
    SetNormalTexture = setButtonTexture("normal", "ARTWORK"),
    SetPushedTexture = setButtonTexture("pushed", "ARTWORK"),
    SetHighlightTexture = setButtonTexture("highlight", "HIGHLIGHT"),
    SetDisabledTexture = setButtonTexture("disabled", "ARTWORK"),
    SetNormalAtlas = setButtonAtlas("normal", "ARTWORK"),
    SetPushedAtlas = setButtonAtlas("pushed", "ARTWORK"),
    SetHighlightAtlas = setButtonAtlas("highlight", "HIGHLIGHT"),
    SetDisabledAtlas = setButtonAtlas("disabled", "ARTWORK"),
    GetNormalTexture = function(self)
        return S(self).normal
    end,
    GetPushedTexture = function(self)
        return S(self).pushed
    end,
    GetHighlightTexture = function(self)
        return S(self).highlight
    end,
    GetDisabledTexture = function(self)
        return S(self).disabled
    end,
    ClearNormalTexture = function(self)
        if S(self).normal then
            S(self).normal:Hide()
        end
    end,
    ClearPushedTexture = function(self)
        if S(self).pushed then
            S(self).pushed:Hide()
        end
    end,
    ClearHighlightTexture = function(self)
        if S(self).highlight then
            S(self).highlight:Hide()
        end
    end,
    ClearDisabledTexture = function(self)
        if S(self).disabled then
            S(self).disabled:Hide()
        end
    end,
    LockHighlight = function(self)
        S(self).highlightLocked = true
        sim.touchVisual(self)
    end,
    UnlockHighlight = function(self)
        S(self).highlightLocked = nil
        sim.touchVisual(self)
    end,
    Enable = function(self)
        self:SetEnabled(true)
    end,
    Disable = function(self)
        self:SetEnabled(false)
    end,
    SetEnabled = function(self, isEnabled)
        local s = S(self)
        local wasEnabled = s.enabled ~= false
        s.enabled = isEnabled and true or false
        if wasEnabled == s.enabled then
            return
        end
        sim.touchVisual(self)
        if wasEnabled ~= s.enabled then
            sim.runScript(self, s.enabled and "OnEnable" or "OnDisable")
        end
    end,
    IsEnabled = function(self)
        return S(self).enabled ~= false
    end,
    -- The clicks it acts on, in any case and as lists ("anyUp" from LibDBIcon's minimap buttons; XML's
    -- registerForClicks="LeftButtonUp, RightButtonUp", one string), as the client reads them: kept in lower case
    RegisterForClicks = function(self, ...)
        local clicks = {}
        for _, click in ipairs({ ... }) do
            for name in tostring(click):gmatch("[^,%s]+") do
                clicks[name:lower()] = true
            end
        end
        S(self).clicks = clicks
    end,
    RegisterForMouse = function() end,
    Click = function(self, button, isDown)
        W.clickButton(self, button or "LeftButton", isDown)
    end,
    SetButtonState = function(self, buttonState, isLocked)
        S(self).buttonState = buttonState
        sim.touchVisual(self)
    end,
    GetButtonState = function(self)
        return S(self).buttonState or "NORMAL"
    end,
    SetPushedTextOffset = function() end,
    GetPushedTextOffset = function()
        return 1, -1
    end,
    SetMotionScriptsWhileDisabled = function(self, isEnabled)
        S(self).motionWhileDisabled = isEnabled
        sim.touchVisual(self) -- (a disabled button's highlight follows it)
    end,
    GetMotionScriptsWhileDisabled = function(self)
        return S(self).motionWhileDisabled == true
    end,
}
defineType("Button", "Frame", buttonMethods)

defineType("CheckButton", "Button", {
    SetChecked = function(self, isChecked)
        S(self).checked = isChecked and true or false
        sim.touchVisual(self)
    end,
    GetChecked = function(self)
        return S(self).checked == true
    end,
    SetCheckedTexture = setButtonTexture("checkedTexture", "OVERLAY"),
    GetCheckedTexture = function(self)
        return S(self).checkedTexture
    end,
    SetDisabledCheckedTexture = setButtonTexture("disabledChecked", "OVERLAY"),
    GetDisabledCheckedTexture = function(self)
        return S(self).disabledChecked
    end,
})

-- Edit boxes
local function getEditFontString(self)
    local s = S(self)
    if not s.editText then
        s.editText = createRegion(self, "FontString", nil, "OVERLAY", "ChatFontNormal")
        S(s.editText).isEditText = true
        s.editText:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
        s.editText:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
        S(s.editText).justifyH = "LEFT"
    end
    return s.editText
end

local function setEditText(self, text, isUser)
    local s = S(self)
    text = tostring(text or "")
    if s.maxLetters and s.maxLetters > 0 and #text > s.maxLetters then
        text = text:sub(1, s.maxLetters)
    end
    if s.numeric then
        text = text:gsub("[^%d]", "")
    end
    local isChanged = s.text ~= text
    s.text = text
    s.cursor = #text
    getEditFontString(self):SetText(s.password and string.rep("*", #text) or text)
    if isChanged then
        if isUser or W.isVisible(self) then
            sim.runScript(self, "OnTextChanged", isUser == true)
        elseif not s.isTextChangePending then
            -- A hidden box tells of its new text at the next frame, not at once: inferred from the game's own code,
            -- which sets a box's number in its OnLoad while the frame around it, whose callbacks the box's
            -- OnTextChanged calls, has not loaded yet (the currency transfer's amount selector), and runs clean
            s.isTextChangePending = true
            sim.addTimer(0, function()
                s.isTextChangePending = nil
                sim.runScript(self, "OnTextChanged", false)
            end)
        end
    end
    sim.runScript(self, "OnTextSet")
end
W.setEditText = setEditText

defineType("EditBox", "Frame", {
    SetText = function(self, text)
        setEditText(self, text, false)
    end,
    GetText = function(self)
        return S(self).text or ""
    end,
    GetDisplayText = function(self)
        return S(self).text or ""
    end,
    SetNumber = function(self, number)
        setEditText(self, tostring(number or 0), false)
    end,
    GetNumber = function(self)
        return tonumber(S(self).text) or 0
    end,
    GetNumLetters = function(self)
        return #(S(self).text or "")
    end,
    Insert = function(self, text)
        setEditText(self, (S(self).text or "") .. tostring(text), false)
    end,
    SetFocus = function(self)
        W.setFocus(self)
    end,
    ClearFocus = function(self)
        if W.focus == self then
            W.setFocus(nil)
        end
    end,
    HasFocus = function(self)
        return W.focus == self
    end,
    SetAutoFocus = function(self, isAuto)
        S(self).autoFocus = isAuto
    end,
    IsAutoFocus = function(self)
        return S(self).autoFocus ~= false
    end,
    SetMultiLine = function(self, isMulti)
        S(self).multiLine = isMulti
        getEditFontString(self):SetJustifyV(isMulti and "TOP" or "MIDDLE")
    end,
    IsMultiLine = function(self)
        return S(self).multiLine == true
    end,
    SetMaxLetters = function(self, maxLetters)
        S(self).maxLetters = maxLetters
    end,
    GetMaxLetters = function(self)
        return S(self).maxLetters or 0
    end,
    SetMaxBytes = function() end,
    SetNumeric = function(self, isNumeric)
        S(self).numeric = isNumeric
    end,
    IsNumeric = function(self)
        return S(self).numeric == true
    end,
    SetPassword = function(self, isPassword)
        S(self).password = isPassword
    end,
    HighlightText = function(self, from, to)
        S(self).highlighted = true
        sim.touchVisual(self)
    end,
    ClearHighlightText = function(self)
        S(self).highlighted = nil
        sim.touchVisual(self)
    end,
    SetCursorPosition = function(self, position)
        S(self).cursor = position
    end,
    GetCursorPosition = function(self)
        return S(self).cursor or 0
    end,
    GetTextInsets = function(self)
        local insets = S(self).textInsets or { 0, 0, 0, 0 }
        return insets[1], insets[2], insets[3], insets[4]
    end,
    SetTextInsets = function(self, left, right, top, bottom)
        S(self).textInsets = { left or 0, right or 0, top or 0, bottom or 0 }
        local text = getEditFontString(self)
        text:ClearAllPoints()
        text:SetPoint("TOPLEFT", self, "TOPLEFT", left or 0, -(top or 0))
        text:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -(right or 0), bottom or 0)
    end,
    SetFontObject = function(self, fontObject)
        getEditFontString(self):SetFontObject(fontObject)
    end,
    GetFontObject = function(self)
        return getEditFontString(self):GetFontObject()
    end,
    SetFont = function(self, ...)
        return getEditFontString(self):SetFont(...)
    end,
    GetFont = function(self)
        return getEditFontString(self):GetFont()
    end,
    SetTextColor = function(self, ...)
        getEditFontString(self):SetTextColor(...)
    end,
    SetJustifyH = function(self, justify)
        getEditFontString(self):SetJustifyH(justify)
    end,
    SetJustifyV = function(self, justify)
        getEditFontString(self):SetJustifyV(justify)
    end,
    SetSpacing = function(self, spacing)
        getEditFontString(self):SetSpacing(spacing)
    end,
    SetShadowOffset = function(self, ...)
        getEditFontString(self):SetShadowOffset(...)
    end,
    SetCountInvisibleLetters = function() end,
    SetBlinkSpeed = function() end,
    SetHistoryLines = function() end,
    AddHistoryLine = function() end,
    SetAltArrowKeyMode = function() end,
    SetEnabled = function(self, isEnabled)
        S(self).enabled = isEnabled and true or false
    end,
    Enable = function(self)
        S(self).enabled = true
    end,
    Disable = function(self)
        S(self).enabled = false
    end,
    IsEnabled = function(self)
        return S(self).enabled ~= false
    end,
    GetInputLanguage = function()
        return "ROMAN"
    end,
    SetHighlightColor = function() end,
    SetVisibleTextByteLimit = function() end,
})

-- Scroll frames
defineType("ScrollFrame", "Frame", {
    SetScrollChild = function(self, child)
        local s = S(self)
        if s.scrollChild and S(s.scrollChild) then
            S(s.scrollChild).scrollChildOf = nil
        end
        s.scrollChild = child
        if child then
            child:SetParent(self)
            S(child).scrollChildOf = self
            W.watchScrollRange(self)
        end
        -- (it clips its scroll child, not its other children: lua/scene.lua getClip)
        sim.touch(self)
    end,
    GetScrollChild = function(self)
        return S(self).scrollChild
    end,
    SetVerticalScroll = function(self, offset)
        -- Fired only on a real change, as the game does: scroll bars set it back from their own callbacks
        offset = offset or 0
        if (S(self).verticalScroll or 0) == offset then
            return
        end
        S(self).verticalScroll = offset
        sim.markChanged(self) -- (its offset is its own: the native layout reads it from the scroll frame)
        if S(self).scrollChild then
            touchLayoutOf(S(self).scrollChild)
        else
            sim.touchVisual(self)
        end
        sim.runScript(self, "OnVerticalScroll", offset)
    end,
    GetVerticalScroll = function(self)
        return S(self).verticalScroll or 0
    end,
    SetHorizontalScroll = function(self, offset)
        -- Fired only on a real change, as the game does: scroll bars set it back from their own callbacks
        offset = offset or 0
        if (S(self).horizontalScroll or 0) == offset then
            return
        end
        S(self).horizontalScroll = offset
        sim.markChanged(self) -- (its offset is its own: the native layout reads it from the scroll frame)
        if S(self).scrollChild then
            touchLayoutOf(S(self).scrollChild)
        else
            sim.touchVisual(self)
        end
        sim.runScript(self, "OnHorizontalScroll", offset)
    end,
    GetHorizontalScroll = function(self)
        return S(self).horizontalScroll or 0
    end,
    GetVerticalScrollRange = function(self)
        local child = S(self).scrollChild
        if not child then
            return 0
        end
        return math.max(0, child:GetHeight() - self:GetHeight())
    end,
    GetHorizontalScrollRange = function(self)
        local child = S(self).scrollChild
        if not child then
            return 0
        end
        return math.max(0, child:GetWidth() - self:GetWidth())
    end,
    -- Told only when the range changed, as the client does: a handler that measures again (calls this) from
    -- OnScrollRangeChanged would otherwise call itself for ever (ForeverDungeonJournal's settings pages do)
    UpdateScrollChildRect = function(self)
        local s = S(self)
        local horizontal, vertical = self:GetHorizontalScrollRange(), self:GetVerticalScrollRange()
        -- (changed by more than rounding, as sizes are told: W.fireSizeChanges)
        local told = s.toldScrollRange
        if told and math.abs(told[1] - horizontal) <= 0.001 and math.abs(told[2] - vertical) <= 0.001 then
            return
        end
        s.toldScrollRange = { horizontal, vertical }
        sim.runScript(self, "OnScrollRangeChanged", horizontal, vertical)
    end,
})

-- Sliders and bars
local function setBarValue(self, value)
    local s = S(self)
    local minimum, maximum = s.minValue or 0, s.maxValue or 1
    value = math.max(minimum, math.min(maximum, value or 0))
    if s.valueStep and s.valueStep > 0 and s.obeyStep ~= false then
        value = minimum + math.floor((value - minimum) / s.valueStep + 0.5) * s.valueStep
    end
    local isChanged = s.value ~= value
    s.value = value
    if isChanged then
        sim.touchVisual(self) -- (the thumb or fill is placed from the value as the scene is drawn)
    end
    if isChanged then
        sim.runScript(self, "OnValueChanged", value, false)
    end
end
W.setBarValue = setBarValue

local valueMethods = {
    SetMinMaxValues = function(self, minimum, maximum)
        local s = S(self)
        s.minValue, s.maxValue = minimum, maximum
        sim.runScript(self, "OnMinMaxChanged", minimum, maximum)
        if s.value then
            setBarValue(self, s.value)
        end
        sim.touchVisual(self)
    end,
    GetMinMaxValues = function(self)
        return S(self).minValue or 0, S(self).maxValue or 1
    end,
    SetValue = function(self, value)
        setBarValue(self, value)
    end,
    GetValue = function(self)
        return S(self).value or 0
    end,
    SetOrientation = function(self, orientation)
        S(self).orientation = orientation
        sim.touchVisual(self)
    end,
    GetOrientation = function(self)
        return W.orientationOf(self)
    end,
}
---The way a bar or slider runs: as set, else the widget's own default (a slider VERTICAL, as in the client: every
---horizontal one of the game's says so, UISliderTemplate, MinimalSliderTemplate, and UIPanelScrollBarTemplate says
---nothing; a status bar HORIZONTAL). Taken as HORIZONTAL, a scroll bar's thumb moved sideways in its 16 pixels.
function W.orientationOf(frame)
    local s = S(frame)
    if s.orientation then
        return s.orientation
    end
    return s.type == "Slider" and "VERTICAL" or "HORIZONTAL"
end
local sliderMethods = {
    SetValueStep = function(self, step)
        S(self).valueStep = step
    end,
    GetValueStep = function(self)
        return S(self).valueStep or 0
    end,
    SetObeyStepOnDrag = function(self, isObeyed)
        S(self).obeyStep = isObeyed
    end,
    SetStepsPerPage = function() end,
    SetThumbTexture = function(self, texture)
        local s = S(self)
        if type(texture) == "table" and S(texture) then
            s.thumb = texture
        else
            s.thumb = s.thumb or createRegion(self, "Texture", nil, "OVERLAY")
            s.thumb:SetTexture(texture)
        end
        S(s.thumb).role = "thumb"
        sim.markChanged(s.thumb)
        sim.touchVisual(self)
    end,
    GetThumbTexture = function(self)
        return S(self).thumb
    end,
    Enable = function(self)
        S(self).enabled = true
        sim.touchVisual(self)
    end,
    Disable = function(self)
        S(self).enabled = false
        sim.touchVisual(self)
    end,
    SetEnabled = function(self, isEnabled)
        S(self).enabled = isEnabled and true or false
        sim.touchVisual(self)
    end,
    IsEnabled = function(self)
        return S(self).enabled ~= false
    end,
    IsDraggingThumb = function()
        return false
    end,
}
for key, value in pairs(valueMethods) do
    sliderMethods[key] = sliderMethods[key] or value
end
defineType("Slider", "Frame", sliderMethods)

local statusMethods = {
    SetStatusBarTexture = function(self, texture)
        local s = S(self)
        if type(texture) == "table" and S(texture) then
            s.barTexture = texture
        else
            s.barTexture = s.barTexture or createRegion(self, "Texture", nil, "ARTWORK")
            -- An atlas's name as well as a file, as in the client (the player frame's mana bar)
            local isAtlas = type(texture) == "string"
                and not texture:find("[\\/]")
                and W.getAtlasInfo
                and W.getAtlasInfo(texture)
            if isAtlas then
                s.barTexture:SetAtlas(texture)
            else
                s.barTexture:SetTexture(texture)
            end
        end
        S(s.barTexture).role = "bar"
        sim.markChanged(s.barTexture)
        sim.touchVisual(self) -- (the fill is placed from the value as the scene is drawn)
    end,
    GetStatusBarTexture = function(self)
        local s = S(self)
        if not s.barTexture then
            self:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        end
        return s.barTexture
    end,
    SetStatusBarColor = function(self, r, g, b, a)
        self:GetStatusBarTexture():SetVertexColor(r, g, b, a)
    end,
    SetStatusBarDesaturated = function(self, isDesaturated)
        self:GetStatusBarTexture():SetDesaturated(isDesaturated)
    end,
    IsStatusBarDesaturated = function(self)
        return self:GetStatusBarTexture():IsDesaturated()
    end,
    GetStatusBarColor = function(self)
        return self:GetStatusBarTexture():GetVertexColor()
    end,
    SetStatusBarAtlas = function(self, atlas)
        self:GetStatusBarTexture():SetAtlas(atlas)
    end,
    SetReverseFill = function(self, isReversed)
        S(self).reverseFill = isReversed
        sim.touchVisual(self)
    end,
    GetReverseFill = function(self)
        return S(self).reverseFill == true
    end,
    -- STANDARD (from the left, or the bottom), STANDARD_NO_RANGE_FILL, CENTER (out from the middle), REVERSE (from
    -- the right, or the top)
    -- (the client's Enum.StatusBarFillStyle, 0 to 3, or its name; GetFillStyle answers the number, as measured)
    SetFillStyle = function(self, style)
        local names = { [0] = "STANDARD", "STANDARD_NO_RANGE_FILL", "CENTER", "REVERSE" }
        S(self).fillStyle = names[tonumber(style) or -1] or (style and tostring(style):upper()) or "STANDARD"
        sim.touchVisual(self)
    end,
    GetFillStyle = function(self)
        local numbers = { STANDARD = 0, STANDARD_NO_RANGE_FILL = 1, CENTER = 2, REVERSE = 3 }
        return numbers[S(self).fillStyle or "STANDARD"] or 0
    end,
    SetRotatesTexture = function(self, isOn)
        S(self).rotatesTexture = isOn and true or false
        sim.touchVisual(self)
    end,
    GetRotatesTexture = function(self)
        return S(self).rotatesTexture == true
    end,
}
for key, value in pairs(valueMethods) do
    statusMethods[key] = statusMethods[key] or value
end
defineType("StatusBar", "Frame", statusMethods)

W.COOLDOWN_BLING_SECONDS = 0.4
-- A cooldown, as the client draws it over an action button's icon: a swipe in its colour (or texture) over the part
-- of the time still to run, sweeping clockwise from the top (reversed: over the part gone), the seconds left in its
-- middle when the countdownForCooldowns setting is on; OnCooldownDone when it runs out. Drawn by scene.lua
-- (exportCooldown); while one runs the picture changes every frame (sim.liveVisuals)
sim.liveVisuals = sim.liveVisuals or setmetatable({}, { __mode = "k" })
local function cooldownState(self)
    local s = S(self)
    s.swipe = s.swipe
        -- (the client's defaults, measured: the edge drawn, at an edge scale of the square root of 2)
        or {
            drawSwipe = true,
            drawEdge = true,
            drawBling = true,
            color = { 0, 0, 0, 0.8 },
            reverse = false,
            edgeScale = math.sqrt(2),
        }
    return s
end
-- Running: kept on the clock (its swipe drawn each frame) and told when it runs out
local function startCooldown(self, start, duration, modRate)
    local s = cooldownState(self)
    start, duration = tonumber(start) or 0, tonumber(duration) or 0
    if s.cooldownTimer then
        s.cooldownTimer.cancelled = true
        s.cooldownTimer = nil
    end
    if duration <= 0 then
        s.cooldown = nil
        sim.liveVisuals[self] = nil
        sim.touchVisual(self)
        return
    end
    s.cooldown = { start = start, duration = duration, modRate = tonumber(modRate) or 1 }
    sim.liveVisuals[self] = true
    sim.touchVisual(self)
    local left = start + duration - sim.now
    if left > 0 then
        local cooldown = s.cooldown
        s.cooldownTimer = sim.addTimer(left, function()
            if s.cooldown ~= cooldown or s.paused then
                return
            end
            s.cooldown = nil
            s.cooldownTimer = nil
            sim.touchVisual(self)
            -- The bling: a flash as it runs out, a moment long (kept on the clock while it shows)
            if s.swipe and s.swipe.drawBling ~= false then
                s.blingAt = sim.now
                sim.addTimer(W.COOLDOWN_BLING_SECONDS, function()
                    if s.blingAt and sim.now - s.blingAt >= W.COOLDOWN_BLING_SECONDS - 0.001 then
                        s.blingAt = nil
                        if not s.cooldown then
                            sim.liveVisuals[self] = nil
                        end
                        sim.touchVisual(self)
                    end
                end)
            else
                sim.liveVisuals[self] = nil
            end
            local handler = s.scripts and s.scripts.OnCooldownDone
            if handler then
                sim.call(handler, self)
            end
        end)
    else
        s.cooldown = nil
        sim.liveVisuals[self] = nil
    end
end
defineType("Cooldown", "Frame", {
    SetCooldown = function(self, start, duration, modRate)
        startCooldown(self, start, duration, modRate)
    end,
    SetCooldownDuration = function(self, duration, modRate)
        startCooldown(self, sim.now, duration, modRate)
    end,
    SetCooldownFromExpirationTime = function(self, expiration, duration, modRate)
        startCooldown(self, (tonumber(expiration) or 0) - (tonumber(duration) or 0), duration, modRate)
    end,
    -- (a start in the real clock's seconds: time())
    SetCooldownUNIX = function(self, start, duration, modRate)
        startCooldown(self, (tonumber(start) or 0) - os.time() + sim.now, duration, modRate)
    end,
    GetCooldownTimes = function(self)
        local cooldown = S(self).cooldown
        return cooldown and cooldown.start * 1000 or 0, cooldown and cooldown.duration * 1000 or 0
    end,
    GetCooldownDuration = function(self)
        local cooldown = S(self).cooldown
        return cooldown and cooldown.duration * 1000 or 0
    end,
    GetCooldownDisplayDuration = function(self)
        local cooldown = S(self).cooldown
        return cooldown and cooldown.duration or 0
    end,
    Clear = function(self)
        startCooldown(self, 0, 0)
    end,
    SetDrawSwipe = function(self, isOn)
        cooldownState(self).swipe.drawSwipe = isOn and true or false
        sim.touchVisual(self)
    end,
    GetDrawSwipe = function(self)
        return cooldownState(self).swipe.drawSwipe
    end,
    SetDrawEdge = function(self, isOn)
        cooldownState(self).swipe.drawEdge = isOn and true or false
        sim.touchVisual(self)
    end,
    GetDrawEdge = function(self)
        return cooldownState(self).swipe.drawEdge
    end,
    SetDrawBling = function(self, isOn)
        cooldownState(self).swipe.drawBling = isOn and true or false
    end,
    GetDrawBling = function(self)
        return cooldownState(self).swipe.drawBling
    end,
    SetSwipeColor = function(self, r, g, b, a)
        cooldownState(self).swipe.color = { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0, tonumber(a) or 1 }
        sim.touchVisual(self)
    end,
    SetSwipeTexture = function(self, texture, r, g, b, a)
        local swipe = cooldownState(self).swipe
        swipe.texture = texture
        if r then
            swipe.color = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
        end
        sim.touchVisual(self)
    end,
    SetReverse = function(self, isReversed)
        cooldownState(self).swipe.reverse = isReversed and true or false
        sim.touchVisual(self)
    end,
    GetReverse = function(self)
        return cooldownState(self).swipe.reverse
    end,
    SetHideCountdownNumbers = function(self, isHidden)
        cooldownState(self).swipe.hideNumbers = isHidden and true or false
        sim.touchVisual(self)
    end,
    SetEdgeTexture = function(self, texture, r, g, b, a)
        local swipe = cooldownState(self).swipe
        swipe.edgeTexture = texture
        if r then
            swipe.edgeColor = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
        end
        sim.touchVisual(self)
    end,
    SetEdgeColor = function(self, r, g, b, a)
        cooldownState(self).swipe.edgeColor = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
        sim.touchVisual(self)
    end,
    GetEdgeColor = function(self)
        return unpack(cooldownState(self).swipe.edgeColor or { 1, 1, 1, 1 })
    end,
    SetBlingTexture = function(self, texture)
        cooldownState(self).swipe.blingTexture = texture
    end,
    SetUseCircularEdge = function(self, isCircular)
        cooldownState(self).swipe.isCircularEdge = isCircular and true or false
    end,
    SetEdgeScale = function(self, scale)
        cooldownState(self).swipe.edgeScale = tonumber(scale) or 1
    end,
    GetEdgeScale = function(self)
        return cooldownState(self).swipe.edgeScale or math.sqrt(2)
    end,
    SetCountdownFont = function() end,
    SetCountdownAbbrevThreshold = function() end,
    SetMinimumCountdownDuration = function() end,
    SetUseAuraDisplayTime = function() end,
    SetTexCoordRange = function() end,
    -- Held: the swipe stays where it is, and goes on from there
    Pause = function(self)
        local s = cooldownState(self)
        if s.cooldown and not s.paused then
            s.paused = sim.now
            sim.liveVisuals[self] = nil
        end
    end,
    Resume = function(self)
        local s = cooldownState(self)
        if s.cooldown and s.paused then
            local cooldown = s.cooldown
            local held = sim.now - s.paused
            s.paused = nil
            startCooldown(self, cooldown.start + held, cooldown.duration, cooldown.modRate)
        end
    end,
    IsPaused = function(self)
        return S(self).paused ~= nil
    end,
})

-- A message frame (MessageFrame; ScrollingMessageFrame, an addon's chat window): its messages each with its colour,
-- in the frame's own font, justification and spacing (the font instance methods, as a font string's), new ones at the
-- bottom (or at the top: insertMode TOP, the error banner), fading out after timeVisible when fading, scrolled by
-- whole messages; drawn by scene.lua (exportMessageFrame)
local MAX_MESSAGES = 1000
local messageFrameMethods = {
    AddMessage = function(self, text, r, g, b, a)
        local s = S(self)
        s.messages = s.messages or {}
        local message = {
            text = tostring(text),
            r = r or 1,
            g = g or 1,
            b = b or 1,
            a = a or 1,
            time = sim.now,
            id = sim.newId(),
        }
        table.insert(s.messages, message)
        local maxLines = s.maxLines or MAX_MESSAGES
        while #s.messages > maxLines do
            table.remove(s.messages, 1)
        end
        if s.isChat then
            sim.print(text, r, g, b)
        end
        -- (faded out: drawn again then, gone)
        if s.fading ~= false then
            sim.addTimer((s.timeVisible or 10) + (s.fadeDuration or 3), sim.touchVisual, 1)
        end
        touchLayoutOf(self)
    end,
    -- An older message put before the others (a chat window filled from its history)
    BackFillMessage = function(self, text, r, g, b, a)
        local s = S(self)
        s.messages = s.messages or {}
        table.insert(
            s.messages,
            1,
            { text = tostring(text), r = r or 1, g = g or 1, b = b or 1, a = a or 1, time = sim.now, id = sim.newId() }
        )
        touchLayoutOf(self)
    end,
    Clear = function(self)
        local s = S(self)
        s.messages = {}
        s.scrollOffset = 0
        touchLayoutOf(self)
    end,
    GetNumMessages = function(self)
        return #(S(self).messages or {})
    end,
    GetMessageInfo = function(self, index)
        local message = (S(self).messages or {})[index]
        if message then
            return message.text, message.r, message.g, message.b, message.a
        end
    end,
    RemoveMessagesByPredicate = function(self, predicate)
        local s = S(self)
        for index = #(s.messages or {}), 1, -1 do
            local message = s.messages[index]
            if predicate(message.text, message.r, message.g, message.b) then
                table.remove(s.messages, index)
            end
        end
        touchLayoutOf(self)
    end,
    SetFading = function(self, isFading)
        S(self).fading = isFading ~= false
        sim.touchVisual(self)
    end,
    GetFading = function(self)
        return S(self).fading ~= false
    end,
    SetTimeVisible = function(self, seconds)
        S(self).timeVisible = tonumber(seconds)
        sim.touchVisual(self)
    end,
    GetTimeVisible = function(self)
        return S(self).timeVisible or 10
    end,
    SetFadeDuration = function(self, seconds)
        S(self).fadeDuration = tonumber(seconds)
    end,
    GetFadeDuration = function(self)
        return S(self).fadeDuration or 3
    end,
    SetFadePower = function() end,
    ResetAllFadeTimes = function(self)
        for _, message in ipairs(S(self).messages or {}) do
            message.time = sim.now
        end
        sim.touchVisual(self)
    end,
    SetMaxLines = function(self, lines)
        S(self).maxLines = tonumber(lines)
    end,
    GetMaxLines = function(self)
        return S(self).maxLines or MAX_MESSAGES
    end,
    SetInsertMode = function(self, mode)
        S(self).insertMode = (mode == "TOP" or mode == 1) and "TOP" or "BOTTOM"
        touchLayoutOf(self)
    end,
    GetInsertMode = function(self)
        return S(self).insertMode or "BOTTOM"
    end,
    -- Scrolled by whole messages: the offset is how many of the newest are below the view
    SetScrollOffset = function(self, offset)
        local s = S(self)
        s.scrollOffset = math.max(0, math.min(tonumber(offset) or 0, math.max(0, #(s.messages or {}) - 1)))
        touchLayoutOf(self)
    end,
    GetScrollOffset = function(self)
        return S(self).scrollOffset or 0
    end,
    GetMaxScrollRange = function(self)
        return math.max(0, #(S(self).messages or {}) - 1)
    end,
    ScrollUp = function(self)
        self:SetScrollOffset(self:GetScrollOffset() + 1)
    end,
    ScrollDown = function(self)
        self:SetScrollOffset(self:GetScrollOffset() - 1)
    end,
    PageUp = function(self)
        self:SetScrollOffset(self:GetScrollOffset() + 5)
    end,
    PageDown = function(self)
        self:SetScrollOffset(self:GetScrollOffset() - 5)
    end,
    ScrollToTop = function(self)
        self:SetScrollOffset(self:GetMaxScrollRange())
    end,
    ScrollToBottom = function(self)
        self:SetScrollOffset(0)
    end,
    ScrollByAmount = function(self, amount)
        self:SetScrollOffset(self:GetScrollOffset() + (tonumber(amount) or 0))
    end,
    AtTop = function(self)
        return self:GetScrollOffset() >= self:GetMaxScrollRange()
    end,
    AtBottom = function(self)
        return self:GetScrollOffset() == 0
    end,
    SetHyperlinksEnabled = function(self, isEnabled)
        S(self).hyperlinks = isEnabled ~= false
    end,
    GetHyperlinksEnabled = function(self)
        return S(self).hyperlinks == true
    end,
    SetIndentedWordWrap = function(self, isIndented)
        S(self).indentedWordWrap = isIndented == true
    end,
    GetIndentedWordWrap = function(self)
        return S(self).indentedWordWrap == true
    end,
    AddMsg = function(self, ...)
        self:AddMessage(...)
    end,
}
-- Its font, as a font string's (SetFont, SetFontObject, SetJustifyH, SetSpacing, SetShadowOffset...)
for _, name in ipairs({
    "SetFont",
    "GetFont",
    "SetFontHeight",
    "SetFontObject",
    "GetFontObject",
    "SetTextColor",
    "GetTextColor",
    "SetJustifyH",
    "GetJustifyH",
    "SetJustifyV",
    "GetJustifyV",
    "SetSpacing",
    "GetSpacing",
    "SetShadowColor",
    "GetShadowColor",
    "SetShadowOffset",
    "GetShadowOffset",
}) do
    messageFrameMethods[name] = fontStringMethods[name]
end
defineType("MessageFrame", "Frame", messageFrameMethods)
defineType("ScrollingMessageFrame", "MessageFrame", {})

-- The help window's web page (SimpleBrowserAPI): no pages are shown here, so going anywhere does nothing
do
    local function nothing() end
    defineType("Browser", "Frame", {
        NavigateHome = nothing,
        NavigateBack = nothing,
        NavigateForward = nothing,
        NavigateReload = nothing,
        NavigateStop = nothing,
        OpenTicket = nothing,
        OpenExternalLink = nothing,
        CopyExternalLink = nothing,
        DeleteCookies = nothing,
        ClearFocus = nothing,
        SetFocus = nothing,
        SetZoom = function(self, zoom)
            S(self).browserZoom = zoom
        end,
    })
end

defineType("Model", "Frame", {
    SetModel = function() end,
    SetDisplayInfo = function() end,
    SetUnit = function() end,
    SetCamDistanceScale = function() end,
    SetFacing = function() end,
    SetPosition = function() end,
    ClearModel = function() end,
    SetCreature = function() end,
    SetPortraitZoom = function() end,
    SetRotation = function() end,
    RefreshUnit = function() end,
    SetSequence = function() end,
})
defineType("PlayerModel", "Model", {})
defineType("DressUpModel", "PlayerModel", {})
defineType("ModelScene", "Frame", {
    -- The space round the drawn scene (the client keeps it; nothing is drawn here)
    SetViewInsets = function(self, left, right, top, bottom)
        S(self).viewInsets = { left or 0, right or 0, top or 0, bottom or 0 }
    end,
    GetViewInsets = function(self)
        local insets = S(self).viewInsets or { 0, 0, 0, 0 }
        return insets[1], insets[2], insets[3], insets[4]
    end,
})
-- The map's native frame types; their methods come from the client's documentation (docs.lua)
defineType("Blob", "Frame", {})
for _, typeName in ipairs({ "QuestPOIFrame", "ScenarioPOIFrame", "ArchaeologyDigSiteFrame" }) do
    defineType(typeName, "Blob", {}) -- the game's POI frames are blobs
end
defineType("FogOfWarFrame", "Frame", {})
-- The map's group members (the player's arrow, the party's dots): the client draws each unit added, where the unit
-- stands on the frame's map, at its size and colour, the player's turned by their facing (scene.lua draws them)
local function findUnit(self, unit)
    for _, entry in ipairs(S(self).units or {}) do
        if entry.unit == unit then
            return entry
        end
    end
end
defineType("UnitPositionFrame", "Frame", {
    AddUnit = function(self, unit, asset, width, height, r, g, b, a, sublayer, showFacing)
        local state = S(self)
        state.units = state.units or {}
        local entry = findUnit(self, unit) or {}
        if not entry.unit then
            state.units[#state.units + 1] = entry
        end
        entry.unit, entry.asset, entry.width, entry.height = unit, asset, width or 40, height or width or 40
        entry.color, entry.sublayer, entry.showFacing =
            { r or 1, g or 1, b or 1, a or 1 }, sublayer or 7, showFacing == true
        sim.touch(self)
    end,
    ClearUnits = function(self)
        S(self).units = {}
        sim.touch(self)
    end,
    FinalizeUnits = function() end,
    SetUnitColor = function(self, unit, r, g, b, a)
        local entry = findUnit(self, unit)
        if entry then
            entry.color = { r or 1, g or 1, b or 1, a or 1 }
            sim.touchVisual(self)
        end
    end,
    SetUiMapID = function(self, uiMapId)
        S(self).uiMapId = uiMapId
        sim.touch(self)
    end,
    GetUiMapID = function(self)
        return S(self).uiMapId
    end,
    -- The units under the cursor (the game's tooltip names them)
    GetMouseOverUnits = function(self)
        local found = {}
        for _, drawn in ipairs(S(self).drawnUnits or {}) do
            local mouse = sim.mouse
            if
                mouse
                and math.abs(mouse.x - drawn.x) <= drawn.radius
                and math.abs(mouse.y - drawn.y) <= drawn.radius
            then
                found[#found + 1] = drawn.unit
            end
        end
        return unpack(found)
    end,
    -- The ring that runs out from the player's arrow when the map opens
    SetPlayerPingScale = function(self, scale)
        S(self).pingScale = scale
    end,
    GetPlayerPingScale = function(self)
        return S(self).pingScale or 1
    end,
    SetPlayerPingTexture = function(self, kind, asset, width, height)
        S(self).pingTextures = S(self).pingTextures or {}
        S(self).pingTextures[kind] = { asset = asset, width = width or 32, height = height or 32 }
    end,
    StartPlayerPing = function(self, duration, fadeDuration)
        S(self).ping = { start = sim.now, duration = duration or 2, fade = fadeDuration or 0.25 }
        -- (it moves while it lasts: drawn anew at every frame, sim.liveVisuals, until it ends)
        sim.liveVisuals = sim.liveVisuals or setmetatable({}, { __mode = "k" })
        sim.liveVisuals[self] = true
        sim.touchVisual(self)
    end,
    StopPlayerPing = function(self)
        S(self).ping = nil
        if sim.liveVisuals then
            sim.liveVisuals[self] = nil
        end
        sim.touchVisual(self)
    end,
})
-- A nameplate's base frame, which only the client makes (game.addNamePlate): where the mouse targets its unit is
-- set by points (the game's nameplate frames set them round the name and the health bar)
defineType("NamePlate", "Frame", {
    SetHitTestPoints = function(self, anchors)
        S(self).hitTestPoints = anchors
    end,
    GetHitTestPoints = function(self)
        return S(self).hitTestPoints or {}
    end,
    ClearAllHitTestPoints = function(self)
        S(self).hitTestPoints = nil
    end,
    SetAllHitTestPoints = function(self, relativeTo)
        S(self).hitTestPoints =
            { { point = "TOPLEFT", relativeTo = relativeTo }, { point = "BOTTOMRIGHT", relativeTo = relativeTo } }
    end,
    CanChangeHitTestPoints = function()
        return true
    end,
    SetStackingBoundsFrame = function(self, frame)
        S(self).stackingBoundsFrame = frame
    end,
})
defineType("ColorSelect", "Frame", {
    SetColorRGB = function() end,
    GetColorRGB = function()
        return 1, 1, 1
    end,
})
-- (its text kept; each text type's colour and font kept as set: h1, h2, h3, p)
defineType("SimpleHTML", "Frame", {
    SetText = function(self, text)
        S(self).html = text
    end,
    SetTextColor = function(self, textType, r, g, b, a)
        local s = S(self)
        if type(textType) == "number" then
            textType, r, g, b, a = "p", textType, r, g, b
        end
        s.htmlColors = s.htmlColors or {}
        s.htmlColors[textType or "p"] = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1 }
    end,
    GetTextColor = function(self, textType)
        local colors = S(self).htmlColors
        local color = colors and colors[textType or "p"] or { 1, 1, 1, 1 }
        return color[1], color[2], color[3], color[4]
    end,
    SetFont = function(self, textType, path, size, flags)
        local s = S(self)
        if type(textType) ~= "string" or textType:find("[/\\]") or textType:find("%.") then
            textType, path, size, flags = "p", textType, path, size
        end
        s.htmlFonts = s.htmlFonts or {}
        s.htmlFonts[textType or "p"] = { path, tonumber(size) or 12, flags or "" }
        return true
    end,
    SetFontObject = function(self, textType, fontObject)
        local s = S(self)
        if fontObject == nil then
            textType, fontObject = "p", textType
        end
        s.htmlFontObjects = s.htmlFontObjects or {}
        s.htmlFontObjects[textType or "p"] = fontObject
    end,
    GetFontObject = function(self, textType)
        local objects = S(self).htmlFontObjects
        return objects and objects[textType or "p"]
    end,
    GetFont = function(self, textType)
        local fonts_ = S(self).htmlFonts
        local font = fonts_ and (fonts_[textType or "p"] or fonts_.p)
        if font then
            return font[1], font[2], font[3]
        end
        return "Fonts\\FRIZQT__.TTF", 12, ""
    end,
})
defineType("Minimap", "Frame", {
    SetZoom = function(self, zoom)
        S(self).zoom = zoom
    end,
    GetZoom = function(self)
        return S(self).zoom or 0
    end,
    GetZoomLevels = function()
        return 6
    end,
    SetMaskTexture = function() end,
    SetBlipTexture = function() end,
    SetArchBlobRingScalar = function() end,
    SetQuestBlobRingScalar = function() end,
    SetPlayerTexture = function() end,
    -- The quest and dig-site blobs the client draws on the minimap: kept as set (the simulator does not draw them)
    SetQuestBlobInsideAlpha = function(self, alpha)
        S(self).questBlobInsideAlpha = alpha
    end,
    SetQuestBlobOutsideAlpha = function(self, alpha)
        S(self).questBlobOutsideAlpha = alpha
    end,
    SetQuestBlobRingAlpha = function(self, alpha)
        S(self).questBlobRingAlpha = alpha
    end,
    SetQuestBlobInsideTexture = function(self, texture)
        S(self).questBlobInsideTexture = texture
    end,
    SetQuestBlobOutsideTexture = function(self, texture)
        S(self).questBlobOutsideTexture = texture
    end,
    SetQuestBlobRingTexture = function(self, texture)
        S(self).questBlobRingTexture = texture
    end,
})
defineType("DropdownButton", "Button", {})

-- Animation groups (lua/animation.lua: their timing, and what they do, which the scene draws)
function W.createAnimationGroup(owner, name)
    local group = require("animation").newGroup(owner)
    -- A named group is a global, as a named frame is ("$parent" is the nearest named owner's name): the tutorial
    -- frame calls its AnimateCallout so
    if type(name) == "string" and name ~= "" then
        local resolved = name
        if name:find("$parent", 1, true) then
            local ownerName = W.getParentNameFor(owner)
            resolved = ownerName and (name:gsub("%$parent", ownerName)) or nil
        end
        if resolved then
            group.name = resolved
            sim.G[resolved] = group
        end
    end
    return group
end

---Makes a frame of a type, as CreateFrame does.
---@param isLoadDeferred boolean? Building from XML: the builder runs OnLoad once the frame's children exist
function W.createFrame(frameType, name, parent, template, id, isLoadDeferred)
    frameType = frameType or "Frame"
    local typeName
    for candidate in pairs(types) do
        if candidate:lower() == tostring(frameType):lower() then
            typeName = candidate
            break
        end
    end
    -- An intrinsic from XML (EventFrame, EventButton...) is made as its base type, then given its definition
    local intrinsic = W.getIntrinsic and W.getIntrinsic(frameType)
    if not typeName and intrinsic then
        for candidate in pairs(types) do
            if candidate:lower() == intrinsic.baseType:lower() then
                typeName = candidate
            end
        end
    end
    if not typeName or not types[typeName].chain.Frame then
        error("CreateFrame: Unknown frame type '" .. tostring(frameType) .. "'", 3)
    end
    parent = resolveRelative(parent)
    if type(name) == "string" and parent and S(parent) then
        name = name:gsub("%$parent", W.getParentNameFor(parent) or "")
    end
    local frame, s = newObject(typeName, name, nil)
    s.isFrame = true
    s.parent = parent
    if parent and S(parent) then
        table.insert(S(parent).children, frame)
        s.level = (S(parent).level or 0) + 1
    else
        s.level = 0
    end
    if
        typeName == "Button"
        or typeName == "CheckButton"
        or typeName == "EditBox"
        or typeName == "Slider"
        or typeName == "DropdownButton"
    then
        s.mouse = true
    end
    if typeName == "Button" or typeName == "CheckButton" or typeName == "DropdownButton" then
        s.clicks = { leftbuttonup = true }
    end
    s.frameId = id
    W.frames[#W.frames + 1] = frame
    if isVisible(frame) then
        W.touchOrder() -- (made under a hidden parent, it changes nothing drawn)
    end
    if name then
        sim.G[name] = frame
    end
    sim.touchVisual() -- (as a new region: nothing is placed from it yet)
    if W.applyIntrinsic then
        W.applyIntrinsic(frame, frameType)
    end
    -- Built whole from its templates before any OnLoad in it runs (xmlui.beginBuild)
    local xmlui = template and package.loaded["xmlui"]
    if xmlui then
        xmlui.beginBuild()
    end
    if template and W.applyTemplate then
        for templateName in tostring(template):gmatch("[^,%s]+") do
            W.applyTemplate(frame, templateName)
        end
    end
    if W.finishTemplates then
        W.finishTemplates()
    end
    if xmlui then
        if not isLoadDeferred then
            xmlui.queueLoad(frame)
        end
        xmlui.endBuild()
    elseif not isLoadDeferred then
        if name then
            require("layout").restore(frame)
        end -- (put back where the player left it: the layout cache)
        sim.runScript(frame, "OnLoad")
    end
    return frame
end

return W
