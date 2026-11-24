-- Animation groups as the client plays them: each animation changes its target (the group's owner, or a child by its
-- key or name) over its duration, in the order its group gives (an order's animations together, the next order after),
-- eased by its smoothing, held at its end while the group plays on, gone when the group stops. Alpha sets the target's
-- alpha (setToFinalAlpha keeps the last); Translation moves it, Scale and Rotation turn and size it about its origin,
-- TextureCoordTranslation scrolls a texture, FlipBook steps through a sheet's cells, VertexColor tints it.
--
-- What the animations do is the scene's to draw (lua/scene.lua asks animation.collect() once an export, then each
-- object's effect): a group's timer here only tells its scripts (OnPlay, OnLoop, OnFinished) when.
local sim = require("sim")

local animation = {}

-- The groups that are playing or held paused: what an export looks at
local active = setmetatable({}, { __mode = "k" })
animation.active = active
-- What an Alpha animation of a playing group has played on (GetAlpha looks further only for these)
local alphaTargets = setmetatable({}, { __mode = "k" })

-- (a group's owner on show: the game's cast bars loop their animations while hidden, which changes nothing drawn)
local function isOnShow(group)
    local owner = group.owner
    return type(owner) == "table" and owner.IsVisible ~= nil and owner:IsVisible()
end

local SMOOTHING = {
    NONE = function(p)
        return p
    end,
    IN = function(p)
        return p * p
    end,
    OUT = function(p)
        return 1 - (1 - p) * (1 - p)
    end,
    IN_OUT = function(p)
        return p < 0.5 and 2 * p * p or 1 - 2 * (1 - p) * (1 - p)
    end,
}

-- The setters and getters of every kind; each animation also takes its kind's own (below)
local function number(value, default)
    return tonumber(value) or default
end

local function lowerKind(kind)
    kind = tostring(kind or "Animation"):lower()
    if kind == "texturecoordtranslation" then
        return "texcoord"
    end
    return kind
end

local animationMethods = {}
animationMethods.__index = animationMethods

function animationMethods:SetDuration(seconds)
    self.duration = math.max(0, number(seconds, 0))
end
function animationMethods:GetDuration()
    return self.duration
end
function animationMethods:SetStartDelay(seconds)
    self.startDelay = math.max(0, number(seconds, 0))
end
function animationMethods:GetStartDelay()
    return self.startDelay
end
function animationMethods:SetEndDelay(seconds)
    self.endDelay = math.max(0, number(seconds, 0))
end
function animationMethods:GetEndDelay()
    return self.endDelay
end
function animationMethods:SetOrder(order)
    self.order = math.max(1, math.floor(number(order, 1)))
end
function animationMethods:GetOrder()
    return self.order
end
function animationMethods:SetSmoothing(smoothing)
    self.smoothing = SMOOTHING[tostring(smoothing or "NONE"):upper()] and tostring(smoothing):upper() or "NONE"
end
function animationMethods:GetSmoothing()
    return self.smoothing
end
function animationMethods:SetSmoothProgress(progress)
    self.smoothProgress = number(progress, 0)
end
-- Its target: an object, a key on the group's owner (dotted: "Glow.Ring"), or a global name
function animationMethods:SetTarget(target)
    self.target, self.childKey, self.targetName = target, nil, nil
end
function animationMethods:SetChildKey(key)
    self.childKey, self.target, self.targetName = key, nil, nil
    return true
end
animationMethods.SetTargetKey = animationMethods.SetChildKey
function animationMethods:SetTargetName(name)
    self.targetName, self.target, self.childKey = name, nil, nil
    return true
end
function animationMethods:SetTargetParent()
    self.target, self.childKey, self.targetName = nil, nil, nil
    return true
end
function animationMethods:GetTarget()
    return animation.targetOf(self)
end
function animationMethods:GetRegionParent()
    return self.group.owner
end
function animationMethods:GetParent()
    return self.group
end
function animationMethods:GetObjectType()
    return self.kindName
end
function animationMethods:IsObjectType(kind)
    return tostring(kind):lower() == self.kindName:lower() or tostring(kind):lower() == "animation"
end
function animationMethods:GetName()
    return self.name
end
function animationMethods:SetScript(script, handler)
    self.scripts[script] = handler
end
function animationMethods:GetScript(script)
    return self.scripts[script]
end
function animationMethods:HookScript(script, handler)
    local before = self.scripts[script]
    self.scripts[script] = before and function(...)
        before(...)
        handler(...)
    end or handler
end
function animationMethods:HasScript()
    return true
end
function animationMethods:IsPlaying()
    return self.group.playing
end
function animationMethods:IsPaused()
    return self.group.paused == true
end
function animationMethods:IsStopped()
    return not self.group.playing and not self.group.paused
end
function animationMethods:IsDone()
    return not self.group.playing
end
function animationMethods:IsDelaying()
    local state = animation.stateOf(self)
    return state ~= nil and state.isWaiting
end
function animationMethods:Play()
    self.group:Play()
end
function animationMethods:Restart()
    self.group:Restart()
end
function animationMethods:Stop()
    self.group:Stop()
end
function animationMethods:Pause()
    self.group:Pause()
end
function animationMethods:SetPlaying(isPlaying)
    self.group:SetPlaying(isPlaying)
end
function animationMethods:GetElapsed()
    local state = animation.stateOf(self)
    return state and state.elapsed or 0
end
function animationMethods:GetProgress()
    local state = animation.stateOf(self)
    return state and state.progress or 0
end
function animationMethods:GetSmoothProgress()
    local state = animation.stateOf(self)
    return state and state.eased or 0
end

-- Alpha
function animationMethods:SetFromAlpha(alpha)
    self.fromAlpha = number(alpha, 0)
end
function animationMethods:GetFromAlpha()
    return self.fromAlpha
end
function animationMethods:SetToAlpha(alpha)
    self.toAlpha = number(alpha, 0)
end
function animationMethods:GetToAlpha()
    return self.toAlpha
end
-- (the old way: a change from the target's alpha)
function animationMethods:SetChange(change)
    self.change = number(change, 0)
end
function animationMethods:GetChange()
    return self.change or 0
end
-- Translation, TextureCoordTranslation
function animationMethods:SetOffset(x, y)
    self.offsetX, self.offsetY = number(x, 0), number(y, 0)
end
function animationMethods:GetOffset()
    return self.offsetX, self.offsetY
end
-- Scale: by (from 1), or from and to
function animationMethods:SetScale(x, y)
    self.fromScaleX, self.fromScaleY = 1, 1
    self.toScaleX, self.toScaleY = number(x, 1), number(y, number(x, 1))
end
function animationMethods:GetScale()
    return self.toScaleX, self.toScaleY
end
function animationMethods:SetScaleFrom(x, y)
    self.fromScaleX, self.fromScaleY = number(x, 1), number(y, number(x, 1))
end
function animationMethods:GetScaleFrom()
    return self.fromScaleX, self.fromScaleY
end
function animationMethods:SetScaleTo(x, y)
    self.toScaleX, self.toScaleY = number(x, 1), number(y, number(x, 1))
end
function animationMethods:GetScaleTo()
    return self.toScaleX, self.toScaleY
end
animationMethods.SetFromScale = animationMethods.SetScaleFrom
animationMethods.GetFromScale = animationMethods.GetScaleFrom
animationMethods.SetToScale = animationMethods.SetScaleTo
animationMethods.GetToScale = animationMethods.GetScaleTo
-- Scale, Rotation: the point they are about (the target's centre by default)
function animationMethods:SetOrigin(point, x, y)
    self.originPoint, self.originX, self.originY = tostring(point or "CENTER"):upper(), number(x, 0), number(y, 0)
end
function animationMethods:GetOrigin()
    return self.originPoint, self.originX, self.originY
end
-- Rotation
function animationMethods:SetDegrees(degrees)
    self.radians = math.rad(number(degrees, 0))
end
function animationMethods:GetDegrees()
    return math.deg(self.radians)
end
function animationMethods:SetRadians(radians)
    self.radians = number(radians, 0)
end
function animationMethods:GetRadians()
    return self.radians
end
-- FlipBook: the sheet's cells, played left to right, a row at a time
function animationMethods:SetFlipBookRows(rows)
    self.flipRows = math.max(1, number(rows, 1))
end
function animationMethods:GetFlipBookRows()
    return self.flipRows
end
function animationMethods:SetFlipBookColumns(columns)
    self.flipColumns = math.max(1, number(columns, 1))
end
function animationMethods:GetFlipBookColumns()
    return self.flipColumns
end
function animationMethods:SetFlipBookFrames(frames)
    self.flipFrames = math.max(0, number(frames, 0))
end
function animationMethods:GetFlipBookFrames()
    return self.flipFrames
end
function animationMethods:SetFlipBookFrameWidth(width)
    self.flipFrameWidth = number(width, 0)
end
function animationMethods:GetFlipBookFrameWidth()
    return self.flipFrameWidth
end
function animationMethods:SetFlipBookFrameHeight(height)
    self.flipFrameHeight = number(height, 0)
end
function animationMethods:GetFlipBookFrameHeight()
    return self.flipFrameHeight
end
-- VertexColor: a colour (a ColorMixin, or r, g, b, a) to another
local function readColor(r, g, b, a)
    if type(r) == "table" then
        return { number(r.r, 1), number(r.g, 1), number(r.b, 1), number(r.a, 1) }
    end
    return { number(r, 1), number(g, 1), number(b, 1), number(a, 1) }
end
function animationMethods:SetStartColor(r, g, b, a)
    self.startColor = readColor(r, g, b, a)
end
function animationMethods:GetStartColor()
    local c = self.startColor or { 1, 1, 1, 1 }
    return sim.G.CreateColor and sim.G.CreateColor(c[1], c[2], c[3], c[4]) or c
end
function animationMethods:SetEndColor(r, g, b, a)
    self.endColor = readColor(r, g, b, a)
end
function animationMethods:GetEndColor()
    local c = self.endColor or { 1, 1, 1, 1 }
    return sim.G.CreateColor and sim.G.CreateColor(c[1], c[2], c[3], c[4]) or c
end

-- The rest of what the client's animations take, kept but not drawn (paths, lines' ends)
for _, name in ipairs({ "SetCurveType", "SetLineStart", "SetLineEnd", "SetFromValue", "SetToValue" }) do
    animationMethods[name] = function(self, ...)
        self[name] = { ... }
    end
end
function animationMethods:CreateControlPoint()
    local point = {}
    function point.SetOffset() end
    function point.SetOrder() end
    function point.GetOffset()
        return 0, 0
    end
    return point
end

---What an animation is doing now (nil while its group is stopped): elapsed and progress in its own time, eased; it
---waits before its start, holds its end after it
function animation.stateOf(anim)
    local group = anim.group
    local timing = group.timing
    if not timing or not (group.playing or group.paused) then
        return nil
    end
    local at = group.paused and group.pausedAt or (sim.now - group.startedAt)
    local total = timing.total
    if total > 0 then
        if group.looping == "REPEAT" then
            at = at % total
        elseif group.looping == "BOUNCE" then
            at = at % (2 * total)
            if at > total then
                at = 2 * total - at
            end
        else
            at = math.min(at, total)
        end
    end
    local local_ = at - (timing.orderStart[anim.order] or 0) - anim.startDelay
    if local_ < 0 then
        return { isWaiting = true, elapsed = 0, progress = 0, eased = 0 }
    end
    local progress = anim.duration > 0 and math.min(1, local_ / anim.duration) or 1
    local ease = SMOOTHING[anim.smoothing] or SMOOTHING.NONE
    return { isWaiting = false, elapsed = math.min(local_, anim.duration), progress = progress, eased = ease(progress) }
end

---Its target: the object it changes (the group's owner, unless a key or name says another)
function animation.targetOf(anim)
    if anim.target then
        return anim.target
    end
    local owner = anim.group.owner
    if anim.childKey then
        local current = owner
        for key in tostring(anim.childKey):gmatch("[^%.]+") do
            if type(current) ~= "table" then
                return nil
            end
            current = key == "$parent" and current:GetParent() or rawget(current, key) or current[key]
        end
        return type(current) == "table" and current or nil
    end
    if anim.targetName then
        local name = tostring(anim.targetName)
        if name:find("$parent", 1, true) then
            local W = require("widgets")
            name = name:gsub("%$parent", W.getParentNameFor(owner) or "")
        end
        local found = rawget(sim.G, name)
        return type(found) == "table" and found or nil
    end
    return owner
end

-- When each order starts and how long the whole takes (an order lasts as long as its longest animation)
local function computeTiming(group)
    local spans, orders = {}, {}
    for _, anim in ipairs(group.animations) do
        local span = anim.startDelay + anim.duration + anim.endDelay
        if not spans[anim.order] then
            orders[#orders + 1] = anim.order
        end
        spans[anim.order] = math.max(spans[anim.order] or 0, span)
    end
    table.sort(orders)
    local orderStart, at = {}, 0
    for _, order in ipairs(orders) do
        orderStart[order] = at
        at = at + spans[order]
    end
    return { orderStart = orderStart, total = at }
end

local groupMethods = {}
groupMethods.__index = groupMethods

function groupMethods:CreateAnimation(animationType, animationName, template)
    local kindName = tostring(animationType or "Animation")
    local anim = setmetatable({
        group = self,
        kind = lowerKind(kindName),
        kindName = kindName,
        name = animationName,
        duration = 0,
        startDelay = 0,
        endDelay = 0,
        order = 1,
        smoothing = "NONE",
        scripts = {},
        offsetX = 0,
        offsetY = 0,
        fromScaleX = 1,
        fromScaleY = 1,
        toScaleX = 1,
        toScaleY = 1,
        originPoint = "CENTER",
        originX = 0,
        originY = 0,
        radians = 0,
        flipRows = 1,
        flipColumns = 1,
        flipFrames = 0,
        flipFrameWidth = 0,
        flipFrameHeight = 0,
    }, animationMethods)
    table.insert(self.animations, anim)
    if template and animation.applyTemplate then
        animation.applyTemplate(anim, template)
    end
    return anim
end

-- (playing already, it plays on: Restart starts it again, as in the client; paused, it goes on from there)
function groupMethods:Play(isReverse, offset)
    if self.playing then
        return
    end
    if self.timer then
        self.timer.cancelled = true
    end
    self.timing = computeTiming(self)
    self.startedAt = sim.now - (tonumber(offset) or 0)
    if self.paused and self.pausedAt then
        self.startedAt = sim.now - self.pausedAt
    end
    self.playing, self.paused, self.pausedAt = true, false, nil
    active[self] = true
    for _, anim in ipairs(self.animations) do
        if anim.kind == "alpha" then
            local target = animation.targetOf(anim)
            if target then
                alphaTargets[target] = true
            end
        end
    end
    sim.touchVisual()
    if self.scripts.OnPlay then
        sim.call(self.scripts.OnPlay, self)
    end
    local total = self.timing.total
    local function finish()
        if not self.playing then
            return
        end
        if self.looping ~= "NONE" then
            if self.scripts.OnLoop then
                sim.call(self.scripts.OnLoop, self, "FORWARD")
            end
            self.timer = sim.addTimer(math.max(total, 0.1), finish)
            return
        end
        self.playing = false
        active[self] = nil
        sim.touchVisual()
        -- setToFinalAlpha: the alpha the animation ended at stays the target's
        if self.isToFinalAlpha then
            for _, anim in ipairs(self.animations) do
                local target = anim.kind == "alpha" and animation.targetOf(anim)
                if target and target.SetAlpha then
                    target:SetAlpha(anim.toAlpha or 1)
                end
            end
        end
        for _, anim in ipairs(self.animations) do
            if anim.scripts.OnFinished then
                sim.call(anim.scripts.OnFinished, anim, false)
            end
        end
        if self.scripts.OnFinished then
            sim.call(self.scripts.OnFinished, self, false)
        end
    end
    self.timer = sim.addTimer(math.max(total - (sim.now - self.startedAt), 0), finish)
end
function groupMethods:Restart(isReverse, offset)
    self.playing, self.paused, self.pausedAt = false, false, nil
    self:Play(isReverse, offset)
end
function groupMethods:Stop()
    local wasActive = self.playing or self.paused
    self.playing, self.paused, self.pausedAt = false, false, nil
    active[self] = nil
    if self.timer then
        self.timer.cancelled = true
    end
    if wasActive then
        sim.touchVisual()
    end
    if self.scripts.OnStop then
        sim.call(self.scripts.OnStop, self)
    end
end
-- Held where it is: not playing, not done; Play goes on from there
function groupMethods:Pause()
    if not self.playing then
        return
    end
    self.pausedAt = sim.now - self.startedAt
    self.playing, self.paused = false, true
    if self.timer then
        self.timer.cancelled = true
    end
    if self.scripts.OnPause then
        sim.call(self.scripts.OnPause, self)
    end
end
function groupMethods:IsPaused()
    return self.paused == true
end
function groupMethods:Finish()
    self:Stop()
end
function groupMethods:IsPlaying()
    return self.playing
end
function groupMethods:IsPendingFinish()
    return false
end
function groupMethods:IsDone()
    return not self.playing and not self.paused
end
function groupMethods:SetLooping(looping)
    self.looping = tostring(looping or "NONE"):upper()
end
function groupMethods:GetLooping()
    return self.looping
end
function groupMethods:GetLoopState()
    return self.looping == "NONE" and "NONE" or "FORWARD"
end
function groupMethods:SetScript(script, handler)
    self.scripts[script] = handler
end
function groupMethods:GetScript(script)
    return self.scripts[script]
end
function groupMethods:HookScript(script, handler)
    local before = self.scripts[script]
    self.scripts[script] = before and function(...)
        before(...)
        handler(...)
    end or handler
end
function groupMethods:HasScript()
    return true
end
function groupMethods:GetAnimations()
    return unpack(self.animations)
end
function groupMethods:GetParent()
    return self.owner
end
function groupMethods:SetToFinalAlpha(isOn)
    self.isToFinalAlpha = isOn and true or false
end
function groupMethods:IsSetToFinalAlpha()
    return self.isToFinalAlpha == true
end
function groupMethods:GetDuration()
    return computeTiming(self).total
end
function groupMethods:GetElapsed()
    if self.paused then
        return self.pausedAt or 0
    end
    return self.playing and (sim.now - self.startedAt) or 0
end
function groupMethods:GetProgress()
    local total = (self.timing or computeTiming(self)).total
    return total > 0 and math.min(1, self:GetElapsed() / total) or 0
end
function groupMethods:SetPlaying(isPlaying)
    if isPlaying then
        self:Play()
    else
        self:Stop()
    end
end
function groupMethods:GetName()
    return self.name
end
function groupMethods:GetObjectType()
    return "AnimationGroup"
end
function groupMethods:IsObjectType(kind)
    return tostring(kind):lower() == "animationgroup"
end
function groupMethods:IsReverse()
    return false
end
function groupMethods:SetAnimationSpeedMultiplier() end
function groupMethods:GetAnimationSpeedMultiplier()
    return 1
end
function groupMethods:RemoveAnimations()
    self.animations = {}
end

---A new group on its owner (a frame or a region)
function animation.newGroup(owner)
    return setmetatable(
        { owner = owner, animations = {}, scripts = {}, playing = false, paused = false, looping = "NONE" },
        groupMethods
    )
end

-- What the playing groups do this export: for each target, its effect. Kept in tables reused from export to export
local effects = {}
local effectPool, effectCount = {}, 0

local function effectFor(target)
    local effect = effects[target]
    if effect then
        return effect
    end
    effectCount = effectCount + 1
    effect = effectPool[effectCount]
    if not effect then
        effect = {}
        effectPool[effectCount] = effect
    end
    effect.alpha, effect.dx, effect.dy, effect.scaleX, effect.scaleY, effect.radians = nil, 0, 0, 1, 1, 0
    effect.originPoint, effect.originX, effect.originY = "CENTER", 0, 0
    effect.u, effect.v, effect.cell, effect.color = 0, 0, nil, nil
    effects[target] = effect
    return effect
end

---The playing groups' effects gathered (once an export); true when there are any
function animation.collect()
    for target in pairs(effects) do
        effects[target] = nil
    end
    effectCount = 0
    if next(active) == nil then
        return false
    end
    for group in pairs(active) do
        if (group.playing or group.paused) and isOnShow(group) then
            for _, anim in ipairs(group.animations) do
                local kind = anim.kind
                if kind ~= "animation" then
                    local state = animation.stateOf(anim)
                    local target = state and not state.isWaiting and animation.targetOf(anim)
                    if target then
                        local p = state.eased
                        local effect = effectFor(target)
                        if kind == "alpha" then
                            local from = anim.fromAlpha
                            local to = anim.toAlpha
                            if anim.change and not from then
                                from = (effect.alpha or 1)
                                to = from + anim.change
                            end
                            from, to = from or 0, to or 0
                            effect.alpha = (effect.alpha or 1) * math.max(0, math.min(1, from + (to - from) * p))
                        elseif kind == "translation" then
                            effect.dx = effect.dx + anim.offsetX * p
                            effect.dy = effect.dy + anim.offsetY * p
                        elseif kind == "scale" then
                            local sx = anim.fromScaleX + (anim.toScaleX - anim.fromScaleX) * p
                            local sy = anim.fromScaleY + (anim.toScaleY - anim.fromScaleY) * p
                            effect.scaleX, effect.scaleY = effect.scaleX * sx, effect.scaleY * sy
                            effect.originPoint, effect.originX, effect.originY =
                                anim.originPoint, anim.originX, anim.originY
                        elseif kind == "rotation" then
                            effect.radians = effect.radians + anim.radians * p
                            effect.originPoint, effect.originX, effect.originY =
                                anim.originPoint, anim.originX, anim.originY
                        elseif kind == "texcoord" then
                            effect.u = effect.u + anim.offsetX * p
                            effect.v = effect.v + anim.offsetY * p
                        elseif kind == "flipbook" then
                            local cells = anim.flipFrames > 0 and anim.flipFrames or anim.flipRows * anim.flipColumns
                            local index = math.min(cells - 1, math.floor(state.progress * cells))
                            effect.cell = effect.cell or {}
                            effect.cell[1], effect.cell[2], effect.cell[3] = index, anim.flipRows, anim.flipColumns
                        elseif kind == "vertexcolor" then
                            local from, to = anim.startColor or { 1, 1, 1, 1 }, anim.endColor or { 1, 1, 1, 1 }
                            local color = effect.color or {}
                            for channel = 1, 4 do
                                color[channel] = from[channel] + (to[channel] - from[channel]) * p
                            end
                            effect.color = color
                        end
                    end
                end
            end
        end
    end
    return next(effects) ~= nil
end

---Whether a group is playing on something shown (the picture changes every frame while one is)
function animation.isAnimating()
    for group in pairs(active) do
        if group.playing and isOnShow(group) then
            return true
        end
    end
    return false
end
sim.isAnimating = animation.isAnimating

---The alpha an Alpha animation gives an object now (GetAlpha reads it while one plays); nil when none plays on it
function animation.liveAlphaOf(object)
    if next(active) == nil or not alphaTargets[object] then
        return nil
    end
    local result
    for group in pairs(active) do
        if group.playing or group.paused then
            for _, anim in ipairs(group.animations) do
                if anim.kind == "alpha" then
                    local state = animation.stateOf(anim)
                    if state and not state.isWaiting and animation.targetOf(anim) == object then
                        local from, to = anim.fromAlpha or 0, anim.toAlpha or 0
                        local value = math.max(0, math.min(1, from + (to - from) * state.eased))
                        result = (result or 1) * value
                    end
                end
            end
        end
    end
    return result
end

---What the animations do to an object this export (collect first); nil for nothing
function animation.effectOf(object)
    return effects[object]
end

---Every object an animation plays on this export, with its effect (as animation.collect left them; read only)
function animation.targets()
    return effects
end

return animation
