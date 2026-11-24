-- Smoke test: with the world map and an addon's window open (the fixture's), hover every visible thing that reacts
-- to the mouse. Fails on any Lua error, and on a tooltip whose text spills out of its box.
local W = require("widgets")
local S = W.state

setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1421, 0.45, 0.45) -- Silverpine Forest
wait(0.5)
key("M")
wait(0.5)
slash("/simfixture")
wait(0.3)

local function isInside(inner, outer)
    local left, bottom, width, height = inner:GetRect()
    local outerLeft, outerBottom, outerWidth, outerHeight = outer:GetRect()
    if not left or not outerLeft then
        return true
    end
    local slack = 1
    return left >= outerLeft - slack
        and bottom >= outerBottom - slack
        and left + width <= outerLeft + outerWidth + slack
        and bottom + height <= outerBottom + outerHeight + slack
end

local function checkTooltip(label)
    local tooltip = G.GameTooltip
    if not tooltip:IsVisible() then
        return
    end
    for index = 1, tooltip:NumLines() do
        for _, side in ipairs({ "Left", "Right" }) do
            local line = G["GameTooltipText" .. side .. index]
            if line and line:IsVisible() and (line:GetText() or "") ~= "" then
                expect(
                    isInside(line, tooltip),
                    "tooltip text inside its box when hovering " .. label .. ": " .. line:GetText()
                )
            end
        end
    end
end

local function hoverAll(label)
    local targets = {}
    for _, frame in ipairs(W.frames) do
        local s = S[frame]
        if
            s.mouse
            and (s.scripts.OnEnter or (s.intrinsicScripts and s.intrinsicScripts.OnEnter))
            and W.isVisible(frame)
        then
            local left, bottom, width, height = frame:GetRect()
            if left and width > 2 and height > 2 then
                targets[#targets + 1] = { x = left + width / 2, y = G.GetScreenHeight() - (bottom + height / 2) }
            end
        end
    end
    for _, target in ipairs(targets) do
        hover(target)
        checkTooltip(label .. " at " .. math.floor(target.x) .. "," .. math.floor(target.y))
    end
    return #targets
end

local count = hoverAll("the map and the window")
expect(count > 20, "found things to hover (" .. count .. ")")
click("Line 3")
wait(0.2)
wheel("SimFixtureWindow", -1)
hoverAll("the window scrolled")
key("M")
wait(0.3)
hoverAll("the map closed")
hover({ x = 5, y = 760 })
