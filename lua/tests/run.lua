-- Every Lua test that needs nothing of the game, each in a LuaJIT of its own (each ends with os.exit): the one list of
-- them, for `bun run test:lua` and CI. Run from the repository's root: `luajit lua/tests/run.lua`.
local TESTS = { "encoding", "bootcache", "colorutil", "stringutil", "audiofile" }

local luajit = arg and arg[-1] or "luajit"
local failed = {}
for _, name in ipairs(TESTS) do
    local status = os.execute(string.format('"%s" lua/tests/%s.lua', luajit, name))
    -- (a number in Lua 5.1, true in a LuaJIT built with 5.2's ways)
    if status ~= 0 and status ~= true then
        failed[#failed + 1] = name
    end
end
if #failed > 0 then
    print("FAILED: " .. table.concat(failed, ", "))
    os.exit(1)
end
print(string.format("all %d Lua test files passed", #TESTS))
