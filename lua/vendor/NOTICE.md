# Vendored code

- `LibDeflate.lua`: LibDeflate 1.0.2 by Haoqian He, zlib License (header kept), taken from QuestieDB's generator/vendor copy.
- `BlizzardCBOR.lua`: a pure-Lua stand-in for C_EncodingUtil's CBOR, from Questie's test mocks (Questie, GPL-3.0), via QuestieDB.
- `base64.lua`: from QuestieDB's generator (GPL-3.0).

AddonSim therefore includes GPL-3.0 code: keep it under the GPL-3.0 if it is ever shared.

## vendor/questie (party members running Questie)

Copied unchanged from the Questie addon's source (github.com/Questie/Questie), to make a simulated party
member's messages with Questie's own code:

- `QuestieSerializer.lua`, `QuestieStream.lua`: Questie, by the Questie team, GPL-3.0.
- `AceComm-3.0.lua`, `CallbackHandler-1.0.lua`: Ace3, by the Ace3 team, under the Ace3 licence (BSD-style), as
  bundled with Questie.
- `LibStub.lua`: public domain, as bundled with Questie.
