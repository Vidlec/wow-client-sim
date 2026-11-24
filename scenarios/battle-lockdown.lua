--@addons SimQuestieDB, SimFixture
-- Combat lockdown driven by a fight (lua/combat.lua): PLAYER_REGEN_DISABLED comes before the lockdown starts (its
-- handlers may still do protected things, as in the client) and PLAYER_REGEN_ENABLED after it ends; an addon's own
-- call to a protected function (targeting, casting) is forbidden, in combat or not, while the player's keys work; the
-- page's "In combat" switch stays an override that holds the lockdown whatever the fight does.
setProfile({ level = 10, race = "Orc", class = "WARRIOR" })
moveTo(1411, 0.52, 0.62) -- Durotar
resetCombat(5)

local lockdownAt = {}
local listener = G.CreateFrame("Frame")
listener:RegisterEvent("PLAYER_REGEN_DISABLED")
listener:RegisterEvent("PLAYER_REGEN_ENABLED")
listener:RegisterEvent("ADDON_ACTION_FORBIDDEN")
local forbidden = {}
listener:SetScript("OnEvent", function(_, event, _, functionName)
    if event == "ADDON_ACTION_FORBIDDEN" then
        forbidden[#forbidden + 1] = functionName
    else
        lockdownAt[event] = G.InCombatLockdown()
    end
end)

expect(not G.InCombatLockdown(), "no lockdown before the fight")
local boar = spawn(3111, { distance = 4 }) -- a quilboar right beside him: it attacks at once
wait(0.2)
expect(lockdownAt.PLAYER_REGEN_DISABLED == false, "PLAYER_REGEN_DISABLED is heard before the lockdown")
expect(G.InCombatLockdown() and G.UnitAffectingCombat("player"), "then the lockdown holds")
expect(enemy(boar).inCombat, "the quilboar is in combat too")

-- The scenario's own code is an addon's here: its protected calls are forbidden
G.TargetUnit("nameplate1")
G.CastSpellByID(78)
expect(
    #forbidden == 2 and forbidden[1] == "TargetUnit()" and forbidden[2] == "CastSpellByID()",
    "an addon may not target or cast: " .. table.concat(forbidden, ", ")
)
expect(not G.UnitExists("target"), "and nothing was targeted")
-- The player's own key does it
key("TAB")
expect(G.UnitName("target") == "Razormane Quilboar", "Tab (the player's key) targets it")

fight(boar, { slots = { 2 } })
expect(enemy(boar).isDead, "the quilboar dies")
expect(not G.InCombatLockdown(), "the fight over, the lockdown ends")
expect(lockdownAt.PLAYER_REGEN_ENABLED == false, "PLAYER_REGEN_ENABLED is heard after it has ended")

-- The page's switch: on, the lockdown holds through a fight's end
local sim = require("sim")
sim.inCombat = true
G.SetCVar("nameplateShowEnemies", "1")
local second = spawn(3111, { distance = 4 })
wait(0.2)
expect(G.InCombatLockdown(), "the switch on and a fight: locked down")
hurt(100000, second)
wait(0.2)
expect(enemy(second).isDead and G.InCombatLockdown(), "the fight over, the switch still holds the lockdown")
expect(not combatState().player.inCombat, "while the fight itself is over")
sim.inCombat = false
