-- A module of the self-test project's luaPath (scenarios/fixtures/lib): what its plugin and scenarios share. Found by
-- require("fixturelib") before the simulator's own modules, and made afresh at a reload as they are.
local sim = require("sim")

local fixturelib = { heard = {}, left = {} }

---Keeps every addon message on a prefix that reaches the player's side (CHAT_MSG_ADDON).
function fixturelib.listen(prefix)
    local frame = sim.G.CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, messagePrefix, text, channel, sender)
        if messagePrefix == prefix then
            fixturelib.heard[#fixturelib.heard + 1] = { text = text, channel = channel, sender = sender }
        end
    end)
end

return fixturelib
