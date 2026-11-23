-- The scene stream (lua/stream.lua): a page that puts the scene together from the frames it is sent (a whole scene,
-- then only what changed) holds exactly what a whole export gives, every frame; with the mouse moving, the world map
-- opening and closing, an addon's window (the fixture's), and a page joining midway. Also: the layout kept between frames is the one
-- worked out afresh (the rectangles cached per object, thrown away only for what a change moves).
local json = require("json")
local scene = require("scene")
local stream = require("stream")
local W = require("widgets")
local S = W.state
local sim = require("sim")

setProfile({ level = 30, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.30) -- The Barrens
wait(0.5)

local held, order = {}, {}
local function apply(frame)
    if frame.whole then
        held, order = {}, {}
        for index, item in ipairs(frame.items) do
            local key = item.k .. item.i
            held[key], order[index] = item, key
        end
    elseif frame.delta then
        for _, item in ipairs(frame.u or {}) do held[item.k .. item.i] = item end
        if frame.o then order = frame.o end
    end
end
local function writeFrame(isWhole)
    local parts = {}
    if isWhole then
        stream.encodeWhole(parts)
        return json.decode("{\"whole\":true," .. table.concat(parts) .. "}")
    end
    if stream.getVersion() == sim.version then return {} end
    local isChanged = stream.encodeChanges(scene.export(), parts)
    stream.setVersion(sim.version)
    if not isChanged then return {} end
    return json.decode("{\"delta\":true," .. table.concat(parts) .. "}")
end
local function canonical(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local inner = value[key]
        if inner == nil then inner = value[tonumber(key)] end
        parts[#parts + 1] = key .. "=" .. canonical(inner)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
local checked = 0
local function check(label)
    local expected = json.decode(json.encode(scene.export()))
    local isSame = #order == #expected
    local firstDifference
    for index = 1, math.min(#order, #expected) do
        if canonical(held[order[index]]) ~= canonical(expected[index]) then
            isSame, firstDifference = false, index
            break
        end
    end
    checked = checked + 1
    expect(isSame, label .. ": the page's scene is the export's (" .. #order .. " vs " .. #expected .. " items"
        .. (firstDifference and ", first difference at " .. firstDifference or "") .. ")")
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
                if math.abs(fresh[index] - rect[index]) > 0.01 then differing = differing + 1; break end
            end
        end
    end
    expect(differing == 0, label .. ": rectangles kept between frames are as worked out afresh (" .. differing .. " differ)")
end

local function frames(label, count, area)
    for index = 1, count do
        local x = area[1] + (index * 37) % area[3]
        local y = area[2] + (index * 23) % area[4]
        hover({ x, y })
        sim.tick(1 / 60)
        apply(writeFrame(false))
        if index % 8 == 0 then check(label .. " frame " .. index) end
    end
    checkLayout(label)
end

stream.setVersion(nil)
writeFrame(false)
apply(writeFrame(true))
check("first whole scene")
frames("world", 40, { 300, 200, 700, 300 })
key("M")
wait(0.3)
frames("world map", 60, { 100, 150, 600, 450 })
apply(writeFrame(true)) -- a page joining midway
check("joined midway")
frames("world map, after joining", 24, { 100, 150, 600, 450 })
key("M")
wait(0.3)
frames("map closed", 16, { 300, 200, 700, 300 })
slash("/simfixture")
wait(0.5)
expect(G.SimFixtureWindow:IsVisible(), "the fixture's window is open")
frames("addon window", 40, { 600, 150, 600, 450 })
expect(checked > 20, "frames were checked")
