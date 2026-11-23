--@login race=Orc,class=WARRIOR,level=12
-- The game's gamepad interface, played with a gamepad (needs the whole interface): switched on, it takes Edit Mode's
-- Gamepad layout and its own action bars; Start opens the radial menu, the right stick picks a slice (the bags); the
-- d-pad moves the game's navigation cursor in them and B closes them; the left stick walks; switched off, the usual
-- bars come back. Nothing on the way is blocked as an addon's action.
moveTo(1413, 0.52, 0.30)
wait(1)
if not G.GamepadMainActionBarFrame then
    print("skipped: the game's own gamepad interface is not loaded (light mode)")
    return
end
local blocked = 0
G.hooksecurefunc("DisplayInterfaceActionBlockedMessage", function() blocked = blocked + 1 end)

gamepadInterface(true)
expect(G.C_InputInterfaceStyle.GetCurrentStyle() == 1 and G.InputUtil.IsGamepadUIEnabled(), "the interface is the gamepad's")
expect(G.GamepadMainActionBarFrame:IsVisible(), "the gamepad's action bars show")
expect(not (G.MainActionBar or G.MainMenuBar):IsVisible(), "the usual action bar is hidden")
expect(G.EditModeManagerFrame:GetActiveLayoutInfo().layoutName == G.LAYOUT_STYLE_GAMEPAD or G.C_EditMode.GetLayouts().activeLayout == 3,
    "Edit Mode's Gamepad layout is the active one")
local barRect = require("widgets").computeRect(G.GamepadMainActionBarFrame)
expect(barRect and barRect[2] < 300, "the gamepad bars stand at the bottom of the screen")
saveScene("gamepad-interface")

-- The radial menu: Start, then the right stick to the right (the bags) and let go
pad("PADFORWARD")
expect(G.GamepadRadial and G.GamepadRadial:IsShown(), "Start opens the radial menu")
padStick("Camera", 1, 0, 0.4)
wait(0.3)
expect(not G.GamepadRadial:IsShown(), "the stick let go picks the slice and closes the menu")
expect(G.ContainerFrameCombinedBags:IsShown(), "the slice to the right opens the bags")
local navigation = G.SmartNavigation
local first = navigation and navigation.currentButton
expect(first ~= nil, "the game's navigation cursor stands in them")
pad("PADDRIGHT")
expect(navigation.currentButton ~= nil and navigation.currentButton ~= first, "the d-pad moves the cursor")
saveScene("gamepad-bags")
pad("PAD2")
wait(0.3)
expect(not G.ContainerFrameCombinedBags:IsShown(), "B closes the bags")

-- The left stick walks the character
local profile = require("game").profile
local before = { x = profile.x, y = profile.y }
padStick("Movement", 0, 1, 1)
expect(math.abs(profile.x - before.x) + math.abs(profile.y - before.y) > 0.0005, "the left stick walks the character")

-- The ping wheel: R3 held opens it and it stays open; it takes the right stick and B, and lets every other button
-- go on to its binding (its handler answers true), so R3 again closes it and Start still opens the radial menu
pad("PADRSTICK", 1)
wait(0.3)
expect(G.PingFrame:IsShown(), "R3 held opens the ping wheel")
pad("PADFORWARD")
expect(G.GamepadRadial:IsShown(), "Start goes past the open ping wheel to the radial menu")
pad("PADFORWARD")
wait(0.3)
expect(not G.GamepadRadial:IsShown(), "Start again closes the radial menu")
pad("PADRSTICK")
wait(0.5)
expect(not G.PingFrame:IsShown() and not G.PingFrame:IsGamePadButtonEnabled(), "R3 again closes the ping wheel and lets the pad go")

-- The triggers switch the crossbar: held, LT makes the left set the active one, RT the right one
local pageUnit = G.GamepadMainActionBarFrame.PageUnit
local function activeSet()
    local bar = pageUnit:GetActiveBar()
    for name, each in pairs(pageUnit.actionBars) do if each == bar then return name end end
end
local gamepad, sim = require("gamepad"), require("sim")
sim.runSecurely(gamepad.press, "PADLTRIGGER")
wait(0.2)
expect(activeSet() == "leftBar", "LT held: the left set is active (" .. tostring(activeSet()) .. ")")
sim.runSecurely(gamepad.release, "PADLTRIGGER")
wait(0.2)
expect(activeSet() == "topBar", "LT let go: the main set again")
sim.runSecurely(gamepad.press, "PADRTRIGGER")
wait(0.2)
expect(activeSet() == "rightBar", "RT held: the right set is active (" .. tostring(activeSet()) .. ")")
sim.runSecurely(gamepad.release, "PADRTRIGGER")
wait(0.2)

expect(blocked == 0, "no action of the game's is blocked as an addon's (" .. blocked .. ")")

gamepadInterface(false)
expect(G.C_InputInterfaceStyle.GetCurrentStyle() == 0, "back to mouse and keyboard")
expect(not G.GamepadMainActionBarFrame:IsVisible() and (G.MainActionBar or G.MainMenuBar):IsVisible(), "the usual action bar is back")
