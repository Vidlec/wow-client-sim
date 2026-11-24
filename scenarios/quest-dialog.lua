--@addons SimQuestieDB
--@login race=Orc,class=WARRIOR,level=12
-- The quest giver's windows as the client opens them, and the sounds that come with them: talking opens the gossip
-- window (placed by the game's panel manager), a quest chosen there opens the quest window (QUEST_DETAIL), Accept takes
-- it; once done, talking again offers it back, the window shows the reward (QUEST_COMPLETE) and Complete Quest hands it
-- in. Narration addons read the window (GetQuestID, the "npc" unit) and play their files (PlaySoundFile, lua/sound.lua).
local sound = require("sound")
local GIVER, QUEST = 3338, 844 -- Sergra Darkthorn, Plainstrider Menace
moveTo(1413, 0.52, 0.30)
local heard = {}
local listener = G.CreateFrame("Frame")
for _, event in ipairs({
    "GOSSIP_SHOW",
    "QUEST_DETAIL",
    "QUEST_COMPLETE",
    "QUEST_FINISHED",
    "QUEST_ACCEPTED",
    "QUEST_TURNED_IN",
}) do
    listener:RegisterEvent(event)
end
listener:SetScript("OnEvent", function(_, event)
    heard[#heard + 1] = event
end)

-- The offer
talk(GIVER)
wait(0.3)
expect(
    G.GossipFrame:IsVisible() and G.GossipFrame:GetLeft() ~= nil,
    "the gossip window opens, placed by the game's panel manager"
)
local offered = false
for _, offer in ipairs(G.C_GossipInfo.GetAvailableQuests()) do
    offered = offered or offer.questID == QUEST
end
expect(offered and G.C_GossipInfo.GetNumAvailableQuests() >= 1, "with the quest offered")
local soundsBefore = #sound.history
click("Plainstrider Menace")
wait(0.3)
expect(
    G.QuestFrame:IsVisible() and not G.GossipFrame:IsVisible(),
    "choosing it opens the quest window in the gossip window's place"
)
expect(G.GetQuestID() == QUEST and G.GetTitleText() == "Plainstrider Menace", "about the quest")
expect(
    G.UnitName("npc") == "Sergra Darkthorn" and tostring(G.UnitGUID("npc")):find("-" .. GIVER .. "-", 1, true),
    "the giver is the npc unit"
)
expectText("Collect 7 Plainstrider Beaks", "its objectives on the page")
expect(#sound.history > soundsBefore, "the window opened with the game's sound")
click("Accept")
wait(0.3)
expect(G.C_QuestLog.GetLogIndexForQuestID(QUEST) ~= nil, "Accept takes it into the log")
expect(not G.QuestFrame:IsVisible(), "and the window closes")

-- The reward
complete(QUEST)
talk(GIVER)
wait(0.3)
expect(G.C_GossipInfo.GetNumActiveQuests() == 1, "the giver offers it back, done")
click("Plainstrider Menace")
wait(0.3)
expect(G.QuestFrame:IsVisible() and G.QuestFrameRewardPanel:IsVisible(), "its reward window")
expect(G.IsQuestCompletable(), "done: it can be handed in")
click("Complete Quest")
wait(0.3)
expect(
    G.C_QuestLog.GetLogIndexForQuestID(QUEST) == nil and G.C_QuestLog.IsQuestFlaggedCompleted(QUEST),
    "Complete Quest hands it in"
)
expect(not G.QuestFrame:IsVisible(), "and the window closes")
local order = table.concat(heard, ",")
expect(
    order:find("GOSSIP_SHOW,QUEST_DETAIL,QUEST_ACCEPTED,QUEST_FINISHED", 1, true) ~= nil,
    "the offer's events in the client's order (" .. order .. ")"
)
expect(order:find("QUEST_COMPLETE,QUEST_TURNED_IN", 1, true) ~= nil, "the reward's too")

-- The page's Accept and Turn in go through the giver's windows too, as the player does (what reads them, a narration
-- addon, sees the offer and the reward)
local game = require("game")
heard = {}
listener:SetScript("OnEvent", function(_, event)
    heard[#heard + 1] = event
end)
expect(game.acceptFromGiver(869) == true, "the page takes Raptor Thieves at its giver") -- (Gazrog)
local taken = table.concat(heard, ",")
expect(
    taken:find("GOSSIP_SHOW,QUEST_DETAIL,QUEST_ACCEPTED,QUEST_FINISHED", 1, true) ~= nil,
    "through the quest window (" .. taken .. ")"
)
expect(not G.QuestFrame:IsVisible() and not G.GossipFrame:IsVisible(), "which closes again")

-- Sounds: a file on a channel has a handle and a length, stops when told; a switched-off channel plays nothing
local path = "Interface/AddOns/SimFixture/media/beep.wav"
local willPlay, handle = G.PlaySoundFile(path, "Dialog")
expect(willPlay and G.C_Sound.IsPlaying(handle), "an addon's sound plays, with its handle")
expect(math.abs((sound.history[#sound.history].length or 0) - 0.5) < 0.01, "its length read from the file (0.5 s)")
wait(1)
expect(not G.C_Sound.IsPlaying(handle), "over after its length")
local _, again = G.PlaySoundFile(path, "Dialog")
G.StopSound(again)
expect(not G.C_Sound.IsPlaying(again), "StopSound stops it")
expect(G.PlaySoundFile("Interface/AddOns/SimFixture/media/missing.wav", "Dialog") == false, "a missing file: false")
G.SetCVar("Sound_EnableDialog", "0")
expect(G.PlaySoundFile(path, "Dialog") == false, "the dialog channel switched off: false")
G.SetCVar("Sound_EnableDialog", "1")
local finishedHandle
listener:RegisterEvent("SOUNDKIT_FINISHED")
listener:SetScript("OnEvent", function(_, event, finished)
    if event == "SOUNDKIT_FINISHED" then
        finishedHandle = finished
    end
end)
local _, kitHandle = G.PlaySound(G.SOUNDKIT.IG_QUEST_LOG_OPEN, "SFX", false, true)
wait(4)
expect(kitHandle ~= nil and finishedHandle == kitHandle, "a kit played with a finish callback: SOUNDKIT_FINISHED")
