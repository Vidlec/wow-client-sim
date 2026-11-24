-- Walking as in the game: held keys run at 7 yards a second (4.5 backwards), turn about 180 degrees a second,
-- auto-run keeps going, and walking to a point turns to face it and stops there. Addons see the movement events,
-- IsPlayerMoving and GetUnitSpeed; a click on the minimap walks there.
local game = require("game")
setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
face(0) -- north
wait(0.5)

local events = {}
local listener = G.CreateFrame("Frame")
for _, name in ipairs({
    "PLAYER_STARTED_MOVING",
    "PLAYER_STOPPED_MOVING",
    "PLAYER_STARTED_TURNING",
    "PLAYER_STOPPED_TURNING",
}) do
    listener:RegisterEvent(name)
end
listener:SetScript("OnEvent", function(_, event)
    events[#events + 1] = event
end)
local function yardsFrom(start)
    local _, north, west = game.getPlayerWorldPosition()
    return math.sqrt((north - start[2]) ^ 2 + (west - start[3]) ^ 2)
end
local function here()
    return { game.getPlayerWorldPosition() }
end

-- Running: 2 seconds of W is 14 yards
local start = here()
local scene = require("scene")
scene.input({ type = "key", key = "W", isHeld = true })
wait(1)
expect(G.IsPlayerMoving() == true, "moving while W is held")
expect(select(1, G.GetUnitSpeed("player")) == 7, "at running speed, 7 yards a second")
wait(1)
scene.input({ type = "keyup", key = "W" })
wait(0.1)
expect(G.IsPlayerMoving() == false, "stopped when W came up")
local ran = yardsFrom(start)
expect(math.abs(ran - 14) < 0.8, string.format("2 seconds of running is 14 yards (ran %.1f)", ran))
expect(
    events[1] == "PLAYER_STARTED_MOVING" and events[#events] == "PLAYER_STOPPED_MOVING",
    "the movement events, in order"
)

-- Backwards is slower
start = here()
hold("S", 2)
local backed = yardsFrom(start)
expect(math.abs(backed - 9) < 0.8, string.format("2 seconds backwards is 9 yards (went %.1f)", backed))

-- Turning: half a second of A is about 90 degrees
local facing = game.profile.facing
hold("A", 0.5)
local turned = math.deg((game.profile.facing - facing) % (2 * math.pi))
expect(math.abs(turned - 90) < 6, string.format("half a second of turning is about 90 degrees (%.0f)", turned))

-- Walking to a point: it gets there at running speed
local _, north, west = game.getPlayerWorldPosition()
local targetX, targetY = 0.50, 0.33
local _, targetNorth, targetWest = game.mapToWorld(1413, targetX, targetY)
local distance = math.sqrt((targetNorth - north) ^ 2 + (targetWest - west) ^ 2)
local seconds = walkTo(1413, targetX, targetY)
expect(
    math.abs(seconds - distance / 7) < 1,
    string.format("%.0f yards took %.1f seconds, at 7 a second", distance, seconds)
)
expect(
    math.abs(game.profile.x - targetX) < 0.002 and math.abs(game.profile.y - targetY) < 0.002,
    "it stands on the point"
)

-- Auto-run keeps going without a key; S stops it
start = here()
key("NUMLOCK")
wait(1)
expect(G.IsPlayerMoving() == true, "auto-run moves without a key held")
expect(yardsFrom(start) > 2, "auto-run covers ground (" .. math.floor(yardsFrom(start)) .. " yards in a second)")
hold("S", 0.1)
wait(0.5)
expect(G.IsPlayerMoving() == false, "pressing S ends auto-run")

-- Click to walk on the minimap: a click above the arrow walks north
face(0)
local sim = require("sim")
sim.clickToWalk = true
local W = require("widgets")
local rect = W.computeRect(G.Minimap)
local centerX = (rect[1] + rect[3]) / 2
local topY = sim.screenHeight - (rect[2] + rect[4]) / 2 - (rect[4] - rect[2]) / 4 -- a quarter of the map above the middle
local before = here()
scene.input({ type = "down", x = centerX, y = topY, button = "LeftButton" })
scene.input({ type = "up", x = centerX, y = topY, button = "LeftButton" })
wait(20)
sim.clickToWalk = false
local after = here()
local walkedNorth = after[2] - before[2]
local expected = G.C_Minimap.GetViewRadius() / 2
expect(
    math.abs(walkedNorth - expected) < 2 and math.abs(after[3] - before[3]) < 2,
    string.format("a click half way up the minimap walks %.0f yards north (walked %.0f)", expected, walkedNorth)
)
