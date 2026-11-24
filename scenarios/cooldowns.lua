-- What sweeps and fills as the client draws it: a cooldown's swipe over the time still to run (clockwise from the top;
-- reversed, over the time gone) and its OnCooldownDone; a texture's radial progress bar; a status bar's texture cropped
-- to the part filled, from the left, the right (SetReverseFill, REVERSE) or the middle (CENTER).
local sceneModule = require("scene")

local function exported(test)
    for _, item in ipairs(sceneModule.export()) do
        if test(item) then
            return item
        end
    end
end

local button = G.CreateFrame("Frame", "CooldownHolder", G.UIParent)
button:SetSize(40, 40)
button:SetPoint("CENTER")
local cooldown = G.CreateFrame("Cooldown", nil, button)
cooldown:SetAllPoints()
local isDone = false
cooldown:SetScript("OnCooldownDone", function()
    isDone = true
end)
cooldown:SetCooldown(G.GetTime(), 4)
wait(1)
local swipe = exported(function(item)
    return item.pie and item.c
end)
expect(
    swipe and math.abs(swipe.pie[1] - 0.25) < 0.02 and swipe.pie[2] == 1,
    "a quarter of the way through, the swipe covers the three quarters left: "
        .. tostring(swipe and swipe.pie and table.concat(swipe.pie, ","))
)
expect(swipe and swipe.c[4] == 0.8, "in the default swipe colour (black, 0.8)")
cooldown:SetReverse(true)
swipe = exported(function(item)
    return item.pie and item.c
end)
expect(swipe and swipe.pie[1] == 0 and math.abs(swipe.pie[2] - 0.25) < 0.02, "reversed: over the time gone")
G.SetCVar("countdownForCooldowns", "1")
local number = exported(function(item)
    return item.k == "s" and item.lines[1] == "3"
end)
expect(number ~= nil, "with countdownForCooldowns on, the seconds left are shown: 3")
G.SetCVar("countdownForCooldowns", "0")
wait(3.2)
expect(isDone, "OnCooldownDone when it runs out")
expect(exported(function(item)
    return item.pie and item.c
end) == nil, "and the swipe is gone")

-- A radial progress bar: 40% from the top, clockwise
local ring = button:CreateTexture()
ring:SetAllPoints()
ring:SetColorTexture(0.44, 0, 0, 1)
ring:SetRadialProgressBarPercent(0.4)
local arc = exported(function(item)
    return item.c and math.abs((item.c[1] or 0) - 0.44) < 0.001
end)
expect(
    arc and arc.pie and arc.pie[1] == 0 and math.abs(arc.pie[2] - 0.4) < 0.001,
    "a radial bar at 40% shows 0.4 of a turn"
)
ring:SetRadialProgressBarReverse(true)
arc = exported(function(item)
    return item.c and math.abs((item.c[1] or 0) - 0.44) < 0.001
end)
expect(arc and math.abs(arc.pie[1] - 0.6) < 0.001 and arc.pie[2] == 1, "reversed: counter-clockwise from the top")
ring:SetRadialProgressBarPercent(0)
expect(exported(function(item)
    return item.c and math.abs((item.c[1] or 0) - 0.44) < 0.001
end) == nil, "at 0% nothing is drawn")

-- A status bar's texture: cropped to the part filled
local bar = G.CreateFrame("StatusBar", nil, G.UIParent)
bar:SetSize(100, 10)
bar:SetPoint("TOP")
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 100)
bar:SetValue(25)
local function barItem()
    return exported(function(item)
        return item.k == "t" and item.i == require("widgets").state[bar:GetStatusBarTexture()].id
    end)
end
local filled = barItem()
expect(
    filled and math.abs(filled.w - 25 * bar:GetEffectiveScale()) <= 1 and filled.tc and filled.tc[2] == 0.25,
    "a quarter filled: a quarter as wide, its texture cropped (not squeezed): "
        .. tostring(filled and filled.w)
        .. " "
        .. tostring(filled and filled.tc and filled.tc[2])
)
bar:SetReverseFill(true)
filled = barItem()
expect(filled and filled.tc[1] == 0.75 and filled.tc[2] == 1, "reversed: from the right, the texture's right part")
bar:SetReverseFill(false)
bar:SetFillStyle("CENTER")
filled = barItem()
expect(filled and filled.tc[1] == 0.375 and filled.tc[2] == 0.625, "CENTER: out from the middle")
expect(bar:GetFillStyle() == 2, "GetFillStyle: the enumeration's number (CENTER is 2)")
