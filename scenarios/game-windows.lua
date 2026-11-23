-- The game's own windows open and close as in the client, with no Lua error (any fails the scenario): each opened
-- as the player opens it, then closed with its X where the game shows one, else Escape. In the gamepad
-- interface the game hides the X on its windows (each one's InitializeGamepad), and B closes them.
-- It caught the professions window loaded without its templates (its X then did nothing), the profession gear
-- slots, class info, the character's stats, the help window's browser and the spellbook's gamepad footer.
local sim = require("sim")

-- Opened as hardware input opens them: securely (a key binding, a micro button)
-- (hidesX: the game hides that window's X in the gamepad interface)
local WINDOWS = {
    { "the character window", "CharacterFrame", function() G.ToggleCharacter("PaperDollFrame") end, hidesX = true },
    { "reputation", "CharacterFrame", function() G.ToggleCharacter("ReputationFrame") end, hidesX = true },
    { "the spellbook", "PlayerSpellsFrame", function() G.PlayerSpellsUtil.ToggleSpellBookFrame() end, hidesX = true },
    { "the professions", "ProfessionsFrame", function() G.ToggleProfessionsBook() end, hidesX = true },
    { "friends", "FriendsFrame", function() G.ToggleFriendsFrame() end },
    -- (its list fills itself in its own OnShow, which the window's OnShow then reads: children first, as measured)
    { "the guild finder", "CommunitiesFrame", function() G.ToggleGuildFrame() end },
    { "collections", "CollectionsJournal", function() G.ToggleCollectionsJournal() end },
    { "macros", "MacroFrame", function() G.ShowMacroFrame() end },
    { "the world map", "WorldMapFrame", function() G.ToggleWorldMap() end, hidesX = true },
    { "the clock", "TimeManagerFrame", function() G.ToggleTimeManager() end },
    { "help", "HelpFrame", function() G.ToggleHelpFrame() end },
}

local function closeButtonOf(frame)
    return frame.CloseButton or G[(frame:GetName() or "") .. "CloseButton"] or (frame.BorderFrame and frame.BorderFrame.CloseButton)
end

local function playWindows(isGamepad)
    local mode = isGamepad and " (gamepad)" or ""
    for _, window in ipairs(WINDOWS) do
        local label, name, open = window[1], window[2], window[3]
        sim.runSecurely(open)
        wait(0.2)
        local frame = G[name]
        expect(frame and frame:IsShown(), label .. " opens" .. mode)
        if frame and frame:IsShown() then
            local close = closeButtonOf(frame)
            if isGamepad then
                if window.hidesX then expect(not (close and close:IsVisible()), label .. ": the gamepad interface hides its X") end
                pad("PAD2")
                wait(0.3)
                expect(not frame:IsShown(), label .. ": B closes it")
            elseif close and close:IsVisible() then
                click(close)
                wait(0.2)
                expect(not frame:IsShown(), label .. ": its X closes it")
            else
                key("ESCAPE")
                wait(0.2)
                expect(not frame:IsShown(), label .. ": Escape closes it")
            end
            if frame:IsShown() then sim.runSecurely(G.HideUIPanel, frame); frame:Hide() end
        end
    end
end

-- Something to wear: the character window shows it in its slots, with the item's own icon
equip(25)   -- Worn Shortsword: the main hand
equip(2362) -- Worn Wooden Shield: the off hand
equip(6125) -- Brawler's Harness: the shirt slot
expect(G.GetInventoryItemID("player", 16) == 25 and G.GetInventoryItemID("player", 17) == 2362, "the weapon and shield go to their hands")
expect(tostring(G.GetInventoryItemLink("player", 16)):find("Worn Shortsword", 1, true), "the slot's link names the item")
sim.runSecurely(G.ToggleCharacter, "PaperDollFrame")
wait(0.2)
expect(G.CharacterMainHandSlot.icon:GetTexture() == G.C_Item.GetItemIconByID(25), "the main hand slot shows the sword's icon")
sim.runSecurely(G.HideUIPanel, G.CharacterFrame)
wait(0.1)

playWindows(false)

-- The character window's stats: worked out from race, class and level, never nothing
local strength = G.UnitStat("player", 1)
expect(type(strength) == "number" and strength > 20, "the character has strength (" .. tostring(strength) .. ")")
expect(G.UnitArmor("player") > 0, "and armor")
expect(type(G.GetCombatRatingBonus(1)) == "number", "a combat rating's bonus is a number")

-- The class and race tables the windows read
expect(G.C_CreatureInfo.GetClassInfo(8).classFile == "MAGE", "class 8 is the mage")
expect(G.GetClassInfo(6) == nil, "no class 6 in this client")
expect(G.C_CreatureInfo.GetRaceInfo(5).clientFileString == "Scourge", "race 5 is the undead")
expect(G.GetFileIDFromPath == nil or G.GetFileIDFromPath("Interface\\Icons\\INV_Misc_QuestionMark") == 134400
    or G.GetFileIDFromPath("Interface\\Icons\\INV_Misc_QuestionMark") == nil, "a path's file ID, where the listfile is there")

gamepadInterface(true)
playWindows(true)
-- (not switched back: the game's spellbook fails as the gamepad interface is left once it was open,
-- Blizzard_PlayerSpellsFrame.lua's Uninit calling SetSearchBoxDefaultPosition on the talents' search box, which
-- has no such method: the client's own bug, which the simulator shows as the client would)
