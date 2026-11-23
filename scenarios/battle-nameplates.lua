--@addons QuestieDB, SimFixture
-- What a nameplate addon sees of a fight (lua/combat.lua): plates come as creatures come in range (with the setting
-- on), go as they leave it or die; their units answer health, level, rank and side; UNIT_HEALTH tells of every blow,
-- once for each unit token the creature has (a frame registered for one unit hears only it); Tab cycles the
-- nearest first, a click on a plate targets it; a caster's cast shows on its unit and a Kick interrupts it; combo
-- points build and are spent; the threat and identity restrictions hide what the client hides.
setProfile({ level = 14, race = "Scourge", class = "ROGUE" })
moveTo(1413, 0.52, 0.31) -- the Barrens
resetCombat(11)

-- The addon: its own plates, by unit
local plates, guids, healthSeen, removed, died = {}, {}, {}, {}, {}
local addon = G.CreateFrame("Frame")
addon:RegisterEvent("NAME_PLATE_UNIT_ADDED")
addon:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
addon:RegisterEvent("UNIT_HEALTH")
addon:RegisterEvent("UNIT_DIED")
addon:SetScript("OnEvent", function(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        plates[unit] = G.UnitName(unit)
        guids[unit] = G.UnitGUID(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        removed[#removed + 1] = unit
        plates[unit] = nil
    elseif event == "UNIT_HEALTH" then
        healthSeen[unit] = G.UnitHealth(unit)
    elseif event == "UNIT_DIED" then
        died[#died + 1] = unit -- (a GUID)
    end
end)
local targetOnly = {}
local targetFrame = G.CreateFrame("Frame")
targetFrame:RegisterUnitEvent("UNIT_HEALTH", "target")
targetFrame:SetScript("OnEvent", function(_, _, unit) targetOnly[unit] = true end)
local function plateCount() local found = 0; for _ in pairs(plates) do found = found + 1 end; return found end

-- Enemy nameplates are off by default in this client: the creatures are there, without plates
G.SetCVar("nameplateShowEnemies", "0")
local near, striders = spawn("Greater Plainstrider", { distance = 12, count = 2 })
local caster = spawn("Kolkar Stormer", { distance = 9, bearing = 40, aggro = false })
local far = spawn("Greater Plainstrider", { distance = 70 })
wait(0.2)
expect(plateCount() == 0 and #G.C_NamePlate.GetNamePlates() == 0, "no plates while the setting is off")
G.SetCVar("nameplateShowEnemies", "1")
wait(0.2)
expect(plateCount() == 3, "three plates once it is on; the one 70 yards off has none (" .. plateCount() .. ")")
expect(#G.C_NamePlate.GetNamePlates() == 3, "C_NamePlate.GetNamePlates lists them")
local strider = enemy(near)
expect(plates[strider.unit] == "Greater Plainstrider", "a plate's unit has the creature's name")
expect(G.UnitLevel(strider.unit) == strider.level and G.UnitClassification(strider.unit) == "normal", "its level and rank")
expect(G.UnitReaction(strider.unit, "player") == 4 and G.UnitCanAttack("player", strider.unit), "a plainstrider is neutral, and can be attacked")
expect(G.UnitHealth(strider.unit) == G.UnitHealthMax(strider.unit) and G.UnitHealthMax(strider.unit) > 0, "at full health")
expect(type(guids[strider.unit]) == "string" and guids[strider.unit]:match("^Creature%-0%-%d+%-%d+%-%d+%-" .. strider.npcId .. "%-"),
    "with a creature's GUID (" .. tostring(guids[strider.unit]) .. ")")
local plateFrame = G.C_NamePlate.GetNamePlateForUnit(strider.unit)
expect(plateFrame and plateFrame.UnitFrame and plateFrame.UnitFrame:IsShown(), "the game's own nameplate frame shows it")

-- Tab: the nearest first, then the next
key("TAB")
expect(G.UnitName("target") == "Kolkar Stormer", "Tab targets the nearest: the stormer, 9 yards off")
key("TAB")
local secondTarget = G.UnitGUID("target")
expect(secondTarget == strider.guid or secondTarget == enemy(striders[2]).guid, "Tab again: the next nearest, a plainstrider")
key("TAB")
expect(G.UnitGUID("target") ~= secondTarget and G.UnitName("target") == "Greater Plainstrider", "and again: the other one")
-- A click on a plate targets its creature
local casterUnit = enemy(caster).unit
click(G.C_NamePlate.GetNamePlateForUnit(casterUnit))
expect(G.UnitIsUnit("target", casterUnit), "a click on the stormer's plate targets it")

-- The stormer casts: its unit has the cast; a Kick interrupts it
local casts = {}
local castWatch = G.CreateFrame("Frame")
castWatch:RegisterUnitEvent("UNIT_SPELLCAST_START", casterUnit)
castWatch:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", casterUnit)
castWatch:SetScript("OnEvent", function(_, event) casts[#casts + 1] = event end)
fight(caster, { slots = { 2 }, seconds = 1 }) -- walks up, a first blow, and the fight is on
waitUntil(function() return G.UnitCastingInfo(casterUnit) ~= nil end, 15, "the stormer begins a cast")
local spellName, _, _, _, endTime = G.UnitCastingInfo(casterUnit)
expect(spellName == "Lightning Bolt" and endTime > G.GetTime() * 1000, "it casts Lightning Bolt: " .. tostring(spellName))
expect(G.UnitCastingInfo("target") == spellName, "the same cast, as the target")
waitUntil(function() return G.C_ActionBar.IsUsableAction(7) and not G.C_ActionBar.GetActionCooldown(7).isActive end, 3, "Kick ready (energy, no global cooldown)")
useAction(7) -- Kick
expect(G.UnitCastingInfo(casterUnit) == nil, "Kick interrupts it")
expect(casts[1] == "UNIT_SPELLCAST_START" and casts[#casts] == "UNIT_SPELLCAST_INTERRUPTED", "its frame heard the cast and the interrupt")

-- Combo points from Sinister Strike, spent by Eviscerate
fight(caster, { slots = { 2 }, seconds = 3 })
expect(G.GetComboPoints("player", "target") >= 1, "Sinister Strike gives combo points (" .. G.GetComboPoints("player", "target") .. ")")
fight(caster, { slots = { 3, 2 } })
expect(enemy(caster).isDead, "the stormer dies")
expect(healthSeen[casterUnit] == 0 or healthSeen.target == 0, "the addon saw its health fall to 0")
expect(targetOnly.target and not targetOnly[casterUnit], "a frame registered for the target hears only the target's UNIT_HEALTH")
expect(removed[#removed] == casterUnit and plates[casterUnit] == nil, "its plate is taken away as it dies")
expect(died[#died] == guids[casterUnit], "UNIT_DIED gives the GUID the plate had")

-- Out of range: the far plainstrider gets its plate as the player walks up to it
approach(far, 40)
wait(0.1)
expect(enemy(far).unit ~= nil, "walking toward it, the far one's plate comes")

-- What the client hides where it restricts it (PvP, some instances)
restrict({ identity = true, threat = true })
local unit = enemy(near).unit
expect(G.issecretvalue(G.UnitGUID(unit)), "the identity restricted: a plate's GUID is a secret")
key("TAB")
useAction(2)
wait(1)
local status = G.UnitThreatSituation("player", "target")
expect(status == nil or G.issecretvalue(status), "the threat restricted: its threat a secret")
restrict({})
saveScene("plates")
