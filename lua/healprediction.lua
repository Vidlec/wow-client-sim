-- Heal prediction, as the client works it out for unit frames: a calculator (CreateUnitHealPredictionCalculator) told
-- how to clamp and count (its modes), filled for a unit by UnitGetDetailedHealPrediction from the unit's health,
-- absorbs and incoming heals, then read (GetPredictedValues, GetDamageAbsorbs...). In the simulated world nobody is
-- healing or shielding anyone, so absorbs and incoming heals are what the units give (none, unless the battle says).
local healprediction = {}

function healprediction.install(G)
    local function number(value)
        return tonumber(value) or 0
    end
    local function totalAbsorbs(unit)
        return G.UnitGetTotalAbsorbs and number(G.UnitGetTotalAbsorbs(unit)) or 0
    end

    -- Heal absorbs (a debuff that eats healing): none here
    G.UnitGetTotalHealAbsorbs = function()
        return 0
    end
    if not G.UnitGetIncomingHeals then
        G.UnitGetIncomingHeals = function()
            return 0
        end
    end
    -- How much a unit's maximum health is changed by effects, as a share (0: unchanged)
    G.GetUnitTotalModifiedMaxHealthPercent = function()
        return 0
    end

    local calculatorMethods = {}
    calculatorMethods.__index = calculatorMethods
    local function defaults(calculator)
        calculator.damageAbsorbClampMode = 0 -- MissingHealth
        calculator.healAbsorbClampMode = 0 -- CurrentHealth
        calculator.healAbsorbMode = 0 -- ReducedByIncomingHeals
        calculator.incomingHealClampMode = 0 -- MissingHealth
        calculator.maximumHealthMode = 0 -- Default
        calculator.incomingHealOverflowPercent = 0
        calculator.values = {
            health = 0,
            healthMax = 0,
            totalIncomingHeals = 0,
            totalIncomingHealsFromHealer = 0,
            totalDamageAbsorbs = 0,
            totalHealAbsorbs = 0,
        }
    end
    G.CreateUnitHealPredictionCalculator = function()
        local calculator = setmetatable({}, calculatorMethods)
        defaults(calculator)
        return calculator
    end
    for _, mode in ipairs({
        "DamageAbsorbClampMode",
        "HealAbsorbClampMode",
        "HealAbsorbMode",
        "IncomingHealClampMode",
        "MaximumHealthMode",
        "IncomingHealOverflowPercent",
    }) do
        local key = mode:sub(1, 1):lower() .. mode:sub(2)
        calculatorMethods["Set" .. mode] = function(self, value)
            self[key] = value
        end
        calculatorMethods["Get" .. mode] = function(self)
            return self[key]
        end
    end
    function calculatorMethods:SetToDefaults()
        defaults(self)
    end
    function calculatorMethods:Reset()
        local values = self.values
        for key in pairs(values) do
            values[key] = 0
        end
    end
    calculatorMethods.ResetPredictedValues = calculatorMethods.Reset
    function calculatorMethods:SetPredictedValues(values)
        for key in pairs(self.values) do
            self.values[key] = number(values and values[key])
        end
    end
    function calculatorMethods:GetPredictedValues()
        local copy = {}
        for key, value in pairs(self.values) do
            copy[key] = value
        end
        return copy
    end
    function calculatorMethods:HasSecretValues()
        return false
    end
    -- The maximum the frame shows: with the absorbs on top, when told so (WithAbsorbs)
    function calculatorMethods:GetMaximumHealth()
        local values = self.values
        if self.maximumHealthMode == 1 then
            return math.max(values.healthMax, values.health + values.totalDamageAbsorbs)
        end
        return values.healthMax
    end
    function calculatorMethods:GetCurrentHealth()
        return self.values.health
    end
    function calculatorMethods:GetMissingHealth()
        return math.max(0, self:GetMaximumHealth() - self.values.health)
    end
    function calculatorMethods:GetCurrentHealthPercent()
        local maximum = self:GetMaximumHealth()
        return maximum > 0 and self.values.health / maximum or 0
    end
    function calculatorMethods:GetMissingHealthPercent()
        local maximum = self:GetMaximumHealth()
        return maximum > 0 and self:GetMissingHealth() / maximum or 0
    end
    function calculatorMethods:EvaluateCurrentHealthPercent(curve)
        return curve and curve.Evaluate and curve:Evaluate(self:GetCurrentHealthPercent())
            or self:GetCurrentHealthPercent()
    end
    function calculatorMethods:EvaluateMissingHealthPercent(curve)
        return curve and curve.Evaluate and curve:Evaluate(self:GetMissingHealthPercent())
            or self:GetMissingHealthPercent()
    end
    -- Incoming heals: clamped to the missing health, or the maximum
    function calculatorMethods:GetMaximumIncomingHeals()
        if self.incomingHealClampMode == 1 then
            return self:GetMaximumHealth()
        end
        return self:GetMissingHealth()
    end
    function calculatorMethods:GetIncomingHeals()
        local total, fromHealer = self.values.totalIncomingHeals, self.values.totalIncomingHealsFromHealer
        local maximum = self:GetMaximumIncomingHeals()
        local amount = math.min(total, maximum)
        local share = total > 0 and amount / total or 0
        return amount, fromHealer * share, (total - fromHealer) * share, amount < total
    end
    function calculatorMethods:GetTotalIncomingHeals()
        return self.values.totalIncomingHeals
    end
    function calculatorMethods:GetTotalIncomingHealsFromHealer()
        return self.values.totalIncomingHealsFromHealer
    end
    -- Damage absorbs (shields): clamped to the missing health (less the incoming heals), or the maximum
    function calculatorMethods:GetMaximumDamageAbsorbs()
        local mode = self.damageAbsorbClampMode
        if mode == 2 then
            return self:GetMaximumHealth()
        elseif mode == 1 then
            return self:GetMissingHealth()
        end
        return math.max(0, self:GetMissingHealth() - (self:GetIncomingHeals()))
    end
    function calculatorMethods:GetDamageAbsorbs()
        local total, maximum = self.values.totalDamageAbsorbs, self:GetMaximumDamageAbsorbs()
        return math.min(total, maximum), total > maximum
    end
    function calculatorMethods:GetTotalDamageAbsorbs()
        return self.values.totalDamageAbsorbs
    end
    -- Heal absorbs: clamped to the current health, or the maximum; less the incoming heals unless counted whole
    function calculatorMethods:GetMaximumHealAbsorbs()
        if self.healAbsorbClampMode == 1 then
            return self:GetMaximumHealth()
        end
        return self.values.health
    end
    function calculatorMethods:GetHealAbsorbs()
        local total = self.values.totalHealAbsorbs
        if self.healAbsorbMode == 0 then
            total = math.max(0, total - self.values.totalIncomingHeals)
        end
        local maximum = self:GetMaximumHealAbsorbs()
        return math.min(total, maximum), total > maximum
    end
    function calculatorMethods:GetTotalHealAbsorbs()
        return self.values.totalHealAbsorbs
    end

    G.UnitGetDetailedHealPrediction = function(unit, healerUnit, calculator)
        if getmetatable(calculator) ~= calculatorMethods then
            return
        end
        local values = calculator.values
        values.health = number(G.UnitHealth and G.UnitHealth(unit))
        values.healthMax = number(G.UnitHealthMax and G.UnitHealthMax(unit))
        values.totalIncomingHeals = number(G.UnitGetIncomingHeals(unit))
        values.totalIncomingHealsFromHealer = healerUnit and number(G.UnitGetIncomingHeals(unit, healerUnit)) or 0
        values.totalDamageAbsorbs = totalAbsorbs(unit)
        values.totalHealAbsorbs = number(G.UnitGetTotalHealAbsorbs(unit))
    end
end

return healprediction
