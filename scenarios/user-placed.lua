-- Frames the player drags keep their place across a /reload, as the client's layout cache (layout-local.txt) keeps
-- them: StartMoving makes a frame user-placed; at logout every named, user-placed frame is written down unless
-- SetDontSavePosition(true) or SetUserPlaced(false) said not to; at the next login a frame of that name is put back as
-- it is made, user-placed already. An addon that places its frame again at every login fights that; one that asks
-- IsUserPlaced first leaves it alone.
local function makeFrames()
    local made = {}
    for _, name in ipairs({ "UserPlacedKept", "UserPlacedNotSaved", "UserPlacedCleared", "UserPlacedNever" }) do
        local frame = G.CreateFrame("Frame", name, G.UIParent)
        frame:SetSize(120, 60)
        frame:SetMovable(true)
        made[name] = frame
    end
    return made
end
local function placeDefault(frame) frame:ClearAllPoints(); frame:SetPoint("CENTER", G.UIParent, "CENTER", 0, 0) end
local function dragBy(frame, dx, dy)
    local x, y = frame:GetCenter()
    local screenY = G.GetScreenHeight() - y
    local scale = frame:GetEffectiveScale()
    local scene = require("scene")
    scene.input({ type = "move", x = x * scale, y = screenY * scale })
    frame:StartMoving()
    scene.input({ type = "move", x = (x + dx) * scale, y = (screenY - dy) * scale })
    frame:StopMovingOrSizing()
end

local frames = makeFrames()
for _, frame in pairs(frames) do
    expect(not frame:IsUserPlaced(), frame:GetName() .. " is not user-placed when made")
    placeDefault(frame)
end
wait(0.1)
dragBy(frames.UserPlacedKept, 200, 100)
dragBy(frames.UserPlacedNotSaved, -200, 100)
dragBy(frames.UserPlacedCleared, 0, -150)
expect(frames.UserPlacedKept:IsUserPlaced(), "a frame moved with StartMoving is user-placed")
frames.UserPlacedNotSaved:SetDontSavePosition(true)
expect(frames.UserPlacedNotSaved:GetDontSavePosition(), "GetDontSavePosition answers what was set")
-- (the game's Stopwatch does this at PLAYER_LOGOUT, to keep its frame out of the cache)
local unflagger = G.CreateFrame("Frame")
unflagger:RegisterEvent("PLAYER_LOGOUT")
unflagger:SetScript("OnEvent", function() G.UserPlacedCleared:SetUserPlaced(false) end)
local keptX, keptY = frames.UserPlacedKept:GetCenter()
local centerX, centerY = G.UIParent:GetCenter()
expect(math.abs(keptX - (centerX + 200)) < 1 and math.abs(keptY - (centerY + 100)) < 1,
    string.format("it moved with the cursor: %.0f, %.0f", keptX - centerX, keptY - centerY))

slash("/reload")
expect(G.UserPlacedKept == nil, "the old session's frames are gone after the reload")

-- The next session: the same addon code makes the frames again
local seenInLoad
local loaded = G.CreateFrame("Frame", "UserPlacedKept", G.UIParent)
seenInLoad = loaded:IsUserPlaced()
frames = { UserPlacedKept = loaded }
for _, name in ipairs({ "UserPlacedNotSaved", "UserPlacedCleared", "UserPlacedNever" }) do
    frames[name] = G.CreateFrame("Frame", name, G.UIParent)
end
for _, frame in pairs(frames) do frame:SetSize(120, 60) end
expect(seenInLoad, "a frame the player moved is user-placed again as soon as it is made")
expect(not frames.UserPlacedNotSaved:IsUserPlaced(), "SetDontSavePosition(true) kept it out of the cache")
expect(not frames.UserPlacedCleared:IsUserPlaced(), "SetUserPlaced(false) at PLAYER_LOGOUT kept it out")
expect(not frames.UserPlacedNever:IsUserPlaced(), "a frame never moved is not user-placed")
local x, y = frames.UserPlacedKept:GetCenter()
centerX, centerY = G.UIParent:GetCenter()
expect(math.abs(x - (centerX + 200)) < 1 and math.abs(y - (centerY + 100)) < 1,
    string.format("it is back where the player left it: %.0f, %.0f", x - centerX, y - centerY))
expect(frames.UserPlacedNotSaved:GetNumPoints() == 0, "the one not saved has no place until its addon gives it one")

-- An addon that asks first leaves the player's place alone; one that places its frame at every login moves it back
if not frames.UserPlacedKept:IsUserPlaced() then placeDefault(frames.UserPlacedKept) end
x = frames.UserPlacedKept:GetCenter()
expect(math.abs(x - (centerX + 200)) < 1, "asking IsUserPlaced first keeps the player's place")
placeDefault(frames.UserPlacedKept)
x = frames.UserPlacedKept:GetCenter()
expect(math.abs(x - centerX) < 1, "placing it anyway moves it back to the addon's place")
expect(frames.UserPlacedKept:IsUserPlaced(), "and leaves it user-placed (SetPoint does not clear the flag)")

-- Made from a template too (built as XML is: put back before its OnLoad)
placeDefault(frames.UserPlacedNever)
dragBy(frames.UserPlacedNever, 50, 50)
slash("/reload")
local frame = G.CreateFrame("Frame", "UserPlacedNever", G.UIParent, "BackdropTemplate")
frame:SetSize(120, 60)
expect(frame:IsUserPlaced(), "moved in the last session, a frame made from a template is user-placed too")
x = frame:GetCenter()
centerX = G.UIParent:GetCenter()
expect(math.abs(x - (centerX + 50)) < 1, string.format("and back where it was left: %.0f", x - centerX))
