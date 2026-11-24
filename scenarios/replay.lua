-- Playing back a session recorded in the game (here a sample in the recorder's shape): the character, the
-- quest it accepted, the fight and the loot that count for its drop objective, its count, and where it walked.
--@addons SimQuestieDB, SimFixture
local count = replay(scenariosDir .. "/fixtures/sample-recording.lua")
expect(count == 10, "every recorded moment played")
expect(G.C_QuestLog.GetLogIndexForQuestID(844) ~= nil, "the recorded quest is in the log")
local objective = (G.C_QuestLog.GetQuestObjectives(844) or {})[1] or {}
expect(
    objective.numFulfilled == 1,
    "with the recorded count of 1 beak (got " .. tostring(objective.numFulfilled) .. ")"
)
local x, y = require("game").profile.x, require("game").profile.y
expect(math.abs(x - 0.505) < 0.001 and math.abs(y - 0.29) < 0.001, "the character stands where the recording ends")
