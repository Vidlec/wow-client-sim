-- The game's windows drawn with their art and in their order: each opened as the player opens it, every shown
-- texture's atlas known (looked up by its element's name, as the client does: the spellbook's page
-- "spellbook-Page-Right-C60", the swing timer's and bag slots' high-resolution-only art), and no frame left at or below
-- its parent's level unless its code put it there (a pooled frame given to a list brings its parts above it: the
-- spellbook's spells over its page, the quest log's entries in the world map). Both drew windows wrong for long.
local sim = require("sim")
local W = require("widgets")

local problems = {}
local function note(text)
    problems[text] = true
end
local function nameOf(object)
    return tostring(object:GetDebugName()):sub(-70)
end
local function audit(window, frame)
    for _, region in ipairs({ frame:GetRegions() }) do
        local atlas = region:IsVisible() and region.GetAtlas and region:GetAtlas()
        if atlas and atlas ~= "" and not G.C_Texture.GetAtlasInfo(atlas) then
            note(window .. ": the atlas " .. atlas .. " is unknown (" .. nameOf(region) .. ")")
        end
    end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:IsVisible() then
            local state = W.state[child]
            local isBelow = child:GetFrameStrata() == frame:GetFrameStrata()
                and child:GetFrameLevel() <= frame:GetFrameLevel()
            if state and not state.levelSet and not state.useParentLevel and isBelow then
                note(window .. ": " .. nameOf(child) .. " is below " .. nameOf(frame))
            end
            audit(window, child)
        end
    end
end

-- Opened as hardware input opens them: securely (a key binding, a micro button)
local WINDOWS = {
    {
        "the character window",
        function()
            G.ToggleCharacter("PaperDollFrame")
        end,
    },
    {
        "reputation",
        function()
            G.ToggleCharacter("ReputationFrame")
        end,
    },
    {
        "the spellbook",
        function()
            G.PlayerSpellsUtil.ToggleSpellBookFrame()
        end,
    },
    {
        "the talents",
        function()
            G.PlayerSpellsUtil.ToggleClassTalentOrSpecFrame()
        end,
    },
    {
        "the professions",
        function()
            G.ToggleProfessionsBook()
        end,
    },
    {
        "friends",
        function()
            G.ToggleFriendsFrame()
        end,
    },
    {
        "the guild finder",
        function()
            G.ToggleGuildFrame()
        end,
    },
    {
        "collections",
        function()
            G.ToggleCollectionsJournal()
        end,
    },
    {
        "macros",
        function()
            G.ShowMacroFrame()
        end,
    },
    {
        "the world map",
        function()
            G.ToggleWorldMap()
        end,
    },
    {
        "the quest log",
        function()
            G.ToggleQuestLog()
        end,
    },
    {
        "the clock",
        function()
            G.ToggleTimeManager()
        end,
    },
    {
        "help",
        function()
            G.ToggleHelpFrame()
        end,
    },
    {
        "the bags",
        function()
            G.OpenAllBags()
        end,
    },
    {
        "the game menu",
        function()
            G.ToggleGameMenu()
        end,
    },
    {
        "achievements",
        function()
            G.ToggleAchievementFrame()
        end,
    },
}

audit("the screen", G.UIParent)
for _, window in ipairs(WINDOWS) do
    sim.runSecurely(window[2])
    wait(0.4)
    audit(window[1], G.UIParent)
    key("ESCAPE")
    G.CloseAllBags()
    wait(0.2)
end
local list = {}
for text in pairs(problems) do
    list[#list + 1] = text
end
table.sort(list)
expect(
    #list == 0,
    "every window's art is known and in its order" .. (#list > 0 and ":\n  " .. table.concat(list, "\n  ") or "")
)
