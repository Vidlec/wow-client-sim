--@addons QuestieDB, SimFixture
-- Running away (lua/combat.lua, the Combat panel's Run away): a level 14 rogue pulls two quilboar, then runs;
-- she turns her back on them and auto-runs, they chase (as fast as she runs, so they do not catch her), each gives up (EVADE)
-- once it is its leash from where she pulled it, and she is out of combat (PLAYER_REGEN_ENABLED) with the run over.
setProfile({ level = 14, race = "Scourge", class = "ROGUE" })
moveTo(1413, 0.52, 0.31) -- the Barrens
resetCombat(5)

local regenEnabled = 0
local listener = G.CreateFrame("Frame")
listener:RegisterEvent("PLAYER_REGEN_ENABLED")
listener:SetScript("OnEvent", function() regenEnabled = regenEnabled + 1 end)

local movement = require("movement")
local function where()
    local continentId, north, west = game.getPlayerWorldPosition()
    return continentId, north, west
end

expect(not combat.flee(), "with nothing fighting her, Run away refuses")
expect(not combat.player.isFleeing, "with nothing fighting her there is nothing to run from")

local first, ids = spawn(3111, { distance = 6, count = 2 }) -- Razormane Quilboar
waitUntil(function() return combat.player.inCombat end, 10, "they come at her")
expect(G.InCombatLockdown(), "in combat")
attack(first)
wait(1)

local _, startNorth, startWest = where()
flee()
expect(combat.player.isFleeing and movement.describe().isAutoRunning, "she runs: auto-run on")
expect(not combat.player.isAutoAttacking, "running stops her swings")
-- Her back to them: each is behind her now
for _, id in ipairs(ids) do
    local boar = enemy(id)
    expect(math.abs(boar.bearing) > math.pi / 2, boar.name .. " is behind her (" .. math.floor(math.deg(boar.bearing)) .. "°)")
end

local seconds = waitUntil(function() return not combat.player.inCombat end, 30, "they give up")
local _, endNorth, endWest = where()
local ran = math.sqrt((endNorth - startNorth) ^ 2 + (endWest - startWest) ^ 2)
expect(ran > 40, "she ran a good way (" .. math.floor(ran) .. " yards in " .. math.floor(seconds) .. " s)")
expect(not G.InCombatLockdown() and regenEnabled == 1, "out of combat: PLAYER_REGEN_ENABLED once")
expect(not combat.player.isFleeing and not movement.describe().isAutoRunning, "the run stops with the fight")
expect(G.UnitHealth("player") > 0, "alive")
local evaded = 0
for _, line in ipairs(combat.log) do
    if (line.text or ""):find("evades") then evaded = evaded + 1 end
end
expect(evaded >= 2, "both gave up (EVADE in the combat log: " .. evaded .. ")")

-- Stopping a run by hand: S (or the page's Stop) ends it, and she stays in the fight
resetCombat(6)
spawn(3111, { distance = 6 })
waitUntil(function() return combat.player.inCombat end, 10, "another comes at her")
flee()
wait(0.5)
hold("S", 0.2)

expect(not combat.player.isFleeing and not movement.describe().isAutoRunning, "S stops the run")
expect(combat.player.inCombat, "and she is still fighting")
