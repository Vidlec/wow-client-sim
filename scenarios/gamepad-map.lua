--@login race=Orc,class=WARRIOR,level=12
-- The world map with a gamepad: in the gamepad interface the map opens with its focus on the map and the game's soft
-- cursor in it. The right stick zooms; the left stick moves the cursor (the game reads it as the "Left" stick) and,
-- at the map's edge, pans it, without walking the character; B closes it.
moveTo(1413, 0.52, 0.30)
wait(1)
if not G.GamepadMainActionBarFrame then
    print("skipped: the game's own gamepad interface is not loaded (light mode)")
    return
end
gamepadInterface(true)
key("M")
wait(0.5)
local map = G.WorldMapFrame
local scroll = map.ScrollContainer
expect(map:IsShown() and map:IsMapFocused(), "M opens the map, its focus on the map")
expect(G.SoftCursor:IsShown(), "the soft cursor stands in the map")

local scale = scroll:GetCanvasScale()
padStick("Camera", 0, 1, 1)
expect(scroll:GetCanvasScale() > scale, "the right stick zooms in")

local profile = require("game").profile
local before = { x = profile.x, y = profile.y }
local cursorX = scroll:GetGamepadCursorPosition()
local scrollX = scroll:GetNormalizedHorizontalScroll()
padStick("Movement", 1, 0, 2)
expect(scroll:GetGamepadCursorPosition() > cursorX + 50, "the left stick moves the cursor")
expect(scroll:GetNormalizedHorizontalScroll() > scrollX, "the cursor at the edge pans the map")
expect(profile.x == before.x and profile.y == before.y, "the character stands still while the map has the stick")

local mapId = map:GetMapID()
pad("PAD3")
wait(0.3)
local parent = G.C_Map.GetMapInfo(mapId).parentMapID
expect(
    map:GetMapID() == parent,
    "X goes up to the parent map (" .. tostring(map:GetMapID()) .. ", " .. tostring(parent) .. ")"
)

pad("PAD2")
wait(0.3)
expect(not map:IsShown(), "B closes the map")
expect(not G.SoftCursor:IsShown(), "the soft cursor goes with it")

-- With quests (a party member on them too, for the party's progress in their tooltips) and the quest panel open, the
-- map opens with its focus in the quest list: the d-pad moves the game's cursor through it (each quest's tooltip
-- shown as it goes), A opens a quest's details, B goes back, d-pad left goes to the map. No Lua error on the way.
accept(844)
accept(870)
accept(871)
joinParty({ name = "Garrix", class = "WARRIOR", level = 14 })
memberAccept("Garrix", 844)
memberAccept("Garrix", 870)
expect(G.GetCVar("questLogOpen") == "1", "the quest panel opens with the map, as the client's default has it")
key("M")
wait(0.5)
local navigation = G.SmartNavigation
expect(G.QuestMapFrame:IsShown() and map:IsQuestFocused(), "the map opens with its focus in the quest list")
local first = navigation.currentButton
pad("PADDDOWN")
expect(
    navigation.currentButton ~= nil and navigation.currentButton ~= first,
    "the d-pad moves the cursor in the quest list"
)
for _ = 1, 6 do
    if navigation.currentButton and navigation.currentButton.questID then
        break
    end
    pad("PADDDOWN")
end
expect(navigation.currentButton and navigation.currentButton.questID, "the cursor stands on a quest")
pad("PAD1")
wait(0.3)
expect(G.QuestMapFrame.DetailsFrame:IsShown() and map:IsQuestDetailsFocused(), "A opens the quest's details")
pad("PAD2")
wait(0.3)
expect(map:IsQuestFocused(), "B goes back to the list")
pad("PADDLEFT")
expect(map:IsMapFocused(), "d-pad left goes to the map")
pad("PAD2")
wait(0.3)
expect(not map:IsShown(), "B closes the map")
gamepadInterface(false)
