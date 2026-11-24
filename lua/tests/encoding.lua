-- C_EncodingUtil's base64, hex, CBOR and compression (lua/encoding.lua), against the RFCs' own examples and round trips.
-- Needs nothing of the game: `luajit lua/tests/encoding.lua` from the repository's root (CI runs it).
package.path = "lua/?.lua;" .. package.path
local encoding = require("encoding")

local failures, checks = 0, 0
local function check(isTrue, what)
    checks = checks + 1
    if not isTrue then
        failures = failures + 1
        print("FAIL  " .. what)
    end
end
local function hex(text)
    return (text:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end
local function fromHex(text)
    return (text:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end
local function deepEqual(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b or (a ~= a and b ~= b)
    end
    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- RFC 4648, section 10
for _, case in ipairs({
    { "", "" },
    { "f", "Zg==" },
    { "fo", "Zm8=" },
    { "foo", "Zm9v" },
    { "foob", "Zm9vYg==" },
    { "fooba", "Zm9vYmE=" },
    { "foobar", "Zm9vYmFy" },
}) do
    check(encoding.encodeBase64(case[1]) == case[2], "base64 encodes " .. case[1])
    check(encoding.decodeBase64(case[2]) == case[1], "base64 decodes " .. case[2])
end
check(encoding.encodeBase64("\251\255", 1) == "-_8=", "the URL-safe alphabet")
check(encoding.decodeBase64("-_8=", 1) == "\251\255", "decoded with the URL-safe alphabet")
check(not pcall(encoding.decodeBase64, "Zm9"), "a length not of four is refused")
check(not pcall(encoding.decodeBase64, "Zm9!"), "a character outside the alphabet is refused")
check(not pcall(encoding.encodeBase64, "x", 7), "an unknown variant is refused")
check(encoding.encodeHex("\0\16\255") == "0010ff" and encoding.decodeHex("0010FF") == "\0\16\255", "hex")
check(not pcall(encoding.decodeHex, "abc"), "odd hex is refused")

-- RFC 8949, appendix A (the items a Lua value can be: the client writes strings as byte strings, and a whole number as
-- an integer, so 65504.0 is not among them)
local CBOR_EXAMPLES = {
    { 0, "00" },
    { 1, "01" },
    { 10, "0a" },
    { 23, "17" },
    { 24, "1818" },
    { 25, "1819" },
    { 100, "1864" },
    { 1000, "1903e8" },
    { 1000000, "1a000f4240" },
    { 1000000000000, "1b000000e8d4a51000" },
    { -1, "20" },
    { -10, "29" },
    { -100, "3863" },
    { -1000, "3903e7" },
    { 0.5, "f93800" },
    { 1.1, "fb3ff199999999999a" },
    { 1.5, "f93e00" },
    { 100000.5, "fa47c35040" },
    { 3.4028234663852886e+38, "fa7f7fffff" },
    { 1.0e+300, "fb7e37e43c8800759c" },
    { 5.960464477539063e-8, "f90001" },
    { 0.00006103515625, "f90400" },
    { -4.1, "fbc010666666666666" },
    { 1 / 0, "f97c00" },
    { -1 / 0, "f9fc00" },
    { false, "f4" },
    { true, "f5" },
    { "", "40" },
    { "\1\2\3\4", "4401020304" },
    { { 1, 2, 3 }, "83010203" },
}
for _, case in ipairs(CBOR_EXAMPLES) do
    local encoded = hex(encoding.serializeCBOR(case[1]))
    check(encoded == case[2], "CBOR writes " .. tostring(case[1]) .. " as " .. case[2] .. " (" .. encoded .. ")")
    check(deepEqual(encoding.deserializeCBOR(fromHex(case[2])), case[1]), "CBOR reads " .. case[2])
end
check(hex(encoding.serializeCBOR(0 / 0)) == "f97e00", "NaN as a half")
check(
    encoding.deserializeCBOR(fromHex("f6")) == nil and encoding.deserializeCBOR(fromHex("f7")) == nil,
    "null and undefined read as nil"
)
check(encoding.deserializeCBOR(fromHex("6449455446")) == "IETF", "a text string reads as a string")
check(deepEqual(encoding.deserializeCBOR(fromHex("a201020304")), { [1] = 2, [3] = 4 }), "a map")
check(not pcall(encoding.deserializeCBOR, fromHex("c074")), "tags are refused")
check(not pcall(encoding.deserializeCBOR, fromHex("9fff")), "indefinite lengths are refused")
check(not pcall(encoding.deserializeCBOR, fromHex("0101")), "data left over is refused")

-- Tables: arrays at least half full (gaps as null), anything else a map; what CBOR cannot hold
check(hex(encoding.serializeCBOR({ 1, nil, 3 })) == "8301f603", "a gap in an array is null")
check(hex(encoding.serializeCBOR({ [1] = 1, [9] = 9 })):sub(1, 2) == "a2", "a sparse table is a map")
local nested =
    { name = "Plainstrider Menace", id = 844, objectives = { { 7, 0 }, { 3, 1 } }, isDone = false, ratio = 0.25 }
check(deepEqual(encoding.deserializeCBOR(encoding.serializeCBOR(nested)), nested), "a nested table round trip")
check(not pcall(encoding.serializeCBOR, { print }), "a function is refused")
check(
    encoding.deserializeCBOR(encoding.serializeCBOR({ print }, { ignoreSerializationErrors = true }))[1] == nil,
    "with ignoreSerializationErrors it is undefined"
)
local loop = {}
loop.self = loop
check(not pcall(encoding.serializeCBOR, loop), "a table that holds itself is refused")

-- Compression: deflate, zlib and gzip each read back what they wrote, at each level
local text = string.rep("The quick brown fox jumps over the lazy dog. ", 50) .. "\0\1\2\255"
for method = 0, 2 do
    for level = 0, 2 do
        check(
            encoding.decompressString(encoding.compressString(text, method, level), method) == text,
            "compression " .. method .. " at level " .. level
        )
    end
end
local gzip = encoding.compressString("hello", 2)
check(gzip:sub(1, 3) == "\31\139\8", "gzip's header")
check(not pcall(encoding.decompressString, "not compressed", 1), "bad data is refused")

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
