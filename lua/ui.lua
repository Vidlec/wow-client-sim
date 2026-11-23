-- The default interface's own frames, as far as addons lean on them: the screen (UIParent), tooltips, chat,
-- error text, popups, menus, the settings window, the minimap and the world map with its canvas and tiles.
local sim = require("sim")
local W = require("widgets")
local game = require("game")

local ui = {}
local G = sim.G
local S = W.state

local function createFrame(...) return W.createFrame(...) end

-- Tooltips: lines of font strings, sized to fit, placed by their owner
local tooltipMethods = {}
-- The padding round the tooltip's lines (SetPadding) back to none
tooltipMethods.ClearPadding = function(self)
    if self.SetPadding then self:SetPadding(0, 0, 0, 0) end
end
local function getTooltipLine(tooltip, index, side)
    local s = S[tooltip]
    s.lines = s.lines or {}
    local line = s.lines[index]
    if not line then
        local name = s.name or "Tooltip"
        line = {
            left = tooltip:CreateFontString(name .. "TextLeft" .. index, "ARTWORK", index == 1 and "GameTooltipHeaderText" or "GameTooltipText"),
            right = tooltip:CreateFontString(name .. "TextRight" .. index, "ARTWORK", index == 1 and "GameTooltipHeaderText" or "GameTooltipText"),
        }
        S[line.left].justifyH, S[line.right].justifyH = "LEFT", "RIGHT"
        s.lines[index] = line
    end
    return line
end
function tooltipMethods:SetOwner(owner, anchor, x, y)
    local s = S[self]
    s.owner, s.anchor, s.anchorX, s.anchorY = owner, anchor or "ANCHOR_RIGHT", x or 0, y or 0
    self:ClearLines()
end
function tooltipMethods:GetOwner() return S[self].owner end
function tooltipMethods:IsOwned(frame) return S[self].owner == frame end
function tooltipMethods:SetAnchorType(anchor, x, y) local s = S[self]; s.anchor, s.anchorX, s.anchorY = anchor, x or 0, y or 0 end
function tooltipMethods:GetAnchorType() return S[self].anchor end
function tooltipMethods:ClearLines()
    local s = S[self]
    for _, line in ipairs(s.lines or {}) do
        line.left:SetText(nil); line.left:Hide()
        line.right:SetText(nil); line.right:Hide()
    end
    s.lineCount = 0
    s.itemId = nil
    sim.runScript(self, "OnTooltipCleared")
    sim.touch()
end
function tooltipMethods:AddLine(text, r, g, b, isWrapped)
    local s = S[self]
    s.lineCount = (s.lineCount or 0) + 1
    local line = getTooltipLine(self, s.lineCount)
    line.left:SetText(text or " ")
    line.left:SetTextColor(r or 1, g or 0.82, b or 0, 1)
    if s.lineCount > 1 and r == nil then line.left:SetTextColor(1, 1, 1, 1) end
    S[line.left].tooltipWrap = isWrapped
    line.left:Show()
    line.right:Hide()
    sim.touch()
end
function tooltipMethods:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
    local s = S[self]
    s.lineCount = (s.lineCount or 0) + 1
    local line = getTooltipLine(self, s.lineCount)
    line.left:SetText(left or " "); line.left:SetTextColor(lr or 1, lg or 1, lb or 1); line.left:Show()
    line.right:SetText(right or " "); line.right:SetTextColor(rr or 1, rg or 1, rb or 1); line.right:Show()
    sim.touch()
end
function tooltipMethods:SetText(text, r, g, b, a, isWrapped)
    self:ClearLines()
    self:AddLine(text, r or 1, g or 1, b or 1, isWrapped)
    self:Show()
end
function tooltipMethods:AppendText(text)
    local s = S[self]
    local line = s.lines and s.lines[s.lineCount or 1]
    if line then line.left:SetText((line.left:GetText() or "") .. text) end
end
function tooltipMethods:NumLines() return S[self].lineCount or 0 end
function tooltipMethods:SetMinimumWidth(width) S[self].minimumWidth = width end
function tooltipMethods:SetPadding() end
function tooltipMethods:AddTexture() end
function tooltipMethods:AddSpellByID() end
function tooltipMethods:SetHyperlink(link)
    local itemId = tostring(link):match("item:(%d+)")
    if itemId then return self:SetItemByID(tonumber(itemId)) end
    self:AddLine(tostring(link))
end
function tooltipMethods:SetItemByID(itemId)
    local name = G.C_Item.GetItemInfo(itemId) -- the modern one: this client has no global GetItemInfo
    self:AddLine(name or ("Item " .. tostring(itemId)), 1, 1, 1)
    S[self].itemId = itemId
    -- Then every post-call addons registered for item tooltip data, as the game runs them (a bag slot, a link, an id)
    local data = { type = G.Enum and G.Enum.TooltipDataType and G.Enum.TooltipDataType.Item or 0, id = itemId, lines = {} }
    for _, handler in ipairs(ui.tooltipPostCalls[data.type] or {}) do sim.call(handler, self, data) end
    for _, handler in ipairs(ui.tooltipPostCalls.ALL or {}) do sim.call(handler, self, data) end
    sim.runScript(self, "OnTooltipSetItem")
end
function tooltipMethods:SetSpellByID(spellId) self:AddLine("Spell " .. tostring(spellId), 1, 1, 1) end
function tooltipMethods:SetQuestLogItem(kind, index, questId) self:AddLine("Quest reward", 1, 1, 1) end
function tooltipMethods:SetQuestItem() self:AddLine("Quest item", 1, 1, 1) end
function tooltipMethods:SetUnit(unit) self:AddLine(G.UnitName(unit) or unit, 1, 1, 1) end
function tooltipMethods:SetBagItem() end
function tooltipMethods:SetInventoryItem() end
function tooltipMethods:GetItem()
    local itemId = S[self].itemId
    if not itemId then return nil end
    local name = G.C_Item.GetItemInfo(itemId)
    return name, string.format("|cffffffff|Hitem:%d::::::::::::|h[%s]|h|r", itemId, name or ("Item " .. itemId))
end
function tooltipMethods:GetSpell() return nil end
function tooltipMethods:GetUnit() return nil end
function tooltipMethods:FadeOut() self:Hide() end
function tooltipMethods:IsTooltipType() return false end
function tooltipMethods:GetTooltipData() return nil end
function tooltipMethods:SetCustomLineSpacing(spacing) S[self].customLineSpacing = spacing end
function tooltipMethods:GetCustomLineSpacing() return S[self].customLineSpacing end
function tooltipMethods:SetTooltipData() end
-- The rest of the client's tooltip methods (api-report.txt listed them as missing): kept as set, drawn as plain lines
-- (an atlas line as AddTexture is: not drawn). Whether an empty tooltip shows (SetAllowShowWithNoLines) is not
-- measured yet: the recorder's "tooltips" probe asks; Show here shows it either way, as it did.
function tooltipMethods:AddAtlas() end
function tooltipMethods:SetAllowShowWithNoLines(isAllowed) S[self].allowShowWithNoLines = isAllowed and true or false end
function tooltipMethods:SetCustomWordWrapMinWidth(width) S[self].customWordWrapMinWidth = width end
function tooltipMethods:SetShrinkToFitWrapped(isShrinking) S[self].shrinkToFitWrapped = isShrinking and true or false end
function tooltipMethods:SetObjectTooltipPosition() end
function tooltipMethods:SetFrameStack() end
---Another tooltip's lines, owner and anchor, as the game's CopyTooltip
function tooltipMethods:CopyTooltip(source)
    local from = source and S[source]
    if not from then return end
    local s = S[self]
    s.owner, s.anchor, s.anchorX, s.anchorY = from.owner, from.anchor, from.anchorX, from.anchorY
    self:ClearLines()
    for index = 1, from.lineCount or 0 do
        local line = from.lines[index]
        local left, right = line.left:GetText(), line.right:IsShown() and line.right:GetText() or nil
        local lr, lg, lb = line.left:GetTextColor()
        if right then
            local rr, rg, rb = line.right:GetTextColor()
            self:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
        else
            self:AddLine(left, lr, lg, lb, S[line.left].tooltipWrap)
        end
    end
end

---Lays out a tooltip's lines and places it by its owner, as Show does in the game.
function ui.layoutTooltip(tooltip)
    local s = S[tooltip]
    local lineCount = s.lineCount or 0
    local width, y = s.minimumWidth or 0, -10
    local rows = {}
    -- As the game: lines that do not wrap widen the tooltip to fit; lines that wrap take the width there is, or
    -- wrap at about 300 when nothing else is wider
    local WRAP_WIDTH = 300
    for index = 1, lineCount do
        local line = s.lines[index]
        local leftWidth = line.left:GetUnboundedStringWidth()
        local rightWidth = line.right:IsShown() and (line.right:GetUnboundedStringWidth() + 20) or 0
        rows[index] = { leftWidth = leftWidth, rightWidth = rightWidth }
        if S[line.left].tooltipWrap then
            width = math.max(width, math.min(leftWidth + rightWidth, WRAP_WIDTH))
        else
            width = math.max(width, leftWidth + rightWidth)
        end
    end
    for index = 1, lineCount do
        local line = s.lines[index]
        line.left:ClearAllPoints()
        line.left:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 10, y)
        if rows[index].leftWidth > width and S[line.left].tooltipWrap then
            line.left:SetWidth(width)
        else
            S[line.left].width = nil
        end
        line.right:ClearAllPoints()
        line.right:SetPoint("TOPRIGHT", tooltip, "TOPRIGHT", -10, y)
        y = y - line.left:GetStringHeight() - 2
    end
    S[tooltip].width, S[tooltip].height = width + 20, -y + 8
    local owner, anchor = s.owner, s.anchor or "ANCHOR_RIGHT"
    if owner and anchor ~= "ANCHOR_NONE" and anchor ~= "ANCHOR_PRESERVE" then
        S[tooltip].points = {}
        local x, offsetY = s.anchorX or 0, s.anchorY or 0
        if anchor == "ANCHOR_RIGHT" then tooltip:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", x, offsetY)
        elseif anchor == "ANCHOR_LEFT" then tooltip:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", x, offsetY)
        elseif anchor == "ANCHOR_TOP" then tooltip:SetPoint("BOTTOM", owner, "TOP", x, offsetY)
        elseif anchor == "ANCHOR_BOTTOM" then tooltip:SetPoint("TOP", owner, "BOTTOM", x, offsetY)
        elseif anchor == "ANCHOR_TOPLEFT" then tooltip:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", x, offsetY)
        elseif anchor == "ANCHOR_TOPRIGHT" then tooltip:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", x, offsetY)
        elseif anchor == "ANCHOR_BOTTOMLEFT" then tooltip:SetPoint("TOPRIGHT", owner, "BOTTOMLEFT", x, offsetY)
        elseif anchor == "ANCHOR_BOTTOMRIGHT" then tooltip:SetPoint("TOPLEFT", owner, "BOTTOMRIGHT", x, offsetY)
        else
            local mouse = sim.mouse or { x = 0, y = 0 }
            tooltip:SetPoint("BOTTOMLEFT", G.UIParent, "BOTTOMLEFT", mouse.x + 16, mouse.y + 16)
        end
    end
    sim.touch()
end

local function createTooltip(name)
    local tooltip = createFrame("GameTooltip", name, G.UIParent, "GameTooltipTemplate")
    tooltip:Hide()
    tooltip:SetSize(100, 30)
    return tooltip
end

-- Menus (MenuUtil): descriptions built by a generator, shown as a simple list
local function newDescription()
    local description = { elements = {} }
    local methods = {}
    local function addElement(kind, text, extra)
        local element = { kind = kind, text = text, enabled = true }
        for key, value in pairs(extra or {}) do element[key] = value end
        local elementMethods = {}
        function elementMethods:SetTooltip(handler) self.tooltip = handler; return self end
        function elementMethods:SetEnabled(isEnabled) self.enabled = isEnabled ~= false; return self end
        function elementMethods:SetResponder(responder) self.responder = responder; return self end
        function elementMethods:SetResponse(response) self.response = response; return self end
        function elementMethods:AddInitializer(initializer) self.initializers = self.initializers or {}; table.insert(self.initializers, initializer); return self end
        function elementMethods:SetData(data) self.data = data; return self end
        function elementMethods:GetData() return self.data end
        function elementMethods:SetIsSelected(handler) self.isSelected = handler; return self end
        function elementMethods:SetSelectionIgnored() return self end
        function elementMethods:SetRadio() return self end
        function elementMethods:SetCanSelect() return self end
        function elementMethods:SetShouldRespondIfSubmenu() return self end
        function elementMethods:SetOnEnter() return self end
        function elementMethods:SetOnLeave() return self end
        function elementMethods:SetTitleAndTextTooltip() return self end
        function elementMethods:CreateButton(...) return methods.CreateButton(self, ...) end
        function elementMethods:CreateRadio(...) return methods.CreateRadio(self, ...) end
        function elementMethods:CreateCheckbox(...) return methods.CreateCheckbox(self, ...) end
        function elementMethods:CreateTitle(...) return methods.CreateTitle(self, ...) end
        function elementMethods:CreateDivider(...) return methods.CreateDivider(self, ...) end
        function elementMethods:CreateSpacer(...) return methods.CreateSpacer(self, ...) end
        setmetatable(element, { __index = elementMethods })
        table.insert(description.elements, element)
        return element
    end
    function methods.CreateButton(_, text, callback, data) return addElement("button", text, { callback = callback, data = data }) end
    function methods.CreateRadio(_, text, isSelected, setSelected, data) return addElement("radio", text, { isSelected = isSelected, setSelected = setSelected, data = data }) end
    function methods.CreateCheckbox(_, text, isSelected, setSelected, data) return addElement("checkbox", text, { isSelected = isSelected, setSelected = setSelected, data = data }) end
    function methods.CreateTitle(_, text) return addElement("title", text) end
    function methods.CreateDivider() return addElement("divider") end
    function methods.CreateSpacer() return addElement("spacer") end
    function methods.CreateTemplate() return addElement("spacer") end
    function methods.SetTag() end
    function methods.SetScrollMode() end
    function methods.SetMinimumWidth() end
    function methods.AddMenuReleasedCallback() end
    function methods.AddMenuAcquiredCallback() end
    function methods.SetGridMode() end
    return setmetatable(description, { __index = methods })
end

local openMenu
local function closeMenu()
    if openMenu then
        openMenu:Hide()
        openMenu = nil
    end
end
ui.closeMenu = closeMenu

local function showMenu(owner, generator, onPicked)
    closeMenu()
    local description = newDescription()
    sim.call(generator, owner, description)
    local menu = createFrame("Frame", nil, G.UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    menu:SetBackdropColor(0.06, 0.06, 0.06, 0.96)
    menu:EnableMouse(true)
    local y, width = -8, 120
    for _, element in ipairs(description.elements) do
        if element.kind == "divider" or element.kind == "spacer" then
            if element.kind == "divider" then
                local line = menu:CreateTexture(nil, "ARTWORK")
                line:SetColorTexture(1, 1, 1, 0.15)
                line:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, y - 5)
                line:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, y - 5)
                line:SetHeight(1)
            end
            y = y - 10
        else
            local button = createFrame("Button", nil, menu)
            button:SetHeight(18)
            button:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, y)
            button:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -6, y)
            local label = button:CreateFontString(nil, "ARTWORK", element.kind == "title" and "GameFontNormalSmall" or "GameFontHighlightSmall")
            label:SetText(element.text)
            label:SetPoint("LEFT", button, "LEFT", (element.kind == "radio" or element.kind == "checkbox") and 18 or 4, 0)
            width = math.max(width, label:GetStringWidth() + 40)
            if element.kind == "radio" or element.kind == "checkbox" then
                local mark = button:CreateTexture(nil, "ARTWORK")
                mark:SetSize(12, 12)
                mark:SetPoint("LEFT", button, "LEFT", 2, 0)
                local isChecked = element.isSelected and select(2, sim.call(element.isSelected, element.data))
                if element.kind == "radio" then
                    mark:SetAtlas(isChecked and "common-dropdown-icon-radialbutton-checked" or "common-dropdown-icon-radialbutton")
                else
                    mark:SetAtlas(isChecked and "common-dropdown-icon-checkmark-yellow" or "common-dropdown-ticksquare")
                end
            end
            if element.kind ~= "title" then
                button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                button:SetScript("OnClick", function()
                    if element.enabled == false then return end
                    if element.kind == "button" and element.callback then
                        sim.call(element.callback, element.data, { buttonName = "LeftButton" })
                    elseif element.setSelected then
                        sim.call(element.setSelected, element.data)
                    end
                    closeMenu()
                    if onPicked then onPicked() end
                end)
            end
            y = y - 18
        end
    end
    menu:SetSize(width, -y + 8)
    if owner and owner ~= G.UIParent then
        menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    else
        local mouse = sim.mouse or { x = 200, y = 400 }
        menu:SetPoint("TOPLEFT", G.UIParent, "BOTTOMLEFT", mouse.x, mouse.y)
    end
    openMenu = menu
    return menu
end
ui.showMenu = showMenu

---A dropdown from WowStyle1DropdownTemplate: SetupMenu stores the generator; the text shows the selected radio.
function sim.installDropdown(dropdown)
    local function refreshText()
        local generator = S[dropdown].menuGenerator
        if not generator or S[dropdown].overrideText then return end
        local description = newDescription()
        sim.call(generator, dropdown, description)
        local function find(elements)
            for _, element in ipairs(elements) do
                if element.kind == "radio" and element.isSelected and select(2, sim.call(element.isSelected, element.data)) then
                    return element.text
                end
            end
        end
        local text = find(description.elements) or S[dropdown].defaultText
        dropdown.Text:SetText(text)
    end
    dropdown.SetupMenu = function(self, generator) S[self].menuGenerator = generator; refreshText() end
    dropdown.GenerateMenu = function() refreshText() end
    dropdown.SetDefaultText = function(self, text) S[self].defaultText = text; refreshText() end
    dropdown.OverrideText = function(self, text) S[self].overrideText = text; self.Text:SetText(text) end
    dropdown.SetSelectionText = function() end
    dropdown.SetSelectionTranslator = function() end
    dropdown.CloseMenu = closeMenu
    dropdown.IsMenuOpen = function() return openMenu ~= nil end
    dropdown.OpenMenu = function(self) showMenu(self, S[self].menuGenerator, refreshText) end
    dropdown.SetEnabled = function(self, isEnabled) S[self].enabled = isEnabled and true or false end
    dropdown:SetScript("OnClick", function(self)
        if openMenu then closeMenu() else self:OpenMenu() end
    end)
end

function ui.install()
    -- The screen
    local root = createFrame("Frame", "UIParent", nil)
    S[root].isRoot = true
    S[root].strata = "MEDIUM"
    root:SetSize(sim.screenWidth, sim.screenHeight)
    -- A screen of a given size and UI scale, as the game lays out its interface: always 768 units tall at scale
    -- 1, as wide as the shape of the screen; the interface is scaled by the UI scale when it is switched on, and
    -- otherwise drawn pixel for pixel (768 / the screen's height)
    function sim.setScreen(physicalWidth, physicalHeight, uiScale)
        sim.physicalWidth, sim.physicalHeight = physicalWidth, physicalHeight
        sim.screenWidth, sim.screenHeight = math.floor(768 * physicalWidth / physicalHeight + 0.5), 768
        local scale = uiScale or (768 / physicalHeight)
        G.SetCVar("useUiScale", uiScale and "1" or "0")
        if uiScale then G.SetCVar("uiScale", tostring(uiScale)) end
        S[root].scale = scale
        root:SetSize(sim.screenWidth / scale, sim.screenHeight / scale)
        sim.touch()
        sim.fireEvent("DISPLAY_SIZE_CHANGED")
        sim.fireEvent("UI_SCALE_CHANGED")
    end
    G.WorldFrame = createFrame("Frame", "WorldFrame", nil)
    S[G.WorldFrame].isRoot = true
    G.UIParent = root

    -- Tooltips: a frame type of their own, whose Show lays the lines out first
    -- A unit's tooltip, as the game's: its name (red for a creature that can be attacked) and level, then every
    -- post-call addons registered for unit tooltip data (TooltipDataProcessor), with the unit's GUID
    tooltipMethods.SetUnit = function(self, unit)
        self:ClearLines()
        local name = G.UnitName and G.UnitName(unit)
        if not name then return end
        S[self].unit = unit
        local isEnemy = G.UnitCanAttack and G.UnitCanAttack("player", unit)
        self:AddLine(name, isEnemy and 1 or 1, isEnemy and 0.1 or 1, isEnemy and 0.1 or 1)
        local level = G.UnitLevel and G.UnitLevel(unit)
        if level and level > 0 then self:AddLine("Level " .. level, 1, 1, 1) end
        local data = { type = G.Enum and G.Enum.TooltipDataType and G.Enum.TooltipDataType.Unit or 2, guid = G.UnitGUID and G.UnitGUID(unit), lines = {} }
        for _, handler in ipairs(ui.tooltipPostCalls[data.type] or {}) do sim.call(handler, self, data) end
        for _, handler in ipairs(ui.tooltipPostCalls.ALL or {}) do sim.call(handler, self, data) end
        if S[self].scripts.OnTooltipSetUnit then sim.runScript(self, "OnTooltipSetUnit") end
        self:Show()
    end
    tooltipMethods.GetUnit = function(self)
        local unit = S[self].unit
        if not unit then return nil end
        return G.UnitName and G.UnitName(unit), unit
    end
    local regionShow = W.types.Region.methods.Show
    -- As the game's: a tooltip shows only with an owner (SetOwner), and hiding it lets go of the owner, so
    -- one hidden and shown again without SetOwner stays hidden
    local regionHide = W.types.Region.methods.Hide
    tooltipMethods.Show = function(self)
        if not S[self].owner then return end
        ui.layoutTooltip(self)
        regionShow(self)
    end
    tooltipMethods.Hide = function(self)
        S[self].owner = nil
        regionHide(self)
    end
    W.defineType("GameTooltip", "Frame", tooltipMethods)
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2", "EmbeddedItemTooltip" }) do
        createTooltip(name)
    end

    -- Chat and messages
    local chat = createFrame("ScrollingMessageFrame", "ChatFrame1", root)
    S[chat].isChat = true
    chat:SetSize(430, 120)
    chat:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 32, 95)
    G.DEFAULT_CHAT_FRAME, G.SELECTED_CHAT_FRAME = chat, chat
    G.NUM_CHAT_WINDOWS = 1
    G.ChatFrame_AddMessageEventFilter = function() end
    G.ChatFrame_RemoveMessageEventFilter = function() end
    -- The chat's edit box, as the game's: opened with Enter or ChatFrame_OpenChat, links put into it while it is
    -- open (ChatEdit_InsertLink, a shift-click's link), Enter sends it (a slash command, or said), Escape closes it
    local chatBox = createFrame("EditBox", "ChatFrame1EditBox", root)
    chatBox:SetSize(430, 22)
    chatBox:SetPoint("TOPLEFT", chat, "BOTTOMLEFT", 0, -6)
    chatBox:SetFontObject("ChatFontNormal")
    chatBox:SetAutoFocus(false)
    if chatBox.SetBackdrop then
        chatBox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        chatBox:SetBackdropColor(0, 0, 0, 0.7)
        chatBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    chatBox:SetTextInsets(6, 6, 0, 0)
    chatBox:Hide()
    chatBox:SetScript("OnEnterPressed", function(self)
        local text = self:GetText() or ""
        self:SetText("")
        self:ClearFocus()
        self:Hide()
        if text:match("^%s*/") then
            if sim.runSlashCommand then sim.runSlashCommand(text) end
        elseif text:match("%S") then
            G.SendChatMessage(text, "SAY")
        end
    end)
    chatBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); self:Hide() end)
    G.ChatFrame1EditBox = chatBox
    G.ChatFrame_OpenChat = function(text)
        chatBox:Show()
        chatBox:SetText(text or "")
        chatBox:SetFocus()
    end
    G.ChatEdit_GetActiveWindow = function() return chatBox:IsShown() and chatBox or nil end
    G.ChatEdit_InsertLink = function(text)
        if not text or not chatBox:IsShown() then return false end
        chatBox:Insert(text)
        return true
    end
    local errors = createFrame("MessageFrame", "UIErrorsFrame", root)
    errors:SetSize(512, 60)
    errors:SetPoint("TOP", root, "TOP", 0, -122)
    errors:SetFrameStrata("DIALOG")
    G.RaidNotice_AddMessage = function() end
    G.RaidWarningFrame = createFrame("MessageFrame", "RaidWarningFrame", root)

    -- Panels and special frames
    G.UISpecialFrames = {}
    G.UIPanelWindows = {}
    G.ShowUIPanel = function(frame) if frame then frame:Show() end end
    G.HideUIPanel = function(frame) if frame then frame:Hide() end end
    G.SetUIPanelAttribute = function(frame, key, value) frame:SetAttribute("UIPanelLayout-" .. key, value) end
    G.GetUIPanel = function() return nil end
    G.UpdateUIPanelPositions = function() end
    G.CloseSpecialWindows = function()
        local isClosed = false
        for _, name in ipairs(G.UISpecialFrames) do
            local frame = G[name]
            if frame and frame.IsShown and frame:IsShown() then frame:Hide(); isClosed = true end
        end
        return isClosed
    end
    G.CloseAllWindows = G.CloseSpecialWindows
    G.ToggleFrame = function(frame) if frame:IsShown() then frame:Hide() else frame:Show() end end
    G.PanelTemplates_TabResize = function(tab, padding, absoluteSize, minWidth, maxWidth)
        local text = tab.Text or (tab.GetFontString and tab:GetFontString())
        local width = absoluteSize or ((text and text:GetStringWidth() or 40) + 20 + (padding or 0))
        if minWidth then width = math.max(width, minWidth) end
        if maxWidth and maxWidth > 0 then width = math.min(width, maxWidth) end
        tab:SetWidth(width)
    end
    G.PanelTemplates_SelectTab = function(tab)
        local text = tab.Text or (tab.GetFontString and tab:GetFontString())
        if text then text:SetTextColor(1, 1, 1) end
        S[tab].tabSelected = true
        tab:Disable()
    end
    G.PanelTemplates_DeselectTab = function(tab)
        local text = tab.Text or (tab.GetFontString and tab:GetFontString())
        if text then text:SetTextColor(1, 0.82, 0) end
        S[tab].tabSelected = false
        tab:Enable()
    end
    G.PanelTemplates_SetNumTabs = function(frame, count) frame.numTabs = count end
    G.PanelTemplates_SetTab = function(frame, index) frame.selectedTab = index end
    G.PanelTemplates_UpdateTabs = function() end
    G.PanelTemplates_EnableTab = function(_, index) end
    G.PanelTemplates_DisableTab = function(_, index) end
    G.ScrollUtil = { AddManagedScrollBarVisibilityBehavior = function() end, InitScrollBoxListWithScrollBar = function() end,
        RegisterScrollBoxWithScrollBar = function() end, AddResizableChildrenBehavior = function() end }
    G.NineSliceUtil = { ApplyLayout = function(frame) if frame.SetBackdrop then frame:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 }) end end,
        ApplyLayoutByName = function(frame) G.NineSliceUtil.ApplyLayout(frame) end, GetLayout = function() return {} end }
    G.NineSliceLayouts = setmetatable({}, { __index = function() return {} end })
    G.BackdropTemplateMixin = {}
    for key, method in pairs(require("templates").backdropMethods) do G.BackdropTemplateMixin[key] = method end
    G.TOOLTIP_BACKDROP_STYLE_DEFAULT = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 }
    G.BACKDROP_TOOLTIP_16_16_5555 = G.TOOLTIP_BACKDROP_STYLE_DEFAULT

    -- Popups
    G.StaticPopupDialogs = {}
    local popup
    G.StaticPopup_Show = function(which, text1, text2, data)
        local dialog = G.StaticPopupDialogs[which]
        if not dialog then
            if which == "ABANDON_QUEST" then
                dialog = { text = "Abandon \"%s\"?", button1 = "Yes", button2 = "No", OnAccept = function() G.C_QuestLog.AbandonQuest() end }
            else
                return nil
            end
        end
        if not popup then
            popup = createFrame("Frame", "StaticPopup1", root, "BackdropTemplate")
            popup:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
            popup:SetFrameStrata("DIALOG")
            popup:SetSize(320, 110)
            popup:SetPoint("TOP", root, "TOP", 0, -135)
            popup.text = popup:CreateFontString("StaticPopup1Text", "ARTWORK", "GameFontHighlight")
            popup.text:SetPoint("TOP", popup, "TOP", 0, -16)
            popup.text:SetWidth(290)
            popup.button1 = createFrame("Button", "StaticPopup1Button1", popup, "UIPanelButtonTemplate")
            popup.button2 = createFrame("Button", "StaticPopup1Button2", popup, "UIPanelButtonTemplate")
            popup.button1:SetSize(128, 21)
            popup.button2:SetSize(128, 21)
            popup.button1:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -6, 16)
            popup.button2:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 6, 16)
        end
        popup.which, popup.data = which, data
        popup.text:SetText(string.format(dialog.text or "", text1 or "", text2 or ""))
        popup.button1:SetText(dialog.button1 or "Okay")
        popup.button2:SetText(dialog.button2 or "Cancel")
        popup.button2:SetShown(dialog.button2 ~= nil)
        popup.button1:SetScript("OnClick", function() popup:Hide(); if dialog.OnAccept then sim.call(dialog.OnAccept, popup, data) end end)
        popup.button2:SetScript("OnClick", function() popup:Hide(); if dialog.OnCancel then sim.call(dialog.OnCancel, popup, data) end end)
        popup:Show()
        if dialog.OnShow then sim.call(dialog.OnShow, popup, data) end
        return popup
    end
    G.StaticPopup_Hide = function(which) if popup and (not which or popup.which == which) then popup:Hide() end end
    G.StaticPopup_Visible = function(which) return popup and popup:IsShown() and popup.which == which and "StaticPopup1" or nil end

    -- Menus
    G.MenuUtil = {
        CreateContextMenu = function(owner, generator) return showMenu(nil, generator) end,
        CreateButtonMenu = function(owner, ...) end,
        CreateRadioMenu = function() end,
        CreateCheckboxMenu = function() end,
        HideTooltip = function() G.GameTooltip:Hide() end,
        ShowTooltip = function(owner, handler) G.GameTooltip:SetOwner(owner, "ANCHOR_RIGHT"); sim.call(handler, G.GameTooltip); G.GameTooltip:Show() end,
        GetElementText = function(description) return description.text end,
    }
    G.Menu = { GetManager = function() return { HandleESC = function() local wasOpen = openMenu ~= nil; closeMenu(); return wasOpen end } end,
        ModifyMenu = function() end }
    G.MenuResponse = { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }

    -- Settings
    local settingsPanel = createFrame("Frame", "SettingsPanel", root, "BasicFrameTemplateWithInset")
    settingsPanel:SetSize(920, 620)
    settingsPanel:SetPoint("CENTER", root, "CENTER", 0, 20)
    settingsPanel:SetFrameStrata("HIGH")
    settingsPanel.TitleText:SetText("Options")
    settingsPanel:Hide()
    table.insert(G.UISpecialFrames, "SettingsPanel")
    local categories = {}
    G.Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            local category = { ID = name, name = name, frame = frame }
            function category:GetID() return self.ID end
            function category:GetName() return self.name end
            return category
        end,
        RegisterVerticalLayoutCategory = function(name)
            local category = { ID = name, name = name }
            function category:GetID() return self.ID end
            return category
        end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name) return G.Settings.RegisterCanvasLayoutCategory(frame, name) end,
        RegisterAddOnCategory = function(category) categories[category.ID] = category end,
        OpenToCategory = function(id)
            local category = categories[id]
            for _, other in pairs(categories) do if other.frame then other.frame:Hide() end end
            if category and category.frame then
                category.frame:SetParent(settingsPanel)
                category.frame:ClearAllPoints()
                category.frame:SetPoint("TOPLEFT", settingsPanel.Inset, "TOPLEFT", 4, -4)
                category.frame:SetPoint("BOTTOMRIGHT", settingsPanel.Inset, "BOTTOMRIGHT", -4, 4)
                category.frame:Show()
            end
            settingsPanel:Show()
            return true
        end,
        RegisterAddOnSetting = function() return {} end,
        CreateCheckbox = function() end,
        CreateSlider = function() end,
        CreateDropdown = function() end,
        CreateControlTextContainer = function() return { Add = function() end, GetData = function() return {} end } end,
        CreateSliderOptions = function() return { SetLabelFormatter = function() end } end,
        SetValue = function() end,
        GetValue = function() end,
        VarType = { Boolean = "boolean", Number = "number", String = "string" },
    }
    G.InterfaceOptions_AddCategory = function(frame) categories[frame.name or "AddOn"] = { ID = frame.name, frame = frame } end
    G.InterfaceOptionsFrame_OpenToCategory = function(frame) G.Settings.OpenToCategory(type(frame) == "table" and frame.name or frame) end
    G.AddonCompartmentFrame = { RegisterAddon = function() end }

    if sim.isWholeInterface then
        -- The game's own minimap (Blizzard_Minimap) is loaded: the engine's part of it only. The zone's name, as the
        -- engine gives it; Edit Mode and placing it act on the game's own cluster
        G.GetMinimapZoneText = function()
            local map = game.maps[game.profile.uiMapId]
            return game.profile.isInInstance and (game.profile.instanceName or "") or (map and map.name or "")
        end
        function sim.setEditMode(isOn)
            sim.editMode = isOn == true
            sim.fireEvent(sim.editMode and "EDIT_MODE_ENTERED" or "EDIT_MODE_EXITED")
        end
        function sim.placeMinimap(point, x, y)
            local cluster = G.MinimapCluster
            if not cluster then return end
            cluster:ClearAllPoints()
            cluster:SetPoint(point or "TOPRIGHT", root, point or "TOPRIGHT", x or 0, y or 0)
            -- (kept in the layout too, so the game's Edit Mode does not put it back when it applies the layouts)
            if sim.keepEditModePlace and G.Enum and G.Enum.EditModeSystem then
                sim.keepEditModePlace(G.Enum.EditModeSystem.Minimap, point or "TOPRIGHT", point or "TOPRIGHT", x or 0, y or 0)
            end
        end
    else
        -- The minimap, laid out as Forever's (Blizzard_Minimap/Mainline/Minimap.xml): a 256 cluster at the top right,
        -- the zone's name in its header, a 198 map in the 215 x 226 frame ring (UI-HUD-Minimap-Frame)
        local cluster = createFrame("Frame", "MinimapCluster", root)
        cluster:SetSize(256, 256)
        cluster:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
        cluster:SetFrameStrata("LOW")
        local zoneButton = createFrame("Button", nil, cluster)
        zoneButton:SetSize(152, 23)
        zoneButton:SetPoint("TOP", cluster, "TOP", 10, 0)
        local zoneBackground = zoneButton:CreateTexture(nil, "BACKGROUND")
        zoneBackground:SetAtlas("ui-hud-minimap-header-button", true)
        zoneBackground:SetPoint("CENTER", zoneButton, "CENTER")
        local zoneText = zoneButton:CreateFontString("MinimapZoneText", "OVERLAY", "GameFontHighlightSmall")
        zoneText:SetSize(110, 12)
        zoneText:SetPoint("LEFT", zoneButton, "LEFT", 8, -1)
        zoneText:SetJustifyH("LEFT")
        cluster.ZoneTextButton = zoneButton
        local container = createFrame("Frame", nil, cluster)
        container:SetSize(215, 226)
        container:SetPoint("TOP", cluster, "TOP", 10, -30)
        cluster.MinimapContainer = container
        local minimap = createFrame("Minimap", "Minimap", container)
        minimap:SetSize(198, 198)
        minimap:SetPoint("CENTER", container, "CENTER")
        container.Minimap = minimap
        local minimapBackground = minimap:CreateTexture(nil, "BACKGROUND")
        minimapBackground:SetColorTexture(0.05, 0.06, 0.08, 1)
        minimapBackground:SetAllPoints(minimap)
        local backdrop = createFrame("Frame", "MinimapBackdrop", minimap)
        backdrop:SetSize(215, 226)
        backdrop:SetPoint("CENTER", minimap, "CENTER")
        local compass = backdrop:CreateTexture("MinimapCompassTexture", "OVERLAY", nil, 2)
        compass:SetAtlas("UI-HUD-Minimap-Frame")
        compass:SetSize(215, 226)
        compass:SetPoint("CENTER", minimap, "CENTER")
        G.MinimapBorder = compass
        -- The zone's name follows the player
        local function showZone()
            local map = game.maps[game.profile.uiMapId]
            zoneText:SetText(game.profile.isInInstance and (game.profile.instanceName or "") or (map and map.name or ""))
        end
        local zoneWatcher = createFrame("Frame", nil, cluster)
        for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_INDOORS" }) do zoneWatcher:RegisterEvent(event) end
        zoneWatcher:SetScript("OnEvent", showZone)
        G.GetMinimapZoneText = function() return zoneText:GetText() or "" end
        -- Edit Mode, as far as the minimap goes: it is outlined in the game's Edit Mode blue and can be dragged
        local editOverlay = createFrame("Frame", nil, cluster)
        editOverlay:SetAllPoints(cluster)
        editOverlay:SetFrameStrata("DIALOG")
        local editFill = editOverlay:CreateTexture(nil, "BACKGROUND")
        editFill:SetAllPoints(editOverlay)
        editFill:SetColorTexture(0.25, 0.55, 1, 0.22)
        local editLabel = editOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        editLabel:SetPoint("BOTTOM", editOverlay, "BOTTOM", 0, 6)
        editLabel:SetText("Minimap: drag to move")
        editOverlay:Hide()
        function sim.setEditMode(isOn)
            sim.editMode = isOn == true
            editOverlay:SetShown(sim.editMode)
            sim.fireEvent(sim.editMode and "EDIT_MODE_ENTERED" or "EDIT_MODE_EXITED")
        end
        ---Places the minimap: a point of the screen and an offset from it, as Edit Mode keeps it.
        function sim.placeMinimap(point, x, y)
            cluster:ClearAllPoints()
            cluster:SetPoint(point or "TOPRIGHT", root, point or "TOPRIGHT", x or 0, y or 0)
        end

    end
    -- Frames addons hide or hook: stand-ins, unless the game's own interface is loaded, which makes the real ones
    -- (a stand-in left in their place lacks their methods: the panel manager calls ObjectiveTrackerFrame:UpdateHeight)
    if sim.isWholeInterface then return end
    G.ObjectiveTrackerFrame = createFrame("Frame", "ObjectiveTrackerFrame", root)
    G.ObjectiveTrackerFrame:SetSize(235, 400)
    G.ObjectiveTrackerFrame:SetPoint("TOPRIGHT", root, "TOPRIGHT", -80, -210)
    G.QuestWatchFrame = G.ObjectiveTrackerFrame
    -- The objective tracker's profession section, which addons such as Auctionator hang their frames on: a
    -- stand-in with its header (the simulator does not run the game's objective tracker)
    G.ProfessionsRecipeTracker = createFrame("Frame", "ProfessionsRecipeTracker", G.ObjectiveTrackerFrame)
    G.ProfessionsRecipeTracker.Header = createFrame("Frame", nil, G.ProfessionsRecipeTracker)
    G.ProfessionsRecipeTracker:Hide()
    G.QuestLogFrame = createFrame("Frame", "QuestLogFrame", root)
    G.QuestLogFrame:Hide()
    G.QuestFrame = createFrame("Frame", "QuestFrame", root)
    G.QuestFrame:Hide()
    G.GossipFrame = createFrame("Frame", "GossipFrame", root)
    G.GossipFrame:Hide()
    G.GameMenuFrame = createFrame("Frame", "GameMenuFrame", root)
    G.GameMenuFrame:Hide()
    G.CharacterFrame = createFrame("Frame", "CharacterFrame", root)
    G.CharacterFrame:Hide()

    -- The game's own world map (Blizzard_WorldMap) when asked for; the simulator's stand-in otherwise
    -- The world map is made after the game's interface files are read (boot.lua), so it can use their templates
end

---The frame level the game's world map gives group member pins: its own level manager
---(MapCanvas_PinFrameLevelsManager) fed the list of pin levels from Blizzard_WorldMap.lua, as the game builds it.
function ui.getGroupMemberPinLevel()
    if ui.groupMemberPinLevel then return ui.groupMemberPinLevel end
    local level = 2765 -- what the game's code gives with 20 quests in the log, should its files be missing
    local root = sim.config and sim.config.interfaceRoot
    local managerChunk = root and loadfile(root .. "/AddOns/Blizzard_MapCanvas/MapCanvas_PinFrameLevelsManager.lua")
    local worldMapFile = root and io.open(root .. "/AddOns/Blizzard_WorldMap/Blizzard_WorldMap.lua")
    if managerChunk and worldMapFile then
        local holder = {}
        setfenv(managerChunk, setmetatable(holder, { __index = _G }))
        managerChunk()
        local manager = setmetatable({}, { __index = holder.MapCanvasPinFrameLevelsManagerMixin })
        manager:Initialize()
        local maxQuests = G.C_QuestLog.GetMaxNumQuests and G.C_QuestLog.GetMaxNumQuests() or 20
        for line in worldMapFile:lines() do
            local name, range = line:match('AddFrameLevel%("([%w_]+)"%s*,?%s*([^)]*)%)')
            if name then
                if range == "" then range = nil
                elseif range:find("GetMaxNumQuests") then range = maxQuests
                elseif range:find("PIN_LEVEL_RANGE") then range = 7 -- the quest offer icons' levels (QuestOfferDataProvider)
                else range = tonumber(range) end
                manager:AddFrameLevel(name, range)
            end
        end
        worldMapFile:close()
        level = manager:GetFrameLevelStart("PIN_FRAME_LEVEL_GROUP_MEMBER") or level
        ui.pinFrameLevelsManager = manager
    elseif worldMapFile then
        worldMapFile:close()
    end
    ui.groupMemberPinLevel = level
    return level
end

ui.tooltipPostCalls = {}
---Records tooltip data post-calls as addons register them with the game's TooltipDataProcessor, so the
---simulator's tooltips run them as the game's do (the game runs them from its tooltip data handler).
function ui.installTooltipData()
    local processor = G.TooltipDataProcessor
    if type(processor) ~= "table" or not processor.AddTooltipPostCall then
        processor = { AllTypes = "ALL" }
        G.TooltipDataProcessor = processor
    end
    local register = processor.AddTooltipPostCall
    processor.AddTooltipPostCall = function(tooltipType, handler)
        ui.tooltipPostCalls[tooltipType] = ui.tooltipPostCalls[tooltipType] or {}
        table.insert(ui.tooltipPostCalls[tooltipType], handler)
        if register then return register(tooltipType, handler) end
    end
end

-- The world map: a window with a canvas the size of the map's art, its tiles drawn from the game's files
function ui.installWorldMap(root)
    -- The game's windowed map: 702 x 534 at the interface's scale, a 67-high title strip with the breadcrumb bar,
    -- the map art below it (Blizzard_WorldMap.lua: minimizedWidth/Height, TITLE_CANVAS_SPACER_FRAME_HEIGHT)
    local map = createFrame("Frame", "WorldMapFrame", root)
    map:SetSize(702, 534)
    map:SetPoint("TOPLEFT", root, "TOPLEFT", 16, -30) -- until the game's panel manager places it
    map:SetFrameStrata("HIGH")
    map:SetToplevel(true)
    map:EnableMouse(true)
    map:Hide()
    table.insert(G.UISpecialFrames, "WorldMapFrame")
    local hasGameChrome = W.getTemplate and W.getTemplate("PortraitFrameTemplateMinimizable")
    local border, title
    if hasGameChrome then
        -- Its frame, from the game's own template, set up as WorldMapMixin:SetupTitle does
        border = createFrame("Frame", nil, map, "PortraitFrameTemplateMinimizable")
        border:SetFrameStrata("HIGH")
        border:SetAllPoints(map)
        border.onCloseCallback = function() G.HideUIPanel(map) end
        border:SetTitle(G.MAP_AND_QUEST_LOG)
        if border.Bg then border.Bg:SetParent(map) end
        if border.TopTileStreaks then border.TopTileStreaks:Hide() end
        border:SetPortraitToAsset([[Interface\QuestFrame\UI-QuestLog-BookIcon]])
        if W.getTemplate("MaximizeMinimizeButtonFrameTemplate") then
            local sizeButtons = createFrame("Frame", nil, border, "MaximizeMinimizeButtonFrameTemplate")
            sizeButtons:SetPoint("RIGHT", border.CloseButton, "LEFT", -1, 0)
            border.MaximizeMinimizeFrame = sizeButtons
        end
        title = border:GetTitleText()
    else
        border = createFrame("Frame", nil, map, "BackdropTemplate")
        border:SetAllPoints(map)
        border:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
        title = border:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", border, "TOP", 0, -10)
        local close = createFrame("Button", nil, border, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", border, "TOPRIGHT", -2, -2)
        close:SetScript("OnClick", function() G.HideUIPanel(map) end)
        border.CloseButton = close
    end
    map.BorderFrame = border
    map.TitleText = title
    local spacer = createFrame("Frame", nil, map)
    spacer:SetPoint("TOPLEFT", map, "TOPLEFT", 2, 0)
    spacer:SetPoint("BOTTOMRIGHT", map, "TOPRIGHT", -3, -67)
    map.TitleCanvasSpacerFrame = spacer
    local container = createFrame("ScrollFrame", nil, map)
    container:SetPoint("TOPLEFT", spacer, "BOTTOMLEFT", 0, 0)
    container:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", 0, 2)
    container:SetPoint("RIGHT", spacer, "RIGHT")
    container:SetClipsChildren(true)
    container:EnableMouse(true)
    local canvas = createFrame("Frame", nil, container)
    canvas:SetSize(1002, 668)
    -- Zoomed out, the art fills the container's width, as the game's canvas scale does
    canvas:SetScale(697 / 1002)
    container:SetScrollChild(canvas)
    container.Child = canvas
    map.ScrollContainer = container
    S[canvas].isMapCanvas = true
    local tiles = {}
    local function drawTiles(uiMapId)
        for _, tile in ipairs(tiles) do tile:Hide() end
        local art = ui.mapArt and ui.mapArt[uiMapId]
        if not art then return end
        for index, tile in ipairs(art.tiles) do
            local texture = tiles[index]
            if not texture then
                texture = canvas:CreateTexture(nil, "BACKGROUND", nil, -8)
                tiles[index] = texture
            end
            texture:SetTexture(tile.fileId)
            texture:SetSize(art.tileWidth * art.scale, art.tileHeight * art.scale)
            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", canvas, "TOPLEFT", tile.column * art.tileWidth * art.scale, -tile.row * art.tileHeight * art.scale)
            texture:Show()
        end
    end
    map.QuestLog = createFrame("Frame", "QuestMapFrame", map)
    map.QuestLog:Hide()
    map.SidePanelToggle = createFrame("Button", nil, map)
    map.SidePanelToggle:Hide()
    map.SidePanelToggle.Refresh = function() end
    local mapId = game.profile.uiMapId
    local providers, pins = {}, {}
    map.GetMapID = function() return mapId end
    map.SetMapID = function(self, newMapId)
        if not newMapId or newMapId == mapId and S[self].mapSet then return end
        mapId, S[self].mapSet = newMapId, true
        local info = G.C_Map.GetMapInfo(mapId)
        -- The game's map keeps its title ("Map & Quest Log"); the stand-in frame names the map
        if not hasGameChrome then title:SetText(info and info.name or ("Map " .. tostring(mapId))) end
        drawTiles(mapId)
        -- A new map starts zoomed out, its zoom levels its own
        if container.resetView then container.resetView() end
        self:OnMapChanged()
    end
    map.OnMapChanged = function(self)
        if self.NavBar and self.NavBar.Refresh then sim.call(self.NavBar.Refresh, self.NavBar) end
        for provider in pairs(providers) do
            if provider.OnMapChanged then sim.call(provider.OnMapChanged, provider) end
            if provider.RefreshAllData then sim.call(provider.RefreshAllData, provider, true) end
        end
        if self.callbacks then for _, callback in ipairs(self.callbacks) do sim.call(callback, self, mapId) end end
    end
    map.RegisterCallback = function(self, event, callback, owner)
        self.callbacks = self.callbacks or {}
        table.insert(self.callbacks, function(...) callback(owner, ...) end)
    end
    map.UnregisterCallback = function() end
    -- The map's pin level manager, as the game's world map builds it (see ui.getGroupMemberPinLevel)
    map.GetPinFrameLevelsManager = function()
        ui.getGroupMemberPinLevel()
        return ui.pinFrameLevelsManager or { GetFrameLevelStart = function(_, levelType)
            return levelType == "PIN_FRAME_LEVEL_GROUP_MEMBER" and ui.groupMemberPinLevel or 2000
        end, GetValidFrameLevel = function() return 2000 end }
    end
    map.GetCanvas = function() return canvas end
    map.GetCanvasContainer = function() return container end

    -- Zoom and pan, as the game's MapCanvasScrollControllerMixin: zoom levels from the map's art layer (from
    -- minScale to maxScale, with its additional steps) times the scale that fits the art in the window; the
    -- wheel steps a level toward the point under the cursor; the left button drags the map; a new map starts
    -- zoomed out. scrollX, scrollY: the canvas point (0 to 1) at the middle of the view.
    local zoomLevels, zoomIndex, scrollX, scrollY = {}, 1, 0.5, 0.5
    -- The scale on show, which glides to the zoom level's (zoomIndex) when the map does not zoom instantly. The game's
    -- world map does (Blizzard_WorldMap.lua's OnLoad: SetShouldZoomInstantly(true)); a map that does not, eases there
    -- frame by frame as the game's MapCanvasScrollControllerMixin:OnUpdate does (FrameDeltaLerp by .15 of a 60 fps
    -- frame, snapped within .0001), telling the map (OnCanvasScaleChanged) at each step
    local currentScale, isZoomInstant = nil, true
    local function createZoomLevels()
        local layer = G.C_Map.GetMapArtLayers(mapId)[1]
        local width, height = container:GetWidth(), container:GetHeight()
        if not width or width <= 0 then width, height = 697, 465 end
        local baseScale = math.min(width / layer.layerWidth, height / layer.layerHeight)
        zoomLevels = {}
        local currentScale = 0
        local delta = layer.maxScale - layer.minScale
        local count = delta > 0 and 2 + (layer.additionalZoomSteps or 0) or 1
        local perStep = delta > 0 and delta / (count - 1) or 1
        for index = 0, count - 1 do
            currentScale = math.max(layer.minScale + perStep * index, currentScale + 0.01)
            zoomLevels[#zoomLevels + 1] = currentScale * baseScale
        end
    end
    local function applyView()
        local scale = currentScale or zoomLevels[zoomIndex] or 697 / 1002
        canvas:SetScale(scale)
        -- The view in canvas units, kept on the canvas (centred where the canvas is smaller than the view)
        local viewWidth, viewHeight = (container:GetWidth() or 697) / scale, (container:GetHeight() or 465) / scale
        local canvasWidth, canvasHeight = canvas:GetWidth(), canvas:GetHeight()
        local function clampScroll(center, view, size)
            if view >= size then return (size - view) / 2 end
            return math.max(0, math.min(size - view, center * size - view / 2))
        end
        local horizontal, vertical = clampScroll(scrollX, viewWidth, canvasWidth), clampScroll(scrollY, viewHeight, canvasHeight)
        scrollX, scrollY = (horizontal + viewWidth / 2) / canvasWidth, (vertical + viewHeight / 2) / canvasHeight
        S[container].horizontalScroll, S[container].verticalScroll = horizontal, vertical
        sim.touch()
    end
    local function setZoom(index, centerX, centerY)
        index = math.max(1, math.min(#zoomLevels, index))
        local isChanged = index ~= zoomIndex
        zoomIndex = index
        if centerX then scrollX, scrollY = centerX, centerY end
        if zoomIndex == 1 then scrollX, scrollY = 0.5, 0.5 end
        if isZoomInstant or not currentScale then
            currentScale = nil
            applyView()
            if isChanged then sim.call(map.OnCanvasScaleChanged, map) end
        else
            applyView() -- (the scale stays; the glide moves it, in OnUpdate)
        end
    end
    -- Each step of the scale: to the data providers, then every pin, as MapCanvasMixin:CallMethodOnPinsAndDataProviders
    map.OnCanvasScaleChanged = function(self)
        for provider in pairs(providers) do
            if provider.OnCanvasScaleChanged then sim.call(provider.OnCanvasScaleChanged, provider) end
        end
        for pin in pairs(pins) do
            if pin.OnCanvasScaleChanged then sim.call(pin.OnCanvasScaleChanged, pin) end
        end
    end
    map.GetCanvasScale = function() return canvas:GetScale() end
    map.GetCanvasZoomPercent = function()
        if #zoomLevels <= 1 then return 0 end
        return (canvas:GetScale() - zoomLevels[1]) / (zoomLevels[#zoomLevels] - zoomLevels[1])
    end
    map.IsZoomedIn = function() return zoomIndex > 1 end
    map.IsZoomingIn = function() return currentScale ~= nil and currentScale < (zoomLevels[zoomIndex] or currentScale) end
    map.IsZoomingOut = function() return currentScale ~= nil and currentScale > (zoomLevels[zoomIndex] or currentScale) end
    map.SetShouldZoomInstantly = function(_, isInstant)
        isZoomInstant = isInstant and true or false
        currentScale = (not isZoomInstant) and canvas:GetScale() or nil
    end
    map.ShouldZoomInstantly = function() return isZoomInstant end
    container.SetShouldZoomInstantly = map.SetShouldZoomInstantly
    container.ShouldZoomInstantly = map.ShouldZoomInstantly
    local function glide()
        local target = zoomLevels[zoomIndex]
        if isZoomInstant or not currentScale or not target or currentScale == target then return end
        if math.abs(currentScale - target) < 0.0001 then
            currentScale = target
        else
            currentScale = currentScale + (target - currentScale) * math.min(1, 0.15 * (sim.lastElapsed or 0) * 60)
        end
        applyView()
        sim.call(map.OnCanvasScaleChanged, map)
    end
    map.GetViewRect = function()
        local scale = canvas:GetScale()
        local width, height = (container:GetWidth() or 697) / scale / canvas:GetWidth(), (container:GetHeight() or 465) / scale / canvas:GetHeight()
        return scrollX - width / 2, scrollY - height / 2, width, height
    end
    map.PanTo = function(self, x, y) scrollX, scrollY = x, y; applyView() end
    map.PanAndZoomTo = function(self, x, y) setZoom(#zoomLevels, x, y) end
    -- (at once whatever the map's zoom, as the game's ResetZoom: InstantPanAndZoom)
    map.ResetZoom = function()
        currentScale = nil
        setZoom(1)
        if not isZoomInstant then currentScale = canvas:GetScale() end
    end
    container.ZoomIn = function() setZoom(zoomIndex + 1) end
    container.ZoomOut = function() setZoom(zoomIndex - 1) end
    container.GetCanvasScale = map.GetCanvasScale
    container.IsZoomedIn = map.IsZoomedIn
    container.GetZoomLevelCount = function() return #zoomLevels end
    container.GetCurrentZoomIndex = function() return zoomIndex end
    container.resetView = function()
        createZoomLevels()
        zoomIndex, scrollX, scrollY = 1, 0.5, 0.5
        if currentScale then currentScale = zoomLevels[1] end
        applyView()
    end
    container:SetScript("OnMouseWheel", function(_, delta)
        local mouse = sim.mouse
        local left, bottom, width, height = canvas:GetRect()
        local centerX, centerY
        if delta > 0 and mouse and left then
            centerX, centerY = (mouse.x / canvas:GetEffectiveScale() - left) / width, 1 - (mouse.y / canvas:GetEffectiveScale() - bottom) / height
        end
        setZoom(zoomIndex + (delta > 0 and 1 or -1), centerX, centerY)
    end)
    container:EnableMouseWheel(true)
    -- Dragged with the left button: the map follows the cursor
    local dragFrom
    container:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and sim.mouse then dragFrom = { x = sim.mouse.x, y = sim.mouse.y, scrollX = scrollX, scrollY = scrollY } end
    end)
    local function followDrag()
        if not dragFrom or not sim.mouse then return end
        local scale = canvas:GetEffectiveScale()
        scrollX = dragFrom.scrollX - (sim.mouse.x - dragFrom.x) / scale / canvas:GetWidth()
        scrollY = dragFrom.scrollY + (sim.mouse.y - dragFrom.y) / scale / canvas:GetHeight()
        applyView()
    end
    -- Let go: the map ends where the cursor is, however fast it moved
    container:SetScript("OnMouseUp", function() followDrag(); dragFrom = nil end)
    container:SetScript("OnUpdate", function()
        glide()
        if dragFrom and not sim.mouseDown then dragFrom = nil end
        followDrag()
    end)
    map.NavigateToParentMap = function(self) local info = G.C_Map.GetMapInfo(mapId); if info and info.parentMapID > 0 then self:SetMapID(info.parentMapID) end end
    map.NavigateToCursor = function() end
    map.GetNormalizedCursorPosition = function()
        local mouse = sim.mouse
        local left, bottom, width, height = canvas:GetRect()
        if not mouse or not left then return 0.5, 0.5 end
        -- The cursor is in screen units, the canvas' rect in its own (scaled by the map and its zoom)
        local scale = canvas:GetEffectiveScale()
        return (mouse.x - left * scale) / (width * scale), 1 - (mouse.y - bottom * scale) / (height * scale)
    end
    map.AddDataProvider = function(self, provider) providers[provider] = true; provider.owningMap = self; if provider.OnAdded then sim.call(provider.OnAdded, provider, self) end end
    map.RemoveDataProvider = function(self, provider) providers[provider] = nil end
    map.RefreshAllDataProviders = function() for provider in pairs(providers) do if provider.RefreshAllData then sim.call(provider.RefreshAllData, provider) end end end
    map.AcquirePin = function(self, template, ...)
        local pin = createFrame("Button", nil, canvas)
        S[pin].pinTemplate = template
        pin.owningMap = self
        pins[pin] = template
        -- As MapCanvasMixin:ApplyPinPosition: the offsets are divided by the pin's own scale, so a scaled pin
        -- still sits on its point of the map
        pin.SetPosition = function(pinSelf, x, y)
            local scale = pinSelf:GetScale()
            pinSelf:ClearAllPoints()
            pinSelf:SetPoint("CENTER", canvas, "TOPLEFT", x * canvas:GetWidth() / scale, -y * canvas:GetHeight() / scale)
        end
        pin.GetMap = function() return self end
        if pin.OnAcquired then sim.call(pin.OnAcquired, pin, ...) end
        return pin
    end
    map.RemoveAllPinsByTemplate = function(_, template) for pin, pinTemplate in pairs(pins) do if pinTemplate == template then pin:Hide(); pins[pin] = nil end end end
    map.RemovePin = function(_, pin) pin:Hide(); pins[pin] = nil end
    map.EnumeratePinsByTemplate = function(_, template)
        local list = {}
        for pin, pinTemplate in pairs(pins) do if pinTemplate == template then list[#list + 1] = pin end end
        local index = 0
        return function() index = index + 1; return list[index] end
    end
    map.EnumerateAllPins = function()
        local list = {}
        for pin in pairs(pins) do list[#list + 1] = pin end
        local index = 0
        return function() index = index + 1; return list[index] end
    end
    map.GetNumActivePinsByTemplate = function(_, template) local count = 0; for _, pinTemplate in pairs(pins) do if pinTemplate == template then count = count + 1 end end; return count end
    map.SetDisplayState = function(self, displayState) S[self].displayState = displayState end
    -- What the game's map calls as it pans, zooms and resizes; addons hook these
    for _, name in ipairs({ "OnCanvasScaleChanged", "OnCanvasPanChanged", "OnCanvasSizeChanged", "OnFrameSizeChanged",
        "RefreshAll", "RefreshOverlayFrames", "OnMapInsetSizeChanged", "OnMapInsetMouseEnter", "OnMapInsetMouseLeave",
        "OnUIClose", "SetHighlightedPin", "TriggerEvent" }) do
        -- (not over the ones made above: OnCanvasScaleChanged was, and the providers never heard the zoom)
        if map[name] == nil then map[name] = function() end end
    end
    map.IsMaximized = function() return false end
    map.HandleUserActionMinimizeSelf = function() end
    map.HandleUserActionMaximizeSelf = function() end
    map.SetQuestLogPanelShown = function(_, isShown) map.QuestLog:SetShown(isShown) end
    map.UpdateSpacerFrameAnchoring = function() end
    map.SynchronizeDisplayState = function() end
    map.IsSidePanelShown = function() return map.QuestLog:IsShown() end
    map:HookScript("OnShow", function(self)
        if not S[self].mapSet then self:SetMapID(game.profile.uiMapId) end
    end)
    -- The breadcrumb bar (World > continent > zone), the game's own when its templates are loaded
    if W.getTemplate("WorldMapNavBarTemplate") then
        local navBar = createFrame("Frame", nil, map, "WorldMapNavBarTemplate")
        navBar:SetPoint("TOPLEFT", spacer, "TOPLEFT", 64, -25)
        navBar:SetPoint("BOTTOMRIGHT", spacer, "BOTTOMRIGHT", -4, 9)
        map.NavBar = navBar
    end
    -- The player and the party, as the game's GroupMembersDataProvider draws them: the player's arrow (27) turned
    -- to the facing, members as class-coloured WhiteCircle-RaidBlips (11), the same size on screen at any zoom
    local groupLayer = createFrame("Frame", nil, canvas)
    groupLayer:SetAllPoints(canvas)
    -- At the game's own level for group members (PIN_FRAME_LEVEL_GROUP_MEMBER, about 2765): anything an addon
    -- draws on the canvas above that level covers them, as it does in the game
    groupLayer:SetFrameLevel(ui.getGroupMemberPinLevel())
    local playerArrow = groupLayer:CreateTexture(nil, "OVERLAY", nil, 7)
    playerArrow:SetAtlas("UI-WorldMapArrow")
    S[playerArrow].markRole = "player"
    local memberBlips = {}
    local function placeOnCanvas(texture, unit, size)
        local position = G.C_Map.GetPlayerMapPosition(mapId, unit)
        if not position then texture:Hide(); return false end
        local x, y = position:GetXY()
        local scale = canvas:GetScale()
        texture:SetSize(size / scale, size / scale)
        texture:ClearAllPoints()
        texture:SetPoint("CENTER", canvas, "TOPLEFT", x * canvas:GetWidth(), -y * canvas:GetHeight())
        texture:Show()
        return true
    end
    groupLayer:SetScript("OnUpdate", function()
        if not map:IsVisible() then return end
        local party = require("party")
        for index, member in ipairs(party.members) do
            local blip = memberBlips[index]
            if not blip then
                blip = groupLayer:CreateTexture(nil, "OVERLAY", nil, 5)
                blip:SetAtlas("WhiteCircle-RaidBlips")
                S[blip].markRole = "party"
                memberBlips[index] = blip
            end
            local color = G.RAID_CLASS_COLORS[member.classFile]
            blip:SetVertexColor(color and color.r or 1, color and color.g or 1, color and color.b or 1)
            if not member.isOnline or not placeOnCanvas(blip, "party" .. index, 11) then blip:Hide() end
        end
        for index = #party.members + 1, #memberBlips do memberBlips[index]:Hide() end
        if placeOnCanvas(playerArrow, "player", 27) then playerArrow:SetRotation(game.profile.facing or 0) end
    end)

    -- Placed by the game's panel manager, registered as Blizzard_WorldMap.lua registers it
    if G.RegisterUIPanel then
        G.RegisterUIPanel(map, { area = "left", pushable = 0, xoffset = 0, yoffset = 0, whileDead = 1, minYOffset = 0, maximizePoint = "TOP", allowOtherPanels = 1 })
    end
    G.ToggleWorldMap = function()
        if map:IsShown() then G.HideUIPanel(map) else G.ShowUIPanel(map); map:SetMapID(game.profile.uiMapId) end
    end
    G.ToggleQuestLog = function() G.ToggleWorldMap() end
    G.OpenWorldMap = function(uiMapId) G.ShowUIPanel(map); if uiMapId then map:SetMapID(uiMapId) end end
    G.MapCanvasPinMixin = { SetPosition = function(self, x, y) self:ClearAllPoints(); self:SetPoint("CENTER", canvas, "TOPLEFT", x * canvas:GetWidth(), -y * canvas:GetHeight()) end,
        OnLoad = function() end, OnAcquired = function() end, OnReleased = function() end, SetScalingLimits = function() end, UseFrameLevelType = function() end,
        GetMap = function(self) return self.owningMap end }
    G.MapCanvasDataProviderMixin = { GetMap = function(self) return self.owningMap end, OnAdded = function(self, owningMap) self.owningMap = owningMap end,
        RemoveAllData = function() end, RefreshAllData = function() end, OnMapChanged = function(self) self:RefreshAllData() end }
end

---Map art per map: the tiles of its first art layer (UiMapXMapArt, UiMapArt, UiMapArtTile), fitted to the canvas.
function ui.loadMapArt(readTable)
    local artByMap, tilesByArt, styles = {}, {}, {}
    for _, row in ipairs(readTable("UiMapXMapArt") or {}) do
        local mapId, artId = tonumber(row.UiMapID), tonumber(row.UiMapArtID)
        if mapId and artId and not artByMap[mapId] then artByMap[mapId] = artId end
    end
    for _, row in ipairs(readTable("UiMapArtTile") or {}) do
        local artId = tonumber(row.UiMapArtID)
        if artId and (tonumber(row.LayerIndex) or 0) == 0 then
            tilesByArt[artId] = tilesByArt[artId] or {}
            table.insert(tilesByArt[artId], { row = tonumber(row.RowIndex) or 0, column = tonumber(row.ColIndex) or 0, fileId = tonumber(row.FileDataID) })
        end
    end
    for _, row in ipairs(readTable("UiMapArt") or {}) do
        styles[tonumber(row.ID) or 0] = tonumber(row.UiMapArtStyleID)
    end
    local styleLayers = {}
    for _, row in ipairs(readTable("UiMapArtStyleLayer") or {}) do
        local style = tonumber(row.UiMapArtStyleID)
        if style and (tonumber(row.LayerIndex) or 0) == 0 then
            styleLayers[style] = { tileWidth = tonumber(row.TileWidth) or 256, tileHeight = tonumber(row.TileHeight) or 256,
                width = tonumber(row.LayerWidth) or 1002, height = tonumber(row.LayerHeight) or 668,
                minScale = tonumber(row.MinScale) or 1, maxScale = tonumber(row.MaxScale) or 1, additionalZoomSteps = tonumber(row.AdditionalZoomSteps) or 0 }
        end
    end
    ui.mapArt = {}
    for mapId, artId in pairs(artByMap) do
        local tiles = tilesByArt[artId]
        if tiles then
            local layer = styleLayers[styles[artId] or 0] or { tileWidth = 256, tileHeight = 256, width = 1002, height = 668 }
            ui.mapArt[mapId] = { tiles = tiles, tileWidth = layer.tileWidth, tileHeight = layer.tileHeight, scale = 1002 / layer.width,
                layer = { layerWidth = layer.width, layerHeight = layer.height, tileWidth = layer.tileWidth, tileHeight = layer.tileHeight,
                    minScale = layer.minScale or 1, maxScale = layer.maxScale or 1, additionalZoomSteps = layer.additionalZoomSteps or 0 } }
        end
    end
end

return ui
