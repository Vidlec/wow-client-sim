-- The game's UIPanelScrollFrameTemplate: scrolling moves the scroll bar's thumb down with the content. Its slider
-- names no orientation, and a slider's own is VERTICAL (taken as HORIZONTAL, the thumb moved sideways in the bar's 16
-- pixels: DungeonJournal's lists scrolled with a thumb that stayed put)
local W = require("widgets")
local scroll = G.CreateFrame("ScrollFrame", "SimThumbScroll", G.UIParent, "UIPanelScrollFrameTemplate")
scroll:SetSize(200, 300)
scroll:SetPoint("CENTER")
local child = G.CreateFrame("Frame", nil, scroll)
child:SetSize(200, 1200)
scroll:SetScrollChild(child)
wait(0.2)
local bar = scroll.ScrollBar
local thumb = bar:GetThumbTexture()
expect(bar:GetOrientation() == "VERTICAL", "the scroll bar runs up and down")
local function drawnThumbTop()
    for _, item in ipairs(require("scene").export()) do
        if item.i == W.state[thumb].id then
            return item.y
        end
    end
end
local before = drawnThumbTop()
scroll:GetScript("OnMouseWheel")(scroll, -1)
wait(0.2)
local after = drawnThumbTop()
expect(scroll:GetVerticalScroll() > 0, "the content scrolled")
expect(
    before and after and after > before + 10,
    "the thumb moved down (" .. tostring(before) .. " to " .. tostring(after) .. ")"
)
-- At the end, the thumb at the bar's bottom
scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
wait(0.2)
local barRect = W.computeRect(bar)
local bottom = drawnThumbTop()
expect(bottom and bottom > after, "further down at the end")
expect(
    barRect and bottom and math.abs((bottom + W.state[thumb].height) - (G.UIParent:GetHeight() - barRect[2])) < 2,
    "at the bar's bottom"
)
-- A horizontal one (the game's slider template says so) keeps running sideways
local slider = G.CreateFrame("Slider", nil, G.UIParent, "UISliderTemplate")
expect(slider:GetOrientation() == "HORIZONTAL", "a template's HORIZONTAL is kept")
local bare = G.CreateFrame("StatusBar", nil, G.UIParent)
expect(bare:GetOrientation() == "HORIZONTAL", "a status bar runs sideways by default")
