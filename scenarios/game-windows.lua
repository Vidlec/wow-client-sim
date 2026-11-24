-- The game's own windows open and close as in the client, with no Lua error (any fails the scenario): each opened
-- as the player opens it, then closed with its X where the game shows one, else Escape. In the gamepad
-- interface the game hides the X on its windows (each one's InitializeGamepad), and B closes them.
-- It caught the professions window loaded without its templates (its X then did nothing), the profession gear
-- slots, class info, the character's stats, the help window's browser and the spellbook's gamepad footer.
local sim = require("sim")

-- Opened as hardware input opens them: securely (a key binding, a micro button)
-- (hidesX: the game hides that window's X in the gamepad interface)
local WINDOWS = {
    {
        "the character window",
        "CharacterFrame",
        function()
            G.ToggleCharacter("PaperDollFrame")
        end,
        hidesX = true,
    },
    {
        "reputation",
        "CharacterFrame",
        function()
            G.ToggleCharacter("ReputationFrame")
        end,
        hidesX = true,
    },
    {
        "the spellbook",
        "PlayerSpellsFrame",
        function()
            G.PlayerSpellsUtil.ToggleSpellBookFrame()
        end,
        hidesX = true,
    },
    {
        "the professions",
        "ProfessionsFrame",
        function()
            G.ToggleProfessionsBook()
        end,
        hidesX = true,
    },
    -- (in Forever the friends key opens the social window: C_SocialUI.IsSystemEnabled, measured by /asrec probe)
    {
        "friends",
        "SocialUIFrame",
        function()
            G.ToggleFriendsFrame()
        end,
    },
    -- (its list fills itself in its own OnShow, which the window's OnShow then reads: children first, as measured)
    {
        "the guild finder",
        "CommunitiesFrame",
        function()
            G.ToggleGuildFrame()
        end,
    },
    {
        "collections",
        "CollectionsJournal",
        function()
            G.ToggleCollectionsJournal()
        end,
    },
    {
        "macros",
        "MacroFrame",
        function()
            G.ShowMacroFrame()
        end,
    },
    {
        "the world map",
        "WorldMapFrame",
        function()
            G.ToggleWorldMap()
        end,
        hidesX = true,
    },
    {
        "the clock",
        "TimeManagerFrame",
        function()
            G.ToggleTimeManager()
        end,
    },
    {
        "help",
        "HelpFrame",
        function()
            G.ToggleHelpFrame()
        end,
    },
}

local function closeButtonOf(frame)
    return frame.CloseButton
        or G[(frame:GetName() or "") .. "CloseButton"]
        or (frame.BorderFrame and frame.BorderFrame.CloseButton)
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
                if window.hidesX then
                    expect(not (close and close:IsVisible()), label .. ": the gamepad interface hides its X")
                end
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
            if frame:IsShown() then
                sim.runSecurely(G.HideUIPanel, frame)
                frame:Hide()
            end
        end
    end
end

-- Something to wear: the character window shows it in its slots, with the item's own icon
equip(25) -- Worn Shortsword: the main hand
equip(2362) -- Worn Wooden Shield: the off hand
equip(6125) -- Brawler's Harness: the shirt slot
expect(
    G.GetInventoryItemID("player", 16) == 25 and G.GetInventoryItemID("player", 17) == 2362,
    "the weapon and shield go to their hands"
)
expect(
    tostring(G.GetInventoryItemLink("player", 16)):find("Worn Shortsword", 1, true),
    "the slot's link names the item"
)
sim.runSecurely(G.ToggleCharacter, "PaperDollFrame")
wait(0.2)
expect(
    G.CharacterMainHandSlot.icon:GetTexture() == G.C_Item.GetItemIconByID(25),
    "the main hand slot shows the sword's icon"
)
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
expect(
    G.GetFileIDFromPath == nil
        or G.GetFileIDFromPath("Interface\\Icons\\INV_Misc_QuestionMark") == 134400
        or G.GetFileIDFromPath("Interface\\Icons\\INV_Misc_QuestionMark") == nil,
    "a path's file ID, where the listfile is there"
)

-- What wowless's stand-ins answered with its own test values: a character at rest has no vote under way (its window
-- stood on the screen), its faction's language, no spell haste; the key bindings window lists the game's bindings
expect(not G.InstanceAbandonPopup:IsShown(), "no instance abandon vote at rest")
expect(
    select(1, G.GetDefaultLanguage()) == "Orcish" and G.UnitSpellHaste("player") == 0,
    "a Horde character speaks Orcish, no haste"
)
local bindingCount, forwardKey = G.GetNumBindings(), nil
for index = 1, bindingCount do
    local command, _, key = G.GetBinding(index)
    if command == "MOVEFORWARD" then
        forwardKey = key
    end
end
expect(bindingCount > 100, "the game's key bindings are listed (" .. bindingCount .. ")")
expect(forwardKey ~= nil, "with their keys (move forward: " .. tostring(forwardKey) .. ")")

-- The item qualities' colours (C_ColorOverrides: every item was white) and the string utilities (C_StringUtil: an
-- error's message, a link stripped to its text)
expect(
    G.ITEM_QUALITY_COLORS[4].hex == "|cffa335ee" and G.ITEM_QUALITY_COLORS[3].hex == "|cff0070dd",
    "epic purple, rare blue"
)
expect(
    G.C_StringUtil.StripHyperlinks("|cff71d5ff|Hspell:133:0|h[Fireball]|h|r") == "Fireball",
    "a link stripped to its text"
)
expect(G.GetModifiedClick("AUTOLOOTTOGGLE") == "SHIFT", "auto loot on Shift, as the game's bindings say")
-- The options window (its Controls page shows key bindings by their index, C_KeyBindings.GetBindingIndex)
sim.runSecurely(function()
    G.SettingsPanel:Open()
end)
wait(0.3)
expect(G.SettingsPanel:IsShown() and not G.ScriptErrorsFrame:IsShown(), "the options open, with no error")
sim.runSecurely(function()
    G.HideUIPanel(G.SettingsPanel)
end)
wait(0.1)

-- Menus: a unit frame's right-click opens its menu (the secure button asks C_ClickBindings, then runs its
-- "menu-function" attribute: ExecuteAttribute), and a press anywhere outside it closes it (GLOBAL_MOUSE_DOWN), as Esc does
local menus = G.Menu.GetManager()
click(G.PlayerFrame, "RightButton")
wait(0.2)
expect(menus:IsAnyMenuOpen(), "right-clicking the player frame opens its menu")
click({ x = 700, y = 300 })
wait(0.2)
expect(not menus:IsAnyMenuOpen(), "a click outside closes it")
click(G.PlayerFrame, "RightButton")
wait(0.2)
key("ESCAPE")
wait(0.2)
expect(not menus:IsAnyMenuOpen(), "and Escape")

-- A button's font objects are objects, its XML naming them or not (an addon copies one: CopyFontObject, GetFont)
local panelButton = G.CreateFrame("Button", nil, G.UIParent, "UIPanelButtonTemplate")
local normalFont = panelButton:GetNormalFontObject()
expect(
    type(normalFont) == "table" and normalFont:GetFont() ~= nil,
    "a button's normal font object, set by its XML by name, is the font object"
)

-- The bags (lua/bags.lua): the backpack's 16 slots hold what was looted, in stacks of the item's size; bag 1 is
-- equipment slot 31 (Syndicator counts the slots below it)
loot(4865, 7) -- Ruined Pelt, stacks of 5
local container = G.C_Container
expect(
    container.GetContainerNumSlots(0) == 16 and container.GetContainerNumSlots(1) == 0,
    "the backpack: 16 slots, no bag in slot 1"
)
local first, second = container.GetContainerItemInfo(0, 1), container.GetContainerItemInfo(0, 2)
expect(
    first and first.itemID == 4865 and first.stackCount == 5 and second and second.stackCount == 2,
    "seven pelts: a stack of 5 and one of 2"
)
expect(container.ContainerIDToInventoryID(1) == 31, "bag 1 is equipment slot 31")
-- A map's size in the world (HereBeDragons measures every map by it: TomTom's arrow, Questie's marks)
local mapWidth, mapHeight = G.C_Map.GetMapWorldSize(1413)
expect(
    math.floor(mapWidth) == 10133 and math.floor(mapHeight) == 6756,
    "The Barrens: 10133 x 6756 yards (" .. mapWidth .. ")"
)
-- An error an addon catches itself and hands to the game's handler is reported too (xpcall(fn, geterrorhandler()))
local errorsBefore = #sim.errors
xpcall(function()
    error("handed on")
end, G.geterrorhandler())
expect(#sim.errors == errorsBefore + 1, "an error handed to geterrorhandler() is reported")
sim.errors[#sim.errors] = nil -- (the scenario's own: not a failure)
-- What popular addons (DBM, EllesmereUI, LibSharedMedia) need of the client
local fileAsset = G.C_UIFileAsset
expect(
    fileAsset.IsKnownFile("Interface\\AddOns\\SimFixture\\media\\beep.wav")
        and fileAsset.IsKnownFile("Interface\\Icons\\INV_Misc_QuestionMark")
        and not fileAsset.IsKnownFile("Interface\\AddOns\\SimFixture\\nothing.ogg"),
    "known files: an addon's own and the game's; not a missing one"
)
local scrubbed = { G.scrub("text", 2, true, {}, print) }
expect(
    scrubbed[1] == "text" and scrubbed[2] == 2 and scrubbed[3] == true and scrubbed[4] == nil and scrubbed[5] == nil,
    "scrub keeps plain values only"
)
expect(
    G.UnitHealthPercent("player", true, G.CurveConstants.ScaleTo100) == 100,
    "the player's health: 100 of 100 through the curve"
)
local secure = G.CreateFrame("Frame", nil, G.UIParent, "SecureHandlerStateTemplate")
local isProtected, isExplicit = secure:IsProtected()
expect(
    isProtected and isExplicit and not G.CreateFrame("Frame"):IsProtected(),
    "a secure template's frame is explicitly protected; a plain one not"
)
secure:SetAttribute("_onstate-page", "self:SetAttribute('seen', newstate)")
secure:SetAttribute("state-page", "2")
expect(secure:GetAttribute("seen") == "2", "a secure handler's snippet runs (the restricted environment)")
expect(
    secure:GetObjectTable() == secure and G.GetForbiddenObjectTable(secure) == secure,
    "an object's public and secure tables are itself"
)
local countdown
local countdownWatcher = G.CreateFrame("Frame")
countdownWatcher:RegisterEvent("START_PLAYER_COUNTDOWN")
countdownWatcher:SetScript("OnEvent", function(_, _, _, seconds)
    countdown = seconds
end)
G.C_PartyInfo.DoCountdown(10)
expect(countdown == 10, "a countdown (/countdown, DBM's pull timer) is announced")
G.C_PartyInfo.DoCountdown(0)
countdownWatcher:UnregisterAllEvents()
-- EllesmereUI's glitches: a message frame drawn in its own font and justification (the error banner: centred, red);
-- a font family drawing with the client's alphabet's member; a code-made font left-justified; a texture made by code
-- drawn only once it has points; the pointer an addon sets
G.UIErrorsFrame:AddMessage("Not enough rage", 1, 0.1, 0.1)
local banner
for _, item in ipairs(require("scene").export()) do
    if item.k == "s" and item.lines and item.lines[1] == "Not enough rage" then
        banner = item
    end
end
expect(
    banner and banner.jh == "CENTER" and banner.c[1] == 1 and banner.c[2] < 0.2,
    "the error banner: its message centred, in its red"
)
local family = G.CreateFontFamily("SimFamilyCheck", {
    { alphabet = "roman", file = "Fonts\\ARIALN.TTF", height = 13, flags = "" },
    { alphabet = "simplifiedchinese", file = "Fonts\\ARKai_T.ttf", height = 15, flags = "" },
})
family:GetFontObjectForAlphabet("korean"):SetFont("Fonts\\2002.ttf", 16, "")
local familyFile, familySize = family:GetFont()
expect(
    familyFile == "Fonts\\ARIALN.TTF" and familySize == 13,
    "a font family draws with the roman member: " .. tostring(familyFile)
)
expect(G.CreateFont("SimCodeFont"):GetJustifyH() == "LEFT", "a font made by code starts left-justified")
local holder = G.CreateFrame("Frame", nil, G.UIParent)
holder:SetSize(200, 200)
holder:SetPoint("CENTER")
local loose = holder:CreateTexture()
loose:SetColorTexture(1, 1, 1)
expect(require("widgets").computeRect(loose) == nil, "a texture made by code with no points is not drawn")
loose:SetAllPoints()
expect(require("widgets").computeRect(loose) ~= nil, "given points, it is")
G.SetCursor("ATTACK_CURSOR")
expect(sim.cursor == "Interface\\Cursor\\Attack", "SetCursor names the game's pointer art: " .. tostring(sim.cursor))
G.ResetCursor()
expect(sim.cursor == nil, "ResetCursor gives the game's own arrow back")
-- debugstack as the client's: from the caller asked for, count1 lines, no header (EllesmereUI finds the addon calling
-- its RegisterModule from debugstack(2, 1, 0))
local inner = G.loadstring(
    "return function() local s = debugstack(2, 1, 0) return s end",
    "@Interface/AddOns/SimInner/Inner.lua"
)()
local outer = G.loadstring(
    "local f = ... return function() local s = f() return s end",
    "@Interface/AddOns/SimOuter/Outer.lua"
)(inner)
local stackLine = outer()
expect(
    stackLine:match("AddOns/([^/]+)/") == "SimOuter" and select(2, stackLine:gsub("\n", "")) == 1,
    "debugstack(2, 1, 0): the caller's caller, one line: " .. stackLine
)
-- Clicks registered in any case and as XML's lists ("anyUp": LibDBIcon's minimap buttons; "LeftButtonUp, RightButtonUp")
local clicker = G.CreateFrame("Button", nil, G.UIParent)
clicker:SetSize(40, 40)
clicker:SetPoint("CENTER", G.UIParent, "BOTTOMLEFT", 300, 300)
local clicked = 0
clicker:SetScript("OnClick", function()
    clicked = clicked + 1
end)
clicker:RegisterForClicks("anyUp")
click(clicker)
clicker:RegisterForClicks("LeftButtonUp, RightButtonUp")
click(clicker, "RightButton")
expect(clicked == 2, 'a button registered as "anyUp" and as a list is clicked (' .. clicked .. ")")
clicker:Hide()
-- The world map opens over unit frames (its game rule: HIGH)
expect(
    G.C_GameRules.GetGameRuleAsFrameStrata(G.Enum.GameRule.WorldMapFrameStrata) == "HIGH",
    "the world map's strata rule is HIGH"
)
-- Macro options as the client parses them (state drivers, /click, /cast): an unknown condition does not hold
expect(G.SecureCmdOptionParse("[petbattle] hide; show") == "show", "[petbattle] does not hold: show")
local action, unit = G.SecureCmdOptionParse("[@player] Frame RightButton")
expect(
    action == "Frame RightButton" and unit == "player",
    "an @unit is the unit: " .. tostring(action) .. " " .. tostring(unit)
)
expect(G.SecureCmdOptionParse("[nomod] plain; shifted") == "plain", "[nomod] holds with no key down")
-- /click from a macro clicks the named button (EllesmereUI's unit menus go through it)
local proxyClicks = 0
local proxy = G.CreateFrame("Button", "SimClickProxy", G.UIParent)
proxy:SetScript("OnClick", function()
    proxyClicks = proxyClicks + 1
end)
G.C_Macro.RunMacroText("/click SimClickProxy")
expect(
    G.GetClickFrame("SimClickProxy") == proxy and proxyClicks == 1,
    "/click SimClickProxy clicks it (" .. proxyClicks .. ")"
)
-- A font string made by code with no points is not drawn (an addon's measuring string on UIParent filled the screen);
-- a texture on UIParent itself, placed, is
local measuring = G.UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
measuring:SetText("SimMeasuringString")
local onRoot = G.UIParent:CreateTexture()
onRoot:SetSize(10, 10)
onRoot:SetPoint("CENTER")
onRoot:SetColorTexture(0.77, 0, 0, 1)
local isMeasuringDrawn, isRootTextureDrawn = false, false
for _, item in ipairs(require("scene").export()) do
    if item.k == "s" and item.lines[1] == "SimMeasuringString" then
        isMeasuringDrawn = true
    end
    if item.k == "t" and item.c and item.c[1] == 0.77 then
        isRootTextureDrawn = true
    end
end
expect(not isMeasuringDrawn, "an unplaced font string made by code is not drawn")
expect(isRootTextureDrawn, "a texture on UIParent itself is drawn")
onRoot:Hide()
-- Play on a playing group plays on (Restart starts it again); a friendly unit focused (a unit menu's Set Focus)
local playing = G.UIParent:CreateAnimationGroup()
playing:CreateAnimation("Alpha"):SetDuration(1)
playing:Play()
local startedAt = playing.startedAt
wait(0.2)
playing:Play()
expect(playing.startedAt == startedAt, "Play while playing does not start it again")
playing:Restart()
expect(playing.startedAt ~= startedAt, "Restart does")
playing:Stop()
G.FocusUnit("player")
expect(G.UnitIsUnit("focus", "player") and G.UnitExists("focus"), "the player can be the focus")
G.ClearFocus()
expect(not G.UnitExists("focus"), "and the focus cleared")
-- A sheet's cell (the unit menu's raid target icons): cell 6 of 4 × 4 is the second row's second
local marker = G.UIParent:CreateTexture()
marker:SetSpriteSheetCell(6, 4, 4)
local left, top = marker:GetTexCoord()
expect(left == 0.25 and top == 0.25, "SetSpriteSheetCell(6, 4, 4): " .. left .. ", " .. top)
-- A texture nine-sliced exports its margins (EllesmereUI's rounded corners)
local sliced = holder:CreateTexture()
sliced:SetAllPoints()
sliced:SetTexture("Interface\\Buttons\\WHITE8X8")
sliced:SetTextureSliceMargins(4, 4, 4, 4)
local slicedItem
for _, item in ipairs(require("scene").export()) do
    if item.k == "t" and item.sl then
        slicedItem = item
    end
end
expect(slicedItem and slicedItem.sl[1] == 4, "a sliced texture's margins are drawn")
-- An aura's description from the game's Spell table (Arcane Intellect, rank 1: +2 Intellect)
local described = require("spelltext").describe(1459, true, 1800)
expect(
    described == nil or described == "Increases Intellect by 2.",
    "Arcane Intellect's aura text: " .. tostring(described)
)
local addonsModule = require("addons")
expect(
    addonsModule.isForThisGame("16001")
        and addonsModule.isForThisGame("11509")
        and addonsModule.isForThisGame(nil)
        and not addonsModule.isForThisGame("120105, 120107"),
    "only addons for this game line are listed (Retail-only ones are not)"
)

-- A friendly target: the player frame's left-click targets the player (lua/friendlytarget.lua); "target" is then the
-- player for every unit function, and the target frame shows it till the target is cleared
click(G.PlayerFrame)
wait(0.2)
expect(
    G.UnitIsUnit("target", "player") and G.UnitName("target") == G.UnitName("player"),
    "clicking the player frame targets the player"
)
expect(G.TargetFrame:IsVisible(), "the target frame shows it")
G.ClearTarget()
wait(0.1)
expect(not G.UnitExists("target") and not G.TargetFrame:IsVisible(), "cleared: no target")

-- The character window as the client lays it out and fills it
sim.runSecurely(G.ToggleCharacter, "PaperDollFrame")
wait(0.3)
expect(
    tostring(G.CharacterLevelText:GetText()):find("|cff3fc7ebMage|r", 1, true),
    "its title wears the class's colour (" .. tostring(G.CharacterLevelText:GetText()) .. "): C_ColorUtil's codes"
)
-- (the right pane's TOPLEFT and BOTTOMLEFT both set its left edge: the client keeps TOPLEFT, the first of its points)
local leftPaneRight = select(3, G.CharacterFrame.LeftPaneHost:GetRect()) + G.CharacterFrame.LeftPaneHost:GetLeft()
expect(
    math.abs(G.CharacterFrame.RightPaneHost:GetLeft() - leftPaneRight) < 1,
    "the stats pane stands right of the paper doll"
)
expect(
    G.CharacterStatsPaneScrollBox:IsVisible() and #G.CharacterStatsPaneScrollBox.ScrollBox:GetFrames() > 5,
    "with its stats"
)
-- The side tabs are frames with OnMouseDown and OnMouseUp, no EnableMouse: the scripts alone take the mouse
expect(G.CharacterFrameModeTab2:IsMouseEnabled(), "a side tab takes the mouse by its scripts")
click(G.CharacterFrameModeTab2)
wait(0.2)
expect(G.ReputationFrame:IsVisible(), "the reputation tab opens reputation")
click(G.CharacterFrameModeTab1)
wait(0.2)
expect(G.PaperDollFrame:IsVisible(), "and the character tab the paper doll again")
sim.runSecurely(G.HideUIPanel, G.CharacterFrame)
wait(0.1)

-- The spellbook: General and the class's schools, from the game's tables (lua/spellbook.lua)
local book = G.C_SpellBook
local lineNames, spellNames = {}, {}
for index = 1, book.GetNumSpellBookSkillLines() do
    local line = book.GetSpellBookSkillLineInfo(index)
    lineNames[#lineNames + 1] = line.name
    for slot = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
        local item = book.GetSpellBookItemInfo(slot, 0)
        if not book.IsSpellBookItemLowRank(slot, 0) then
            spellNames[item.name] = item.subName
        end
    end
end
expect(
    table.concat(lineNames, ",") == "General,Arcane,Fire,Frost",
    "a mage's book: General, Arcane, Fire, Frost (" .. table.concat(lineNames, ",") .. ")"
)
expect(
    spellNames["Fireball"] == "Rank 6" and spellNames["Attack"] ~= nil and spellNames["Will of the Forsaken"] ~= nil,
    "Fireball at its level-30 rank, Attack, the undead's own"
)
expect(spellNames["Impact"] == nil and spellNames["Pyroblast"] == nil, "no talent's spells, untrained")
for name in pairs(spellNames) do
    expect(not name:find("^Engrave"), "no runes (" .. name .. ")")
end
expect(book.GetClassSkillLineInfo().name == "Mage", "the class's line (the General tab wears its icon)")
sim.runSecurely(G.PlayerSpellsUtil.ToggleSpellBookFrame)
wait(0.3)
expect(G.PlayerSpellsFrame.SpellBookFrame:IsVisible(), "the spellbook opens with its spells")
sim.runSecurely(G.PlayerSpellsUtil.ToggleSpellBookFrame)
wait(0.1)

gamepadInterface(true)
playWindows(true)
-- (not switched back: the game's spellbook fails as the gamepad interface is left once it was open,
-- Blizzard_PlayerSpellsFrame.lua's Uninit calling SetSearchBoxDefaultPosition on the talents' search box, which
-- has no such method: the client's own bug, which the simulator shows as the client would)
