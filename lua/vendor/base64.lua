-- generator/base64.lua
--
-- Standard base64 for the plain-Lua generator and client emulator.

local base64 = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local encodeCharacter = {}
local decodeCharacter = {}
for index = 1, #alphabet do
  local character = alphabet:sub(index, index)
  encodeCharacter[index - 1] = character
  decodeCharacter[character] = index - 1
end

local byte, char, concat, floor = string.byte, string.char, table.concat, math.floor

-- AddonSim: decoding into a byte buffer through LuaJIT's FFI, four characters at a time (the client decodes in
-- C; QuestieDB decodes its whole baked database at login). Called once the text has passed the checks below,
-- which leave "=" only as the last one or two characters.
local fastDecode
do
  local isLoaded, ffi = pcall(require, "ffi")
  local isBit, bit = pcall(require, "bit")
  if isLoaded and isBit then
    local lshift, rshift, band = bit.lshift, bit.rshift, bit.band
    local values = {}
    for code = 0, 255 do values[code] = 0 end
    for index = 1, #alphabet do values[byte(alphabet, index)] = index - 1 end
    fastDecode = function(text)
      local length = #text
      if length == 0 then return "" end
      local padding = (byte(text, length) == 61 and 1 or 0) + (byte(text, length - 1) == 61 and 1 or 0)
      local size = length / 4 * 3
      local buffer = ffi.new("uint8_t[?]", size)
      local at = 0
      for index = 1, length, 4 do
        local a, b, c, d = byte(text, index, index + 3)
        local value = lshift(values[a], 18) + lshift(values[b], 12) + lshift(values[c], 6) + values[d]
        buffer[at] = rshift(value, 16)
        buffer[at + 1] = band(rshift(value, 8), 255)
        buffer[at + 2] = band(value, 255)
        at = at + 3
      end
      return ffi.string(buffer, size - padding)
    end
  end
end

---@param bytes string
---@return string encoded
function base64.encode(bytes)
  if type(bytes) ~= "string" then error("base64.encode: expected a string", 2) end

  local output = {}
  for index = 1, #bytes, 3 do
    local first, second, third = byte(bytes, index, index + 2)
    local value = first * 65536 + (second or 0) * 256 + (third or 0)
    output[#output + 1] = encodeCharacter[floor(value / 262144) % 64]
    output[#output + 1] = encodeCharacter[floor(value / 4096) % 64]
    output[#output + 1] = second and encodeCharacter[floor(value / 64) % 64] or "="
    output[#output + 1] = third and encodeCharacter[value % 64] or "="
  end
  return concat(output)
end

---@param text string
---@return string decoded
function base64.decode(text)
  if type(text) ~= "string" then error("base64.decode: expected a string", 2) end
  if #text % 4 ~= 0 then error("base64.decode: invalid length", 2) end
  if text:find("[^A-Za-z0-9+/=]") or text:find("=[^=]") or text:find("===") then
    error("base64.decode: invalid encoding", 2)
  end

  if fastDecode then return fastDecode(text) end

  local output = {}
  for index = 1, #text, 4 do
    local first = decodeCharacter[text:sub(index, index)]
    local second = decodeCharacter[text:sub(index + 1, index + 1)]
    local thirdCharacter = text:sub(index + 2, index + 2)
    local fourthCharacter = text:sub(index + 3, index + 3)
    local third = decodeCharacter[thirdCharacter]
    local fourth = decodeCharacter[fourthCharacter]

    if first == nil or second == nil or
       (third == nil and thirdCharacter ~= "=") or
       (fourth == nil and fourthCharacter ~= "=") or
       (thirdCharacter == "=" and fourthCharacter ~= "=") or
       ((thirdCharacter == "=" or fourthCharacter == "=") and index + 3 ~= #text) then
      error("base64.decode: invalid encoding", 2)
    end

    local value = first * 262144 + second * 4096 + (third or 0) * 64 + (fourth or 0)
    output[#output + 1] = char(floor(value / 65536) % 256)
    if third ~= nil then output[#output + 1] = char(floor(value / 256) % 256) end
    if fourth ~= nil then output[#output + 1] = char(value % 256) end
  end
  return concat(output)
end

return base64
