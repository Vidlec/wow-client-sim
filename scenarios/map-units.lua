--@login race=Scourge,class=MAGE,level=30
-- The world map's group members and panning, as the game has them (needs the whole interface: the game's own map
-- draws them through its UnitPositionFrame): the player's arrow and a member's class-coloured dot where each stands,
-- on the zone and on the continent; and a quick drag across the zoomed map pans it, as the page sends one.
setProfile({ level = 30 })
moveTo(1413, 0.54, 0.33) -- The Barrens, by the Crossroads
joinParty({ name = "Garra", class = "WARRIOR", level = 30, addon = "none" })
memberMoveTo("Garra", 1413, 0.50, 0.30)
face(135) -- (facing north exactly, the arrow has no turn to show)
wait(0.5)
key("M")
wait(1)

local scene, W, sim = require("scene"), require("widgets"), require("sim")
local map = G.WorldMapFrame
if not (map and map.ScrollContainer and map.ScrollContainer.Child and G.UnitPositionFrameMixin) then
    print("skipped: the game's own world map is not loaded (light mode)")
    return
end

---@return table? item The drawn marker of a unit ("player", "party1"), from the drawing list
local function findUnitItem(unit)
    for _, item in ipairs(scene.export()) do
        if type(item.i) == "string" and item.i:match("u" .. unit .. "$") then return item end
    end
end
---@return number x, number y Where a unit should be drawn: its map position on the canvas, as the page counts
local function expectedSpot(mapId, unit)
    local position = G.C_Map.GetPlayerMapPosition(mapId, unit)
    local rect = W.computeRect(map.ScrollContainer.Child)
    local x = rect[1] + position.x * (rect[3] - rect[1])
    local y = sim.screenHeight - (rect[4] - position.y * (rect[4] - rect[2]))
    return x, y
end
local function isNear(item, x, y)
    return item and math.abs(item.x + item.w / 2 - x) < 1.5 and math.abs(item.y + item.h / 2 - y) < 1.5
end

-- On the zone's map
local arrow, dot = findUnitItem("player"), findUnitItem("party1")
expect(arrow and arrow.atlas == "UI-WorldMapArrow", "the player's arrow is drawn with the game's art")
expect(isNear(arrow, expectedSpot(1413, "player")), "the arrow stands where the player is")
expect(arrow and arrow.rot ~= nil, "the arrow turns with the player's facing")
local red, green, blue = G.GetClassColor("WARRIOR")
expect(dot and dot.atlas == "WhiteCircle-RaidBlips" and dot.vc and math.abs(dot.vc[1] - red) < 0.01 and math.abs(dot.vc[3] - blue) < 0.01,
    "Garra's dot is drawn in the warrior's class colour")
expect(dot and dot.w > 9 and dot.w < 12, "a party member's dot is the party size, not the raid's (" .. tostring(dot and dot.w) .. ")")
expect(isNear(dot, expectedSpot(1413, "party1")), "the dot stands where Garra is")

-- On the continent: members are placed by their world position, not their zone's numbers
map:SetMapID(1414)
wait(0.5)
local onKalimdor = G.C_Map.GetPlayerMapPosition(1414, "party1")
expect(onKalimdor and onKalimdor.x > 0.39 and onKalimdor.x < 0.67 and onKalimdor.y > 0.45 and onKalimdor.y < 0.74,
    "on Kalimdor, Garra is inside the Barrens")
expect(isNear(findUnitItem("party1"), expectedSpot(1414, "party1")), "on Kalimdor, the dot moves with the map")

-- A quick drag on the zoomed map, as the page sends one: the release right after the last move
map:SetMapID(1413)
wait(0.5)
zoomMap(1, 2)
wait(1)
local container = map.ScrollContainer
local beforeX, beforeY = container:GetNormalizedHorizontalScroll(), container:GetNormalizedVerticalScroll()
local rect = W.computeRect(container)
local middleX, middleY = (rect[1] + rect[3]) / 2, sim.screenHeight - (rect[2] + rect[4]) / 2
scene.input({ type = "move", x = middleX, y = middleY })
scene.input({ type = "down", x = middleX, y = middleY, button = "LeftButton" })
scene.input({ type = "up", x = middleX - 80, y = middleY - 60, button = "LeftButton" })
wait(0.5)
expect(container:GetNormalizedHorizontalScroll() > beforeX + 0.01 and container:GetNormalizedVerticalScroll() > beforeY + 0.01,
    "a quick drag up and left pans the map to show more of its lower right")
