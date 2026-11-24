--@locale deDE
--@addons QuestieDB, SimFixture
-- A German client: the game's strings, map names and objective wording come from the game's German tables, and
-- everything (the world map, an addon's window) opens without errors.
setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
accept(844) -- Plainstrider Menace: plainstriders to kill
wait(1)
expect(G.GetLocale() == "deDE", "the client is German")
expect(
    G.QUEST_MONSTERS_KILLED ~= "%2$d/%3$d %1$s slain",
    "the game's objective wording is its German one (" .. tostring(G.QUEST_MONSTERS_KILLED) .. ")"
)
local objective = (G.C_QuestLog.GetQuestObjectives(844) or {})[1] or {}
print("German objective:", objective.text)
expect(objective.text and not objective.text:find("slain", 1, true), "the quest log's objective is worded in German")
expect(G.GetRealZoneText() ~= "The Barrens", "the zone has its German name (" .. tostring(G.GetRealZoneText()) .. ")")
key("M")
wait(0.5)
expect(G.WorldMapFrame:IsShown(), "the map opens")
key("M")
slash("/simfixture")
wait(0.5)
expect(G.SimFixtureWindow:IsVisible(), "an addon's window opens")
draw()
