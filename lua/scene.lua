-- The picture and the hands: every visible frame and region in draw order as a flat list for the page, and
-- the mouse and keyboard turned into the scripts the game would run (OnEnter, OnClick, OnMouseWheel, ...).
local sim = require("sim")
local W = require("widgets")
local fonts = require("fonts")
local animation = require("animation")

local scene = {}
local S = W.state
local G = sim.G

-- Animations playing this export (animation.collect): what they do to an object's alpha, place and texture
local isAnimating = false
---An object's own alpha: an Alpha animation's while one plays on it, else its own
local function ownAlpha(object, s)
    if isAnimating then
        local effect = animation.effectOf(object)
        if effect and effect.alpha then
            return effect.alpha
        end
    end
    return s.alpha or 1
end

local function round(value)
    return math.floor(value * 10 + 0.5) / 10
end

local function getAlpha(object)
    local alpha, current = 1, object
    while current and S[current] do
        alpha = alpha * (S[current].alpha or 1)
        if S[current].ignoreParentAlpha or S[current].isRoot then
            break
        end
        current = S[current].parent
    end
    return alpha
end

---A clip cut down to a frame's rectangle (or the frame's rectangle, with no clip yet)
local function clipTo(clip, frame)
    local rect = W.computeRect(frame)
    if not rect then
        return clip
    end
    if not clip then
        return { rect[1], rect[2], rect[3], rect[4] }
    end
    return {
        math.max(clip[1], rect[1]),
        math.max(clip[2], rect[2]),
        math.min(clip[3], rect[3]),
        math.min(clip[4], rect[4]),
    }
end

---The rectangle a frame's drawing is clipped to: every clipping ancestor's, intersected. A scroll frame clips only
---its scroll child (as the client: the quest log's search box, its child above the list, shows); a frame that clips
---its children (SetClipsChildren) clips them all.
local function getClip(frame)
    local clip
    local node = frame
    while node and S[node] do
        local s = S[node]
        if node ~= frame and s.clips then
            clip = clipTo(clip, node)
        end
        if s.scrollChildOf and S[s.scrollChildOf] then
            clip = clipTo(clip, s.scrollChildOf)
        end
        node = s.parent
    end
    return clip
end

-- The same two, worked out once per frame in an export: a frame's answer is its parent's, carried down (an export
-- asked them for every frame, each walking up to the screen)
local alphaMemo, clipMemo, insideClipMemo = {}, {}, {}
local NO_CLIP = {}
local function exportAlpha(object)
    local known = alphaMemo[object]
    if known then
        return known
    end
    local s = S[object]
    if not s then
        return 1
    end
    local alpha = ownAlpha(object, s)
    if not (s.ignoreParentAlpha or s.isRoot) and s.parent and S[s.parent] then
        alpha = alpha * exportAlpha(s.parent)
    end
    alphaMemo[object] = alpha
    return alpha
end
local exportClip
-- The clip a frame puts on what it holds: its own rectangle if it clips, within the clip it is in
local function insideClip(frame)
    local known = insideClipMemo[frame]
    if known then
        return known ~= NO_CLIP and known or nil
    end
    local clip = exportClip(frame)
    if S[frame].clips then
        clip = clipTo(clip, frame)
    end
    insideClipMemo[frame] = clip or NO_CLIP
    return clip
end
exportClip = function(frame)
    local known = clipMemo[frame]
    if known then
        return known ~= NO_CLIP and known or nil
    end
    local s = S[frame]
    local parent = s and s.parent
    local clip = parent and S[parent] and insideClip(parent) or nil
    -- (a scroll child: cut to its scroll frame, which clips only it)
    if s and s.scrollChildOf and S[s.scrollChildOf] then
        clip = clipTo(clip, s.scrollChildOf)
    end
    clipMemo[frame] = clip or NO_CLIP
    return clip
end
local transformMemo = {}
local NO_TRANSFORM = {}
local function clearExportMemos()
    for key in pairs(alphaMemo) do
        alphaMemo[key] = nil
    end
    for key in pairs(transformMemo) do
        transformMemo[key] = nil
    end
    for key in pairs(clipMemo) do
        clipMemo[key] = nil
    end
    for key in pairs(insideClipMemo) do
        insideClipMemo[key] = nil
    end
end

-- Each edge snapped to the pixel, as the game draws, and the size from the snapped edges: two rectangles that share an
-- edge then meet exactly (rounding the size apart from the position left one-pixel seams between rows of strips)
local function toBox(rect)
    local left, right = round(rect[1]), round(rect[3])
    local top, bottom = round(sim.screenHeight - rect[4]), round(sim.screenHeight - rect[2])
    return left, top, right - left, bottom - top
end

-- Animations' moves, sizes and turns as affine maps of the game's coordinates (y up): x' = a x + b y + c, y' = d x + e
-- y + f. An object's own (Translation, Scale, Rotation about its origin) after its parent's: a frame's carries what it
-- holds along
local ORIGIN_X = { LEFT = 0, TOPLEFT = 0, BOTTOMLEFT = 0, RIGHT = 1, TOPRIGHT = 1, BOTTOMRIGHT = 1 }
local ORIGIN_Y = { BOTTOM = 0, BOTTOMLEFT = 0, BOTTOMRIGHT = 0, TOP = 1, TOPLEFT = 1, TOPRIGHT = 1 }
local function ownTransform(object)
    local effect = animation.effectOf(object)
    if
        not effect
        or (effect.dx == 0 and effect.dy == 0 and effect.scaleX == 1 and effect.scaleY == 1 and effect.radians == 0)
    then
        return nil
    end
    local rect = W.computeRect(object)
    if not rect then
        return nil
    end
    local scale = W.getEffectiveScale(object)
    local point = effect.originPoint or "CENTER"
    local ox = rect[1] + (rect[3] - rect[1]) * (ORIGIN_X[point] or 0.5) + (effect.originX or 0) * scale
    local oy = rect[2] + (rect[4] - rect[2]) * (ORIGIN_Y[point] or 0.5) + (effect.originY or 0) * scale
    local cos, sin = math.cos(effect.radians), math.sin(effect.radians)
    local sx, sy = effect.scaleX, effect.scaleY
    -- about the origin: scaled, then turned; then moved
    local a, b, d, e = cos * sx, -sin * sy, sin * sx, cos * sy
    local c = ox - a * ox - b * oy + effect.dx * scale
    local f = oy - d * ox - e * oy + effect.dy * scale
    return { a, b, c, d, e, f }
end
local function transformOf(object)
    local known = transformMemo[object]
    if known then
        return known ~= NO_TRANSFORM and known or nil
    end
    local s = S[object]
    local parentTransform = s and not s.isRoot and s.parent and S[s.parent] and transformOf(s.parent) or nil
    local own = ownTransform(object)
    local result = parentTransform
    if own and parentTransform then
        local p = parentTransform
        result = {
            p[1] * own[1] + p[2] * own[4],
            p[1] * own[2] + p[2] * own[5],
            p[1] * own[3] + p[2] * own[6] + p[3],
            p[4] * own[1] + p[5] * own[4],
            p[4] * own[2] + p[5] * own[5],
            p[4] * own[3] + p[5] * own[6] + p[6],
        }
    elseif own then
        result = own
    end
    transformMemo[object] = result or NO_TRANSFORM
    return result
end

-- A box (x, y from the top left, w, h) moved, sized and turned by a map: its new box, and how much it turned
local function mapBox(m, x, y, w, h)
    local height = sim.screenHeight
    local cx, cy = x + w / 2, height - (y + h / 2)
    local nx, ny = m[1] * cx + m[2] * cy + m[3], m[4] * cx + m[5] * cy + m[6]
    local scaleX, scaleY = math.sqrt(m[1] * m[1] + m[4] * m[4]), math.sqrt(m[2] * m[2] + m[5] * m[5])
    local nw, nh = w * scaleX, h * scaleY
    return round(nx - nw / 2), round(height - ny - nh / 2), round(nw), round(nh), math.atan2(m[4], m[1]), scaleY
end

---The items exported for an object (from index first on) changed by what its animations, and its parents', do
local function animateItems(items, first, object)
    local m = transformOf(object)
    local effect = animation.effectOf(object)
    for index = first, #items do
        local item = items[index]
        if m then
            if item.k == "ln" then
                local height = sim.screenHeight
                local x1, y1 = item.x1, height - item.y1
                local x2, y2 = item.x2, height - item.y2
                item.x1, item.y1 = round(m[1] * x1 + m[2] * y1 + m[3]), round(height - (m[4] * x1 + m[5] * y1 + m[6]))
                item.x2, item.y2 = round(m[1] * x2 + m[2] * y2 + m[3]), round(height - (m[4] * x2 + m[5] * y2 + m[6]))
            elseif item.w then
                local turn, scaleY
                item.x, item.y, item.w, item.h, turn, scaleY = mapBox(m, item.x, item.y, item.w, item.h)
                if item.k == "t" and math.abs(turn) > 0.0001 then
                    item.rot = (item.rot or 0) + turn
                end
                if item.k == "s" and math.abs(scaleY - 1) > 0.001 then
                    item.fs = round(item.fs * scaleY)
                    item.lh = item.lh and round(item.lh * scaleY)
                end
                for _, mask in ipairs(item.mk or {}) do
                    local b = mask.b
                    local mx, my, mw, mh = mapBox(m, b[1], b[2], b[3], b[4])
                    mask.b = { mx, my, mw, mh }
                end
            end
        end
        -- A texture's own: its coordinates scrolled, a cell of its sheet, a colour
        if effect and item.k == "t" then
            if effect.cell or effect.u ~= 0 or effect.v ~= 0 then
                local tc = item.tc or { 0, 1, 0, 1 }
                local left, right, top, bottom = tc[1], tc[2], tc[3], tc[4]
                if effect.cell then
                    local cell, rows, columns = effect.cell[1], effect.cell[2], effect.cell[3]
                    local column, row = cell % columns, math.floor(cell / columns)
                    local width, height = (right - left) / columns, (bottom - top) / rows
                    left, top = left + column * width, top + row * height
                    right, bottom = left + width, top + height
                end
                item.tc = { left + effect.u, right + effect.u, top - effect.v, bottom - effect.v }
                item.tcTurned = nil
            end
            if effect.color then
                local vc, color = item.vc, effect.color
                item.vc = {
                    (vc and vc[1] or 1) * color[1],
                    (vc and vc[2] or 1) * color[2],
                    (vc and vc[3] or 1) * color[3],
                    (vc and vc[4] or 1) * color[4],
                }
            end
        end
    end
end

local function frameOrder(frame)
    local s = S[frame]
    local strata = W.getStrata(frame)
    local level, raised = W.drawLevel(frame)
    return W.STRATA_RANK[strata] or 4, level, raised, s.id
end

-- The shown frames in drawing order, kept until the order may have changed (sim.orderVersion; and a quarter second at
-- most, ORDER_KEPT_SECONDS): the mouse moving, a click and a key
-- between two frames of the game's clock ask for it again and again. Each frame's visibility is worked out once (its
-- parent's answer reused), and its place in the order once, not at every comparison of the sort. Read only: callers
-- go through it, none changes it.
-- (kept while the order stands, W.touchOrder; made again at least every quarter of a game second all the same, in
-- case something changed the order by a way not told)
local sortedFrames, sortedVersion, sortedAt
-- (each sorted frame's strata, level and raise: frames that share all three are drawn as one level, below)
local sortedStratas, sortedLevels, sortedRaises
-- The frames with no parent (or the screen itself): where the walk starts. Kept until a frame is made or moved to
-- another parent.
local roots, rootsFrameCount, rootsParentVersion
local function getRoots()
    if roots and rootsFrameCount == #W.frames and rootsParentVersion == sim.parentVersion then
        return roots
    end
    roots = {}
    for _, frame in ipairs(W.frames) do
        local state = S[frame]
        if state and (state.isRoot or not state.parent or not S[state.parent]) then
            roots[#roots + 1] = frame
        end
    end
    rootsFrameCount, rootsParentVersion = #W.frames, sim.parentVersion
    return roots
end
local ORDER_KEPT_SECONDS = 0.25
function scene.getSortedFrames()
    if sortedFrames and sortedVersion == sim.orderVersion and sim.now - sortedAt < ORDER_KEPT_SECONDS then
        return sortedFrames
    end
    -- Down from the top frames (no parent, or the screen's own) through the shown ones only: what is hidden, and all
    -- it holds, is never looked at (of 13 000 frames, a few hundred are shown)
    local roots = getRoots()
    local frames, stratas, levels, raises = {}, {}, {}, {}
    -- (the screen's own frames too: a texture an addon makes on UIParent is drawn, at UIParent's strata and level)
    local function visit(frame, state)
        frames[#frames + 1] = frame
        stratas[frame], levels[frame], raises[frame] = frameOrder(frame)
        local children = state.children
        if children then
            for index = 1, #children do
                local child = children[index]
                local childState = S[child]
                if childState and childState.shown and childState.parent == frame then
                    visit(child, childState)
                end
            end
        end
    end
    for index = 1, #roots do
        local frame = roots[index]
        local state = S[frame]
        if state and state.shown then
            visit(frame, state)
        end
    end
    table.sort(frames, function(first, second)
        local firstStrata, secondStrata = stratas[first], stratas[second]
        if firstStrata ~= secondStrata then
            return firstStrata < secondStrata
        end
        -- By the level each is drawn at (a raised frame's own, W.drawLevel), then the one raised last in front
        local firstLevel, secondLevel = levels[first], levels[second]
        if firstLevel ~= secondLevel then
            return firstLevel < secondLevel
        end
        local firstRaised, secondRaised = raises[first], raises[second]
        if firstRaised ~= secondRaised then
            return firstRaised < secondRaised
        end
        return S[first].id < S[second].id
    end)
    sortedFrames, sortedVersion, sortedAt = frames, sim.orderVersion, sim.now
    sortedStratas, sortedLevels, sortedRaises = stratas, levels, raises
    return frames
end

-- The shown frames in drawing order with each one's level group (a number; frames of one strata, level and raise
-- share it), worked out once for each sorted list: the native walk's order (lua/scenesync.lua)
local groupedFrames, frameGroups
function scene.getFrameGroups()
    local frames = scene.getSortedFrames()
    if groupedFrames ~= frames then
        groupedFrames, frameGroups = frames, {}
        local group = 0
        for index, frame in ipairs(frames) do
            local previous = frames[index - 1]
            if
                not previous
                or sortedStratas[frame] ~= sortedStratas[previous]
                or sortedLevels[frame] ~= sortedLevels[previous]
                or sortedRaises[frame] ~= sortedRaises[previous]
            then
                group = group + 1
            end
            frameGroups[index] = group
        end
    end
    return frames, frameGroups
end

local function isPressed(frame)
    return sim.mouseDown ~= nil and sim.mouseDown.frame == frame and sim.motionFocus == frame
end

---Whether a button's state texture shows now, as the game swaps them.
local function isRoleShown(frame, role)
    local s = S[frame]
    local isEnabled = s.enabled ~= false
    if role == "normal" then
        return not ((isPressed(frame) or s.buttonState == "PUSHED") and s.pushed) and not (not isEnabled and s.disabled)
    elseif role == "pushed" then
        return isEnabled and (isPressed(frame) or s.buttonState == "PUSHED")
    elseif role == "disabled" then
        return not isEnabled
    elseif role == "highlight" then
        return (sim.motionFocus == frame and (isEnabled or s.motionWhileDisabled)) or s.highlightLocked == true
    elseif role == "checkedTexture" then
        return s.checked == true and (isEnabled or not s.disabledChecked)
    elseif role == "disabledChecked" then
        return s.checked == true and not isEnabled
    end
    return true
end

local WRAP_CODES = { REPEAT = "r", MIRROR = "m", CLAMPTOBLACK = "b", CLAMPTOBLACKADDITIVE = "b", CLAMPTOWHITE = "w" }
local function exportTexture(items, region, rs, frame, rect, alpha, clip)
    local item = { k = "t", i = rs.id }
    item.x, item.y, item.w, item.h = toBox(rect)
    -- Corners moved with SetVertexOffset (in the texture's units, y up): the shape's corners, upper left, upper
    -- right, lower right, lower left, as fractions of its box, which the page clips the texture to
    if rs.vertexOffsets and next(rs.vertexOffsets) then
        local scale = W.getEffectiveScale(region)
        local width, height = rect[3] - rect[1], rect[4] - rect[2]
        local function corner(index, x, y)
            local offset = rs.vertexOffsets[index] or { 0, 0 }
            local cornerX = x * width + offset[1] * scale
            local cornerY = y * height - offset[2] * scale -- down the screen
            return round(cornerX / math.max(width, 0.01) * 1000) / 1000,
                round(cornerY / math.max(height, 0.01) * 1000) / 1000
        end
        local ulX, ulY = corner(1, 0, 0)
        local urX, urY = corner(3, 1, 0)
        local lrX, lrY = corner(4, 1, 1)
        local llX, llY = corner(2, 0, 1)
        item.poly = { ulX, ulY, urX, urY, lrX, lrY, llX, llY }
    end
    -- A radial progress bar: only the sweep it shows (pie: from and to, in turns clockwise from the top)
    local radial = rs.radial
    if radial and radial.percent then
        local room = math.max(0, 1 - (radial.startOffset or 0) - (radial.endOffset or 0))
        local span = room * radial.percent
        if span <= 0.0001 then
            return
        end
        if span < 0.9999 then
            local from = radial.reverse and (1 - (radial.startOffset or 0) - span) or (radial.startOffset or 0)
            item.pie = { math.floor(from * 10000 + 0.5) / 10000, math.floor((from + span) * 10000 + 0.5) / 10000 }
        end
    end
    if rs.color then
        item.c = rs.color
    elseif rs.atlas then
        item.atlas = rs.atlas
        -- A sliced atlas keeps its corners at their own size, times the scale it is drawn at
        local scale = W.getEffectiveScale(region)
        if scale ~= 1 then
            item.sc = round(scale * 1000) / 1000
        end
    elseif rs.texture then
        item.tex = rs.texture
        -- Nine-sliced (SetTextureSliceMargins): its margins in texels, its corners at their size times its scale
        if rs.slice then
            item.sl = rs.slice
            local scale = W.getEffectiveScale(region)
            if scale ~= 1 then
                item.sc = round(scale * 1000) / 1000
            end
            -- (edges and middle tiled rather than stretched: SetTextureSliceMode(1))
            if rs.sliceMode == 1 then
                item.slm = 1
            end
        end
        -- How it is read past its edges, across and down, when not clamped (SetTexture's wrap modes): r repeats, m
        -- mirrors, b is nothing (CLAMPTOBLACK, CLAMPTOBLACKADDITIVE), w white (CLAMPTOWHITE)
        local wrapH, wrapV = WRAP_CODES[rs.wrapH or ""], WRAP_CODES[rs.wrapV or ""]
        if wrapH or wrapV then
            item.wr = (wrapH or "c") .. (wrapV or "c")
        end
    elseif not rs.gradient then
        return
    end
    item.a = round(alpha * 100) / 100
    if rs.vertexColor then
        item.vc = rs.vertexColor
    end
    if rs.texCoord then
        item.tc = rs.texCoord
    end
    if rs.isTexCoordTurned then
        item.tcTurned = true
    end
    if rs.blend and rs.blend ~= "BLEND" then
        item.bl = rs.blend
    end
    -- Greyed: wholly (SetDesaturated, SetDesaturation 1), or partly (SetDesaturation 0.4)
    local desaturation = rs.desaturation
    if desaturation and desaturation > 0.001 and desaturation < 0.999 then
        item.ds = round(desaturation * 100) / 100
    elseif rs.desaturated then
        item.ds = true
    end
    if rs.rotation and rs.rotation ~= 0 then
        item.rot = rs.rotation
    end
    if rs.gradient then
        item.gr = rs.gradient
    end
    if rs.horizTile or rs.vertTile then
        item.tile = { rs.horizTile and true or false, rs.vertTile and true or false }
    end
    -- Its masks (up to three), each: its texture, or an atlas as most of the game's masks are (the player portrait's
    -- circle, the action icons' rounded square); where it is (it cuts textures that only partly cover it: the minimap's
    -- round edge across a tile); nine-sliced (EllesmereUI's rounded corners: margins in texels, and its scale); and
    -- what lies past its box (wr: "white" lets it be, "black" cuts it; else its edge's texels go on)
    for _, mask in ipairs(rs.masks or {}) do
        local maskState = S[mask]
        local maskRect = maskState and (maskState.texture or maskState.atlas) and W.computeRect(mask)
        if maskRect then
            local entry = { b = { toBox(maskRect) } }
            if maskState.texture then
                entry.tex = maskState.texture
            else
                entry.atlas = maskState.atlas
            end
            if maskState.slice then
                entry.sl = maskState.slice
                local scale = W.getEffectiveScale(mask)
                if scale ~= 1 then
                    entry.sc = round(scale * 1000) / 1000
                end
            end
            local wrap = maskState.wrapH or maskState.wrapV
            if wrap == "CLAMPTOWHITE" then
                entry.wr = "white"
            elseif wrap == "CLAMPTOBLACK" or wrap == "CLAMPTOBLACKADDITIVE" then
                entry.wr = "black"
            end
            item.mk = item.mk or {}
            item.mk[#item.mk + 1] = entry
        end
    end
    -- Map tiles overlap a hair on the page, so no seams show between them: the stand-in map's on its canvas, the game's
    -- in the layers on its canvas (their background art; the pins over them keep their size)
    local fs = S[frame]
    if
        fs
        and (fs.isMapCanvas or (rs.layer == "BACKGROUND" and fs.parent and S[fs.parent] and S[fs.parent].isMapCanvas))
    then
        item.seam = true
    end
    if clip then
        item.cl = { toBox(clip) }
    end
    items[#items + 1] = item
end

local function exportFontString(items, region, rs, rect, alpha, clip)
    if not rs.text or rs.text == "" then
        return
    end
    local font = fonts.getFont(rs)
    local scale = W.getEffectiveScale(region)
    local width = (rect[3] - rect[1]) / scale
    local lines = fonts.wrap(rs, width > 0 and (#rs.points >= 2 or (rs.width and rs.width > 0)) and width or nil)
    -- A string given a height (its size, or anchored top and bottom) shows only the lines that fit in it, the last
    -- one cut with "...", as the client draws it (a party frame's name in its 12-high box: one line)
    local height = (rect[4] - rect[2]) / scale
    local hasHeight = (rs.height and rs.height > 0) or #rs.points >= 2
    local lineHeight = fonts.getLineHeight(rs)
    local spacing = rs.spacing or font.spacing or 0
    if hasHeight and height > 0 and #lines > 1 and #lines * lineHeight + (#lines - 1) * spacing > height + 1 then
        local fitting = math.max(1, math.floor((height + spacing + 1) / (lineHeight + spacing)))
        if fitting < #lines then
            -- The last line shown runs on with what follows, cut a character at a time until it fits with the dots
            local rest = {}
            for index = fitting, #lines do
                rest[#rest + 1] = lines[index].text
            end
            for index = #lines, fitting + 1, -1 do
                lines[index] = nil
            end
            local function measure(part)
                return fonts.measureWidth(
                    setmetatable({ text = part, maxLines = false, wordWrap = false }, { __index = rs })
                )
            end
            local cut, dotsWidth = table.concat(rest, " "), measure("...")
            while #cut > 0 and measure(cut) + dotsWidth > width + 0.5 do
                cut = cut:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
            end
            cut = cut:gsub("%s+$", "")
            lines[fitting] = { text = cut .. "...", width = measure(cut) + dotsWidth }
        end
    end
    local texts = {}
    for index, line in ipairs(lines) do
        texts[index] = line.text
    end
    -- The text's colour, tinted by its vertex colour as in the client (the target frame greys a trivial level so)
    local color = fonts.getColor(rs)
    local tint = rs.vertexColor
    if tint then
        color = {
            (color[1] or 1) * tint[1],
            (color[2] or 1) * tint[2],
            (color[3] or 1) * tint[3],
            (color[4] or 1) * (tint[4] or 1),
        }
    end
    local item = {
        k = "s",
        i = rs.id,
        lines = texts,
        f = fonts.key(font.path),
        fs = round(font.size * (rs.textScale or 1) * scale),
        fl = font.flags ~= "" and font.flags or nil,
        c = color,
        a = round(alpha * 100) / 100,
        jh = rs.justifyH or font.justifyH or "CENTER",
        jv = rs.justifyV or "MIDDLE",
        lh = round(fonts.getLineHeight(rs) * scale),
        sp = round((rs.spacing or font.spacing or 0) * scale),
    }
    local shadow = rs.shadowOffset or font.shadowOffset
    if shadow and (shadow[1] ~= 0 or shadow[2] ~= 0) then
        item.sh = { shadow[1], shadow[2] }
        -- (its colour, when not the usual black)
        local shadowColor = rs.shadowColor or font.shadowColor
        if
            shadowColor
            and (
                (shadowColor[1] or 0) ~= 0
                or (shadowColor[2] or 0) ~= 0
                or (shadowColor[3] or 0) ~= 0
                or (shadowColor[4] or 1) ~= 1
            )
        then
            item.shc = { shadowColor[1] or 0, shadowColor[2] or 0, shadowColor[3] or 0, shadowColor[4] or 1 }
        end
    end
    -- Faded out from a character on (SetAlphaGradient: the character, and over how many units, times the scale)
    if rs.alphaGradient then
        item.ag = { rs.alphaGradient[1], round(rs.alphaGradient[2] * scale) }
    end
    item.x, item.y, item.w, item.h = toBox(rect)
    if rs.isEditText and W.focus == rs.parent then
        item.cursor = true
    end
    if clip then
        item.cl = { toBox(clip) }
    end
    items[#items + 1] = item
end

---A message frame's messages (lua/widgets.lua's MessageFrame): each in its own colour, in the frame's font and
---justification, wrapped to its width; the newest at the bottom (or at the top: insertMode TOP), from the scroll
---offset on, as many as fit; a fading frame's old ones fading and then gone. Clipped to the frame.
local TWO_POINTS = { true, true } -- (a message is as wide as its frame: a font string anchored on both sides)
local function exportMessageFrame(items, frame, fs, rect, alpha, clip)
    local messages = fs.messages
    if not messages or #messages == 0 then
        return
    end
    local scale = W.getEffectiveScale(frame)
    local width = (rect[3] - rect[1]) / scale
    if width <= 0 then
        return
    end
    local isTop = fs.insertMode == "TOP"
    local isFading = fs.fading ~= false
    local visible, fadeTime = fs.timeVisible or 10, fs.fadeDuration or 3
    local messageClip = clipTo(clip, frame)
    local y = isTop and rect[4] or rect[2]
    for index = #messages - (fs.scrollOffset or 0), 1, -1 do
        local message = messages[index]
        local age = sim.now - message.time
        local fade = 1
        if isFading and age > visible then
            fade = 1 - (age - visible) / math.max(fadeTime, 0.001)
        end
        if fade > 0 then
            local state = setmetatable({
                text = message.text,
                id = message.id,
                points = TWO_POINTS,
                width = width,
                maxLines = false,
                textColor = { message.r, message.g, message.b, message.a or 1 },
                justifyH = fs.justifyH or "LEFT",
                justifyV = "TOP",
            }, { __index = fs })
            local height = fonts.measureHeight(state, width) * scale
            state.height = height / scale
            local top = isTop and y or y + height
            local bottom = top - height
            exportFontString(items, frame, state, { rect[1], bottom, rect[3], top }, alpha * fade, messageClip)
            y = isTop and bottom or top
            if (isTop and y <= rect[2]) or (not isTop and y >= rect[4]) then
                break
            end
        end
    end
end

---A line cut to a clipping rect (Liang-Barsky), as a frame that clips its children draws it.
---@return number? x1, number? y1, number? x2, number? y2 nil when the line lies wholly outside
local function clipSegment(x1, y1, x2, y2, rect)
    local dx, dy = x2 - x1, y2 - y1
    local first, last = 0, 1
    for _, edge in ipairs({ { -dx, x1 - rect[1] }, { dx, rect[3] - x1 }, { -dy, y1 - rect[2] }, { dy, rect[4] - y1 } }) do
        local p, q = edge[1], edge[2]
        if p == 0 then
            if q < 0 then
                return nil
            end
        else
            local t = q / p
            if p < 0 then
                if t > last then
                    return nil
                end
                if t > first then
                    first = t
                end
            else
                if t < first then
                    return nil
                end
                if t < last then
                    last = t
                end
            end
        end
    end
    return x1 + dx * first, y1 + dy * first, x1 + dx * last, y1 + dy * last
end

local function exportLine(items, region, rs, alpha, clip)
    local x1, y1, x2, y2 = W.getLineEnds(region)
    if not x1 then
        return
    end
    if clip then
        x1, y1, x2, y2 = clipSegment(x1, y1, x2, y2, clip)
        if not x1 then
            return
        end
    end
    local item = {
        k = "ln",
        i = rs.id,
        x1 = round(x1),
        y1 = round(sim.screenHeight - y1),
        x2 = round(x2),
        y2 = round(sim.screenHeight - y2),
        th = round((rs.thickness or 1) * W.getEffectiveScale(region) * 100) / 100,
        c = rs.color,
        tex = rs.texture,
        vc = rs.vertexColor,
        a = round(alpha * 100) / 100,
    }
    if clip then
        item.cl = { toBox(clip) }
    end
    items[#items + 1] = item
end

---A slider's thumb and a status bar's fill take their place from the value.
local function getValueRect(frame, fs, region, rect)
    local minimum, maximum = fs.minValue or 0, fs.maxValue or 1
    -- (a bar on a timer: its value the time gone or left now, SetTimerDuration)
    local value = (fs.timer and W.statusBarTimerValue and W.statusBarTimerValue(frame)) or fs.value or 0
    local fraction = maximum > minimum and (value - minimum) / (maximum - minimum) or 0
    fraction = math.max(0, math.min(1, fraction))
    local frameRect = W.computeRect(frame)
    if not frameRect then
        return rect
    end
    local isVertical = W.orientationOf(frame) == "VERTICAL"
    if S[region].role == "bar" then
        -- The bar's texture cropped to the part filled, as the client fills it (not squeezed): from the start (the left,
        -- or the bottom), from the end (reversed: REVERSE, SetReverseFill), or out from the middle (CENTER)
        local style = fs.fillStyle or "STANDARD"
        local from, to = 0, fraction
        if style == "CENTER" then
            from, to = 0.5 - fraction / 2, 0.5 + fraction / 2
        elseif style == "REVERSE" or fs.reverseFill then
            from, to = 1 - fraction, 1
        end
        if isVertical then
            local height = frameRect[4] - frameRect[2]
            -- (texture coordinates run down: the bottom of the bar is the bottom of the texture)
            return { frameRect[1], frameRect[2] + height * from, frameRect[3], frameRect[2] + height * to }, {
                0,
                1,
                1 - to,
                1 - from,
            }
        end
        local width = frameRect[3] - frameRect[1]
        return { frameRect[1] + width * from, frameRect[2], frameRect[1] + width * to, frameRect[4] }, { from, to, 0, 1 }
    end
    local scale = W.getEffectiveScale(region)
    local width, height = (S[region].width or 16) * scale, (S[region].height or 16) * scale
    if isVertical then
        local y = frameRect[4] - height / 2 - (frameRect[4] - frameRect[2] - height) * fraction
        local x = (frameRect[1] + frameRect[3]) / 2
        return { x - width / 2, y - height / 2, x + width / 2, y + height / 2 }
    end
    local x = frameRect[1] + width / 2 + (frameRect[3] - frameRect[1] - width) * fraction
    local y = (frameRect[2] + frameRect[4]) / 2
    return { x - width / 2, y - height / 2, x + width / 2, y + height / 2 }
end

local LAYER_RANK = W.LAYER_RANK

-- A cooldown running, as the client draws it over its button: the swipe over the time still to run (reversed: over
-- the time gone), clockwise from the top, in its colour or texture; the seconds left in the middle when the
-- countdownForCooldowns setting is on (whole seconds, then minutes, then hours)
local COUNTDOWN_FONT = "Fonts\\FRIZQT__.TTF"
local COOLDOWN_EDGE = "Interface\\Cooldown\\edge"
local COOLDOWN_BLING = "Interface\\Cooldown\\star4"
local function exportCooldown(items, frame, fs, rect, alpha, clip)
    local swipe = fs.swipe or {}
    -- The bling: as it runs out, the star flashes over the button, growing and fading
    if fs.blingAt and not fs.cooldown then
        local progress = (sim.now - fs.blingAt) / W.COOLDOWN_BLING_SECONDS
        if progress >= 0 and progress < 1 then
            local x, y, w, h = toBox(rect)
            local grow = 1 + progress * 0.5
            local item = {
                k = "t",
                i = fs.id .. "bling",
                tex = swipe.blingTexture or COOLDOWN_BLING,
                bl = "ADD",
                a = round(alpha * (1 - progress) * 100) / 100,
                x = round(x + w / 2 - w * grow / 2),
                y = round(y + h / 2 - h * grow / 2),
                w = round(w * grow),
                h = round(h * grow),
            }
            if clip then
                item.cl = { toBox(clip) }
            end
            items[#items + 1] = item
        end
        return
    end
    local cooldown = fs.cooldown
    if not cooldown then
        return
    end
    local elapsed = (fs.paused or sim.now) - cooldown.start
    if elapsed < 0 or elapsed >= cooldown.duration then
        return
    end
    local done = math.floor(elapsed / cooldown.duration * 10000 + 0.5) / 10000
    if swipe.drawSwipe ~= false then
        local color = swipe.color or { 0, 0, 0, 0.8 }
        local item = { k = "t", i = fs.id .. "swipe", a = round(alpha * 100) / 100 }
        item.x, item.y, item.w, item.h = toBox(rect)
        if swipe.texture then
            item.tex = swipe.texture
            item.vc = color
        else
            item.c = color
        end
        item.pie = swipe.reverse and { 0, done } or { done, 1 }
        if clip then
            item.cl = { toBox(clip) }
        end
        items[#items + 1] = item
    end
    -- The edge: the game's edge art (a line from its middle up to its top) laid over the button and turned with the
    -- sweep's front
    if swipe.drawEdge then
        local x, y, w, h = toBox(rect)
        local item = {
            k = "t",
            i = fs.id .. "edge",
            tex = swipe.edgeTexture or COOLDOWN_EDGE,
            vc = swipe.edgeColor,
            a = round(alpha * 100) / 100,
            x = x,
            y = y,
            w = w,
            h = h,
            rot = -done * math.pi * 2,
        }
        -- (the art at the edge scale, cut to the button: at the square root of 2, the client's default, its line
        -- reaches the button's corners)
        local grow = swipe.edgeScale or math.sqrt(2)
        if grow ~= 1 then
            item.x, item.y = round(x + w / 2 - w * grow / 2), round(y + h / 2 - h * grow / 2)
            item.w, item.h = round(w * grow), round(h * grow)
        end
        local cutTo = clip and clipTo(clip, frame) or rect
        if cutTo then
            item.cl = { toBox(cutTo) }
        end
        items[#items + 1] = item
    end
    local cvar = sim.cvars and sim.cvars.countdownForCooldowns
    if not swipe.hideNumbers and (cvar == "1" or cvar == 1 or cvar == true) then
        local left = cooldown.duration - elapsed
        local text = left >= 3600 and (math.ceil(left / 3600) .. "h")
            or left >= 60 and (math.ceil(left / 60) .. "m")
            or tostring(math.ceil(left))
        local scale = W.getEffectiveScale(frame)
        local size = math.max(8, math.min(24, (rect[4] - rect[2]) / scale * 0.45))
        local item = {
            k = "s",
            i = fs.id .. "countdown",
            lines = { text },
            f = fonts.key(COUNTDOWN_FONT),
            fs = round(size * scale),
            fl = "OUTLINE",
            c = { 1, 1, 1, 1 },
            a = round(alpha * 100) / 100,
            jh = "CENTER",
            jv = "MIDDLE",
            lh = round(size * 1.2 * scale),
            sp = 0,
        }
        item.x, item.y, item.w, item.h = toBox(rect)
        if clip then
            item.cl = { toBox(clip) }
        end
        items[#items + 1] = item
    end
end

-- A UnitPositionFrame's units, as the client draws them: each where it stands on the frame's map, its size times the
-- frame's scale, its colour, the player's arrow turned by their facing; and the player's ping, a ring running out
local function exportUnits(items, frame, fs, rect, alpha, clip)
    fs.drawnUnits = {}
    local mapId = fs.uiMapId
    if not mapId or not fs.units or not G.C_Map then
        return
    end
    local scale = W.getEffectiveScale(frame)
    local width, height = rect[3] - rect[1], rect[4] - rect[2]
    local entries = {}
    for _, entry in ipairs(fs.units) do
        entries[#entries + 1] = entry
    end
    -- The player's arrow over the party's dots (the larger sublevel on top; the player last among equals)
    table.sort(entries, function(first, second)
        if first.sublayer ~= second.sublayer then
            return first.sublayer < second.sublayer
        end
        return (first.unit == "player" and 1 or 0) < (second.unit == "player" and 1 or 0)
    end)
    local function addItem(key, centerX, centerY, sizeX, sizeY, asset, color, rotation, itemAlpha)
        local item = { k = "t", i = fs.id .. key }
        item.x, item.y, item.w, item.h =
            toBox({ centerX - sizeX / 2, centerY - sizeY / 2, centerX + sizeX / 2, centerY + sizeY / 2 })
        if W.getAtlasInfo(asset) then
            item.atlas = asset
        else
            item.tex = asset
        end
        item.a = round(itemAlpha * 100) / 100
        if color then
            item.vc = color
        end
        if rotation and rotation ~= 0 then
            item.rot = rotation
        end
        if clip then
            item.cl = { toBox(clip) }
        end
        items[#items + 1] = item
    end
    for _, entry in ipairs(entries) do
        local position = G.C_Map.GetPlayerMapPosition(mapId, entry.unit)
        local x, y = position and position.x, position and position.y
        if x and y and (x ~= 0 or y ~= 0) then
            local centerX, centerY = rect[1] + x * width, rect[4] - y * height
            local sizeX, sizeY = entry.width * scale, entry.height * scale
            if entry.unit == "player" and fs.ping and fs.pingTextures then
                -- The ping: its ring grows and fades over the time given, the centre glows under the arrow
                local age = sim.now - fs.ping.start
                if age < fs.ping.duration then
                    local progress = (age % 1)
                    local fade = math.min(1, (fs.ping.duration - age) / math.max(fs.ping.fade, 0.01))
                    local pingScale = (fs.pingScale or 1) * scale
                    local expand =
                        fs.pingTextures[G.Enum and G.Enum.PingTextureType and G.Enum.PingTextureType.Expand or 1]
                    if expand then
                        local size = expand.width * pingScale * (0.5 + progress * 1.5)
                        addItem(
                            "pingExpand",
                            centerX,
                            centerY,
                            size,
                            size,
                            expand.asset,
                            nil,
                            nil,
                            alpha * fade * (1 - progress)
                        )
                    end
                else
                    fs.ping = nil
                    if sim.liveVisuals then
                        sim.liveVisuals[frame] = nil
                    end
                end
            end
            local rotation = entry.showFacing and G.GetPlayerFacing and G.GetPlayerFacing() or nil
            addItem(
                "u" .. entry.unit,
                centerX,
                centerY,
                sizeX,
                sizeY,
                entry.asset,
                entry.color,
                rotation,
                alpha * (entry.color[4] or 1)
            )
            fs.drawnUnits[#fs.drawnUnits + 1] =
                { unit = entry.unit, x = centerX, y = centerY, radius = math.max(sizeX, sizeY) / 2 }
        end
    end
end

-- Kept items: a region's (or a frame's backdrop's) items from the last export are used again while everything they
-- were made from stands: its own state (its visual version, moved on by its setters: sim.touchVisual(object)), its
-- rectangle, scale, alpha and clip, its masks', the font objects' (fonts.version), the screen's height. A frame where
-- little changes then costs a comparison per region instead of new tables, and the stream sends nothing for them
-- (the same table as last time is the same item). What changes on its own is made every time: animated objects, a
-- bar on a timer, lines, a message frame's lines, units, cooldowns.
-- ADDONSIM_CHECK_SCENE=1: every export is made a second time without kept items and the two compared (and an export
-- follows every tick of the game's clock), any difference reported as an error: a setter that changes how an object
-- looks without saying so.
local isKeeping = true
local isChecking = os.getenv("ADDONSIM_CHECK_SCENE") == "1"
-- What an object's items are made from, in two parts: its shape (its state, size, scale, alpha, where its clip and
-- masks lie from it...) and its place (the boxes the items carry: its own, its clip's, its masks'). The same shape in
-- another place is a move: the kept items are given their new boxes, not made again (a dragged window's every item
-- moves at every step), and the stream sends only those (scene.moveCounts).
local stamp, stampCount = {}, 0
local place, placeCount = {}, 0
local placeMasks, placeMaskCount = {}, 0 -- (the masks' rectangles, in the order the items list them)
local function put(value)
    stampCount = stampCount + 1
    stamp[stampCount] = value
end
local function putPlace(value)
    placeCount = placeCount + 1
    place[placeCount] = value
end
local function putPlaceRect(rect)
    if rect then
        putPlace(rect[1])
        putPlace(rect[2])
        putPlace(rect[3])
        putPlace(rect[4])
    else
        putPlace(false)
    end
end
-- (sizes and offsets rounded past float noise: a rectangle moved has its width worked out at another place)
local function fine(value)
    return math.floor(value * 1000000 + 0.5) / 1000000
end
local function putSize(rect)
    if rect then
        put(fine(rect[3] - rect[1]))
        put(fine(rect[4] - rect[2]))
    else
        put(false)
    end
end
---A box (a clip, a mask) into the shape as where it lies from the object's rectangle, and its size
local function putRelative(box, rect)
    if box and rect then
        put(fine(box[1] - rect[1]))
        put(fine(box[2] - rect[2]))
        put(fine(box[3] - box[1]))
        put(fine(box[4] - box[2]))
    else
        put(box ~= nil)
    end
end
-- [item] = how many times its boxes were given anew in place (a move): the stream sends a move when this changed
scene.moveCounts = setmetatable({}, { __mode = "k" })
local moveCounts = scene.moveCounts
---Whether the object's kept items stand as they are ("kept"), stand somewhere else ("moved"), or not (false)
local function compareKept(kept, canMove)
    if not kept then
        return false
    end
    local keptStamp = kept.stamp
    if keptStamp.count ~= stampCount then
        return false
    end
    for index = 1, stampCount do
        if keptStamp[index] ~= stamp[index] then
            return false
        end
    end
    local keptPlace = kept.place
    if keptPlace.count ~= placeCount then
        return false
    end
    for index = 1, placeCount do
        if keptPlace[index] ~= place[index] then
            return canMove and "moved" or false
        end
    end
    return "kept"
end
local function copyInto(target, source, count)
    for index = 1, count do
        target[index] = source[index]
    end
    for index = count + 1, #target do
        target[index] = nil
    end
    target.count = count
end
---Keeps the items made (items[first..]) with the stamp and place they were made at, on the object's state (field)
local function keepItems(s, field, items, first)
    local kept = s[field]
    if not kept then
        kept = { stamp = {}, place = {}, items = {} }
        s[field] = kept
    end
    copyInto(kept.stamp, stamp, stampCount)
    copyInto(kept.place, place, placeCount)
    local keptItems = kept.items
    local count = 0
    for index = first, #items do
        count = count + 1
        keptItems[count] = items[index]
    end
    for index = count + 1, #keptItems do
        keptItems[index] = nil
    end
end
local function putKeptItems(items, kept)
    local keptItems = kept.items
    local count = #items
    for index = 1, #keptItems do
        items[count + index] = keptItems[index]
    end
end
---The kept items given their new boxes (the place just stamped: the object's rectangle, its clip, its masks')
local function moveKept(kept)
    copyInto(kept.place, place, placeCount)
    local rect = { place[1], place[2], place[3], place[4] }
    local clip = place[5] and { place[5], place[6], place[7], place[8] } or nil
    for _, item in ipairs(kept.items) do
        item.x, item.y, item.w, item.h = toBox(rect)
        if clip then
            item.cl = { toBox(clip) }
        else
            item.cl = nil
        end
        local masks = item.mk
        if masks then
            for index = 1, #masks do
                local maskRect = placeMasks[index]
                if maskRect then
                    masks[index].b = { toBox(maskRect) }
                end
            end
        end
        moveCounts[item] = (moveCounts[item] or 0) + 1
    end
end
---A region's stamp: false when its items are made every time (animated, a bar on a timer, a line); else true, and
---whether a move of it can be kept (not a bar's fill or a slider's thumb, placed from the value)
local function stampRegion(region, rs, frame, fs, ownerRect, regionAlpha, clip, isFlattened, frameAlpha)
    if rs.type == "Line" then
        return false
    end
    if isAnimating and (animation.effectOf(region) or transformOf(region)) then
        return false
    end
    local role = rs.role
    if (role == "bar" or role == "thumb") and fs.timer then
        return false
    end
    stampCount, placeCount, placeMaskCount = 0, 0, 0
    local rect = W.computeRect(region)
    put(rs.visualVersion or 0)
    putSize(rect)
    put(W.getEffectiveScale(region))
    put(regionAlpha)
    put(sim.screenHeight)
    putPlaceRect(rect)
    if rs.type == "FontString" then
        -- (a string in a clipping frame is cut to the frame; its font objects; the edit box's cursor)
        local stringClip = fs.clips and ownerRect or clip
        putRelative(stringClip, rect)
        putPlaceRect(stringClip)
        put(fonts.version)
        put(rs.isEditText == true and W.focus == rs.parent)
    else
        putRelative(clip, rect)
        putPlaceRect(clip)
        if role == "bar" or role == "thumb" then
            put(fs.visualVersion or 0)
            putPlaceRect(ownerRect)
        end
        local masks = rs.masks
        if masks then
            for index = 1, #masks do
                local mask = masks[index]
                local maskState = S[mask]
                local maskRect = maskState and (maskState.texture or maskState.atlas) and W.computeRect(mask)
                put(maskState and maskState.visualVersion or 0)
                putRelative(maskRect or nil, rect)
                put(W.getEffectiveScale(mask))
                if maskRect then
                    putPlaceRect(maskRect)
                    placeMaskCount = placeMaskCount + 1
                    placeMasks[placeMaskCount] = maskRect
                end
            end
        end
        put(frame)
        put(fs.isMapCanvas == true)
        put(fs.parent ~= nil and S[fs.parent] ~= nil and S[fs.parent].isMapCanvas == true)
    end
    put(isFlattened)
    if isFlattened then
        put(fs.id)
        put(frameAlpha)
    end
    return true, role ~= "bar" and role ~= "thumb"
end

-- The regions of the frame being exported, and of its children drawn at its level, with who owns each (the frame, or
-- such a child): kept between frames and exports, emptied as they are used (an export made thousands of these)
local gathered, gatheredCount = {}, 0
local ownerOf = setmetatable({}, { __mode = "k" })
-- [region] = layer, then text over textures, then sublevel, then the owner's rank, as one number (sorted on first)
local sortKey = setmetatable({}, { __mode = "k" })
local ownerPool, ownerCount = {}, 0
local drawnWithParent = {}
local function gather(ownerFrame, ownerState, ownerAlpha, ownerRect, ownerClip, rank)
    ownerCount = ownerCount + 1
    local owner = ownerPool[ownerCount]
    if not owner then
        owner = {}
        ownerPool[ownerCount] = owner
    end
    owner.frame, owner.fs, owner.alpha, owner.rect, owner.clip, owner.rank =
        ownerFrame, ownerState, ownerAlpha, ownerRect, ownerClip, rank
    local regions = ownerState.regions
    for index = 1, #regions do
        local region = regions[index]
        local rs = S[region]
        if rs and rs.shown and rs.type ~= "MaskTexture" and rs.parent == ownerFrame then
            gatheredCount = gatheredCount + 1
            gathered[gatheredCount] = region
            ownerOf[region] = owner
            local sublevel = math.max(-512, math.min(511, rs.sublevel or 0))
            sortKey[region] = (
                ((LAYER_RANK[rs.layer or "ARTWORK"] or 3) * 2 + (rs.type == "FontString" and 1 or 0)) * 1024
                + sublevel
                + 512
            )
                    * 1024
                + math.min(rank, 1023)
        end
    end
    local children = ownerState.children
    if children then
        for index = 1, #children do
            local child = children[index]
            local cs = S[child]
            if cs and cs.useParentLevel and cs.shown and not drawnWithParent[child] then
                local childRect, childAlpha = W.computeRect(child), exportAlpha(child)
                if childRect and childAlpha > 0.002 then
                    drawnWithParent[child] = true
                    gather(child, cs, childAlpha, childRect, exportClip(child), rank + 1)
                end
            end
        end
    end
end
-- By layer; in a layer the client draws its text over its textures, whatever their order or sublevel (the target
-- frame's level number over the circle behind it, both in OVERLAY); then sublevel, the owner's rank, when the art
-- was set, and the id (sortKey holds the first four)
local function regionOrder(first, second)
    local keyA, keyB = sortKey[first], sortKey[second]
    if keyA ~= keyB then
        return keyA < keyB
    end
    local a, b = S[first], S[second]
    local artA, artB = a.artOrder or 0, b.artOrder or 0
    if artA ~= artB then
        return artA < artB
    end
    return a.id < b.id
end

-- The gathered regions in drawing order. A frame's order is kept with what it was sorted from (each region, its key
-- and art order): the same again, as it nearly always is, takes the kept order without sorting (the map's frames
-- hold hundreds of regions, sorted at every export).
local function sortGathered(fs)
    local kept = fs.drawOrder
    if kept and kept.count == gatheredCount then
        local isSame = true
        local inputs, keys, arts = kept.inputs, kept.keys, kept.arts
        for index = 1, gatheredCount do
            local region = gathered[index]
            if
                inputs[index] ~= region
                or keys[index] ~= sortKey[region]
                or arts[index] ~= (S[region].artOrder or 0)
            then
                isSame = false
                break
            end
        end
        if isSame then
            local sorted = kept.sorted
            for index = 1, gatheredCount do
                gathered[index] = sorted[index]
            end
            return
        end
    end
    kept = { count = gatheredCount, inputs = {}, keys = {}, arts = {}, sorted = {} }
    for index = 1, gatheredCount do
        local region = gathered[index]
        kept.inputs[index], kept.keys[index], kept.arts[index] = region, sortKey[region], S[region].artOrder or 0
    end
    table.sort(gathered, regionOrder)
    for index = 1, gatheredCount do
        kept.sorted[index] = gathered[index]
    end
    fs.drawOrder = kept
end

-- The items made for one object, shared by the export below and by the native walk (lua/scenesync.lua), which asks
-- for the objects whose items have to be made again

local function makeBackdrop(items, fs, rect, alpha, clip)
    local item = {
        k = "b",
        i = fs.id,
        bg = fs.backdrop.bgFile,
        edge = fs.backdrop.edgeFile,
        es = fs.backdrop.edgeSize,
        ins = fs.backdrop.insets,
        tile = fs.backdrop.tile,
        ts = fs.backdrop.tileSize,
        c = fs.backdropColor,
        bc = fs.backdropBorderColor,
        a = round(alpha * 100) / 100,
    }
    item.x, item.y, item.w, item.h = toBox(rect)
    if clip then
        item.cl = { toBox(clip) }
    end
    items[#items + 1] = item
end

---A shown region's items, given its owner's (the frame it is drawn with) alpha, rectangle and clip
local function makeRegionItems(items, region, rs, frame, fs, alpha, rect, clip, regionAlpha, isFlattened)
    local regionFirst = #items + 1
    if rs.type == "FontString" then
        local regionRect = W.computeRect(region)
        if regionRect then
            exportFontString(
                items,
                region,
                rs,
                regionRect,
                regionAlpha,
                fs.clips and { rect[1], rect[2], rect[3], rect[4] } or clip
            )
        end
    elseif rs.type == "Line" then
        exportLine(items, region, rs, regionAlpha, clip)
    else
        local regionRect, crop = W.computeRect(region), nil
        if rs.role == "thumb" or rs.role == "bar" then
            regionRect, crop = getValueRect(frame, fs, region, regionRect)
        end
        if regionRect then
            local before = #items
            exportTexture(items, region, rs, frame, regionRect, regionAlpha, clip)
            local item = crop and #items > before and items[#items]
            if item and not item.tcTurned then
                -- (within the coordinates the texture has)
                local tc = item.tc or { 0, 1, 0, 1 }
                local spanX, spanY = tc[2] - tc[1], tc[4] - tc[3]
                item.tc = {
                    tc[1] + spanX * crop[1],
                    tc[1] + spanX * crop[2],
                    tc[3] + spanY * crop[3],
                    tc[3] + spanY * crop[4],
                }
            end
        end
    end
    if isAnimating and #items >= regionFirst then
        animateItems(items, regionFirst, region)
    end
    -- (a flattened frame's: drawn together into one layer, which takes the frame's alpha)
    if isFlattened then
        for index = regionFirst, #items do
            items[index].fg = fs.id
            items[index].fa = round(alpha * 100) / 100
        end
    end
    return regionFirst
end

---What a frame draws over its regions: a map's units, a cooldown's swipe
local function makeFrameAfter(items, frame, fs, rect, alpha, clip)
    if fs.type == "UnitPositionFrame" then
        exportUnits(items, frame, fs, rect, alpha, clip)
    end
    if (fs.cooldown or fs.blingAt) and fs.type == "Cooldown" then
        local cooldownFirst = #items + 1
        exportCooldown(items, frame, fs, rect, alpha, clip)
        if isAnimating and #items >= cooldownFirst then
            animateItems(items, cooldownFirst, frame)
        end
    end
end

---Each export's start: the memos emptied, the animations collected, the world map's canvas marked
function scene.beginExport()
    -- The game's world map canvas (with the whole interface), marked as the stand-in's is
    local map = G.WorldMapFrame
    local canvas = type(map) == "table" and type(map.ScrollContainer) == "table" and map.ScrollContainer.Child
    if canvas and S[canvas] and not S[canvas].isMapCanvas then
        S[canvas].isMapCanvas = true
        sim.markChanged(canvas)
        for _, child in ipairs(S[canvas].children or {}) do
            sim.markChanged(child)
        end
    end
    clearExportMemos()
    isAnimating = animation.collect()
    return isAnimating
end

---A region's items made anew (the native walk's request): its owner's alpha, rectangle and clip worked out here
function scene.buildRegion(items, region)
    local rs = S[region]
    local frame = rs and rs.parent
    local fs = frame and S[frame]
    if not fs then
        return
    end
    local rect = W.computeRect(frame)
    if not rect then
        return
    end
    local alpha, clip = exportAlpha(frame), exportClip(frame)
    local isFlattened = fs.flattensRenderLayers and alpha < 0.999
    local regionAlpha = (isFlattened and 1 or alpha) * ownAlpha(region, rs)
    makeRegionItems(items, region, rs, frame, fs, alpha, rect, clip, regionAlpha, isFlattened)
end

---A frame's items before its regions made anew (its backdrop, a message frame's lines)
function scene.buildBefore(items, frame)
    local fs = S[frame]
    local rect = fs and W.computeRect(frame)
    if not rect then
        return
    end
    local alpha, clip = exportAlpha(frame), exportClip(frame)
    local frameFirst = #items + 1
    if fs.backdrop then
        makeBackdrop(items, fs, rect, alpha, clip)
    end
    if fs.messages and fs.isChat == nil and #fs.messages > 0 then
        exportMessageFrame(items, frame, fs, rect, alpha, clip)
    end
    if isAnimating and #items >= frameFirst then
        animateItems(items, frameFirst, frame)
    end
end

---A frame's items after its regions made anew (units, a cooldown)
function scene.buildAfter(items, frame)
    local fs = S[frame]
    local rect = fs and W.computeRect(frame)
    if not rect then
        return
    end
    makeFrameAfter(items, frame, fs, rect, exportAlpha(frame), exportClip(frame))
end

local function buildScene()
    local items = {}
    -- (children drawn at their parent's level are drawn with it, below)
    for key in pairs(drawnWithParent) do
        drawnWithParent[key] = nil
    end
    scene.beginExport()
    -- Frames are drawn a level at a time, as the client draws them: the frames that share a strata, a level and a raise
    -- have their regions drawn together, by layer (every BACKGROUND, then every BORDER...), the frames' order only
    -- deciding within a layer. EllesmereUI's game menu buttons hold a frame of their own level whose dark BACKGROUND
    -- lies behind the button's text: drawn frame after frame, it covered the text and greyed it.
    local frames = scene.getSortedFrames()
    local groupFirst = 1
    while groupFirst <= #frames do
        local first = frames[groupFirst]
        local groupLast = groupFirst
        while true do
            local nextFrame = frames[groupLast + 1]
            if
                not nextFrame
                or sortedStratas[nextFrame] ~= sortedStratas[first]
                or sortedLevels[nextFrame] ~= sortedLevels[first]
                or sortedRaises[nextFrame] ~= sortedRaises[first]
            then
                break
            end
            groupLast = groupLast + 1
        end
        -- Each frame's own drawing that is not a region (a backdrop, a message frame's lines), then every region of
        -- the level in one order, then what is drawn over a frame's regions (a cooldown's swipe, a map's units)
        local previousCount = gatheredCount
        gatheredCount, ownerCount = 0, 0
        local groupState
        for position = groupFirst, groupLast do
            local frame = frames[position]
            local fs = S[frame]
            local rect = W.computeRect(frame)
            local alpha = exportAlpha(frame)
            if rect and alpha > 0.002 then
                local clip = exportClip(frame)
                local frameFirst = #items + 1
                -- (its backdrop kept while it, its place, alpha and clip stand)
                local isBackdropKept = false
                if fs.backdrop and isKeeping and not (isAnimating and transformOf(frame)) then
                    stampCount, placeCount, placeMaskCount = 0, 0, 0
                    put(fs.visualVersion or 0)
                    putSize(rect)
                    put(alpha)
                    putRelative(clip, rect)
                    put(sim.screenHeight)
                    putPlaceRect(rect)
                    putPlaceRect(clip)
                    local kept = compareKept(fs.keptBackdrop, true)
                    if kept then
                        if kept == "moved" then
                            moveKept(fs.keptBackdrop)
                        end
                        putKeptItems(items, fs.keptBackdrop)
                        isBackdropKept = true
                    end
                end
                if fs.backdrop and not isBackdropKept then
                    local backdropFirst = #items + 1
                    makeBackdrop(items, fs, rect, alpha, clip)
                    if isKeeping and not (isAnimating and transformOf(frame)) then
                        keepItems(fs, "keptBackdrop", items, backdropFirst)
                    end
                end
                if fs.messages and fs.isChat == nil and #fs.messages > 0 then
                    exportMessageFrame(items, frame, fs, rect, alpha, clip)
                end
                if isAnimating and #items >= frameFirst then
                    animateItems(items, frameFirst, frame)
                end

                -- Its regions, and those of its children drawn at its level (useParentLevel: a tooltip's NineSlice).
                -- Such a child, met later in the frames' order, has nothing more to draw.
                if not drawnWithParent[frame] then
                    drawnWithParent[frame] = true -- (its own turn taken: a parent met later does not draw it again)
                    gather(frame, fs, alpha, rect, clip, math.min(1000, (position - groupFirst) * 8))
                    groupState = groupState or fs
                end
            end
        end
        for index = gatheredCount + 1, previousCount do
            gathered[index] = nil
        end
        if gatheredCount > 1 and groupState then
            sortGathered(groupState)
        end
        for regionIndex = 1, gatheredCount do
            local region = gathered[regionIndex]
            local owner = ownerOf[region]
            local frame, fs, alpha, rect, clip = owner.frame, owner.fs, owner.alpha, owner.rect, owner.clip
            local rs = S[region]
            local isShown = not rs.role or isRoleShown(frame, rs.role)
            if rs.layer == "HIGHLIGHT" and not rs.role then
                isShown = sim.motionFocus == frame or fs.highlightLocked == true
            end
            local isFlattened = isShown and fs.flattensRenderLayers and alpha < 0.999
            local regionAlpha = isShown and (isFlattened and 1 or alpha) * ownAlpha(region, rs)
            local isStamped, canMove = false, false
            if isShown and isKeeping then
                isStamped, canMove = stampRegion(region, rs, frame, fs, rect, regionAlpha, clip, isFlattened, alpha)
            end
            local kept = isStamped and compareKept(rs.keptItems, canMove)
            if kept then
                if kept == "moved" then
                    moveKept(rs.keptItems)
                end
                putKeptItems(items, rs.keptItems)
            elseif isShown then
                local regionFirst =
                    makeRegionItems(items, region, rs, frame, fs, alpha, rect, clip, regionAlpha, isFlattened)
                if isStamped then
                    keepItems(rs, "keptItems", items, regionFirst)
                end
            end
        end

        for position = groupFirst, groupLast do
            local frame = frames[position]
            local fs = S[frame]
            local rect = W.computeRect(frame)
            local alpha = exportAlpha(frame)
            if rect and alpha > 0.002 then
                makeFrameAfter(items, frame, fs, rect, alpha, exportClip(frame))
            end
        end
        groupFirst = groupLast + 1
    end
    return items
end

-- Input
local function contains(rect, x, y, insets)
    if not rect then
        return false
    end
    insets = insets or { 0, 0, 0, 0 }
    return x >= rect[1] + insets[1]
        and x <= rect[3] - insets[2]
        and y >= rect[2] + insets[4]
        and y <= rect[4] - insets[3]
end

local function isInsideClip(frame, x, y)
    local clip = getClip(frame)
    return not clip or (x >= clip[1] and x <= clip[3] and y >= clip[2] and y <= clip[4])
end

---The topmost frame under the point that takes this kind of mouse input.
function scene.findFrameAt(x, y, kind)
    local frames = scene.getSortedFrames()
    for index = #frames, 1, -1 do
        local frame = frames[index]
        local s = S[frame]
        local isTaking
        if kind == "wheel" then
            isTaking = s.mouseWheel == true
        elseif kind == "motion" then
            isTaking = W.takesMotion(s)
        else
            isTaking = W.takesClicks(s)
        end
        if
            isTaking
            and getAlpha(frame) > 0.002
            and contains(W.computeRect(frame), x, y, s.hitInsets)
            and isInsideClip(frame, x, y)
        then
            return frame
        end
    end
end

local function setMotionFocus(frame)
    local old = sim.motionFocus
    if old == frame then
        return
    end
    sim.motionFocus = frame
    sim.touchVisual()
    local function canMove(target)
        local s = S[target]
        return s and (s.enabled ~= false or s.motionWhileDisabled or not W.types[s.type].chain.Button)
    end
    if old and canMove(old) then
        sim.runScript(old, "OnLeave", true)
    end
    if frame and canMove(frame) then
        sim.runScript(frame, "OnEnter", true)
    end
end

local moving
function W.startMoving(frame)
    local rect = W.computeRect(frame)
    local mouse = sim.mouse or { x = 0, y = 0 }
    if rect then
        moving = { frame = frame, dx = mouse.x - rect[1], dy = mouse.y - rect[4] }
    end
end
function W.stopMoving()
    moving = nil
end

function W.setFocus(editBox)
    local old = W.focus
    if old == editBox then
        return
    end
    W.focus = editBox
    sim.touchVisual() -- (the edit box's cursor: nothing moves)
    if old then
        sim.runScript(old, "OnEditFocusLost")
    end
    if editBox then
        sim.runScript(editBox, "OnEditFocusGained")
    end
end

function W.clickButton(button, mouseButton, isDown)
    local s = S[button]
    if s.enabled == false then
        return
    end
    -- (the click's mouse button, while its scripts run: IsModifiedClick's "SHIFT-BUTTON1" asks which it is)
    local outerButton = sim.clickingButton
    sim.clickingButton = mouseButton
    sim.runScript(button, "PreClick", mouseButton, isDown or false)
    if s.type == "CheckButton" then
        s.checked = not s.checked
        sim.touchVisual(button)
    end
    sim.runScript(button, "OnClick", mouseButton, isDown or false)
    sim.runScript(button, "PostClick", mouseButton, isDown or false)
    sim.clickingButton = outerButton
end

local function sliderValueAt(slider, x, y)
    local s = S[slider]
    local rect = W.computeRect(slider)
    if not rect then
        return
    end
    local minimum, maximum = s.minValue or 0, s.maxValue or 1
    local fraction
    if W.orientationOf(slider) == "VERTICAL" then
        fraction = (rect[4] - y) / math.max(rect[4] - rect[2], 1)
    else
        fraction = (x - rect[1]) / math.max(rect[3] - rect[1], 1)
    end
    W.setBarValue(slider, minimum + math.max(0, math.min(1, fraction)) * (maximum - minimum))
end

function scene.input(event)
    -- The page's report on a sound it played: it ended (lua/sound.lua)
    if event.type == "soundEnded" then
        require("sound").ended(event.h)
        return
    end
    local x, y = event.x and event.x or 0, event.y and (sim.screenHeight - event.y) or 0
    if event.mods then
        sim.modifiers.shift, sim.modifiers.ctrl, sim.modifiers.alt =
            event.mods.shift == true, event.mods.ctrl == true, event.mods.alt == true
    end
    -- A press or release where the cursor has not been yet: in the client the cursor got there over frames first, so
    -- a frame following the cursor in OnUpdate (the map's scroll container, panning while the button is held) sees it
    -- move with the button still down. The page can send a quick drag's release right after its last move.
    if
        (event.type == "down" or event.type == "up")
        and sim.mouse
        and (math.abs(sim.mouse.x - x) > 0.5 or math.abs(sim.mouse.y - y) > 0.5)
    then
        scene.input({ type = "move", x = event.x, y = event.y })
        sim.tick(1 / 60)
    end
    if event.type == "move" then
        sim.mouse = { x = x, y = y }
        if moving then
            local frame = moving.frame
            local scale = W.getEffectiveScale(frame)
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", G.UIParent, "BOTTOMLEFT", (x - moving.dx) / scale, (y - moving.dy) / scale)
        end
        local down = sim.mouseDown
        if down and down.frame then
            if S[down.frame].type == "Slider" and S[down.frame].enabled ~= false then
                sliderValueAt(down.frame, x, y)
            end
            if
                not down.isDragging
                and S[down.frame].dragButtons
                and (math.abs(x - down.x) > 4 or math.abs(y - down.y) > 4)
            then
                -- (in any case, as the client: "LeftButton", "leftbutton", "AnyUp", "LeftButtonUp")
                local pressed = tostring(down.button):lower()
                for _, registered in ipairs(S[down.frame].dragButtons) do
                    local button = tostring(registered):lower()
                    if
                        button == pressed
                        or button == "anyup"
                        or button == "any"
                        or button == pressed .. "up"
                        or button == pressed .. "down"
                    then
                        down.isDragging = true
                        sim.runScript(down.frame, "OnDragStart", down.button)
                        break
                    end
                end
            end
        end
        local motionFrame = scene.findFrameAt(x, y, "motion")
        setMotionFocus(motionFrame)
        -- Over the world (no frame under the cursor): what stands there becomes the mouseover (lua/combat.lua)
        if sim.onWorldHover then
            sim.onWorldHover(x, y, motionFrame == nil or motionFrame == G.WorldFrame)
        end
    elseif event.type == "down" then
        sim.mouse = { x = x, y = y }
        -- Every press, wherever it lands (the world too), before the frame under it: the game's menus close on one
        -- outside them (Blizzard_Menu's Menu.lua listens for it)
        sim.fireEvent("GLOBAL_MOUSE_DOWN", event.button or "LeftButton")
        if sim.clickToWalk and scene.walkToPoint(x, y) then
            return
        end
        -- Edit Mode: a press on the minimap picks it up to drag, as the game's Edit Mode does
        local cluster = sim.editMode and G.MinimapCluster
        local clusterRect = cluster and W.computeRect(cluster)
        if
            clusterRect
            and x >= clusterRect[1]
            and x <= clusterRect[3]
            and y >= clusterRect[2]
            and y <= clusterRect[4]
        then
            sim.editDrag = cluster
            W.startMoving(cluster)
            return
        end
        local button = event.button or "LeftButton"
        local frame = scene.findFrameAt(x, y, "click")
        -- A press on the world: a creature's nameplate there is targeted (lua/combat.lua), as the client's world does
        if (frame == nil or frame == G.WorldFrame) and sim.onWorldClick and sim.onWorldClick(x, y, button) then
            return
        end
        sim.mouseDown = { frame = frame, button = button, x = x, y = y }
        if frame and W.types[S[frame].type].chain.EditBox then
            W.setFocus(frame)
        elseif W.focus then
            W.setFocus(nil)
        end
        if not frame or not (frame == G.UIParent) then
            -- A click outside an open menu closes it
            local ui = require("ui")
            if
                ui.closeMenu
                and frame
                and not (S[frame].parent and S[S[frame].parent] and S[S[frame].parent].strata == "FULLSCREEN_DIALOG")
            then
                if not (frame and S[frame].menuGenerator) then
                    ui.closeMenu()
                end
            elseif not frame then
                ui.closeMenu()
            end
        end
        if frame then
            W.raiseToplevelOf(frame)
            sim.runScript(frame, "OnMouseDown", button)
            if S[frame].type == "Slider" and S[frame].enabled ~= false then
                sliderValueAt(frame, x, y)
            end
            -- A button registered for the press clicks on it (down = true), as in the client: the game's secure action
            -- buttons act on the press when ActionButtonUseKeyDown is on
            if W.types[S[frame].type].chain.Button then
                if W.isClickRegistered(S[frame], button, "Down") then
                    sim.mouseDown.clickedOnPress = true
                    W.clickButton(frame, button, true)
                end
            end
            sim.touchVisual() -- (a press: the pushed textures; nothing moves)
        end
    elseif event.type == "up" then
        sim.mouse = { x = x, y = y }
        sim.fireEvent("GLOBAL_MOUSE_UP", event.button or "LeftButton")
        if sim.editDrag then
            -- Put down where it was dropped, kept wholly on screen
            local dragged = sim.editDrag
            -- Where it was let go, even if the last move never arrived
            if moving and moving.frame == dragged then
                local scale = W.getEffectiveScale(dragged)
                dragged:ClearAllPoints()
                dragged:SetPoint("TOPLEFT", G.UIParent, "BOTTOMLEFT", (x - moving.dx) / scale, (y - moving.dy) / scale)
            end
            sim.editDrag, moving = nil, nil
            local rect = W.computeRect(dragged)
            if rect then
                local scale = W.getEffectiveScale(dragged)
                local left = math.max(0, math.min(rect[1], sim.screenWidth - (rect[3] - rect[1])))
                local top = math.max(rect[4] - rect[2], math.min(rect[4], sim.screenHeight))
                dragged:ClearAllPoints()
                dragged:SetPoint("TOPLEFT", G.UIParent, "BOTTOMLEFT", left / scale, top / scale)
            end
            -- The game's Edit Mode keeps the minimap's new place in the player's own layout and places it from there;
            -- then every addon hears of the layouts (with them, as the game sends the event)
            if dragged == G.MinimapCluster and rect and sim.keepEditModePlace and G.Enum and G.Enum.EditModeSystem then
                local scale = W.getEffectiveScale(dragged)
                local left = math.max(0, math.min(rect[1], sim.screenWidth - (rect[3] - rect[1])))
                local top = math.max(rect[4] - rect[2], math.min(rect[4], sim.screenHeight))
                sim.keepEditModePlace(G.Enum.EditModeSystem.Minimap, "TOPLEFT", "BOTTOMLEFT", left / scale, top / scale)
            end
            sim.fireEvent("EDIT_MODE_LAYOUTS_UPDATED", G.C_EditMode.GetLayouts(), false)
            return
        end
        local button = event.button or "LeftButton"
        local down = sim.mouseDown
        sim.mouseDown = nil
        local frame = scene.findFrameAt(x, y, "click")
        if down and down.isDragging and down.frame then
            sim.runScript(down.frame, "OnDragStop")
        end
        moving = nil
        if down and down.frame then
            sim.runScript(down.frame, "OnMouseUp", button, frame == down.frame)
        end
        if frame and down and frame == down.frame and not down.isDragging then
            local s = S[frame]
            if W.types[s.type].chain.Button then
                -- On the release for a button registered for it (left-button-up when it registered nothing), as in
                -- the client; a button registered for both clicks twice, the press and the release
                if W.isClickRegistered(s, button, "Up") then
                    W.clickButton(frame, button, false)
                end
            end
        end
        sim.touchVisual()
    elseif event.type == "wheel" then
        local frame = scene.findFrameAt(x, y, "wheel")
        if frame then
            sim.runScript(frame, "OnMouseWheel", event.delta or 0)
        end
    elseif event.type == "key" then
        if event.isHeld then
            sim.heldKeys = sim.heldKeys or {}
            sim.heldKeys[(event.key or ""):upper()] = true
        end
        scene.key(event.key or "", event.text, event.isHeld == true)
    elseif event.type == "keyup" then
        -- A held key let go: a movement stops; a binding run on the release too (runOnUp) runs with keystate "up"
        local key = (event.key or ""):upper()
        if sim.heldKeys then
            sim.heldKeys[key] = nil
        end
        local command = sim.overrideBindings[key] and sim.overrideBindings[key].command or sim.bindings[key]
        scene.releaseCommand(command, key)
    elseif event.type == "pad" then
        -- A gamepad's button (the page reads the browser's controller): PAD1, PADDUP...
        local gamepad = require("gamepad")
        if event.isDown then
            gamepad.press(event.button or "")
        else
            gamepad.release(event.button or "")
        end
    elseif event.type == "padStick" then
        require("gamepad").setStick(event.stick, event.x, event.y)
    elseif event.type == "padConnected" then
        if event.isConnected then
            require("gamepad").connect(event.name)
        else
            require("gamepad").disconnect()
        end
    elseif event.type == "releaseAll" then
        sim.heldKeys = {}
        require("movement").releaseAll()
    elseif event.type == "text" then
        if W.focus then
            local editBox = W.focus
            W.setEditText(editBox, (S[editBox].text or "") .. (event.text or ""), true)
            sim.runScript(editBox, "OnChar", event.text)
        end
    end
end

local function runBindingCommand(command, isHeld)
    if not command or command == "" then
        return false
    end
    -- A click binding (SetBindingClick; the gamepad's menus set them on its keys): as in the client, the press clicks
    -- a button registered for down-clicks ("AnyDown"), with down true; its up-click comes as the key comes up
    -- (releaseCommand)
    local frameName, button = command:match("^CLICK%s+([^:]+):?(.*)$")
    if frameName then
        local frame = G[frameName]
        if not (frame and frame.Click and S[frame]) then
            return false
        end
        button = button ~= "" and button or "LeftButton"
        if W.isClickRegistered(S[frame], button, "Down") then
            W.clickButton(frame, button, true)
        end
        return true
    end
    local movement = require("movement")
    -- Held (the page sends key down and up): the character moves until the key comes up, at the game's speeds
    if isHeld and movement.isMovementCommand(command) then
        movement.press(command)
        return true
    end
    if command == "TOGGLEAUTORUN" then
        movement.toggleAutoRun()
        return true
    end
    if command == "TOGGLERUN" then
        movement.setWalking(not movement.describe().isWalking)
        return true
    end
    -- A single press (a scenario's key("W")) moves a step (yards) or turns a little
    local game = require("game")
    local STEP, TURN = 8, math.rad(15)
    local stepCommands = {
        MOVEFORWARD = function()
            game.walk(STEP, 0)
        end,
        MOVEBACKWARD = function()
            game.walk(-STEP / 2, 0)
        end,
        TURNLEFT = function()
            game.turn(TURN)
        end,
        TURNRIGHT = function()
            game.turn(-TURN)
        end,
        STRAFELEFT = function()
            game.walk(0, -STEP)
        end,
        STRAFERIGHT = function()
            game.walk(0, STEP)
        end,
    }
    if stepCommands[command] then
        stepCommands[command]()
        return true
    end
    -- The game's own binding (its Bindings XML, read with the whole interface): its Lua, run as the client runs a
    -- key's command, securely, with keystate "down"
    local binding = sim.bindingCode and sim.bindingCode[command]
    if binding then
        sim.runSecurely(binding, "down")
        return true
    end
    local handlers = {
        OPENCHAT = function()
            G.ChatFrame_OpenChat("")
        end,
        TOGGLEWORLDMAP = G.ToggleWorldMap,
        TOGGLEQUESTLOG = G.ToggleQuestLog,
        TOGGLEGAMEMENU = function()
            local ui = require("ui")
            if ui.closeMenu then
                ui.closeMenu()
            end
            G.CloseSpecialWindows()
        end,
    }
    if handlers[command] then
        sim.call(handlers[command])
        return true
    end
    return false
end

---Runs a key's command as the client does on its press (a pad button's too).
---@return boolean isRun
function scene.runCommand(command, isHeld)
    return runBindingCommand(command, isHeld)
end

---A key's command as its key comes up: a held movement stops; a binding the game runs on the release too
---(runOnUp="true": the gamepad's action buttons and modifiers) runs again with keystate "up".
function scene.releaseCommand(command)
    if not command or command == "" then
        return
    end
    local frameName, button = command:match("^CLICK%s+([^:]+):?(.*)$")
    if frameName then
        local frame = G[frameName]
        if not (frame and frame.Click and S[frame]) then
            return
        end
        button = button ~= "" and button or "LeftButton"
        if W.isClickRegistered(S[frame], button, "Up") then
            W.clickButton(frame, button, false)
        end
        return
    end
    require("movement").release(command)
    local binding = sim.bindingCode and sim.bindingCode[command]
    if binding and sim.bindingRunsOnUp and sim.bindingRunsOnUp[command] then
        sim.runSecurely(binding, "up")
    end
end

---Click to walk: a click on the minimap or the world map's canvas sends the character there.
---@return boolean isWalking The click was on one of them
function scene.walkToPoint(x, y)
    local game, movement = require("game"), require("movement")
    local minimap = G.Minimap
    local rect = minimap and minimap:IsVisible() and W.computeRect(minimap)
    if rect and contains(rect, x, y) then
        local radius = (rect[3] - rect[1]) / 2
        local right = (x - (rect[1] + rect[3]) / 2) / radius
        local up = (y - (rect[2] + rect[4]) / 2) / radius
        if right * right + up * up <= 1 then
            local continentId, north, west = game.getPlayerWorldPosition()
            if not continentId then
                return true
            end
            local viewRadius = G.C_Minimap.GetViewRadius()
            if G.GetCVar("rotateMinimap") == "1" then
                -- The land is turned by the facing: turn the click back
                local facing = game.profile.facing or 0
                local sine, cosine = math.sin(facing), math.cos(facing)
                right, up = right * cosine - up * sine, right * sine + up * cosine
            end
            movement.walkToWorld(continentId, north + up * viewRadius, west - right * viewRadius)
            return true
        end
    end
    local map = G.WorldMapFrame
    local canvas = map and map:IsVisible() and map.ScrollContainer and map.ScrollContainer.Child
    local container = canvas and W.computeRect(map.ScrollContainer)
    local canvasRect = canvas and W.computeRect(canvas)
    if container and canvasRect and contains(container, x, y) then
        local mapX = (x - canvasRect[1]) / (canvasRect[3] - canvasRect[1])
        local mapY = (canvasRect[4] - y) / (canvasRect[4] - canvasRect[2])
        local isSent, problem = movement.walkTo(map:GetMapID(), mapX, mapY)
        if not isSent then
            sim.call(
                G.UIErrorsFrame and G.UIErrorsFrame.AddMessage or function() end,
                G.UIErrorsFrame,
                problem,
                1,
                0.1,
                0.1
            )
        end
        return true
    end
    return false
end

function scene.key(key, text, isHeld)
    key = key:upper()
    local editBox = W.focus
    if editBox then
        local s = S[editBox]
        if key == "ENTER" then
            if s.scripts.OnEnterPressed then
                sim.runScript(editBox, "OnEnterPressed")
            elseif not s.multiLine then
                W.setFocus(nil)
            end
            if s.multiLine and not s.scripts.OnEnterPressed then
                W.setEditText(editBox, (s.text or "") .. "\n", true)
            end
        elseif key == "ESCAPE" then
            if s.scripts.OnEscapePressed then
                sim.runScript(editBox, "OnEscapePressed")
            else
                W.setFocus(nil)
            end
        elseif key == "TAB" then
            sim.runScript(editBox, "OnTabPressed")
        elseif key == "BACKSPACE" then
            local value = s.text or ""
            W.setEditText(editBox, value:sub(1, #value - 1), true)
        elseif text and text ~= "" then
            W.setEditText(editBox, (s.text or "") .. text, true)
            sim.runScript(editBox, "OnChar", text)
        end
        return
    end
    -- Frames listening to the keyboard first, then the bindings
    local frames = scene.getSortedFrames()
    for index = #frames, 1, -1 do
        local frame = frames[index]
        if S[frame].keyboard and S[frame].scripts.OnKeyDown then
            sim.runScript(frame, "OnKeyDown", key)
            if not S[frame].propagateKeyboard then
                return
            end
        end
    end
    local override = sim.overrideBindings[key]
    if override and runBindingCommand(override.command, isHeld) then
        return
    end
    if key == "ESCAPE" then
        runBindingCommand("TOGGLEGAMEMENU")
        return
    end
    runBindingCommand(sim.bindings[key], isHeld)
end

---Every frame under a point, top first, for the inspector.
---@return string label A frame as the game's frame stack names it: its name, else the key its parent keeps it under
---(PlayerFrame.PlayerFrameContent), else its type and number
function scene.frameLabel(object, depth)
    local state = object and S[object]
    if not state then
        return tostring(object)
    end
    if state.name then
        return state.name
    end
    local parent = state.parent
    if type(parent) == "table" and (depth or 0) < 12 then
        for key, value in pairs(parent) do
            if value == object and type(key) == "string" then
                return scene.frameLabel(parent, (depth or 0) + 1) .. "." .. key
            end
        end
    end
    return "<" .. state.type .. " #" .. state.id .. ">"
end

---@return boolean isDrawing The frame draws something of its own: a shown texture with art or colour, or text
local function drawsSomething(frame)
    for _, region in ipairs(S[frame].regions or {}) do
        local rs = S[region]
        if rs and rs.shown and rs.type ~= "MaskTexture" then
            if rs.type == "FontString" then
                if rs.text and rs.text ~= "" then
                    return true
                end
            elseif rs.texture or rs.atlas or rs.color or rs.gradient then
                return true
            end
        end
    end
    return false
end

---@param isDrawnOnly boolean? Leave out the frames that neither draw anything nor take the mouse (the full-screen
---containers and model scenes over everything)
function scene.inspect(x, y, isDrawnOnly)
    y = sim.screenHeight - y
    local results = {}
    local frames = scene.getSortedFrames()
    for index = #frames, 1, -1 do
        local frame = frames[index]
        local rect = W.computeRect(frame)
        if
            contains(rect, x, y)
            and isInsideClip(frame, x, y)
            and (not isDrawnOnly or S[frame].mouse or drawsSomething(frame))
        then
            local s = S[frame]
            local bx, by, bw, bh = toBox(rect)
            results[#results + 1] = {
                id = s.id,
                creator = s.creator,
                name = scene.frameLabel(frame),
                type = s.type,
                strata = W.getStrata(frame),
                level = s.level,
                mouse = s.mouse == true,
                x = bx,
                y = by,
                w = bw,
                h = bh,
            }
            if #results >= 20 then
                break
            end
        end
    end
    return results
end

---The highest level a shown frame of a strata is drawn at, those in except left out (Raise: one above it)
function scene.highestDrawLevel(strata, except)
    local frames = scene.getSortedFrames()
    local rank = W.STRATA_RANK[strata] or 4
    local highest = 0
    for _, frame in ipairs(frames) do
        if sortedStratas[frame] == rank and not except[frame] and not S[frame].isRoot then
            local level = sortedLevels[frame] or 0
            if level > highest then
                highest = level
            end
        end
    end
    return highest
end

-- The kept items checked (ADDONSIM_CHECK_SCENE=1): two items the same, but for the stream's mark on a second item of
-- one key (an id's "#2", which a kept item carries on)
local function baseId(id)
    return type(id) == "string" and id:gsub("#%d+$", "") or id
end
local function isSameValue(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        if not isSameValue(value, b[key]) then
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
local function describe(value)
    if type(value) ~= "table" then
        return tostring(value)
    end
    local parts = {}
    for key, inner in pairs(value) do
        parts[#parts + 1] = tostring(key) .. "=" .. describe(inner)
        if #parts >= 8 then
            break
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function differenceOf(kept, made)
    for key, value in pairs(made) do
        local other = kept[key]
        if key == "i" then
            other, value = baseId(other), baseId(value)
        end
        if not isSameValue(value, other) then
            return key
        end
    end
    for key in pairs(kept) do
        if made[key] == nil then
            return key
        end
    end
end
local reportedKeys = {}
local function checkKept(items)
    isKeeping = false
    local made = buildScene()
    isKeeping = true
    local problem
    if #made ~= #items then
        problem = "the scene has " .. #items .. " items with kept ones, " .. #made .. " made anew"
    end
    for index = 1, math.max(#items, #made) do
        local kept, fresh = items[index], made[index]
        if not kept or not fresh then
            break
        end
        local field = differenceOf(kept, fresh)
        if field then
            problem = string.format(
                "item %d (%s%s) differs in %s: kept %s, made anew %s",
                index,
                tostring(fresh.k),
                tostring(fresh.i),
                field,
                describe(kept[field]),
                describe(fresh[field])
            )
            break
        end
    end
    if problem then
        local key = problem:gsub("%d+%.?%d*", "#")
        if not reportedKeys[key] then
            reportedKeys[key] = true
            sim.reportError("Kept scene items out of date: " .. problem, debug.traceback("", 2))
        end
    end
    return made
end

-- The native walk checked the same way (lua/scenesync.lua): the scene it made, read back from the store, and the one
-- made anew here, compared item by item (numbers to the four places the packed items keep)
local function isClose(a, b)
    if a == b then
        return true
    end
    if type(a) == "number" and type(b) == "number" then
        return math.abs(a - b) < 0.0002
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for key, value in pairs(a) do
        if not isClose(value, b[key]) then
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
local function checkNative(made)
    local scenesync = require("scenesync")
    if not scenesync.isAvailable() then
        return
    end
    scenesync.frame()
    local walked = require("unpack").whole(require("stream").encodeWholeBinary())
    local problem = scenesync.checkLayout()
    if problem then
        problem = "its layout differs: " .. problem
    end
    if not problem and #walked ~= #made then
        problem = "the native walk made " .. #walked .. " items, the export " .. #made
    end
    for index = 1, math.max(#walked, #made) do
        local native, fresh = walked[index], made[index]
        if problem or not native or not fresh then
            break
        end
        local field
        for key, value in pairs(fresh) do
            local other = native[key]
            if key == "i" then
                value, other = baseId(value), baseId(other)
            end
            if not isClose(value, other) then
                field = key
                break
            end
        end
        if not field then
            for key in pairs(native) do
                if fresh[key] == nil then
                    field = key
                    break
                end
            end
        end
        if field then
            problem = string.format(
                "item %d (%s%s) differs in %s: walked %s, exported %s",
                index,
                tostring(fresh.k),
                tostring(fresh.i),
                field,
                describe(native[field]),
                describe(fresh[field])
            )
            break
        end
    end
    if problem then
        local key = problem:gsub("%d+%.?%d*", "#")
        if not reportedKeys[key] then
            reportedKeys[key] = true
            sim.reportError("The native walk's scene differs: " .. problem, debug.traceback("", 2))
        end
    end
end

---Every visible frame and region in drawing order, as the page draws them
function scene.export()
    local items = buildScene()
    if isChecking then
        checkNative(checkKept(items))
    end
    return items
end
if isChecking then
    local tick = sim.tick
    sim.tick = function(...)
        local results = { tick(...) }
        scene.export()
        return unpack(results, 1, table.maxn(results))
    end
end

return scene
