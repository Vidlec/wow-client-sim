-- The game's own Edit Mode, as a player uses it: opened, the main action bar picked and dragged, action bar 2
-- turned on (the game's Settings, Action Bars), the bar made bigger with its dialog's Icon Size slider, the changes
-- saved as a new layout (Save on a preset asks for a name), Edit Mode left: all of it stays, and is what the
-- account keeps for the next login (C_EditMode.GetLayouts, the action bar toggles).
-- It caught Edit Mode's systems not draggable (registerForDrag in XML), a raised window covering the dialogs
-- shown over it, Save on a preset keeping nothing, and action bars 2 to 8 that could not be turned on.
local sim = require("sim")
local W = require("widgets")
local scene = require("scene")

local function rectOf(frame) return W.computeRect(frame) end
local function centre(frame)
    local rect = rectOf(frame)
    return (rect[1] + rect[3]) / 2, sim.screenHeight - (rect[2] + rect[4]) / 2
end
local function drag(frame, dx, dy)
    local x, y = centre(frame)
    scene.input({ type = "move", x = x, y = y })
    scene.input({ type = "down", x = x, y = y, button = "LeftButton" })
    for step = 1, 10 do scene.input({ type = "move", x = x + dx * step / 10, y = y + dy * step / 10 }); wait(0.02) end
    scene.input({ type = "up", x = x + dx, y = y + dy, button = "LeftButton" })
    wait(0.1)
end

local manager, bar, bar2, bar3 = G.EditModeManagerFrame, G.MainActionBar, G.MultiBarBottomLeft, G.MultiBarBottomRight
local iconSize = G.Enum.EditModeActionBarSetting.IconSize
local startRect = rectOf(bar)
expect(not bar2:IsShown(), "a new character has no action bar 2")

-- Opened as the game menu's Edit Mode button opens it
sim.runSecurely(G.ShowUIPanel, manager)
wait(0.2)
expect(manager:IsShown() and manager:IsEditModeActive(), "Edit Mode opens")
expect(bar.Selection:IsVisible(), "the main bar shows its selection box")

-- Action bar 2, as the Action Bars page's checkbox sets it; bar 3 as an addon does it
sim.runSecurely(G.Settings.SetValue, "PROXY_SHOW_ACTIONBAR_2", true)
wait(0.1)
expect(bar2:IsShown(), "action bar 2 turned on shows")
expect(bar2.Selection and bar2.Selection:IsVisible(), "and can be picked in Edit Mode")
G.SetActionBarToggles(true, true, false, false, false, false, false)
wait(0.1)
expect(bar3:IsShown(), "action bar 3 shows once its toggle is set")

-- Picked, then dragged up and to the right
click(bar.Selection)
wait(0.1)
expect(G.EditModeSystemSettingsDialog:IsShown(), "picking the bar opens its settings")
drag(bar.Selection, 80, -120)
local movedRect = rectOf(bar)
expect(movedRect[1] > startRect[1] + 40 and movedRect[2] > startRect[2] + 60, "the bar follows the drag")
expect(manager:HasActiveChanges(), "Edit Mode notes the change")

-- Bigger: the Icon Size slider dragged to its end
local dialog = G.EditModeSystemSettingsDialog
local slider
for _, row in ipairs({ dialog.Settings:GetChildren() }) do
    if row.setting == iconSize then slider = row.Slider and (row.Slider.Slider or row.Slider) end
end
expect(slider and slider:IsVisible(), "the bar's dialog has its Icon Size slider")
if slider then
    local rect = rectOf(slider)
    local y = sim.screenHeight - (rect[2] + rect[4]) / 2
    scene.input({ type = "move", x = (rect[1] + rect[3]) / 2, y = y })
    scene.input({ type = "down", x = (rect[1] + rect[3]) / 2, y = y, button = "LeftButton" })
    scene.input({ type = "move", x = rect[3] - 1, y = y })
    scene.input({ type = "up", x = rect[3] - 1, y = y, button = "LeftButton" })
    wait(0.1)
end
expect(bar:GetSettingValue(iconSize) == 200, "the slider sets the icon size (" .. tostring(bar:GetSettingValue(iconSize)) .. ")")
local bigRect = rectOf(bar)
expect(bigRect[3] - bigRect[1] > (movedRect[3] - movedRect[1]) * 1.5, "the bar grows with its icons")

-- Saved: the dialog closed (it stands over Save at this screen size), Save, a name for the new layout
click(dialog.CloseButton)
wait(0.1)
click(manager.SaveChangesButton)
wait(0.1)
local layoutDialog = G.EditModeLayoutDialog
expect(layoutDialog:IsShown(), "Save on a preset asks for a new layout's name")
click(layoutDialog.LayoutNameEditBox)
scene.input({ type = "text", text = "Mine" })
wait(0.1)
expect(layoutDialog.AcceptButton:IsEnabled(), "a name lets it be saved")
click(layoutDialog.AcceptButton)
wait(0.2)
expect(not layoutDialog:IsShown(), "the name dialog closes")
local layouts = G.C_EditMode.GetLayouts()
expect(#layouts.layouts == 1 and layouts.layouts[1].layoutName == "Mine", "the account keeps the new layout, and only it")
expect(layouts.activeLayout == #G.EditModePresetLayoutManager:GetCopyOfPresetLayouts() + 1, "and makes it the active one")
expect(not manager:HasActiveChanges(), "nothing is left unsaved")

-- Left: everything stays where it was put
click(manager.CloseButton)
wait(0.2)
expect(not manager:IsShown(), "Edit Mode closes")
local leftRect = rectOf(bar)
expect(math.abs(leftRect[1] - bigRect[1]) < 1 and math.abs(leftRect[3] - bigRect[3]) < 1, "the bar keeps its place and size")
expect(bar2:IsShown() and bar3:IsShown(), "bars 2 and 3 stay on")
expect(select(1, G.GetActionBarToggles()) == true, "and the account keeps them on")
