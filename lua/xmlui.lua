-- Frames from XML, as the game builds them: <Ui> files with templates (virtual), intrinsic frame types, frames,
-- their layers, anchors, scripts, key values and mixins. Used for the game's own interface files (so a dropdown
-- is the game's dropdown) and for addons that define frames in XML.
local sim = require("sim")
local W = require("widgets")
local xml = require("xml")

---@return table names A table of names that the client looks up without regard to case (templates: Blizzard's own
---QuestMapFrame inherits "QuestLogTrackCheckBoxTemplate", defined as "...CheckboxTemplate")
local function caseBlind()
    local byLower = {}
    return setmetatable({}, {
        __newindex = function(names, name, value)
            rawset(names, name, value)
            if type(name) == "string" then byLower[name:lower()] = value end
        end,
        __index = function(_, name) return type(name) == "string" and byLower[name:lower()] or nil end,
    })
end
local xmlui = { templates = caseBlind(), intrinsics = caseBlind() }
xmlui.caseBlind = caseBlind
local S = W.state
local G = sim.G

local FRAME_TAGS = {
    Frame = "Frame", Button = "Button", CheckButton = "CheckButton", EditBox = "EditBox", ScrollFrame = "ScrollFrame",
    Slider = "Slider", StatusBar = "StatusBar", Cooldown = "Cooldown", GameTooltip = "GameTooltip", MessageFrame = "MessageFrame",
    ScrollingMessageFrame = "ScrollingMessageFrame", Model = "Model", PlayerModel = "PlayerModel", DressUpModel = "DressUpModel",
    CinematicModel = "PlayerModel", TabardModel = "PlayerModel", ModelScene = "ModelScene", SimpleHTML = "SimpleHTML",
    ColorSelect = "ColorSelect", DropdownButton = "DropdownButton", Minimap = "Minimap", MovieFrame = "Frame",
    OffScreenFrame = "Frame", Browser = "Browser", QuestPOIFrame = "Frame", ScenarioPOIFrame = "Frame", UnitPositionFrame = "Frame",
    FogOfWarFrame = "Frame", ArchaeologyDigSiteFrame = "Frame", Checkout = "Frame", ContainedAlertFrame = "Frame",
    ItemButton = "Button", WorldFrame = "Frame", ScrollBar = "Frame",
}
local REGION_TAGS = { Texture = "Texture", FontString = "FontString", MaskTexture = "MaskTexture", Line = "Line" }

-- The arguments each script gets, named as the game names them for inline code
local SCRIPT_ARGUMENTS = {
    OnEvent = "event, ...", OnUpdate = "elapsed", OnClick = "button, down", PreClick = "button, down", PostClick = "button, down",
    OnDoubleClick = "button", OnMouseDown = "button", OnMouseUp = "button, upInside", OnMouseWheel = "delta", OnEnter = "motion",
    OnLeave = "motion", OnSizeChanged = "width, height", OnValueChanged = "value, userInput", OnMinMaxChanged = "min, max",
    OnTextChanged = "userInput", OnChar = "text", OnKeyDown = "key", OnKeyUp = "key", OnDragStart = "button",
    OnVerticalScroll = "offset", OnHorizontalScroll = "offset", OnScrollRangeChanged = "xrange, yrange", OnAttributeChanged = "name, value",
    OnHyperlinkClick = "link, text, button", OnHyperlinkEnter = "link, text", OnCursorChanged = "x, y, w, h", OnFinished = "requested",
    OnStop = "requested", OnArrowPressed = "key", OnGamePadButtonDown = "button", OnGamePadButtonUp = "button", OnGamePadStick = "stick, x, y, len",
}

local function isTrue(value) return value == "true" or value == "1" end

local function substituteParent(text, parent)
    if type(text) ~= "string" or not text:find("$parent", 1, true) then return text end
    local parentName = parent and require("widgets").getParentNameFor(parent)
    if not parentName then return nil end
    return (text:gsub("%$parent", parentName))
end

---Resolves "$parent.$parent.Key" from an object, as relativeKey and childKey do.
local function resolveKey(object, key)
    local current = object
    for part in key:gmatch("[^%.]+") do
        if part == "$parent" then
            current = current and S[current] and S[current].parent
        elseif current then
            current = current[part]
        end
    end
    return current
end

local function readNumber(element, name, fallback)
    return tonumber(element.attrs[name]) or fallback
end

local function readDimension(element)
    if not element then return nil end
    local absolute = xml.child(element, "AbsDimension")
    local source = absolute or element
    return tonumber(source.attrs.x), tonumber(source.attrs.y)
end

local function readColor(element)
    if element.attrs.color then
        local named = G[element.attrs.color]
        if type(named) == "table" and named.r then return named.r, named.g, named.b, named.a or 1 end
        return 1, 1, 1, 1
    end
    return readNumber(element, "r", 1), readNumber(element, "g", 1), readNumber(element, "b", 1), readNumber(element, "a", 1)
end

-- Anchors wait until the whole tree exists: templates anchor to siblings made later in the file
local pendingAnchors = {}
local function applyAnchors(object, element)
    for _, anchor in ipairs(element.children) do
        if anchor.tag == "Anchor" then
            pendingAnchors[#pendingAnchors + 1] = { object = object, anchor = anchor }
        end
    end
end

local function resolvePendingAnchors()
    local list = pendingAnchors
    pendingAnchors = {}
    for _, pending in ipairs(list) do
        local object, attrs = pending.object, pending.anchor.attrs
        local parent = S[object] and S[object].parent
        local relative
        if attrs.relativeKey then
            relative = resolveKey(object, attrs.relativeKey)
        elseif attrs.relativeTo then
            local name = substituteParent(attrs.relativeTo, parent)
            relative = name and G[name]
        end
        relative = relative or parent or G.UIParent
        local x, y = tonumber(attrs.x) or 0, tonumber(attrs.y) or 0
        local offset = xml.child(pending.anchor, "Offset")
        if offset then
            local offsetX, offsetY = readDimension(offset)
            x, y = offsetX or x, offsetY or y
        end
        sim.call(object.SetPoint, object, attrs.point or "CENTER", relative, attrs.relativePoint or attrs.point or "CENTER", x, y)
    end
end
xmlui.resolvePendingAnchors = resolvePendingAnchors

local function compileScript(element, scriptName, chunkName)
    local attrs = element.attrs
    if attrs.method then
        local method = attrs.method
        return function(self, ...)
            local handler = self[method]
            if handler then return handler(self, ...) end
        end
    elseif attrs["function"] then
        local functionName = attrs["function"]
        return function(...)
            local handler = G[functionName]
            if handler then return handler(...) end
        end
    elseif element.text and element.text:match("%S") then
        local arguments = SCRIPT_ARGUMENTS[scriptName] or "..."
        local chunk, problem = loadstring("return function(self, " .. arguments .. ")\n" .. element.text .. "\nend", "@" .. chunkName)
        if not chunk then
            sim.reportError(problem, "")
            return nil
        end
        setfenv(chunk, G)
        return chunk()
    end
end

local function applyScripts(object, scriptsElement, chunkName)
    local s = S[object]
    for _, scriptElement in ipairs(scriptsElement.children) do
        local scriptName = W.canonicalScript(scriptElement.tag) -- (case-blind, as the client: <OnGamepadStick>)
        local handler = compileScript(scriptElement, scriptName, chunkName)
        if handler then
            local existing = s.scripts[scriptName]
            local inherit = scriptElement.attrs.inherit
            -- As the client: "prepend" puts the inherited handler before this one, "append" after it (the chat edit
            -- box's appended OnLoad sets self.chatFrame, which the template's own OnLoad then reads)
            if existing and inherit == "prepend" then
                local newHandler = handler
                handler = function(...) existing(...); return newHandler(...) end
            elseif existing and inherit == "append" then
                local newHandler = handler
                handler = function(...) newHandler(...); return existing(...) end
            end
            s.scripts[scriptName] = handler
            W.watchScript(object, scriptName)
            if scriptName == "OnUpdate" then sim.setOnUpdate(object, true) end
            if scriptName == "OnMouseWheel" and s.mouseWheel == nil then s.mouseWheel = true end -- (as SetScript: takes the wheel)
        end
    end
end

local function applyKeyValues(object, element)
    for _, keyValue in ipairs(element.children) do
        if keyValue.tag == "KeyValue" then
            local value, valueType = keyValue.attrs.value, keyValue.attrs.type
            if valueType == "number" then value = tonumber(value)
            elseif valueType == "boolean" then value = isTrue(value)
            elseif valueType == "global" then
                -- A path as well as a name: "Enum.EditModeSystem.UnitFrame" (each Edit Mode system's id)
                local found = G
                for part in tostring(value):gmatch("[^%.]+") do
                    found = type(found) == "table" and found[part] or nil
                end
                value = found
            elseif valueType == "nil" then value = nil end
            local key = keyValue.attrs.key
            if keyValue.attrs.keyType == "number" then key = tonumber(key) or key end
            object[key] = value
        end
    end
end

local function assignKeys(object, attrs, parent)
    if parent and attrs.parentKey then
        parent[attrs.parentKey] = object
        -- (what GetParentKey answers: the spellbook's gamepad footers are named after it)
        if S[object] then S[object].parentKey = attrs.parentKey end
    end
    if parent and attrs.parentArray then
        parent[attrs.parentArray] = parent[attrs.parentArray] or {}
        table.insert(parent[attrs.parentArray], object)
    end
end

local function applyMixins(object, attrs)
    for _, attribute in ipairs({ "mixin", "secureMixin" }) do
        for mixinName in (attrs[attribute] or ""):gmatch("[^,%s]+") do
            local mixin = G[mixinName]
            if type(mixin) == "table" then
                for key, value in pairs(mixin) do object[key] = value end
            else
                sim.noteStub("mixin " .. mixinName)
            end
        end
    end
end

local applyRegionElement, applyFrameElement, buildFrame

---A texture's or font string's own settings, after the templates it inherits.
applyRegionElement = function(region, element, chunkName)
    local attrs = element.attrs
    for templateName in (attrs.inherits or ""):gmatch("[^,%s]+") do
        local template = xmlui.templates[templateName]
        if template then
            applyRegionElement(region, template.element, template.chunkName)
        elseif S[region].type == "FontString" or S[region].type == "EditBox" then
            region:SetFontObject(templateName)
        end
    end
    applyMixins(region, attrs)
    local isFontString = S[region].type == "FontString"
    if attrs.file then region:SetTexture(tonumber(attrs.file) or attrs.file) end
    if attrs.atlas then region:SetAtlas(attrs.atlas, isTrue(attrs.useAtlasSize)) end
    if attrs.alphaMode and region.SetBlendMode then region:SetBlendMode(attrs.alphaMode) end
    if attrs.alpha then region:SetAlpha(tonumber(attrs.alpha)) end
    -- A texture's own scale, as a frame's (the gamepad's focus glow is drawn at half: its sliced corners at half size)
    if attrs.scale and region.SetScale then region:SetScale(tonumber(attrs.scale)) end
    if attrs.hidden then region:SetShown(not isTrue(attrs.hidden)) end
    if attrs.horizTile then S[region].horizTile = isTrue(attrs.horizTile) end
    if attrs.vertTile then S[region].vertTile = isTrue(attrs.vertTile) end
    if attrs.desaturated and region.SetDesaturated then region:SetDesaturated(isTrue(attrs.desaturated)) end
    if attrs.rotation and region.SetRotation then region:SetRotation(math.rad(tonumber(attrs.rotation) or 0)) end
    if isFontString then
        if attrs.font then region:SetFont(attrs.font, tonumber(attrs.size) or 12, attrs.outline == "THICK" and "THICKOUTLINE" or attrs.outline == "NORMAL" and "OUTLINE" or "") end
        if attrs.text then region:SetText(G[attrs.text] or attrs.text) end
        if attrs.justifyH then region:SetJustifyH(attrs.justifyH) end
        if attrs.justifyV then region:SetJustifyV(attrs.justifyV) end
        if attrs.maxLines then region:SetMaxLines(tonumber(attrs.maxLines)) end
        if attrs.wordwrap then region:SetWordWrap(isTrue(attrs.wordwrap)) end
        if attrs.nonspacewrap then region:SetNonSpaceWrap(isTrue(attrs.nonspacewrap)) end
        if attrs.spacing then region:SetSpacing(tonumber(attrs.spacing)) end
    end
    if attrs.setAllPoints and isTrue(attrs.setAllPoints) then region:SetAllPoints(S[region].parent) end
    for _, child in ipairs(element.children) do
        local tag = child.tag
        if tag == "Animations" then
            -- A texture's or a text's own animations (the auto-cast spinner's turning): as a frame's
            xmlui.applyAnimations(region, child)
        elseif tag == "Size" then
            local x, y = readDimension(child)
            if x or child.attrs.x then S[region].width = x or tonumber(child.attrs.x) end
            if y or child.attrs.y then S[region].height = y or tonumber(child.attrs.y) end
            sim.touch()
        elseif tag == "Anchors" then
            applyAnchors(region, child)
        elseif tag == "Color" then
            if isFontString then region:SetTextColor(readColor(child))
            elseif S[region].texture or S[region].atlas then region:SetVertexColor(readColor(child))
            elseif region.SetColorTexture then region:SetColorTexture(readColor(child))
            else sim.noteStub("<Color> on a " .. tostring(region.GetObjectType and region:GetObjectType() or "region") .. " (no SetColorTexture)") end
        elseif tag == "TexCoords" and region.SetTexCoord then
            local rect = xml.child(child, "Rect")
            if rect then
                local a = rect.attrs
                region:SetTexCoord(tonumber(a.ULx) or 0, tonumber(a.ULy) or 0, tonumber(a.LLx) or 0, tonumber(a.LLy) or 1,
                    tonumber(a.URx) or 1, tonumber(a.URy) or 0, tonumber(a.LRx) or 1, tonumber(a.LRy) or 1)
            else
                region:SetTexCoord(readNumber(child, "left", 0), readNumber(child, "right", 1), readNumber(child, "top", 0), readNumber(child, "bottom", 1))
            end
        elseif tag == "Gradient" and region.SetGradient then
            local minimum, maximum = xml.child(child, "MinColor"), xml.child(child, "MaxColor")
            if minimum and maximum then
                local r1, g1, b1, a1 = readColor(minimum)
                local r2, g2, b2, a2 = readColor(maximum)
                region:SetGradient(child.attrs.orientation or "HORIZONTAL", { r = r1, g = g1, b = b1, a = a1 }, { r = r2, g = g2, b = b2, a = a2 })
            end
        elseif tag == "Shadow" and isFontString then
            local offset = xml.child(child, "Offset")
            local x, y = readDimension(offset)
            region:SetShadowOffset(x or tonumber(child.attrs.x) or 1, y or tonumber(child.attrs.y) or -1)
            local color = xml.child(child, "Color")
            if color then region:SetShadowColor(readColor(color)) end
        elseif tag == "FontHeight" and isFontString then
            local value = xml.child(child, "AbsValue")
            local path, _, flags = region:GetFont()
            if value then region:SetFont(path, tonumber(value.attrs.val) or 12, flags) end
        elseif tag == "KeyValues" then
            applyKeyValues(region, child)
        elseif tag == "Scripts" then
            -- regions have few scripts the simulator runs; OnLoad is run below
            for _, script in ipairs(child.children) do
                if script.tag == "OnLoad" then S[region].onLoad = compileScript(script, "OnLoad", chunkName) end
            end
        end
    end
end

---Makes a texture, font string, mask or line in a frame's layer, from its element.
local function buildRegion(frame, element, layer, sublevel, chunkName)
    local regionType = REGION_TAGS[element.tag]
    local name = substituteParent(element.attrs.name, frame)
    local region = W.createRegion(frame, regionType, name, layer, nil, sublevel)
    assignKeys(region, element.attrs, frame)
    applyRegionElement(region, element, chunkName)
    if regionType == "MaskTexture" then
        local masked = xml.child(element, "MaskedTextures")
        for _, target in ipairs(masked and masked.children or {}) do
            local childKey = target.attrs.childKey
            xmlui.pendingMasks[#xmlui.pendingMasks + 1] = { frame = frame, key = childKey, mask = region }
        end
    end
    if S[region].onLoad then sim.call(S[region].onLoad, region) end
    return region
end
xmlui.pendingMasks = {}

local function buildButtonPart(button, element, chunkName)
    local tag = element.tag
    local textureSetters = { NormalTexture = "SetNormalTexture", PushedTexture = "SetPushedTexture", DisabledTexture = "SetDisabledTexture",
        HighlightTexture = "SetHighlightTexture", CheckedTexture = "SetCheckedTexture", DisabledCheckedTexture = "SetDisabledCheckedTexture",
        ThumbTexture = "SetThumbTexture", BarTexture = "SetStatusBarTexture" }
    if textureSetters[tag] and button[textureSetters[tag]] then
        local layer = tag == "HighlightTexture" and "HIGHLIGHT" or (tag == "ThumbTexture" and "OVERLAY") or "ARTWORK"
        local region = W.createRegion(button, "Texture", substituteParent(element.attrs.name, button), layer)
        assignKeys(region, element.attrs, button)
        applyRegionElement(region, element, chunkName)
        if #S[region].points == 0 and tag ~= "ThumbTexture" then region:SetAllPoints(button) end
        if tag == "HighlightTexture" and not element.attrs.alphaMode then region:SetBlendMode("ADD") end
        button[textureSetters[tag]](button, region)
        return true
    end
    local fontSetters = { NormalFont = "SetNormalFontObject", HighlightFont = "SetHighlightFontObject", DisabledFont = "SetDisabledFontObject" }
    if fontSetters[tag] and button[fontSetters[tag]] then
        if element.attrs.style then button[fontSetters[tag]](button, element.attrs.style) end
        return true
    end
    if tag == "ButtonText" and button.GetFontString then
        local text = button:GetFontString()
        if element.attrs.name then
            local name = substituteParent(element.attrs.name, button)
            if name then S[text].name = name; G[name] = text end
        end
        assignKeys(text, element.attrs, button)
        applyRegionElement(text, element, chunkName)
        return true
    end
    if tag == "BarColor" and button.SetStatusBarColor then
        button:SetStatusBarColor(readColor(element))
        return true
    end
    if tag == "PushedTextOffset" then return true end
    return false
end

---A frame's own settings, after the templates it inherits: attributes, then children in order.
applyFrameElement = function(frame, element, chunkName)
    local attrs = element.attrs
    -- An intrinsic tag (EventButton, DropdownButton...) brings its own definition first
    if xmlui.intrinsics[element.tag] then xmlui.applyIntrinsic(frame, element.tag) end
    for templateName in (attrs.inherits or ""):gmatch("[^,%s]+") do
        xmlui.applyTemplate(frame, templateName)
    end
    applyMixins(frame, attrs)
    local s = S[frame]
    if attrs.setAllPoints and isTrue(attrs.setAllPoints) then frame:SetAllPoints(s.parent) end
    if attrs.alpha then frame:SetAlpha(tonumber(attrs.alpha)) end
    if attrs.scale then frame:SetScale(tonumber(attrs.scale)) end
    if attrs.fixedFrameStrata == "true" then frame:SetFixedFrameStrata(true) end
    if attrs.frameStrata then frame:SetFrameStrata(attrs.frameStrata) end
    if attrs.frameLevel then frame:SetFrameLevel(tonumber(attrs.frameLevel)) end
    if attrs.collapsesLayout and isTrue(attrs.collapsesLayout) then s.collapsesLayout = true end
    if attrs.useParentLevel and isTrue(attrs.useParentLevel) then
        s.useParentLevel = true
        local parentState = s.parent and S[s.parent]
        if parentState then s.level = parentState.level or 0; W.touchOrder() end
    end
    if attrs.toplevel then frame:SetToplevel(isTrue(attrs.toplevel)) end
    if attrs.movable then frame:SetMovable(isTrue(attrs.movable)) end
    if attrs.resizable then frame:SetResizable(isTrue(attrs.resizable)) end
    if attrs.dontSavePosition then frame:SetDontSavePosition(isTrue(attrs.dontSavePosition)) end
    if attrs.enableMouse then frame:EnableMouse(isTrue(attrs.enableMouse)) end
    -- registerForDrag="LeftButton" (Edit Mode's selections, each system dragged by its own): as RegisterForDrag
    if attrs.registerForDrag and frame.RegisterForDrag then
        local buttons = {}
        for name in attrs.registerForDrag:gmatch("[^,%s]+") do buttons[#buttons + 1] = name end
        frame:RegisterForDrag(unpack(buttons))
    end
    if attrs.enableMouseClicks then frame:SetMouseClickEnabled(isTrue(attrs.enableMouseClicks)) end
    if attrs.enableMouseMotion then frame:SetMouseMotionEnabled(isTrue(attrs.enableMouseMotion)) end
    if attrs.enableKeyboard then frame:EnableKeyboard(isTrue(attrs.enableKeyboard)) end
    if attrs.clampedToScreen then frame:SetClampedToScreen(isTrue(attrs.clampedToScreen)) end
    if attrs.clipChildren then frame:SetClipsChildren(isTrue(attrs.clipChildren)) end
    if attrs.ignoreParentAlpha then frame:SetIgnoreParentAlpha(isTrue(attrs.ignoreParentAlpha)) end
    if attrs.ignoreParentScale then frame:SetIgnoreParentScale(isTrue(attrs.ignoreParentScale)) end
    if attrs.id then frame:SetID(tonumber(attrs.id) or 0) end
    if attrs.motionScriptsWhileDisabled and frame.SetMotionScriptsWhileDisabled then frame:SetMotionScriptsWhileDisabled(isTrue(attrs.motionScriptsWhileDisabled)) end
    if attrs.registerForClicks and frame.RegisterForClicks then frame:RegisterForClicks(strsplit and attrs.registerForClicks or attrs.registerForClicks) end
    if attrs.text and frame.SetText then frame:SetText(G[attrs.text] or attrs.text) end
    if attrs.autoFocus and frame.SetAutoFocus then frame:SetAutoFocus(isTrue(attrs.autoFocus)) end
    if attrs.multiLine and frame.SetMultiLine then frame:SetMultiLine(isTrue(attrs.multiLine)) end
    if attrs.letters and frame.SetMaxLetters then frame:SetMaxLetters(tonumber(attrs.letters)) end
    if attrs.numeric and frame.SetNumeric then frame:SetNumeric(isTrue(attrs.numeric)) end
    if attrs.orientation and frame.SetOrientation then frame:SetOrientation(attrs.orientation) end
    if attrs.minValue and frame.SetMinMaxValues then frame:SetMinMaxValues(tonumber(attrs.minValue) or 0, tonumber(attrs.maxValue) or 1) end
    if attrs.valueStep and frame.SetValueStep then frame:SetValueStep(tonumber(attrs.valueStep)) end
    if attrs.defaultValue and frame.SetValue then frame:SetValue(tonumber(attrs.defaultValue)) end
    if attrs.hidden then s.shown = not isTrue(attrs.hidden); W.touchOrder(); sim.touch() end
    for _, child in ipairs(element.children) do
        local tag = child.tag
        if tag == "Animations" then
            xmlui.applyAnimations(frame, child)
        elseif tag == "Size" then
            local x, y = readDimension(child)
            if x then s.width = x end
            if y then s.height = y end
            sim.touch()
        elseif tag == "Anchors" then
            applyAnchors(frame, child)
        elseif tag == "Layers" then
            for _, layer in ipairs(child.children) do
                if layer.tag == "Layer" then
                    for _, regionElement in ipairs(layer.children) do
                        if REGION_TAGS[regionElement.tag] then
                            buildRegion(frame, regionElement, layer.attrs.level or "ARTWORK", tonumber(layer.attrs.textureSubLevel) or 0, chunkName)
                        end
                    end
                end
            end
        elseif tag == "Frames" then
            for _, frameElement in ipairs(child.children) do
                if FRAME_TAGS[frameElement.tag] or xmlui.intrinsics[frameElement.tag] then
                    buildFrame(frameElement, frame, chunkName)
                else
                    -- A frame type nobody defined (yet): left out, as noted
                    sim.noteStub("XML <" .. tostring(frameElement.tag) .. "> unknown, in " .. tostring(chunkName))
                end
            end
        elseif tag == "Scripts" then
            applyScripts(frame, child, chunkName)
        elseif tag == "KeyValues" then
            applyKeyValues(frame, child)
        elseif tag == "Mixins" then
            -- <Mixins><Mixin key="AuraContainerInboundMixin" .../>: each named mixin, as the mixin attribute does (its
            -- environments and partitions are the secure environment's; the simulator has one)
            for _, mixinElement in ipairs(child.children) do
                if mixinElement.tag == "Mixin" and mixinElement.attrs.key then applyMixins(frame, { mixin = mixinElement.attrs.key }) end
            end
        elseif tag == "Attributes" then
            for _, attribute in ipairs(child.children) do
                local value = attribute.attrs.value
                if attribute.attrs.type == "number" then value = tonumber(value) elseif attribute.attrs.type == "boolean" then value = isTrue(value) end
                -- Set as the frame is made, with no OnAttributeChanged: the frame is not whole yet (an action button's
                -- handler reads its icon, made later from its layers)
                frame:SetAttributeNoHandler(attribute.attrs.name, value)
            end
        elseif tag == "HitRectInsets" then
            local inset = xml.child(child, "AbsInset") or child
            frame:SetHitRectInsets(readNumber(inset, "left", 0), readNumber(inset, "right", 0), readNumber(inset, "top", 0), readNumber(inset, "bottom", 0))
        elseif tag == "TextInsets" and frame.SetTextInsets then
            local inset = xml.child(child, "AbsInset") or child
            frame:SetTextInsets(readNumber(inset, "left", 0), readNumber(inset, "right", 0), readNumber(inset, "top", 0), readNumber(inset, "bottom", 0))
        elseif tag == "ScrollChild" then
            for _, frameElement in ipairs(child.children) do
                if FRAME_TAGS[frameElement.tag] or xmlui.intrinsics[frameElement.tag] then
                    local scrollChild = buildFrame(frameElement, frame, chunkName)
                    if frame.SetScrollChild then frame:SetScrollChild(scrollChild) end
                end
            end
        elseif tag == "FontString" and frame.SetFontObject then
            -- an edit box's text
            applyRegionElement(frame, child, chunkName)
        elseif not buildButtonPart(frame, child, chunkName) then
            -- ResizeBounds, Backdrop and others the simulator does not draw: left alone
        end
    end
end

-- An animation group's animations, as the game makes them from XML: each one is the group's under its parentKey
-- (AutoCast's Anim group, the gamepad bars' Translation), with its timing; what they do on screen is not drawn
local ANIMATION_TAGS = { Alpha = true, Translation = true, Rotation = true, Scale = true, LineScale = true, LineTranslation = true,
    Path = true, FlipBook = true, TextureCoordTranslation = true, VertexColor = true, Animation = true,
    RadialProgress = true } -- (Forever: the gamepad prompt's ring that fills while a button is held)

---Fills an animation group from its element: the templates it inherits first, then its mixin, key values and
---animations (the buff frame's warning fader is a template with a mixin, its Init called from the frame's OnLoad).
local function fillAnimationGroup(group, groupElement, depth)
    local attrs = groupElement.attrs
    for templateName in (attrs.inherits or ""):gmatch("[^,%s]+") do
        local template = xmlui.templates[templateName]
        if template and template.element.tag == "AnimationGroup" and (depth or 0) < 20 then
            fillAnimationGroup(group, template.element, (depth or 0) + 1)
        end
    end
    applyMixins(group, attrs)
    if attrs.looping and group.SetLooping then group:SetLooping(attrs.looping) end
    for _, animationElement in ipairs(groupElement.children) do
        if animationElement.tag == "KeyValues" then
            applyKeyValues(group, animationElement)
        elseif ANIMATION_TAGS[animationElement.tag] then
            local a = animationElement.attrs
            local animation = group:CreateAnimation(animationElement.tag, a.name)
            if a.parentKey then group[a.parentKey] = animation end
            if a.duration and animation.SetDuration then animation:SetDuration(tonumber(a.duration)) end
            if a.order and animation.SetOrder then animation:SetOrder(tonumber(a.order)) end
            if a.startDelay and animation.SetStartDelay then animation:SetStartDelay(tonumber(a.startDelay)) end
            if a.childKey and animation.SetChildKey then animation:SetChildKey(a.childKey) end
            if a.targetKey and animation.SetTargetKey then animation:SetTargetKey(a.targetKey) end
        end
    end
end

---Fills a group made in Lua from its template (frame:CreateAnimationGroup(name, template)).
function xmlui.applyAnimationGroupTemplates(group, templateNames)
    fillAnimationGroup(group, { attrs = { inherits = templateNames }, children = {} })
end

---Makes an <Animations> element's groups on a frame or a region, each group's animations in it.
function xmlui.applyAnimations(owner, element)
    if not owner.CreateAnimationGroup then return end
    for _, groupElement in ipairs(element.children) do
        if groupElement.tag == "AnimationGroup" then
            local group = owner:CreateAnimationGroup(groupElement.attrs.name)
            if groupElement.attrs.parentKey then owner[groupElement.attrs.parentKey] = group end
            -- In a list on the owner as well, as frames and regions are (RogueComboPoint's transitionAnims)
            local arrayKey = groupElement.attrs.parentArray
            if arrayKey then
                owner[arrayKey] = owner[arrayKey] or {}
                table.insert(owner[arrayKey], group)
            end
            fillAnimationGroup(group, groupElement)
        end
    end
end
---Applies a template by name: the game's (or an addon's) XML one, else the simulator's own in Lua.
function xmlui.applyTemplate(object, templateName)
    local template = xmlui.templates[templateName]
    if template then
        -- A template's own parentKey / parentArray applies to what is made from it
        local parent = S[object] and S[object].parent
        if parent then assignKeys(object, template.element.attrs, parent) end
        if REGION_TAGS[template.element.tag] then
            applyRegionElement(object, template.element, template.chunkName)
        else
            applyFrameElement(object, template.element, template.chunkName)
        end
        return true
    end
    return false
end

local function applyPendingMasks()
    local list = xmlui.pendingMasks
    xmlui.pendingMasks = {}
    for _, pending in ipairs(list) do
        local target = pending.key and resolveKey(pending.frame, pending.key)
        if target and target.AddMaskTexture then target:AddMaskTexture(pending.mask) end
    end
end

-- OnLoad waits until the whole frame is built, as in the client: from every template it inherits and all its children,
-- then each frame's OnLoad in the order they were finished (children first). A child's OnLoad may read what a later
-- template gives its parent (ThreeSlice's controller asks its button for the atlasName the red button template sets).
local buildsOpen, pendingLoads = 0, {}
-- Who makes what a build makes: no addon's code runs while a frame is built (its OnLoad waits for the end), so every
-- region in it has the creator its outermost build has, worked out once (it was a walk up the stack for each region)
local buildCreator
function xmlui.beginBuild()
    if buildsOpen == 0 then buildCreator = sim.getCallingAddon() end
    buildsOpen = buildsOpen + 1
end
---@return boolean isBuilding A frame is being built now
---@return string? creator The addon whose code set the build going (nil: the simulator's own, or the game's XML)
function xmlui.getBuild() return buildsOpen > 0, buildCreator end
function xmlui.queueLoad(frame) pendingLoads[#pendingLoads + 1] = frame end
function xmlui.endBuild()
    buildsOpen = buildsOpen - 1
    if buildsOpen > 0 then return end
    local loads = pendingLoads
    pendingLoads = {}
    -- Built whole, anchors and all: a named frame the player moved is put back where they left it (the layout cache)
    -- before any OnLoad, which may ask IsUserPlaced
    local layout = require("layout")
    for _, frame in ipairs(loads) do layout.restore(frame) end
    for _, frame in ipairs(loads) do
        sim.runScript(frame, "OnLoad")
    end
    -- Built already visible, it is shown as far as its own code knows: OnShow follows OnLoad, as in the client
    -- (the personal resource display sets itself up there). Only once every frame built has loaded: a child's
    -- OnShow may call on its parent (the currency transfer's amount selector on its menu's callbacks)
    for _, frame in ipairs(loads) do
        if frame:IsVisible() then sim.runScript(frame, "OnShow") end
    end
end

local depth = 0
---Builds a frame from its element under a parent, children and all, then runs its OnLoad (children first).
buildFrame = function(element, parent, chunkName)
    xmlui.beginBuild()
    local intrinsic = xmlui.intrinsics[element.tag]
    local frameType = (intrinsic and element.tag) or FRAME_TAGS[element.tag] or "Frame"
    local name = substituteParent(element.attrs.name, parent)
    depth = depth + 1
    local frame = W.createFrame(frameType, name, parent, nil, nil, true)
    assignKeys(frame, element.attrs, parent)
    applyFrameElement(frame, element, chunkName)
    depth = depth - 1
    if depth == 0 then
        resolvePendingAnchors()
        applyPendingMasks()
    end
    xmlui.queueLoad(frame)
    xmlui.endBuild()
    return frame
end
xmlui.buildFrame = buildFrame

---After CreateFrame applied XML templates, their anchors and masks are settled before OnLoad runs.
function xmlui.finishTemplates()
    if depth == 0 then
        resolvePendingAnchors()
        applyPendingMasks()
    end
end

---Reads a <Ui> file: scripts and includes in order, fonts, templates (virtual), intrinsic types, and frames.
---@param context { folder: string, name: string, private: table, runLua: fun(path: string, relative: string) }
function xmlui.loadFile(path, context, relativeFolder)
    -- (marked below: a stack walk for the calling addon stops here)
    local root = xml.parseFile(path)
    if not root then
        sim.reportError("Couldn't open " .. path, "")
        return
    end
    local ui = root.children[1]
    if not ui then return end
    local chunkName = path:gsub("^.-/Interface/", "Interface/")
    local handleElement
    handleElement = function(element)
        local tag = element.tag
        if tag == "ScopedModifier" then
            -- Blizzard's wrapper round frames it protects (forbidden="true": the store): its frames are made all the
            -- same, as in the game; the protection itself is not simulated
            for _, child in ipairs(element.children) do handleElement(child) end
        elseif tag == "Script" or tag == "Include" then
            local file = element.attrs.file
            if file then
                local relative = (relativeFolder ~= "" and (relativeFolder .. "\\") or "") .. file:gsub("/", "\\")
                local target = context.findPath(context.folder, relative)
                -- Else from the addon's own folder: an XML in Camelot\ may name "Camelot\PVPMatchScoreboard.lua"
                if not target and relativeFolder ~= "" then
                    local fromRoot = file:gsub("/", "\\")
                    target = context.findPath(context.folder, fromRoot)
                    if target then relative = fromRoot end
                end
                if not target then
                    sim.reportError("Couldn't open " .. context.name .. "\\" .. relative, "")
                elseif tag == "Script" or target:lower():match("%.lua$") then
                    -- An <Include> of a Lua file runs it, as the game does
                    context.runLua(target, relative)
                else
                    xmlui.loadFile(target, context, relative:match("^(.*)\\[^\\]+$") or "")
                end
            elseif element.text then
                local chunk, problem = loadstring(element.text, "@" .. chunkName)
                if chunk then setfenv(chunk, G); sim.call(chunk) else sim.reportError(problem, "") end
            end
        elseif tag == "Font" or tag == "FontFamily" then
            require("fonts").loadGameFontElements({ element }, context.namedColors or {})
        elseif tag == "AnimationGroup" and isTrue(element.attrs.virtual) and element.attrs.name then
            -- An animation group template (the buff frame's warning fader), for groups that inherit it
            xmlui.templates[element.attrs.name] = { element = element, chunkName = chunkName }
        elseif FRAME_TAGS[tag] or REGION_TAGS[tag] or xmlui.intrinsics[tag] then
            local attrs = element.attrs
            if isTrue(attrs.intrinsic) and attrs.name then
                xmlui.intrinsics[attrs.name] = { element = element, chunkName = chunkName, baseType = FRAME_TAGS[tag] or (xmlui.intrinsics[tag] and xmlui.intrinsics[tag].baseType) or "Frame" }
                FRAME_TAGS[attrs.name] = nil
            elseif isTrue(attrs.virtual) and attrs.name then
                xmlui.templates[attrs.name] = { element = element, chunkName = chunkName }
            elseif FRAME_TAGS[tag] or xmlui.intrinsics[tag] then
                -- Without a parent attribute a frame has the one a template it inherits names (ContainerFrame1 from
                -- ContainerFrameTemplate: parent="ContainerFrameContainer", which also lists it), else none, as in the game
                local parentName = attrs.parent
                local function findTemplateParent(names, depth)
                    for templateName in (names or ""):gmatch("[^,%s]+") do
                        local template = xmlui.templates[templateName]
                        local templateAttrs = template and template.element.attrs
                        if templateAttrs and templateAttrs.parent then return templateAttrs.parent end
                        local found = templateAttrs and depth < 20 and findTemplateParent(templateAttrs.inherits, depth + 1)
                        if found then return found end
                    end
                end
                parentName = parentName or findTemplateParent(attrs.inherits, 0)
                local parent = parentName and G[parentName] or nil
                buildFrame(element, parent, chunkName)
            end
        end
    end
    for _, element in ipairs(ui.children) do
        handleElement(element)
    end
end

---An intrinsic type's definition, once per frame; its scripts are kept apart so they run before the frame's own.
function xmlui.applyIntrinsic(frame, typeName)
    local intrinsic = xmlui.intrinsics[typeName]
    local s = S[frame]
    if not intrinsic or s.isIntrinsicApplied then return end
    s.isIntrinsicApplied = true
    local ownScripts = s.scripts
    s.scripts = {}
    applyFrameElement(frame, intrinsic.element, intrinsic.chunkName)
    s.intrinsicScripts = s.scripts
    for scriptName in pairs(s.intrinsicScripts) do W.watchScript(frame, scriptName) end
    for scriptName, handler in pairs(ownScripts) do s.scripts[scriptName] = nil; ownScripts[scriptName] = handler end
    s.scripts = ownScripts
end

function W.getIntrinsic(typeName)
    for name, intrinsic in pairs(xmlui.intrinsics) do
        if name:lower() == tostring(typeName):lower() then return intrinsic end
    end
end
W.applyIntrinsic = function(frame, typeName)
    local intrinsic = W.getIntrinsic(typeName)
    if intrinsic then
        for name, candidate in pairs(xmlui.intrinsics) do
            if candidate == intrinsic then return xmlui.applyIntrinsic(frame, name) end
        end
    end
end
W.finishTemplates = xmlui.finishTemplates
function W.getTemplate(name) return xmlui.templates[name] end

---What C_XMLUtil.GetTemplateInfo answers: the template's frame type, size and key values, inherited ones included.
function xmlui.getTemplateInfo(templateName)
    local template = xmlui.templates[templateName]
    if not template then return nil end
    local info = { type = template.element.tag, width = 0, height = 0, keyValues = {}, inherits = template.element.attrs.inherits,
        sourceLocation = template.chunkName }
    local seen = {}
    local function collect(element)
        for parentName in (element.attrs.inherits or ""):gmatch("[^,%s]+") do
            local parentTemplate = xmlui.templates[parentName]
            if parentTemplate and not seen[parentName] then
                seen[parentName] = true
                collect(parentTemplate.element)
            end
        end
        for _, child in ipairs(element.children) do
            if child.tag == "Size" then
                local x, y = readDimension(child)
                info.width, info.height = x or info.width, y or info.height
            elseif child.tag == "KeyValues" then
                for _, keyValue in ipairs(child.children) do
                    if keyValue.tag == "KeyValue" then
                        info.keyValues[#info.keyValues + 1] = { key = keyValue.attrs.key, keyType = keyValue.attrs.keyType or "string",
                            type = keyValue.attrs.type or "string", value = keyValue.attrs.value or "" }
                    end
                end
            end
        end
    end
    collect(template.element)
    return info
end

G.C_XMLUtil = G.C_XMLUtil or {}
G.C_XMLUtil.GetTemplateInfo = xmlui.getTemplateInfo
G.C_XMLUtil.GetTemplates = function()
    local list = {}
    for name, template in pairs(xmlui.templates) do list[#list + 1] = { name = name, type = template.element.tag } end
    return list
end
sim.stackBoundaries[xmlui.loadFile] = true

return xmlui
