-- The client's layout cache (layout-local.txt, kept per character): where the player put the frames they moved.
-- A frame moved with StartMoving becomes user-placed (IsUserPlaced); at logout, after PLAYER_LOGOUT has run (the
-- game's Stopwatch and battlefield map tab clear the flag there, SetUserPlaced(false), to keep themselves out of it),
-- the client writes down every named frame that is user-placed and not SetDontSavePosition(true) (dontSavePosition
-- in XML). At the next login a frame of that name is put back where it was as it is made: XML anchors and a template's
-- are overridden, and it is user-placed already in its OnLoad and right after CreateFrame, so an addon that places its
-- frame then (unless IsUserPlaced) leaves the player's place alone, and one that always places it fights the cache.
-- Not measured in the client yet (the recorder's "userPlaced" probe asks): when exactly the restore happens (at
-- creation, as here, or later in the login), which point the frame is anchored by, and whether a frame needs to be
-- movable. Kept in the saved-variables folder as _layout.json.
local sim = require("sim")
local W = require("widgets")
local S = W.state
local json = require("json")

local layout = {}
local entries -- name -> { point, relativePoint, x, y }; read on first use, once the saved folder is known

local function cachePath()
    local addons = package.loaded["addons"]
    local folder = addons and addons.savedRoot
    return folder and (folder .. "/_layout.json") or nil
end

local function read()
    if entries then
        return entries
    end
    local path = cachePath()
    if not path then
        return nil
    end -- (frames made before the boot knows its folder: the simulator's own)
    entries = {}
    local file = io.open(path, "rb")
    if file then
        local isRead, value = pcall(json.decode, file:read("*a"))
        file:close()
        if isRead and type(value) == "table" and type(value.frames) == "table" then
            entries = value.frames
        end
    end
    return entries
end

---A frame just made, before its OnLoad: put where the player left it, when the cache has its name.
function layout.restore(frame)
    local s = S[frame]
    local name = s and s.name
    if not name then
        return
    end
    local cache = read()
    local entry = cache and cache[name]
    if type(entry) ~= "table" then
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint(
        entry.point or "TOPLEFT",
        sim.G.UIParent,
        entry.relativePoint or "BOTTOMLEFT",
        tonumber(entry.x) or 0,
        tonumber(entry.y) or 0
    )
    s.userPlaced = true
end

---At logout: every named, user-placed frame that may be saved, where it stands (its top left, from the screen's
---bottom left in the frame's own units, as a frame being moved is anchored). The cache's other frames, not made this
---session (an addon loaded on demand, not loaded), are kept.
function layout.save()
    local path = cachePath()
    if not path then
        return
    end
    local cache = read() or {}
    for _, frame in ipairs(W.frames) do
        local s = S[frame]
        local name = s and s.name
        if name and sim.G[name] == frame then
            local rect = s.userPlaced and not s.dontSavePosition and W.computeRect(frame)
            if rect then
                local scale = W.getEffectiveScale(frame)
                cache[name] = {
                    point = "TOPLEFT",
                    relativePoint = "BOTTOMLEFT",
                    x = math.floor(rect[1] / scale * 100 + 0.5) / 100,
                    y = math.floor(rect[4] / scale * 100 + 0.5) / 100,
                }
            else
                cache[name] = nil
            end
        end
    end
    entries = cache
    local file = io.open(path, "wb")
    if file then
        file:write(json.encode({ frames = cache }))
        file:close()
    end
end

return layout
