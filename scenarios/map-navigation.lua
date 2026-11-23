--@login race=Tauren,class=WARRIOR,level=12
-- The game's own world map, used as a player uses it (needs the whole interface): the wheel zooms in on the place
-- under the cursor and the drawn map moves with the scroll; the cursor over a zone names it and lights its shape;
-- a click opens the zone, a right-click goes back up; the nav bar's buttons have their dropdowns; a Ctrl+click
-- sets the map pin, shown on the continent too.
moveTo(1413, 0.52, 0.30) -- The Barrens
wait(0.5)
key("M")
wait(1)

local scene, W, sim = require("scene"), require("widgets"), require("sim")
local map = G.WorldMapFrame
if not (map and map.ScrollContainer and map.ScrollContainer.Child and G.MapCanvasScrollControllerMixin) then
    print("skipped: the game's own world map is not loaded (light mode)")
    return
end
local container = map.ScrollContainer

---@return number x, number y A place on the map's canvas (0..1 across its art) as the page counts, top down
local function toPage(normalX, normalY)
    local rect = W.computeRect(container.Child)
    return rect[1] + normalX * (rect[3] - rect[1]), sim.screenHeight - (rect[4] - normalY * (rect[4] - rect[2]))
end
---@return number x, number y The place on the map's art under a point of the page
local function fromPage(x, y)
    local rect = W.computeRect(container.Child)
    return (x - rect[1]) / (rect[3] - rect[1]), ((sim.screenHeight - y) - rect[4]) / (rect[2] - rect[4])
end
local function moveMouse(x, y)
    scene.input({ type = "move", x = x, y = y })
    wait(0.1)
end
local function clickAt(x, y, button, mods)
    scene.input({ type = "move", x = x, y = y, mods = mods })
    scene.input({ type = "down", x = x, y = y, button = button or "LeftButton", mods = mods })
    scene.input({ type = "up", x = x, y = y, button = button or "LeftButton", mods = mods })
    wait(0.3)
end

-- The wheel: the place under the cursor stays under it, and the drawn map moves (it hung still before, its own
-- anchor kept over the scroll)
local frameRect = W.computeRect(container)
local cursorX, cursorY = frameRect[1] + (frameRect[3] - frameRect[1]) * 0.7, sim.screenHeight - (frameRect[2] + (frameRect[4] - frameRect[2]) * 0.4)
moveMouse(cursorX, cursorY)
local beforeX, beforeY = fromPage(cursorX, cursorY)
local scaleBefore = container:GetCanvasScale()
scene.input({ type = "wheel", x = cursorX, y = cursorY, delta = 1 })
wait(0.3)
expect(container:GetCanvasScale() > scaleBefore, "the wheel zooms in")
local afterX, afterY = fromPage(cursorX, cursorY)
expect(math.abs(afterX - beforeX) < 0.01 and math.abs(afterY - beforeY) < 0.01,
    string.format("the place under the cursor stays under it (%.3f,%.3f -> %.3f,%.3f)", beforeX, beforeY, afterX, afterY))
-- A drag pans the zoomed map: the drawn map follows the cursor
local childLeft = W.computeRect(container.Child)[1]
scene.input({ type = "move", x = cursorX, y = cursorY })
scene.input({ type = "down", x = cursorX, y = cursorY, button = "LeftButton" })
for step = 1, 6 do
    scene.input({ type = "move", x = cursorX + step * 15, y = cursorY })
    wait(0.05)
end
scene.input({ type = "up", x = cursorX + 90, y = cursorY, button = "LeftButton" })
wait(0.3)
expect(W.computeRect(container.Child)[1] > childLeft + 30, "dragging right moves the drawn map right")

-- The continent: a zone named and lit under the cursor, opened by a click
map:SetMapID(1414)
wait(0.5)
local barrensX, barrensY = toPage(0.565, 0.57)
moveMouse(barrensX, barrensY)
wait(0.2)
local info = G.C_Map.GetMapInfoAtPosition(1414, fromPage(barrensX, barrensY))
expect(info and info.mapID == 1413, "the cursor over The Barrens finds The Barrens (" .. tostring(info and info.name) .. ")")
local areaLabel
for provider in pairs(map.dataProviders or {}) do if provider.Label and provider.Label.Name then areaLabel = provider.Label.Name end end
expect(areaLabel and areaLabel:IsVisible() and areaLabel:GetText() == "The Barrens", "the zone's name shows over the map")
local highlight
for pin in map:EnumeratePinsByTemplate("MapHighlightPinTemplate") do highlight = pin.HighlightTexture end
expect(highlight and highlight:IsShown() and highlight:GetTexture() == 137094, "The Barrens' shape lights up")
local mulgore = G.C_Map.GetMapInfoAtPosition(1414, 0.48, 0.62)
expect(mulgore and mulgore.mapID == 1412, "beside it, Mulgore (" .. tostring(mulgore and mulgore.name) .. ")")
expect(G.C_Map.GetMapInfoAtPosition(1414, 0.15, 0.5) == nil, "the sea is no zone")
clickAt(barrensX, barrensY)
expect(map:GetMapID() == 1413, "a click opens The Barrens")
clickAt(barrensX, barrensY, "RightButton")
expect(map:GetMapID() == 1414, "a right-click goes back to Kalimdor")

-- The world: each continent where it is drawn
local world = { kalimdor = G.C_Map.GetMapInfoAtPosition(947, 0.25, 0.5), kingdoms = G.C_Map.GetMapInfoAtPosition(947, 0.75, 0.45) }
expect(world.kalimdor and world.kalimdor.mapID == 1414 and world.kingdoms and world.kingdoms.mapID == 1415,
    "on the world map, Kalimdor on the left and the Eastern Kingdoms on the right")

-- The nav bar: a continent's and a zone's buttons drop down their neighbours
map:SetMapID(1413)
wait(0.3)
expect(G.C_Map.IsMapValidForNavBarDropdown(1413) and G.C_Map.IsMapValidForNavBarDropdown(1414) and not G.C_Map.IsMapValidForNavBarDropdown(947),
    "zones and continents drop down in the nav bar; the world does not")
local withList = 0
for _, button in ipairs(map.NavBar.navList or {}) do
    if button.data and button.data.listFunc then withList = withList + 1 end
end
expect(withList == 2, "Kalimdor's and The Barrens' buttons have dropdowns (" .. withList .. ")")

-- The map pin: Ctrl+click sets it, and the continent shows it where it is
local pinX, pinY = toPage(0.4, 0.6)
clickAt(pinX, pinY, "LeftButton", { ctrl = true })
local waypoint = G.C_Map.GetUserWaypoint()
expect(waypoint and waypoint.uiMapID == 1413 and math.abs(waypoint.position.x - 0.4) < 0.02, "Ctrl+click sets the map pin there")
local onKalimdor = G.C_Map.GetUserWaypointPositionForMap(1414)
expect(onKalimdor and onKalimdor.x > 0.39 and onKalimdor.x < 0.67, "the pin is on Kalimdor's map too, inside The Barrens")
expect((G.C_Map.GetUserWaypointHyperlink() or ""):find("|Hworldmap:1413:4000:6000|h", 1, true) ~= nil, "the pin's chat link")
