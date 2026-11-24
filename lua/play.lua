-- Plays a scenario headless: boots the simulator with the addons, runs the scenario's steps as a player would
-- (quests, kills, keys, clicks on frames or on text), and fails on any Lua error or failed check.
--   luajit lua/play.lua <root> <runtime.json> <scenario.lua>        (bun run play writes the runtime config)
-- Each line out as it is written: the runner shows a single scenario as it goes, and a run ended for its time keeps
-- what it printed (a pipe is otherwise filled in blocks)
io.stdout:setvbuf("no") -- (not "line": on Windows the C library takes that for full buffering)
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

-- Coverage (bun run play --coverage): every line run and function called in one addon's own files (the project's
-- coverage addon, ADDONSIM_COVERAGE_ADDON), from the moment it loads, written out when the scenario ends
local coverageFile, coverageAddon, coverage = os.getenv("ADDONSIM_COVERAGE"), os.getenv("ADDONSIM_COVERAGE_ADDON"), nil
if coverageFile and coverageFile ~= "" and coverageAddon and coverageAddon ~= "" then
    coverage = { lines = {}, functions = {} }
    local prefix = "@Interface/AddOns/" .. coverageAddon .. "/"
    local prefixLength = #prefix
    local getinfo = debug.getinfo
    local isOwn = setmetatable({}, {
        __index = function(cache, source)
            local value = source:sub(1, prefixLength) == prefix and source:sub(prefixLength + 1) or false
            cache[source] = value
            return value
        end,
    })
    local function hook(event, line)
        local info = getinfo(2, "S")
        local file = info and isOwn[info.source]
        if not file then
            return
        end
        if event == "line" then
            local lines = coverage.lines[file]
            if not lines then
                lines = {}
                coverage.lines[file] = lines
            end
            lines[line] = true
        elseif event == "call" then
            local functions = coverage.functions[file]
            if not functions then
                functions = {}
                coverage.functions[file] = functions
            end
            functions[info.linedefined] = true
        end
    end
    debug.sethook(hook, "cl")
    -- Each coroutine has hooks of its own
    local createCoroutine, wrapCoroutine = coroutine.create, coroutine.wrap
    coroutine.create = function(body)
        return createCoroutine(function(...)
            debug.sethook(hook, "cl")
            return body(...)
        end)
    end
    coroutine.wrap = function(body)
        return wrapCoroutine(function(...)
            debug.sethook(hook, "cl")
            return body(...)
        end)
    end
end
local function writeCoverage()
    if not coverage then
        return
    end
    debug.sethook()
    local out = io.open(coverageFile, "a")
    if not out then
        return
    end
    for file, lines in pairs(coverage.lines) do
        for line in pairs(lines) do
            out:write("L\t", file, "\t", line, "\n")
        end
    end
    for file, functions in pairs(coverage.functions) do
        for line in pairs(functions) do
            out:write("F\t", file, "\t", line, "\n")
        end
    end
    out:close()
end

-- Lua's own libraries as they were before the game: the game's global table shares them (its string, table, math...),
-- and the game adds to them (the client's string and table extensions, and what its code stores there). A reload
-- puts them back as they were, so the next boot starts from the same libraries as the first.
local LIBRARIES = { "string", "table", "math", "os", "coroutine", "bit", "debug", "io" }
local pristineLibraries = {}
for _, name in ipairs(LIBRARIES) do
    local library = _G[name]
    if type(library) == "table" then
        local copy = {}
        for key, value in pairs(library) do
            copy[key] = value
        end
        pristineLibraries[name] = copy
    end
end
local function restoreLibraries()
    for name, copy in pairs(pristineLibraries) do
        local library = _G[name]
        for key in pairs(library) do
            if copy[key] == nil then
                library[key] = nil
            end
        end
        for key, value in pairs(copy) do
            library[key] = value
        end
    end
end

local runtime = dofile(root .. "/lua/boot.lua")
local sim, game, scene, W = runtime.sim, runtime.game, runtime.scene, runtime.W

-- The scenario's mouse and keys are the player's own: secure, as the page's input is (an addon's or a scenario's code
-- on the stack taints; a menu's Set Focus clicked by a scenario was forbidden)
local function playerInput(event)
    return sim.runSecurely(scene.input, event)
end
local S = W.state
local scenarioPath = arg[3]
-- The project's folders (its addonsim.config.ts): golden snapshots and the last run's scenes are kept in its
-- scenarios folder; without a project, the simulator's own
local scenariosDir = ((sim.config.scenariosDir or (root .. "/scenarios")):gsub("\\", "/"))
local projectRoot = ((sim.config.projectRoot or root):gsub("\\", "/"))
-- (the page that shows a saved scene: the server's, on the port it is set to)
local PAGE = "http://localhost:" .. tostring(sim.config.port or 8765)
-- The scenario's name: its file's, without the folders (the folder its snapshots and scenes are kept under)
local scenarioName = scenarioPath:match("([^/\\]+)%.lua$")

-- Where a failure happened: the innermost line of the scenario's own code (the scenario, or a file of the project's
-- it ran), not the simulator's or the game's
local simulatorPrefix = (root:gsub("\\", "/")) .. "/lua/"
local function findScenarioLine()
    for level = 3, 40 do
        local info = debug.getinfo(level, "Sl")
        if not info then
            return nil
        end
        local source = info.source or ""
        if source:sub(1, 1) == "@" and info.currentline and info.currentline > 0 then
            local file = source:sub(2):gsub("\\", "/")
            if file:sub(1, #simulatorPrefix) ~= simulatorPrefix and not file:find("^Interface/") then
                return file .. ":" .. info.currentline
            end
        end
    end
end

local failures, stepCount = {}, 0
---A failed check or step, with the scenario's line it came from (the report's "  at file:line")
local function fail(text)
    local where = findScenarioLine()
    failures[#failures + 1] = where and (text .. "\n  at " .. where) or text
end
local function note(text)
    io.write("  " .. text .. "\n")
end

-- What a scenario can do
local steps = {}
steps.G = sim.G
steps.root = root -- the simulator's folder
steps.projectRoot = projectRoot -- the project's folder (the simulator's, without a project)
steps.scenariosDir = scenariosDir -- the project's scenarios folder, for scenarios that read files of their own
-- A scenario split in parts that play side by side ("--@shards 4": the runner runs it 4 times, each a part):
-- forShard(list) is this part's share of a list, every count-th item from its own; the whole list when not split
steps.shard = { index = 1, count = 1 }
do
    local index, count = (os.getenv("ADDONSIM_SHARD") or ""):match("^(%d+)/(%d+)$")
    if index then
        steps.shard = { index = tonumber(index), count = tonumber(count) }
    end
end
function steps.forShard(list)
    local share = {}
    for position, item in ipairs(list) do
        if (position - 1) % steps.shard.count == steps.shard.index - 1 then
            share[#share + 1] = item
        end
    end
    return share
end
steps.game = game

---Lets the game's clock run: timers and OnUpdate, in frames of 1/20 s.
function steps.wait(seconds)
    -- Whole ticks of 0.05 seconds, counted (adding up 0.05s falls short and plays one tick too many)
    for _ = 1, math.max(1, math.floor((seconds or 0.05) / 0.05 + 0.5)) do
        sim.tick(0.05)
        -- /reload typed, or ReloadUI called by an addon: the interface reloads before the clock goes on
        if sim.requestReload then
            steps.reload()
            return
        end
    end
end

local function act(name, ok, problem)
    stepCount = stepCount + 1
    if ok == false then
        fail(name .. ": " .. tostring(problem))
    end
    steps.wait(0.1)
end

-- The party: simulated players in the group, their quests and counts, where they stand
local party = require("party")
-- A project's plugins (lua/plugins.lua) may add steps
local plugins = require("plugins")
-- The project's own Lua modules (its luaPath folders), made afresh at a reload as the simulator's are
local projectModuleFolders = {}
for _, folder in ipairs(sim.config.luaPath or {}) do
    projectModuleFolders[#projectModuleFolders + 1] = (folder:gsub("\\", "/"))
end
local function isModuleFile(folder, name)
    local file = io.open(folder .. "/" .. name .. ".lua", "rb")
    if file then
        file:close()
    end
    return file ~= nil
end

---The interface reloaded, as /reload does: the logout (PLAYER_LOGOUT, then the addons' saved variables, the layout
---cache of the frames the player moved and the character written), then the whole game booted afresh from them in
---this run, the addons loading anew. What the scenario took from the old game (its frames, a module it required) is
---the old game's: find them again after (G is the new game's).
function steps.reload()
    sim.requestReload = nil
    runtime.handlers.save()
    local earlier = { errors = sim.errors, stubs = sim.stubs, stubCallers = sim.stubCallers }
    -- (every module of the simulator's own, by its file: the next boot makes each afresh)
    for name in pairs(package.loaded) do
        if type(name) == "string" and not name:find("[^%w_]") then
            local isOwn = isModuleFile(root .. "/lua", name)
            for _, folder in ipairs(projectModuleFolders) do
                isOwn = isOwn or isModuleFile(folder, name)
            end
            if isOwn then
                package.loaded[name] = nil
            end
        end
    end
    restoreLibraries()
    -- (in a coroutine of its own: a stack of its own, as a login has, so the game's code is not seen as called by the
    -- scenario's, which would taint it: issecure() looks down the stack)
    local booting = coroutine.create(function()
        return dofile(root .. "/lua/boot.lua")
    end)
    local isBooted, booted = coroutine.resume(booting)
    if not isBooted then
        error("the reload failed: " .. tostring(booted) .. "\n" .. debug.traceback(booting), 0)
    end
    runtime = booted
    sim, game, scene, W = runtime.sim, runtime.game, runtime.scene, runtime.W
    S = W.state
    party = require("party")
    plugins = require("plugins")
    steps.G, steps.game = sim.G, game
    require("combat").addSteps(steps, act) -- (the fight steps of the new game's battle simulator)
    plugins.installSteps(steps, act) -- (and the new game's plugins')
    -- The errors and stand-ins of the session before count in the report as well
    for index = #earlier.errors, 1, -1 do
        table.insert(sim.errors, 1, earlier.errors[index])
    end
    for name, value in pairs(earlier.stubs or {}) do
        if sim.stubs[name] == nil then
            sim.stubs[name] = value
        end
    end
    for name, callers in pairs(earlier.stubCallers or {}) do
        sim.stubCallers[name] = sim.stubCallers[name] or {}
        for addon in pairs(callers) do
            sim.stubCallers[name][addon] = true
        end
    end
    io.write(string.format("Reloaded in %.2fs\n", runtime.bootSeconds))
    act("reload", true)
end

function steps.accept(questId)
    act("accept " .. questId, game.acceptQuest(questId))
end
---@param options table|boolean? { loot, isTappedByOthers, via = "target"|"nameplate"|"unseen", dropChance } (game.kill);
---or the old form: shouldLoot, isTappedByOthers
function steps.kill(npcId, options, isTappedByOthers)
    if type(options) ~= "table" then
        options = { loot = options ~= false, isTappedByOthers = isTappedByOthers }
    end
    act("kill " .. npcId, game.kill(npcId, options))
end
---Kills a creature again and again, as farming does: its quest items drop at the chance given.
---@return number drops How many items dropped
function steps.hunt(npcId, count, dropChance, via)
    -- (the items objectives gained: a kill objective of the same creature counts no drop)
    local function itemsHeld()
        local held = 0
        for _, entry in ipairs(game.questLog) do
            for _, objective in ipairs(entry.objectives) do
                if objective.kind == "item" then
                    held = held + objective.fulfilled
                end
            end
        end
        return held
    end
    local before = itemsHeld()
    for _ = 1, count do
        game.kill(npcId, { loot = true, dropChance = dropChance, via = via })
    end
    local after = itemsHeld()
    act(string.format("hunt %d x%d", npcId, count), true)
    return after - before
end
function steps.seed(seed)
    game.setRandomSeed(seed)
    act("seed", true)
end
function steps.loot(itemId, count)
    act("loot " .. itemId, game.loot(itemId, count))
end
function steps.progress(questId, index, amount)
    act("progress " .. questId, game.progressQuest(questId, index, amount))
end
function steps.complete(questId)
    act("complete " .. questId, game.completeQuest(questId))
end
function steps.turnIn(questId)
    act("turn in " .. questId, game.turnInQuest(questId))
end
function steps.abandon(questId)
    act("abandon " .. questId, game.abandonQuest(questId))
end
function steps.talk(npcId)
    act("talk " .. npcId, game.talkTo(npcId))
end
function steps.closeDialog()
    act("close dialog", game.closeDialog())
end
function steps.equip(itemId, slot)
    act("equip " .. tostring(itemId), game.equip(itemId, slot) ~= nil, "not something worn")
end
function steps.unequip(slot)
    act("unequip " .. tostring(slot), game.unequip(slot), "nothing there")
end
function steps.moveTo(uiMapId, x, y)
    game.setPosition(uiMapId, x, y)
    act("move", true)
end
function steps.enterInstance(instanceId, instanceType, name)
    act("enter instance", game.setInstance(instanceId, instanceType, name))
end
function steps.leaveInstance()
    act("leave instance", game.setInstance(0))
end
function steps.setProfile(changes)
    game.setProfile(changes)
    sim.fireEvent("QUEST_LOG_UPDATE")
    act("profile", true)
end
---@param member { name: string, class: string?, level: number?, addon: string? } addon: a registered party addon or "none"
---(left out: the default a plugin registered, else "none")
function steps.joinParty(member)
    local joined, problem = party.add(member)
    act("join " .. tostring(member.name), joined ~= nil, problem)
end
function steps.leaveParty(name)
    act("leave " .. name, party.remove(name))
end
function steps.memberAccept(name, questId)
    act(name .. " accepts " .. questId, party.acceptQuest(name, questId))
end
function steps.memberProgress(name, questId, objective, amount)
    act(name .. " progress " .. questId, party.progress(name, questId, objective, amount))
end
function steps.memberComplete(name, questId)
    act(name .. " completes " .. questId, party.complete(name, questId))
end
function steps.memberAbandon(name, questId)
    act(name .. " abandons " .. questId, party.abandonQuest(name, questId))
end
function steps.memberMoveTo(name, uiMapId, x, y)
    act(name .. " moves", party.moveTo(name, uiMapId, x, y))
end
function steps.memberNear(name, yards)
    act(name .. " comes near", party.placeNear(name, yards))
end
function steps.memberOnline(name, isOnline)
    act(name .. (isOnline == false and " goes offline" or " comes online"), party.setOnline(name, isOnline))
end

-- Moving about: yards ahead (negative: back), yards to the right, degrees to turn left; the minimap's zoom (0-5)
function steps.walk(forward, right)
    act("walk", game.walk(forward or 0, right or 0), "no place to walk from")
end
function steps.turn(degrees)
    game.turn(math.rad(degrees or 0))
    act("turn " .. tostring(degrees), true)
end
---Holds a key down for some seconds, as a player does to run (W), turn (A, D) or strafe (Q, E).
function steps.hold(key, seconds)
    playerInput({ type = "key", key = key, isHeld = true })
    steps.wait(seconds or 1)
    playerInput({ type = "keyup", key = key }) -- (as the press: a binding run on release runs as the player's)
    steps.wait(0.05)
    act("hold " .. key, true)
end
-- The gamepad: the game's interface for it switched on or off; a button pressed (and let go, after some seconds:
-- 0 for a tap) by the client's key name (PAD1, PADDUP, PADLTRIGGER...); a stick pushed (Movement or Camera, x right
-- and y up from -1 to 1) for some seconds, then let go
function steps.gamepadInterface(isOn)
    -- (as the player does it: securely, as all hardware input is)
    sim.runSecurely(require("gamepad").setStyle, isOn == false and 0 or 1)
    steps.wait(0.1)
    act("gamepad interface " .. (isOn == false and "off" or "on"), true)
end
function steps.pad(button, seconds)
    local gamepad = require("gamepad")
    sim.runSecurely(gamepad.press, button)
    steps.wait(seconds or 0.05)
    sim.runSecurely(gamepad.release, button)
    steps.wait(0.05)
    act("pad " .. button, true)
end
function steps.padStick(stick, x, y, seconds)
    local gamepad = require("gamepad")
    sim.runSecurely(gamepad.setStick, stick, x, y)
    steps.wait(seconds or 0.5)
    sim.runSecurely(gamepad.setStick, stick, 0, 0)
    steps.wait(0.05)
    act("stick " .. stick, true)
end
---Walks to a point of a map at running speed, as clicking to move does, the game's clock running meanwhile.
---@return number seconds How long it took
function steps.walkTo(uiMapId, x, y, maxSeconds)
    local movement = require("movement")
    local isSent, problem = movement.walkTo(uiMapId, x, y)
    if not isSent then
        act("walk to", false, problem)
        return 0
    end
    local seconds = 0
    while movement.getDistanceToTarget() and seconds < (maxSeconds or 600) do
        steps.wait(0.25)
        seconds = seconds + 0.25
    end
    steps.wait(0.1)
    act(
        string.format("walk to %.2f, %.2f", x, y),
        movement.getDistanceToTarget() == nil,
        "not there after " .. seconds .. " seconds"
    )
    return seconds
end
function steps.face(degrees)
    game.profile.facing = math.rad(degrees or 0)
    sim.touch()
    act("face " .. tostring(degrees), true)
end
function steps.zoomMinimap(level)
    sim.G.Minimap:SetZoom(level)
    act("zoom " .. tostring(level), true)
end

-- What the game hides from addons, as in PvP and some instances: { identity = true, threat = true }
function steps.restrict(restrictions)
    for key in pairs(sim.restrictions) do
        sim.restrictions[key] = restrictions and restrictions[key] == true or false
    end
    act("restrict", true)
end

---A screen of this many pixels, with the UI scale switched on at uiScale, or off (nil): drawn pixel for pixel.
function steps.screen(width, height, uiScale)
    sim.setScreen(width, height, uiScale)
    act(string.format("screen %dx%d", width, height), true)
end

---Plays back a session recorded in the game by the AddonSim Recorder addon: the character, then each recorded
---moment's state and event, in order. source: a SavedVariables file (by default the game's own AddonSimRecorder.lua
---under WTF), options: { session = which one (the last by default), maxGap = longest wait between moments }.
---@return number count Moments played
function steps.replay(source, options)
    options = options or {}
    if not source and sim.config.addonsRoot then
        source = sim.findNewestFile(
            (sim.config.addonsRoot or "") .. "/../../WTF/Account",
            "SavedVariables",
            "AddonSimRecorder.lua"
        )
    end
    local chunk = source and loadfile(source)
    if not chunk then
        act("replay", false, "no recording found (" .. tostring(source) .. ")")
        return 0
    end
    local holder = {}
    setfenv(chunk, holder)
    chunk()
    local sessions = holder.AddonSimRecording and holder.AddonSimRecording.sessions or {}
    local session = sessions[options.session or #sessions]
    if not session then
        act("replay", false, "the recording has no session")
        return 0
    end
    local character = session.character or {}
    game.setProfile({ race = character.race, class = character.class, level = character.level })
    local lastTime, count = nil, 0
    for _, entry in ipairs(session.entries or {}) do
        if lastTime and entry.t and entry.t > lastTime then
            steps.wait(math.min(entry.t - lastTime, options.maxGap or 2))
        end
        lastTime = entry.t or lastTime
        game.applyRecordedState(entry)
        if entry.e ~= "START" and entry.e ~= "STOP" and entry.e ~= "POSITION" then
            local args = {}
            for index, value in ipairs(entry.a or {}) do
                args[index] = value ~= false and value or nil
            end
            sim.fireEvent(entry.e, unpack(args, 1, #(entry.a or {})))
        end
        count = count + 1
    end
    act(string.format("replay %d moments", count), true)
    return count
end

---Moves the minimap as the game's Edit Mode does: to a point of the screen with an offset ("TOPLEFT", 20, -40).
function steps.moveMinimap(point, x, y)
    sim.placeMinimap(point, x, y)
    act("move the minimap", true)
end

---Targets a living creature (PLAYER_TARGET_CHANGED), as clicking it in the world does.
function steps.targetCreature(npcId)
    act("target " .. tostring(npcId), game.pointAt(npcId, "target"))
end
---Hovers a living creature in the world: it becomes the mouseover and the game shows its tooltip.
function steps.hoverCreature(npcId)
    act("hover " .. tostring(npcId), game.pointAt(npcId, "mouseover"))
end
-- Fights (lua/combat.lua): spawn, target, targetNext, focus, hoverEnemy, attack, stopAttack, useAction, cast, fight,
-- waitUntil, waitUntilDead, lootCorpse, release, resurrect, resetCombat, hurt, enemy, combatState
require("combat").addSteps(steps, act)
-- The project's plugins' steps (plugins.addSteps)
plugins.installSteps(steps, act)

-- The world map's zoom, on the game's own map (the whole interface: its scroll container's zoom levels, zoomed with
-- ZoomIn and ZoomOut: at once on the world map, which zooms instantly, gliding over frames on a map that does not)
-- and the simulator's stand-in map alike
local function mapContainer()
    return sim.G.WorldMapFrame and sim.G.WorldMapFrame.ScrollContainer
end
function steps.mapZoomLevelCount()
    local container = mapContainer()
    if not container then
        return 0
    end
    if container.GetZoomLevelCount then
        return container.GetZoomLevelCount()
    end
    return type(container.zoomLevels) == "table" and #container.zoomLevels or 0
end
---Zooms the world map in (direction 1) or out (-1) by levels steps, or all the way when levels is nil.
function steps.zoomMap(direction, levels)
    local container = mapContainer()
    if not container then
        act("zoom the map", false, "no map")
        return
    end
    for _ = 1, levels or steps.mapZoomLevelCount() do
        if container.GetZoomLevelCount then
            if direction > 0 then
                container.ZoomIn()
            else
                container.ZoomOut()
            end
        elseif direction > 0 then
            container:ZoomIn()
        else
            container:ZoomOut()
        end
        steps.wait(0.5) -- (time for a map that glides to each level)
    end
    act("zoom the map " .. (direction > 0 and "in" or "out"), true)
end

function steps.slash(text)
    act(text, runtime.runSlashCommand(text))
end
-- (a tap: down, then up, so a binding run on the release and a click binding's up-click run too, as in the client)
function steps.key(name, text)
    playerInput({ type = "key", key = name, text = text })
    playerInput({ type = "keyup", key = name })
    act("key " .. name, true)
end
function steps.fire(event, ...)
    sim.fireEvent(event, ...)
    act("event " .. event, true)
end

-- Pointing: at a frame by name, at a point (x, y from the top left, as the page counts), or at visible text
local function centerOf(object)
    local rect = W.computeRect(object)
    if not rect then
        return nil
    end
    return (rect[1] + rect[3]) / 2, sim.screenHeight - (rect[2] + rect[4]) / 2
end

---Where to point: a frame (or its global name) is its middle; a string that names no frame is visible text,
---found on screen; a table is { x, y }.
local function resolve(target)
    if type(target) == "table" and target.x then
        return target.x, target.y
    end
    if type(target) == "table" and type(target[1]) == "number" then
        return target[1], target[2]
    end
    if type(target) == "table" and S[target] then
        return centerOf(target)
    end
    if type(target) == "string" then
        local frame = sim.G[target]
        if type(frame) == "table" and S[frame] and W.isVisible(frame) then
            return centerOf(frame)
        end
        -- The topmost text that says it, as a player clicks what is on top: the drawing list is back to front
        local items = scene.export()
        for index = #items, 1, -1 do
            local item = items[index]
            if item.k == "s" then
                for _, line in ipairs(item.lines) do
                    local plain = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
                    if plain == target or plain:find(target, 1, true) then
                        return item.x + item.w / 2, item.y + item.h / 2
                    end
                end
            end
        end
    end
    return nil
end
steps.find = resolve

function steps.hover(target)
    local x, y = resolve(target)
    if not x then
        act("hover " .. tostring(target), false, "not on screen")
        return
    end
    playerInput({ type = "move", x = x, y = y })
    act("hover " .. tostring(target), true)
end

---@param mods { shift: boolean?, ctrl: boolean?, alt: boolean? }? Keys held while clicking
function steps.click(target, button, mods)
    local x, y = resolve(target)
    if not x then
        act("click " .. tostring(target), false, "not on screen")
        return
    end
    playerInput({ type = "move", x = x, y = y, mods = mods })
    playerInput({ type = "down", x = x, y = y, button = button or "LeftButton", mods = mods })
    playerInput({ type = "up", x = x, y = y, button = button or "LeftButton", mods = mods })
    if mods then
        playerInput({ type = "move", x = x, y = y, mods = {} })
    end -- and let go of the keys
    act("click " .. tostring(target), true)
end

---Presses on a target, moves the mouse to a point (or by an offset: { dx, dy }) and lets go, as dragging does.
function steps.drag(target, destination, button)
    local x, y = resolve(target)
    if not x then
        act("drag " .. tostring(target), false, "not on screen")
        return
    end
    local toX, toY
    if type(destination) == "table" and destination.dx then
        toX, toY = x + destination.dx, y + (destination.dy or 0)
    else
        toX, toY = resolve(destination)
    end
    if not toX then
        act("drag " .. tostring(target), false, "no place to drop on")
        return
    end
    playerInput({ type = "move", x = x, y = y })
    playerInput({ type = "down", x = x, y = y, button = button or "LeftButton" })
    -- A few pixels at a time, as a real mouse moves: the game starts a drag only after the first few
    local stepCount = math.max(1, math.ceil(math.sqrt((toX - x) ^ 2 + (toY - y) ^ 2) / 3))
    for step = 1, stepCount do
        playerInput({ type = "move", x = x + (toX - x) * step / stepCount, y = y + (toY - y) * step / stepCount })
    end
    sim.tick(0.02)
    playerInput({ type = "up", x = toX, y = toY, button = button or "LeftButton" })
    act("drag " .. tostring(target), true)
end

---Saves a picture of this moment (the drawn scene) to look at: <the page>/?compare=.last-run/<scenario>/<name>
---(kept in the project's scenarios folder, which the server serving the project shows)
function steps.saveScene(name)
    local folder = scenariosDir .. "/.last-run/" .. scenarioName
    sim.makeDirectory(folder)
    local out = io.open(folder .. "/" .. name .. ".scene.json", "w")
    if out then
        out:write(
            require("json").encode({ width = sim.screenWidth, height = sim.screenHeight, items = scene.export() })
        )
        out:close()
    end
    print("picture: " .. PAGE .. "/?compare=.last-run/" .. scenarioName .. "/" .. name)
end

---A check on the chat: some line since the scenario began holds the text (plain, colour codes left out).
function steps.expectChat(text, message)
    for index = #sim.chat, 1, -1 do
        local plain = sim.chat[index].text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if plain:find(text, 1, true) then
            return true
        end
    end
    steps.expect(false, message or ("in the chat: " .. text))
    return false
end

---Empties the chat, so the next expectChat sees only what comes after.
function steps.clearChat()
    for index = #sim.chat, 1, -1 do
        sim.chat[index] = nil
    end
end

function steps.wheel(target, delta)
    local x, y = resolve(target)
    if not x then
        act("wheel " .. tostring(target), false, "not on screen")
        return
    end
    playerInput({ type = "move", x = x, y = y })
    playerInput({ type = "wheel", x = x, y = y, delta = delta or -1 })
    act("wheel " .. tostring(target), true)
end

---A check: the scenario fails, and goes on, when it does not hold.
function steps.expect(isTrue, message)
    if not isTrue then
        fail("expected: " .. tostring(message))
    end
end

function steps.expectText(text, message)
    steps.expect(resolve(text) ~= nil, message or ("on screen: " .. text))
end

function steps.expectNoText(text, message)
    steps.expect(resolve(text) == nil, message or ("not on screen: " .. text))
end

---Draws the scene, as the page does each frame, so drawing errors surface too.
function steps.draw()
    local items = scene.export()
    act("draw", #items > 0, "nothing drawn")
    return #items
end

-- Reference snapshots: what is on screen, one drawn thing per line, kept under <scenarios>/golden/<scenario>/
-- <name>.txt. The first run (or `addonsim test --update`) writes it; later runs fail when it changed.
local SNAPSHOT_FIELDS = {
    "k",
    "x",
    "y",
    "w",
    "h",
    "atlas",
    "tex",
    "tc",
    "tcTurned",
    "sc",
    "c",
    "vc",
    "a",
    "lines",
    "fs",
    "f",
    "bl",
    "ds",
    "mask",
    "cl",
}
local function composeValue(value)
    if type(value) == "number" then
        local rounded = math.floor(value * 100 + 0.5) / 100
        return rounded == math.floor(rounded) and string.format("%d", rounded) or string.format("%.2f", rounded)
    elseif type(value) == "string" then
        return string.format("%q", value)
    elseif type(value) == "table" then
        local parts = {}
        for index, part in ipairs(value) do
            parts[index] = composeValue(part)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    return tostring(value)
end

local function composeSnapshotLines(area)
    local lines = {}
    for _, item in ipairs(scene.export()) do
        -- Only what lies inside the area, when one is given
        local x, y, width, height = item.x or 0, item.y or 0, item.w or 0, item.h or 0
        if
            not area
            or (
                x >= area[1] - 0.5
                and y >= area[2] - 0.5
                and x + width <= area[1] + area[3] + 0.5
                and y + height <= area[2] + area[4] + 0.5
            )
        then
            local parts = {}
            for _, field in ipairs(SNAPSHOT_FIELDS) do
                if item[field] ~= nil then
                    parts[#parts + 1] = field .. "=" .. composeValue(item[field])
                end
            end
            lines[#lines + 1] = table.concat(parts, " ")
        end
    end
    -- Sorted: the order addons draw equal things in follows table addresses (pairs over tables keyed by
    -- objects), which change between runs; what is drawn, and where, is what is compared
    table.sort(lines)
    return lines
end

---@param within (string|table)? Only what is drawn inside this frame (its global name, or the frame itself)
function steps.snapshot(name, within)
    local folder = scenariosDir .. "/golden/" .. scenarioName
    -- With the game's whole interface its own frames are drawn too (the real minimap): a reference of its own
    if sim.isWholeInterface then
        name = name .. "-whole"
    end
    local path = folder .. "/" .. name .. ".txt"
    local area
    if within then
        local frame = type(within) == "string" and sim.G[within] or within
        local rect = frame and W.computeRect(frame)
        if not rect then
            act("snapshot " .. name, false, "no such frame on screen")
            return
        end
        area = { rect[1], sim.screenHeight - rect[4], rect[3] - rect[1], rect[4] - rect[2] }
    end
    local lines = composeSnapshotLines(area)
    -- The whole drawn scene too, for the comparison page (a picture of what changed)
    local function saveScene(sceneFolder)
        sim.makeDirectory(sceneFolder)
        local out = io.open(sceneFolder .. "/" .. name .. ".scene.json", "w")
        if out then
            out:write(
                require("json").encode({ width = sim.screenWidth, height = sim.screenHeight, items = scene.export() })
            )
            out:close()
        end
    end
    local file = io.open(path, "r")
    if not file or os.getenv("ADDONSIM_UPDATE") == "1" then
        if file then
            file:close()
        end
        sim.makeDirectory(folder)
        local out = assert(io.open(path, "w"))
        out:write(table.concat(lines, "\n"), "\n")
        out:close()
        saveScene(folder)
        note("snapshot " .. name .. " written (" .. #lines .. " drawn things)")
        act("snapshot " .. name, true)
        return
    end
    local expected = {}
    for line in file:lines() do
        expected[#expected + 1] = line
    end
    file:close()
    local changed, first = 0, nil
    for index = 1, math.max(#expected, #lines) do
        if expected[index] ~= lines[index] then
            changed = changed + 1
            first = first
                or string.format(
                    "line %d\n      was: %s\n      now: %s",
                    index,
                    expected[index] or "(nothing)",
                    lines[index] or "(nothing)"
                )
        end
    end
    if changed > 0 then
        saveScene(scenariosDir .. "/.last-run/" .. scenarioName)
        fail(
            string.format(
                "snapshot %s changed in %d of %d lines (addonsim test --update to accept); first at %s"
                    .. "\n      see it: %s/?compare=golden/%s/%s|.last-run/%s/%s",
                name,
                changed,
                math.max(#expected, #lines),
                first,
                PAGE,
                scenarioName,
                name,
                scenarioName,
                name
            )
        )
    end
    act("snapshot " .. name, true)
end

-- Run it
local chunk, problem = loadfile(scenarioPath)
if not chunk then
    io.write("Cannot read the scenario: " .. tostring(problem) .. "\n")
    os.exit(2)
end
-- Bare names: the steps first, then plain Lua (the runner's own globals), then the game's, so UnitName("player")
-- works as G.UnitName("player") does (what an addon's author, or an AI, writes first). Assignments stay the scenario's.
local gameGlobals = sim.G
setfenv(
    chunk,
    setmetatable(steps, {
        __index = function(_, name)
            local value = rawget(_G, name)
            if value ~= nil then
                return value
            end
            return gameGlobals[name]
        end,
    })
)
io.write(string.format("Booted in %.2fs; playing %s\n", runtime.bootSeconds, scenarioPath))
local isDone, scenarioProblem = xpcall(chunk, debug.traceback)
if not isDone then
    failures[#failures + 1] = "the scenario itself failed: " .. tostring(scenarioProblem)
end
-- A check to run after every scenario, in its own words (ADDONSIM_AFTER names a scenario file): what must hold
-- whatever was played, such as an addon's caches still matching what they were read from
local afterPath = os.getenv("ADDONSIM_AFTER")
if afterPath and afterPath ~= "" then
    local afterChunk, afterProblem = loadfile(afterPath)
    if not afterChunk then
        failures[#failures + 1] = "the after-check could not be read: " .. tostring(afterProblem)
    else
        setfenv(afterChunk, steps)
        local isChecked, checkProblem = xpcall(afterChunk, debug.traceback)
        if not isChecked then
            failures[#failures + 1] = "the after-check failed: " .. tostring(checkProblem)
        end
    end
end
steps.draw()

-- Report
for _, entry in ipairs(sim.errors) do
    io.write(
        string.format(
            "\nLua error%s: %s\n%s\n",
            entry.count > 1 and (" (" .. entry.count .. "x)") or "",
            entry.message,
            entry.stack
        )
    )
end
for _, failure in ipairs(failures) do
    io.write("\nFailed: " .. failure .. "\n")
end
-- Stand-ins addons reached matter; the ones only the game's own interface code touched are only counted
local stubs, internalCount = {}, 0
for name in pairs(sim.stubs) do
    local callers = sim.stubCallers[name]
    if callers then
        local addonNames = {}
        for addon in pairs(callers) do
            addonNames[#addonNames + 1] = addon
        end
        table.sort(addonNames)
        stubs[#stubs + 1] = name .. " (" .. table.concat(addonNames, ", ") .. ")"
    else
        internalCount = internalCount + 1
    end
end
table.sort(stubs)
if #stubs > 0 or internalCount > 0 then
    io.write(
        string.format(
            "\nStood in for addons (not real game API yet): %s%s\n",
            #stubs > 0 and table.concat(stubs, ", ") or "none",
            internalCount > 0 and string.format("; and %d only inside the game's own interface code", internalCount)
                or ""
        )
    )
end
writeCoverage()
local isPassed = #sim.errors == 0 and #failures == 0
io.write(
    string.format(
        "\n%s: %d steps, %d Lua errors, %d failed checks\n",
        isPassed and "PASSED" or "FAILED",
        stepCount,
        #sim.errors,
        #failures
    )
)
os.exit(isPassed and 0 or 1)
