-- SimFixture: the simulator's own test addon, so its scenarios try the simulator with an addon of their own rather
-- than a real one. It does what addons commonly do, plainly:
--   a movable window (/simfixture) listing the quest log in scrolling rows that answer the mouse (tooltip, click)
--   marks on the minimap (children of Minimap with .mark set), with tooltips
--   saved variables (SimFixtureDB: how many logins), events counted (the addon's private table: .events)
local addonName, ns = ...

local ROW_COUNT, ROW_HEIGHT = 14, 20
local MARK_OFFSETS = { { -30, 20 }, { 25, 30 }, { 10, -35 }, { -20, -15 }, { 35, -5 } }

ns.events = {}
local eventFrame = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "PLAYER_LOGOUT" }) do
    eventFrame:RegisterEvent(event)
end

-- The window: a title, a scrolling list of rows, a close button
local window = CreateFrame("Frame", "SimFixtureWindow", UIParent)
ns.window = window
window:SetSize(320, ROW_COUNT * ROW_HEIGHT + 60)
window:SetPoint("RIGHT", UIParent, "RIGHT", -120, 0)
window:SetFrameStrata("HIGH")
window:SetMovable(true)
window:EnableMouse(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", window.StopMovingOrSizing)
window:Hide()
local background = window:CreateTexture(nil, "BACKGROUND")
background:SetAllPoints()
background:SetColorTexture(0.05, 0.05, 0.08, 0.92)
local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -12)
title:SetText("SimFixture")
window.title = title

local close = CreateFrame("Button", nil, window)
close:SetSize(24, 24)
close:SetPoint("TOPRIGHT", -6, -6)
local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
closeText:SetPoint("CENTER")
closeText:SetText("X")
close:SetScript("OnClick", function()
    window:Hide()
end)
window.close = close

-- The lines listed: the quest log's titles, then lines of filler, so the list always scrolls
local lines, offset, selected = {}, 0, nil
local function collectLines()
    wipe(lines)
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader then
            lines[#lines + 1] = info.title
        end
    end
    for index = 1, 30 do
        lines[#lines + 1] = "Line " .. index
    end
end

local rows = {}
local function refresh()
    offset = math.max(0, math.min(offset, #lines - ROW_COUNT))
    for index, row in ipairs(rows) do
        local text = lines[offset + index]
        row.text:SetText(text or "")
        row.highlight:SetShown(text ~= nil and text == selected)
        row:SetShown(text ~= nil)
    end
end
ns.refresh = refresh

for index = 1, ROW_COUNT do
    local row = CreateFrame("Button", nil, window)
    row:SetSize(290, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 15, -40 - (index - 1) * ROW_HEIGHT)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(0.3, 0.5, 0.9, 0.35)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.text:GetText() or "")
        GameTooltip:AddLine("Row " .. index, 1, 1, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        selected = self.text:GetText()
        refresh()
    end)
    rows[index] = row
end
ns.rows = rows
window:EnableMouseWheel(true)
window:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    refresh()
end)
window:SetScript("OnShow", function()
    collectLines()
    refresh()
end)

-- Marks on the minimap, round its middle
ns.marks = {}
local function placeMarks()
    if not Minimap or #ns.marks > 0 then
        return
    end
    for index, offsetXY in ipairs(MARK_OFFSETS) do
        local mark = CreateFrame("Frame", nil, Minimap)
        mark:SetSize(12, 12)
        mark:SetPoint("CENTER", Minimap, "CENTER", offsetXY[1], offsetXY[2])
        mark:SetFrameLevel(Minimap:GetFrameLevel() + 5)
        local texture = mark:CreateTexture(nil, "OVERLAY")
        texture:SetAllPoints()
        texture:SetTexture("Interface\\AddOns\\SimFixture\\Media\\Plus") -- (the addon's own art: Media\Plus.tga)
        mark.mark = true
        mark:EnableMouse(true)
        mark:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("SimFixture mark " .. index)
            GameTooltip:Show()
        end)
        mark:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        ns.marks[index] = mark
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    ns.events[event] = (ns.events[event] or 0) + 1
    if event == "ADDON_LOADED" and ... == addonName then
        SimFixtureDB = SimFixtureDB or {}
        SimFixtureDB.logins = (SimFixtureDB.logins or 0) + 1
    elseif event == "PLAYER_LOGIN" then
        placeMarks()
    elseif event == "QUEST_LOG_UPDATE" and window:IsShown() then
        collectLines()
        refresh()
    end
end)

SLASH_SIMFIXTURE1 = "/simfixture"
SlashCmdList.SIMFIXTURE = function(text)
    if text == "marks" then
        print(string.format("SimFixture: %d marks", #ns.marks))
    else
        window:SetShown(not window:IsShown())
    end
end
