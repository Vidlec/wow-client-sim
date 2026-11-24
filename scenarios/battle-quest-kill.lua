--@addons SimQuestieDB, SimFixture
-- A fight to the death that counts for a quest (lua/combat.lua): two quilboar near a level 9 orc warrior in Durotar
-- see him and come at him; he fights them with his swings and Heroic Strike. Each death counts for Encroachment,
-- gives experience and leaves loot (the quest from the quest database); the fight's end lets him out of combat, and resting
-- brings his health back.
setProfile({ level = 9, race = "Orc", class = "WARRIOR", xp = 0, xpMax = 6500 })
moveTo(1411, 0.52, 0.62) -- Durotar
resetCombat(7)
accept(837) -- Encroachment: Razormane Quilboar, Scouts, Dustrunners and Battleguards
G.SetCVar("nameplateShowEnemies", "1")

local events = {}
local listener = G.CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "PARTY_KILL",
    "UNIT_DIED",
    "PLAYER_XP_UPDATE",
    "CHAT_MSG_COMBAT_XP_GAIN",
    "LOOT_OPENED",
    "LOOT_CLOSED",
    "PLAYER_MONEY",
    "PLAYER_ENTER_COMBAT",
    "PLAYER_LEAVE_COMBAT",
}) do
    listener:RegisterEvent(event)
end
listener:SetScript("OnEvent", function(_, event, ...)
    events[#events + 1] = { event = event, ... }
end)
local function count(name)
    local found = 0
    for _, entry in ipairs(events) do
        if entry.event == name then
            found = found + 1
        end
    end
    return found
end

local first, ids = spawn(3111, { distance = 12, count = 2 }) -- Razormane Quilboar
expect(ids and #ids == 2, "two quilboar stand 12 yards ahead")
local quilboar = enemy(first)
expect(
    quilboar.reaction == 2 and quilboar.level >= 6,
    "hostile, of the level the game's data gives them (" .. tostring(quilboar.level) .. ")"
)
expect(G.UnitName("nameplate1") == "Razormane Quilboar", "their nameplates are units with the game's name")
wait(0.5)
expect(G.UnitAffectingCombat("player") and G.InCombatLockdown(), "they see him and attack: he is in combat")
expect(count("PLAYER_REGEN_DISABLED") == 1, "PLAYER_REGEN_DISABLED, once")
expect(enemy(ids[2]).inCombat, "the second comes along with the first")

local seconds = fight(first, { slots = { 2 } }) -- Heroic Strike whenever there is rage for it
expect(enemy(first).isDead, "the first quilboar dies (in " .. math.floor(seconds) .. " s)")
expect(G.UnitIsDead("target"), "the target is its corpse")
expect(count("PARTY_KILL") == 1 and count("UNIT_DIED") == 1, "the game tells of the kill: PARTY_KILL, UNIT_DIED")
local objectives = G.C_QuestLog.GetQuestObjectives(837)
expect(
    objectives[1] and objectives[1].numFulfilled == 1,
    "Encroachment counts the quilboar: " .. tostring(objectives[1] and objectives[1].text)
)
expect(
    G.UnitXP("player") > 0 and count("CHAT_MSG_COMBAT_XP_GAIN") == 1,
    "experience for it (" .. G.UnitXP("player") .. ")"
)
expect(G.InCombatLockdown(), "still in combat: the second quilboar fights on")

fight(ids[2], { slots = { 2 } })
expect(enemy(ids[2]).isDead, "the second dies too")
expect(G.C_QuestLog.GetQuestObjectives(837)[1].numFulfilled == 2, "two quilboar counted")
expect(not G.InCombatLockdown() and not G.UnitAffectingCombat("player"), "the fight over, he is out of combat")
expect(count("PLAYER_REGEN_ENABLED") == 1, "PLAYER_REGEN_ENABLED, once")
expect(
    G.UnitHealth("player") > 0 and G.UnitHealth("player") < G.UnitHealthMax("player"),
    "he took some blows (" .. G.UnitHealth("player") .. " of " .. G.UnitHealthMax("player") .. ")"
)

-- The corpses' loot: money, as most creatures carry
local money = G.GetMoney()
lootCorpse(first)
lootCorpse(ids[2])
expect(count("LOOT_OPENED") >= 1 and count("LOOT_CLOSED") == count("LOOT_OPENED"), "the loot window opens and closes")
expect(G.GetMoney() > money, "and the copper is his (" .. (G.GetMoney() - money) .. ")")

-- Resting: health comes back out of combat
local hurt = G.UnitHealth("player")
wait(10)
expect(G.UnitHealth("player") > hurt, "his health regenerates out of combat")
saveScene("after-the-fight")
