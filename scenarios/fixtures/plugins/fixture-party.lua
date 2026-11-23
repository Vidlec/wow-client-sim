-- The self-test project's plugin (src/project/select.ts): a party member addon of the fixture's own, made through the
-- plugin API (lua/plugins.lua) as a project's would be, so the simulator's suite tries that API too. Its protocol, on
-- the prefix "SimFixture":
--   joining: "HELLO"; a quest changed: "Q|<questId>|<fulfilled>/<required>,..." ("Q|<questId>|gone" when dropped)
--   the player's "PING": "PONG|<member>", whispered
-- It also adds a step, fixtureHeard(), the messages the player's side heard on the prefix (fixturelib keeps them).
local plugins = require("plugins")
local fixturelib = require("fixturelib")

local PREFIX = "SimFixture"

plugins.registerPartyAddon("SimFixture", {
    label = "SimFixture",
    note = "The fixture addon's own protocol (the self-test's plugin)",
    color = "success",
    onJoin = function(member) plugins.sendFromMember(member, PREFIX, "HELLO") end,
    onQuestChanged = function(member, questId)
        local quest = member.quests[questId]
        local counts = {}
        for index, objective in ipairs(quest and quest.objectives or {}) do counts[index] = objective.fulfilled .. "/" .. objective.required end
        plugins.sendFromMember(member, PREFIX, "Q|" .. questId .. "|" .. (quest and table.concat(counts, ",") or "gone"), "PARTY", 0.1)
    end,
    onLeave = function(member) fixturelib.left[#fixturelib.left + 1] = member.name end,
    onMessage = function(member, message)
        if message.prefix == PREFIX and message.text == "PING" then
            plugins.sendFromMember(member, PREFIX, "PONG|" .. member.name, "WHISPER", 0.1)
        end
    end,
})

-- The messages heard, kept from the boot on (the hook runs before the addons load, the game's interface in)
plugins.onBoot(function() fixturelib.listen(PREFIX) end)

plugins.addSteps(function(steps, act)
    ---@return { text: string, channel: string, sender: string }[] heard What came on the fixture's prefix so far
    function steps.fixtureHeard()
        act("fixture heard", true)
        return fixturelib.heard
    end
end)
