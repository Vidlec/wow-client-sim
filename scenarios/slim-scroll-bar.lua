-- The game's slim scroll bar on a plain scroll frame, as addons build it: a ScrollFrame, a "MinimalScrollBar"
-- EventFrame, ScrollUtil.InitScrollFrameWithScrollBar. The client measures the scroll range from the scroll child's
-- laid-out height and tells the frame (OnScrollRangeChanged) at the next layout; the bar's thumb follows the scroll
-- (SetScrollPercentage) and its size the part on show (SetVisibleExtentPercentage); dragging the bar scrolls the frame
-- (its OnScroll callback); SetHideIfUnscrollable(true) hides it when nothing is left to scroll.
local W = require("widgets")
local holder = G.CreateFrame("Frame", "SlimScrollHolder", G.UIParent)
holder:SetSize(220, 200)
holder:SetPoint("CENTER")
local frame = G.CreateFrame("ScrollFrame", nil, holder)
frame:SetPoint("TOPLEFT", 0, 0)
frame:SetPoint("BOTTOMRIGHT", -16, 0)
local child = G.CreateFrame("Frame", nil, frame)
child:SetSize(200, 600)
frame:SetScrollChild(child)
local bar = G.CreateFrame("EventFrame", nil, holder, "MinimalScrollBar")
bar:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 4, 0)
G.ScrollUtil.InitScrollFrameWithScrollBar(frame, bar)
bar:SetHideIfUnscrollable(true)
wait(0.1)

expect(frame:GetVerticalScrollRange() == 400, "the range is the child's height less the frame's: " .. frame:GetVerticalScrollRange())
expect(bar:IsShown(), "the bar shows while there is something to scroll")
expect(math.abs(bar:GetVisibleExtentPercentage() - 200 / 600) < 0.001,
    "the thumb's share is the part on show: " .. tostring(bar:GetVisibleExtentPercentage()))
local thumb = bar:GetThumb()
local track = bar:GetTrack()
local function thumbTop() return track:GetTop() - thumb:GetTop() end
local function thumbBottomGap() return thumb:GetBottom() - track:GetBottom() end
expect(thumbTop() < 0.5, "the thumb starts at the top: " .. thumbTop())
expect(math.abs(thumb:GetHeight() - track:GetHeight() * 200 / 600) < 1,
    string.format("its height a third of the track: %.1f of %.1f", thumb:GetHeight(), track:GetHeight()))

-- Scrolled to the end by the addon: the bar follows (OnVerticalScroll)
frame:SetVerticalScroll(frame:GetVerticalScrollRange())
wait(0.1)
expect(math.abs(bar:GetScrollPercentage() - 1) < 0.001, "scrolled to the end, the bar is at 1: " .. bar:GetScrollPercentage())
expect(math.abs(thumbBottomGap()) < 0.5, "the thumb at the end of its track: " .. thumbBottomGap())

-- Moved by the bar: the frame follows (the bar's OnScroll callback)
bar:SetScrollPercentage(0.5)
wait(0.1)
expect(math.abs(frame:GetVerticalScroll() - 200) < 0.5, "half way on the bar scrolls the frame half way: " .. frame:GetVerticalScroll())
expect(math.abs(child:GetTop() - (frame:GetTop() + 200)) < 0.5, "the child moved up by the scroll")

-- The wheel steps the bar, which scrolls the frame
local before = frame:GetVerticalScroll()
wheel(frame, -1)
wait(0.5)
expect(frame:GetVerticalScroll() > before, string.format("the wheel down scrolls on: %.1f -> %.1f", before, frame:GetVerticalScroll()))

-- The child shrinks to fit: nothing to scroll, the bar hides at the next layout
child:SetHeight(150)
wait(0.1)
expect(frame:GetVerticalScrollRange() == 0, "nothing left to scroll")
expect(not bar:IsShown(), "the bar hides when nothing is left to scroll")
child:SetHeight(500)
wait(0.1)
expect(bar:IsShown(), "and shows again when the child grows")
expect(math.abs(bar:GetVisibleExtentPercentage() - 200 / 500) < 0.001, "with the thumb's share measured again")
