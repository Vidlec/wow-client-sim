-- Rested experience, as addons read it: set on the character (setProfile restedXp, the page's character editor),
-- answered by GetXPExhaustion and GetRestState, told by UPDATE_EXHAUSTION, and drawn by the game's experience bar
-- with its rested fill (without a rest state the bar kept the plain grey status bar texture).
local heard = 0
local listener = G.CreateFrame("Frame")
listener:RegisterEvent("UPDATE_EXHAUSTION")
listener:SetScript("OnEvent", function()
    heard = heard + 1
end)
local function experienceFill()
    local function find(frame)
        for _, child in ipairs({ frame:GetChildren() }) do
            if child.GetStatusBarTexture and child:IsVisible() then
                return child:GetStatusBarTexture():GetAtlas()
            end
            local found = find(child)
            if found then
                return found
            end
        end
    end
    return find(G.MainStatusTrackingBarContainer)
end

expect(G.GetXPExhaustion() == nil and G.GetRestState() == 2, "not rested at first: no exhaustion, state 2 (normal)")
expect(
    experienceFill() == "UI-HUD-ExperienceBar-Fill-Experience",
    "the bar's own fill (" .. tostring(experienceFill()) .. ")"
)

setProfile({ restedXp = 5000 })
wait(0.2)
expect(G.GetXPExhaustion() == 5000, "GetXPExhaustion gives the rested experience")
local state, name, multiplier = G.GetRestState()
expect(state == 1 and name == "Rested" and multiplier == 2, "rested: state 1, twice the experience")
expect(heard >= 1, "UPDATE_EXHAUSTION is heard")
expect(
    experienceFill() == "UI-HUD-ExperienceBar-Fill-Rested",
    "the bar's rested fill (" .. tostring(experienceFill()) .. ")"
)

setProfile({ restedXp = 0 })
wait(0.2)
expect(G.GetXPExhaustion() == nil and G.GetRestState() == 2, "no longer rested")
expect(experienceFill() == "UI-HUD-ExperienceBar-Fill-Experience", "the bar's own fill again")
