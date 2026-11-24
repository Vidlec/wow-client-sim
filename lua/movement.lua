-- Walking as the game does it, on the game's clock: while a movement key is held the character runs at 7 yards a
-- second (4.5 backwards, 2.5 walking), turns about 180 degrees a second, and strafes; auto-run keeps it going;
-- and it can be sent to a point (a click on the map or minimap, or a scenario's walkTo), turning to face it and
-- stopping there. Addons see what the game shows them: the place, the facing, IsPlayerMoving, GetUnitSpeed, and
-- PLAYER_STARTED_MOVING / PLAYER_STOPPED_MOVING, PLAYER_STARTED_TURNING / PLAYER_STOPPED_TURNING.
local sim = require("sim")
local game = require("game")

local movement = {}
local G = sim.G

local RUN_SPEED, BACKWARD_SPEED, WALK_SPEED, SWIM_SPEED = 7, 4.5, 2.5, 4.722
local TURN_SPEED = math.pi -- radians a second
local ARRIVAL_YARDS = 0.5
local MOVE_COMMANDS = {
    MOVEFORWARD = true,
    MOVEBACKWARD = true,
    STRAFELEFT = true,
    STRAFERIGHT = true,
    TURNLEFT = true,
    TURNRIGHT = true,
}

local held = {} -- command -> true while its key is down
local isAutoRunning, isWalking = false, false
local target -- { continentId, north, west } while walking to a point
local isMoving, isTurning, currentSpeed = false, false, 0

function movement.isMovementCommand(command)
    return MOVE_COMMANDS[command] == true
end

---A movement key went down: it moves the character until it comes up. Steering by hand ends a walk to a point.
function movement.press(command)
    if not MOVE_COMMANDS[command] then
        return false
    end
    held[command] = true
    if command ~= "TURNLEFT" and command ~= "TURNRIGHT" then
        target = nil
    end
    if command == "MOVEBACKWARD" then
        isAutoRunning = false
    end
    return true
end

function movement.release(command)
    held[command] = nil
end

function movement.releaseAll()
    held = {}
end

function movement.toggleAutoRun()
    isAutoRunning = not isAutoRunning
    target = nil
end

function movement.setWalking(isOn)
    isWalking = isOn == true
end

---Stops everything: keys, auto-run, a walk to a point.
function movement.stop()
    held, isAutoRunning, target = {}, false, nil
end

---Sends the character to a point of a map, as clicking to move does.
---@return boolean isSent, string? problem
function movement.walkTo(uiMapId, x, y)
    local continentId, north, west = game.mapToWorld(uiMapId, x, y)
    local playerContinentId = game.getPlayerWorldPosition()
    if not continentId then
        return false, "that map has no place in the world"
    end
    if continentId ~= playerContinentId then
        return false, "that point is on another continent"
    end
    target, isAutoRunning = { continentId = continentId, north = north, west = west }, false
    return true
end

---Sends the character to a world point (yards), as clicking on the minimap does.
function movement.walkToWorld(continentId, north, west)
    target, isAutoRunning = { continentId = continentId, north = north, west = west }, false
end

---@return number? yards How far the point it walks to is, nil when it walks to none
function movement.getDistanceToTarget()
    if not target then
        return nil
    end
    local _, north, west = game.getPlayerWorldPosition()
    if not north then
        return nil
    end
    return math.sqrt((target.north - north) ^ 2 + (target.west - west) ^ 2)
end

local function setState(isMovingNow, isTurningNow)
    if isMovingNow ~= isMoving then
        isMoving = isMovingNow
        sim.fireEvent(isMoving and "PLAYER_STARTED_MOVING" or "PLAYER_STOPPED_MOVING")
    end
    if isTurningNow ~= isTurning then
        isTurning = isTurningNow
        sim.fireEvent(isTurning and "PLAYER_STARTED_TURNING" or "PLAYER_STOPPED_TURNING")
    end
end

---Moves the character on by the seconds that passed.
function movement.tick(elapsed)
    if elapsed <= 0 then
        return
    end
    local turn = (held.TURNLEFT and 1 or 0) - (held.TURNRIGHT and 1 or 0)
    local forward = ((held.MOVEFORWARD or isAutoRunning) and 1 or 0) - (held.MOVEBACKWARD and 1 or 0)
    local right = (held.STRAFERIGHT and 1 or 0) - (held.STRAFELEFT and 1 or 0)
    if turn ~= 0 then
        game.turn(turn * TURN_SPEED * elapsed)
    end

    local yards = 0
    if target then
        local continentId, north, west = game.getPlayerWorldPosition()
        local distance = north
            and continentId == target.continentId
            and math.sqrt((target.north - north) ^ 2 + (target.west - west) ^ 2)
        if not distance or distance <= ARRIVAL_YARDS then
            target = nil
        else
            -- Face the point (facing 0 is north, growing to the west) and run straight at it
            game.profile.facing = math.atan2(target.west - west, target.north - north) % (2 * math.pi)
            yards = math.min((isWalking and WALK_SPEED or RUN_SPEED) * elapsed, distance)
            if not game.walk(yards, 0) then
                target, yards = nil, 0
            end
            currentSpeed = isWalking and WALK_SPEED or RUN_SPEED
        end
    end
    if not target and (forward ~= 0 or right ~= 0) then
        local speed = isWalking and WALK_SPEED or (forward < 0 and BACKWARD_SPEED or RUN_SPEED)
        -- Diagonal moves are no faster than straight ones
        local length = math.sqrt(forward * forward + right * right)
        yards = speed * elapsed
        if not game.walk(forward / length * yards, right / length * yards) then
            yards, isAutoRunning = 0, false
        end
        currentSpeed = speed
    end
    if yards == 0 then
        currentSpeed = 0
    end
    setState(yards > 0, turn ~= 0)
end

---What the page shows: moving or not, how fast, and towards what.
function movement.describe()
    return {
        isMoving = isMoving,
        speed = currentSpeed,
        isAutoRunning = isAutoRunning,
        isWalking = isWalking,
        distanceToTarget = movement.getDistanceToTarget() and math.floor(movement.getDistanceToTarget() + 0.5) or nil,
    }
end

function movement.install()
    G.IsPlayerMoving = function()
        return isMoving
    end
    G.IsFalling = function()
        return false
    end
    G.IsSwimming = function()
        return false
    end
    G.IsFlying = function()
        return false
    end
    ---@return number current, number run, number flight, number swim Yards a second
    G.GetUnitSpeed = function(unit)
        if unit ~= "player" and not (G.UnitIsUnit and G.UnitIsUnit(unit, "player")) then
            return 0, RUN_SPEED, RUN_SPEED, SWIM_SPEED
        end
        return currentSpeed, isWalking and WALK_SPEED or RUN_SPEED, RUN_SPEED, SWIM_SPEED
    end
    sim.tickHandlers = sim.tickHandlers or {}
    table.insert(sim.tickHandlers, movement.tick)
end

return movement
