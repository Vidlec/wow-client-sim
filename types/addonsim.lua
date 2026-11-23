---@meta addonsim
-- AddonSim's scenario API, for LuaLS (and for `addonsim docs`, which prints its reference from this file).
-- A scenario (and code run with `addonsim eval`) runs with these as its globals; the game's own globals are in G.
-- In a project's .luarc.json: "workspace.library": ["node_modules/addonsim/types"] (or the checkout's types folder).
-- Each step takes the game's clock on by 0.1 s after it (so frames update as a player would see), and a step that
-- cannot be done is a failed check: the scenario goes on, and fails at its end.

-- ## The game

---The game's global table: its frames, functions and the addons' globals (G.UIParent, G.C_QuestLog, G.MyAddonDB).
---@type table
G = {}

---The simulator's game model: the character (game.profile), the quest log (game.questLog), quests done
---(game.completed), finders (game.findQuests(text), game.findNpcs(text)).
---@type table
game = {}

---The project's folder (the simulator's, without a project).
---@type string
projectRoot = ""

---The project's scenarios folder, for scenarios that read files of their own.
---@type string
scenariosDir = ""

---The simulator's own folder.
---@type string
root = ""

---This part of a scenario split with `--@shards N`: { index, count } (1, 1 when not split).
---@type { index: number, count: number }
shard = { index = 1, count = 1 }

---This part's share of a list, every count-th item from its own (the whole list when not split).
---@generic T
---@param list T[]
---@return T[]
function forShard(list) end

-- ## The character and the world

---Changes the character: level, race ("Scourge", "NightElf"...), class ("MAGE"...), name, money, sex, and the rest of
---game.profile. A scenario's first lines may log in as one instead: --@login race=Orc,class=WARRIOR,level=12.
---@param changes { level: number?, race: string?, class: string?, name: string?, money: number?, legacyRenown: number? }
function setProfile(changes) end

---Puts the character on a map (a UiMap id) at x, y (0 to 1, as the map's coordinates).
---@param uiMapId number
---@param x number
---@param y number
function moveTo(uiMapId, x, y) end

---Walks to a point of a map at running speed, as clicking to move does, the clock running meanwhile.
---@param uiMapId number
---@param x number
---@param y number
---@param maxSeconds number? 600 by default
---@return number seconds How long it took
function walkTo(uiMapId, x, y, maxSeconds) end

---Moves at once by yards ahead (negative: back) and to the right.
---@param forward number
---@param right number?
function walk(forward, right) end

---Turns left by degrees.
---@param degrees number
function turn(degrees) end

---Faces a direction (degrees, 0 north).
---@param degrees number
function face(degrees) end

---Holds a key down for some seconds, as a player does to run (W), turn (A, D) or strafe (Q, E).
---@param key string
---@param seconds number? 1 by default
function hold(key, seconds) end

---Enters an instance (as the game's GetInstanceInfo then answers).
---@param instanceId number
---@param instanceType string "party", "raid", "pvp", "arena"
---@param name string?
function enterInstance(instanceId, instanceType, name) end

---Leaves the instance.
function leaveInstance() end

---Wears an item (by id), in its slot or the one given.
---@param itemId number
---@param slot number?
function equip(itemId, slot) end

---Takes off what is worn in a slot.
---@param slot number
function unequip(slot) end

---What the game hides from addons, as in PvP and some instances.
---@param restrictions { identity: boolean?, threat: boolean? }?
function restrict(restrictions) end

---The game's screen: width by height pixels, with the UI scale on at uiScale, or off (nil: pixel for pixel).
---@param width number
---@param height number
---@param uiScale number?
function screen(width, height, uiScale) end

-- ## Quests

---Takes a quest into the log (QUEST_ACCEPTED, QUEST_LOG_UPDATE...).
---@param questId number
function accept(questId) end

---Moves an objective of a quest in the log on by an amount (1 by default).
---@param questId number
---@param index number? The objective (1 by default)
---@param amount number?
function progress(questId, index, amount) end

---Fulfils every objective of a quest in the log.
---@param questId number
function complete(questId) end

---Hands a completed quest in (it leaves the log, counts as done).
---@param questId number
function turnIn(questId) end

---Drops a quest from the log.
---@param questId number
function abandon(questId) end

---Kills a creature of the game's data (it counts for quests, may drop quest items).
---@param npcId number
---@param options { loot: boolean?, isTappedByOthers: boolean?, via: "target"|"nameplate"|"unseen"|nil, dropChance: number? }?
function kill(npcId, options) end

---Kills a creature again and again, as farming does: its quest items drop at the chance given.
---@param npcId number
---@param count number
---@param dropChance number?
---@param via string?
---@return number drops How many objective counts it moved on
function hunt(npcId, count, dropChance, via) end

---Loots an item (count 1 by default).
---@param itemId number
---@param count number?
function loot(itemId, count) end

---Sets the random seed (drops, fights), so a run plays the same every time.
---@param seed number
function seed(seed) end

---Talks to a quest giver: its dialog (quests offered, to hand in) opens.
---@param npcId number
function talk(npcId) end

---Closes the quest giver's dialog.
function closeDialog() end

---Targets a living creature (PLAYER_TARGET_CHANGED), as clicking it in the world does.
---@param npcId number
function targetCreature(npcId) end

---Hovers a living creature in the world: it becomes the mouseover and the game shows its tooltip.
---@param npcId number
function hoverCreature(npcId) end

---Plays back a session the AddonSim Recorder recorded in the game: the character, then each moment's state and event.
---@param source string? A SavedVariables file (the game's own AddonSimRecorder.lua by default)
---@param options { session: number?, maxGap: number? }?
---@return number count Moments played
function replay(source, options) end

-- ## Fights

---Creatures near the player, as units (nameplates, target, threat, casts). They aggro, chase, swing and cast.
---@param creature number|string An npc id, or a name
---@param options { count: number?, distance: number?, bearing: number?, level: number?, aggro: boolean?, spellId: number? }?
---@return number? id, number[]? ids The first one's id, and all of them
function spawn(creature, options) end

---Targets an enemy (by the id spawn gave; nil: none), as clicking it does.
---@param id number?
function target(id) end

---Targets the next enemy, as Tab does.
---@param isReverse boolean?
function targetNext(isReverse) end

---Focuses an enemy.
---@param id number?
function focus(id) end

---Hovers an enemy (its mouseover).
---@param id number?
function hoverEnemy(id) end

---Auto-attack on: the target, or this enemy targeted first.
---@param id number?
function attack(id) end

---Auto-attack off.
function stopAttack() end

---Runs away from whoever fights the player, until they give up.
function flee() end

---Presses an action button's slot, as its key does.
---@param slot number
function useAction(slot) end

---Casts a spell by id (its cost, cooldown, range and cast bar as the game has them).
---@param spellId number
function cast(spellId) end

---Fights an enemy to its death or the player's: targets, attacks, walks up, presses the slots given when usable.
---@param id number?
---@param options { slots: number[]?, range: number?, maxSeconds: number?, seconds: number? }?
---@return number seconds
function fight(id, options) end

---Walks up to an enemy at running speed until within range yards (5 by default).
---@param id number?
---@param range number?
---@return number seconds
function approach(id, range) end

---Runs the clock until check() holds (maxSeconds at most, 60 by default); a failed check when it never does.
---@param check fun(): boolean
---@param maxSeconds number?
---@param message string?
---@return number seconds
function waitUntil(check, maxSeconds, message) end

---Runs the clock until an enemy dies (nil: the target; "player": the player).
---@param id number|string|nil
---@param maxSeconds number?
function waitUntilDead(id, maxSeconds) end

---Opens a corpse's loot and takes everything in it.
---@param id number?
function lootCorpse(id) end

---Releases the spirit (dead).
function release() end

---Comes back to life.
function resurrect() end

---Ends every fight and clears the enemies; a seed makes the next one play the same.
---@param seed number?
function resetCombat(seed) end

---Hurts the player (or an enemy) directly; a negative amount heals.
---@param amount number
---@param id number?
function hurt(amount, id) end

---What the page sees of an enemy (nil when there is none).
---@param id number?
---@return table? enemy
function enemy(id) end

---The fight as the page sees it.
---@return table
function combatState() end

-- ## The party

---A simulated player joins the group; with an addon (a registered party addon, or "none") it speaks its protocol.
---@param member { name: string, class: string?, level: number?, race: string?, addon: string? }
function joinParty(member) end

---@param name string
function leaveParty(name) end

---@param name string
---@param questId number
function memberAccept(name, questId) end

---@param name string
---@param questId number
---@param objective number
---@param amount number?
function memberProgress(name, questId, objective, amount) end

---@param name string
---@param questId number
function memberComplete(name, questId) end

---@param name string
---@param questId number
function memberAbandon(name, questId) end

---@param name string
---@param uiMapId number
---@param x number
---@param y number
function memberMoveTo(name, uiMapId, x, y) end

---Puts a member near the player (yards away, 20 by default).
---@param name string
---@param yards number?
function memberNear(name, yards) end

---@param name string
---@param isOnline boolean?
function memberOnline(name, isOnline) end

-- ## Input

---A key pressed and let go, by the client's name ("M", "ESCAPE", "ENTER", "SHIFT-1"): the game's bindings run.
---@param name string
---@param text string? The character it types, in an edit box
function key(name, text) end

---A slash command, as typed in the chat box ("/reload", "/myaddon").
---@param text string
function slash(text) end

---An event fired at every frame registered for it, as the game fires it.
---@param event string
---@param ... any Its arguments
function fire(event, ...) end

---Clicks a target: a frame (or its global name), text shown on screen (the topmost that says it), or { x, y } from
---the screen's top left. From the CLI and the SDK also "#id" and "Name.key" (what `addonsim ui` prints).
---@param target table|string
---@param button string? "LeftButton" (default), "RightButton"...
---@param mods { shift: boolean?, ctrl: boolean?, alt: boolean? }? Keys held while clicking
function click(target, button, mods) end

---Moves the mouse over a target (as click takes it): OnEnter runs, tooltips show.
---@param target table|string
function hover(target) end

---Presses on a target, moves to a point (or by { dx, dy }) and lets go, as dragging does.
---@param target table|string
---@param destination table|string
---@param button string?
function drag(target, destination, button) end

---Turns the mouse wheel over a target (delta -1: down, by default).
---@param target table|string
---@param delta number?
function wheel(target, delta) end

---Where a target is: its middle as x, y from the screen's top left (nil when it is not on screen).
---@param target table|string
---@return number? x, number? y
function find(target) end

---The game's gamepad interface on or off.
---@param isOn boolean?
function gamepadInterface(isOn) end

---A gamepad button pressed (PAD1, PADDUP, PADLTRIGGER...) and let go after some seconds (a tap by default).
---@param button string
---@param seconds number?
function pad(button, seconds) end

---A stick pushed ("Movement" or "Camera"; x right and y up, -1 to 1) for some seconds, then let go.
---@param stick string
---@param x number
---@param y number
---@param seconds number?
function padStick(stick, x, y, seconds) end

-- ## Maps

---Zooms the world map in (1) or out (-1), by levels steps or all the way.
---@param direction number
---@param levels number?
function zoomMap(direction, levels) end

---@return number count The world map's zoom levels
function mapZoomLevelCount() end

---The minimap's zoom (0 to 5).
---@param level number
function zoomMinimap(level) end

---Moves the minimap as Edit Mode does: to a point of the screen with an offset ("TOPLEFT", 20, -40).
---@param point string
---@param x number
---@param y number
function moveMinimap(point, x, y) end

-- ## Time and the session

---Runs the game's clock: timers and OnUpdate, in ticks of 0.05 s. In a live game (eval) time passes only so.
---@param seconds number? 0.05 by default
function wait(seconds) end

---/reload: PLAYER_LOGOUT, the saved variables and the character written, the game booted again in the same run with
---them. Frames and modules the scenario held are the old game's: find them again (G is the new game's).
function reload() end

-- ## Checks

---A check: the scenario fails (at its end) and goes on when it does not hold. The report gives the line.
---@param isTrue any
---@param message string?
function expect(isTrue, message) end

---A check that text is shown on screen (plain, colour codes left out; part of a line is enough).
---@param text string
---@param message string?
function expectText(text, message) end

---A check that text is not shown on screen.
---@param text string
---@param message string?
function expectNoText(text, message) end

---A check that some chat line since the scenario began (or clearChat) holds the text.
---@param text string
---@param message string?
---@return boolean found
function expectChat(text, message) end

---Empties the chat, so the next expectChat sees only what comes after.
function clearChat() end

---Draws the scene, as the page does each frame, so drawing errors surface too.
---@return number count Things drawn
function draw() end

---Compares what is drawn with a reference in <scenarios>/golden/<scenario>/<name>.txt (written the first time, and
---with `addonsim test --update`); fails when it changed, with a link to a picture of both.
---@param name string
---@param within string|table? Only what is drawn inside this frame
function snapshot(name, within) end

---Saves a picture of this moment to look at: <scenarios>/.last-run/<scenario>/<name>.scene.json
---(`addonsim shot --scene <scenario>/<name>` makes it a PNG).
---@param name string
function saveScene(name) end
