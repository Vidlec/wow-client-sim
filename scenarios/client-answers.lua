-- The client's answers to what addons ask (EllesmereUI's 12.x calls among them), as the simulator now gives them
-- rather than stand-ins: durations and the bars and cooldowns that run on them, heal prediction, raid target marks,
-- console variables' bit fields, documented enumerations (a value they do not name is nil), a texture's own scripts,
-- SetAlphaGradient's answer, a warrior's stances.
local W = require("widgets")

-- A duration: a span of the game's clock, how much is gone and left
local duration = G.C_DurationUtil.CreateDuration()
duration:SetTimeFromStart(G.GetTime(), 10)
wait(2.5)
expect(math.abs(duration:GetElapsedDuration() - 2.5) < 0.05, "2.5 s of 10 gone: " .. duration:GetElapsedDuration())
expect(math.abs(duration:GetRemainingPercent() - 0.75) < 0.01, "three quarters left")
expect(duration:IsActive() and not duration:HasExpired() and not duration:IsZero(), "running")
local copy = duration:Copy()
expect(copy:GetEndTime() == duration:GetEndTime(), "a copy is the same span")

-- A curve, numbers and colours, read off its points
local curve = G.C_CurveUtil.CreateCurve()
curve:AddPoint(0, 0)
curve:AddPoint(10, 100)
expect(curve:Evaluate(2.5) == 25, "a curve read between its points: " .. tostring(curve:Evaluate(2.5)))
expect(duration:EvaluateElapsedDuration(curve) > 24, "a duration read through a curve")
local colors = G.C_CurveUtil.CreateColorCurve()
colors:AddPoint(0, G.CreateColor(1, 0, 0, 1))
colors:AddPoint(1, G.CreateColor(0, 0, 1, 1))
local r, _, b = colors:EvaluateUnpacked(0.5)
expect(math.abs(r - 0.5) < 0.01 and math.abs(b - 0.5) < 0.01, "a colour curve blends")
expect(G.C_CurveUtil.EvaluateColorValueFromBoolean(true, 0.8, 0.2) == 0.8, "a value by a boolean")

-- A status bar on a timer: its value the time gone, as it goes
local bar = G.CreateFrame("StatusBar", nil, G.UIParent)
bar:SetSize(100, 10)
bar:SetPoint("CENTER")
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetMinMaxValues(0, 10)
local timer = G.C_DurationUtil.CreateDuration()
timer:SetTimeFromStart(G.GetTime(), 10)
bar:SetTimerDuration(timer)
wait(4)
expect(math.abs(bar:GetValue() - 4) < 0.1, "a timer bar's value is the time gone: " .. bar:GetValue())
local barItem
for _, item in ipairs(require("scene").export()) do
    if item.i == W.state[bar:GetStatusBarTexture()].id then
        barItem = item
    end
end
expect(barItem and math.abs(barItem.tc[2] - 0.4) < 0.02, "and drawn so: 40% filled")

-- A cooldown from a duration
local cooldown = G.CreateFrame("Cooldown", nil, G.UIParent)
cooldown:SetCooldownFromDurationObject(timer)
local start, length = cooldown:GetCooldownTimes()
expect(length == 10000, "a cooldown takes a duration's span: " .. length)
cooldown:SetCooldownFromDurationObject(G.C_DurationUtil.CreateDuration())
expect(select(2, cooldown:GetCooldownTimes()) == 0 and start > 0, "a zero one clears it")

-- Heal prediction: the player's health, nothing incoming or absorbed
local calculator = G.CreateUnitHealPredictionCalculator()
calculator:SetMaximumHealthMode(1)
G.UnitGetDetailedHealPrediction("player", nil, calculator)
local values = calculator:GetPredictedValues()
expect(values.healthMax > 0 and values.health == G.UnitHealth("player"), "the player's health is predicted from")
expect(calculator:GetDamageAbsorbs() == 0 and calculator:GetIncomingHeals() == 0, "no absorbs, no heals incoming")

-- A raid target mark: one unit a mark
G.SetRaidTarget("player", 8)
expect(G.GetRaidTargetIndex("player") == 8, "the skull on the player")
G.SetRaidTarget("player", 0)
expect(G.GetRaidTargetIndex("player") == nil, "and off")

-- A console variable as a bit field
G.SetCVar("closedInfoFrames", "0")
G.C_CVar.SetCVarBitfield("closedInfoFrames", 3, true)
expect(G.GetCVar("closedInfoFrames") == "4" and G.C_CVar.GetCVarBitfield("closedInfoFrames", 3), "bit 3 is 4")

-- Documented enumerations name all of this client's values
expect(G.Enum.ItemWeaponSubclass.Bows == 2 and G.Enum.ItemWeaponSubclass.Bow == nil, "Bows is 2, Bow is none")

-- A texture's own OnShow and OnHide
local shownCount = 0
local texture = G.UIParent:CreateTexture()
texture:HookScript("OnHide", function()
    shownCount = shownCount + 1
end)
texture:Hide()
expect(shownCount == 1, "a texture's OnHide runs")

-- SetAlphaGradient: true while the character is within the text (the quest window reveals till it is not)
local text = G.UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
text:SetText("Hello")
expect(text:SetAlphaGradient(2, 10) == true and text:SetAlphaGradient(5, 10) == false, "within, then past the text")

-- The client's own numbers, where the recorder measured them (/asrec api, /asrec probe; none without a recording)
local recorded = require("sim").recordedProbe
if recorded and recorded.worldAnswers and recorded.worldAnswers.hasSpecializationInfoForClassID then
    expect(G.Enum.GameRule.EncounterJournalDisabled == 42 and G.Enum.GameRule.EnableAmmoSystem == 177, "game rules")
    local specId, name, _, _, role, isRecommended, isAllowed = G.GetSpecializationInfoForClassID(1, 1)
    expect(specId == 1491 and name == "Warrior" and role == "DAMAGER", "a warrior's one specialization")
    expect(isRecommended == false and isAllowed == false, "neither recommended nor allowed, as the client answers")
end
