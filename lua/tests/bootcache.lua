-- The boot cache's file keys (lua/bootcache.lua): on Windows, Linux and macOS a file's key comes from its write time
-- and size without reading it, and changes when the file does. Needs nothing of the game:
-- `luajit lua/tests/bootcache.lua` from the repository's root (CI runs it on Linux and macOS).
package.path = "lua/?.lua;" .. package.path
local bootcache = require("bootcache")
local ffi = require("ffi")

local failures, checks = 0, 0
local function check(isTrue, what)
    checks = checks + 1
    if not isTrue then
        failures = failures + 1
        print("FAIL  " .. what)
    end
end

local folder = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
folder = folder:gsub("\\", "/")
local path = folder .. "/addonsim-bootcache-test-" .. tostring(os.time()) .. ".txt"
local function writeFile(content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

local isUsable = bootcache.checkFileData(folder)
print(("%s %s: file keys from %s"):format(ffi.os, ffi.arch, isUsable and "the file's time and size" or "its content"))
check(isUsable, "the system's file data is read (" .. ffi.os .. " " .. ffi.arch .. ")")

writeFile("first")
local first = bootcache.fileKey(path)
check(first ~= nil, "a file has a key")
check(bootcache.fileKey(path) == first, "the same key while the file is unchanged")
writeFile("second, longer")
local second = bootcache.fileKey(path)
check(second ~= nil and second ~= first, "a changed file has another key")
check(bootcache.fileKey(path .. ".missing") == nil, "a missing file has none")
os.remove(path)

-- Values kept as Lua that rebuilds them
local value = { 1, 2, { name = "x", [10] = true }, ratio = 0.1, huge = 1 / 0 }
local rebuilt = loadstring(bootcache.serialize(value))()
check(
    rebuilt[3].name == "x" and rebuilt[3][10] == true and rebuilt.ratio == 0.1 and rebuilt.huge == 1 / 0,
    "a value kept as Lua rebuilds as it was"
)

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
