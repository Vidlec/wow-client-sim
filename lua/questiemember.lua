-- A party member running Questie: their messages made by Questie's own code (vendor/questie: QuestieSerializer,
-- QuestieStream, and AceComm-3.0 to split long ones), so what reaches the player's addons is what Questie sends.
-- The member sends, as Questie does: on joining, a request for everyone's quest log and its own log (packet 10,
-- in blocks); on progress, the quest's counts (packet 1); on dropping a quest, its removal (packet 2); and when
-- asked for its log (packet 11), the log again, whispered.
-- A built-in party addon, registered through the same plugin API a project's own party addons use (lua/plugins.lua).
local sim = require("sim")
local plugins = require("plugins")

local questieMember = {}
local G = sim.G

local PREFIX = "questie"
local MESSAGE_VERSION = 5
local QUESTIE_VERSION = "11.0.0"
local PACKET_QUEST_UPDATE, PACKET_QUEST_REMOVE, PACKET_FULL_LOG, PACKET_REQUEST_LOG = 1, 2, 10, 11
local MAX_BLOCK_LENGTH = 200 -- as Questie splits its log into blocks

local sandbox, serializer, aceComm
local sendingMember -- whose message AceComm is splitting right now

---Loads Questie's code once, in a sandbox of its own: its globals never reach the game's.
local function load()
    if sandbox then return end
    local root = sim.root .. "/lua/vendor/questie/"
    local modules = {}
    sandbox = setmetatable({}, { __index = G })
    sandbox._G = sandbox
    sandbox.QuestieLoader = {
        CreateModule = function(_, name) modules[name] = modules[name] or {}; return modules[name] end,
        ImportModule = function(_, name) modules[name] = modules[name] or {}; return modules[name] end,
    }
    -- AceComm sends through ChatThrottleLib; here each part goes straight out as the member's addon message
    sandbox.ChatThrottleLib = {
        SendAddonMessage = function(_, _, prefix, text, channel)
            plugins.sendFromMember(sendingMember, prefix, text, channel, 0.2)
        end,
    }
    for _, file in ipairs({ "LibStub.lua", "CallbackHandler-1.0.lua", "AceComm-3.0.lua", "QuestieStream.lua", "QuestieSerializer.lua" }) do
        local chunk = assert(loadfile(root .. file))
        setfenv(chunk, sandbox)
        chunk()
    end
    serializer = modules.QuestieSerializer
    aceComm = sandbox.LibStub("AceComm-3.0")
end

local function send(member, data, channel, target)
    load()
    data.ver, data.msgVer = QUESTIE_VERSION, MESSAGE_VERSION
    sendingMember = member
    aceComm:SendCommMessage(PREFIX, serializer:Serialize(data), channel, target, "BULK")
    sendingMember = nil
end

---A quest as Questie packs it: its id and each objective's database id, type letter, and counts.
local function composeQuest(questId, quest)
    local packed = { id = questId, objectives = {} }
    for index, objective in ipairs(quest.objectives) do
        packed.objectives[index] = { id = objective.id or 0, typ = (objective.kind or "m"):sub(1, 1),
            fin = objective.fulfilled >= objective.required, ful = objective.fulfilled, req = objective.required }
    end
    return packed
end

---The member's whole log, in blocks small enough for one message each, as Questie sends it.
function questieMember.sendLog(member, channel, target)
    local block, blocks = {}, {}
    local questIds = {}
    for questId in pairs(member.quests) do questIds[#questIds + 1] = questId end
    table.sort(questIds)
    load()
    for _, questId in ipairs(questIds) do
        block[questId] = composeQuest(questId, member.quests[questId])
        if #serializer:Serialize(block) > MAX_BLOCK_LENGTH then
            block[questId] = nil
            blocks[#blocks + 1] = block
            block = { [questId] = composeQuest(questId, member.quests[questId]) }
        end
    end
    if next(block) then blocks[#blocks + 1] = block end
    for _, rawQuestList in ipairs(blocks) do
        send(member, { msgId = PACKET_FULL_LOG, rawQuestList = rawQuestList }, channel, target)
    end
end

function questieMember.sendJoin(member)
    send(member, { msgId = PACKET_REQUEST_LOG }, "PARTY")
    questieMember.sendLog(member, "PARTY")
end

function questieMember.sendChange(member, questId)
    local quest = member.quests[questId]
    if quest then
        send(member, { msgId = PACKET_QUEST_UPDATE, quest = composeQuest(questId, quest) }, "PARTY")
    else
        send(member, { msgId = PACKET_QUEST_REMOVE, id = questId }, "PARTY")
    end
end

---The player's addon sent something on Questie's channel: a request for logs is answered, whispered.
---@return boolean isRequest
function questieMember.isLogRequest(text)
    load()
    if type(text) ~= "string" or text:match("^[\001-\003]") then return false end -- part of a long message: not a request
    local isRead, data = pcall(serializer.Deserialize, serializer, text:gsub("^\004", ""))
    return isRead and type(data) == "table" and data.msgId == PACKET_REQUEST_LOG
end

plugins.registerPartyAddon("Questie", {
    label = "Questie",
    note = "Shares its log and progress on its own channel (Questie's serializer)",
    color = "warning",
    onJoin = function(member) questieMember.sendJoin(member) end,
    onQuestChanged = function(member, questId) questieMember.sendChange(member, questId) end,
    onMessage = function(member, message)
        if message.prefix == PREFIX and questieMember.isLogRequest(message.text) then
            questieMember.sendLog(member, "WHISPER", plugins.playerName())
        end
    end,
})

return questieMember
