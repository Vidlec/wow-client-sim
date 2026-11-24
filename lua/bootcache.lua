-- What the boot works out from files that rarely change (the game's tables, its atlases, the compiled code of the
-- game's interface and the addons), kept between runs in cache/boot as LuaJIT bytecode: loading that is many
-- times faster than parsing CSV, JSON or Lua source again. An entry is found by a hash of everything it was
-- worked out from, so a changed file is always worked out afresh; nothing is ever taken from a stale one.
--
-- bootcache.remember(name, input, produce)  the value produce() returns for this input (a string)
-- bootcache.compile(code, chunkName)         loadstring(code, chunkName), from the cache when it was compiled before
--
-- Off when no folder is set (bootcache.setFolder), or with ADDONSIM_BOOT_CACHE=0.
local bootcache = { folder = nil, hits = 0, misses = 0 }

local bit = require("bit")
local byte, format, concat, dump = string.byte, string.format, table.concat, string.dump
local tobit, tohex = bit.tobit, bit.tohex

local VERSION = "1" -- (raise when what is kept changes shape)

function bootcache.setFolder(folder)
    if os.getenv("ADDONSIM_BOOT_CACHE") == "0" then
        return
    end
    bootcache.folder = folder .. "/" .. VERSION .. "-" .. (jit and jit.version or _VERSION):gsub("[^%w]", "")
    -- (made by the shell's mkdir: Lua has no other way; once, the folder kept from then on)
    local probe = io.open(bootcache.folder .. "/.made", "rb")
    if probe then
        probe:close()
        return
    end
    local isWindows = package.config:sub(1, 1) == "\\"
    if isWindows then
        os.execute('mkdir "' .. bootcache.folder:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("mkdir -p '" .. bootcache.folder .. "' 2>/dev/null")
    end
    local marker = io.open(bootcache.folder .. "/.made", "wb")
    if marker then
        marker:close()
    else
        bootcache.folder = nil
    end
end

---Two 32-bit hashes of every byte and the length: a key that changes with any change to the text.
function bootcache.hash(text)
    local first, second = 5381, 0
    for index = 1, #text do
        local value = byte(text, index)
        first = tobit(first * 33 + value)
        second = tobit(second * 65599 % 4294967296 + value)
    end
    return tohex(first) .. tohex(second) .. format("%x", #text)
end

-- A file's last write time and size, through the FFI (no need to read the file): a key that changes whenever the
-- file is saved. Windows: GetFileAttributesEx. Linux and macOS: stat, read at the fields' places in the system's
-- struct stat, checked on a file of its own before it is trusted (bootcache.checkFileData). Where none works, nil,
-- and the content's hash is used (slower: every file read and hashed at each boot).
local getFileData
local isFileDataChecked, isStatBased = true, false
do
    local isLoaded, ffi = pcall(require, "ffi")
    -- struct stat: where st_size and st_mtime (seconds, then nanoseconds) sit
    local STAT_LAYOUTS = {
        Linux = { size = 48, mtime = 88 }, -- x64 and arm64 alike (glibc and musl)
        OSX = { size = 96, mtime = 48 }, -- the 64-bit inode struct (arm64's stat, x64's stat$INODE64)
    }
    local layout = isLoaded and STAT_LAYOUTS[ffi.os]
    if layout then
        local buffer = ffi.new("uint8_t[512]")
        local stat
        local candidates = ffi.os == "OSX" and (ffi.arch == "x64" and { "stat$INODE64" } or { "stat" })
            or { "stat", "__xstat" }
        for _, symbol in ipairs(candidates) do
            local name = "addonsim_" .. symbol:gsub("[^%w]", "_")
            local isDeclared = pcall(
                ffi.cdef,
                symbol == "__xstat"
                        and ("int " .. name .. '(int version, const char *path, uint8_t *buffer) __asm__("__xstat");')
                    or ("int " .. name .. '(const char *path, uint8_t *buffer) __asm__("' .. symbol .. '");')
            )
            -- (pcall's two values: "isDeclared and pcall(...)" kept only the first, so call was always nil and the
            -- native stat never used; luacheck's W221 found it)
            local isFound, call = false, nil
            if isDeclared then
                isFound, call = pcall(function()
                    return ffi.C[name]
                end)
            end
            if isFound and call then
                -- (glibc before 2.33 has only __xstat, its struct's version first: 1 on x64, 0 on arm64)
                local version = ffi.arch == "x64" and 1 or 0
                stat = symbol == "__xstat"
                        and function(path)
                            return call(version, path, buffer)
                        end
                    or function(path)
                        return call(path, buffer)
                    end
                break
            end
        end
        if stat then
            local int64 = ffi.typeof("int64_t *")
            local function field(offset)
                return tonumber(ffi.cast(int64, buffer + offset)[0])
            end
            getFileData = function(path)
                if stat(path) ~= 0 then
                    return nil
                end
                return format("%x.%x.%x", field(layout.mtime), field(layout.mtime + 8), field(layout.size))
            end
            isFileDataChecked, isStatBased = false, true
        end
    elseif isLoaded and ffi.os == "Windows" then
        local isDeclared = pcall(
            ffi.cdef,
            [[
            typedef struct { uint32_t low, high; } addonsim_filetime;
            typedef struct { uint32_t attributes; addonsim_filetime created, accessed, written; uint32_t sizeHigh, sizeLow; } addonsim_filedata;
            int GetFileAttributesExA(const char *name, int level, addonsim_filedata *data);
        ]]
        )
        if isDeclared then
            local data = ffi.new("addonsim_filedata")
            getFileData = function(path)
                if ffi.C.GetFileAttributesExA(path, 0, data) == 0 then
                    return nil
                end
                return tohex(data.written.high)
                    .. tohex(data.written.low)
                    .. tohex(data.sizeHigh)
                    .. tohex(data.sizeLow)
            end
        end
    end
end

---Whether the file data read through stat is what it says: a file written here of a known size, then rewritten
---larger, must show each size and a plausible write time. Else stat is not used (the content's hash is).
function bootcache.checkFileData(folder)
    isFileDataChecked = true
    if not getFileData then
        return false
    end
    if not isStatBased then
        return true
    end -- (Windows: its own API, nothing to find out)
    local probe = folder .. "/.stat-probe-" .. tostring(os.time()) .. tostring(math.random(1e9)) -- (runs side by side)
    local function sizeAfterWriting(content)
        local file = io.open(probe, "wb")
        if not file then
            return nil
        end
        file:write(content)
        file:close()
        local data = getFileData(probe)
        local seconds, size = (data or ""):match("^(%x+)%.%x+%.(%x+)$")
        if not seconds then
            return nil
        end
        seconds = tonumber(seconds, 16)
        if seconds < 946684800 or seconds > 4102444800 then
            return nil
        end -- (2000 to 2100)
        return tonumber(size, 16)
    end
    local isRight = sizeAfterWriting("abc") == 3 and sizeAfterWriting("abcdefghij") == 10
    os.remove(probe)
    if not isRight then
        getFileData = nil
    end
    return isRight
end

---A key for a file as it is now (its path, write time and size), or nil where that cannot be had.
function bootcache.fileKey(path)
    if not isFileDataChecked then
        bootcache.checkFileData(bootcache.folder or ".")
    end
    if not getFileData or path:find("[\128-\255]") then
        return nil
    end
    local data = getFileData(path)
    return data and (data .. bootcache.hash(path)) or nil
end

local function readBytes(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- Written beside, then renamed into place: runs side by side (bun run play) never read a half-written entry
local function writeBytes(path, content)
    local temporary = path .. "." .. tostring(os.time()) .. tostring(math.random(1e9)) .. ".tmp"
    local file = io.open(temporary, "wb")
    if not file then
        return
    end
    file:write(content)
    file:close()
    if not os.rename(temporary, path) then
        os.remove(temporary)
    end
end

-- The entries this run looked up (found or written), by file name: bootcache.saveUsed lists them for the server,
-- which deletes the entries no recent run used (src/server/bootCache.ts)
local usedNames, usedCount = {}, 0

local function entryPath(name, key)
    local fileName = name:gsub("[^%w%-_%.]", "_"):sub(1, 80) .. "-" .. key .. ".luac"
    if not usedNames[fileName] then
        usedNames[fileName] = true
        usedCount = usedCount + 1
    end
    return bootcache.folder .. "/" .. fileName
end

---Writes the names of the entries this run used to used/<their hash>.txt (the same boot: the same file, its time
---renewed). The server keeps every entry a list from the last weeks names, and deletes the rest.
function bootcache.saveUsed()
    if not bootcache.folder or usedCount == 0 then
        return
    end
    local names = {}
    for fileName in pairs(usedNames) do
        names[#names + 1] = fileName
    end
    table.sort(names)
    local content = concat(names, "\n") .. "\n"
    local folder = bootcache.folder .. "/used"
    local probe = io.open(folder .. "/.made", "rb")
    if probe then
        probe:close()
    else
        if package.config:sub(1, 1) == "\\" then
            os.execute('mkdir "' .. folder:gsub("/", "\\") .. '" 2>nul')
        else
            os.execute("mkdir -p '" .. folder .. "' 2>/dev/null")
        end
        local marker = io.open(folder .. "/.made", "wb")
        if not marker then
            return
        end
        marker:close()
    end
    writeBytes(folder .. "/" .. bootcache.hash(content) .. ".txt", content)
end

-- Values as Lua that rebuilds them: tables of strings, numbers and booleans, any depth, no cycles. Large tables are
-- filled by statements in functions of their own, each well inside LuaJIT's limits on a function's constants.
local IDENTIFIER = "^[%a_][%w_]*$"
local KEYWORDS = {}
for word in
    ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch(
        "%a+"
    )
do
    KEYWORDS[word] = true
end

local function literal(value)
    local kind = type(value)
    if kind == "string" then
        return format("%q", value)
    end
    if kind == "number" then
        if value ~= value then
            return "0/0"
        end
        if value == math.huge then
            return "1/0"
        end
        if value == -math.huge then
            return "-1/0"
        end
        if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
            return format("%d", value)
        end
        return format("%.17g", value)
    end
    if kind == "boolean" then
        return tostring(value)
    end
    error("bootcache: cannot keep a " .. kind)
end

local function serialize(root)
    local out, pending, registry = { "local R = {}\n" }, {}, 0
    local function flush()
        if #pending == 0 then
            return
        end
        out[#out + 1] = "do local function f()\n" .. concat(pending, "\n") .. "\nend f() end\n"
        pending = {}
    end
    local function statement(text)
        pending[#pending + 1] = text
        if #pending >= 150 then
            flush()
        end
    end
    local seen = {}
    local function size(value, limit)
        if type(value) ~= "table" then
            return 1
        end
        local count = 0
        for _, item in pairs(value) do
            count = count + 1 + size(item, limit - count)
            if count > limit then
                return count
            end
        end
        return count
    end
    local expression
    local function keyText(key, isInline)
        if type(key) == "string" and key:match(IDENTIFIER) and not KEYWORDS[key] then
            return isInline and key or ("." .. key)
        end
        return "[" .. literal(key) .. "]"
    end
    expression = function(value)
        if type(value) ~= "table" then
            return literal(value)
        end
        if seen[value] then
            error("bootcache: a table met twice")
        end
        seen[value] = true
        if getmetatable(value) ~= nil then
            error("bootcache: a table with a metatable")
        end
        if size(value, 40) <= 40 then
            local parts = {}
            local length = #value
            for index = 1, length do
                parts[#parts + 1] = expression(value[index])
            end
            for key, item in pairs(value) do
                if not (type(key) == "number" and key >= 1 and key <= length and key == math.floor(key)) then
                    parts[#parts + 1] = keyText(key, true) .. "=" .. expression(item)
                end
            end
            return "{" .. concat(parts, ",") .. "}"
        end
        registry = registry + 1
        local name = "R[" .. registry .. "]"
        statement(name .. "={}")
        for key, item in pairs(value) do
            local itemText = expression(item)
            statement(name .. keyText(key, false) .. "=" .. itemText)
        end
        return name
    end
    local result = expression(root)
    flush()
    out[#out + 1] = "return " .. result .. "\n"
    return concat(out)
end
bootcache.serialize = serialize

---The value worked out from input (a string: a file's content, or several joined), kept between runs.
---@param produce fun(): any Works the value out; tables of plain values only
function bootcache.remember(name, input, produce)
    if not bootcache.folder or type(input) ~= "string" then
        return produce()
    end
    local path = entryPath(name, bootcache.hash(input))
    local kept = readBytes(path)
    if kept then
        local chunk = loadstring(kept, "=bootcache")
        if chunk then
            local isRead, value = pcall(chunk)
            if isRead and value ~= nil then
                bootcache.hits = bootcache.hits + 1
                return value
            end
        end
    end
    bootcache.misses = bootcache.misses + 1
    local value = produce()
    local isMade, source = pcall(serialize, value)
    local chunk = isMade and loadstring(source, "=bootcache")
    if chunk then
        writeBytes(path, dump(chunk, true))
    end
    return value
end

---The value worked out from a file, kept between runs: found by the file's key without reading it, where it has
---one; else by its content's hash. read() gives the file's content; produce(content) the value.
function bootcache.rememberFile(name, path, read, produce)
    local key = bootcache.folder and bootcache.fileKey(path)
    if not key then
        local content = read()
        if content == nil then
            return nil
        end
        return bootcache.remember(name, content, function()
            return produce(content)
        end)
    end
    local entry = entryPath(name, key)
    local kept = readBytes(entry)
    local chunk = kept and loadstring(kept, "=bootcache")
    if chunk then
        local isRead, value = pcall(chunk)
        if isRead and value ~= nil then
            bootcache.hits = bootcache.hits + 1
            return value
        end
    end
    bootcache.misses = bootcache.misses + 1
    local content = read()
    if content == nil then
        return nil
    end
    local value = produce(content)
    local isMade, source = pcall(serialize, value)
    local made = isMade and loadstring(source, "=bootcache")
    if made then
        writeBytes(entry, dump(made, true))
    end
    return value
end

---Compiles a Lua file as loadstring(read(), chunkName) does, the compiled form kept between runs (with its lines
---and names, for errors and stacks as before), found by the file's key without reading it where it has one.
---@return function? chunk, string? problem
function bootcache.compileFile(path, chunkName, read)
    local key = bootcache.folder and bootcache.fileKey(path)
    if not key then
        local code = read()
        if code == nil then
            return nil, "cannot read " .. path
        end
        return bootcache.compile(code, chunkName)
    end
    local entry = entryPath("lua-" .. (chunkName:match("([^/\\]+)$") or "chunk"), key .. bootcache.hash(chunkName))
    local kept = readBytes(entry)
    local chunk = kept and loadstring(kept, chunkName)
    if chunk then
        bootcache.hits = bootcache.hits + 1
        return chunk
    end
    bootcache.misses = bootcache.misses + 1
    local code = read()
    if code == nil then
        return nil, "cannot read " .. path
    end
    local problem
    chunk, problem = loadstring(code, chunkName)
    if chunk then
        writeBytes(entry, dump(chunk))
    end
    return chunk, problem
end

---Compiles code as loadstring does, the compiled form kept between runs (with its lines and names, for errors and
---stacks as before). Code that does not compile is compiled each time, for its message.
function bootcache.compile(code, chunkName)
    if not bootcache.folder then
        return loadstring(code, chunkName)
    end
    local path =
        entryPath("lua-" .. (chunkName:match("([^/\\]+)$") or "chunk"), bootcache.hash(chunkName .. "\0" .. code))
    local kept = readBytes(path)
    if kept then
        local chunk = loadstring(kept, chunkName)
        if chunk then
            bootcache.hits = bootcache.hits + 1
            return chunk
        end
    end
    bootcache.misses = bootcache.misses + 1
    local chunk, problem = loadstring(code, chunkName)
    if chunk then
        writeBytes(path, dump(chunk))
    end
    return chunk, problem
end

return bootcache
