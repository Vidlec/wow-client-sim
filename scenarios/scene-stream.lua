-- The scene stream (lua/stream.lua, lua/scenesync.lua): the native walk's store, which holds what a page holds after
-- the frames it was sent (a whole scene, then only what changed), is exactly what a whole export gives, every frame;
-- with the mouse moving, the world map opening and closing, an addon's window (the fixture's), and a page joining
-- midway. Also: the layout kept between frames is the one worked out afresh (the rectangles cached per object, thrown
-- away only for what a change moves).
local scene = require("scene")
local scenesync = require("scenesync")
local stream = require("stream")
local W = require("widgets")
local sim = require("sim")

setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.30) -- The Barrens
wait(0.5)

---A frame as the server's clock makes one: the walk's changes since the last
local function writeFrame()
    if stream.getVersion() ~= sim.version then
        scenesync.frame()
        stream.setVersion(sim.version)
    end
end
local checked = 0
local function check(label)
    local problem = scene.findWalkDifference(scene.export())
    checked = checked + 1
    expect(problem == nil, label .. ": the page's scene is the export's" .. (problem and " (" .. problem .. ")" or ""))
end
-- Every shown frame's rectangle, as kept, against the same worked out with nothing kept
local function checkLayout(label)
    local kept = {}
    for _, frame in ipairs(scene.getSortedFrames()) do
        local rect = W.computeRect(frame)
        kept[frame] = rect and { rect[1], rect[2], rect[3], rect[4] } or false
    end
    sim.touch() -- (everything worked out again)
    local differing = 0
    for frame, rect in pairs(kept) do
        local fresh = W.computeRect(frame)
        if (fresh == nil) ~= (rect == false) then
            differing = differing + 1
        elseif fresh then
            for index = 1, 4 do
                if math.abs(fresh[index] - rect[index]) > 0.01 then
                    differing = differing + 1
                    break
                end
            end
        end
    end
    expect(
        differing == 0,
        label .. ": rectangles kept between frames are as worked out afresh (" .. differing .. " differ)"
    )
end

local function frames(label, count, area)
    for index = 1, count do
        local x = area[1] + (index * 37) % area[3]
        local y = area[2] + (index * 23) % area[4]
        hover({ x, y })
        sim.tick(1 / 60)
        writeFrame()
        if index % 8 == 0 then
            check(label .. " frame " .. index)
        end
    end
    checkLayout(label)
end

stream.setVersion(nil)
writeFrame()
check("first whole scene")
frames("world", 40, { 300, 200, 700, 300 })
key("M")
wait(0.3)
frames("world map", 60, { 100, 150, 600, 450 })
check("joined midway") -- (a page joining midway: the store's whole scene)
frames("world map, after joining", 24, { 100, 150, 600, 450 })
key("M")
wait(0.3)
frames("map closed", 16, { 300, 200, 700, 300 })
slash("/simfixture")
wait(0.5)
expect(G.SimFixtureWindow:IsVisible(), "the fixture's window is open")
frames("addon window", 40, { 600, 150, 600, 450 })
expect(checked > 20, "frames were checked")
