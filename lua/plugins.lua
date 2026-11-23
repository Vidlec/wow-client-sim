-- The plugin API: what a project's Lua plugins (its addonsim.config.ts "plugins") use to extend the simulator, and
-- the only part of it they should touch. It stays put while the simulator's own modules change.
--
--   local plugins = require("plugins")
--   plugins.registerPartyAddon("MyAddon", { label = "MyAddon", note = "...", onJoin = ..., onMessage = ... })
--   plugins.addSteps(function(steps, act) function steps.myStep(...) act("my step", true) end end)
--   plugins.onBoot(function() ... end)
--
-- A plugin is a Lua file run once per boot (a /reload in a scenario boots again, and runs it again), after the
-- simulator's own modules are made and before the saved state, the game's interface and the addons load. Its
-- require() finds the project's luaPath folders first. Errors in it are reported as the simulator's own Lua errors
-- (the page's Errors, a scenario's report).
--
-- Costs: registering is a table insert; the party asks the registry once per member change and once per addon
-- message the player sends to the group (a table lookup), so plugins add nothing to a frame's time.
local sim = require("sim")
local game = require("game")

local plugins = { API_VERSION = 1 }

-- Party member addons, by name, and their order of registration (the page lists them so)
local partyAddons, partyAddonOrder = {}, {}
local stepAdders, bootHooks = {}, {}

---@class PartyMember What a plugin is handed: the simulated player (read it; change it through the party steps)
---@field name string
---@field realm string? nil: the player's realm
---@field classFile string "WARRIOR", "MAGE"...
---@field level number
---@field race string
---@field addon string The party addon it runs ("none": none)
---@field isOnline boolean
---@field quests table<number, { objectives: { kind: string, name: string, id: number?, fulfilled: number, required: number }[], isComplete: boolean }>
---@field doneQuestIds number[] Quests it handed in
---@field data table Free for the member's addon to keep its own state in

---@class PartyAddonMessage The player's addon message to the group, or whispered to a member
---@field prefix string
---@field text string
---@field channel string "PARTY", "RAID", "INSTANCE_CHAT", "WHISPER"
---@field target string? The whispered name

---@class PartyAddonSpec
---@field label string? The name the page shows (the addon's name by default)
---@field note string? One line the page shows under it: what the member then tells the party
---@field color string? The page's chip colour: "accent", "success", "warning", "danger" or "default"
---@field isDefault boolean? A member joining without an addon named runs this one (the last registered wins)
---@field onJoin fun(member: PartyMember)? The member joined the group (online or not)
---@field onQuestChanged fun(member: PartyMember, questId: number)? A quest of its log was taken, moved on, completed or dropped (member.quests[questId] is nil when dropped); only while online
---@field onLeave fun(member: PartyMember)? The member left the group (it is out of the party's list already)
---@field onMessage fun(member: PartyMember, message: PartyAddonMessage)? The player sent an addon message the member hears; only while online

---Registers an addon a party member may run: what it tells the player's addons when the member joins, changes its
---quest log, leaves, or hears the player's addon messages. Registering a name again replaces it.
---@param name string The addon's name, as members name it (joinParty({ addon = name }))
---@param spec PartyAddonSpec
function plugins.registerPartyAddon(name, spec)
    assert(type(name) == "string" and name ~= "" and name ~= "none", "a party addon needs a name (not \"none\")")
    if not partyAddons[name] then partyAddonOrder[#partyAddonOrder + 1] = name end
    partyAddons[name] = spec or {}
end

---@return PartyAddonSpec? spec The registered addon of that name
function plugins.getPartyAddon(name) return partyAddons[name] end

---The addon a member runs when none is named: the default one registered last, else "none".
function plugins.defaultPartyAddon()
    local default = "none"
    for _, name in ipairs(partyAddonOrder) do
        if partyAddons[name].isDefault then default = name end
    end
    return default
end

---The party addons for the page: "none" first, then each registered one.
function plugins.describePartyAddons()
    local default = plugins.defaultPartyAddon()
    local list = { { id = "none", label = "No addon", note = "Only what the game itself shares", color = "default", isDefault = default == "none" } }
    for _, name in ipairs(partyAddonOrder) do
        local spec = partyAddons[name]
        list[#list + 1] = { id = name, label = spec.label or name, note = spec.note or "", color = spec.color or "default",
            isDefault = default == name }
    end
    return list
end

---Calls a member's addon's handler, if it has one; an error in it is reported, never thrown into the party's code.
---@return boolean called
function plugins.callPartyAddon(member, hook, ...)
    local spec = partyAddons[member.addon]
    local handler = spec and spec[hook]
    if not handler then return false end
    local isDone, problem = xpcall(handler, debug.traceback, member, ...)
    if not isDone then sim.reportError("party addon " .. tostring(member.addon) .. " " .. hook .. ": " .. tostring(problem), "") end
    return true
end

---Delivers an addon message to the player as the game does (CHAT_MSG_ADDON), sent by a party member, after the
---delay another client takes (0.3 seconds by default). Nothing arrives when the member left in the meantime.
---@param member PartyMember
---@param channel string? "PARTY" by default; "WHISPER" goes to the player
function plugins.sendFromMember(member, prefix, text, channel, delay)
    channel = channel or "PARTY"
    sim.G.C_Timer.After(delay or 0.3, function()
        if not require("party").findMember(member.name) then return end
        sim.fireEvent("CHAT_MSG_ADDON", prefix, text, channel, plugins.fullName(member), channel == "WHISPER" and game.profile.name or "")
    end)
end

---A member's name with its realm, as the game gives senders ("Garra-Realm").
function plugins.fullName(member) return member.name .. "-" .. (member.realm or game.profile.realm) end

---@return PartyMember[] members The group's members, in party1..party4 order (do not change the list)
function plugins.partyMembers() return require("party").members end

---The player's name, for messages whispered to them.
function plugins.playerName() return game.profile.name end

---Adds scenario steps: adder(steps, act) is called with the scenario's step table (set fields on it) and act(name,
---ok, problem), which counts a step, fails the scenario when ok is false, and lets the clock run a moment. Called
---again after a scenario's reload().
function plugins.addSteps(adder) stepAdders[#stepAdders + 1] = adder end

---The scenario runner's part: every plugin's steps added to a scenario's step table.
function plugins.installSteps(steps, act)
    for _, adder in ipairs(stepAdders) do adder(steps, act) end
end

---Runs a function right before the addons load: the game's own interface is in by then (its frames and mixins), so
---a plugin may hook them.
function plugins.onBoot(hook) bootHooks[#bootHooks + 1] = hook end

function plugins.runBootHooks()
    for _, hook in ipairs(bootHooks) do
        local isDone, problem = xpcall(hook, debug.traceback)
        if not isDone then sim.reportError("plugin boot hook: " .. tostring(problem), "") end
    end
end

---Runs the project's plugin files, in order. Each one's errors are reported and the next still runs.
function plugins.load(paths)
    for _, path in ipairs(paths or {}) do
        local chunk, problem = loadfile(path)
        if not chunk then
            sim.reportError("plugin " .. tostring(path) .. ": " .. tostring(problem), "")
        else
            local isDone, runProblem = xpcall(chunk, debug.traceback)
            if not isDone then sim.reportError("plugin " .. tostring(path) .. ": " .. tostring(runProblem), "") end
        end
    end
end

return plugins
