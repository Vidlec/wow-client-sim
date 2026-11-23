# Credits

AddonSim uses the work of others. Thank you.

| What | Where it is used | Licence |
| --- | --- | --- |
| [wowless](https://github.com/wowless/wowless) by Ferronn and contributors | `bun run wowless` fetches its data for a game product (WoW: Forever is `wowf`) into `cache/wowless/`; `lua/wowless.lua` reads it: how the client's functions answer, console variable defaults, constants, the secure addons' namespaces. Its data is downloaded, not shipped. | MIT |
| [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) | `lua/vendor/`: zlib for `C_EncodingUtil` | zlib |
| BlizzardCBOR and base64, from [Questie](https://github.com/Questie/Questie) / [QuestieDB](https://github.com/Questie/QuestieDB) | `lua/vendor/`: CBOR and base64 for `C_EncodingUtil` | GPL-3.0 |
| [wago.tools](https://wago.tools) | The game's art and tables, downloaded per build into `cache/` (never shipped) | |
| Blizzard's interface source ([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source)) | Read at run time from `interfaceRoot` (never shipped) | Blizzard's |
