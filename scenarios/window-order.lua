-- A window shown comes in front of every frame of its strata, as the Forever client raises it: its level unchanged
-- (measured: /asrec probe, levels and raiseOrder), drawn over a frame of a higher level in the same strata (an
-- addon's unit frame: EllesmereUI's player frame drew over the spellbook)
local unitFrame = G.CreateFrame("Frame", "SimHighLevelFrame", G.UIParent)
unitFrame:SetSize(200, 60)
unitFrame:SetPoint("CENTER")
unitFrame:SetFrameStrata("MEDIUM")
unitFrame:SetFrameLevel(50)
require("sim").runSecurely(G.PlayerSpellsUtil.ToggleSpellBookFrame)
wait(0.3)
local book = G.PlayerSpellsFrame
expect(book:IsShown() and book:GetFrameStrata() == "MEDIUM", "the spellbook opens, in the same strata")
expect(book:GetFrameLevel() < 50, "its level not raised past the other: " .. book:GetFrameLevel())
local order = {}
for index, frame in ipairs(require("scene").getSortedFrames()) do
    order[frame] = index
end
expect(order[book] > order[unitFrame], "drawn over the frame of level 50")
local hit = require("scene").findFrameAt(
    (require("widgets").computeRect(unitFrame)[1] + require("widgets").computeRect(unitFrame)[3]) / 2,
    (require("widgets").computeRect(unitFrame)[2] + require("widgets").computeRect(unitFrame)[4]) / 2,
    "click"
)
expect(hit ~= unitFrame, "and takes the mouse over it")
require("sim").runSecurely(G.PlayerSpellsUtil.ToggleSpellBookFrame)
