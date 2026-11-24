-- How long a sound file plays, read from its headers (no decoding): Ogg (Vorbis, Opus), MP3 (constant bitrate, or a
-- Xing/Info/VBRI header's frame count) and WAV. The simulator's sounds end on the game's clock by it (C_Sound.IsPlaying,
-- SOUNDKIT_FINISHED), the page playing or not.
local audiofile = {}

local byte, floor = string.byte, math.floor

local function u32le(data, at)
    local a, b, c, d = byte(data, at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function u32be(data, at)
    local a, b, c, d = byte(data, at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function oggDuration(data)
    -- The rate from the first packet's header (Vorbis: "\1vorbis"; Opus: always 48 kHz), the length from the granule
    -- position of the last page
    local rate
    local vorbis = data:find("\1vorbis", 1, true)
    if vorbis then
        rate = u32le(data, vorbis + 12)
    elseif data:find("OpusHead", 1, true) then
        rate = 48000
    end
    if not rate or rate <= 0 then
        return nil
    end
    local last
    local from = math.max(1, #data - 65536)
    local search = from
    while true do
        local at = data:find("OggS", search, true)
        if not at then
            break
        end
        last, search = at, at + 4
    end
    if not last then
        return nil
    end
    -- (granule position: 8 bytes little-endian at offset 6; the top bytes are 0 for anything but hours)
    local granule = u32le(data, last + 6) + u32le(data, last + 10) * 4294967296
    return granule / rate
end

local MP3_BITRATES = {
    -- [version 1][layer 3], [version 2/2.5][layer 3], kbit/s by index
    v1 = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
    v2 = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
}
local MP3_RATES = { [3] = { 44100, 48000, 32000 }, [2] = { 22050, 24000, 16000 }, [0] = { 11025, 12000, 8000 } }

local function mp3Duration(data)
    local start = 1
    if data:sub(1, 3) == "ID3" then
        local a, b, c, d = byte(data, 7, 10)
        start = 11 + ((a * 128 + b) * 128 + c) * 128 + d
    end
    -- The first frame's header: sync, version, layer, bitrate, rate
    local at = start
    while at < #data - 4 do
        local first, second = byte(data, at, at + 1)
        if first == 0xFF and second >= 0xE0 then
            break
        end
        at = at + 1
    end
    if at >= #data - 4 then
        return nil
    end
    local h1, h2, h3 = byte(data, at + 1, at + 3)
    local version = floor(h1 / 8) % 4 -- 3: MPEG 1, 2: MPEG 2, 0: MPEG 2.5
    local layer = floor(h1 / 2) % 4 -- 1: layer III
    local bitrateIndex, rateIndex = floor(h2 / 16), floor(h2 / 4) % 4
    local channelMode = floor(h3 / 64)
    local rate = MP3_RATES[version] and MP3_RATES[version][rateIndex + 1]
    if layer ~= 1 or not rate or bitrateIndex == 0 or bitrateIndex == 15 then
        return nil
    end
    local samplesPerFrame = version == 3 and 1152 or 576
    -- A VBR header in the first frame: the number of frames
    local sideInfo = version == 3 and (channelMode == 3 and 17 or 32) or (channelMode == 3 and 9 or 17)
    local tag = data:sub(at + 4 + sideInfo, at + 7 + sideInfo)
    if tag == "Xing" or tag == "Info" then
        local flags = u32be(data, at + 8 + sideInfo)
        if flags % 2 == 1 then
            return u32be(data, at + 12 + sideInfo) * samplesPerFrame / rate
        end
    end
    if data:sub(at + 36, at + 39) == "VBRI" then
        return u32be(data, at + 50) * samplesPerFrame / rate
    end
    local kbits = (version == 3 and MP3_BITRATES.v1 or MP3_BITRATES.v2)[bitrateIndex]
    return (#data - at + 1) * 8 / (kbits * 1000)
end

local function wavDuration(data)
    if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
        return nil
    end
    local at, byteRate = 13, nil
    while at < #data - 8 do
        local id, size = data:sub(at, at + 3), u32le(data, at + 4)
        if id == "fmt " then
            byteRate = u32le(data, at + 16)
        end
        if id == "data" and byteRate and byteRate > 0 then
            return size / byteRate
        end
        at = at + 8 + size + size % 2
    end
    return nil
end

---@param data string The file's bytes
---@return number? seconds How long it plays, nil when its kind or headers are not known
function audiofile.duration(data)
    if type(data) ~= "string" or #data < 16 then
        return nil
    end
    if data:sub(1, 4) == "OggS" then
        return oggDuration(data)
    end
    if data:sub(1, 4) == "RIFF" then
        return wavDuration(data)
    end
    if data:sub(1, 3) == "ID3" or byte(data, 1) == 0xFF then
        return mp3Duration(data)
    end
    return nil
end

---@return number? seconds How long the file at this path plays
function audiofile.fileDuration(path)
    local file = path and io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return audiofile.duration(data)
end

return audiofile
