--@addons QuestieDB, SimFixture
-- A project as the simulator runs it (the self-test project, src/project/select.ts): its own addon found in its own
-- folder, its saved variables kept across a reload, its Lua module folder ahead of the simulator's, its plugin's party
-- addon and step (lua/plugins.lua). Also the party's addons: a member runs none unless one is named, Questie's
-- member (built in, through the same API) speaks Questie's protocol, and the plugin's member answers its own.
local addons = require("addons")
local plugins = require("plugins")
local QUEST = 844 -- Plainstrider Menace

-- The project's addon, from the project's folder
local fixture = addons.byName["simfixture"]
expect(fixture and addons.loaded.SimFixture, "the fixture addon loaded")
expect(fixture and fixture.folder:gsub("\\", "/"):find("scenarios/fixtures/addons/SimFixture", 1, true) ~= nil,
    "from the project's folder (" .. tostring(fixture and fixture.folder) .. ")")
expect(G.SimFixtureDB and G.SimFixtureDB.logins == 1, "its saved variables start fresh")
expect(#fixture.private.marks == 5, "its marks are on the minimap")
slash("/simfixture marks")
expectChat("SimFixture: 5 marks")

-- The project's Lua modules come first
expect(package.searchpath("fixturelib", package.path):gsub("\\", "/"):find("fixtures/lib/fixturelib.lua", 1, true) ~= nil,
    "require finds the project's module folder")

-- The party addons the page lists: none (the default), the simulator's Questie, the plugin's
local listed = {}
for _, entry in ipairs(plugins.describePartyAddons()) do listed[entry.id] = entry end
expect(listed.none and listed.none.isDefault, "a member runs no addon by default")
expect(listed.Questie and listed.SimFixture, "Questie's member and the plugin's are listed")

setProfile({ level = 14, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
accept(QUEST)
joinParty({ name = "Plain", class = "WARRIOR" })
expect(require("party").findMember("Plain").addon == "none", "a member without an addon named runs none")

-- The plugin's member: hello on joining, its counts as they change, an answer to the player's question
joinParty({ name = "Fixie", class = "MAGE", addon = "SimFixture" })
wait(0.5)
local function heardText(text)
    for _, message in ipairs(fixtureHeard()) do
        if message.text == text then return message end
    end
end
expect(heardText("HELLO"), "the plugin's member greets the party")
memberAccept("Fixie", QUEST)
memberProgress("Fixie", QUEST, 1, 3)
wait(0.3)
local required = require("party").findMember("Fixie").quests[QUEST].objectives[1].required
expect(heardText("Q|" .. QUEST .. "|3/" .. required), "its count reaches the player's side")
G.C_ChatInfo.SendAddonMessage("SimFixture", "PING", "PARTY")
wait(0.3)
local pong = heardText("PONG|Fixie")
expect(pong and pong.channel == "WHISPER", "it answers the player's message, whispered")
memberAbandon("Fixie", QUEST)
wait(0.3)
expect(heardText("Q|" .. QUEST .. "|gone"), "and says when it drops the quest")
leaveParty("Fixie")
expect(require("fixturelib").left[1] == "Fixie", "its addon hears it leave")

-- Questie's member, built in: its messages on Questie's channel
local questieHeard = 0
local listener = G.CreateFrame("Frame")
listener:RegisterEvent("CHAT_MSG_ADDON")
listener:SetScript("OnEvent", function(_, _, prefix) if prefix == "questie" then questieHeard = questieHeard + 1 end end)
joinParty({ name = "Questa", class = "PRIEST", addon = "Questie" })
memberAccept("Questa", QUEST)
wait(1)
expect(questieHeard >= 2, "Questie's member sends its request and log on joining, and its change (" .. questieHeard .. ")")

-- A reload keeps the addon's saved variables, and boots the plugin again
reload()
expect(G.SimFixtureDB and G.SimFixtureDB.logins == 2, "the saved variables carried over a reload")
expect(require("plugins").getPartyAddon("SimFixture") ~= nil, "the plugin registered again at the new boot")
expect(type(fixtureHeard) == "function", "its step is there after the reload")
