-- Sound, as the client plays it: each sound a handle on a channel (Master, SFX, Music, Ambience, Dialog), at the
-- volume the sound settings give that channel (the Sound_* console variables), on the game's clock till its length
-- is up (read from the file: lua/audiofile.lua) or the page that plays it says it ended. Sound kits are the game's own
-- (SoundKitEntry: a kit's files); files are an addon's (from its folder) or the game's (by number or path).
--
-- The page plays them (src/ui/engine/audio.ts): each frame of the stream carries what started and stopped
-- (sound.takeEvents), and the page sends "soundEnded" back. Played or not, scenarios see sound.history.
local sim = require("sim")
local audiofile = require("audiofile")

local sound = { history = {} }

local G
local active = {} -- [handle] = { endsAt, finishes, channel, source }
local events = {} -- for the page, since the last frame
local nextHandle = 0
local musicHandle
local mutedFiles = {}
local kitFiles -- [kitId] = { { file, volume }, ... }, read on first use
local durations = {} -- [disk path] = seconds or false

local UNKNOWN_SECONDS = 3 -- a game sound whose length the simulator cannot read: over after this, unless the page says
local HISTORY = 200
local MAX_EVENTS = 64 -- (with no page taking them, a scenario run: the oldest go)

-- The channels' console variables (the client's own names): its switch and its volume
local CHANNELS = {
    SFX = { "Sound_EnableSFX", "Sound_SFXVolume" },
    Music = { "Sound_EnableMusic", "Sound_MusicVolume" },
    Ambience = { "Sound_EnableAmbience", "Sound_AmbienceVolume" },
    Dialog = { "Sound_EnableDialog", "Sound_DialogVolume" },
    ["Talking Head"] = { "Sound_EnableDialog", "Sound_DialogVolume" },
}

local function cvarNumber(name, default)
    local value = G.GetCVar and tonumber(G.GetCVar(name))
    if value == nil then
        return default
    end
    return value
end

---@return number volume 0 to 1: the master volume times the channel's, 0 when either is switched off
function sound.channelVolume(channel)
    if cvarNumber("Sound_EnableAllSound", 1) ~= 1 then
        return 0
    end
    local volume = cvarNumber("Sound_MasterVolume", 1)
    local names = CHANNELS[channel or "SFX"] or CHANNELS.SFX
    if channel == "Master" then
        return volume
    end
    if cvarNumber(names[1], 1) ~= 1 then
        return 0
    end
    return volume * cvarNumber(names[2], 1)
end

local function urlEncode(text)
    return (
        tostring(text):gsub("[^%w%-%._~]", function(character)
            return string.format("%%%02X", character:byte())
        end)
    )
end

-- An addon's file on disk (Interface\AddOns\<Addon>\...): from the addon's own folder, else the AddOns folder
local function addonFilePath(path)
    local addonName, rest = tostring(path):gsub("/", "\\"):match("^[Ii]nterface\\[Aa]dd[Oo]ns\\([^\\]+)\\(.+)$")
    if not addonName then
        return nil
    end
    local addons = package.loaded["addons"]
    local addon = addons and addons.byName and addons.byName[addonName:lower()]
    local root = addon and addon.folder or ((addons and addons.root or ".") .. "/" .. addonName)
    return root .. "/" .. rest:gsub("\\", "/")
end

local function exists(diskPath)
    local file = io.open(diskPath, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function fileDuration(diskPath)
    if durations[diskPath] == nil then
        durations[diskPath] = audiofile.fileDuration(diskPath) or false
    end
    return durations[diskPath] or nil
end

---Where the page fetches a sound: an addon's through /media, the game's through /sound
local function sourceOf(file)
    if type(file) == "number" or tostring(file):match("^%d+$") then
        return "/sound?p=" .. tostring(file)
    end
    if addonFilePath(file) then
        return "/media?p=" .. urlEncode(file)
    end
    return "/sound?p=" .. urlEncode(file)
end

local function remember(entry)
    table.insert(sound.history, entry)
    if #sound.history > HISTORY then
        table.remove(sound.history, 1)
    end
end

---Starts a file on a channel: the client's answer (whether it will play) and its handle
local function start(file, channel, options)
    options = options or {}
    channel = channel or "SFX"
    local diskPath = type(file) == "string" and addonFilePath(file)
    if diskPath and not exists(diskPath) then
        return false
    end -- (a missing file: false, as the client)
    local volume = sound.channelVolume(channel) * (options.volume or 1)
    if volume <= 0 then
        return false
    end -- (a channel switched off plays nothing: false too)
    nextHandle = nextHandle + 1
    local handle = nextHandle
    local length = options.length or (diskPath and fileDuration(diskPath)) or UNKNOWN_SECONDS
    active[handle] = {
        endsAt = not options.loop and (G.GetTime() + length) or nil,
        finishes = options.finishes,
        channel = channel,
        source = file,
        kit = options.kit,
    }
    remember({
        handle = handle,
        file = file,
        kit = options.kit,
        channel = channel,
        at = G.GetTime(),
        length = not options.loop and length or nil,
    })
    if not mutedFiles[tostring(file)] then
        events[#events + 1] = { k = "play", h = handle, src = sourceOf(file), v = volume, loop = options.loop or nil }
    end
    if #events > MAX_EVENTS then
        table.remove(events, 1)
    end
    sim.touch()
    return true, handle
end

local function finish(handle, isStopped, fadeSeconds)
    local playing = active[handle]
    if not playing then
        return
    end
    active[handle] = nil
    if isStopped then
        events[#events + 1] = { k = "stop", h = handle, fade = fadeSeconds }
    end
    if playing.finishes then
        sim.fireEvent("SOUNDKIT_FINISHED", handle)
    end
end

---The kit's files, from the game's table (one is picked each time, as the client picks among them)
local function kitFile(kitId)
    if not kitFiles then
        kitFiles = {}
        local readTable = package.loaded["game"] and package.loaded["game"].readDb2
        for _, row in ipairs(readTable and readTable("SoundKitEntry", { "SoundKitID", "FileDataID", "Volume" }) or {}) do
            local kit, fileId = tonumber(row.SoundKitID), tonumber(row.FileDataID)
            if kit and fileId then
                kitFiles[kit] = kitFiles[kit] or {}
                table.insert(kitFiles[kit], { file = fileId, volume = tonumber(row.Volume) or 1 })
            end
        end
    end
    local files = kitFiles[tonumber(kitId) or 0]
    if not files then
        return nil
    end
    return files[math.random(#files)]
end

local function playKit(kitId, channel, forceNoDuplicates, runFinishCallback, volumeOverride)
    local entry = kitFile(kitId)
    if not entry then
        return false
    end
    if forceNoDuplicates then
        for _, playing in pairs(active) do
            if playing.kit == kitId then
                return false
            end
        end
    end
    return start(
        entry.file,
        channel,
        { kit = kitId, finishes = runFinishCallback == true, volume = volumeOverride or entry.volume }
    )
end

---What the page is to start and stop, since the last frame (handlers.frame sends it)
function sound.takeEvents()
    if #events == 0 then
        return nil
    end
    local taken = events
    events = {}
    return taken
end

---The page's report: the sound ended (its real length, or it could not be played)
function sound.ended(handle)
    finish(tonumber(handle))
end

function sound.tick()
    local now = G.GetTime()
    -- (gathered first: a SOUNDKIT_FINISHED handler may play another, adding to the table walked)
    local ended
    for handle, playing in pairs(active) do
        if playing.endsAt and now >= playing.endsAt then
            ended = ended or {}
            ended[#ended + 1] = handle
        end
    end
    for _, handle in ipairs(ended or {}) do
        finish(handle)
    end
end

function sound.install(globals)
    G = globals
    -- (the channel is a name; the old forms gave a number or nothing, which is the effects')
    local function channelName(channel)
        return type(channel) == "string" and channel or "SFX"
    end
    G.PlaySound = function(kitId, channel, forceNoDuplicates, runFinishCallback)
        return playKit(kitId, channelName(channel), forceNoDuplicates, runFinishCallback)
    end
    G.PlaySoundFile = function(file, channel)
        if file == nil then
            return false
        end
        return start(file, channelName(channel))
    end
    G.StopSound = function(handle, fadeoutMilliseconds)
        finish(tonumber(handle), true, fadeoutMilliseconds and fadeoutMilliseconds / 1000 or nil)
    end
    G.PlayMusic = function(file)
        if musicHandle then
            finish(musicHandle, true)
        end
        local _, handle = start(file, "Music", { loop = true })
        musicHandle = handle
        return handle ~= nil
    end
    G.StopMusic = function()
        if musicHandle then
            finish(musicHandle, true)
        end
        musicHandle = nil
    end
    G.MuteSoundFile = function(file)
        mutedFiles[tostring(file)] = true
    end
    G.UnmuteSoundFile = function(file)
        mutedFiles[tostring(file)] = nil
    end
    G.C_Sound = G.C_Sound or {}
    G.C_Sound.PlaySound = function(kitId, _, forceNoDuplicates, runFinishCallback, _, volumeOverride)
        return playKit(kitId, "SFX", forceNoDuplicates, runFinishCallback, volumeOverride)
    end
    G.C_Sound.PlaySoundWithOptions = function(params)
        params = type(params) == "table" and params or {}
        return playKit(
            params.soundKitID,
            "SFX",
            params.forceNoDuplicates,
            params.runFinishCallback,
            params.volumeOverride
        )
    end
    G.C_Sound.IsPlaying = function(handle)
        return active[tonumber(handle) or 0] ~= nil
    end
    G.C_Sound.GetSoundScaledVolume = function(handle)
        local playing = active[tonumber(handle) or 0]
        return playing and sound.channelVolume(playing.channel) or 0
    end
    sim.tickHandlers = sim.tickHandlers or {}
    table.insert(sim.tickHandlers, sound.tick)
end

return sound
