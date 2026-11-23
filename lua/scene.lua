-- The picture and the hands: every visible frame and region in draw order as a flat list for the page, and
-- the mouse and keyboard turned into the scripts the game would run (OnEnter, OnClick, OnMouseWheel, ...).
local sim = require("sim")
local W = require("widgets")
local fonts = require("fonts")

local scene = {}
local S = W.state
local G = sim.G

local function round(value) return math.floor(value * 10 + 0.5) / 10 end

local function getAlpha(object)
    local alpha, current = 1, object
    while current and S[current] do
        alpha = alpha * (S[current].alpha or 1)
        if S[current].ignoreParentAlpha or S[current].isRoot then break end
        current = S[current].parent
    end
    return alpha
end

---A clip cut down to a frame's rectangle (or the frame's rectangle, with no clip yet)
local function clipTo(clip, frame)
    local rect = W.computeRect(frame)
    if not rect then return clip end
    if not clip then return { rect[1], rect[2], rect[3], rect[4] } end
    return { math.max(clip[1], rect[1]), math.max(clip[2], rect[2]), math.min(clip[3], rect[3]), math.min(clip[4], rect[4]) }
end

---The rectangle a frame's drawing is clipped to: every clipping ancestor's, intersected. A scroll frame clips only
---its scroll child (as the client: the quest log's search box, its child above the list, shows); a frame that clips
---its children (SetClipsChildren) clips them all.
local function getClip(frame)
    local clip
    local node = frame
    while node and S[node] do
        local s = S[node]
        if node ~= frame and s.clips then clip = clipTo(clip, node) end
        if s.scrollChildOf and S[s.scrollChildOf] then clip = clipTo(clip, s.scrollChildOf) end
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
    if known then return known end
    local s = S[object]
    if not s then return 1 end
    local alpha = s.alpha or 1
    if not (s.ignoreParentAlpha or s.isRoot) and s.parent and S[s.parent] then alpha = alpha * exportAlpha(s.parent) end
    alphaMemo[object] = alpha
    return alpha
end
local exportClip
-- The clip a frame puts on what it holds: its own rectangle if it clips, within the clip it is in
local function insideClip(frame)
    local known = insideClipMemo[frame]
    if known then return known ~= NO_CLIP and known or nil end
    local clip = exportClip(frame)
    if S[frame].clips then clip = clipTo(clip, frame) end
    insideClipMemo[frame] = clip or NO_CLIP
    return clip
end
exportClip = function(frame)
    local known = clipMemo[frame]
    if known then return known ~= NO_CLIP and known or nil end
    local s = S[frame]
    local parent = s and s.parent
    local clip = parent and S[parent] and insideClip(parent) or nil
    -- (a scroll child: cut to its scroll frame, which clips only it)
    if s and s.scrollChildOf and S[s.scrollChildOf] then clip = clipTo(clip, s.scrollChildOf) end
    clipMemo[frame] = clip or NO_CLIP
    return clip
end
local function clearExportMemos()
    for key in pairs(alphaMemo) do alphaMemo[key] = nil end
    for key in pairs(clipMemo) do clipMemo[key] = nil end
    for key in pairs(insideClipMemo) do insideClipMemo[key] = nil end
end

-- Each edge snapped to the pixel, as the game draws, and the size from the snapped edges: two rectangles that share an
-- edge then meet exactly (rounding the size apart from the position left one-pixel seams between rows of strips)
local function toBox(rect)
    local left, right = round(rect[1]), round(rect[3])
    local top, bottom = round(sim.screenHeight - rect[4]), round(sim.screenHeight - rect[2])
    return left, top, right - left, bottom - top
end

-- A raised frame (Raise, a toplevel one shown or clicked) goes to the front of its strata with everything in it, as
-- the client lifts its frame levels: the nearest raised frame from this one up, in the same strata, counts
local function getRaised(frame, strata)
    local current, depth = frame, 0
    while current and depth < 60 do
        local state = S[current]
        if not state or state.isRoot then return 0 end
        if state.raised and W.getStrata(current) == strata then return state.raised end
        current, depth = state.parent, depth + 1
    end
    return 0
end

local function frameOrder(frame)
    local s = S[frame]
    local strata = W.getStrata(frame)
    return W.STRATA_RANK[strata] or 4, s.level or 0, getRaised(frame, strata), s.id
end

-- The shown frames in drawing order, kept until anything changes (sim.version): the mouse moving, a click and a key
-- between two frames of the game's clock ask for it again and again. Each frame's visibility is worked out once (its
-- parent's answer reused), and its place in the order once, not at every comparison of the sort. Read only: callers
-- go through it, none changes it.
-- (kept while the order stands, W.touchOrder; made again at least every quarter of a game second all the same, in
-- case something changed the order by a way not told)
local sortedFrames, sortedVersion, sortedAt
-- The frames with no parent (or the screen itself): where the walk starts. Kept until a frame is made or moved to
-- another parent.
local roots, rootsFrameCount, rootsParentVersion
local function getRoots()
    if roots and rootsFrameCount == #W.frames and rootsParentVersion == sim.parentVersion then return roots end
    roots = {}
    for _, frame in ipairs(W.frames) do
        local state = S[frame]
        if state and (state.isRoot or not state.parent or not S[state.parent]) then roots[#roots + 1] = frame end
    end
    rootsFrameCount, rootsParentVersion = #W.frames, sim.parentVersion
    return roots
end
local ORDER_KEPT_SECONDS = 0.25
function scene.getSortedFrames()
    if sortedFrames and sortedVersion == sim.orderVersion and sim.now - sortedAt < ORDER_KEPT_SECONDS then return sortedFrames end
    -- Down from the top frames (no parent, or the screen's own) through the shown ones only: what is hidden, and all
    -- it holds, is never looked at (of 13 000 frames, a few hundred are shown)
    local roots = getRoots()
    local frames, stratas, levels, raises = {}, {}, {}, {}
    local function visit(frame, state)
        if not state.isRoot then
            frames[#frames + 1] = frame
            stratas[frame], levels[frame], raises[frame] = frameOrder(frame)
        end
        local children = state.children
        if children then
            for index = 1, #children do
                local child = children[index]
                local childState = S[child]
                if childState and childState.shown and childState.parent == frame then visit(child, childState) end
            end
        end
    end
    for index = 1, #roots do
        local frame = roots[index]
        local state = S[frame]
        if state and state.shown then visit(frame, state) end
    end
    table.sort(frames, function(first, second)
        local firstStrata, secondStrata = stratas[first], stratas[second]
        if firstStrata ~= secondStrata then return firstStrata < secondStrata end
        local firstLevel, secondLevel = levels[first], levels[second]
        if firstLevel ~= secondLevel then return firstLevel < secondLevel end
        -- (among frames of one level: the one raised last in front, as in the client)
        local firstRaised, secondRaised = raises[first], raises[second]
        if firstRaised ~= secondRaised then return firstRaised < secondRaised end
        return S[first].id < S[second].id
    end)
    sortedFrames, sortedVersion, sortedAt = frames, sim.orderVersion, sim.now
    return frames
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
            return round(cornerX / math.max(width, 0.01) * 1000) / 1000, round(cornerY / math.max(height, 0.01) * 1000) / 1000
        end
        local ulX, ulY = corner(1, 0, 0)
        local urX, urY = corner(3, 1, 0)
        local lrX, lrY = corner(4, 1, 1)
        local llX, llY = corner(2, 0, 1)
        item.poly = { ulX, ulY, urX, urY, lrX, lrY, llX, llY }
    end
    if rs.color then
        item.c = rs.color
    elseif rs.atlas then
        item.atlas = rs.atlas
        -- A sliced atlas keeps its corners at their own size, times the scale it is drawn at
        local scale = W.getEffectiveScale(region)
        if scale ~= 1 then item.sc = round(scale * 1000) / 1000 end
    elseif rs.texture then
        item.tex = rs.texture
    elseif not rs.gradient then
        return
    end
    item.a = round(alpha * 100) / 100
    if rs.vertexColor then item.vc = rs.vertexColor end
    if rs.texCoord then item.tc = rs.texCoord end
    if rs.isTexCoordTurned then item.tcTurned = true end
    if rs.blend and rs.blend ~= "BLEND" then item.bl = rs.blend end
    if rs.desaturated then item.ds = true end
    if rs.rotation and rs.rotation ~= 0 then item.rot = rs.rotation end
    if rs.gradient then item.gr = rs.gradient end
    if rs.horizTile or rs.vertTile then item.tile = { rs.horizTile and true or false, rs.vertTile and true or false } end
    if rs.mask then
        local maskState = S[rs.mask]
        item.mask = maskState and maskState.texture
        -- or an atlas, as most of the game's masks are (the player portrait's circle, the action icons' rounded square)
        if maskState and not maskState.texture and maskState.atlas then item.maskAtlas = maskState.atlas end
        -- Where the mask is: it cuts textures that only partly cover it (the minimap's round edge across a tile)
        local maskRect = maskState and W.computeRect(rs.mask)
        if maskRect then item.maskBox = { toBox(maskRect) } end
    end
    -- Map tiles overlap a hair on the page, so no seams show between them: the stand-in map's on its canvas, the game's
    -- in the layers on its canvas (their background art; the pins over them keep their size)
    local fs = S[frame]
    if fs and (fs.isMapCanvas or (rs.layer == "BACKGROUND" and fs.parent and S[fs.parent] and S[fs.parent].isMapCanvas)) then item.seam = true end
    if clip then item.cl = { toBox(clip) } end
    items[#items + 1] = item
end

local function exportFontString(items, region, rs, rect, alpha, clip)
    if not rs.text or rs.text == "" then return end
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
            for index = fitting, #lines do rest[#rest + 1] = lines[index].text end
            for index = #lines, fitting + 1, -1 do lines[index] = nil end
            local function measure(part)
                return fonts.measureWidth(setmetatable({ text = part, maxLines = false, wordWrap = false }, { __index = rs }))
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
    for index, line in ipairs(lines) do texts[index] = line.text end
    -- The text's colour, tinted by its vertex colour as in the client (the target frame greys a trivial level so)
    local color = fonts.getColor(rs)
    local tint = rs.vertexColor
    if tint then color = { (color[1] or 1) * tint[1], (color[2] or 1) * tint[2], (color[3] or 1) * tint[3], (color[4] or 1) * (tint[4] or 1) } end
    local item = { k = "s", i = rs.id, lines = texts, f = fonts.key(font.path), fs = round(font.size * (rs.textScale or 1) * scale),
        fl = font.flags ~= "" and font.flags or nil, c = color, a = round(alpha * 100) / 100,
        jh = rs.justifyH or font.justifyH or "CENTER", jv = rs.justifyV or "MIDDLE",
        lh = round(fonts.getLineHeight(rs) * scale), sp = round((rs.spacing or font.spacing or 0) * scale) }
    local shadow = rs.shadowOffset or font.shadowOffset
    if shadow and (shadow[1] ~= 0 or shadow[2] ~= 0) then item.sh = { shadow[1], shadow[2] } end
    item.x, item.y, item.w, item.h = toBox(rect)
    if rs.isEditText and W.focus == rs.parent then item.cursor = true end
    if clip then item.cl = { toBox(clip) } end
    items[#items + 1] = item
end

---A line cut to a clipping rect (Liang-Barsky), as a frame that clips its children draws it.
---@return number? x1, number? y1, number? x2, number? y2 nil when the line lies wholly outside
local function clipSegment(x1, y1, x2, y2, rect)
    local dx, dy = x2 - x1, y2 - y1
    local first, last = 0, 1
    for _, edge in ipairs({ { -dx, x1 - rect[1] }, { dx, rect[3] - x1 }, { -dy, y1 - rect[2] }, { dy, rect[4] - y1 } }) do
        local p, q = edge[1], edge[2]
        if p == 0 then
            if q < 0 then return nil end
        else
            local t = q / p
            if p < 0 then
                if t > last then return nil end
                if t > first then first = t end
            else
                if t < first then return nil end
                if t < last then last = t end
            end
        end
    end
    return x1 + dx * first, y1 + dy * first, x1 + dx * last, y1 + dy * last
end

local function exportLine(items, region, rs, alpha, clip)
    local x1, y1, x2, y2 = W.getLineEnds(region)
    if not x1 then return end
    if clip then
        x1, y1, x2, y2 = clipSegment(x1, y1, x2, y2, clip)
        if not x1 then return end
    end
    local item = { k = "ln", i = rs.id, x1 = round(x1), y1 = round(sim.screenHeight - y1), x2 = round(x2), y2 = round(sim.screenHeight - y2),
        th = round((rs.thickness or 1) * W.getEffectiveScale(region) * 100) / 100, c = rs.color, tex = rs.texture, vc = rs.vertexColor, a = round(alpha * 100) / 100 }
    if clip then item.cl = { toBox(clip) } end
    items[#items + 1] = item
end

---A slider's thumb and a status bar's fill take their place from the value.
local function getValueRect(frame, fs, region, rect)
    local minimum, maximum = fs.minValue or 0, fs.maxValue or 1
    local fraction = maximum > minimum and ((fs.value or 0) - minimum) / (maximum - minimum) or 0
    fraction = math.max(0, math.min(1, fraction))
    local frameRect = W.computeRect(frame)
    if not frameRect then return rect end
    local isVertical = fs.orientation == "VERTICAL"
    if S[region].role == "bar" then
        if isVertical then
            return { frameRect[1], frameRect[2], frameRect[3], frameRect[2] + (frameRect[4] - frameRect[2]) * fraction }
        elseif fs.reverseFill then
            return { frameRect[3] - (frameRect[3] - frameRect[1]) * fraction, frameRect[2], frameRect[3], frameRect[4] }
        end
        return { frameRect[1], frameRect[2], frameRect[1] + (frameRect[3] - frameRect[1]) * fraction, frameRect[4] }
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

-- A UnitPositionFrame's units, as the client draws them: each where it stands on the frame's map, its size times the
-- frame's scale, its colour, the player's arrow turned by their facing; and the player's ping, a ring running out
local function exportUnits(items, frame, fs, rect, alpha, clip)
    fs.drawnUnits = {}
    local mapId = fs.uiMapId
    if not mapId or not fs.units or not G.C_Map then return end
    local scale = W.getEffectiveScale(frame)
    local width, height = rect[3] - rect[1], rect[4] - rect[2]
    local entries = {}
    for _, entry in ipairs(fs.units) do entries[#entries + 1] = entry end
    -- The player's arrow over the party's dots (the larger sublevel on top; the player last among equals)
    table.sort(entries, function(first, second)
        if first.sublayer ~= second.sublayer then return first.sublayer < second.sublayer end
        return (first.unit == "player" and 1 or 0) < (second.unit == "player" and 1 or 0)
    end)
    local function addItem(key, centerX, centerY, sizeX, sizeY, asset, color, rotation, itemAlpha)
        local item = { k = "t", i = fs.id .. key }
        item.x, item.y, item.w, item.h = toBox({ centerX - sizeX / 2, centerY - sizeY / 2, centerX + sizeX / 2, centerY + sizeY / 2 })
        if W.getAtlasInfo(asset) then item.atlas = asset else item.tex = asset end
        item.a = round(itemAlpha * 100) / 100
        if color then item.vc = color end
        if rotation and rotation ~= 0 then item.rot = rotation end
        if clip then item.cl = { toBox(clip) } end
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
                    local expand = fs.pingTextures[G.Enum and G.Enum.PingTextureType and G.Enum.PingTextureType.Expand or 1]
                    if expand then
                        local size = expand.width * pingScale * (0.5 + progress * 1.5)
                        addItem("pingExpand", centerX, centerY, size, size, expand.asset, nil, nil, alpha * fade * (1 - progress))
                    end
                    sim.touchVisual() -- (it moves while it lasts)
                else
                    fs.ping = nil
                end
            end
            local rotation = entry.showFacing and G.GetPlayerFacing and G.GetPlayerFacing() or nil
            addItem("u" .. entry.unit, centerX, centerY, sizeX, sizeY, entry.asset, entry.color, rotation, alpha * (entry.color[4] or 1))
            fs.drawnUnits[#fs.drawnUnits + 1] = { unit = entry.unit, x = centerX, y = centerY, radius = math.max(sizeX, sizeY) / 2 }
        end
    end
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
    if not owner then owner = {}; ownerPool[ownerCount] = owner end
    owner.frame, owner.fs, owner.alpha, owner.rect, owner.clip, owner.rank = ownerFrame, ownerState, ownerAlpha, ownerRect, ownerClip, rank
    local regions = ownerState.regions
    for index = 1, #regions do
        local region = regions[index]
        local rs = S[region]
        if rs and rs.shown and rs.type ~= "MaskTexture" and rs.parent == ownerFrame then
            gatheredCount = gatheredCount + 1
            gathered[gatheredCount] = region
            ownerOf[region] = owner
            local sublevel = math.max(-512, math.min(511, rs.sublevel or 0))
            sortKey[region] = (((LAYER_RANK[rs.layer or "ARTWORK"] or 3) * 2 + (rs.type == "FontString" and 1 or 0)) * 1024
                + sublevel + 512) * 1024 + math.min(rank, 1023)
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
    if keyA ~= keyB then return keyA < keyB end
    local a, b = S[first], S[second]
    local artA, artB = a.artOrder or 0, b.artOrder or 0
    if artA ~= artB then return artA < artB end
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
            if inputs[index] ~= region or keys[index] ~= sortKey[region] or arts[index] ~= (S[region].artOrder or 0) then
                isSame = false
                break
            end
        end
        if isSame then
            local sorted = kept.sorted
            for index = 1, gatheredCount do gathered[index] = sorted[index] end
            return
        end
    end
    kept = { count = gatheredCount, inputs = {}, keys = {}, arts = {}, sorted = {} }
    for index = 1, gatheredCount do
        local region = gathered[index]
        kept.inputs[index], kept.keys[index], kept.arts[index] = region, sortKey[region], S[region].artOrder or 0
    end
    table.sort(gathered, regionOrder)
    for index = 1, gatheredCount do kept.sorted[index] = gathered[index] end
    fs.drawOrder = kept
end

function scene.export()
    local items = {}
    -- The game's world map canvas (with the whole interface), marked as the stand-in's is
    local map = G.WorldMapFrame
    local canvas = type(map) == "table" and type(map.ScrollContainer) == "table" and map.ScrollContainer.Child
    if canvas and S[canvas] and not S[canvas].isMapCanvas then S[canvas].isMapCanvas = true end
    -- (children drawn at their parent's level are drawn with it, below)
    for key in pairs(drawnWithParent) do drawnWithParent[key] = nil end
    clearExportMemos()
    for _, frame in ipairs(scene.getSortedFrames()) do
        local fs = S[frame]
        local rect = W.computeRect(frame)
        local alpha = exportAlpha(frame)
        if rect and alpha > 0.002 then
            local clip = exportClip(frame)
            if fs.backdrop then
                local item = { k = "b", i = fs.id, bg = fs.backdrop.bgFile, edge = fs.backdrop.edgeFile, es = fs.backdrop.edgeSize,
                    ins = fs.backdrop.insets, tile = fs.backdrop.tile, ts = fs.backdrop.tileSize, c = fs.backdropColor, bc = fs.backdropBorderColor,
                    a = round(alpha * 100) / 100 }
                item.x, item.y, item.w, item.h = toBox(rect)
                if clip then item.cl = { toBox(clip) } end
                items[#items + 1] = item
            end
            if fs.messages and fs.isChat == nil and #fs.messages > 0 then
                local lines = {}
                for index = math.max(1, #fs.messages - 5), #fs.messages do
                    local message = fs.messages[index]
                    if sim.now - message.time < 6 then lines[#lines + 1] = message.text end
                end
                if #lines > 0 then
                    local item = { k = "s", i = fs.id, lines = lines, f = fonts.key("Fonts\\FRIZQT__.TTF"), fs = 16, c = { 1, 0.1, 0.1, 1 }, a = alpha, jh = "CENTER", jv = "TOP", lh = 18, sp = 2 }
                    item.x, item.y, item.w, item.h = toBox(rect)
                    items[#items + 1] = item
                end
            end
            -- Its regions, and those of its children drawn at its level (useParentLevel: a tooltip's NineSlice), all
            -- in one order by layer as the client draws a level: the tooltip's background under its text. Such a
            -- child, met later in the frames' order, has nothing more to draw.
            local previousCount = gatheredCount
            gatheredCount, ownerCount = 0, 0
            if not drawnWithParent[frame] then
                drawnWithParent[frame] = true -- (its own turn taken: a parent met later does not draw it again)
                gather(frame, fs, alpha, rect, clip, 0)
            end
            for index = gatheredCount + 1, previousCount do gathered[index] = nil end
            if gatheredCount > 1 then sortGathered(fs) end
            for regionIndex = 1, gatheredCount do
                local region = gathered[regionIndex]
                local owner = ownerOf[region]
                local frame, fs, alpha, rect, clip = owner.frame, owner.fs, owner.alpha, owner.rect, owner.clip
                local rs = S[region]
                local isShown = not rs.role or isRoleShown(frame, rs.role)
                if rs.layer == "HIGHLIGHT" and not rs.role then
                    isShown = sim.motionFocus == frame or fs.highlightLocked == true
                end
                if isShown then
                    local regionAlpha = alpha * (rs.alpha or 1)
                    if rs.type == "FontString" then
                        local regionRect = W.computeRect(region)
                        if regionRect then exportFontString(items, region, rs, regionRect, regionAlpha, fs.clips and { rect[1], rect[2], rect[3], rect[4] } or clip) end
                    elseif rs.type == "Line" then
                        exportLine(items, region, rs, regionAlpha, clip)
                    else
                        local regionRect = W.computeRect(region)
                        if rs.role == "thumb" or rs.role == "bar" then regionRect = getValueRect(frame, fs, region, regionRect) end
                        if regionRect then exportTexture(items, region, rs, frame, regionRect, regionAlpha, clip) end
                    end
                end
            end
            if fs.type == "UnitPositionFrame" then exportUnits(items, frame, fs, rect, alpha, clip) end
        end
    end
    return items
end

-- Input
local function contains(rect, x, y, insets)
    if not rect then return false end
    insets = insets or { 0, 0, 0, 0 }
    return x >= rect[1] + insets[1] and x <= rect[3] - insets[2] and y >= rect[2] + insets[4] and y <= rect[4] - insets[3]
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
            isTaking = s.mouse == true and s.mouseMotion ~= false
        else
            isTaking = s.mouse == true and s.mouseClick ~= false
        end
        if isTaking and getAlpha(frame) > 0.002 and contains(W.computeRect(frame), x, y, s.hitInsets) and isInsideClip(frame, x, y) then
            return frame
        end
    end
end

local function setMotionFocus(frame)
    local old = sim.motionFocus
    if old == frame then return end
    sim.motionFocus = frame
    sim.touchVisual()
    local function canMove(target)
        local s = S[target]
        return s and (s.enabled ~= false or s.motionWhileDisabled or not W.types[s.type].chain.Button)
    end
    if old and canMove(old) then sim.runScript(old, "OnLeave", true) end
    if frame and canMove(frame) then sim.runScript(frame, "OnEnter", true) end
end

local moving
function W.startMoving(frame)
    local rect = W.computeRect(frame)
    local mouse = sim.mouse or { x = 0, y = 0 }
    if rect then moving = { frame = frame, dx = mouse.x - rect[1], dy = mouse.y - rect[4] } end
end
function W.stopMoving() moving = nil end

function W.setFocus(editBox)
    local old = W.focus
    if old == editBox then return end
    W.focus = editBox
    sim.touch()
    if old then sim.runScript(old, "OnEditFocusLost") end
    if editBox then sim.runScript(editBox, "OnEditFocusGained") end
end

function W.clickButton(button, mouseButton, isDown)
    local s = S[button]
    if s.enabled == false then return end
    sim.runScript(button, "PreClick", mouseButton, isDown or false)
    if s.type == "CheckButton" then
        s.checked = not s.checked
        sim.touch()
    end
    sim.runScript(button, "OnClick", mouseButton, isDown or false)
    sim.runScript(button, "PostClick", mouseButton, isDown or false)
end

local function sliderValueAt(slider, x, y)
    local s = S[slider]
    local rect = W.computeRect(slider)
    if not rect then return end
    local minimum, maximum = s.minValue or 0, s.maxValue or 1
    local fraction
    if s.orientation == "VERTICAL" then
        fraction = (rect[4] - y) / math.max(rect[4] - rect[2], 1)
    else
        fraction = (x - rect[1]) / math.max(rect[3] - rect[1], 1)
    end
    W.setBarValue(slider, minimum + math.max(0, math.min(1, fraction)) * (maximum - minimum))
end

function scene.input(event)
    local x, y = event.x and event.x or 0, event.y and (sim.screenHeight - event.y) or 0
    if event.mods then
        sim.modifiers.shift, sim.modifiers.ctrl, sim.modifiers.alt = event.mods.shift == true, event.mods.ctrl == true, event.mods.alt == true
    end
    -- A press or release where the cursor has not been yet: in the client the cursor got there over frames first, so
    -- a frame following the cursor in OnUpdate (the map's scroll container, panning while the button is held) sees it
    -- move with the button still down. The page can send a quick drag's release right after its last move.
    if (event.type == "down" or event.type == "up") and sim.mouse and (math.abs(sim.mouse.x - x) > 0.5 or math.abs(sim.mouse.y - y) > 0.5) then
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
            if S[down.frame].type == "Slider" and S[down.frame].enabled ~= false then sliderValueAt(down.frame, x, y) end
            if not down.isDragging and S[down.frame].dragButtons and (math.abs(x - down.x) > 4 or math.abs(y - down.y) > 4) then
                for _, button in ipairs(S[down.frame].dragButtons) do
                    if button == down.button or button == "AnyUp" or button == "LeftButtonUp" and down.button == "LeftButton" then
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
        if sim.onWorldHover then sim.onWorldHover(x, y, motionFrame == nil or motionFrame == G.WorldFrame) end
    elseif event.type == "down" then
        sim.mouse = { x = x, y = y }
        if sim.clickToWalk and scene.walkToPoint(x, y) then return end
        -- Edit Mode: a press on the minimap picks it up to drag, as the game's Edit Mode does
        local cluster = sim.editMode and G.MinimapCluster
        local clusterRect = cluster and W.computeRect(cluster)
        if clusterRect and x >= clusterRect[1] and x <= clusterRect[3] and y >= clusterRect[2] and y <= clusterRect[4] then
            sim.editDrag = cluster
            W.startMoving(cluster)
            return
        end
        local button = event.button or "LeftButton"
        local frame = scene.findFrameAt(x, y, "click")
        -- A press on the world: a creature's nameplate there is targeted (lua/combat.lua), as the client's world does
        if (frame == nil or frame == G.WorldFrame) and sim.onWorldClick and sim.onWorldClick(x, y, button) then return end
        sim.mouseDown = { frame = frame, button = button, x = x, y = y }
        if frame and W.types[S[frame].type].chain.EditBox then
            W.setFocus(frame)
        elseif W.focus then
            W.setFocus(nil)
        end
        if not frame or not (frame == G.UIParent) then
            -- A click outside an open menu closes it
            local ui = require("ui")
            if ui.closeMenu and frame and not (S[frame].parent and S[S[frame].parent] and S[S[frame].parent].strata == "FULLSCREEN_DIALOG") then
                if not (frame and S[frame].menuGenerator) then ui.closeMenu() end
            elseif not frame then
                ui.closeMenu()
            end
        end
        if frame then
            W.raiseToplevelOf(frame)
            sim.runScript(frame, "OnMouseDown", button)
            if S[frame].type == "Slider" and S[frame].enabled ~= false then sliderValueAt(frame, x, y) end
            -- A button registered for the press clicks on it (down = true), as in the client: the game's secure action
            -- buttons act on the press when ActionButtonUseKeyDown is on
            if W.types[S[frame].type].chain.Button then
                local clicks = S[frame].clicks or { LeftButtonUp = true }
                if clicks[button .. "Down"] or clicks.AnyDown then
                    sim.mouseDown.clickedOnPress = true
                    W.clickButton(frame, button, true)
                end
            end
            sim.touch()
        end
    elseif event.type == "up" then
        sim.mouse = { x = x, y = y }
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
                local clicks = s.clicks or { LeftButtonUp = true }
                if clicks[button .. "Up"] or clicks.AnyUp then
                    W.clickButton(frame, button, false)
                end
            end
        end
        sim.touch()
    elseif event.type == "wheel" then
        local frame = scene.findFrameAt(x, y, "wheel")
        if frame then sim.runScript(frame, "OnMouseWheel", event.delta or 0) end
    elseif event.type == "key" then
        if event.isHeld then sim.heldKeys = sim.heldKeys or {}; sim.heldKeys[(event.key or ""):upper()] = true end
        scene.key(event.key or "", event.text, event.isHeld == true)
    elseif event.type == "keyup" then
        -- A held key let go: a movement stops; a binding run on the release too (runOnUp) runs with keystate "up"
        local key = (event.key or ""):upper()
        if sim.heldKeys then sim.heldKeys[key] = nil end
        local command = sim.overrideBindings[key] and sim.overrideBindings[key].command or sim.bindings[key]
        scene.releaseCommand(command, key)
    elseif event.type == "pad" then
        -- A gamepad's button (the page reads the browser's controller): PAD1, PADDUP...
        local gamepad = require("gamepad")
        if event.isDown then gamepad.press(event.button or "") else gamepad.release(event.button or "") end
    elseif event.type == "padStick" then
        require("gamepad").setStick(event.stick, event.x, event.y)
    elseif event.type == "padConnected" then
        if event.isConnected then require("gamepad").connect(event.name) else require("gamepad").disconnect() end
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
    if not command or command == "" then return false end
    -- A click binding (SetBindingClick; the gamepad's menus set them on its keys): as in the client, the press clicks
    -- a button registered for down-clicks ("AnyDown"), with down true; its up-click comes as the key comes up
    -- (releaseCommand)
    local frameName, button = command:match("^CLICK%s+([^:]+):?(.*)$")
    if frameName then
        local frame = G[frameName]
        if not (frame and frame.Click and S[frame]) then return false end
        button = button ~= "" and button or "LeftButton"
        local clicks = S[frame].clicks or { LeftButtonUp = true }
        if clicks.AnyDown or clicks[button .. "Down"] then W.clickButton(frame, button, true) end
        return true
    end
    local movement = require("movement")
    -- Held (the page sends key down and up): the character moves until the key comes up, at the game's speeds
    if isHeld and movement.isMovementCommand(command) then movement.press(command); return true end
    if command == "TOGGLEAUTORUN" then movement.toggleAutoRun(); return true end
    if command == "TOGGLERUN" then movement.setWalking(not movement.describe().isWalking); return true end
    -- A single press (a scenario's key("W")) moves a step (yards) or turns a little
    local game = require("game")
    local STEP, TURN = 8, math.rad(15)
    local movement = { MOVEFORWARD = function() game.walk(STEP, 0) end, MOVEBACKWARD = function() game.walk(-STEP / 2, 0) end,
        TURNLEFT = function() game.turn(TURN) end, TURNRIGHT = function() game.turn(-TURN) end,
        STRAFELEFT = function() game.walk(0, -STEP) end, STRAFERIGHT = function() game.walk(0, STEP) end }
    if movement[command] then movement[command](); return true end
    -- The game's own binding (its Bindings XML, read with the whole interface): its Lua, run as the client runs a
    -- key's command, securely, with keystate "down"
    local binding = sim.bindingCode and sim.bindingCode[command]
    if binding then sim.runSecurely(binding, "down"); return true end
    local handlers = { OPENCHAT = function() G.ChatFrame_OpenChat("") end,
        TOGGLEWORLDMAP = G.ToggleWorldMap, TOGGLEQUESTLOG = G.ToggleQuestLog, TOGGLEGAMEMENU = function()
        local ui = require("ui")
        if ui.closeMenu then ui.closeMenu() end
        G.CloseSpecialWindows()
    end }
    if handlers[command] then sim.call(handlers[command]); return true end
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
    if not command or command == "" then return end
    local frameName, button = command:match("^CLICK%s+([^:]+):?(.*)$")
    if frameName then
        local frame = G[frameName]
        if not (frame and frame.Click and S[frame]) then return end
        button = button ~= "" and button or "LeftButton"
        local clicks = S[frame].clicks or { LeftButtonUp = true }
        if clicks.AnyUp or clicks[button .. "Up"] then W.clickButton(frame, button, false) end
        return
    end
    require("movement").release(command)
    local binding = sim.bindingCode and sim.bindingCode[command]
    if binding and sim.bindingRunsOnUp and sim.bindingRunsOnUp[command] then sim.runSecurely(binding, "up") end
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
            if not continentId then return true end
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
        if not isSent then sim.call(G.UIErrorsFrame and G.UIErrorsFrame.AddMessage or function() end, G.UIErrorsFrame, problem, 1, 0.1, 0.1) end
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
            if s.scripts.OnEnterPressed then sim.runScript(editBox, "OnEnterPressed") elseif not s.multiLine then W.setFocus(nil) end
            if s.multiLine and not s.scripts.OnEnterPressed then W.setEditText(editBox, (s.text or "") .. "\n", true) end
        elseif key == "ESCAPE" then
            if s.scripts.OnEscapePressed then sim.runScript(editBox, "OnEscapePressed") else W.setFocus(nil) end
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
            if not S[frame].propagateKeyboard then return end
        end
    end
    local override = sim.overrideBindings[key]
    if override and runBindingCommand(override.command, isHeld) then return end
    if key == "ESCAPE" then runBindingCommand("TOGGLEGAMEMENU"); return end
    runBindingCommand(sim.bindings[key], isHeld)
end

---Every frame under a point, top first, for the inspector.
---@return string label A frame as the game's frame stack names it: its name, else the key its parent keeps it under
---(PlayerFrame.PlayerFrameContent), else its type and number
function scene.frameLabel(object, depth)
    local state = object and S[object]
    if not state then return tostring(object) end
    if state.name then return state.name end
    local parent = state.parent
    if type(parent) == "table" and (depth or 0) < 12 then
        for key, value in pairs(parent) do
            if value == object and type(key) == "string" then return scene.frameLabel(parent, (depth or 0) + 1) .. "." .. key end
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
                if rs.text and rs.text ~= "" then return true end
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
        if contains(rect, x, y) and isInsideClip(frame, x, y) and (not isDrawnOnly or S[frame].mouse or drawsSomething(frame)) then
            local s = S[frame]
            local bx, by, bw, bh = toBox(rect)
            results[#results + 1] = { id = s.id, creator = s.creator, name = scene.frameLabel(frame),
                type = s.type, strata = W.getStrata(frame), level = s.level, mouse = s.mouse == true, x = bx, y = by, w = bw, h = bh }
            if #results >= 20 then break end
        end
    end
    return results
end

return scene
