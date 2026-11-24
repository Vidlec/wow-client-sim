-- Sound files' lengths from their headers (lua/audiofile.lua), on files made here. Needs nothing of the game:
-- `luajit lua/tests/audiofile.lua` from the repository's root (CI runs it).
package.path = "lua/?.lua;" .. package.path
local audiofile = require("audiofile")

local failures, checks = 0, 0
local function check(actual, expected, what)
    checks = checks + 1
    if actual == nil or math.abs(actual - expected) > 0.01 then
        failures = failures + 1
        print(string.format("FAIL  %s: %s, not %s", what, tostring(actual), tostring(expected)))
    end
end
local function u32le(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256
    )
end
local function u16le(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

-- WAV: 8 kHz, 8-bit mono, 2 s of data
local samples = 16000
local wav = "RIFF"
    .. u32le(36 + samples)
    .. "WAVE"
    .. "fmt "
    .. u32le(16)
    .. u16le(1)
    .. u16le(1)
    .. u32le(8000)
    .. u32le(8000)
    .. u16le(1)
    .. u16le(8)
    .. "data"
    .. u32le(samples)
    .. string.rep("\128", samples)
check(audiofile.duration(wav), 2, "a WAV's length from its data and byte rate")

-- MP3, constant bitrate: MPEG-1 layer III, 128 kbit/s, 44.1 kHz, after an ID3 tag; 160000 bytes are 10 s
local frameHeader = "\255\251\144\100"
local id3 = "ID3\3\0\0\0\0\0\10" .. string.rep("\0", 10)
local mp3 = id3 .. frameHeader .. string.rep("\0", 160000 - 4)
check(audiofile.duration(mp3), 10, "a constant-bitrate MP3's length from its bitrate")

-- MP3 with a Xing header: 383 frames of 1152 samples at 44.1 kHz are 10.005 s
local sideInfo = string.rep("\0", 32) -- (MPEG-1 stereo)
local xing = frameHeader .. sideInfo .. "Xing" .. "\0\0\0\1" .. "\0\0\1\127"
check(
    audiofile.duration(xing .. string.rep("\0", 4000)),
    383 * 1152 / 44100,
    "a variable-bitrate MP3's length from its Xing frames"
)

-- Ogg Vorbis: the rate in the identification header, the length in the last page's granule position
local idHeader = "OggS" .. string.rep("\0", 24) .. "\1vorbis" .. u32le(0) .. "\2" .. u32le(22050)
local lastPage = "OggS\0\4" .. u32le(22050 * 3) .. u32le(0) .. string.rep("\0", 14)
check(
    audiofile.duration(idHeader .. string.rep("\0", 100) .. lastPage),
    3,
    "an Ogg Vorbis file's length from its last granule"
)

checks = checks + 1
if audiofile.duration("not a sound file at all") ~= nil then
    failures = failures + 1
    print("FAIL  another kind of file has no length")
end

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
