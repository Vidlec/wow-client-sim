-- C_StringUtil's text functions (lua/stringutil.lua). Needs nothing of the game: `luajit lua/tests/stringutil.lua`
-- from the repository's root (CI runs it).
package.path = "lua/?.lua;" .. package.path
local s = require("stringutil")

local failures, checks = 0, 0
local function check(actual, expected, what)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAIL  %s: %q, not %q", what, tostring(actual), tostring(expected)))
    end
end

check(
    s.escapeDecimalNonPrintables("a\1b\nc\tdé\255"),
    "a\\1b\nc\tdé\\255",
    "control bytes and broken UTF-8 escaped, the rest kept"
)
check(s.escapeDecimalNonPrintables("\127"), "\\127", "DEL escaped")
check(s.escapeLuaFormatString("100% done"), "100%% done", "format tokens")
check(s.escapeLuaPatterns("a.b*c[1]"), "a%.b%*c%[1%]", "pattern characters")
check(("x.y"):find(s.escapeLuaPatterns("."), 1) == 2, true, "an escaped pattern finds the dot itself")
check(s.escapeQuotedCodes("|cffffffffx|r"), "||cffffffffx||r", "quoted codes")
check(s.floorToNearestString(2.9), "2", "floor")
check(s.roundToNearestString(2.5), "3", "round")
check(s.truncateWhenZero(0.7), "", "zero gives nothing")
check(s.truncateWhenZero(12.9), "12", "a whole number")
check(s.removeContiguousSpaces("a     b  c", 2), "a  b  c", "runs of spaces cut")
check(s.wrapString("x", "(", ")"), "(x)", "wrapped")
check(s.wrapString("", "(", ")"), "", "nothing to wrap: nothing")

local link = "|cff71d5ff|Hspell:133:0|h[Fireball]|h|r"
check(s.stripHyperlinks(link), "Fireball", "a link's text")
check(s.stripHyperlinks(link, true, true), "|cff71d5ff[Fireball]|r", "its colour and brackets kept when asked")
check(s.stripHyperlinks("a|nb|TInterface\\Icons\\X:16|tc"), "a|nbc", "textures out, newlines kept")
check(s.stripHyperlinks("a|nb", false, false, true), "ab", "newlines out when asked")
check(
    s.stripHyperlinks("x|A:atlas:16:16|ay", false, false, false, true),
    "x|A:atlas:16:16|ay",
    "atlases kept when asked"
)
check(
    s.stripTextureMarkupForLooseFiles("a|TInterface\\X:16|tb|T136243:16|tc"),
    "ab|T136243:16|tc",
    "loose files out, the game's own kept"
)

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
