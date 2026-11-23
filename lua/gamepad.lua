-- The gamepad, as the client has it: one controller (the browser's, read by the page, or a scenario's pad steps),
-- its buttons by the client's key names (PAD1, PADDUP, PADLSHOULDER...) and its two sticks ("Movement" and "Camera").
--
-- A button goes first to the frames that take gamepad buttons (EnableGamePadButton, OnGamePadButtonDown/Up), top
-- first, as the keyboard's keys go; then to the bindings: the override bindings (the game's gamepad menus set them),
-- the gamepad mode's own binding context while it is active, then the plain ones. A stick goes to the frames that
-- take sticks (EnableGamePadStick, OnGamePadStick, each saying whether it left it unhandled); left unhandled, the
-- Movement stick walks the character and the Camera stick turns it.
--
-- The interface style (the InputDeviceInterfaceStyle setting: 0 mouse and keyboard, 1 gamepad) switches the game's
-- gamepad interface on and off (INPUT_DEVICE_INTERFACE_TRANSITION).
local sim = require("sim")
local W = require("widgets")
local S = W.state
local G = sim.G

local gamepad = {}

-- The buttons in the order the simulator numbers them (ButtonIndexToBinding, the mapped state's buttons): the
-- client keeps its own order internally, this one is the simulator's
gamepad.BUTTONS = { "PAD1", "PAD2", "PAD3", "PAD4", "PADLSHOULDER", "PADRSHOULDER", "PADLTRIGGER", "PADRTRIGGER", "PADBACK",
    "PADFORWARD", "PADLSTICK", "PADRSTICK", "PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT", "PADSYSTEM" }
local BUTTON_INDEX = {}
for index, name in ipairs(gamepad.BUTTONS) do BUTTON_INDEX[name] = index end
gamepad.STICKS = { "Movement", "Camera" }
local STICK_PLACES = { Movement = "Left", Camera = "Right" }
local DEVICE_ID, COMBINED_DEVICE_ID = 1, 0
local STICK_MOVES_AT = 0.35 -- how far a stick is pushed before it walks or turns

-- The gamepad mode's own keys (the client's defaults are its own; these follow the game's gamepad action bars:
-- the d-pad and the face buttons are their two diamonds, 1-4 and 5-8; the triggers switch the crossbar, the
-- shoulders the targeting)
gamepad.CONTEXT_BINDINGS = {
    GamepadModeInGameCore = {
        PADDLEFT = "GAMEPADACTIONBUTTON1", PADDUP = "GAMEPADACTIONBUTTON2", PADDRIGHT = "GAMEPADACTIONBUTTON3", PADDDOWN = "GAMEPADACTIONBUTTON4",
        PAD3 = "GAMEPADACTIONBUTTON5", PAD4 = "GAMEPADACTIONBUTTON6", PAD2 = "GAMEPADACTIONBUTTON7", PAD1 = "GAMEPADACTIONBUTTON8",
        PADLTRIGGER = "GAMEPADLEFTMOD", PADRTRIGGER = "GAMEPADRIGHTMOD",
        PADLSHOULDER = "GAMEPADLEFTTARGETMODIFIER", PADRSHOULDER = "GAMEPADRIGHTTARGETMODIFIER",
        PADFORWARD = "OPENRADIAL", PADBACK = "TOGGLEUIFOCUS", PADRSTICK = "TOGGLEPINGSYSTEM",
    },
}

local state = {
    isConnected = false,
    name = "Gamepad",
    buttons = {}, -- [name] = true while held
    sticks = { Movement = { x = 0, y = 0 }, Camera = { x = 0, y = 0 } },
    contexts = {}, -- [context name] = true while active
    stickHeld = {}, -- [movement command] = true while a stick holds it
}
gamepad.state = state

---@return string? name The name of a binding context (Enum.BindingContext value or name)
local function contextName(context)
    if type(context) == "string" then return context end
    for name, value in pairs(G.Enum and G.Enum.BindingContext or {}) do
        if value == context then return name end
    end
end

---@return string? command What a pad button runs now: an override binding, the active contexts', or a plain one
function gamepad.getCommand(key)
    local override = sim.overrideBindings[key]
    if override and override.command and override.command ~= "" then return override.command end
    for context in pairs(state.contexts) do
        local bindings = gamepad.CONTEXT_BINDINGS[context]
        local command = bindings and bindings[key]
        if command then return command end
    end
    return sim.bindings[key]
end

---The frames taking gamepad buttons or sticks, top first, each until one stops it going on.
---@return boolean isTaken A frame took it (and did not let it go on)
local function sendToFrames(flag, script, ...)
    local frames = require("scene").getSortedFrames()
    for index = #frames, 1, -1 do
        local frame = frames[index]
        local s = S[frame]
        if s[flag] and frame:IsVisible() and (s.scripts[script] or (s.hooks and s.hooks[script])) then
            local handler = s.scripts[script]
            local result
            if handler then
                local isFine, value = pcall(handler, frame, ...)
                if isFine then result = value else sim.reportError(value, debug.traceback()) end
            end
            local hooks = s.hooks and s.hooks[script]
            for _, hook in ipairs(hooks or {}) do sim.call(hook, frame, ...) end
            -- (a stick handler answers whether it left the stick unhandled; a button handler lets the press go on when
            -- it answers true, as the client's radial wheels do with every button but B, or by propagation)
            if flag == "gamePadStick" then
                if result ~= true then return true end
            elseif result ~= true and not s.propagateKeyboard then
                return true
            end
        end
    end
    return false
end

function gamepad.press(key)
    key = key:upper()
    if state.buttons[key] then return end
    state.buttons[key] = true
    gamepad.connect()
    if sendToFrames("gamePadButton", "OnGamePadButtonDown", key) then sim.touch(); return end
    require("scene").runCommand(gamepad.getCommand(key), true, key)
    sim.touch()
end

function gamepad.release(key)
    key = key:upper()
    if not state.buttons[key] then return end
    state.buttons[key] = nil
    if sendToFrames("gamePadButton", "OnGamePadButtonUp", key) then sim.touch(); return end
    require("scene").releaseCommand(gamepad.getCommand(key), key)
    sim.touch()
end

local function holdMovement(command, isHeld)
    local movement = require("movement")
    if isHeld and not state.stickHeld[command] then
        state.stickHeld[command] = true
        movement.press(command)
    elseif not isHeld and state.stickHeld[command] then
        state.stickHeld[command] = nil
        movement.release(command)
    end
end

---A stick moved (x right, y up, each -1..1): told to the frames taking sticks; left to the game, the Movement stick
---walks (forward, back, sideways) and the Camera stick turns.
function gamepad.setStick(stick, x, y)
    local current = state.sticks[stick]
    if not current then return end
    x, y = tonumber(x) or 0, tonumber(y) or 0
    if current.x == x and current.y == y then return end
    current.x, current.y = x, y
    gamepad.connect()
    local length = math.min(1, math.sqrt(x * x + y * y))
    -- The client tells each stick by its place too ("Left", "Right"), apart from its use: the map's soft cursor
    -- follows "Left", the gamepad mode's stick bindings "Movement" and "Camera"
    sendToFrames("gamePadStick", "OnGamePadStick", STICK_PLACES[stick], x, y, length)
    local isTaken = sendToFrames("gamePadStick", "OnGamePadStick", stick, x, y, length)
    if stick == "Movement" then
        holdMovement("MOVEFORWARD", not isTaken and y > STICK_MOVES_AT)
        holdMovement("MOVEBACKWARD", not isTaken and y < -STICK_MOVES_AT)
        holdMovement("STRAFELEFT", not isTaken and x < -STICK_MOVES_AT)
        holdMovement("STRAFERIGHT", not isTaken and x > STICK_MOVES_AT)
    else
        holdMovement("TURNLEFT", not isTaken and x < -STICK_MOVES_AT)
        holdMovement("TURNRIGHT", not isTaken and x > STICK_MOVES_AT)
    end
    sim.touch()
end

function gamepad.connect(name)
    if name then state.name = name end
    if state.isConnected then return end
    state.isConnected = true
    sim.fireEvent("GAME_PAD_CONNECTED")
    sim.fireEvent("GAME_PAD_ACTIVE_CHANGED", true)
end

function gamepad.disconnect()
    if not state.isConnected then return end
    for key in pairs(state.buttons) do gamepad.release(key) end
    gamepad.setStick("Movement", 0, 0)
    gamepad.setStick("Camera", 0, 0)
    state.isConnected = false
    sim.fireEvent("GAME_PAD_ACTIVE_CHANGED", false)
    sim.fireEvent("GAME_PAD_DISCONNECTED")
end

---@return number style The interface style now: 0 mouse and keyboard, 1 gamepad (the InputDeviceInterfaceStyle setting)
function gamepad.getStyle()
    return G.GetCVar("InputDeviceInterfaceStyle") == "1" and 1 or 0
end

---Switches the game's interface between mouse and keyboard (0) and gamepad (1), as the client does when the
---setting changes: the game's gamepad addons set themselves up and take down on the event.
function gamepad.setStyle(style)
    local old = gamepad.getStyle()
    style = (style == 1 or style == "1" or style == true) and 1 or 0
    sim.cvars.InputDeviceInterfaceStyle = tostring(style)
    if style ~= old then
        -- Into the gamepad interface, the client takes Edit Mode's Gamepad preset (the game's own code puts the Modern
        -- one back on the way out, Blizzard_Gamepad's Core.lua)
        local presets = G.Enum and G.Enum.EditModePresetLayouts
        if style == 1 and presets and presets.Gamepad and G.C_EditMode and G.C_EditMode.SetActiveLayout then
            G.C_EditMode.SetActiveLayout(presets.Gamepad + 1)
        end
        sim.fireEvent("INPUT_DEVICE_INTERFACE_TRANSITION", style, old)
        sim.touch()
    end
end

function gamepad.describe()
    return { connected = state.isConnected, name = state.name, style = gamepad.getStyle() }
end

function gamepad.install()
    G.C_GamePad = G.C_GamePad or {}
    local pad = G.C_GamePad
    pad.IsEnabled = function() return G.GetCVar("GamePadEnable") ~= "0" end
    pad.GetActiveDeviceID = function() return state.isConnected and DEVICE_ID or -1 end
    pad.GetAllDeviceIDs = function() return state.isConnected and { DEVICE_ID } or {} end
    pad.GetCombinedDeviceID = function() return COMBINED_DEVICE_ID end
    pad.GetDeviceMappedState = function(deviceId)
        if not state.isConnected then return nil end
        local buttons, axes = {}, {}
        for index, name in ipairs(gamepad.BUTTONS) do buttons[index] = state.buttons[name] == true end
        local sticks = {}
        for index, name in ipairs(gamepad.STICKS) do
            local stick = state.sticks[name]
            sticks[index] = { x = stick.x, y = stick.y, len = math.min(1, math.sqrt(stick.x * stick.x + stick.y * stick.y)) }
            axes[#axes + 1], axes[#axes + 2] = stick.x, stick.y
        end
        return { name = state.name, labelStyle = "Generic", buttonCount = #buttons, axisCount = #axes, stickCount = #sticks,
            buttons = buttons, axes = axes, sticks = sticks }
    end
    pad.GetDeviceRawState = pad.GetDeviceMappedState
    pad.ButtonIndexToBinding = function(index) return gamepad.BUTTONS[(index or 0) + 1] end
    pad.ButtonBindingToIndex = function(binding) local index = binding and BUTTON_INDEX[binding:upper()]; return index and index - 1 or nil end
    pad.ButtonIndexToConfigName = function(index) return gamepad.BUTTONS[(index or 0) + 1] end
    pad.StickIndexToConfigName = function(index) return gamepad.STICKS[(index or 0) + 1] end
    pad.AxisIndexToConfigName = function(index) return ({ "LStickX", "LStickY", "RStickX", "RStickY" })[(index or 0) + 1] end
    pad.GetPowerLevel = function() return G.Enum and G.Enum.GamePadPowerLevel and G.Enum.GamePadPowerLevel.Wired or 4 end
    pad.SetVibration = function() end
    pad.StopVibration = function() end
    pad.SetLedColor = function() end
    pad.ClearLedColor = function() end
    pad.GetLedColor = function() return nil end
    local allowHover = false
    pad.GetAllowHoverEventsWithFreeLook = function() return allowHover end
    pad.SetAllowHoverEventsWithFreeLook = function(isAllowed) allowHover = isAllowed == true end

    G.C_InputInterfaceStyle = G.C_InputInterfaceStyle or {}
    G.C_InputInterfaceStyle.GetCurrentStyle = gamepad.getStyle

    -- The keys a command is on, the gamepad mode's own context bindings among them while it is active: the game asks
    -- whether a trigger is held as IsKeyDown(GetBindingKey("GAMEPADLEFTMOD")), which is how the crossbar follows LT/RT
    local getBindingKey = G.GetBindingKey
    G.GetBindingKey = function(command, ...)
        local keys = { getBindingKey(command, ...) }
        for context in pairs(state.contexts) do
            for key, bound in pairs(gamepad.CONTEXT_BINDINGS[context] or {}) do
                if bound == command then keys[#keys + 1] = key end
            end
        end
        return unpack(keys)
    end
    -- Whether a key is held now: a pad button, a modifier, or a keyboard key the page holds down
    sim.heldKeys = sim.heldKeys or {}
    G.IsKeyDown = function(key)
        if type(key) ~= "string" then return false end
        local upper = key:upper()
        if state.buttons[upper] then return true end
        if upper == "LSHIFT" or upper == "RSHIFT" or upper == "SHIFT" then return sim.modifiers.shift == true end
        if upper == "LCTRL" or upper == "RCTRL" or upper == "CTRL" then return sim.modifiers.ctrl == true end
        if upper == "LALT" or upper == "RALT" or upper == "ALT" then return sim.modifiers.alt == true end
        return sim.heldKeys[upper] == true
    end

    G.C_KeyBindings = G.C_KeyBindings or {}
    G.C_KeyBindings.ActivateBindingContext = function(context)
        local name = contextName(context)
        if name then state.contexts[name] = true end
    end
    G.C_KeyBindings.DeactivateBindingContext = function(context)
        local name = contextName(context)
        if name then state.contexts[name] = nil end
    end
    G.C_KeyBindings.IsBindingContextActive = function(context)
        local name = contextName(context)
        return name ~= nil and state.contexts[name] == true
    end

    -- The interface style set by the game's own settings (or an addon) switches it, as the setting does in the client
    if sim.cvars.InputDeviceInterfaceStyle == nil then sim.cvars.InputDeviceInterfaceStyle = "0" end
    if sim.cvars.GamePadEnable == nil then sim.cvars.GamePadEnable = "1" end
    local setCVar = G.SetCVar
    local function setCVarSwitching(name, value, ...)
        if type(name) == "string" and name:lower() == "inputdeviceinterfacestyle" then
            gamepad.setStyle(tostring(value) == "1" and 1 or 0)
            return true
        end
        return setCVar(name, value, ...)
    end
    G.SetCVar = setCVarSwitching
    G.C_CVar = G.C_CVar or {}
    G.C_CVar.SetCVar = setCVarSwitching

    -- Temporary settings (the gamepad mode sets its own while on, and puts them back): kept apart from the saved ones
    G.C_CVar = G.C_CVar or {}
    local saved = {}
    G.C_CVar.SetTempCVar = function(name, value)
        if saved[name] == nil then saved[name] = { value = sim.cvars[name] } end
        setCVar(name, value)
    end
    G.C_CVar.RemoveTempCVar = function(name)
        local before = saved[name]
        if before then
            sim.cvars[name] = before.value
            saved[name] = nil
        end
    end
end

return gamepad
