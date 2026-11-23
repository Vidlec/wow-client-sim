-- How the world map's zoom moves, frame by frame. The game's world map zooms at once: Blizzard_WorldMap.lua's OnLoad
-- calls SetShouldZoomInstantly(true), so ZoomIn sets the level's scale in one step (InstantPanAndZoom) and the map tells
-- OnCanvasScaleChanged once. A map canvas that does not zoom instantly (an addon's SetShouldZoomInstantly(false))
-- glides: MapCanvasScrollControllerMixin:OnUpdate eases the scale toward the level's each frame (FrameDeltaLerp, by
-- the frame's GetTickTime) and tells the map at every step, so marks an addon keeps the same size on screen must follow
-- each step. Both the game's map (the whole interface) and the simulator's stand-in do this.
setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
wait(0.5)
key("M")
wait(0.5)
local map = G.WorldMapFrame
local container = map.ScrollContainer
local canvas = map:GetCanvas()
expect(map:ShouldZoomInstantly() == true, "the game's world map zooms instantly")
expect(G.GetTickTime() > 0, "GetTickTime is the last frame's length: " .. tostring(G.GetTickTime()))

-- A mark on the canvas that keeps its size on screen, as addons draw theirs: scaled against the canvas at each change
local mark = G.CreateFrame("Frame", nil, canvas)
mark:SetSize(20, 20)
mark:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() / 2, -canvas:GetHeight() / 2)
local steps, worstSize = {}, 0
local function follow()
    local scale = map:GetCanvasScale()
    mark:SetScale(1 / scale)
    steps[#steps + 1] = scale
    local onScreen = mark:GetWidth() * mark:GetEffectiveScale()
    worstSize = math.max(worstSize, math.abs(onScreen - 20 * canvas:GetEffectiveScale() / scale))
end
G.hooksecurefunc(map, "OnCanvasScaleChanged", follow)
local providerSteps = 0
-- (made as the game's providers are, from its mixin where the game's map code is loaded)
local provider = G.MapCanvasDataProviderMixin and G.CreateFromMixins(G.MapCanvasDataProviderMixin) or {}
provider.OnCanvasScaleChanged = function() providerSteps = providerSteps + 1 end
map:AddDataProvider(provider)
local outScale = map:GetCanvasScale()
follow(); steps = {}
local markScreenWidth = mark:GetWidth() * mark:GetEffectiveScale()

-- At once
container:ZoomIn()
local instantTarget = map:GetCanvasScale()
wait(1)
expect(instantTarget > outScale, string.format("zoomed in at once: %.3f -> %.3f", outScale, instantTarget))
expect(#steps == 1, "told once: " .. #steps)

-- Gliding
map:ResetZoom()
wait(0.2)
map:SetShouldZoomInstantly(false)
steps, providerSteps, worstSize = {}, 0, 0
local perFrame = {}
local ticker = G.CreateFrame("Frame")
ticker:SetScript("OnUpdate", function() perFrame[#perFrame + 1] = map:GetCanvasScale() end)
container:ZoomIn()
wait(2)
ticker:SetScript("OnUpdate", nil)
local intermediate, isRising = 0, true
for index, scale in ipairs(steps) do
    if scale > outScale + 0.0001 and scale < instantTarget - 0.0001 then intermediate = intermediate + 1 end
    if index > 1 and scale < steps[index - 1] then isRising = false end
end
io.write(string.format("GLIDE %d steps: %s\n", #steps, table.concat((function()
    local shown = {}
    for index = 1, math.min(#steps, 8) do shown[index] = string.format("%.4f", steps[index]) end
    return shown
end)(), ", ")))
expect(intermediate >= 5, "the scale passes through the scales between (" .. intermediate .. " steps between)")
expect(isRising, "rising all the way")
expect(math.abs(map:GetCanvasScale() - instantTarget) < 0.0001, string.format("and ends on the level's scale (%.4f)", map:GetCanvasScale()))
expect(providerSteps == #steps, string.format("a data provider hears each step (%d of %d)", providerSteps, #steps))
expect(#perFrame >= #steps and #steps >= 5, "a step a frame while it glides")
expect(worstSize < 0.01, string.format("the mark kept its size on screen at every step (worst %.4f)", worstSize))
expect(math.abs(mark:GetWidth() * mark:GetEffectiveScale() - markScreenWidth) < 0.01, "as big as before the zoom")
expect(not (map.ScrollContainer.IsZoomingIn and map.ScrollContainer:IsZoomingIn()) and not map:IsZoomingIn(), "the glide is over")

map:SetShouldZoomInstantly(true)
map:RemoveDataProvider(provider)
