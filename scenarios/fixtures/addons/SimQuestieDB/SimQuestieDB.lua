-- A stand-in for QuestieDB (github.com/Questie/QuestieDB, GPL-3.0) in the simulator's own scenarios: the global
-- LibQuestieDB with the four kinds the simulator reads (Quest, Npc, Item, Object), each answering Get(id, field) and
-- GetAllIds() as QuestieDB's do, from the few entries in Data.lua; in another language, its own values first.
local _, ns = ...

local function makeStore(kind)
    local entries = ns.data[kind] or {}
    local store = {}
    ---One field of one entry, as QuestieDB's Get gives it; nil for an entry or a field it does not have
    function store.Get(id, field)
        local localized = ns.localized[GetLocale()]
        local own = localized and localized[kind] and localized[kind][id]
        if own and own[field] ~= nil then
            return own[field]
        end
        local entry = entries[id]
        return entry and entry[field]
    end
    ---Every entry's id, in order
    function store.GetAllIds()
        local ids = {}
        for id in pairs(entries) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        return ids
    end
    return store
end

LibQuestieDB = {
    Quest = makeStore("Quest"),
    Npc = makeStore("Npc"),
    Item = makeStore("Item"),
    Object = makeStore("Object"),
}
