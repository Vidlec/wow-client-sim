--@login race=Orc,class=WARRIOR,level=20
-- A warrior's stances, as the client gives them: those the spell book has (Battle Stance from the start, Defensive
-- from level 10, Berserker from 30), Battle Stance taken; the game's stance bar shows them
expect(G.GetNumShapeshiftForms() == 2, "two stances at level 20: " .. G.GetNumShapeshiftForms())
local icon, isActive, isCastable, spellId = G.GetShapeshiftFormInfo(1)
expect(isActive and isCastable and spellId == 2457 and icon ~= nil, "Battle Stance, taken")
expect(G.GetShapeshiftForm() == 1 and G.GetShapeshiftFormID() == 17, "its form id 17")
G.CastShapeshiftForm(2)
expect(G.GetShapeshiftForm() == 2 and G.GetShapeshiftFormID() == 18, "Defensive Stance taken")
