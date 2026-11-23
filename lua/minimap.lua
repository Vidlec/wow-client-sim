-- The minimap as the game draws it: the land round the player from the game's own minimap tiles (one per
-- 533⅓-yard block of the continent, world/minimaps/<continent>/mapXX_YY), cut round, the player's arrow turned
-- to their facing, party members as class-coloured blips, and the zoom levels' view radii.
local sim = require("sim")
local W = require("widgets")
local game = require("game")

local minimap = {}
local G = sim.G
local S = W.state

local BLOCK_YARDS = 1600 / 3 -- one tile of a continent
-- Yards from the centre to the edge at each zoom level, outdoors (C_Minimap.GetViewRadius)
local VIEW_RADII = { 1400 / 6, 200, 1000 / 6, 800 / 6, 100, 400 / 6 }
local MAX_TILES = 16

---@param directories table<number, string> The continents' folders by map id (Map.db2 Directory): 0 Azeroth...
function minimap.install(directories)
    local frame = G.Minimap
    if not frame then return end
    local zoom = 0

    -- The game's zoom: levels 0 (widest) to 5, and the view radius each gives
    local methods = W.types.Minimap.methods
    methods.SetZoom = function(self, level)
        local newZoom = math.max(0, math.min(#VIEW_RADII - 1, math.floor(tonumber(level) or 0)))
        if newZoom ~= zoom then
            zoom = newZoom
            sim.touch()
            sim.fireEvent("MINIMAP_UPDATE_ZOOM")
        end
    end
    methods.GetZoom = function() return zoom end
    methods.GetZoomLevels = function() return #VIEW_RADII end
    G.C_Minimap.GetViewRadius = function() return VIEW_RADII[zoom + 1] end
    G.Minimap_ZoomIn = function() frame:SetZoom(zoom + 1) end
    G.Minimap_ZoomOut = function() frame:SetZoom(zoom - 1) end
    -- The wheel over the minimap zooms, as in the game
    if not sim.isWholeInterface then
        frame:EnableMouseWheel(true)
        frame:SetScript("OnMouseWheel", function(self, delta) self:SetZoom(zoom + (delta > 0 and 1 or -1)) end)
    end
    -- Hovered, the game's minimap rebuilds its tooltip at the cursor every frame (Blizzard_Minimap, MinimapMixin:OnEnter
    -- and Minimap_OnUpdate): what is under the cursor, which addons add to by hooking Minimap_OnUpdate
    G.GameTooltip.SetMinimapMouseover = G.GameTooltip.SetMinimapMouseover or function(tooltip)
        -- The simulator's blips have no names to list: as the game's with nothing under the cursor (no tooltip
        -- data), the tooltip is hidden, which lets go of its owner
        tooltip:Hide()
    end
    G.Minimap_OnUpdate = function()
        G.GameTooltip:SetOwner(G.UIParent, "ANCHOR_CURSOR")
        G.GameTooltip:SetMinimapMouseover()
    end
    -- The game's own minimap (the whole interface) has its own handlers from Blizzard_Minimap; the simulator's stands in
    if not sim.isWholeInterface then
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", G.Minimap_OnUpdate) end)
        frame:SetScript("OnLeave", function(self)
            self:SetScript("OnUpdate", nil)
            G.GameTooltip:Hide()
        end)
    end

    -- The round cut (the game's own is ui-hud-minimap-frame-generic-mask, a circle), and the land under it
    local mask = frame:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    mask:SetAllPoints(frame)
    -- The minimap's own background regions are round too
    for _, region in ipairs({ frame:GetRegions() }) do
        if region ~= mask and region:GetObjectType() == "Texture" and region:GetDrawLayer() == "BACKGROUND" then region:AddMaskTexture(mask) end
    end
    local tiles = {}
    local function getTile(index)
        local tile = tiles[index]
        if not tile then
            tile = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
            tile:AddMaskTexture(mask)
            tiles[index] = tile
        end
        return tile
    end

    local arrow = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    arrow:SetSize(32, 32)
    W.state[arrow].markRole = "player"
    W.state[arrow].markInset = 0.19 -- the arrow's art fills the middle 20 of its 32 pixels (MinimapArrow.blp)
    arrow:SetPoint("CENTER", frame, "CENTER")

    local blips = {}
    local function getBlip(index)
        local blip = blips[index]
        if not blip then
            blip = frame:CreateTexture(nil, "OVERLAY", nil, 5)
            blip:SetAtlas("PlayerPartyBlip")
            blip:SetSize(14, 14)
            W.state[blip].markRole = "party"
            blips[index] = blip
        end
        return blip
    end

    local lastKey
    local function update()
        local profile = game.profile
        local continentId, north, west = game.getPlayerWorldPosition()
        local party = require("party")
        -- With "rotate minimap" on, the land turns so that ahead is up, and the arrow stays pointing up
        local isRotating = G.GetCVar and G.GetCVar("rotateMinimap") == "1"
        local turn = isRotating and (profile.facing or 0) or 0
        local function rotate(right, up)
            if turn == 0 then return right, up end
            local sine, cosine = math.sin(turn), math.cos(turn)
            return right * cosine + up * sine, -right * sine + up * cosine
        end
        local key = table.concat({ tostring(isRotating), tostring(continentId), tostring(north), tostring(west), zoom, profile.facing or 0, #party.members,
            frame:GetWidth() }, "|")
        for _, member in ipairs(party.members) do key = key .. "|" .. member.uiMapId .. ":" .. member.x .. ":" .. member.y end
        if key == lastKey then return end
        lastKey = key
        arrow:SetRotation(isRotating and 0 or (profile.facing or 0))
        local directory = continentId and directories[continentId]
        local radius = frame:GetWidth() / 2
        local yardsToPixels = radius / VIEW_RADII[zoom + 1]
        local used = 0
        if directory and north then
            -- Tiles are numbered from the continent's north-west corner: column grows eastward, row southward
            local column = 32 - west / BLOCK_YARDS
            local row = 32 - north / BLOCK_YARDS
            local reach = VIEW_RADII[zoom + 1] / BLOCK_YARDS
            local tilePixels = BLOCK_YARDS * yardsToPixels
            for tileRow = math.floor(row - reach), math.floor(row + reach) do
                for tileColumn = math.floor(column - reach), math.floor(column + reach) do
                    if used < MAX_TILES and tileRow >= 0 and tileRow < 64 and tileColumn >= 0 and tileColumn < 64 then
                        used = used + 1
                        local tile = getTile(used)
                        tile:SetTexture(string.format("World\\Minimaps\\%s\\map%02d_%02d", directory, tileColumn, tileRow))
                        tile:SetSize(tilePixels + 1, tilePixels + 1) -- a pixel over the next tile, so no seam shows
                        tile:ClearAllPoints()
                        -- The tile's middle, turned about the player with the land
                        local right, up = rotate((tileColumn + 0.5 - column) * tilePixels, -(tileRow + 0.5 - row) * tilePixels)
                        tile:SetPoint("CENTER", frame, "CENTER", right, up)
                        tile:SetRotation(-turn)
                        tile:Show()
                    end
                end
            end
        end
        for index = used + 1, #tiles do tiles[index]:Hide() end

        -- Party members within the circle
        local shown = 0
        for _, member in ipairs(party.members) do
            local memberContinent, memberNorth, memberWest = game.mapToWorld(member.uiMapId, member.x, member.y)
            if north and memberContinent == continentId and member.isOnline then
                local right, down = (west - memberWest) * yardsToPixels, (north - memberNorth) * yardsToPixels
                if right * right + down * down <= (radius - 4) * (radius - 4) then
                    shown = shown + 1
                    local blip = getBlip(shown)
                    local color = G.RAID_CLASS_COLORS and G.RAID_CLASS_COLORS[member.classFile]
                    blip:SetVertexColor(color and color.r or 1, color and color.g or 1, color and color.b or 1)
                    blip:ClearAllPoints()
                    local turnedRight, turnedUp = rotate(right, -down)
                    blip:SetPoint("CENTER", frame, "CENTER", turnedRight, turnedUp)
                    blip:Show()
                end
            end
        end
        for index = shown + 1, #blips do blips[index]:Hide() end
    end
    minimap.update = update
    local updater = W.createFrame("Frame", nil, frame)
    updater:SetScript("OnUpdate", update)
    update()
end

return minimap
