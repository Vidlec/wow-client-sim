-- The game's own dropdown and menu (Blizzard_Menu, loaded from the client's interface files) work in the
-- simulator: it opens on a click, lists its entries, scrolls a long list, and picking an entry runs its callback
-- and closes the menu.
local picked
local dropdown = G.CreateFrame("DropdownButton", nil, G.UIParent, "WowStyle1DropdownTemplate")
dropdown:SetPoint("TOP", G.UIParent, "TOP", 0, -40)
dropdown:SetWidth(150)
dropdown:SetupMenu(function(_, root)
    root:CreateTitle("Pick one")
    for index = 1, 5 do
        root:CreateRadio("Entry " .. index, function() return picked == index end, function() picked = index end)
    end
end)

click(dropdown)
wait(0.2)
expectText("Pick one", "the menu's title shows")
expectText("Entry 5", "every entry shows")
click("Entry 3")
wait(0.2)
expect(picked == 3, "picking an entry runs its callback")
expectNoText("Entry 4", "the menu closes after picking")

-- A long menu scrolls, as the game's does: only what fits is made
local long = G.CreateFrame("DropdownButton", nil, G.UIParent, "WowStyle1DropdownTemplate")
long:SetPoint("TOP", G.UIParent, "TOP", 0, -40)
long:SetupMenu(function(_, root)
    root:SetScrollMode(200)
    for index = 1, 30 do root:CreateButton("Row " .. index, function() end) end
end)
click(long)
wait(0.2)
expectText("Row 1", "a long menu starts at the top")
expectNoText("Row 30", "rows past the scroll height are not shown")
