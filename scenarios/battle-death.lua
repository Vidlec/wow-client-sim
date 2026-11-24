--@addons QuestieDB, SimFixture
-- The player dying and coming back (lua/combat.lua): a quilboar far above a level 6 mage's level beats her; she dies
-- (PLAYER_DEAD, the game's release dialog), the creature gives up and she is out of combat; she releases her spirit
-- (a ghost: PLAYER_ALIVE) and comes back at her corpse (PLAYER_UNGHOST) with half her health and mana.
setProfile({ level = 6, race = "Troll", class = "MAGE" })
moveTo(1411, 0.52, 0.62) -- Durotar
resetCombat(3)
G.SetCVar("nameplateShowEnemies", "1")

local events = {}
local listener = G.CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_DEAD",
    "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}) do
    listener:RegisterEvent(event)
end
listener:SetScript("OnEvent", function(_, event)
    events[#events + 1] = event
end)
local function saw(name)
    for _, event in ipairs(events) do
        if event == name then
            return true
        end
    end
    return false
end
local healthChanges = 0
local playerHealth = G.CreateFrame("Frame")
playerHealth:RegisterUnitEvent("UNIT_HEALTH", "player")
playerHealth:SetScript("OnEvent", function()
    healthChanges = healthChanges + 1
end)

local brute = spawn(3114, { distance = 6, level = 16 }) -- a Razormane Battleguard, ten levels up
expect(G.UnitLevel("nameplate1") == -1, "ten levels above her: its level shows as ?? (-1)")
local seconds = waitUntilDead("player", 90)
expect(
    G.UnitIsDead("player") and G.UnitIsDeadOrGhost("player") and G.UnitHealth("player") == 0,
    "she dies (after " .. math.floor(seconds) .. " s)"
)
expect(healthChanges > 2, "her UNIT_HEALTH came with every blow (" .. healthChanges .. ")")
expect(saw("PLAYER_DEAD"), "PLAYER_DEAD")
expect(G.StaticPopup_Visible and G.StaticPopup_Visible("DEATH"), "the game asks her to release her spirit")
expect(G.GetReleaseTimeRemaining() > 0, "with the time left to release")
wait(0.5)
expect(
    not enemy(brute).inCombat and not G.InCombatLockdown() and saw("PLAYER_REGEN_ENABLED"),
    "the quilboar gives up; she is out of combat"
)
local ok = G.C_ActionBar.IsUsableAction(1)
expect(not ok, "the dead cast nothing: Fireball is not usable")
saveScene("dead")

release()
expect(G.UnitIsGhost("player") and not G.UnitIsDead("player") and G.UnitIsDeadOrGhost("player"), "released: a ghost")
expect(saw("PLAYER_ALIVE"), "PLAYER_ALIVE as she releases")
expect(not (G.StaticPopup_Visible and G.StaticPopup_Visible("DEATH")), "the release dialog goes")

resurrect()
expect(not G.UnitIsDeadOrGhost("player"), "back to life")
expect(saw("PLAYER_UNGHOST"), "PLAYER_UNGHOST")
local health, healthMax = G.UnitHealth("player"), G.UnitHealthMax("player")
expect(health == math.floor(healthMax / 2), "with half her health (" .. health .. " of " .. healthMax .. ")")
expect(G.UnitPower("player") == math.floor(G.UnitPowerMax("player") / 2), "and half her mana")
expect(G.C_ActionBar.IsUsableAction(1), "Fireball is usable again")
