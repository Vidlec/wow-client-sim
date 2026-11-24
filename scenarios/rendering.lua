-- What the client draws beyond plain textures, as the scene carries it to the page: a texture partly greyed
-- (SetDesaturation), nine-sliced in tiled mode, read past its edges by its wrap modes (REPEAT, MIRROR,
-- CLAMPTOBLACKADDITIVE, CLAMPTOWHITE); text with a coloured shadow, faded by SetAlphaGradient, MONOCHROME; a flattened
-- frame (its regions drawn as one, at its alpha); a cooldown's edge and, as it runs out, its bling.
local sceneModule = require("scene")
local W = require("widgets")

local function itemOf(region)
    local id = W.state[region].id
    for _, item in ipairs(sceneModule.export()) do
        if item.i == id then
            return item
        end
    end
end
local ICON = "Interface/Icons/INV_Misc_QuestionMark"

local board = G.CreateFrame("Frame", "RenderingBoard", G.UIParent)
board:SetSize(600, 300)
board:SetPoint("CENTER")
local function place(region, x, y, w, h)
    region:SetSize(w, h)
    region:SetPoint("TOPLEFT", board, "TOPLEFT", x, -y)
end

-- Greyed partly, and wholly
local half = board:CreateTexture()
place(half, 0, 0, 48, 48)
half:SetTexture(ICON)
half:SetDesaturation(0.5)
expect(itemOf(half).ds == 0.5, "SetDesaturation(0.5): half greyed: " .. tostring(itemOf(half).ds))
local whole = board:CreateTexture()
place(whole, 52, 0, 48, 48)
whole:SetTexture(ICON)
whole:SetDesaturation(1)
expect(itemOf(whole).ds == true, "SetDesaturation(1): wholly greyed")

-- Wrap modes: the icon twice across each way
local wraps = { "REPEAT", "MIRROR", "CLAMPTOBLACKADDITIVE", "CLAMPTOWHITE" }
local codes = { REPEAT = "rr", MIRROR = "mm", CLAMPTOBLACKADDITIVE = "bb", CLAMPTOWHITE = "ww" }
for index, mode in ipairs(wraps) do
    local texture = board:CreateTexture()
    place(texture, 110 + (index - 1) * 52, 0, 48, 48)
    texture:SetTexture(ICON, mode, mode)
    texture:SetTexCoord(0, 2, 0, 2)
    expect(itemOf(texture).wr == codes[mode], mode .. " is carried: " .. tostring(itemOf(texture).wr))
end
local clamped = board:CreateTexture()
place(clamped, 318, 0, 48, 48)
clamped:SetTexture(ICON)
clamped:SetTexCoord(0, 2, 0, 2)
expect(itemOf(clamped).wr == nil, "no wrap modes: clamped (the client's default)")

-- Nine-sliced, tiled
local tiled = board:CreateTexture()
place(tiled, 0, 60, 200, 60)
tiled:SetTexture(ICON)
tiled:SetTextureSliceMargins(16, 16, 16, 16)
tiled:SetTextureSliceMode(1)
expect(itemOf(tiled).slm == 1, "tiled slices are carried")

-- Text: a red shadow, faded from its 5th character over 30 units, MONOCHROME
local shadowed = board:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
shadowed:SetPoint("TOPLEFT", board, "TOPLEFT", 210, -60)
shadowed:SetText("Red shadow")
shadowed:SetShadowOffset(2, -2)
shadowed:SetShadowColor(1, 0, 0, 1)
local shadowItem = itemOf(shadowed)
expect(shadowItem.shc and shadowItem.shc[1] == 1 and shadowItem.shc[2] == 0, "the shadow's colour is carried")
local faded = board:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
faded:SetPoint("TOPLEFT", board, "TOPLEFT", 210, -85)
faded:SetText("Fading out slowly")
faded:SetAlphaGradient(5, 30)
expect(itemOf(faded).ag and itemOf(faded).ag[1] == 5, "the alpha gradient is carried")
local mono = board:CreateFontString(nil, "OVERLAY")
mono:SetFont("Fonts\\FRIZQT__.TTF", 14, "MONOCHROME")
mono:SetPoint("TOPLEFT", board, "TOPLEFT", 210, -110)
mono:SetText("Monochrome")
expect(itemOf(mono).fl == "MONOCHROME", "MONOCHROME is carried")

-- A flattened frame at half alpha: its two overlapping squares drawn as one
local flat = G.CreateFrame("Frame", nil, board)
flat:SetSize(80, 60)
flat:SetPoint("TOPLEFT", board, "TOPLEFT", 400, -60)
flat:SetAlpha(0.5)
flat:SetFlattensRenderLayers(true)
local back = flat:CreateTexture(nil, "BACKGROUND")
back:SetPoint("TOPLEFT")
back:SetSize(50, 50)
back:SetColorTexture(0, 0.4, 1, 1)
local front = flat:CreateTexture(nil, "ARTWORK")
front:SetPoint("BOTTOMRIGHT")
front:SetSize(50, 50)
front:SetColorTexture(1, 0.8, 0, 1)
local frontItem = itemOf(front)
expect(
    frontItem.fg ~= nil and frontItem.fa == 0.5 and frontItem.a == 1,
    "a flattened frame's regions: drawn whole, the layer at its alpha"
)

-- A cooldown with its edge, then its bling as it runs out
local button = G.CreateFrame("Frame", nil, board)
button:SetSize(48, 48)
button:SetPoint("TOPLEFT", board, "TOPLEFT", 500, -60)
local icon = button:CreateTexture()
icon:SetAllPoints()
icon:SetTexture(ICON)
local cooldown = G.CreateFrame("Cooldown", nil, button)
cooldown:SetAllPoints()
cooldown:SetDrawEdge(true)
cooldown:SetEdgeColor(1, 1, 0, 1)
cooldown:SetCooldown(G.GetTime(), 2)
wait(0.5)
local edge
for _, item in ipairs(sceneModule.export()) do
    if item.k == "t" and item.tex == "Interface\\Cooldown\\edge" then
        edge = item
    end
end
expect(
    edge and edge.vc and edge.vc[3] == 0 and math.abs(edge.rot + math.pi / 2) < 0.05,
    "the edge drawn in its colour, turned a quarter with the sweep: " .. tostring(edge and edge.rot)
)
saveScene("all")
wait(1.55)
local bling
for _, item in ipairs(sceneModule.export()) do
    if item.k == "t" and item.tex == "Interface\\Cooldown\\star4" then
        bling = item
    end
end
expect(bling ~= nil and bling.bl == "ADD", "as it runs out, the bling flashes")
wait(0.5)
bling = nil
for _, item in ipairs(sceneModule.export()) do
    if item.k == "t" and item.tex == "Interface\\Cooldown\\star4" then
        bling = item
    end
end
expect(bling == nil, "and is gone a moment later")
