-- Targeting a friendly unit: the player or a party member (a click on their unit frame, TargetUnit("party1"), F1-F5).
-- The battle simulator (lua/combat.lua) targets creatures; a friendly target makes "target" another name for that
-- unit, for every Unit* function (UnitName("target"), UnitHealth("target"), UnitIsUnit("target", "player")...), till
-- a creature is targeted or the target cleared. PLAYER_TARGET_CHANGED tells the game's target frame, as it does.
-- The focus likewise (FocusUnit("player"): a unit menu's Set Focus): "focus" another name for the friendly unit,
-- PLAYER_FOCUS_CHANGED told.
local sim = require("sim")

local friendlytarget = { unit = nil, focus = nil }

local G, combat, game
local isInstalled = false

local function isFriendlyToken(unit)
    if type(unit) ~= "string" then
        return nil
    end
    local lower = unit:lower()
    if lower == "player" then
        return lower
    end
    if lower:match("^party[1-4]$") and G.UnitExists(lower) then
        return lower
    end
    return nil
end

---The friendly unit "target" stands for now: none once a creature is the target (targeted in the world, Tab)
local function current()
    local unit = friendlytarget.unit
    if unit and ((combat and combat.target) or (game and game.fighting and game.fighting.unit == "target")) then
        friendlytarget.unit = nil
        return nil
    end
    if unit and unit ~= "player" and not G.UnitExists(unit) then
        friendlytarget.unit = nil -- (the member left the party)
        return nil
    end
    return unit
end

---The friendly unit "focus" stands for now: none once a creature is the focus
local function currentFocus()
    local unit = friendlytarget.focus
    if unit and combat and combat.focus then
        friendlytarget.focus = nil
        return nil
    end
    if unit and unit ~= "player" and not G.UnitExists(unit) then
        friendlytarget.focus = nil
        return nil
    end
    return unit
end

-- "target" and "focus" (any case) as the friendly units they stand for; anything else as it is
local function translate(unit)
    if type(unit) == "string" then
        if #unit == 6 and friendlytarget.unit and unit:lower() == "target" then
            return current() or unit
        elseif #unit == 5 and friendlytarget.focus and unit:lower() == "focus" then
            return currentFocus() or unit
        end
    end
    return unit
end
local function isStandingIn()
    return friendlytarget.unit ~= nil or friendlytarget.focus ~= nil
end

function friendlytarget.set(unit)
    if unit == friendlytarget.unit then
        return
    end
    friendlytarget.unit = unit
    sim.fireEvent("PLAYER_TARGET_CHANGED")
    sim.touch()
end

function friendlytarget.install(globals)
    if isInstalled then
        return
    end
    isInstalled = true
    G = globals
    combat = package.loaded["combat"]
    game = package.loaded["game"]
    -- Every unit function: "target" read as the friendly unit while there is one
    for name, original in pairs(G) do
        if type(name) == "string" and type(original) == "function" and name:match("^Unit") and name ~= "UnitIsUnit" then
            G[name] = function(unit, ...)
                if isStandingIn() then
                    unit = translate(unit)
                end
                return original(unit, ...)
            end
        end
    end
    local isUnit = G.UnitIsUnit
    G.UnitIsUnit = function(first, second)
        if isStandingIn() then
            first, second = translate(first), translate(second)
        end
        if type(first) == "string" and type(second) == "string" and first:lower() == second:lower() then
            return true
        end
        return isUnit(first, second)
    end
    local getUnitName = G.GetUnitName
    if getUnitName then
        G.GetUnitName = function(unit, ...)
            if isStandingIn() then
                unit = translate(unit)
            end
            return getUnitName(unit, ...)
        end
    end
    local targetUnit, clearTarget = G.TargetUnit, G.ClearTarget
    G.TargetUnit = function(unit, isExact)
        local friendly = isFriendlyToken(unit)
        if friendly then
            -- (a creature targeted before lets go first: one target at a time)
            if (combat and combat.target) or (game and game.fighting and game.fighting.unit == "target") then
                if clearTarget then
                    clearTarget()
                end
            end
            friendlytarget.set(friendly)
            return
        end
        friendlytarget.unit = nil
        if targetUnit then
            return targetUnit(unit, isExact)
        end
    end
    G.ClearTarget = function()
        if friendlytarget.unit then
            friendlytarget.set(nil)
            return true
        end
        if clearTarget then
            return clearTarget()
        end
    end
    local focusUnit, clearFocus = G.FocusUnit, G.ClearFocus
    G.FocusUnit = function(unit)
        -- (a friendly target focused is the unit it stands for)
        local friendly = isFriendlyToken(translate(unit or "target"))
        if friendly then
            if combat and combat.focus and clearFocus then
                clearFocus()
            end
            friendlytarget.setFocus(friendly)
            return
        end
        if friendlytarget.focus then
            friendlytarget.setFocus(nil)
        end
        if focusUnit then
            return focusUnit(unit)
        end
    end
    G.ClearFocus = function()
        if friendlytarget.focus then
            friendlytarget.setFocus(nil)
            return
        end
        if clearFocus then
            return clearFocus()
        end
    end
end

function friendlytarget.setFocus(unit)
    if unit == friendlytarget.focus then
        return
    end
    friendlytarget.focus = unit
    sim.fireEvent("PLAYER_FOCUS_CHANGED")
    sim.touch()
end

return friendlytarget
