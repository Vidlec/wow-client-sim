-- The game's widgets: frames, textures, font strings and their kin, with anchors resolved into rectangles.
-- Each object is a plain table the addon owns; the simulator keeps its own state beside it (W.state), so an
-- addon's fields never meet ours. A missing method is nil, as in the game: calling it is an error, reported.
local sim = require("sim")
local fonts = require("fonts")

local W = {}
local state = setmetatable({}, { __mode = "k" })
W.state = state
W.byId = setmetatable({}, { __mode = "v" })
W.frames = {} -- every frame, in creation order (strong: frames live forever in the game)
function sim.getId(object) local s = state[object]; return s and s.id or 0 end

local STRATA = { "WORLD", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
W.STRATA_RANK = {}
for index, name in ipairs(STRATA) do
    W.STRATA_RANK[name] = index
end
W.LAYER_RANK = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }

local touchLayoutOf -- (below, with the rectangle cache)

local POINT_X = { TOPLEFT = 0, LEFT = 0, BOTTOMLEFT = 0, TOP = 0.5, CENTER = 0.5, BOTTOM = 0.5, TOPRIGHT = 1, RIGHT = 1, BOTTOMRIGHT = 1 }
local POINT_Y = { TOPLEFT = 1, TOP = 1, TOPRIGHT = 1, LEFT = 0.5, CENTER = 0.5, RIGHT = 0.5, BOTTOMLEFT = 0, BOTTOM = 0, BOTTOMRIGHT = 0 }

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
    types[name] = { methods = merged, parent = parentName, chain = chain, meta = { __index = merged, __tostring = function() return name end } }
    return merged
end
W.defineType = defineType

local function S(object)
    return state[object]
end

local function getCreator()
    local xmlui = package.loaded["xmlui"]
    if xmlui then
        local isBuilding, creator = xmlui.getBuild()
        if isBuilding then return creator end
    end
    return sim.getCallingAddon()
end

local function newObject(typeName, name, parent)
    local definition = types[typeName]
    local object = setmetatable({}, definition.meta)
    local id = sim.newId()
    state[object] = {
        id = id, type = typeName, name = name, parent = parent, points = {}, shown = true, alpha = 1, scale = 1,
        scripts = {}, children = {}, regions = {},
        creator = getCreator(), -- the addon whose code made it (nil: the simulator's own)
    }
    object[0] = object -- the game puts its userdata here; some addons look for it
    W.byId[id] = object
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
    GetName = function(self) return S(self).name end,
    GetObjectType = function(self) return S(self).type end,
    IsObjectType = function(self, typeName) return types[S(self).type].chain[typeName] == true end,
    GetParent = function(self) return S(self).parent end,
    GetDebugName = function(self) return S(self).name or (S(self).type .. "#" .. S(self).id) end,
    IsForbidden = function(self) return S(self).isForbidden == true end,
    SetForbidden = function(self) S(self).isForbidden = true end,
    -- Art the simulator draws is there at once (the map canvas waits on this before showing its tiles)
    IsObjectLoaded = function() return true end,
    IsProtected = function() return false, false end,
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
        if relative == self then relative = nil end
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
    s.points[#s.points + 1] = { point = point, relative = relative, relativePoint = relativePoint, x = x or 0, y = y or 0 }
    touchLayoutOf(self)
end

---The scale the object is drawn at, against the screen.
---Raises children (and theirs) that are not above their parent, keeping how far apart they were.
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
        elseif childState and (childState.level or 0) <= level then
            childState.level = level + 1
            W.touchOrder()
            W.liftChildren(child)
        elseif childState then
            W.liftChildren(child)
        end
    end
end

-- (kept while the layout stands: scale, parent and ignoreParentScale change it, and their setters touch the layout)
local scaleCache, scaleCacheVersion = {}, -1
local function getEffectiveScale(object)
    if scaleCacheVersion ~= sim.layoutVersion then
        scaleCache, scaleCacheVersion = {}, sim.layoutVersion
    end
    local cached = scaleCache[object]
    if cached then return cached end
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
    if not list then list = {}; dependents[source] = list end
    list[object] = true
end
local function invalidateRect(object)
    rectCache[object] = nil
    local list = dependents[object]
    if list then
        dependents[object] = nil
        for dependent in pairs(list) do invalidateRect(dependent) end
    end
end
touchLayoutOf = function(object)
    sim.version = sim.version + 1
    sim.layoutChanges = sim.layoutChanges + 1
    if rectCacheVersion == sim.layoutVersion then invalidateRect(object) end
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
        if info then return info.width * scale, info.height * scale end
    end
    return (s.width or 0) * scale, (s.height or 0) * scale
end

local NO_POINTS = {}
computeRect = function(object)
    if rectCacheVersion ~= sim.layoutVersion then
        rectCache, rectCacheVersion, dependents = {}, sim.layoutVersion, {}
    end
    local cached = rectCache[object]
    if cached ~= nil then
        return cached or nil
    end
    local s = S(object)
    if not s then
        return nil
    end
    if s.isRoot then
        local rect = { 0, 0, sim.screenWidth / s.scale * s.scale, sim.screenHeight }
        rectCache[object] = rect
        return rect
    end
    if computing[object] then
        return nil -- anchored in a circle
    end
    computing[object] = true
    local scale = getEffectiveScale(object)
    local left, right, centerX, bottom, top, centerY
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
        if anchor.relative then addDependent(anchor.relative, object) end
        if relativeRect then
            local x = relativeRect[1] + (relativeRect[3] - relativeRect[1]) * POINT_X[anchor.relativePoint] + anchor.x * scale
            local y = relativeRect[2] + (relativeRect[4] - relativeRect[2]) * POINT_Y[anchor.relativePoint] + anchor.y * scale
            local pointX, pointY = POINT_X[anchor.point], POINT_Y[anchor.point]
            if pointX == 0 then left = x elseif pointX == 1 then right = x else centerX = x end
            if pointY == 0 then bottom = y elseif pointY == 1 then top = y else centerY = y end
        end
    end
    -- A texture given no anchors is drawn on its parent, as the client does: centred at its own size, or over the
    -- whole parent when it has none (the minimap's zone button draws its bar so, an atlas sized by useAtlasSize)
    -- (a font string too: the gamepad's button legend writes each label in a string with no anchors, over its frame)
    local objectType = #s.points == 0 and object.GetObjectType and object:GetObjectType()
    if #s.points == 0 and not s.scrollChildOf and s.parent and (objectType == "Texture" or objectType == "FontString") then
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
            if left then right = left + width
            elseif right then left = right - width
            else left, right = centerX - width / 2, centerX + width / 2 end
        end
        if not (top and bottom) then
            local height
            if s.type == "FontString" and not (s.height and s.height > 0) then
                height = fonts.measureHeight(s, (right - left) / scale) * scale
            else
                local _, naturalHeightValue = getNatural()
                height = naturalHeightValue
            end
            if top then bottom = top - height
            elseif bottom then top = bottom + height
            else bottom, top = centerY - height / 2, centerY + height / 2 end
        end
        rect = { left, bottom, right, top }
        -- Kept on the screen when clamped, as the client keeps it (a tall tooltip over a row near the top: moved
        -- down whole rather than cut off); what hangs from it moves with it
        if s.clamped and s.isFrame then
            local dx, dy = 0, 0
            if right > sim.screenWidth then dx = sim.screenWidth - right end
            if left + dx < 0 then dx = -left end
            if top > sim.screenHeight then dy = sim.screenHeight - top end
            if bottom + dy < 0 and top - bottom <= sim.screenHeight then dy = -bottom end
            if dx ~= 0 or dy ~= 0 then rect = { left + dx, bottom + dy, right + dx, top + dy } end
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

local function isVisible(object)
    local s = S(object)
    while s do
        if not s.shown then
            return false
        end
        if s.isRoot then
            return true
        end
        local parent = s.parent
        if not parent then
            return true
        end
        s = S(parent)
    end
    return true
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
    W.touchOrder()
    sim.touchVisual()
    if s.collapsesLayout then touchLayoutOf(self) end -- (its room comes or goes: what hangs from it moves)
    local nowVisible = isVisible(self)
    -- A toplevel frame comes to the front of its strata as it is shown (the map, a panel), as in the client
    if isShown and s.toplevel and s.isFrame then self:Raise() end
    if wasVisible ~= nowVisible then
        W.propagateVisibility(self, nowVisible)
    end
end

---The nearest toplevel frame from this one up, which a click brings to the front.
function W.raiseToplevelOf(frame)
    local current, depth = frame, 0
    while current and depth < 60 do
        local state = S(current)
        if not state then return end
        if state.toplevel and state.isFrame then current:Raise(); return end
        current, depth = state.parent, depth + 1
    end
end

---OnShow and OnHide run for a frame and every child whose visibility changed with it, as in the game.
function W.propagateVisibility(object, isNowVisible)
    local s = S(object)
    if s.isFrame then
        -- An edit box that is hidden lets go of the keyboard, as in the game (a report closed with Escape from its
        -- copy box: the next key goes to the game again)
        if not isNowVisible and W.focus == object then W.setFocus(nil) end
        -- The children shown as it changed, taken before its own script runs: a child its OnHide hides in turn (the
        -- map's hiding an addon's window) was visible when the parent went, and hears its OnHide, as in the client
        -- The children's scripts run before the frame's own, deepest first, showing and hiding alike, as the client
        -- runs them (measured in the game: /asrec probe, a window, its child and grandchild -> grandchild, child,
        -- window). The guild window's OnShow reads the list its child filled in its own OnShow.
        local shownChildren = {}
        for _, child in ipairs(s.children) do
            if S(child).shown then shownChildren[#shownChildren + 1] = child end
        end
        for _, child in ipairs(shownChildren) do
            if isNowVisible == false or S(child).shown then
                W.propagateVisibility(child, isNowVisible)
            end
        end
        sim.runScript(object, isNowVisible and "OnShow" or "OnHide")
    end
end

local regionMethods = {
    SetPoint = setPoint,
    ClearAllPoints = function(self)
        local s = S(self)
        if #s.points == 0 then return end
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
    GetNumPoints = function(self) return #S(self).points end,
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
        if s.width == width and s.height == height then return end
        s.width, s.height = width, height
        touchLayoutOf(self)
    end,
    SetWidth = function(self, width)
        local s = S(self)
        if s.width == width then return end
        s.width = width
        touchLayoutOf(self)
    end,
    SetHeight = function(self, height)
        local s = S(self)
        if s.height == height then return end
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
    GetSize = function(self) return self:GetWidth(), self:GetHeight() end,
    GetLeft = function(self) local left = getRectInOwnUnits(self); return left end,
    GetRight = function(self) local _, _, right = getRectInOwnUnits(self); return right end,
    GetTop = function(self) local _, _, _, top = getRectInOwnUnits(self); return top end,
    GetBottom = function(self) local _, bottom = getRectInOwnUnits(self); return bottom end,
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
    IsRectValid = function(self) return computeRect(self) ~= nil end,
    IsAnchoringRestricted = function() return false end,
    Show = function(self) setShown(self, true) end,
    Hide = function(self) setShown(self, false) end,
    SetShown = function(self, isShown) setShown(self, isShown) end,
    SetCollapsesLayout = function(self, isCollapsing) S(self).collapsesLayout = isCollapsing and true or nil; touchLayoutOf(self) end,
    GetCollapsesLayout = function(self) return S(self).collapsesLayout == true end,
    IsShown = function(self) return S(self).shown end,
    IsVisible = function(self) return isVisible(self) end,
    SetAlpha = function(self, alpha) S(self).alpha = math.max(0, math.min(1, alpha or 1)); sim.touchVisual() end,
    GetAlpha = function(self) return S(self).alpha end,
    GetEffectiveAlpha = function(self)
        local alpha, object = 1, self
        while object and S(object) do
            alpha = alpha * S(object).alpha
            if S(object).ignoreParentAlpha then
                break
            end
            object = S(object).parent
        end
        return alpha
    end,
    SetIgnoreParentAlpha = function(self, isIgnored) S(self).ignoreParentAlpha = isIgnored; sim.touchVisual() end,
    SetIgnoreParentScale = function(self, isIgnored) S(self).ignoreParentScale = isIgnored; sim.touch() end,
    -- A number written as text is taken, as by the client (the game's XML gives KeyValue scales as text: ".75")
    SetScale = function(self, scale) scale = tonumber(scale); S(self).scale = (scale and scale > 0) and scale or 1; sim.touch() end,
    GetScale = function(self) return S(self).scale end,
    GetEffectiveScale = function(self) return getEffectiveScale(self) end,
    -- The key the object has on its parent (parent[key] = object), as parentKey in XML gives it; set from Lua too
    -- (the raid frame manager's raid marker buttons are found so: raidMarkers["raidMarker" .. i])
    SetParentKey = function(self, key, clearOtherKeys)
        local s = S(self)
        local parent = s.parent
        if parent and clearOtherKeys then
            for otherKey, value in pairs(parent) do
                if value == self and type(otherKey) == "string" then parent[otherKey] = nil end
            end
        end
        s.parentKey = key
        if parent and key then parent[key] = self end
    end,
    GetParentKey = function(self) return S(self).parentKey end,
    SetParent = function(self, parent)
        parent = resolveRelative(parent)
        local s = S(self)
        -- The game refuses a parent that is the object itself or one of its own children
        local ancestor = parent
        while ancestor do
            if ancestor == self then error("SetParent: Cannot set parent to itself or a descendant", 2) end
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
        if parent and S(parent) then
            local list = s.isFrame and S(parent).children or S(parent).regions
            list[#list + 1] = self
            if s.isFrame and not s.levelSet then
                s.level = (S(parent).level or 0) + 1
            end
            if s.isFrame then W.liftChildren(parent) end
        end
        W.touchOrder()
        sim.parentVersion = (sim.parentVersion or 0) + 1 -- (the scene's walk from the top frames, scene.getSortedFrames)
        sim.touch()
    end,
    -- The offsets move each edge, as the client takes them: (10, -10, -10, 10) grows the area by 10 all round
    IsMouseOver = function(self, top, bottom, left, right)
        local rect = computeRect(self)
        local mouse = sim.mouse
        if not rect or not mouse then
            return false
        end
        return mouse.x >= rect[1] + (left or 0) and mouse.x <= rect[3] + (right or 0) and mouse.y >= rect[2] + (bottom or 0) and mouse.y <= rect[4] + (top or 0)
    end,
    IsMouseMotionFocus = function(self) return sim.motionFocus == self end,
    CreateAnimationGroup = function(self, name, template)
        local group = W.createAnimationGroup(self, name)
        local xmlui = template and package.loaded["xmlui"]
        if xmlui then xmlui.applyAnimationGroupTemplates(group, template) end
        return group
    end,
    StopAnimating = function() end,
    SetSnapToPixelGrid = function() end,
    SetTexelSnappingBias = function() end,
    GetSourceLocation = function() return nil end,
}
defineType("Region", "Object", regionMethods)

-- Layered regions: textures, font strings, lines
local layeredMethods = {
    SetDrawLayer = function(self, layer, sublevel)
        local s = S(self)
        s.layer, s.sublevel = layer or "ARTWORK", sublevel or 0
        sim.touch()
    end,
    GetDrawLayer = function(self) return S(self).layer, S(self).sublevel end,
    SetVertexColor = function(self, r, g, b, a)
        S(self).vertexColor = { r or 1, g or 1, b or 1, a or 1 }
        sim.touchVisual()
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
    if isChanged then artCounter = artCounter + 1; s.artOrder = artCounter end
end

local textureMethods = {
    SetTexture = function(self, texture, horizontalWrap, verticalWrap, filter)
        local s = S(self)
        noteArt(s, texture ~= s.texture)
        local hadAtlas = s.atlas ~= nil
        s.texture, s.color, s.atlas = texture, nil, nil
        if hadAtlas then touchLayoutOf(self) else sim.touchVisual() end
        return texture ~= nil
    end,
    GetTexture = function(self) return S(self).texture end,
    GetTextureFilePath = function(self) return S(self).texture end,
    GetTextureFileID = function(self) local texture = S(self).texture; return type(texture) == "number" and texture or nil end,
    SetColorTexture = function(self, r, g, b, a)
        local s = S(self)
        noteArt(s, s.color == nil)
        local hadAtlas = s.atlas ~= nil
        s.color, s.texture, s.atlas = { unpackColor(r, g, b, a) }, nil, nil
        if hadAtlas then touchLayoutOf(self) else sim.touchVisual() end
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
    GetAtlas = function(self) return S(self).atlas end,
    -- A corner moved off its place (1 upper left, 2 lower left, 3 upper right, 4 lower right), in the texture's
    -- units with y up: the texture is drawn as the shape its corners make, a triangle when two meet
    SetVertexOffset = function(self, vertexIndex, x, y)
        local s = S(self)
        s.vertexOffsets = s.vertexOffsets or {}
        s.vertexOffsets[vertexIndex] = { x or 0, y or 0 }
        sim.touchVisual()
    end,
    GetVertexOffset = function(self, vertexIndex)
        local offset = S(self).vertexOffsets and S(self).vertexOffsets[vertexIndex]
        if offset then return offset[1], offset[2] end
        return 0, 0
    end,
    SetTexCoord = function(self, ...)
        local count = select("#", ...)
        local values = { ... }
        if count == 8 then
            -- ULx, ULy, LLx, LLy, URx, URy, LRx, LRy (the texture's point at each screen corner). Straight, it is
            -- left, right, top, bottom; turned a quarter (the game's backdrop edges), u runs down the screen
            local isTurned = values[1] == values[5] and values[2] == values[6]
            if not isTurned and values[1] == values[5] and values[3] ~= values[1] then isTurned = true end
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
        sim.touchVisual()
    end,
    GetTexCoord = function(self)
        local coord = S(self).texCoord or { 0, 1, 0, 1 }
        return coord[1], coord[3], coord[1], coord[4], coord[2], coord[3], coord[2], coord[4]
    end,
    SetDesaturated = function(self, isDesaturated) S(self).desaturated = isDesaturated and true or nil; sim.touchVisual() end,
    IsDesaturated = function(self) return S(self).desaturated == true end,
    SetDesaturation = function(self, amount) S(self).desaturated = (amount or 0) > 0.5 or nil; sim.touchVisual() end,
    SetBlendMode = function(self, mode) S(self).blend = mode; sim.touchVisual() end,
    GetBlendMode = function(self) return S(self).blend or "BLEND" end,
    SetRotation = function(self, radians) S(self).rotation = radians; sim.touchVisual() end,
    GetRotation = function(self) return S(self).rotation or 0 end,
    SetGradient = function(self, orientation, fromColor, toColor)
        local fr, fg, fb, fa = unpackColor(fromColor)
        local tr, tg, tb, ta = unpackColor(toColor)
        S(self).gradient = { orientation = orientation, from = { fr, fg, fb, fa }, to = { tr, tg, tb, ta } }
        sim.touchVisual()
    end,
    SetGradientAlpha = function(self, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
        S(self).gradient = { orientation = orientation, from = { r1, g1, b1, a1 }, to = { r2, g2, b2, a2 } }
        sim.touchVisual()
    end,
    SetHorizTile = function(self, isTiled) S(self).horizTile = isTiled; sim.touchVisual() end,
    SetVertTile = function(self, isTiled) S(self).vertTile = isTiled; sim.touchVisual() end,
    GetHorizTile = function(self) return S(self).horizTile == true end,
    GetVertTile = function(self) return S(self).vertTile == true end,
    AddMaskTexture = function(self, mask) S(self).mask = mask; sim.touchVisual() end,
    RemoveMaskTexture = function(self) S(self).mask = nil; sim.touchVisual() end,
    GetNumMaskTextures = function(self) return S(self).mask and 1 or 0 end,
    GetMaskTexture = function(self, index) if index == 1 then return S(self).mask end end,
    SetMask = function(self, path) S(self).maskPath = path; sim.touchVisual() end,
    SetTextureSliceMargins = function() end,
    SetTextureSliceMode = function() end,
    SetNonBlocking = function() end,
    IsBlockingLoadRequested = function() return false end,
}
defineType("Texture", "LayeredRegion", textureMethods)
defineType("MaskTexture", "Texture", {})

defineType("Line", "Texture", {
    SetStartPoint = function(self, point, relative, x, y)
        S(self).startPoint = { point = point or "CENTER", relative = resolveRelative(relative) or S(self).parent, x = x or 0, y = y or 0 }
        sim.touch()
    end,
    SetEndPoint = function(self, point, relative, x, y)
        S(self).endPoint = { point = point or "CENTER", relative = resolveRelative(relative) or S(self).parent, x = x or 0, y = y or 0 }
        sim.touch()
    end,
    SetThickness = function(self, thickness) S(self).thickness = thickness; sim.touch() end,
    GetThickness = function(self) return S(self).thickness or 1 end,
    GetThickness = function(self) return S(self).thickness or 1 end,
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
local function applyFontObject(s, fontObject)
    if type(fontObject) == "string" then
        fontObject = sim.G[fontObject]
    end
    s.fontObject = fontObject
end

local fontStringMethods = {
    SetText = function(self, text)
        local s = S(self)
        text = text ~= nil and tostring(text) or nil
        if s.text == text then return end
        s.text = text
        touchLayoutOf(self)
    end,
    GetText = function(self) return S(self).text end,
    SetFormattedText = function(self, pattern, ...) self:SetText(string.format(pattern, ...)) end,
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
    ClearText = function(self) self:SetText(nil) end,
    SetFontObject = function(self, fontObject)
        local s = S(self)
        applyFontObject(s, fontObject)
        s.font = nil
        touchLayoutOf(self)
    end,
    GetFontObject = function(self) return S(self).fontObject end,
    SetTextColor = function(self, r, g, b, a) S(self).textColor = { unpackColor(r, g, b, a) }; sim.touchVisual() end,
    GetTextColor = function(self)
        local color = fonts.getColor(S(self))
        return color[1], color[2], color[3], color[4]
    end,
    SetJustifyH = function(self, justify) S(self).justifyH = justify; sim.touch() end,
    GetJustifyH = function(self) return S(self).justifyH or fonts.getFont(S(self)).justifyH or "CENTER" end,
    SetJustifyV = function(self, justify) S(self).justifyV = justify; sim.touch() end,
    GetJustifyV = function(self) return S(self).justifyV or "MIDDLE" end,
    SetWordWrap = function(self, isWrapped) S(self).wordWrap = isWrapped and true or false; sim.touch() end,
    CanWordWrap = function(self) return S(self).wordWrap ~= false end,
    SetNonSpaceWrap = function(self, isWrapped) S(self).nonSpaceWrap = isWrapped; sim.touch() end,
    SetIndentedWordWrap = function() end,
    SetMaxLines = function(self, lines) S(self).maxLines = lines; sim.touch() end,
    GetMaxLines = function(self) return S(self).maxLines or 0 end,
    SetSpacing = function(self, spacing) S(self).spacing = spacing; sim.touch() end,
    GetSpacing = function(self) return S(self).spacing or 0 end,
    SetShadowColor = function(self, r, g, b, a) S(self).shadowColor = { unpackColor(r, g, b, a) }; sim.touchVisual() end,
    GetShadowColor = function(self) local color = S(self).shadowColor or { 0, 0, 0, 1 }; return unpack(color) end,
    SetShadowOffset = function(self, x, y) S(self).shadowOffset = { x or 0, y or 0 }; sim.touchVisual() end,
    GetShadowOffset = function(self) local offset = S(self).shadowOffset or { 0, 0 }; return offset[1], offset[2] end,
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
    GetUnboundedStringWidth = function(self) return fonts.measureWidth(S(self)) end,
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
    SetTextScale = function(self, scale) S(self).textScale = scale; sim.touch() end,
    GetTextScale = function(self) return S(self).textScale or 1 end,
    SetAlphaGradient = function() end,
    GetLineHeight = function(self) return fonts.getFont(S(self)).size end,
    SetTextToFit = function(self, text)
        self:SetText(text)
        S(self).width = fonts.measureWidth(S(self))
        sim.touch()
    end,
    SetTextHeight = function(self, height)
        local s = S(self)
        local font = fonts.getFont(s)
        s.font = { path = font.path, size = height, flags = font.flags }
        sim.touch()
    end,
}
defineType("FontString", "LayeredRegion", fontStringMethods)

---@return string? name What "$parent" in a name stands for: the parent's name, or, when it has none, its nearest named
---ancestor's (as the client does: a template's "$parentActionButton1" inside an unnamed bar takes the bar's owner's)
function W.getParentNameFor(parent)
    local depth = 0
    while parent and depth < 50 do
        local state = S(parent)
        if not state then return nil end
        if state.name then return state.name end
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
    sim.touch()
    return region
end
W.createRegion = createRegion

local scriptTypes = {} -- [script] = true for every script a frame may hold
for _, script in ipairs({ "OnEvent", "OnUpdate", "OnShow", "OnHide", "OnLoad", "OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp",
    "OnMouseWheel", "OnClick", "PreClick", "PostClick", "OnDoubleClick", "OnDragStart", "OnDragStop", "OnReceiveDrag", "OnSizeChanged",
    "OnValueChanged", "OnMinMaxChanged", "OnTextChanged", "OnEnterPressed", "OnEscapePressed", "OnTabPressed", "OnSpacePressed",
    "OnEditFocusGained", "OnEditFocusLost", "OnChar", "OnKeyDown", "OnKeyUp", "OnAttributeChanged", "OnVerticalScroll",
    "OnHorizontalScroll", "OnScrollRangeChanged", "OnTooltipSetItem", "OnTooltipCleared", "OnTooltipSetUnit", "OnTooltipSetSpell",
    "OnHyperlinkClick", "OnHyperlinkEnter", "OnHyperlinkLeave", "OnCursorChanged", "OnInputLanguageChanged", "OnEnable",
    "OnDisable", "OnCooldownDone", "OnFinished", "OnPlay", "OnStop", "OnLoop", "OnUpdateModel", "OnModelLoaded", "OnArrowPressed",
    "OnTextSet", "OnMouseDownSecure", "OnGamePadButtonDown", "OnGamePadButtonUp", "OnGamePadStick" }) do
    scriptTypes[script] = true
end
-- Script names are case-blind in the client: the game's gamepad code sets "OnGamepadStick" for OnGamePadStick
local canonicalScripts = {}
for script in pairs(scriptTypes) do canonicalScripts[script:lower()] = script end
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
function W.watchScript(frame, script)
    if script == "OnSizeChanged" and not isSizeWatched[frame] then
        isSizeWatched[frame] = true
        sizeWatchers[#sizeWatchers + 1] = frame
    elseif script == "OnScrollRangeChanged" then
        W.watchScrollRange(frame)
    end
end
function W.watchScrollRange(frame)
    if not isScrollWatched[frame] then
        isScrollWatched[frame] = true
        scrollWatchers[#scrollWatchers + 1] = frame
    end
end
local checkedVersion
function W.fireSizeChanges()
    for _ = 1, 8 do
        local changes = sim.layoutVersion * 1000003 + sim.layoutChanges
        if checkedVersion == changes then return end
        checkedVersion = changes
        -- (only those on show: a hidden frame is laid out, and told, once it shows)
        for _, frame in ipairs(scrollWatchers) do
            if S(frame).scrollChild and frame:IsVisible() then frame:UpdateScrollChildRect() end
        end
        for _, frame in ipairs(sizeWatchers) do
            local s = S(frame)
            if s.scripts.OnSizeChanged or (s.intrinsicScripts and s.intrinsicScripts.OnSizeChanged) or (s.hooks and s.hooks.OnSizeChanged) then
                local width, height = frame:GetWidth(), frame:GetHeight()
                if width ~= s.reportedWidth or height ~= s.reportedHeight then
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

local frameMethods = {
    SetScript = function(self, script, handler)
        local s = S(self)
        script = canonicalScript(script)
        s.scripts[script] = handler
        if handler then W.watchScript(self, script) end
        if s.hooks then
            s.hooks[script] = nil
        end
        if script == "OnUpdate" then
            sim.setOnUpdate(self, handler)
        end
        -- A wheel handler takes the wheel, as in the client (the game's map scroll container sets only its script)
        if script == "OnMouseWheel" and handler and s.mouseWheel == nil then s.mouseWheel = true end
    end,
    GetScript = function(self, script) return S(self).scripts[canonicalScript(script)] end,
    HookScript = function(self, script, handler)
        local s = S(self)
        script = canonicalScript(script)
        W.watchScript(self, script)
        if not s.scripts[script] then
            s.scripts[script] = handler
            if script == "OnUpdate" then
                sim.setOnUpdate(self, true)
            end
            if script == "OnMouseWheel" and s.mouseWheel == nil then s.mouseWheel = true end
            return
        end
        s.hooks = s.hooks or {}
        s.hooks[script] = s.hooks[script] or {}
        table.insert(s.hooks[script], handler)
    end,
    HasScript = function(self, script) return scriptTypes[canonicalScript(script)] == true end,
    CreateTexture = function(self, name, layer, template, sublevel)
        local texture = createRegion(self, "Texture", name, layer, nil, sublevel)
        if template and W.applyTemplate then
            W.applyTemplate(texture, template)
        end
        return texture
    end,
    CreateMaskTexture = function(self, name, layer) return createRegion(self, "MaskTexture", name, layer) end,
    CreateFontString = function(self, name, layer, template) return createRegion(self, "FontString", name, layer, template) end,
    CreateLine = function(self, name, layer, template, sublevel) return createRegion(self, "Line", name, layer, nil, sublevel) end,
    GetChildren = function(self) return unpack(S(self).children) end,
    -- Every texture of the frame and the frames under it greyed by an amount (0 to 1), the frame's own left out when
    -- excludeRoot, as the client does it
    DesaturateHierarchy = function(self, desaturation, excludeRoot)
        local function visit(frame, isRoot)
            local state = S(frame)
            if not state then return end
            if not (isRoot and excludeRoot) then
                for _, region in ipairs(state.regions or {}) do
                    if region.SetDesaturation then region:SetDesaturation(desaturation or 0) end
                end
            end
            for _, child in ipairs(state.children or {}) do visit(child, false) end
        end
        visit(self, true)
    end,
    GetNumChildren = function(self) return #S(self).children end,
    GetRegions = function(self) return unpack(S(self).regions) end,
    GetNumRegions = function(self) return #S(self).regions end,
    RegisterEvent = function(self, event)
        -- An event this client does not have fails as it does in the game (one renamed in another version of it)
        if type(event) ~= "string" or event == "" or not sim.isEventKnown(event) then
            error("Frame:RegisterEvent(): Attempt to register unknown event \"" .. tostring(event) .. "\"", 2)
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
        if isRegistered and select("#", ...) > 0 then sim.setUnitEventFilter(self, event, ...) end
        return isRegistered
    end,
    UnregisterEvent = function(self, event)
        if S(self).events then
            S(self).events[event] = nil
        end
        sim.unregisterEvent(self, event)
    end,
    UnregisterAllEvents = function(self) S(self).events = {}; sim.unregisterAllEvents(self) end,
    RegisterAllEvents = function(self) sim.allEventFrames[self] = true end,
    IsEventRegistered = function(self, event) return S(self).events ~= nil and S(self).events[event] == true end,
    EnableMouse = function(self, isEnabled) S(self).mouse = isEnabled and true or false end,
    -- A press and release of a mouse button on the frame, as the game's gamepad navigation presses the control under
    -- its cursor (A): its OnMouseDown and OnMouseUp, an edit box takes the keyboard, and a button clicks as it would
    -- under the mouse (on the press or the release it registered for)
    MouseDown = function(self, button)
        button = button or "LeftButton"
        local s = S(self)
        if W.types[s.type].chain.EditBox then W.setFocus(self) end
        sim.runScript(self, "OnMouseDown", button)
        if W.types[s.type].chain.Button then
            local clicks = s.clicks or { LeftButtonUp = true }
            if clicks[button .. "Down"] or clicks.AnyDown then W.clickButton(self, button, true) end
        end
        sim.touch()
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
            local clicks = s.clicks or { LeftButtonUp = true }
            if clicks[button .. "Up"] or clicks.AnyUp then W.clickButton(self, button, false) end
        end
        sim.touch()
    end,
    IsMouseEnabled = function(self) return S(self).mouse == true end,
    SetMouseClickEnabled = function(self, isEnabled) S(self).mouseClick = isEnabled and true or false end,
    IsMouseClickEnabled = function(self) return S(self).mouseClick ~= false and S(self).mouse == true end,
    SetMouseMotionEnabled = function(self, isEnabled) S(self).mouseMotion = isEnabled and true or false end,
    IsMouseMotionEnabled = function(self) return S(self).mouseMotion ~= false and S(self).mouse == true end,
    EnableMouseWheel = function(self, isEnabled) S(self).mouseWheel = isEnabled == nil and true or (isEnabled and true or false) end,
    IsMouseWheelEnabled = function(self) return S(self).mouseWheel == true end,
    SetPassThroughButtons = function() end,
    EnableKeyboard = function(self, isEnabled) S(self).keyboard = isEnabled and true or false end,
    IsKeyboardEnabled = function(self) return S(self).keyboard == true end,
    SetPropagateKeyboardInput = function(self, isPropagated) S(self).propagateKeyboard = isPropagated end,
    GetPropagateKeyboardInput = function(self) return S(self).propagateKeyboard == true end,
    EnableGamePadButton = function(self, isEnabled) S(self).gamePadButton = isEnabled ~= false end,
    IsGamePadButtonEnabled = function(self) return S(self).gamePadButton == true end,
    EnableGamePadStick = function(self, isEnabled) S(self).gamePadStick = isEnabled ~= false end,
    IsGamePadStickEnabled = function(self) return S(self).gamePadStick == true end,
    SetFrameStrata = function(self, strata)
        local s = S(self)
        if W.STRATA_RANK[strata] then
            s.strata = strata
            -- Everything it holds goes with it, as in the client: a child's own strata (one its XML gave it) gives
            -- way, unless it is fixed (SetFixedFrameStrata, fixedFrameStrata="true"). The gamepad's navigation
            -- pointer is a HIGH child of a frame set to TOOLTIP, and draws over the windows it points into.
            local function carry(frame)
                for _, child in ipairs(S(frame).children or {}) do
                    local childState = S(child)
                    if childState and childState.isFrame and not childState.isStrataFixed then
                        childState.strata = nil
                        carry(child)
                    end
                end
            end
            carry(self)
            W.touchOrder()
            sim.touch()
        end
    end,
    GetFrameStrata = function(self) return W.getStrata(self) end,
    SetFrameLevel = function(self, level)
        local s = S(self)
        -- Its children move by as much, keeping their places above it, as in the client (measured: a child at 6
        -- and one at 20 of a frame at 5 are at 51 and 65 once it is set to 50)
        local delta = (tonumber(level) or 0) - (s.level or 0)
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
        sim.touch()
    end,
    GetFrameLevel = function(self) return S(self).level or 0 end,
    SetFixedFrameStrata = function(self, isFixed) S(self).isStrataFixed = isFixed == true end,
    SetFixedFrameLevel = function() end,
    SetToplevel = function(self, isTop) S(self).toplevel = isTop end,
    IsToplevel = function(self) return S(self).toplevel == true end,
    -- Raise and Lower leave the frame's level as it is, as the client does (measured: /asrec probe): among the
    -- frames of its strata and level it, and all it holds, comes in front of (or behind) the others. A frame at a
    -- higher level stays in front of it (Edit Mode's dialogs, at 100, over its window raised as it opened)
    Raise = function(self)
        W.raiseCounter = (W.raiseCounter or 0) + 1
        S(self).raised = W.raiseCounter
        W.touchOrder()
        sim.touch()
    end,
    Lower = function(self)
        W.raiseCounter = (W.raiseCounter or 0) + 1
        S(self).raised = -W.raiseCounter
        W.touchOrder()
        sim.touch()
    end,
    SetMovable = function(self, isMovable) S(self).movable = isMovable end,
    IsMovable = function(self) return S(self).movable == true end,
    SetResizable = function(self, isResizable) S(self).resizable = isResizable end,
    IsResizable = function(self) return S(self).resizable == true end,
    SetResizeBounds = function() end,
    SetMinResize = function() end,
    SetMaxResize = function() end,
    -- Moved by the player, the frame is user-placed from then on: the client keeps its place in the layout cache
    -- (layout.lua) unless it is told not to (SetDontSavePosition, or SetUserPlaced(false) before the logout)
    StartMoving = function(self) S(self).userPlaced = true; W.startMoving(self) end,
    StartSizing = function() end,
    StopMovingOrSizing = function() W.stopMoving() end,
    RegisterForDrag = function(self, ...) S(self).dragButtons = { ... } end,
    SetClampedToScreen = function(self, isClamped) S(self).clamped = isClamped end,
    IsClampedToScreen = function(self) return S(self).clamped == true end,
    SetClampRectInsets = function(self, left, right, top, bottom) S(self).clampInsets = { left or 0, right or 0, top or 0, bottom or 0 } end,
    GetClampRectInsets = function(self) return unpack(S(self).clampInsets or { 0, 0, 0, 0 }) end,
    ClearAttribute = function(self, key)
        local attributes = S(self).attributes
        if attributes then attributes[key] = nil end
    end,
    SetUserPlaced = function(self, isUserPlaced) S(self).userPlaced = isUserPlaced end,
    IsUserPlaced = function(self) return S(self).userPlaced == true end,
    SetDontSavePosition = function(self, isNotSaved) S(self).dontSavePosition = isNotSaved and true or nil end,
    SetHitRectInsets = function(self, left, right, top, bottom) S(self).hitInsets = { left or 0, right or 0, top or 0, bottom or 0 } end,
    GetHitRectInsets = function(self) local insets = S(self).hitInsets or { 0, 0, 0, 0 }; return unpack(insets) end,
    SetID = function(self, id) S(self).frameId = id end,
    GetID = function(self) return S(self).frameId or 0 end,
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
        if not attributes then return nil end
        if name == nil then return attributes[prefix] end
        prefix, suffix = prefix or "", suffix or ""
        local value = attributes[prefix .. name .. suffix]
        if value == nil then value = attributes["*" .. name .. suffix] end
        if value == nil then value = attributes[prefix .. name .. "*"] end
        if value == nil then value = attributes["*" .. name .. "*"] end
        if value == nil then value = attributes[name] end
        return value
    end,
    SetAttributeNoHandler = function(self, key, value)
        S(self).attributes = S(self).attributes or {}
        S(self).attributes[key] = value
    end,
    SetClipsChildren = function(self, isClipping) S(self).clips = isClipping and true or false; sim.touch() end,
    DoesClipChildren = function(self) return S(self).clips == true end,
    SetFlattensRenderLayers = function() end,
    SetFrameBuffer = function() end,
    IgnoreDepth = function() end,
    SetDepth = function() end,
    SetHyperlinksEnabled = function(self, isEnabled) S(self).hyperlinks = isEnabled end,
    EnableDrawLayer = function() end,
    DisableDrawLayer = function() end,
    GetBoundsRect = function(self) return self:GetRect() end,
    CanChangeProtectedState = function() return true end,
    SetHighlightLocked = function() end,
    RegisterForWidgetSet = function() end,
    UnregisterForWidgetSet = function() end,
    GetDontSavePosition = function(self) return S(self).dontSavePosition == true end,
    SetUsingParentLevel = function() end,
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
                    sim.touch()
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
        sim.touch()
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
    end
end

local buttonMethods = {
    SetText = function(self, text) getButtonFontString(self):SetText(text) end,
    GetText = function(self) return S(self).fontString and S(self).fontString:GetText() end,
    SetFormattedText = function(self, pattern, ...) self:SetText(string.format(pattern, ...)) end,
    GetFontString = function(self) return getButtonFontString(self) end,
    SetFontString = function(self, fontString) S(self).fontString = fontString end,
    GetTextWidth = function(self) return getButtonFontString(self):GetStringWidth() end,
    GetTextHeight = function(self) return getButtonFontString(self):GetStringHeight() end,
    SetNormalFontObject = function(self, fontObject)
        S(self).normalFontObject = fontObject
        getButtonFontString(self):SetFontObject(fontObject)
    end,
    GetNormalFontObject = function(self) return S(self).normalFontObject end,
    SetHighlightFontObject = function(self, fontObject) S(self).highlightFontObject = fontObject end,
    SetDisabledFontObject = function(self, fontObject) S(self).disabledFontObject = fontObject end,
    GetHighlightFontObject = function(self) return S(self).highlightFontObject end,
    GetDisabledFontObject = function(self) return S(self).disabledFontObject end,
    SetNormalTexture = setButtonTexture("normal", "ARTWORK"),
    SetPushedTexture = setButtonTexture("pushed", "ARTWORK"),
    SetHighlightTexture = setButtonTexture("highlight", "HIGHLIGHT"),
    SetDisabledTexture = setButtonTexture("disabled", "ARTWORK"),
    SetNormalAtlas = setButtonAtlas("normal", "ARTWORK"),
    SetPushedAtlas = setButtonAtlas("pushed", "ARTWORK"),
    SetHighlightAtlas = setButtonAtlas("highlight", "HIGHLIGHT"),
    SetDisabledAtlas = setButtonAtlas("disabled", "ARTWORK"),
    GetNormalTexture = function(self) return S(self).normal end,
    GetPushedTexture = function(self) return S(self).pushed end,
    GetHighlightTexture = function(self) return S(self).highlight end,
    GetDisabledTexture = function(self) return S(self).disabled end,
    ClearNormalTexture = function(self) if S(self).normal then S(self).normal:Hide() end end,
    ClearPushedTexture = function(self) if S(self).pushed then S(self).pushed:Hide() end end,
    ClearHighlightTexture = function(self) if S(self).highlight then S(self).highlight:Hide() end end,
    ClearDisabledTexture = function(self) if S(self).disabled then S(self).disabled:Hide() end end,
    LockHighlight = function(self) S(self).highlightLocked = true; sim.touchVisual() end,
    UnlockHighlight = function(self) S(self).highlightLocked = nil; sim.touchVisual() end,
    Enable = function(self) self:SetEnabled(true) end,
    Disable = function(self) self:SetEnabled(false) end,
    SetEnabled = function(self, isEnabled)
        local s = S(self)
        local wasEnabled = s.enabled ~= false
        s.enabled = isEnabled and true or false
        if wasEnabled == s.enabled then return end
        sim.touchVisual()
        if wasEnabled ~= s.enabled then
            sim.runScript(self, s.enabled and "OnEnable" or "OnDisable")
        end
    end,
    IsEnabled = function(self) return S(self).enabled ~= false end,
    RegisterForClicks = function(self, ...)
        local clicks = {}
        for _, click in ipairs({ ... }) do
            clicks[click] = true
        end
        S(self).clicks = clicks
    end,
    RegisterForMouse = function() end,
    Click = function(self, button, isDown)
        W.clickButton(self, button or "LeftButton", isDown)
    end,
    SetButtonState = function(self, buttonState, isLocked) S(self).buttonState = buttonState; sim.touchVisual() end,
    GetButtonState = function(self) return S(self).buttonState or "NORMAL" end,
    SetPushedTextOffset = function() end,
    GetPushedTextOffset = function() return 1, -1 end,
    SetMotionScriptsWhileDisabled = function(self, isEnabled) S(self).motionWhileDisabled = isEnabled end,
    GetMotionScriptsWhileDisabled = function(self) return S(self).motionWhileDisabled == true end,
}
defineType("Button", "Frame", buttonMethods)

defineType("CheckButton", "Button", {
    SetChecked = function(self, isChecked) S(self).checked = isChecked and true or false; sim.touchVisual() end,
    GetChecked = function(self) return S(self).checked == true end,
    SetCheckedTexture = setButtonTexture("checkedTexture", "OVERLAY"),
    GetCheckedTexture = function(self) return S(self).checkedTexture end,
    SetDisabledCheckedTexture = setButtonTexture("disabledChecked", "OVERLAY"),
    GetDisabledCheckedTexture = function(self) return S(self).disabledChecked end,
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
    SetText = function(self, text) setEditText(self, text, false) end,
    GetText = function(self) return S(self).text or "" end,
    GetDisplayText = function(self) return S(self).text or "" end,
    SetNumber = function(self, number) setEditText(self, tostring(number or 0), false) end,
    GetNumber = function(self) return tonumber(S(self).text) or 0 end,
    GetNumLetters = function(self) return #(S(self).text or "") end,
    Insert = function(self, text) setEditText(self, (S(self).text or "") .. tostring(text), false) end,
    SetFocus = function(self) W.setFocus(self) end,
    ClearFocus = function(self) if W.focus == self then W.setFocus(nil) end end,
    HasFocus = function(self) return W.focus == self end,
    SetAutoFocus = function(self, isAuto) S(self).autoFocus = isAuto end,
    IsAutoFocus = function(self) return S(self).autoFocus ~= false end,
    SetMultiLine = function(self, isMulti) S(self).multiLine = isMulti; getEditFontString(self):SetJustifyV(isMulti and "TOP" or "MIDDLE") end,
    IsMultiLine = function(self) return S(self).multiLine == true end,
    SetMaxLetters = function(self, maxLetters) S(self).maxLetters = maxLetters end,
    GetMaxLetters = function(self) return S(self).maxLetters or 0 end,
    SetMaxBytes = function() end,
    SetNumeric = function(self, isNumeric) S(self).numeric = isNumeric end,
    IsNumeric = function(self) return S(self).numeric == true end,
    SetPassword = function(self, isPassword) S(self).password = isPassword end,
    HighlightText = function(self, from, to) S(self).highlighted = true; sim.touchVisual() end,
    ClearHighlightText = function(self) S(self).highlighted = nil; sim.touchVisual() end,
    SetCursorPosition = function(self, position) S(self).cursor = position end,
    GetCursorPosition = function(self) return S(self).cursor or 0 end,
    SetTextInsets = function(self, left, right, top, bottom)
        local text = getEditFontString(self)
        text:ClearAllPoints()
        text:SetPoint("TOPLEFT", self, "TOPLEFT", left or 0, -(top or 0))
        text:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -(right or 0), bottom or 0)
    end,
    SetFontObject = function(self, fontObject) getEditFontString(self):SetFontObject(fontObject) end,
    GetFontObject = function(self) return getEditFontString(self):GetFontObject() end,
    SetFont = function(self, ...) return getEditFontString(self):SetFont(...) end,
    GetFont = function(self) return getEditFontString(self):GetFont() end,
    SetTextColor = function(self, ...) getEditFontString(self):SetTextColor(...) end,
    SetJustifyH = function(self, justify) getEditFontString(self):SetJustifyH(justify) end,
    SetJustifyV = function(self, justify) getEditFontString(self):SetJustifyV(justify) end,
    SetSpacing = function(self, spacing) getEditFontString(self):SetSpacing(spacing) end,
    SetShadowOffset = function(self, ...) getEditFontString(self):SetShadowOffset(...) end,
    SetCountInvisibleLetters = function() end,
    SetBlinkSpeed = function() end,
    SetHistoryLines = function() end,
    AddHistoryLine = function() end,
    SetAltArrowKeyMode = function() end,
    SetEnabled = function(self, isEnabled) S(self).enabled = isEnabled and true or false end,
    Enable = function(self) S(self).enabled = true end,
    Disable = function(self) S(self).enabled = false end,
    IsEnabled = function(self) return S(self).enabled ~= false end,
    GetInputLanguage = function() return "ROMAN" end,
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
        sim.touch()
    end,
    GetScrollChild = function(self) return S(self).scrollChild end,
    SetVerticalScroll = function(self, offset)
        -- Fired only on a real change, as the game does: scroll bars set it back from their own callbacks
        offset = offset or 0
        if (S(self).verticalScroll or 0) == offset then return end
        S(self).verticalScroll = offset
        if S(self).scrollChild then touchLayoutOf(S(self).scrollChild) else sim.touchVisual() end
        sim.runScript(self, "OnVerticalScroll", offset)
    end,
    GetVerticalScroll = function(self) return S(self).verticalScroll or 0 end,
    SetHorizontalScroll = function(self, offset)
        -- Fired only on a real change, as the game does: scroll bars set it back from their own callbacks
        offset = offset or 0
        if (S(self).horizontalScroll or 0) == offset then return end
        S(self).horizontalScroll = offset
        if S(self).scrollChild then touchLayoutOf(S(self).scrollChild) else sim.touchVisual() end
        sim.runScript(self, "OnHorizontalScroll", offset)
    end,
    GetHorizontalScroll = function(self) return S(self).horizontalScroll or 0 end,
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
        if s.toldScrollRange and s.toldScrollRange[1] == horizontal and s.toldScrollRange[2] == vertical then return end
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
    sim.touch()
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
        sim.touch()
    end,
    GetMinMaxValues = function(self) return S(self).minValue or 0, S(self).maxValue or 1 end,
    SetValue = function(self, value) setBarValue(self, value) end,
    GetValue = function(self) return S(self).value or 0 end,
    SetOrientation = function(self, orientation) S(self).orientation = orientation; sim.touch() end,
    GetOrientation = function(self) return S(self).orientation or "HORIZONTAL" end,
}
local sliderMethods = {
    SetValueStep = function(self, step) S(self).valueStep = step end,
    GetValueStep = function(self) return S(self).valueStep or 0 end,
    SetObeyStepOnDrag = function(self, isObeyed) S(self).obeyStep = isObeyed end,
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
        sim.touch()
    end,
    GetThumbTexture = function(self) return S(self).thumb end,
    Enable = function(self) S(self).enabled = true; sim.touchVisual() end,
    Disable = function(self) S(self).enabled = false; sim.touchVisual() end,
    SetEnabled = function(self, isEnabled) S(self).enabled = isEnabled and true or false; sim.touch() end,
    IsEnabled = function(self) return S(self).enabled ~= false end,
    IsDraggingThumb = function() return false end,
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
            local isAtlas = type(texture) == "string" and not texture:find("[\\/]") and W.getAtlasInfo and W.getAtlasInfo(texture)
            if isAtlas then s.barTexture:SetAtlas(texture) else s.barTexture:SetTexture(texture) end
        end
        S(s.barTexture).role = "bar"
        sim.touch()
    end,
    GetStatusBarTexture = function(self)
        local s = S(self)
        if not s.barTexture then
            self:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        end
        return s.barTexture
    end,
    SetStatusBarColor = function(self, r, g, b, a) self:GetStatusBarTexture():SetVertexColor(r, g, b, a) end,
    SetStatusBarDesaturated = function(self, isDesaturated) self:GetStatusBarTexture():SetDesaturated(isDesaturated) end,
    IsStatusBarDesaturated = function(self) return self:GetStatusBarTexture():IsDesaturated() end,
    GetStatusBarColor = function(self) return self:GetStatusBarTexture():GetVertexColor() end,
    SetStatusBarAtlas = function(self, atlas) self:GetStatusBarTexture():SetAtlas(atlas) end,
    SetReverseFill = function(self, isReversed) S(self).reverseFill = isReversed; sim.touch() end,
    SetFillStyle = function() end,
    SetRotatesTexture = function() end,
}
for key, value in pairs(valueMethods) do
    statusMethods[key] = statusMethods[key] or value
end
defineType("StatusBar", "Frame", statusMethods)

defineType("Cooldown", "Frame", {
    SetCooldown = function(self, start, duration) S(self).cooldown = { start = start, duration = duration }; sim.touchVisual() end,
    GetCooldownTimes = function(self)
        local cooldown = S(self).cooldown
        return cooldown and cooldown.start * 1000 or 0, cooldown and cooldown.duration * 1000 or 0
    end,
    Clear = function(self) S(self).cooldown = nil; sim.touch() end,
    SetDrawEdge = function() end,
    SetDrawSwipe = function() end,
    SetDrawBling = function() end,
    SetSwipeColor = function() end,
    SetSwipeTexture = function() end,
    SetHideCountdownNumbers = function() end,
    SetReverse = function() end,
    SetEdgeTexture = function() end,
    SetUseCircularEdge = function() end,
    Pause = function() end,
    Resume = function() end,
})

defineType("MessageFrame", "Frame", {
    AddMessage = function(self, text, r, g, b)
        local s = S(self)
        s.messages = s.messages or {}
        table.insert(s.messages, { text = tostring(text), r = r or 1, g = g or 1, b = b or 1, time = sim.now })
        if #s.messages > 100 then
            table.remove(s.messages, 1)
        end
        if s.isChat then
            sim.print(text, r, g, b)
        end
        sim.touch()
    end,
    Clear = function(self) S(self).messages = {}; sim.touch() end,
    SetFading = function() end,
    SetFadeDuration = function() end,
    SetTimeVisible = function() end,
    SetMaxLines = function() end,
    SetInsertMode = function() end,
    SetFontObject = function() end,
    SetJustifyH = function() end,
    AddMsg = function(self, ...) self:AddMessage(...) end,
    GetNumMessages = function(self) return #(S(self).messages or {}) end,
})
defineType("ScrollingMessageFrame", "MessageFrame", { ScrollToBottom = function() end, SetHyperlinksEnabled = function() end })

-- The help window's web page (SimpleBrowserAPI): no pages are shown here, so going anywhere does nothing
do
    local function nothing() end
    defineType("Browser", "Frame", {
        NavigateHome = nothing, NavigateBack = nothing, NavigateForward = nothing, NavigateReload = nothing,
        NavigateStop = nothing, OpenTicket = nothing, OpenExternalLink = nothing, CopyExternalLink = nothing,
        DeleteCookies = nothing, ClearFocus = nothing, SetFocus = nothing,
        SetZoom = function(self, zoom) S(self).browserZoom = zoom end,
    })
end

defineType("Model", "Frame", {
    SetModel = function() end, SetDisplayInfo = function() end, SetUnit = function() end, SetCamDistanceScale = function() end,
    SetFacing = function() end, SetPosition = function() end, ClearModel = function() end, SetCreature = function() end,
    SetPortraitZoom = function() end, SetRotation = function() end, RefreshUnit = function() end, SetSequence = function() end,
})
defineType("PlayerModel", "Model", {})
defineType("DressUpModel", "PlayerModel", {})
defineType("ModelScene", "Frame", {
    -- The space round the drawn scene (the client keeps it; nothing is drawn here)
    SetViewInsets = function(self, left, right, top, bottom) S(self).viewInsets = { left or 0, right or 0, top or 0, bottom or 0 } end,
    GetViewInsets = function(self) local insets = S(self).viewInsets or { 0, 0, 0, 0 }; return insets[1], insets[2], insets[3], insets[4] end,
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
        if entry.unit == unit then return entry end
    end
end
defineType("UnitPositionFrame", "Frame", {
    AddUnit = function(self, unit, asset, width, height, r, g, b, a, sublayer, showFacing)
        local state = S(self)
        state.units = state.units or {}
        local entry = findUnit(self, unit) or {}
        if not entry.unit then state.units[#state.units + 1] = entry end
        entry.unit, entry.asset, entry.width, entry.height = unit, asset, width or 40, height or width or 40
        entry.color, entry.sublayer, entry.showFacing = { r or 1, g or 1, b or 1, a or 1 }, sublayer or 7, showFacing == true
        sim.touch()
    end,
    ClearUnits = function(self) S(self).units = {}; sim.touch() end,
    FinalizeUnits = function() end,
    SetUnitColor = function(self, unit, r, g, b, a)
        local entry = findUnit(self, unit)
        if entry then entry.color = { r or 1, g or 1, b or 1, a or 1 }; sim.touchVisual() end
    end,
    SetUiMapID = function(self, uiMapId) S(self).uiMapId = uiMapId; sim.touch() end,
    GetUiMapID = function(self) return S(self).uiMapId end,
    -- The units under the cursor (the game's tooltip names them)
    GetMouseOverUnits = function(self)
        local found = {}
        for _, drawn in ipairs(S(self).drawnUnits or {}) do
            local mouse = sim.mouse
            if mouse and math.abs(mouse.x - drawn.x) <= drawn.radius and math.abs(mouse.y - drawn.y) <= drawn.radius then
                found[#found + 1] = drawn.unit
            end
        end
        return unpack(found)
    end,
    -- The ring that runs out from the player's arrow when the map opens
    SetPlayerPingScale = function(self, scale) S(self).pingScale = scale end,
    GetPlayerPingScale = function(self) return S(self).pingScale or 1 end,
    SetPlayerPingTexture = function(self, kind, asset, width, height)
        S(self).pingTextures = S(self).pingTextures or {}
        S(self).pingTextures[kind] = { asset = asset, width = width or 32, height = height or 32 }
    end,
    StartPlayerPing = function(self, duration, fadeDuration)
        S(self).ping = { start = sim.now, duration = duration or 2, fade = fadeDuration or 0.25 }
        sim.touchVisual()
    end,
    StopPlayerPing = function(self) S(self).ping = nil; sim.touchVisual() end,
})
-- A nameplate's base frame, which only the client makes (game.addNamePlate): where the mouse targets its unit is
-- set by points (the game's nameplate frames set them round the name and the health bar)
defineType("NamePlate", "Frame", {
    SetHitTestPoints = function(self, anchors) S(self).hitTestPoints = anchors end,
    GetHitTestPoints = function(self) return S(self).hitTestPoints or {} end,
    ClearAllHitTestPoints = function(self) S(self).hitTestPoints = nil end,
    SetAllHitTestPoints = function(self, relativeTo) S(self).hitTestPoints = { { point = "TOPLEFT", relativeTo = relativeTo }, { point = "BOTTOMRIGHT", relativeTo = relativeTo } } end,
    CanChangeHitTestPoints = function() return true end,
    SetStackingBoundsFrame = function(self, frame) S(self).stackingBoundsFrame = frame end,
})
defineType("ColorSelect", "Frame", { SetColorRGB = function() end, GetColorRGB = function() return 1, 1, 1 end })
defineType("SimpleHTML", "Frame", { SetText = function(self, text) S(self).html = text end })
defineType("Minimap", "Frame", {
    SetZoom = function(self, zoom) S(self).zoom = zoom end, GetZoom = function(self) return S(self).zoom or 0 end,
    GetZoomLevels = function() return 6 end, SetMaskTexture = function() end, SetBlipTexture = function() end,
    SetArchBlobRingScalar = function() end, SetQuestBlobRingScalar = function() end, SetPlayerTexture = function() end,
    -- The quest and dig-site blobs the client draws on the minimap: kept as set (the simulator does not draw them)
    SetQuestBlobInsideAlpha = function(self, alpha) S(self).questBlobInsideAlpha = alpha end,
    SetQuestBlobOutsideAlpha = function(self, alpha) S(self).questBlobOutsideAlpha = alpha end,
    SetQuestBlobRingAlpha = function(self, alpha) S(self).questBlobRingAlpha = alpha end,
    SetQuestBlobInsideTexture = function(self, texture) S(self).questBlobInsideTexture = texture end,
    SetQuestBlobOutsideTexture = function(self, texture) S(self).questBlobOutsideTexture = texture end,
    SetQuestBlobRingTexture = function(self, texture) S(self).questBlobRingTexture = texture end,
})
defineType("DropdownButton", "Button", {})

-- Animation groups: they play for their duration and finish, without moving anything
function W.createAnimationGroup(owner, name)
    local group = { owner = owner, animations = {}, scripts = {}, playing = false, looping = "NONE" }
    local groupMethods = {}
    function groupMethods:CreateAnimation(animationType, animationName)
        local animation = { group = self, kind = animationType, duration = 0, delay = 0, order = 1, scripts = {} }
        local animationMethods = {}
        for _, setter in ipairs({ "SetDuration", "SetStartDelay", "SetEndDelay", "SetOrder", "SetSmoothing", "SetFromAlpha",
            "SetToAlpha", "SetChange", "SetOffset", "SetScale", "SetScaleFrom", "SetScaleTo", "SetOrigin", "SetDegrees",
            "SetTarget", "SetChildKey", "SetTargetKey", "SetTargetName", "SetSmoothProgress", "SetFromScale", "SetToScale",
            "SetRadians", "SetTranslation", "SetFromPercent", "SetToPercent" }) do
            animationMethods[setter] = function(target, value)
                if setter == "SetDuration" then target.duration = value or 0 end
                if setter == "SetStartDelay" then target.delay = value or 0 end
                if setter == "SetOrder" then target.order = value or 1 end
            end
        end
        function animationMethods:GetDuration() return self.duration end
        function animationMethods:SetScript(script, handler) self.scripts[script] = handler end
        function animationMethods:GetScript(script) return self.scripts[script] end
        function animationMethods:IsPlaying() return self.group.playing end
        function animationMethods:Play() self.group:Play() end
        function animationMethods:Stop() self.group:Stop() end
        function animationMethods:GetParent() return self.group end
        function animationMethods:GetRegionParent() return self.group.owner end
        function animationMethods:GetTarget() return self.group.owner end
        function animationMethods:GetProgress() return 0 end
        -- (the progress through its smoothing curve: the buff frame fades expiring auras by it)
        function animationMethods:GetSmoothProgress() return 0 end
        setmetatable(animation, { __index = animationMethods })
        table.insert(self.animations, animation)
        return animation
    end
    function groupMethods:Play()
        if self.timer then
            self.timer.cancelled = true
        end
        self.playing, self.paused = true, false
        if self.scripts.OnPlay then sim.call(self.scripts.OnPlay, self) end
        local total = 0
        for _, animation in ipairs(self.animations) do
            total = math.max(total, animation.delay + animation.duration)
        end
        local function finish()
            if self.looping ~= "NONE" and self.playing then
                if self.scripts.OnLoop then sim.call(self.scripts.OnLoop, self, "FORWARD") end
                self.timer = sim.addTimer(math.max(total, 0.1), finish)
                return
            end
            self.playing = false
            for _, animation in ipairs(self.animations) do
                if animation.scripts.OnFinished then sim.call(animation.scripts.OnFinished, animation, false) end
            end
            if self.scripts.OnFinished then sim.call(self.scripts.OnFinished, self, false) end
        end
        self.timer = sim.addTimer(total, finish)
    end
    function groupMethods:Stop()
        self.playing, self.paused = false, false
        if self.timer then self.timer.cancelled = true end
        if self.scripts.OnStop then sim.call(self.scripts.OnStop, self) end
    end
    -- Held where it is: not playing, not done; Play goes on with it (here, from the start)
    function groupMethods:Pause()
        if not self.playing then return end
        self.playing, self.paused = false, true
        if self.timer then self.timer.cancelled = true end
    end
    function groupMethods:IsPaused() return self.paused == true end
    function groupMethods:Finish() self:Stop() end
    function groupMethods:Restart() self:Play() end
    function groupMethods:IsPlaying() return self.playing end
    function groupMethods:IsDone() return not self.playing and not self.paused end
    function groupMethods:SetLooping(looping) self.looping = looping or "NONE" end
    function groupMethods:GetLooping() return self.looping end
    function groupMethods:SetScript(script, handler) self.scripts[script] = handler end
    function groupMethods:GetScript(script) return self.scripts[script] end
    function groupMethods:HookScript(script, handler) self.scripts[script] = handler end
    function groupMethods:GetAnimations() return unpack(self.animations) end
    function groupMethods:GetParent() return self.owner end
    function groupMethods:SetToFinalAlpha() end
    function groupMethods:GetDuration() return 0 end
    function groupMethods:GetProgress() return 0 end
    function groupMethods:GetElapsed() return 0 end
    function groupMethods:SetPlaying(isPlaying) if isPlaying then self:Play() else self:Stop() end end
    function groupMethods:GetName() return self.name end
    setmetatable(group, { __index = groupMethods })
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
            if candidate:lower() == intrinsic.baseType:lower() then typeName = candidate end
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
    if typeName == "Button" or typeName == "CheckButton" or typeName == "EditBox" or typeName == "Slider" or typeName == "DropdownButton" then
        s.mouse = true
    end
    if typeName == "Button" or typeName == "CheckButton" or typeName == "DropdownButton" then
        s.clicks = { LeftButtonUp = true }
    end
    s.frameId = id
    W.frames[#W.frames + 1] = frame
    W.touchOrder()
    if name then
        sim.G[name] = frame
    end
    sim.touch()
    if W.applyIntrinsic then W.applyIntrinsic(frame, frameType) end
    -- Built whole from its templates before any OnLoad in it runs (xmlui.beginBuild)
    local xmlui = template and package.loaded["xmlui"]
    if xmlui then xmlui.beginBuild() end
    if template and W.applyTemplate then
        for templateName in tostring(template):gmatch("[^,%s]+") do
            W.applyTemplate(frame, templateName)
        end
    end
    if W.finishTemplates then W.finishTemplates() end
    if xmlui then
        if not isLoadDeferred then xmlui.queueLoad(frame) end
        xmlui.endBuild()
    elseif not isLoadDeferred then
        if name then require("layout").restore(frame) end -- (put back where the player left it: the layout cache)
        sim.runScript(frame, "OnLoad")
    end
    return frame
end

return W
