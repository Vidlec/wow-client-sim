# Credits

AddonSim uses the work of others. Thank you.

| What | Where it is used | Licence |
| --- | --- | --- |
| [wowless](https://github.com/wowless/wowless) by Ferronn and contributors | `bun run wowless` fetches its data for a game product (WoW: Forever is `wowf`) into `cache/wowless/`; `lua/wowless.lua` reads it: how the client's functions answer, console variable defaults, constants, the secure addons' namespaces. Its data is downloaded, not shipped. | MIT |
| [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) by Haoqian He | `lua/vendor/`: deflate and zlib for `C_EncodingUtil` (base64, hex, CBOR and gzip are AddonSim's own, `lua/encoding.lua`) | zlib |
| [QuestieDB](https://github.com/Questie/QuestieDB) | Optional: when a project loads it from the game's AddOns folder, the game's quests, creatures and items come from its data (read at run time, never shipped); the simulator's own scenarios carry a few of its entries (`scenarios/fixtures/addons/SimQuestieDB/Data.lua`: 11 quests, 34 creatures, 4 items) | Its own (GPL-3.0) |
| [wago.tools](https://wago.tools) | The game's art and tables, downloaded per build into `cache/` (never shipped) | |
| Blizzard's interface source ([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)) | Read at run time from `interfaceRoot` (never shipped) | Blizzard's |
