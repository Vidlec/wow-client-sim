-- What is on screen, as data for the SDK (src/sdk/): the shown frames with where they are and what they say, and a
-- compact state of the character. Read by lua/sdkplay.lua's commands; nothing here changes the game.
local sdkui = {}

local function plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[%w_]+:", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        :gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|n", " "):gsub("\n", " "))
end
sdkui.plain = plain

local function round(value) return math.floor(value + 0.5) end

---The text a frame shows: its shown font strings' (and an edit box's own), in the order they were made.
local function frameText(S, frame, state)
    local parts = {}
    if state.type == "EditBox" and state.text and state.text ~= "" then parts[#parts + 1] = plain(state.text) end
    for _, region in ipairs(state.regions or {}) do
        local rs = S[region]
        if rs and rs.shown and rs.type == "FontString" and rs.text and rs.text ~= "" then
            local text = plain(rs.text)
            if text:find("%S") then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " | ")
end

---Every shown frame, walked down from the top frames, as rows: { id, label, ref, type, depth, x, y, w, h, text,
---mouse, alpha, creator }. x, y from the screen's top left, as clicks count.
---@param options { filter: string?, creators: string[]?, limit: number?, at: number[]? }
---filter: rows whose label or text holds it (any case), and the frames they hang in as context; creators: only the
---frames those addons made (with no filter); limit: rows at most (300).
function sdkui.frames(runtime, options)
    options = options or {}
    local W, sim, scene = runtime.W, runtime.sim, runtime.scene
    local S = W.state
    local filter = options.filter and options.filter ~= "" and options.filter:lower() or nil
    local creators
    if options.creators and #options.creators > 0 and not filter then
        creators = {}
        for _, name in ipairs(options.creators) do creators[name] = true end
    end
    local limit = tonumber(options.limit) or 300
    local screenHeight = sim.screenHeight

    -- The rows of interest, found walking down the shown frames; the frames above one are kept as its context
    local rows = {}
    local function describe(frame, state, depth)
        local rect = W.computeRect(frame)
        local label = scene.frameLabel(frame)
        local row = { id = state.id, label = label, type = state.type, depth = depth, text = frameText(S, frame, state),
            creator = state.creator, mouse = state.mouse == true or nil }
        -- A name the game knows the frame by is what a click takes; else its number
        if state.name and sim.G[state.name] == frame then row.ref = state.name else row.ref = "#" .. state.id end
        if rect then
            row.x, row.y = round(rect[1]), round(screenHeight - rect[4])
            row.w, row.h = round(rect[3] - rect[1]), round(rect[4] - rect[2])
        end
        local alpha = frame.GetEffectiveAlpha and frame:GetEffectiveAlpha() or 1
        if alpha < 0.99 then row.alpha = math.floor(alpha * 100 + 0.5) / 100 end
        return row
    end
    -- A frame that neither says anything, nor is named, nor takes the mouse is a container: what it holds is enough
    local function isTelling(state, row) return row.text ~= "" or state.name ~= nil or state.mouse == true end
    local function isWanted(state, row)
        if filter then
            return row.label:lower():find(filter, 1, true) ~= nil or row.text:lower():find(filter, 1, true) ~= nil
        end
        if creators and not creators[state.creator or ""] then return false end
        return isTelling(state, row)
    end
    -- context: the telling frames above this one, outermost first; a row written goes under those written before it
    local function visit(frame, state, context)
        local row = describe(frame, state, 0)
        if isWanted(state, row) then
            local written = 0
            for _, above in ipairs(context) do
                if not above.isWritten then
                    above.isWritten, above.depth = true, written
                    rows[#rows + 1] = above
                end
                written = written + 1
            end
            row.isWritten, row.depth = true, written
            rows[#rows + 1] = row
        end
        if #rows > limit then return end
        local children = state.children
        if children then
            local isContext = row.isWritten or isTelling(state, row)
            if isContext then context[#context + 1] = row end
            for index = 1, #children do
                local child = children[index]
                local childState = S[child]
                if childState and childState.shown and childState.parent == frame and childState.isFrame ~= false then
                    visit(child, childState, context)
                end
            end
            if isContext then context[#context] = nil end
        end
    end
    for _, frame in ipairs(W.frames) do
        local state = S[frame]
        if state and state.shown and (state.isRoot or not state.parent or not S[state.parent]) then
            if state.isRoot then
                for _, child in ipairs(state.children or {}) do
                    local childState = S[child]
                    if childState and childState.shown and childState.parent == frame then visit(child, childState, {}) end
                end
            else
                visit(frame, state, {})
            end
        end
        if #rows > limit then break end
    end
    local isCut = #rows > limit
    while #rows > limit do rows[#rows] = nil end
    for _, row in ipairs(rows) do row.isWritten = nil end
    return { frames = rows, isCut = isCut or nil, width = sim.screenWidth, height = screenHeight }
end

---One frame by what a click takes: "#123" (its number), "Name" or "Name.key.key" (a global name and the keys below it)
---(runtime: boot.lua's; nil from a command's code, which finds the game's modules as they are loaded now)
function sdkui.findFrame(runtime, ref)
    runtime = runtime or { W = require("widgets"), sim = require("sim") }
    local W, sim = runtime.W, runtime.sim
    if type(ref) ~= "string" then return nil end
    local id = ref:match("^#(%d+)$")
    if id then return W.byId[tonumber(id)] end
    local value = sim.G
    for part in ref:gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    if type(value) == "table" and W.state[value] then return value end
    return nil
end

---The character and the game as the AI reads them: compact, no lists of thousands
function sdkui.state(runtime)
    local sim, game = runtime.sim, runtime.game
    local profile = game.profile or {}
    local log = {}
    for _, entry in ipairs(game.questLog or {}) do
        local objectives = {}
        for _, objective in ipairs(entry.objectives or {}) do
            objectives[#objectives + 1] = string.format("%s %d/%d", game.objectiveText(objective), objective.fulfilled or 0, objective.required or 0)
        end
        log[#log + 1] = { id = entry.questId, title = entry.title, level = entry.level, complete = entry.isComplete == true or nil,
            objectives = objectives }
    end
    local completedCount = 0
    for _ in pairs(game.completed or {}) do completedCount = completedCount + 1 end
    local G = sim.G
    local position = { uiMapId = profile.uiMapId, x = profile.x and math.floor(profile.x * 1000 + 0.5) / 1000,
        y = profile.y and math.floor(profile.y * 1000 + 0.5) / 1000, zone = G.GetRealZoneText and G.GetRealZoneText() or nil }
    local target = G.UnitExists and G.UnitExists("target") and { name = G.UnitName("target"), level = G.UnitLevel("target"),
        health = G.UnitHealth("target"), healthMax = G.UnitHealthMax("target") } or nil
    local chat = {}
    for index = math.max(1, #sim.chat - 9), #sim.chat do chat[#chat + 1] = plain(sim.chat[index].text) end
    return {
        name = profile.name, race = profile.race, class = profile.class, level = profile.level, money = profile.money,
        position = position, questLog = log, completedQuests = completedCount, target = target,
        inCombat = sim.inCombat == true, now = math.floor((sim.now or 0) * 100 + 0.5) / 100,
        screen = { width = sim.screenWidth, height = sim.screenHeight }, errors = #sim.errors, lastChat = chat,
    }
end

return sdkui
