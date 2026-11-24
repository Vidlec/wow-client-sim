-- What the client answers about the world the character is in, for the questions addons ask that the rest of the
-- simulator has no system for: units (vehicles, phases, summons, resurrections, raid target marks, threat colours,
-- who a GUID is), the character's shapeshift forms and stances, spells' overrides and overlays, item level, quest
-- difficulty, the realm's time, console variables' details and bit fields, and the systems this world does not have
-- (pet battles, Mythic+, garrisons, housing, Battle.net friends, the damage meter): each answered as the client
-- answers for a character with none of them, rather than with a stand-in's made-up value.
local sim = require("sim")

local worldstate = {}

-- Shapeshift forms and stances by class: each with its spell (known from its level on, as the spell book says), the
-- form's id (GetShapeshiftFormID) and whether it starts active (a warrior is in Battle Stance)
local FORMS = {
    WARRIOR = {
        { spell = 2457, formId = 17, isDefault = true }, -- Battle Stance
        { spell = 71, formId = 18 }, -- Defensive Stance
        { spell = 2458, formId = 19 }, -- Berserker Stance
    },
    DRUID = {
        { spell = 5487, formId = 5 }, -- Bear Form
        { spell = 1066, formId = 4 }, -- Aquatic Form
        { spell = 768, formId = 1 }, -- Cat Form
        { spell = 783, formId = 3 }, -- Travel Form
        { spell = 24858, formId = 31 }, -- Moonkin Form
    },
    ROGUE = { { spell = 1784, formId = 30 } }, -- Stealth
    PRIEST = { { spell = 15473, formId = 28 } }, -- Shadowform
    -- A paladin's auras are its forms in Forever (measured: /asrec probe, five on a paladin's stance bar, no form id),
    -- each at the highest rank known
    PALADIN = {
        { ranks = { 465, 10290, 643, 10291, 1032, 10292, 10293 } }, -- Devotion Aura
        { ranks = { 7294, 10298, 10299, 10300, 10301 } }, -- Retribution Aura
        { ranks = { 19746 } }, -- Concentration Aura
        { ranks = { 19876, 19895, 19896 } }, -- Shadow Resistance Aura
        { ranks = { 19888, 19897, 19898 } }, -- Frost Resistance Aura
        { ranks = { 19891, 19899, 19900 } }, -- Fire Resistance Aura
        { ranks = { 20218 } }, -- Sanctity Aura
    },
}

-- The game rules on in Forever (measured: /asrec probe, worldAnswers.activeGameRules, 1.60.1.71037): by name, the
-- values coming from the client's enumeration
local ACTIVE_GAME_RULES = {
    "HousingDashboardDisabled",
    "StandardQuestXPDecayLevelOffset",
    "QuestLootRoundRobin",
    "MaxAccountCharReservationsPerContentset",
    "DisableHonorDecay",
    "BinarySpellPushbackResist",
    "DontAllowPartialTicks",
    "MerchantFilterDisabled",
    "LootMethodStyle",
    "DisableQuickJoin",
    "WorldMapHelpPlateDisabled",
    "EtaRealmLaunchTime",
    "EnableMaxBuffLevelDifference",
    "ManaRegenBonusStatMeansMp5",
    "EncounterJournalDisabled",
    "DisableCampsites",
    "TransmogEnabled",
    "RequirePvPFlagForPvPKillCredit",
    "EnableAmmoSystem",
    "WeaponSwapIgnoresCombatSwapCd",
    "PreventXPAndLootForExcessiveOutsideHelp",
    "CannotSkinCreaturesTooHighLevelForYourSkinningSkill",
    "RangedAttackDelay",
    "TrackAchievementsDisabled",
    "DynamicDistrictAffinityAssignmentAlgorithm",
    "UnflaggedPlayersCanAttackPvPFlaggedPlayers",
    "CraftFromBankRestricted",
    "FishingClassicDifficulty",
    "ReagentBagsFitItemsOfTheirBagFamily",
    "AeLootDisabled",
    "RPEDisabled",
    "AutoLearnPetSpells",
    "AllowEmptyLoot",
    "CreatureDamageMultiplierAllowedSources",
    "MinimumXPDecayCoefficient",
    "ThrownWeaponsUseDurability",
    "SingleTargetComboPoints",
    "ChatLinkLevelToastsDisabled",
    "PremadeGroupFinderStyle",
    "CustomActionbarOverlayHeightOffset",
    "MaxCharReservationsPerRealm",
}

-- The profession skill lines the client lists (measured: /asrec probe, the same for every character)
local PROFESSION_SKILL_LINES = {
    2946,
    2944,
    2937,
    2948,
    2934,
    2940,
    2938,
    2941,
    2947,
    2945,
    165,
    333,
    186,
    197,
    393,
    202,
    171,
    164,
    2933,
    182,
}

-- The threat colours the client gives by status (0 none, 1 higher than the tank's, 2 tanking insecurely, 3 tanking)
local THREAT_COLORS = { [0] = { 0.69, 0.69, 0.69 }, { 1, 1, 0.47 }, { 1, 0.6, 0 }, { 1, 0, 0 } }

function worldstate.install(G, game)
    local function isPlayer(unit)
        return G.UnitIsUnit and G.UnitIsUnit(unit, "player") or unit == "player"
    end

    -- Units: nothing of these happens in the simulated world
    G.UnitHasIncomingResurrection = function()
        return false
    end
    G.C_IncomingSummon = G.C_IncomingSummon or {}
    G.C_IncomingSummon.HasIncomingSummon = function()
        return false
    end
    G.C_IncomingSummon.IncomingSummonStatus = function()
        return 0 -- (Enum.SummonStatus.None)
    end
    G.UnitPhaseReason = function()
        return nil
    end
    G.UnitInVehicle = function()
        return false
    end
    G.UnitUsingVehicle = function()
        return false
    end
    G.CanExitVehicle = function()
        return false
    end
    G.UnitIsGroupAssistant = function()
        return false
    end
    G.UnitIsDND = function()
        return false
    end
    -- The player, a party member, or a player's pet
    G.UnitIsPlayerControlledOrGroupMember = function(unit)
        if type(unit) ~= "string" or not (G.UnitExists and G.UnitExists(unit)) then
            return false
        end
        local lower = unit:lower()
        return isPlayer(unit)
            or (G.UnitInParty and G.UnitInParty(unit) and true or false)
            or (G.UnitIsPlayer and G.UnitIsPlayer(unit) and true or false)
            or lower:find("pet", 1, true) ~= nil
    end
    G.GetThreatStatusColor = function(status)
        local color = THREAT_COLORS[tonumber(status) or 0] or THREAT_COLORS[0]
        return color[1], color[2], color[3]
    end

    -- Raid target marks (the unit menu's Target Marker Icon): one unit a mark, by its GUID
    local marks = {} -- [guid] = index
    G.SetRaidTarget = function(unit, index)
        local guid = G.UnitGUID and G.UnitGUID(unit)
        if not guid then
            return
        end
        index = tonumber(index) or 0
        for other, mark in pairs(marks) do
            if mark == index then
                marks[other] = nil
            end
        end
        marks[guid] = index > 0 and index or nil
        sim.fireEvent("RAID_TARGET_UPDATE")
        sim.touch()
    end
    G.GetRaidTargetIndex = function(unit)
        local guid = G.UnitGUID and G.UnitGUID(unit)
        return guid and marks[guid] or nil
    end

    -- Who a GUID is: the player, a party member, the target or focus, as the client tells of a player it knows
    G.GetPlayerInfoByGUID = function(guid)
        if not guid then
            return nil
        end
        for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4", "target", "focus", "mouseover" }) do
            if G.UnitExists(unit) and G.UnitGUID(unit) == guid and G.UnitIsPlayer(unit) then
                local localizedClass, englishClass = G.UnitClass(unit)
                local localizedRace, englishRace = G.UnitRace(unit)
                local name, realm = G.UnitName(unit)
                return localizedClass,
                    englishClass,
                    localizedRace,
                    englishRace,
                    G.UnitSex(unit),
                    name,
                    realm or "",
                    G.UnitLevel(unit)
            end
        end
        return nil
    end
    -- (the player too: measured)
    G.CanInspect = function(unit)
        return G.UnitExists(unit) and G.UnitIsPlayer(unit) and true or false
    end

    -- Item level: the worn items', averaged over the sixteen slots that count (a two-handed weapon counts twice)
    local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }
    local function averageItemLevel()
        local total = 0
        for _, slot in ipairs(SLOTS) do
            local link = G.GetInventoryItemLink and G.GetInventoryItemLink("player", slot)
            local itemId = link and tonumber(tostring(link):match("item:(%d+)"))
            if itemId and G.C_Item and G.C_Item.GetItemInfo then
                local _, _, _, level, _, _, _, _, equipLoc = G.C_Item.GetItemInfo(itemId)
                level = tonumber(level) or 0
                total = total + level
                if slot == 16 and equipLoc == "INVTYPE_2HWEAPON" then
                    total = total + level
                end
            end
        end
        return total / #SLOTS
    end
    G.GetAverageItemLevel = function()
        local level = averageItemLevel()
        return level, level, level
    end
    G.C_PaperDollInfo = G.C_PaperDollInfo or {}
    -- (an inspected unit's, once inspected: nothing is, so 0, the player's own too, as measured)
    G.C_PaperDollInfo.GetInspectItemLevel = function()
        return 0
    end

    -- Spells: no overrides, overlays or press-and-hold spells in this world; a spell is its own base
    G.C_Spell = G.C_Spell or {}
    G.C_Spell.IsPressHoldReleaseSpell = function()
        return false
    end
    G.C_Spell.GetBaseSpell = function(spell)
        return tonumber(spell) or spell
    end
    G.C_Spell.GetOverrideSpell = function(spell)
        return tonumber(spell) or spell
    end
    G.C_SpellActivationOverlay = G.C_SpellActivationOverlay or {}
    G.C_SpellActivationOverlay.IsSpellOverlayed = function()
        return false
    end
    G.C_SpellBook = G.C_SpellBook or {}
    -- (a spell with no override is its own: measured)
    G.C_SpellBook.FindSpellOverrideByID = function(spell)
        return tonumber(spell)
    end
    G.C_SpellBook.IsSpellKnownOrInSpellBook = function(spellId)
        return G.IsSpellKnown and G.IsSpellKnown(spellId) and true or false
    end

    -- Shapeshift forms and stances: the class's, those its spell book has; one active at a time
    local activeForm -- the spell of the active one; nil for none
    local function knownForms()
        local _, class = G.UnitClass("player")
        local list = {}
        for _, form in ipairs(FORMS[tostring(class or "")] or {}) do
            local known
            for _, rank in ipairs(form.ranks or { form.spell }) do
                if G.IsSpellKnown and G.IsSpellKnown(rank) then
                    known = rank
                end
            end
            if known then
                list[#list + 1] = { spell = known, formId = form.formId, isDefault = form.isDefault }
            end
        end
        return list
    end
    local function activeIndex()
        local forms = knownForms()
        if activeForm == nil then
            for _, form in ipairs(forms) do
                if form.isDefault then
                    activeForm = form.spell
                end
            end
        end
        for index, form in ipairs(forms) do
            if form.spell == activeForm then
                return index, form
            end
        end
        return 0
    end
    G.GetNumShapeshiftForms = function()
        return #knownForms()
    end
    G.GetShapeshiftForm = function()
        return (activeIndex())
    end
    G.GetShapeshiftFormID = function()
        local _, form = activeIndex()
        return form and form.formId or nil
    end
    -- (no form has a cooldown of its own here)
    G.GetShapeshiftFormCooldown = function()
        return 0, 0, 1
    end
    G.GetShapeshiftFormInfo = function(index)
        local form = knownForms()[tonumber(index) or 0]
        if not form then
            return nil
        end
        local icon = G.C_Spell and G.C_Spell.GetSpellTexture and G.C_Spell.GetSpellTexture(form.spell)
        return icon, (activeIndex()) == tonumber(index), true, form.spell
    end
    -- Taking a form (a stance button, its spell cast): the one before is left (a warrior's stance is always one)
    G.CastShapeshiftForm = function(index)
        local form = knownForms()[tonumber(index) or 0]
        if not form then
            return
        end
        local _, class = G.UnitClass("player")
        if activeForm == form.spell and class ~= "WARRIOR" then
            activeForm = false
        else
            activeForm = form.spell
        end
        sim.fireEvent("UPDATE_SHAPESHIFT_FORM")
        sim.fireEvent("UPDATE_SHAPESHIFT_FORMS")
        sim.touch()
    end

    -- Specializations: one a class, named as the class (measured: a paladin's is 1, id 1486, "Paladin", DAMAGER, its
    -- primary stat 4); each class's own as the recorder measured them (worldAnswers.specializations), else its name
    -- alone with no id
    local recorded = sim.recordedProbe and sim.recordedProbe.worldAnswers or {}
    local function specializationOf(classId)
        local byClass = recorded.specializations and recorded.specializations[tostring(classId)]
        if type(byClass) == "table" and byClass[1] then
            return byClass
        end
        if recorded.GetSpecializationInfo1 and recorded.classId == classId then
            return recorded.GetSpecializationInfo1
        end
        return nil
    end
    local function playerSpecialization()
        local localized, _, classId = G.UnitClass("player")
        local info = specializationOf(classId)
        if info then
            return info[1], info[2], info[3], info[4], info[5], info[6], info[7] or 0, info[8], info[9] or 0, true
        end
        return 0, localized, "", nil, "DAMAGER", nil, 0, nil, 0, true
    end
    G.C_SpecializationInfo = G.C_SpecializationInfo or {}
    G.C_SpecializationInfo.GetSpecialization = function()
        return 1
    end
    G.C_SpecializationInfo.GetSpecializationInfo = function(index)
        if tonumber(index) ~= 1 then
            return nil
        end
        return playerSpecialization()
    end
    G.C_SpecializationInfo.GetNumSpecializationsForClassID = function()
        return 1
    end
    -- (a global in this client, GetSpecializationInfoForClassID(classID, index [, sex]), as the recorder found: the
    -- namespace has none)
    G.GetSpecializationInfoForClassID = function(classId, index)
        if tonumber(index) ~= 1 then
            return nil
        end
        local info = specializationOf(tonumber(classId))
        if info then
            -- (isRecommended and isAllowed: false in this client, as measured)
            return info[1], info[2], info[3], info[4], info[5], info[6] == true, info[7] == true
        end
        return nil
    end
    G.GetNumSpecializations = function()
        return 1
    end
    G.GetSpecializationRole = function(index)
        if tonumber(index) ~= 1 then
            return nil
        end
        local _, _, _, _, role = playerSpecialization()
        return role
    end

    -- The realm's time: the computer's clock (the simulated realm is where the player is)
    G.GetGameTime = function()
        local now = os.date("*t")
        return now.hour, now.min
    end
    G.GetRealmID = function()
        return 0
    end
    G.IsPublicTestClient = function()
        return false
    end
    G.HasNewMail = function()
        return false
    end

    -- Game rules: Forever's (the encounter journal off, ammunition on...), their values the client's own where the
    -- recorder measured them (those the documentation leaves out were made-up numbers)
    local recordedRules = recorded.gameRules
    if type(recordedRules) == "table" and G.Enum then
        local rules = rawget(G.Enum, "GameRule")
        if type(rules) ~= "table" then
            rules = {}
            rawset(G.Enum, "GameRule", rules)
        end
        for name, value in pairs(recordedRules) do
            rawset(rules, name, value)
        end
    end
    local activeRules = {}
    for _, name in ipairs(ACTIVE_GAME_RULES) do
        activeRules[name] = true
    end
    G.C_GameRules = G.C_GameRules or {}
    G.C_GameRules.IsGameRuleActive = function(rule)
        local rules = G.Enum and G.Enum.GameRule
        if type(rules) ~= "table" or rule == nil then
            return false
        end
        for name in pairs(activeRules) do
            if rawget(rules, name) == rule then
                return true
            end
        end
        return false
    end

    -- Console variables: a setting's details, and settings kept as bit fields (a number, bit n at index n)
    G.C_CVar = G.C_CVar or {}
    G.C_CVar.GetCVarInfo = function(name)
        local value = G.GetCVar(name)
        if value == nil then
            return nil
        end
        local default = G.GetCVarDefault and G.GetCVarDefault(name) or value
        return value, default, false, false, false, false, false
    end
    G.C_CVar.GetCVarBitfield = function(name, index)
        local value = tonumber(G.GetCVar(name))
        index = tonumber(index)
        if not value or not index or index < 1 then
            return nil
        end
        return math.floor(value / 2 ^ (index - 1)) % 2 == 1
    end
    G.C_CVar.SetCVarBitfield = function(name, index, isOn)
        local value = tonumber(G.GetCVar(name)) or 0
        index = tonumber(index)
        if not index or index < 1 then
            return false
        end
        local bit = 2 ^ (index - 1)
        local isSet = math.floor(value / bit) % 2 == 1
        if isOn and not isSet then
            value = value + bit
        elseif not isOn and isSet then
            value = value - bit
        end
        G.SetCVar(name, tostring(math.floor(value)))
        return true
    end

    -- Key bindings: the action a key is bound to
    G.C_KeyBindings = G.C_KeyBindings or {}
    G.C_KeyBindings.GetBindingByKey = function(key)
        return G.GetBindingAction and G.GetBindingAction(key) or ""
    end
    -- Playing with a gamepad: the interface in its gamepad style
    G.IsUsingGamepad = function()
        return G.GetCVar("InputDeviceInterfaceStyle") == "1"
    end

    -- Friends and Battle.net: the player is signed in, with no friends in the simulated world
    G.BNGetInfo = function()
        local name = G.UnitName("player") or "Player"
        return 1, name .. "#1001", 1, "", false, false, false
    end
    G.C_FriendList = G.C_FriendList or {}
    G.C_FriendList.GetNumFriends = function()
        return 0
    end
    G.C_FriendList.GetNumOnlineFriends = function()
        return 0
    end
    -- (the newer social window, which takes the friends key from the classic Friends frame: on in Forever, measured)
    G.C_SocialUI = G.C_SocialUI or {}
    G.C_SocialUI.IsSystemEnabled = function()
        return true
    end

    -- Macros: the simulated character has none
    G.GetMacroIndexByName = function()
        return 0
    end

    -- Systems this world does not have: never on
    local function never()
        return false
    end
    G.C_Garrison = G.C_Garrison or {}
    G.C_Garrison.IsOnGarrisonMap = never
    G.C_HouseEditor = G.C_HouseEditor or {}
    G.C_HouseEditor.IsHouseEditorActive = never
    G.C_PetBattles = G.C_PetBattles or {}
    G.C_PetBattles.IsInBattle = never
    G.C_ChallengeMode = G.C_ChallengeMode or {}
    G.C_ChallengeMode.IsChallengeModeActive = never
    G.C_ChallengeMode.GetActiveChallengeMapID = function()
        return nil
    end
    G.C_PvP = G.C_PvP or {}
    G.C_PvP.IsMatchActive = never
    G.C_LFGInfo = G.C_LFGInfo or {}
    G.C_LFGInfo.IsInLFGFollowerDungeon = never
    G.C_Secrets = G.C_Secrets or {}
    G.C_Secrets.ShouldAurasBeSecret = never
    G.C_Secrets.ShouldSpellAuraBeSecret = never
    -- The Encounter Journal's tier, as chosen (0 in Forever, measured: its journal is off by a game rule)
    local journalTier = 0
    G.EJ_GetCurrentTier = function()
        return journalTier
    end
    G.EJ_SelectTier = function(tier)
        journalTier = tonumber(tier) or journalTier
    end

    -- Professions, toys, the bank, currencies: the simulated character has none of them
    G.C_TradeSkillUI = G.C_TradeSkillUI or {}
    G.C_TradeSkillUI.GetAllProfessionTradeSkillLines = function()
        local copy = {}
        for index, line in ipairs(PROFESSION_SKILL_LINES) do
            copy[index] = line
        end
        return copy
    end
    G.C_TradeSkillUI.GetRecipesTracked = function()
        return {}
    end
    G.C_ToyBox = G.C_ToyBox or {}
    G.C_ToyBox.GetToyInfo = function(itemId)
        itemId = tonumber(itemId)
        if not (itemId and G.C_Item and G.C_Item.GetItemInfo) then
            return nil
        end
        local name, _, quality = G.C_Item.GetItemInfo(itemId)
        if not name then
            return nil
        end
        local icon = G.C_Item.GetItemIconByID and G.C_Item.GetItemIconByID(itemId)
        return itemId, name, icon, false, false, quality
    end
    G.C_Bank = G.C_Bank or {}
    G.C_Bank.FetchDepositedMoney = function()
        return 0
    end
    G.C_Bank.FetchMaxNumBankTabs = function()
        return 0
    end
    -- Raid lockouts: the client asks the server, which answers with UPDATE_INSTANCE_INFO; none saved here
    G.RequestRaidInfo = function()
        sim.addTimer(0, function()
            sim.fireEvent("UPDATE_INSTANCE_INFO")
        end)
    end
    G.GetNumSavedInstances = function()
        return 0
    end
    -- Equipment sets: none saved
    G.C_EquipmentSet = G.C_EquipmentSet or {}
    G.C_EquipmentSet.GetEquipmentSetIDs = function()
        return {}
    end
    G.C_EquipmentSet.GetNumEquipmentSets = function()
        return 0
    end
    G.C_CurrencyInfo = G.C_CurrencyInfo or {}
    -- The currency list (the currency tab): no currencies earned
    G.C_CurrencyInfo.GetCurrencyListSize = function()
        return 0
    end
    G.C_CurrencyInfo.GetBackpackCurrencyInfo = function()
        return nil
    end
    -- The damage meter: no fight recorded
    G.C_DamageMeter = G.C_DamageMeter or {}
    G.C_DamageMeter.GetCombatSessionFromType = function()
        return { combatSources = {}, maxAmount = 0, totalAmount = 0, durationSeconds = 0 }
    end
    G.C_DamageMeter.GetSessionDurationSeconds = function()
        return nil
    end

    -- Name plates' size and where they take the mouse, as set (kept for the getters)
    G.C_NamePlate = G.C_NamePlate or {}
    local plateSize = { 110, 45 }
    G.C_NamePlate.SetNamePlateSize = function(width, height)
        plateSize = { tonumber(width) or plateSize[1], tonumber(height) or plateSize[2] }
    end
    G.C_NamePlate.GetNamePlateSize = function()
        return plateSize[1], plateSize[2]
    end
    G.C_NamePlateManager = G.C_NamePlateManager or {}
    local hitInsets = {}
    G.C_NamePlateManager.SetNamePlateHitTestInsets = function(plateType, left, right, top, bottom)
        hitInsets[plateType or 0] = { left, right, top, bottom }
    end
    G.C_NamePlateManager.GetNamePlateHitTestInsets = function(plateType)
        local insets = hitInsets[plateType or 0] or { 0, 0, 0, 0 }
        return insets[1], insets[2], insets[3], insets[4]
    end

    -- Quests: their difficulty by the player's level (as the log colours them), and what this world has none of
    G.C_PlayerInfo = G.C_PlayerInfo or {}
    G.C_PlayerInfo.GetContentDifficultyQuestForPlayer = function(questId)
        local level = G.C_QuestLog.GetQuestDifficultyLevel and G.C_QuestLog.GetQuestDifficultyLevel(questId)
        local playerLevel = G.UnitLevel("player") or 1
        if not level or level <= 0 then
            return 2 -- Fair
        end
        local difference = level - playerLevel
        if difference >= 5 then
            return 4 -- Impossible
        elseif difference >= 3 then
            return 3 -- Difficult
        elseif difference >= -2 then
            return 2 -- Fair
        end
        local greenRange = G.GetQuestGreenRange and G.GetQuestGreenRange() or 5
        if -difference <= greenRange then
            return 1 -- Easy
        end
        return 0 -- Trivial
    end
    G.C_QuestLog = G.C_QuestLog or {}
    G.C_QuestLog.GetNextWaypointText = function()
        return ""
    end
    G.C_QuestLog.GetQuestTimers = function()
        return {}
    end
    G.C_QuestLog.GetQuestRewardCurrencies = function()
        return {}
    end
    G.C_CampaignInfo = G.C_CampaignInfo or {}
    G.C_CampaignInfo.IsCampaignQuest = never
    -- The text a finished quest shows in the log ("Return to ..."): the giver it is turned in to, when known
    G.GetQuestLogCompletionText = function(index)
        local questId = G.C_QuestLog.GetQuestIDForLogIndex and G.C_QuestLog.GetQuestIDForLogIndex(index)
        local finisher = questId and game and game.questFinisherName and game.questFinisherName(questId)
        return finisher and ("Return to " .. finisher .. ".") or nil
    end
end

return worldstate
