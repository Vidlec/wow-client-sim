-- The world map zooms as the game's does: the wheel steps through the map's own zoom levels toward the point
-- under the cursor, dragging pans it within its edges, and a new map starts zoomed out.
setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
wait(0.5)
key("M")
wait(0.5)
local map = G.WorldMapFrame
local container = map.ScrollContainer
expect(mapZoomLevelCount() == 4, "the Barrens has the game's 4 zoom levels (got " .. mapZoomLevelCount() .. ")")
local outScale = map:GetCanvasScale()
local scaleChanges = 0
G.hooksecurefunc(map, "OnCanvasScaleChanged", function()
    scaleChanges = scaleChanges + 1
end)

-- A point of the map under the cursor stays under it as it zooms in
local W = require("widgets")
local rect = W.computeRect(container)
local sim = require("sim")
local pointX, pointY = rect[1] + (rect[3] - rect[1]) * 0.7, sim.screenHeight - (rect[2] + (rect[4] - rect[2]) * 0.4)
wheel({ pointX, pointY }, 1)
wait(0.6)
expect((map:GetCanvasZoomPercent() > 0.001) and map:GetCanvasScale() > outScale, "the wheel zooms in")
expect(scaleChanges == 1, "addons hear OnCanvasScaleChanged")
wheel({ pointX, pointY }, 1)
wheel({ pointX, pointY }, 1)
wheel({ pointX, pointY }, 1)
wait(0.6)
expect(math.abs(map:GetCanvasZoomPercent() - 1) < 0.001, "it stops at the deepest level")
local deepScale = map:GetCanvasScale()
expect(
    math.abs(deepScale / outScale - 2.14) < 0.02,
    string.format("2.14 times closer, as the map's data says (%.2f)", deepScale / outScale)
)

-- Dragging pans; the view stays on the map
-- (the game's own map gives a rectangle object, the simulator's stand-in its left and top)
local function viewLeftTop()
    local first, second = map:GetViewRect()
    if type(first) == "table" then
        return first:GetLeft(), first:GetTop()
    end
    return first, second
end
local left = viewLeftTop()
drag({ pointX, pointY }, { dx = 120, dy = 0 })
wait(0.6)
expect(viewLeftTop() < left, "dragging right shows more to the west")
drag({ pointX, pointY }, { dx = 3000, dy = 3000 })
wait(0.6)
local viewLeft, viewTop = viewLeftTop()
expect(viewLeft >= -0.001 and viewTop >= -0.001, "it cannot be dragged past the map's edge")

wheel({ pointX, pointY }, -1)
wheel({ pointX, pointY }, -1)
wheel({ pointX, pointY }, -1)
wait(0.6)
expect(not (map:GetCanvasZoomPercent() > 0.001), "the wheel zooms back out")

-- A new map starts zoomed out
wheel({ pointX, pointY }, 1)
map:SetMapID(1411)
wait(0.6)
expect(not (map:GetCanvasZoomPercent() > 0.001), "another map opens zoomed out")
