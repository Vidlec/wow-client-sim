-- AddonSim's native core (native/, Rust), loaded through LuaJIT's FFI. It is required: the server, the runner and the
-- SDK build it before they start the simulator (src/server/nativeCore.ts; by hand, `bun run native`). One handle
-- (native.handle) holds the scene stream's item store, which keeps what the page holds and writes binary frames
-- (lua/stream.lua), and the scene's walk with its mirror of the widgets (lua/scenesync.lua).
local ffi = require("ffi")
local sim = require("sim")

local native = {}

ffi.cdef([[
    typedef struct AddonSimNative AddonSimNative;
    typedef struct {
        uint32_t id, parent, scrollChildOf;
        uint32_t masks[3];
        uint32_t visualVersion;
        uint32_t flags;
        int32_t sublevel, artOrder;
        uint8_t kind, layer, role, maskCount;
        double alpha, scale;
        double width, height, atlasWidth, atlasHeight, scrollX, scrollY;
    } AddonSimObject;
    typedef struct {
        uint32_t relative;
        uint8_t point, relativePoint, pad1, pad2;
        double x, y;
    } AddonSimPoint;
    typedef double (*AddonSimMeasure)(uint32_t id, int32_t kind, double width);
    AddonSimNative* sc_new(void);
    void sc_free(AddonSimNative* native);
    uint32_t sc_version(void);
    void sc_begin(AddonSimNative* native);
    void sc_item(AddonSimNative* native, const char* key, size_t keyLength, const uint8_t* item, size_t itemLength);
    void sc_same(AddonSimNative* native, const char* key, size_t keyLength);
    void sc_move(AddonSimNative* native, const char* key, size_t keyLength, const double* boxes, size_t count);
    const uint8_t* sc_end(AddonSimNative* native, size_t* length);
    const uint8_t* sc_whole(AddonSimNative* native, size_t* length);
    void sg_object(AddonSimNative* native, const AddonSimObject* record);
    void sg_points(AddonSimNative* native, uint32_t id, const AddonSimPoint* points, size_t count);
    void sg_set_measure(AddonSimNative* native, AddonSimMeasure measure);
    bool sg_layout_rect(AddonSimNative* native, uint32_t id, double* rect);
    void sg_order(AddonSimNative* native, const uint32_t* frames, const uint32_t* groups, size_t count);
    void sg_globals(AddonSimNative* native, uint32_t motionFocus, uint32_t pressed, uint32_t focus, double fontsVersion,
        double screenWidth, double screenHeight);
    void sg_effects_clear(AddonSimNative* native);
    void sg_effect(AddonSimNative* native, uint32_t id, uint32_t flags, double alpha);
    uint32_t sg_walk(AddonSimNative* native);
    bool sg_request(AddonSimNative* native, uint32_t index, uint32_t* kind, uint32_t* id);
    void sg_submit(AddonSimNative* native, uint32_t request, const char* key, size_t keyLength, const uint8_t* item,
        size_t itemLength);
    const uint8_t* sg_finish(AddonSimNative* native, size_t* length);
    void sg_counts(AddonSimNative* native, uint32_t* kept, uint32_t* moved, uint32_t* made, uint32_t* dropped);
]])

local VERSION = 3 -- (the handle's sc_version this side is written for)

local function libraryName()
    return ffi.os == "Windows" and "addonsim_native.dll"
        or ffi.os == "OSX" and "libaddonsim_native.dylib"
        or "libaddonsim_native.so"
end

---The built library copied to the cache under its build's size and time, and that copy's path: the build's own file
---stays free while a simulator has it loaded (Windows locks a loaded library), so `bun run native` works while the
---server runs; the next start loads the new build
local function loadablePath(built)
    local isKnown, stamp = pcall(function()
        return require("bootcache").fileKey(built) -- (its write time and size)
    end)
    if not isKnown or not stamp then
        return built
    end
    local root = sim.root or "."
    local copy = root .. "/cache/native-" .. stamp:gsub("[^%w%-]", "") .. "-" .. libraryName()
    -- (the copies of earlier builds are let go; one another simulator still has loaded is locked, and stays)
    local suffix = "-" .. libraryName()
    for _, name in ipairs(sim.listDirectory(root .. "/cache")) do
        local path = root .. "/cache/" .. name
        if name:sub(1, 7) == "native-" and name:sub(-#suffix) == suffix and path ~= copy then
            os.remove(path)
        end
    end
    local existing = io.open(copy, "rb")
    if existing then
        existing:close()
        return copy
    end
    -- (written under a name of this process's own, then renamed: simulators starting side by side, a test suite's,
    -- never load a copy another is still writing)
    local unique = tostring({}):match("0x(%x+)") or "0"
    local part = copy .. ".part-" .. unique .. "-" .. os.time() .. "-" .. math.floor(os.clock() * 1e6)
    local source = io.open(built, "rb")
    local target = source and io.open(part, "wb")
    if not (source and target) then
        if source then
            source:close()
        end
        return built
    end
    target:write(source:read("*a"))
    target:close()
    source:close()
    if os.rename(part, copy) then
        return copy
    end
    -- (Windows renames onto no file that exists: another simulator's copy got there first, and is the same build)
    os.remove(part)
    existing = io.open(copy, "rb")
    if existing then
        existing:close()
        return copy
    end
    return built
end

local BUILD_IT = "build it with `bun run native` (Rust from https://rustup.rs)"

local library
---The native library; an error when it is not built, does not load or is of another version
function native.load()
    if library then
        return library
    end
    local built = (sim.root or ".") .. "/native/target/release/" .. libraryName()
    local file = io.open(built, "rb")
    if not file then
        error("AddonSim's native core is not built (" .. built .. "): " .. BUILD_IT, 0)
    end
    file:close()
    local isLoaded, loaded = pcall(ffi.load, loadablePath(built))
    if not isLoaded then
        error("AddonSim's native core did not load (" .. tostring(loaded) .. "): " .. BUILD_IT, 0)
    end
    if loaded.sc_version() ~= VERSION then
        error("AddonSim's native core is of another version: " .. BUILD_IT .. " again", 0)
    end
    library = loaded
    return library
end

local handle
---The one native handle (the item store and the walk's mirror)
function native.handle()
    if not handle then
        local loaded = native.load()
        handle = ffi.gc(loaded.sc_new(), loaded.sc_free)
    end
    return handle
end

return native
