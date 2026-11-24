-- Durations and curves, as the client hands them to addons: a duration object (C_DurationUtil.CreateDuration) holds a
-- span of the game's clock and answers how much of it has gone or is left, a curve reads a value (or a colour) off
-- its points, a numeric rule formatter shortens big numbers by breakpoints. Cooldowns take a duration
-- (SetCooldownFromDurationObject), status bars run on one (SetTimerDuration: their value the time gone or left, drawn
-- as it goes), and a channelled spell's is UnitChannelDuration's.
local sim = require("sim")
local W = require("widgets")

local durations = {}

local function number(value, default)
    return tonumber(value) or default
end

-- Durations
local durationMethods = {}
durationMethods.__index = durationMethods

local function newDuration()
    return setmetatable({ start = 0, length = 0, modRate = 1 }, durationMethods)
end
durations.new = newDuration

---Whether a value is one of these objects
function durations.isDuration(value)
    return type(value) == "table" and getmetatable(value) == durationMethods
end

function durationMethods:SetTimeFromStart(start, length, modRate)
    self.start = number(start, 0)
    self.length = math.max(0, number(length, 0))
    self.modRate = number(modRate, 1)
end
function durationMethods:SetTimeFromEnd(endTime, length, modRate)
    length = math.max(0, number(length, 0))
    self:SetTimeFromStart(number(endTime, 0) - length, length, modRate)
end
function durationMethods:SetTimeSpan(start, endTime)
    start = number(start, 0)
    self:SetTimeFromStart(start, math.max(0, number(endTime, 0) - start), 1)
end
function durationMethods:Reset()
    self.start, self.length, self.modRate = 0, 0, 1
end
durationMethods.SetToDefaults = durationMethods.Reset
function durationMethods:Assign(other)
    if durations.isDuration(other) then
        self.start, self.length, self.modRate = other.start, other.length, other.modRate
    end
end
function durationMethods:Copy()
    local copy = newDuration()
    copy:Assign(self)
    return copy
end
-- (the time gone, at its rate: a hasted cast's runs faster)
local function elapsed(self)
    return math.max(0, math.min(self.length, (sim.now - self.start) * (self.modRate or 1)))
end
function durationMethods:GetStartTime()
    return self.start
end
function durationMethods:GetEndTime()
    return self.start + self.length / (self.modRate ~= 0 and self.modRate or 1)
end
function durationMethods:GetTotalDuration()
    return self.length
end
function durationMethods:GetElapsedDuration()
    return elapsed(self)
end
function durationMethods:GetRemainingDuration()
    return self.length - elapsed(self)
end
function durationMethods:GetElapsedPercent()
    return self.length > 0 and elapsed(self) / self.length or 0
end
function durationMethods:GetRemainingPercent()
    return self.length > 0 and 1 - elapsed(self) / self.length or 0
end
function durationMethods:GetModRate()
    return self.modRate
end
function durationMethods:IsZero()
    return self.length <= 0
end
function durationMethods:HasStarted()
    return sim.now >= self.start
end
function durationMethods:HasExpired()
    return self.length <= 0 or elapsed(self) >= self.length
end
function durationMethods:IsActive()
    return self.length > 0 and sim.now >= self.start and elapsed(self) < self.length
end
function durationMethods:HasSecretValues()
    return false
end
function durationMethods:GetClock()
    return nil
end
function durationMethods:SetClock() end
function durationMethods:GetClockTime()
    return sim.now
end
-- A value read off a curve at the duration's time or share
local function evaluate(curve, x)
    if type(curve) == "table" and curve.Evaluate then
        return curve:Evaluate(x)
    end
    return x
end
function durationMethods:EvaluateElapsedDuration(curve)
    return evaluate(curve, elapsed(self))
end
function durationMethods:EvaluateRemainingDuration(curve)
    return evaluate(curve, self.length - elapsed(self))
end
function durationMethods:EvaluateElapsedPercent(curve)
    return evaluate(curve, self:GetElapsedPercent())
end
function durationMethods:EvaluateRemainingPercent(curve)
    return evaluate(curve, self:GetRemainingPercent())
end
function durationMethods:EvaluateTotalDuration(curve)
    return evaluate(curve, self.length)
end
-- Its time as text: by the formatter given (a numeric rule formatter, or anything with Format), else whole seconds
local function format(formatter, seconds)
    if type(formatter) == "table" and formatter.Format then
        return formatter:Format(seconds)
    end
    return tostring(math.ceil(seconds - 0.0001))
end
function durationMethods:FormatElapsedDuration(formatter)
    return format(formatter, elapsed(self))
end
function durationMethods:FormatRemainingDuration(formatter)
    return format(formatter, self.length - elapsed(self))
end
function durationMethods:FormatTotalDuration(formatter)
    return format(formatter, self.length)
end

-- Curves: points, and a value read off them (straight between points, the ends held beyond them)
local function newCurve(isColor)
    local curve = { points = {}, curveType = 0 }
    local function sortPoints()
        table.sort(curve.points, function(a, b)
            return a[1] < b[1]
        end)
    end
    local function mix(a, b, share)
        if not isColor then
            return a + (b - a) * share
        end
        local function channel(color, key, index)
            return number(type(color) == "table" and (color[key] or color[index]), 1)
        end
        local r = channel(a, "r", 1) + (channel(b, "r", 1) - channel(a, "r", 1)) * share
        local g = channel(a, "g", 2) + (channel(b, "g", 2) - channel(a, "g", 2)) * share
        local bl = channel(a, "b", 3) + (channel(b, "b", 3) - channel(a, "b", 3)) * share
        local al = channel(a, "a", 4) + (channel(b, "a", 4) - channel(a, "a", 4)) * share
        return sim.G.CreateColor and sim.G.CreateColor(r, g, bl, al) or { r = r, g = g, b = bl, a = al }
    end
    function curve:AddPoint(x, y)
        table.insert(self.points, { number(x, 0), y })
        sortPoints()
    end
    function curve:ClearPoints()
        self.points = {}
    end
    curve.SetToDefaults = curve.ClearPoints
    function curve:RemovePoint(index)
        table.remove(self.points, index)
    end
    function curve:SetPoints(points)
        self.points = {}
        for _, point in ipairs(points or {}) do
            table.insert(self.points, { number(point.x or point[1], 0), point.y or point[2] })
        end
        sortPoints()
    end
    function curve:GetPoints()
        local list = {}
        for index, point in ipairs(self.points) do
            list[index] = { x = point[1], y = point[2] }
        end
        return list
    end
    function curve:GetPoint(index)
        local point = self.points[index]
        return point and { x = point[1], y = point[2] }
    end
    function curve:GetPointCount()
        return #self.points
    end
    function curve:SetType(curveType)
        self.curveType = curveType
    end
    function curve:GetType()
        return self.curveType
    end
    function curve:HasSecretValues()
        return false
    end
    function curve:Copy()
        local copy = newCurve(isColor)
        copy:SetPoints(self:GetPoints())
        copy.curveType = self.curveType
        return copy
    end
    function curve:Evaluate(x)
        local points = self.points
        x = number(x, 0)
        if #points == 0 then
            return isColor and mix({ 1, 1, 1, 1 }, { 1, 1, 1, 1 }, 0) or 0
        end
        if x <= points[1][1] then
            return isColor and mix(points[1][2], points[1][2], 0) or points[1][2]
        end
        for index = 2, #points do
            local a, b = points[index - 1], points[index]
            if x <= b[1] then
                return mix(a[2], b[2], (x - a[1]) / math.max(b[1] - a[1], 1e-9))
            end
        end
        local last = points[#points][2]
        return isColor and mix(last, last, 0) or last
    end
    if isColor then
        function curve:EvaluateUnpacked(x)
            local color = self:Evaluate(x)
            return color.r, color.g, color.b, color.a
        end
    end
    return curve
end

-- A number shortened by breakpoints, as the client's NumericRuleFormatter: the largest breakpoint the number reaches
-- gives its divisors and its abbreviation (1500 with { breakpoint = 1000, abbreviation = "K", significandDivisor =
-- 100, fractionDivisor = 10 } is "1.5K")
local function newNumericRuleFormatter()
    local formatter = { breakpoints = {} }
    function formatter:SetBreakpoints(breakpoints)
        self.breakpoints = {}
        for _, breakpoint in ipairs(breakpoints or {}) do
            self:AddBreakpoint(breakpoint)
        end
    end
    function formatter:AddBreakpoint(breakpoint)
        if type(breakpoint) == "table" then
            table.insert(self.breakpoints, breakpoint)
            table.sort(self.breakpoints, function(a, b)
                return number(a.breakpoint, 0) > number(b.breakpoint, 0)
            end)
        end
    end
    function formatter:ClearBreakpoints()
        self.breakpoints = {}
    end
    function formatter:GetBreakpoints()
        return self.breakpoints
    end
    function formatter:Copy()
        local copy = newNumericRuleFormatter()
        copy:SetBreakpoints(self.breakpoints)
        return copy
    end
    function formatter:Format(value)
        value = number(value, 0)
        for _, breakpoint in ipairs(self.breakpoints) do
            if math.abs(value) >= number(breakpoint.breakpoint, 0) then
                local significand = number(breakpoint.significandDivisor, 1)
                local fraction = number(breakpoint.fractionDivisor, 1)
                local shown = math.floor(value / significand) / fraction
                local text = shown == math.floor(shown) and tostring(math.floor(shown)) or tostring(shown)
                return text .. tostring(breakpoint.abbreviation or "")
            end
        end
        return tostring(math.floor(value + 0.5))
    end
    return formatter
end

function durations.install(G)
    G.C_DurationUtil = G.C_DurationUtil or {}
    G.C_DurationUtil.CreateDuration = newDuration

    G.C_CurveUtil = G.C_CurveUtil or {}
    G.C_CurveUtil.CreateCurve = function()
        return newCurve(false)
    end
    G.C_CurveUtil.CreateColorCurve = function()
        return newCurve(true)
    end
    G.C_CurveUtil.EvaluateColorValueFromBoolean = function(isTrue, valueIfTrue, valueIfFalse)
        if isTrue then
            return valueIfTrue
        end
        return valueIfFalse
    end
    G.C_CurveUtil.EvaluateColorFromBoolean = G.C_CurveUtil.EvaluateColorValueFromBoolean

    G.C_StringUtil = G.C_StringUtil or {}
    G.C_StringUtil.CreateNumericRuleFormatter = newNumericRuleFormatter

    -- A channelled spell's duration: the player's channel, when there is one (none in the simulated world otherwise)
    -- (a cast's or channel's info: its start and end in milliseconds, the 4th and 5th values)
    local function spanOf(info, unit)
        if not info then
            return nil
        end
        local _, _, _, startMs, endMs = info(unit)
        return startMs, endMs
    end
    G.UnitChannelDuration = function(unit)
        local startMs, endMs = spanOf(G.UnitChannelInfo, unit)
        if not startMs or not endMs then
            return nil
        end
        local duration = newDuration()
        duration:SetTimeSpan(startMs / 1000, endMs / 1000)
        return duration
    end
    G.UnitCastingDuration = G.UnitCastingDuration
        or function(unit)
            local startMs, endMs = spanOf(G.UnitCastingInfo, unit)
            if not startMs or not endMs then
                return nil
            end
            local duration = newDuration()
            duration:SetTimeSpan(startMs / 1000, endMs / 1000)
            return duration
        end

    -- A cooldown from a duration (cleared by a zero one, unless told not to)
    local cooldownMethods = W.types.Cooldown and W.types.Cooldown.methods
    if cooldownMethods then
        cooldownMethods.SetCooldownFromDurationObject = function(self, duration, clearIfZero)
            if not durations.isDuration(duration) or (duration:IsZero() and clearIfZero ~= false) then
                self:Clear()
                return
            end
            self:SetCooldown(duration.start, duration.length, duration.modRate)
        end
    end

    -- A status bar on a timer: its value the time gone (or left) of the duration, as it goes; drawn each frame while
    -- it runs (sim.liveVisuals)
    local statusMethods = W.types.StatusBar and W.types.StatusBar.methods
    if statusMethods then
        local function timerValue(s)
            local timer = s.timer
            if not timer then
                return nil
            end
            local duration = timer.duration
            return timer.isRemaining and duration:GetRemainingDuration() or duration:GetElapsedDuration()
        end
        W.statusBarTimerValue = function(bar)
            return timerValue(W.state[bar] or {})
        end
        statusMethods.SetTimerDuration = function(self, duration, _, direction)
            local s = W.state[self]
            if not durations.isDuration(duration) then
                s.timer = nil
                if sim.liveVisuals then
                    sim.liveVisuals[self] = nil
                end
                sim.touchVisual(self)
                return
            end
            local isRemaining = direction == 1
                or (
                    G.Enum
                    and G.Enum.StatusBarTimerDirection
                    and direction == G.Enum.StatusBarTimerDirection.RemainingTime
                )
            s.timer = { duration = duration:Copy(), isRemaining = isRemaining }
            sim.liveVisuals = sim.liveVisuals or setmetatable({}, { __mode = "k" })
            sim.liveVisuals[self] = true
            sim.touchVisual(self) -- (the bar is a timer's now: the native walk draws it at every frame)
        end
        statusMethods.GetTimerDuration = function(self)
            local timer = W.state[self].timer
            return timer and timer.duration:Copy() or newDuration()
        end
        statusMethods.ClearTimerDuration = function(self)
            W.state[self].timer = nil
            if sim.liveVisuals then
                sim.liveVisuals[self] = nil
            end
            sim.touchVisual(self)
        end
        -- (its value read: the timer's while one runs)
        local getValue = statusMethods.GetValue
        statusMethods.GetValue = function(self, ...)
            local live = timerValue(W.state[self])
            if live then
                return live
            end
            return getValue(self, ...)
        end
        statusMethods.GetInterpolatedValue = function(self)
            return self:GetValue()
        end
        statusMethods.IsInterpolating = function()
            return false
        end
        statusMethods.SetToTargetValue = function() end
        -- (a value set by hand ends the timer, as in the client)
        local setValue = statusMethods.SetValue
        statusMethods.SetValue = function(self, ...)
            local s = W.state[self]
            if s.timer then
                s.timer = nil
                if sim.liveVisuals then
                    sim.liveVisuals[self] = nil
                end
                sim.touchVisual(self)
            end
            return setValue(self, ...)
        end
    end
end

return durations
