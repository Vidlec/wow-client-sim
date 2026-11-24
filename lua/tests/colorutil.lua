-- C_ColorUtil (lua/colorutil.lua): the colour codes the game's own code writes, and the conversions round trip.
-- Needs nothing of the game: `luajit lua/tests/colorutil.lua` from the repository's root (CI runs it).
package.path = "lua/?.lua;" .. package.path
local colorutil = require("colorutil")

local failures, checks = 0, 0
local function check(isTrue, what)
    checks = checks + 1
    if not isTrue then
        failures = failures + 1
        print("FAIL  " .. what)
    end
end
local function near(a, b)
    return math.abs(a - b) < 1e-6
end

-- The mage's class colour (ChrClasses 63, 199, 235): the code every "|c...Mage|r" carries
local mage = { r = 63 / 255, g = 199 / 255, b = 235 / 255 }
check(colorutil.generateTextColorCode(mage) == "ff3fc7eb", "the mage's code: " .. colorutil.generateTextColorCode(mage))
check(colorutil.generateTextColorCode({ r = 2, g = -1, b = 0.5 }) == "ffff0080", "out of range clamps")
check(colorutil.wrapTextInColor("Mage", mage) == "|cff3fc7ebMage|r", "text wrapped in the colour")
check(colorutil.wrapTextInColorCode("x", "ff112233") == "|cff112233x|r", "text wrapped in a code")
check(not pcall(colorutil.generateTextColorCode, nil), "no colour: refused")

local h, s, v = colorutil.convertRGBToHSV(1, 0, 0)
check(near(h, 0) and near(s, 1) and near(v, 1), "red is hue 0")
h = colorutil.convertRGBToHSV(0, 0, 1)
check(near(h, 240), "blue is hue 240")
for _, rgb in ipairs({ { 0.2, 0.4, 0.6 }, { 1, 1, 1 }, { 0, 0, 0 }, { 0.9, 0.1, 0.5 }, { 0.3, 0.8, 0.1 } }) do
    local r, g, b = colorutil.convertHSVToRGB(colorutil.convertRGBToHSV(rgb[1], rgb[2], rgb[3]))
    check(near(r, rgb[1]) and near(g, rgb[2]) and near(b, rgb[3]), "RGB to HSV and back: " .. table.concat(rgb, ","))
    local hh, ss, vv = colorutil.convertRGBToHSV(rgb[1], rgb[2], rgb[3])
    local h2, s2, v2 = colorutil.convertHSLToHSV(colorutil.convertHSVToHSL(hh, ss, vv))
    check(
        near(h2, hh) and near(v2, vv) and (near(s2, ss) or vv == 0),
        "HSV to HSL and back: " .. table.concat(rgb, ",")
    )
end
local _, _, l = colorutil.convertHSVToHSL(0, 1, 1)
check(near(l, 0.5), "pure red's lightness is a half")

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
