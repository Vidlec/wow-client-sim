-- Animations drawn as the client draws them: a group's animations change their target over their duration, in order,
-- held at their end while the group plays, gone when it stops. Alpha (with setToFinalAlpha), Translation (carrying a
-- frame's regions along), Scale and Rotation about the origin, TextureCoordTranslation, FlipBook, VertexColor; from Lua
-- and from XML.
local sceneModule = require("scene")

-- The exported item of a texture, found by its colour (each test texture has its own)
local function itemOf(red)
    for _, item in ipairs(sceneModule.export()) do
        if item.k == "t" and item.c and math.abs((item.c[1] or 0) - red) < 0.001 then
            return item
        end
    end
end
local function near(value, wanted, slack)
    return value ~= nil and math.abs(value - wanted) <= (slack or 0.6)
end

local holder = G.CreateFrame("Frame", "AnimHolder", G.UIParent)
holder:SetSize(100, 100)
holder:SetPoint("CENTER")
local box = holder:CreateTexture()
box:SetAllPoints()
box:SetColorTexture(0.11, 0, 0, 1)
local before = itemOf(0.11)
expect(before ~= nil, "the box is drawn")

-- Alpha: from 1 to 0 over a second; halfway it is half
local fade = holder:CreateAnimationGroup()
local alpha = fade:CreateAnimation("Alpha")
alpha:SetFromAlpha(1)
alpha:SetToAlpha(0)
alpha:SetDuration(1)
fade:Play()
wait(0.5)
local midway = itemOf(0.11)
expect(
    midway and near(midway.a, 0.5, 0.06),
    "halfway through a fade the box is half seen: " .. tostring(midway and midway.a)
)
wait(0.6)
local afterFade = itemOf(0.11)
expect(afterFade and near(afterFade.a, 1, 0.01), "a fade done (no setToFinalAlpha): its own alpha again")
fade:SetToFinalAlpha(true)
fade:Play()
wait(1.1)
expect(holder:GetAlpha() < 0.01 and itemOf(0.11) == nil, "setToFinalAlpha: the alpha it ended at is the frame's")
holder:SetAlpha(1)

-- Translation: the frame's texture carried 40 right and 20 up (y up in the game) over a second
local slide = holder:CreateAnimationGroup()
local move = slide:CreateAnimation("Translation")
move:SetOffset(40, 20)
move:SetDuration(1)
slide:Play()
wait(0.5)
local sliding = itemOf(0.11)
expect(
    sliding
        and near(sliding.x, before.x + 20 * holder:GetEffectiveScale(), 1)
        and near(sliding.y, before.y - 10 * holder:GetEffectiveScale(), 1),
    "halfway through a slide the box is half the way: "
        .. tostring(sliding and sliding.x)
        .. ","
        .. tostring(sliding and sliding.y)
)
slide:Stop()
local stopped = itemOf(0.11)
expect(stopped and stopped.x == before.x and stopped.y == before.y, "a slide stopped: back where it was")

-- Scale (from 1 to 2 about the centre) then, in order 2, Rotation (a quarter turn) on the texture itself
local grow = box:CreateAnimationGroup()
local scale = grow:CreateAnimation("Scale")
scale:SetScaleFrom(1, 1)
scale:SetScaleTo(2, 2)
scale:SetDuration(1)
local turn = grow:CreateAnimation("Rotation")
turn:SetDegrees(90)
turn:SetDuration(1)
turn:SetOrder(2)
grow:Play()
wait(1.05)
local grown = itemOf(0.11)
expect(
    grown and near(grown.w, before.w * 2, 1.5) and near(grown.x + grown.w / 2, before.x + before.w / 2, 1),
    "a scale done holds (order 2 playing): twice the size, about its centre: " .. tostring(grown and grown.w)
)
wait(0.5)
local turning = itemOf(0.11)
expect(
    turning and near(turning.rot, math.pi / 4, 0.12),
    "halfway through a quarter turn: " .. tostring(turning and turning.rot)
)
wait(0.6)
expect(itemOf(0.11).w == before.w and not itemOf(0.11).rot, "the group done: the box as it was")

-- TextureCoordTranslation, FlipBook and VertexColor on a texture with art
local art = holder:CreateTexture()
art:SetSize(32, 32)
art:SetPoint("TOPLEFT")
art:SetTexture("Interface\\Buttons\\WHITE8X8")
art:SetVertexColor(0.33, 1, 1)
local function artItem()
    for _, item in ipairs(sceneModule.export()) do
        if item.k == "t" and item.vc and math.abs(item.vc[1] - 0.33) < 0.01 then
            return item
        end
    end
end
local sheet = art:CreateAnimationGroup()
local flip = sheet:CreateAnimation("FlipBook")
flip:SetFlipBookRows(2)
flip:SetFlipBookColumns(2)
flip:SetFlipBookFrames(4)
flip:SetDuration(1)
sheet:Play()
wait(0.6)
local cell = artItem()
expect(
    cell and cell.tc and near(cell.tc[1], 0, 0.001) and near(cell.tc[3], 0.5, 0.001) and near(cell.tc[2], 0.5, 0.001),
    "a flipbook 0.6 of the way through four cells shows the third (lower left): "
        .. tostring(cell and cell.tc and table.concat(cell.tc, ","))
)
sheet:Stop()
local scroll = art:CreateAnimationGroup()
local uv = scroll:CreateAnimation("TextureCoordTranslation")
uv:SetOffset(1, 0)
uv:SetDuration(1)
local tint = scroll:CreateAnimation("VertexColor")
tint:SetStartColor(G.CreateColor(1, 1, 1, 1))
tint:SetEndColor(G.CreateColor(1, 0, 0, 1))
tint:SetDuration(1)
scroll:Play()
wait(0.5)
local scrolled = artItem()
expect(
    scrolled and scrolled.tc and near(scrolled.tc[1], 0.5, 0.06) and scrolled.vc and near(scrolled.vc[2], 0.5, 0.06),
    "halfway: the art scrolled half across, its green half gone: "
        .. tostring(scrolled and scrolled.tc and scrolled.tc[1])
        .. " "
        .. tostring(scrolled and scrolled.vc and scrolled.vc[2])
)
scroll:Stop()

-- From XML: an Alpha with a startDelay and smoothing, its childKey a texture of the frame
local xmlFrame = G.CreateFrame("Frame", nil, G.UIParent)
xmlFrame:SetSize(50, 50)
xmlFrame:SetPoint("BOTTOMLEFT")
xmlFrame.Glow = xmlFrame:CreateTexture()
xmlFrame.Glow:SetAllPoints()
xmlFrame.Glow:SetColorTexture(0.22, 0, 0, 1)
local group = xmlFrame:CreateAnimationGroup()
local glow = group:CreateAnimation("Alpha")
glow:SetChildKey("Glow")
glow:SetFromAlpha(0)
glow:SetToAlpha(1)
glow:SetStartDelay(0.5)
glow:SetDuration(0.5)
glow:SetSmoothing("IN")
group:Play()
wait(0.25)
expect(itemOf(0.22) and near(itemOf(0.22).a, 1, 0.01), "before its start delay an animation leaves its target be")
wait(0.5)
local glowing = itemOf(0.22)
expect(
    glowing and near(glowing.a, 0.25, 0.08),
    "halfway (smoothing IN: half squared) the glow is a quarter seen: " .. tostring(glowing and glowing.a)
)
expect(group:IsPlaying() and glow:GetTarget() == xmlFrame.Glow, "the animation's target is the child its key names")
