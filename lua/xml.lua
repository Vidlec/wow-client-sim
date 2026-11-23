-- XML for the game's interface files: elements with attributes, children and text. Comments, the declaration
-- and CDATA (inline scripts) are handled; entities in attributes and text are decoded.
local xml = {}

local ENTITIES = { quot = '"', amp = "&", lt = "<", gt = ">", apos = "'" }
local function decode(text)
    return (text:gsub("&(#?x?%w+);", function(entity)
        if ENTITIES[entity] then return ENTITIES[entity] end
        local hex = entity:match("^#x(%x+)$")
        local number = hex and tonumber(hex, 16) or tonumber(entity:match("^#(%d+)$") or "")
        if number and number < 128 then return string.char(number) end
        return "&" .. entity .. ";"
    end))
end

---@return { tag: string, attrs: table, children: table[], text: string? } root A synthetic root holding the top elements
function xml.parse(content)
    local root = { tag = "#root", attrs = {}, children = {} }
    local stack = { root }
    local position, length = 1, #content
    while position <= length do
        local open = content:find("<", position, true)
        if not open then break end
        if open > position then
            local text = content:sub(position, open - 1)
            if text:match("%S") then
                local current = stack[#stack]
                current.text = (current.text or "") .. decode(text)
            end
        end
        if content:sub(open, open + 3) == "<!--" then
            local close = content:find("-->", open + 4, true)
            position = (close or length) + 3
        elseif content:sub(open, open + 8) == "<![CDATA[" then
            local close = content:find("]]>", open + 9, true) or length
            local current = stack[#stack]
            current.text = (current.text or "") .. content:sub(open + 9, close - 1)
            position = close + 3
        elseif content:sub(open, open + 1) == "<?" or content:sub(open, open + 1) == "<!" then
            local close = content:find(">", open, true)
            position = (close or length) + 1
        elseif content:sub(open, open + 1) == "</" then
            local close = content:find(">", open, true) or length
            local tag = content:sub(open + 2, close - 1):match("^%s*([%w_:%.%-]+)")
            -- Close up to the matching element; a stray closing tag is ignored
            for index = #stack, 2, -1 do
                if stack[index].tag == tag then
                    for _ = #stack, index, -1 do table.remove(stack) end
                    break
                end
            end
            position = close + 1
        else
            -- An opening tag: find its end, minding quoted attribute values that may hold ">"
            -- (from quote to quote to the ">", with finds: not a character at a time)
            local index, quote = open + 1, nil
            while true do
                if quote then
                    local closing = content:find(quote, index, true)
                    if not closing then index = length + 1; break end
                    index, quote = closing + 1, nil
                else
                    local found = content:find("[>\"']", index)
                    if not found then index = length + 1; break end
                    local character = content:sub(found, found)
                    if character == ">" then index = found; break end
                    index, quote = found + 1, character
                end
            end
            local inner = content:sub(open + 1, index - 1)
            local isSelfClosing = inner:sub(-1) == "/"
            if isSelfClosing then inner = inner:sub(1, -2) end
            local tag = inner:match("^([%w_:%.%-]+)")
            if tag then
                local element = { tag = tag, attrs = {}, children = {} }
                for name, valueQuote, value in inner:gmatch("([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2") do
                    element.attrs[name] = decode(value)
                end
                local parent = stack[#stack]
                parent.children[#parent.children + 1] = element
                element.parent = parent
                if not isSelfClosing then stack[#stack + 1] = element end
            end
            position = index + 1
        end
    end
    return root
end

-- (each element's parent: left out of what is kept between runs, a tree being kept without its loops, and put
-- back on reading)
local function setParents(element, parent)
    element.parent = parent
    for _, child in ipairs(element.children) do setParents(child, element) end
end
local function clearParents(element)
    element.parent = nil
    for _, child in ipairs(element.children) do clearParents(child) end
end

---Parses a file, the tree kept between runs while the file is unchanged (bootcache).
function xml.parseFile(path)
    local function read()
        local file = io.open(path, "rb")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        return content
    end
    local root = require("bootcache").rememberFile("xml-" .. (path:match("([^/\\]+)$") or "file"), path, read, function(content)
        if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end
        local tree = xml.parse(content)
        clearParents(tree)
        return tree
    end)
    if root then setParents(root, nil) end
    return root
end

---@return table? child The first child with this tag
function xml.child(element, tag)
    for _, child in ipairs(element.children) do
        if child.tag == tag then return child end
    end
end

return xml
