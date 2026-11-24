-- Moving the minimap as players do with the game's Edit Mode: switched on, the minimap dragged across the screen,
-- put down where it was dropped (kept on screen), and everything on it, an addon's marks too (the fixture's), goes
-- with it.
local W = require("widgets")
local scene = require("scene")
setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)
wait(1.5)

local function center(frame)
    local rect = W.computeRect(frame)
    return (rect[1] + rect[3]) / 2, G.GetScreenHeight() * G.UIParent:GetScale() - (rect[2] + rect[4]) / 2
end
local function minimapPinCount()
    local count, rect = 0, W.computeRect(G.Minimap)
    for _, child in ipairs({ G.Minimap:GetChildren() }) do
        local childRect = child:IsVisible() and W.computeRect(child)
        if child.mark and childRect and childRect[1] >= rect[1] - 20 and childRect[3] <= rect[3] + 20 then
            count = count + 1
        end
    end
    return count
end

local pinsBefore = minimapPinCount()
expect(pinsBefore > 0, "the fixture addon's marks are on the minimap")
local sim = require("sim")
sim.setEditMode(true)
local fromX, fromY = center(G.MinimapCluster)
scene.input({ type = "down", x = fromX, y = fromY, button = "LeftButton" })
scene.input({ type = "move", x = 300, y = 260 })
scene.input({ type = "up", x = 300, y = 260, button = "LeftButton" })
sim.setEditMode(false)
wait(0.5)
local toX, toY = center(G.MinimapCluster)
expect(
    math.abs(toX - 300) < 2 and math.abs(toY - 260) < 2,
    string.format("the minimap moved to where it was dropped (%d, %d)", toX, toY)
)
expect(minimapPinCount() == pinsBefore, "its marks moved with it")

-- Dropped past the edge, it stays on screen
sim.setEditMode(true)
fromX, fromY = center(G.MinimapCluster)
scene.input({ type = "down", x = fromX, y = fromY, button = "LeftButton" })
scene.input({ type = "move", x = -500, y = 2000 })
scene.input({ type = "up", x = -500, y = 2000, button = "LeftButton" })
sim.setEditMode(false)
local rect = W.computeRect(G.MinimapCluster)
expect(rect[1] >= -0.5 and rect[2] >= -0.5, "a minimap dropped off screen is kept on it")
moveMinimap("TOPRIGHT", 0, 0)
