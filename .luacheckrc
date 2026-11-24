-- luacheck (the Lua linter) for AddonSim: bun run lint:lua. Formatting is StyLua's (stylua.toml); this looks for
-- mistakes: globals made or read by accident, unused variables and values, redefinitions, unreachable code.
std = "luajit"
max_line_length = false -- StyLua's (stylua.toml): what it cannot wrap (a long string) stays as written
ignore = {
    "212", -- an unused argument: callbacks and methods keep the signature the game or the caller gives them
    "42.", -- shadowing a local, and
    "43.", -- an upvalue: closures here reuse a name on purpose (self in nested widget methods, state)
    "542", -- an empty if branch: written for its comment, saying what is left alone
    "581", -- "not (x == y)": sometimes written so on purpose
}
exclude_files = { "lua/vendor/**", "node_modules/**" }

-- The sandbox's own files replace parts of the standard library on purpose (the game's print, a project's dofile)
files["lua/sdkplay.lua"] = { globals = { "print", "dofile", "loadfile", "arg", "io", "os" } }
files["lua/play.lua"] = { globals = { "coroutine" } }
files["lua/luaextensions.lua"] = { globals = { "string" } }

-- Scenarios run with the simulator's steps as globals (moveTo, wait, expect...): read from their declarations for
-- the language server (types/addonsim.lua), so the two never disagree
local steps = {}
local declarations = io.open("types/addonsim.lua")
if declarations then
    for line in declarations:lines() do
        local name = line:match("^function ([%a_][%w_]*)%(") or line:match("^([%a_][%w_]*) = ")
        if name then
            steps[#steps + 1] = name
        end
    end
    declarations:close()
end
-- (and the simulator's own tables a scenario may reach: sim, combat)
steps[#steps + 1] = "sim"
steps[#steps + 1] = "combat"
steps[#steps + 1] = "fixtureHeard" -- (the fixture project's plugin adds this step: scenarios/project-and-plugins.lua)
files["scenarios/**"] = { read_globals = steps }
-- The fixture addon is game code: the few game globals it uses, and its own
files["scenarios/fixtures/addons/**"] = {
    read_globals = { "CreateFrame", "UIParent", "GameTooltip", "Minimap", "C_QuestLog", "wipe", "GetLocale" },
    globals = { "SimFixtureDB", "fixtureHeard", "SlashCmdList", "SLASH_SIMFIXTURE1", "LibQuestieDB" },
}
-- A recording as the recorder addon saves it (its saved variable)
files["scenarios/fixtures/sample-recording.lua"] = { globals = { "AddonSimRecording" } }
files["tools/**"] = { globals = { "arg" } }
