--@login race=Scourge,class=MAGE,level=24
-- Achievements from the client's tables, and Forever's Legacy window that shows them as challenges. A level 24 mage
-- has none of the level 25 ones; reaching 25 earns its own class's (not another's), announced; the Legacy window
-- opens only with a renown level on the legacy track, lists the challenges, and finds them by search.
local sim = require("sim")

expect(G.CanShowAchievementUI(), "this client has achievements")
expect(#G.GetCategoryList() > 10, "with their categories (" .. #G.GetCategoryList() .. ")")
local classes
for _, id in ipairs(G.GetCategoryList()) do
    if G.GetCategoryInfo(id) == "Classes" then classes = id end
end
expect(classes and select(2, G.GetCategoryInfo(classes)) == -1, "Classes is a top category")

local function findEarned(title)
    for _, id in ipairs(G.GetCategoryList()) do
        for index = 1, (G.GetCategoryNumAchievements(id)) do
            local achievementId, name, _, isDone = G.GetAchievementInfo(id, index)
            if name == title then return achievementId, isDone end
        end
    end
end
local mageId, mageDone = findEarned("Novice Mage")
expect(mageId and not mageDone, "Novice Mage is there and not earned at 24")
local earnedNow = {}
local hook = sim.onEventFired
sim.onEventFired = function(event, id, ...)
    if event == "ACHIEVEMENT_EARNED" then earnedNow[#earnedNow + 1] = id end
    if hook then hook(event, id, ...) end
end
setProfile({ level = 25 })
wait(0.5)
sim.onEventFired = hook
local _, mageNow = findEarned("Novice Mage")
local _, warlockNow = findEarned("Novice Warlock")
expect(mageNow, "reaching 25 earns Novice Mage")
expect(not warlockNow, "and not another class's")
expect(#earnedNow >= 1, "the game is told (ACHIEVEMENT_EARNED)")
expect(G.GetAchievementLink(mageId):find("[Novice Mage]", 1, true), "its link names it")

-- The Legacy window: none without a renown level on its track; with one, the challenges list and the search
sim.runSecurely(G.ToggleLegacySystemUI)
wait(0.2)
expect(not (G.LegacySystemFrame and G.LegacySystemFrame:IsShown()), "no Legacy window before the track has a level")
setProfile({ legacyRenown = 1 })
sim.runSecurely(G.ToggleLegacySystemUI)
wait(0.3)
expect(G.LegacySystemFrame and G.LegacySystemFrame:IsShown(), "the Legacy window opens with renown 1")
sim.runSecurely(G.ToggleAchievementFrame)
wait(0.3)
expect(G.GetNumFilteredAchievements() > 100, "its challenges are listed (" .. G.GetNumFilteredAchievements() .. ")")
G.SetAchievementSearchString("Novice Mage")
wait(0.1)
expect(G.GetNumFilteredAchievements() == 1 and G.GetFilteredAchievementID(1) == mageId, "the search finds one by its title")
