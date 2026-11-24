-- Templates: the game's XML templates built in Lua, with their children, keys and art paths as in the game's
-- FrameXML. Art comes from the real game files (the asset server), so a button looks like the game's button.
local sim = require("sim")
local W = require("widgets")

local T = {}
local templates = require("xmlui").caseBlind() -- (looked up without regard to case, as the client does)
T.templates = templates

local S = W.state

function W.applyTemplate(object, name)
    -- The game's own (XML) template when it is loaded; the simulator's stand-in otherwise
    local xmlui = package.loaded["xmlui"]
    if xmlui and xmlui.applyTemplate(object, name) then
        return
    end
    local template = templates[name]
    if not template then
        sim.noteStub("template:" .. tostring(name))
        return
    end
    template(object)
end

local function texture(frame, layer, path, key)
    local region = frame:CreateTexture(S[frame].name and key and (S[frame].name .. key) or nil, layer)
    if path then
        region:SetTexture(path)
    end
    if key then
        frame[key] = region
    end
    return region
end

-- Backdrops
local backdropMethods = {
    SetBackdrop = function(self, backdrop)
        S[self].backdrop = backdrop
                and {
                    bgFile = backdrop.bgFile,
                    edgeFile = backdrop.edgeFile,
                    tile = backdrop.tile,
                    tileSize = backdrop.tileSize,
                    edgeSize = backdrop.edgeSize or 16,
                    insets = backdrop.insets or { left = 0, right = 0, top = 0, bottom = 0 },
                }
            or nil
        S[self].backdropColor = S[self].backdropColor or { 1, 1, 1, 1 }
        S[self].backdropBorderColor = S[self].backdropBorderColor or { 1, 1, 1, 1 }
        sim.touchVisual(self)
    end,
    GetBackdrop = function(self)
        return S[self].backdrop
    end,
    SetBackdropColor = function(self, r, g, b, a)
        S[self].backdropColor = { W.unpackColor(r, g, b, a) }
        sim.touchVisual(self)
    end,
    GetBackdropColor = function(self)
        return unpack(S[self].backdropColor or { 1, 1, 1, 1 })
    end,
    SetBackdropBorderColor = function(self, r, g, b, a)
        S[self].backdropBorderColor = { W.unpackColor(r, g, b, a) }
        sim.touchVisual(self)
    end,
    GetBackdropBorderColor = function(self)
        return unpack(S[self].backdropBorderColor or { 1, 1, 1, 1 })
    end,
    ApplyBackdrop = function(self)
        sim.touchVisual(self)
    end,
    ClearBackdrop = function(self)
        S[self].backdrop = nil
        sim.touchVisual(self)
    end,
    OnBackdropLoaded = function() end,
    OnBackdropSizeChanged = function() end,
}
T.backdropMethods = backdropMethods
templates.BackdropTemplate = function(frame)
    for key, method in pairs(backdropMethods) do
        frame[key] = method
    end
end
templates.TooltipBackdropTemplate = function(frame)
    templates.BackdropTemplate(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    frame:SetBackdropColor(0.09, 0.09, 0.19, 0.95)
    frame:SetBackdropBorderColor(1, 1, 1, 1)
end

-- Buttons
templates.UIPanelButtonTemplate = function(button)
    button:SetSize(button:GetWidth() > 0 and button:GetWidth() or 80, 22)
    for kind, path in pairs({
        Normal = "Interface\\Buttons\\UI-Panel-Button-Up",
        Pushed = "Interface\\Buttons\\UI-Panel-Button-Down",
        Disabled = "Interface\\Buttons\\UI-Panel-Button-Disabled",
    }) do
        button["Set" .. kind .. "Texture"](button, path)
        button["Get" .. kind .. "Texture"](button):SetTexCoord(0, 0.625, 0, 0.6875)
    end
    button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
    button:GetHighlightTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")
    button:SetDisabledFontObject("GameFontDisable")
    button.Text = button:GetFontString()
end
templates.UIPanelButtonNoTooltipTemplate = templates.UIPanelButtonTemplate
templates.SharedButtonTemplate = templates.UIPanelButtonTemplate
templates.UIPanelDynamicResizeButtonTemplate = templates.UIPanelButtonTemplate

templates.UIPanelCloseButtonNoScripts = function(button)
    button:SetSize(32, 32)
    button:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    button:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    button:SetDisabledTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Disabled")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
end
templates.UIPanelCloseButton = function(button)
    templates.UIPanelCloseButtonNoScripts(button)
    button:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent then
            parent:Hide()
        end
    end)
end
templates.UIPanelCloseButtonDefaultAnchors = templates.UIPanelCloseButton

templates.UICheckButtonTemplate = function(button)
    button:SetSize(32, 32)
    button:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    button:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    button:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    button:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    button:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
    local name = S[button].name
    local text = button:CreateFontString(name and (name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("LEFT", button, "RIGHT", -2, 0)
    button.Text, button.text = text, text
    button:SetFontString(text)
end
templates.InterfaceOptionsCheckButtonTemplate = templates.UICheckButtonTemplate
templates.ChatConfigCheckButtonTemplate = templates.UICheckButtonTemplate
templates.OptionsBaseCheckButtonTemplate = templates.UICheckButtonTemplate

-- Windows
templates.BasicFrameTemplate = function(frame)
    local background = texture(frame, "BACKGROUND", "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", "Bg")
    background:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -21)
    background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    local titleBackground = texture(frame, "BACKGROUND", nil, "TitleBg")
    titleBackground:SetColorTexture(0.12, 0.1, 0.07, 1)
    titleBackground:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -3)
    titleBackground:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -25, -3)
    titleBackground:SetHeight(18)
    templates.BackdropTemplate(frame)
    frame:SetBackdrop({
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    local name = S[frame].name
    local close = W.createFrame("Button", name and (name .. "CloseButton") or nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 1)
    frame.CloseButton = close
    local title = frame:CreateFontString(name and (name .. "TitleText") or nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", frame, "TOP", 0, -5)
    frame.TitleText = title
end
templates.BasicFrameTemplateWithInset = function(frame)
    templates.BasicFrameTemplate(frame)
    local inset = W.createFrame("Frame", nil, frame)
    inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -24)
    inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 4)
    local insetBackground = inset:CreateTexture(nil, "BACKGROUND")
    insetBackground:SetColorTexture(0, 0, 0, 0.45)
    insetBackground:SetAllPoints(inset)
    frame.Inset, frame.InsetBg = inset, insetBackground
end
templates.InsetFrameTemplate = function(frame)
    local background = texture(frame, "BACKGROUND", nil, "Bg")
    background:SetColorTexture(0, 0, 0, 0.45)
    background:SetAllPoints(frame)
end
templates.DefaultPanelTemplate = templates.BasicFrameTemplate
templates.ButtonFrameTemplate = templates.BasicFrameTemplateWithInset
templates.PortraitFrameTemplate = templates.BasicFrameTemplate

-- Scrolling
templates.UIPanelScrollBarTemplate = function(slider)
    slider:SetWidth(16)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    S[slider].thumb:SetSize(18, 24)
    S[slider].thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)
    S[slider].orientation = "VERTICAL"
    slider:SetMinMaxValues(0, 0)
    slider:SetValue(0)
    local name = S[slider].name
    local up = W.createFrame("Button", name and (name .. "ScrollUpButton") or nil, slider)
    up:SetSize(18, 16)
    up:SetPoint("BOTTOM", slider, "TOP", 0, 0)
    up:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
    up:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
    up:SetDisabledTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled")
    up:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight", "ADD")
    for _, region in ipairs({
        up:GetNormalTexture(),
        up:GetPushedTexture(),
        up:GetDisabledTexture(),
        up:GetHighlightTexture(),
    }) do
        region:SetTexCoord(0.20, 0.80, 0.25, 0.75)
    end
    local down = W.createFrame("Button", name and (name .. "ScrollDownButton") or nil, slider)
    down:SetSize(18, 16)
    down:SetPoint("TOP", slider, "BOTTOM", 0, 0)
    down:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    down:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
    down:SetDisabledTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
    down:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight", "ADD")
    for _, region in ipairs({
        down:GetNormalTexture(),
        down:GetPushedTexture(),
        down:GetDisabledTexture(),
        down:GetHighlightTexture(),
    }) do
        region:SetTexCoord(0.20, 0.80, 0.25, 0.75)
    end
    slider.ScrollUpButton, slider.ScrollDownButton = up, down
    up:SetScript("OnClick", function()
        slider:SetValue(slider:GetValue() - 20)
    end)
    down:SetScript("OnClick", function()
        slider:SetValue(slider:GetValue() + 20)
    end)
end

templates.UIPanelScrollFrameTemplate = function(frame)
    local name = S[frame].name
    local bar = W.createFrame("Slider", name and (name .. "ScrollBar") or nil, frame, "UIPanelScrollBarTemplate")
    bar:SetPoint("TOPLEFT", frame, "TOPRIGHT", 6, -16)
    bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 6, 16)
    frame.ScrollBar = bar
    frame:EnableMouseWheel(true)
    local function update()
        local range = frame:GetVerticalScrollRange()
        bar:SetMinMaxValues(0, range)
        bar:SetShown(range > 0 or not S[frame].hideIfUnscrollable)
        if frame:GetVerticalScroll() > range then
            frame:SetVerticalScroll(range)
        end
    end
    frame:SetScript("OnScrollRangeChanged", update)
    frame:SetScript("OnVerticalScroll", function(self, offset)
        bar:SetValue(offset)
    end)
    frame:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange()
        local offset = math.max(0, math.min(range, self:GetVerticalScroll() - delta * 20))
        self:SetVerticalScroll(offset)
    end)
    bar:SetScript("OnValueChanged", function(self, value)
        if math.abs(frame:GetVerticalScroll() - value) > 0.01 then
            frame:SetVerticalScroll(value) -- (its own hooks hear it; the bar's SetValue back is the same value)
        end
    end)
    frame.SetHideIfUnscrollable = function(self, isHidden)
        S[self].hideIfUnscrollable = isHidden
    end
end
templates.ScrollFrameTemplate = templates.UIPanelScrollFrameTemplate
templates.UIPanelInputScrollFrameTemplate = templates.UIPanelScrollFrameTemplate

-- Text input
templates.InputBoxTemplate = function(box)
    local left = texture(box, "BACKGROUND", "Interface\\Common\\Common-Input-Border", "Left")
    left:SetSize(8, 20)
    left:SetPoint("LEFT", box, "LEFT", -5, 0)
    left:SetTexCoord(0, 0.0625, 0, 0.625)
    local right = texture(box, "BACKGROUND", "Interface\\Common\\Common-Input-Border", "Right")
    right:SetSize(8, 20)
    right:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    right:SetTexCoord(0.9375, 1, 0, 0.625)
    local middle = texture(box, "BACKGROUND", "Interface\\Common\\Common-Input-Border", "Middle")
    middle:SetSize(10, 20)
    middle:SetPoint("LEFT", left, "RIGHT", 0, 0)
    middle:SetPoint("RIGHT", right, "LEFT", 0, 0)
    middle:SetTexCoord(0.0625, 0.9375, 0, 0.625)
    box:SetFontObject("ChatFontNormal")
    box:SetAutoFocus(false)
end
templates.InputBoxInstructionsTemplate = function(box)
    templates.InputBoxTemplate(box)
    local instructions = box:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    instructions:SetPoint("LEFT", box, "LEFT", 0, 0)
    box.Instructions = instructions
end
templates.SearchBoxTemplate = function(box)
    templates.InputBoxInstructionsTemplate(box)
    box:SetTextInsets(16, 20, 0, 0)
    local icon = texture(box, "OVERLAY", "Interface\\Common\\UI-Searchbox-Icon", "searchIcon")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", box, "LEFT", 0, -2)
    icon:SetVertexColor(0.6, 0.6, 0.6)
    box.Instructions:SetText(sim.G.SEARCH or "Search")
    box.Instructions:ClearAllPoints()
    box.Instructions:SetPoint("LEFT", box, "LEFT", 16, 0)
    local clear = W.createFrame("Button", nil, box)
    clear:SetSize(17, 17)
    clear:SetPoint("RIGHT", box, "RIGHT", -3, 0)
    local clearTexture = clear:CreateTexture(nil, "ARTWORK")
    clearTexture:SetTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
    clearTexture:SetAllPoints(clear)
    clear:Hide()
    box.clearButton = clear
    clear:SetScript("OnClick", function()
        box:SetText("")
        box:ClearFocus()
    end)
    box:SetScript("OnTextChanged", function(self)
        local isEmpty = (self:GetText() or "") == ""
        self.Instructions:SetShown(isEmpty)
        clear:SetShown(not isEmpty)
    end)
end

-- Tooltips
templates.GameTooltipTemplate = function(tooltip)
    templates.TooltipBackdropTemplate(tooltip)
    tooltip:SetFrameStrata("TOOLTIP")
    tooltip:SetClampedToScreen(true)
end

-- Others the addons ask for
templates.NineSlicePanelTemplate = function(frame)
    templates.BackdropTemplate(frame)
end
templates.CooldownFrameTemplate = function() end
-- The game's secure button acts on its attributes when clicked: "item" uses that item, "macro" runs its text
templates.SecureActionButtonTemplate = function(button)
    button:HookScript("OnClick", function(self, mouseButton, isDown)
        if isDown and self:GetAttribute("type") ~= nil then
            -- Registered for both: the game acts on the press only when the button is set to; take the release
            local state = S[self] or {}
            if not (W.isClickRegistered(state, "Any", "Down") and not W.isClickRegistered(state, "Any", "Up")) then
                return
            end
        end
        local kind = self:GetAttribute("type")
        if kind == "item" then
            require("game").useItem(self:GetAttribute("item"))
        elseif kind == "macro" then
            for line in tostring(self:GetAttribute("macrotext") or ""):gmatch("[^\n]+") do
                if require("sim").runSlashCommand then
                    require("sim").runSlashCommand(line)
                end
            end
        end
    end)
end
-- Its insecure twin (SecureTemplates.xml): the same action on a click out of combat, for addons' own buttons
templates.InsecureActionButtonTemplate = function(button)
    templates.SecureActionButtonTemplate(button)
end
templates.SecureHandlerBaseTemplate = function() end
templates.SecureFrameTemplate = function() end
templates.SecureUnitButtonTemplate = function() end
templates.ActionButtonTemplate = function(button)
    button:SetSize(36, 36)
    local icon = texture(button, "BACKGROUND", nil, "icon")
    icon:SetAllPoints(button)
    button.Icon = icon
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
end
templates.OptionsSliderTemplate = function(slider)
    templates.BackdropTemplate(slider)
    slider:SetSize(144, 17)
    slider:SetOrientation("HORIZONTAL")
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local name = S[slider].name
    slider.Low = slider:CreateFontString(name and (name .. "Low") or nil, "ARTWORK", "GameFontHighlightSmall")
    slider.High = slider:CreateFontString(name and (name .. "High") or nil, "ARTWORK", "GameFontHighlightSmall")
    slider.Text = slider:CreateFontString(name and (name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    slider.Low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -4, 3)
    slider.High:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 4, 3)
    slider.Text:SetPoint("BOTTOM", slider, "TOP", 0, 0)
end
templates.UISliderTemplate = templates.OptionsSliderTemplate

templates.PanelTabButtonTemplate = function(button)
    button:SetSize(115, 32)
    local name = S[button].name
    local text = button:CreateFontString(name and (name .. "Text") or nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("CENTER", button, "CENTER", 0, 2)
    button:SetFontString(text)
    button.Text = text
end
templates.CharacterFrameTabButtonTemplate = templates.PanelTabButtonTemplate
templates.PanelTopTabButtonTemplate = templates.PanelTabButtonTemplate
templates.TabButtonTemplate = templates.PanelTabButtonTemplate

templates.WowStyle1DropdownTemplate = function(dropdown)
    dropdown:SetSize(150, 26)
    local background = texture(dropdown, "BACKGROUND", nil, "Background")
    background:SetAtlas("common-dropdown-textholder")
    background:SetAllPoints(dropdown)
    local arrow = texture(dropdown, "ARTWORK", nil, "Arrow")
    arrow:SetAtlas("common-dropdown-a-button")
    arrow:SetSize(28, 28)
    arrow:SetPoint("RIGHT", dropdown, "RIGHT", 0, -1)
    local text = dropdown:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("LEFT", dropdown, "LEFT", 9, 0)
    text:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
    text:SetJustifyH("LEFT")
    dropdown.Text = text
    dropdown:SetFontString(text)
    if sim.installDropdown then
        sim.installDropdown(dropdown)
    end
end
templates.WowStyle2DropdownTemplate = templates.WowStyle1DropdownTemplate
templates.WowStyleDropdownTemplate = templates.WowStyle1DropdownTemplate

return T
