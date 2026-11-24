# AddonSim

A simulator of the World of Warcraft client for developing addons, made for **WoW: Forever** (client 1.60.1, game type
Camelot). Your addons run in LuaJIT (the game's Lua 5.1) against the game's own interface code and the client's API,
and the result is drawn in the browser with the game's real art. You can play it by hand in the page, or run scripted
scenarios headless and check the result.

Developing with an AI agent, or from scripts: read [AGENTS.md](AGENTS.md) (the `addonsim` CLI, the TypeScript SDK and
the MCP server).

- **The game's own interface**: Blizzard's FrameXML and addons (from `wow-ui-source`) load as the client loads them:
  the action bars, unit and party frames, chat, minimap, world map, tooltips, menus and Edit Mode. Your addon sits
  among the real frames it will meet in the game.
- **Strict about the API**: a function, event or widget method the client lacks is missing here too (`strictApi`).
  Anything the simulator only stands in for is noted on the page and in each run's report.
- **The game's real art and tables**, from [wago.tools](https://wago.tools) at the client's build, cached locally.
- **Scenarios**: Lua scripts that log in a character, accept and complete quests, kill, loot, walk, click, type and
  check what is on screen. They run headless, side by side, and fail on any Lua error.

## What you need

- **LuaJIT** 2.1, which runs the simulator. The setup finds it on the PATH or where its installers put it, and says
  how to install it when it is missing (Windows: `winget install DEVCOM.LuaJIT`; macOS: `brew install luajit`; Linux:
  your system's `luajit` package).
- **Your addons**: the game's `Interface\AddOns` folder (or any folder of addons). The setup finds the game's own
  folders (`World of Warcraft\_forever_\Interface\AddOns`, from the registry and the usual places).
- **The game's interface source** at the client's build ([Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source),
  branch `forever`). The setup downloads it for you with one button, or uses a checkout you already have.
- **A network connection the first time**: the game's art and tables are fetched from [wago.tools](https://wago.tools)
  at the client's build and cached (a few minutes on the first start, then never again).
- **Google Chrome or Edge**, only for the picture tools (`bun run shots`, comparisons).
- **[Bun](https://bun.sh)** 1.4 or newer, and optionally **[Rust](https://rustup.rs)** for the native core (below).

Or only **Docker**: the image has all of it (below).

## Quick start

AddonSim is built from its sources; there are no binaries to download.

```
bun install
bun run native         (optional, needs Rust: the native core, which draws the scene faster; without it the scene
                        stream is JSON, made in Lua)
bun run start          (or: bun run dev, which restarts the server when its own code changes)
```

Open http://127.0.0.1:8765/ (a first start opens it for you): the setup screen does the rest. Then switch your addons on
in the page's **Addons** tab.

**With Docker** (nothing else to install):

```
docker compose up --build
```

Then open http://localhost:8765/ and choose your AddOns folder in the page's folder browser (your home folder is
mounted read-only for it; `ADDONSIM_FOLDER` names another, the drive the game is on say). The image has Bun, LuaJIT
and the native core built in; the game's files, saved variables, the interface source and the settings are kept in
the `addonsim-data` volume. A project's scenarios run in it too (`addonsim test`): [docs/docker.md](docs/docker.md).

## Settings

The app keeps its settings itself, and the page changes them (its setup screen and settings): every setting below goes
through `POST /api/setup` (`src/shared/setup.ts` has the API). They are kept in the user's settings folder:

| System | Settings |
| --- | --- |
| Windows | `%APPDATA%\AddonSim\settings.json` |
| macOS | `~/Library/Application Support/AddonSim/settings.json` |
| Linux | `~/.config/addonsim/settings.json` |

The data stays in the checkout: `cache/` (the game's files), `saved/` (saved variables), `interface/` (the downloaded
interface source). A `config.json` there from before is read into the settings on the first start, and again whenever
it is changed (so editing it by hand still works). For developers, never needed: `ADDONSIM_PORT` (another port,
beside a server already running), `ADDONSIM_HOST` (the address served on: `0.0.0.0` in a container),
`ADDONSIM_NO_BROWSER=1` (never open the browser), `ADDONSIM_BROWSE` (where the folder browser starts, and the
setup looks for the game: a container's mounted folders), `ADDONSIM_SAVED_DIR` (another saved-variables folder), `ADDONSIM_HOME` (the settings in one folder: a second app, or a
first run from nothing).

| Setting | What it does |
| --- | --- |
| `flavour` | The client the simulator is: `forever` (WoW: Forever). Each is one file in `src/server/flavours/`: its version, build, TOC suffixes, atlas names, interface source, install folder. |
| `addonsRoot` | Your `Interface/AddOns` folder. |
| `addons` | The addons that load, by folder name (the Addons tab changes this). |
| `interfaceRoot` | The game's interface source (`wow-ui-source/Interface`); empty for the one the setup downloaded. |
| `blizzardAddons` | `"all"`: the game's whole interface, as the client loads it. `"light"`: a light stand-in interface (faster to start, less faithful). |
| `strictApi` | `true`: only the client's functions exist, as in the game. |
| `build` | The client build whose art, tables and API the simulator matches; empty for the flavour's own. |
| `tocSuffixes` | Which TOC an addon is read from, in order; empty for the flavour's own (`_Forever`, `_Vanilla`, then the plain one). |
| `screenWidth`, `screenHeight` | The game's screen. |
| `locale` | The client's language (`enUS`, `deDE`...): the game's strings and tables in it. |
| `editModeLayout` | The Edit Mode preset in use: `modern`, `classic` or `gamepad`. |
| `achievementSet` | Forever's tables hold two whole sets of the class, profession, dungeon, raid and season achievements (flags 0x08000000 and 0x10000000). The client finds both by id but lists and counts the first (measured with `/asrec probe`): `a`, the default; `b` lists the other. |
| `autoReload` | Reload the addons whenever one of their files is saved. |
| `fps` | The game's clock, frames a second (10 to 240). |
| `port` | The page's port (taken at the next start). |
| `openBrowser` | Open the page as the app starts, while the setup is not done. |
| `luajitPath` | LuaJIT's executable; empty to find it. |

## The page

- **The game screen**: click, type, hold W A S D to walk, M for the map, Esc for the game menu. The game's own key
  bindings run as in the client. The command box in the header runs slash commands, with Up and Down for the ones typed
  before.
- **Sound** (the speaker in the header): the game's sounds play in the page, at its own sound settings (master and
  channel volumes): the interface's clicks, addons' files (a quest's narration), music. The browser lets the page
  make sound after a first click or key in it. Scenarios see what played in `require("sound").history`.
- **Screen and UI scale** (header): the game's resolution, from 1024x768 to 5120x1440 (4:3, 5:4, 16:10, 16:9, 21:9,
  32:9), and its UI Scale setting (off draws pixel for pixel, as the game does by default). The choice is kept between
  runs; a scenario sets its own with `screen(width, height, uiScale)`.
- **Gamepad**: a controller plugged in plays the game while the page has the focus (the browser's Gamepad API; press a
  button once if the browser has not shown it yet): its buttons go to the game by the client's names (PAD1 to PAD4,
  PADDUP..., PADLSHOULDER, PADLTRIGGER, PADBACK, PADFORWARD), the left stick walks and the right one turns. **Input**
  (header) switches the game's own gamepad interface on: its action bars and Edit Mode's Gamepad layout, the radial
  menu (Start), the navigation cursor in windows (d-pad, A, B), the world map (d-pad left from its quest list to the
  map: the left stick moves its cursor and pans at the edge, the right stick zooms, A and X change the map). The pad keys of the gamepad mode's own bindings are
  the simulator's (the client keeps its defaults inside): d-pad and face buttons for the bars' two diamonds, the
  triggers for the crossbar, the shoulders for targeting, Start the radial menu, Back the UI focus. Kept between runs.
- **Virtual pad** (header): a gamepad drawn on the page, for testing without one: click its buttons, drag its sticks
  (they spring back when let go); Shift-click or right-click holds a button down (a trigger held while another is
  pressed) until clicked again. Opening it switches Input to the gamepad interface (with mouse and keyboard the game
  binds no pad buttons; the pad says so). Drag it by its title; where it stands is kept in the browser.
- **Character**: name, race, class, level, money; in combat, and the game hiding identities or threat from addons.
  The character window shows stats worked out from race, class and level (`lua/stats.lua`, approximate), and what
  the character wears (`profile.equipment`: nothing for a new one; `equip(itemId)` in a scenario, `EquipItemByName`).
- **Achievements**: the client's own (its Achievement, Criteria and ModifierTree tables), earned as the character
  reaches a level or hands quests in, kept with the character. Forever shows them as Legacy challenges, in its Legacy
  window, which opens once the character has a renown level on the legacy track (`legacyRenown` in the profile:
  `setProfile({ legacyRenown = 1 })`; 0 for a new character, as in the game). The client has no encounter journal
  data in this build: its `EJ_*` functions find no tiers, as there.
- **World**: move the character, walk, zoom and rotate the minimap, Edit Mode, enter and leave instances. A picture of
  the continent can stand behind the interface, where the game draws its world.
- **Edit Mode** (World tab, or the game menu's button): the game's own. Pick a frame and drag it, change its settings
  in its dialog (an action bar's icon size, rows, padding...), turn action bars 2 to 8 on in the game's Settings
  (Action Bars), Save (a changed preset asks for a new layout's name), leave. Layouts, the active one, Edit Mode's
  options and the action bars turned on are kept between runs (`saved/_sim.json`), as the account keeps them.
- **Quests**: find quests and quest givers, accept, progress, complete and hand in.
- **Party**: invite simulated members; those with an addon (Questie, or one a project's plugin registers) speak its
  protocol.
- **Addons**: switch the addons in your folder on and off (with what they need), see how long each took to load, and read
  or reset its saved variables.
- **Inspect**: the frames under the mouse, with their names, strata and levels.
- **Events, Errors, Console** (the drawer): every event fired, with a filter; errors with their whole stack; Lua run
  in the game's global scope.

`?tab=addons` (or any tab's name) opens the page on that panel.

## Scenarios

A scenario is a Lua file in a project's scenarios folder (below). It runs top to bottom on the game's clock:

```lua
setProfile({ level = 14, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)          -- the Barrens, at 52, 31
accept(844)                      -- Plainstrider Menace
wait(1)
key("M")
expect(G.WorldMapFrame:IsShown(), "the map opens with M")
hoverCreature(3244)
expectText("Plainstrider Menace")
saveScene("map-and-tooltip")      -- a picture to look at
```

```
bun run play                           every scenario of the project (the self-test: 25 runs, about 10 s)
bun run play smoke scenarios/b.lua     these (by name or path), side by side (one per processor; --jobs=N)
bun run play --project ../MyAddons     another project's suite
bun run play --update                  accept changed reference snapshots
bun run play --each-character x.lua    once for every race and class
```

Each run gets fresh saved variables, so your own saves are never touched. A run fails on any Lua error or failed
check (the report says where: `  at <file>:<line>` under each failure), and prints links to its saved pictures
(`http://localhost:8765/?compare=...` while a server serving the project runs). Each report gives its time, and the
suite the five slowest; the times are kept (`<scenarios>/.timings.json`) so the next run starts the slowest first.
The runner is a function too: `playScenarios(options)` (`src/cli/suite.ts`) returns every run's result as data
(`src/project/results.ts`: passed, failures with file and line, scenes, output).

A scenario's first lines may say how it runs: `--@login race=Orc,class=WARRIOR,level=12`, `--@addons A, B`,
`--@locale deDE`, `--@interface light` (the simulator's stand-in interface instead of the game's whole one), and `--@shards 4` to play it as 4 parts side by side, each taking its share of a list with
`forShard(list)` (`quest-pages` opens its 664 quest pages so).

**Boot cache**: what the boot works out from files that rarely change (the game's tables, atlases, TOCs, XML, the
compiled Lua of the game's interface and the addons) is kept in `cache/boot` as LuaJIT bytecode: a boot takes 2 s
instead of 4.5. An entry is found by its file's write time and size (by a hash of its content where those cannot be
read), so a changed file is always read afresh. `ADDONSIM_BOOT_CACHE=0` turns it off; deleting the folder is safe.

Steps: `setProfile`, `moveTo`, `walk`, `walkTo`, `turn`, `face`, `hold`, `accept`, `progress`, `complete`, `turnIn`,
`abandon`, `kill`, `hunt`, `loot`, `seed`, `talk`, `closeDialog`, `enterInstance`, `leaveInstance`, `targetCreature`,
`hoverCreature`, `joinParty`, `leaveParty`, `memberAccept`, `memberProgress`, `memberComplete`, `memberAbandon`,
`memberMoveTo`, `memberNear`, `memberOnline`, `key`, `gamepadInterface`, `pad`, `padStick`, `slash`, `fire`, `hover`, `click`, `drag`, `wheel`, `zoomMap`,
`mapZoomLevelCount`, `zoomMinimap`, `moveMinimap`, `screen`, `restrict`, `replay`, `wait`, `expect`, `expectText`,
`expectNoText`, `expectChat`, `clearChat`, `draw`, `saveScene`, `snapshot`, `forShard`, `equip`, `unequip`, `reload`. `G` is the game's global table; `require`
reaches the simulator's own modules. `reload()` (or `slash("/reload")`, or an addon's `ReloadUI()`) logs out and boots the
game again in the same run, as /reload does: the addons' saved variables, the character and the frames the player
moved (the layout cache: a frame moved with `StartMoving` is user-placed and put back where it was left as it is made
again) carry over; frames and modules the scenario held are the old game's, so find them again after it.

**Fights** (`lua/combat.lua`): `spawn(npcIdOrName, { count, distance, bearing, level, aggro, spellId })` puts creatures
of the game's data near the player as units (nameplates in range, with the `nameplateShowEnemies` setting on as in the
client; target, focus, mouseover; health, level, rank, side, threat, casts, auras). They aggro, chase, swing and cast;
the player targets them (`target`, `targetNext`, Tab, a click on a plate), swings (`attack`), presses the action bars
(`useAction`, `cast`: costs, cooldowns, the global cooldown, ranges, cast bars), or `fight(id, { slots })` to the end;
`approach`, `waitUntil`, `waitUntilDead`, `lootCorpse`, `release`, `resurrect`, `hurt`, `resetCombat(seed)`,
`enemy(id)`, `combatState()`. Kills count for quests, give experience and loot; the player can die. The rolls come from a
seed, so a fight plays the same every time. The numbers are believable guesses, not the client's (`lua/combat/data.lua`).
The combat log stays kept from addons, as this client keeps it; the page shows its own (`src/shared/combat.ts`).

**Snapshots** (`snapshot("name")`) compare what is drawn with a reference in `<scenarios>/golden/`; the whole interface
and the stand-in one each keep their own. **Pictures** (`saveScene`) are kept for looking at, not compared, in
`<scenarios>/.last-run/`. A scenario also has `projectRoot` and `scenariosDir`, for files of its own, and `root`, the
simulator's folder.

## Projects

The simulator knows nothing of your addons: a **project** says what to play. It is a folder with an
`addonsim.config.ts` (`src/project/config.ts` has every key):

```ts
import { defineProject } from "addonsim";

export default defineProject({
  addons: ["addons/MyAddon"],              // your addons' folders (each with its .toc), found before the AddOns folder's
  installed: ["QuestieDB"],                // addons of the game's AddOns folder (the settings') it plays with
  load: ["QuestieDB", "MyAddon"],          // what loads when a scenario names none (default: installed + addons)
  scenarios: "sim/scenarios",              // every *.lua straight in it is the suite
  plugins: ["sim/plugins/my-party.lua"],   // Lua that extends the simulator (lua/plugins.lua)
  luaPath: ["sim/lib"],                    // where scenarios and plugins require() from, before the simulator
  coverage: "MyAddon",                     // what --coverage records
  gallery: "~/Desktop/gallery",            // where bun run shots puts its pictures
});
```

- `bun run play`, `bun run shots` and `bun run coverage` work on the project of the working folder (its nearest
  config above), or the one `--project <dir>` names. In this checkout with no project they play the simulator's own
  **self-test**: `scenarios/`, with a small fixture addon (`scenarios/fixtures/addons/SimFixture`), a plugin
  (`scenarios/fixtures/plugins`) and a module folder (`scenarios/fixtures/lib`); scenarios that need the quest
  database add QuestieDB with `--@addons`.
- `bun run start --project <dir>` (or started in a project's folder) serves the project: its addons on the Addons
  tab (marked "project"; switching them lasts for the session, the settings' list is untouched), watched for changes
  (auto-reload), its plugins loaded, its scenes on the comparison pages. Without a project the server runs the
  settings' addons, as always.
- A project depends on the simulator as a Bun workspace (Bun links the folder, so the simulator's files are used as
  they are): `"workspaces": ["../AddonSim"]`, `"dependencies": { "addonsim": "workspace:*" }`.

## Plugins

A plugin is a Lua file of the project's (`plugins` in its config), run at every boot after the simulator's modules
and before the saved state, the game's interface and the addons. It uses only `require("plugins")` (`lua/plugins.lua`,
which documents each function), a small API kept stable:

- `registerPartyAddon(name, { label, note, color, isDefault, onJoin, onQuestChanged, onLeave, onMessage })`: an addon
  a simulated party member may run, and what it tells the player's addons. `sendFromMember(member, prefix, text,
  channel, delay)` delivers a member's addon message (CHAT_MSG_ADDON); `partyMembers()`, `playerName()`, `fullName()`;
  `gameGlobals()` gives the game's globals, for a plugin that runs an addon's own code in a sandbox. A member runs no
  addon unless one is named, or a registration says `isDefault`. None is built into the simulator: every party addon
  is a project's plugin. The page's Party tab lists what is registered.
- `addSteps(function(steps, act) ... end)`: scenario steps of the plugin's.
- `onBoot(fn)`: run right before the addons load, the game's interface in.

## Tools

- `recorder/AddonSimRecorder`: an addon for the real game. `/asrec start|stop` records quest, place and fight events
  to replay in a scenario (`replay(path)`); `/asrec api` dumps the client's API surface, console variables and
  constants for the simulator to match; `/asrec probe` measures how the client behaves where its code does not say
  (the order of OnShow, what Raise does to levels, which achievements it lists, what functions answer...).
- `tools/probe-sim.lua`: runs the same probe in the simulator and lists every answer that differs from the
  client's (`luajit tools/probe-sim.lua . cache/runtime.json`). A new question is a new check in the recorder's
  `PROBES`.
- `bun run wowless [product] [ref]`: fetches wowless's data for a product (`wowf` is WoW: Forever) at its newest
  commit. The simulator fetches the flavour's known commit by itself as it first starts.
- `bun run shots`: plays a project's `<scenarios>/shots/` scenarios and renders their scenes to pictures with
  headless Chrome (a server serving the same project must run).
- `bun run play --coverage`: which lines of the project's coverage addon ran (slow); `bun run coverage` rebuilds the
  report (`<scenarios>/.coverage/report.txt`).
- `bun test`, `bun run typecheck`, `bun run lint`: the TypeScript's tests, type check (TypeScript 7) and Biome;
  `bun run test:lua`: the Lua tests that need nothing of the game (`lua/tests/`); `bun run check`: all of them, as CI
  runs them. The scenarios (`bun src/cli/main.ts test`) need the game's files and the interface source: local only.

## CI

- `.github/workflows/ci.yml`: on every push to `main` and every pull request, `bun run check` (the native core's check
  in a job of its own), the Lua tests on Linux and macOS, and the Docker image built and started (its page answers,
  LuaJIT and the native core load in it). There are no binary releases: AddonSim is run from its sources, or the
  image.
- What changed between versions, in detail: `docs/changes/`.

## The code

- `src/server/`: the server (TypeScript on Bun). `main.ts` starts it; `luaHost.ts` runs the simulator (LuaJIT,
  `lua/host.lua`: one JSON line in, one out); `sceneStream.ts` and `clock.ts` tick it and push the frames; `http/`
  holds the API; `assets/` fetches, decodes and caches the game's art and tables. `flavours/` holds what differs
  between clients (one file each); `paths.ts`, `settings.ts` and `config.ts` where the app keeps things, its settings
  and what the simulator runs with; `app.ts` and `setup/` the first-run setup (`src/shared/setup.ts`: its API).
- `src/ui/`: the page, React with [HeroUI](https://heroui.com) and Tailwind. Bun serves it straight from its sources
  (`index.html` is imported by the server; no build step). `engine/` draws the game and sends the input back (a typed
  `GameScreen`, also the ?shot= and ?compare= picture pages); `shell/` is the header, rail, side panel and status
  strip; `panels/` one folder per panel; `sim/` the typed API client and the state store; `flavours/` what is
  game-flavoured (classes, races, colours), one file per flavour.
- `src/cli/`: the scenario runner (`suite.ts`, the CLI `play.ts`), the picture tool, coverage and wowless.
- `native/`: the native core in Rust (the scene's walk and layout, the stream's store), loaded by LuaJIT's FFI when
  built (`bun run native`). `Dockerfile` and `docker/`: the image. `src/project/`: projects (their config, how one is found) and the results the runner returns.
- `lua/`: the simulator itself (`lua/tests/`: its tests that need nothing of the game; `lua/vendor/`: LibDeflate).
- `recorder/`: the recorder addon for the real game; `tools/`: the LuaJIT profilers and the probe; `types/`: the
  scenario API's types for projects' editors; `docs/`: the SDK's guide, designs and the change notes.

## How a frame gets to the screen

At each frame of the game's clock (`fps`, 60 by default) the server sends the simulator one request: the page's input
since the last frame, the tick, and the scene. The simulator answers with what changed in the scene since the frame
before (`lua/stream.lua`): the items new or changed, and the drawing order when it changed. The server pushes that to
every page over a WebSocket (`src/server/sceneStream.ts`, Bun's own WebSockets); a page that joins, or falls behind, is sent the whole scene first. A
frame with the world map open is a few KB, not the whole scene's 120 KB.

The page draws with the GPU (`src/ui/engine/renderers/renderer.ts`): every item a few quads in one buffer, colour,
alpha, greying, blend modes, up to three masks (nine-sliced, with their wrap modes) and clipping in the shader, each
string laid out once with the game's fonts and kept as a texture, all drawn with WebGPU (`webgpu.ts`: a browser
without it is told so on the screen). The picture pages (`?shot=`, `?compare=`) and the screenshots (`addonsim shot`, the
gallery) draw with the same renderer: headless Chrome is driven over DevTools and waits for the page to say "ready". A
new kind of item is a case in the renderer's `draw`.

The status bar shows how it keeps up: the game's frames a second and their time in the simulator, the worst frame of
the last second split into the game's code (input and tick), the drawing list (export) and its changes written (send),
and the page's draws a second with the renderer's time for one.

Inside the simulator, a change to how something looks (a colour, an alpha, the mouse over a button, shown or hidden)
keeps the layout; a change to an object's anchors, size or text throws away its rectangle and those worked out from
it, not every rectangle on the screen. `scenarios/scene-stream.lua` checks both: the page's scene put together from
the frames is the whole export, and the rectangles kept are the ones worked out afresh.

## Credits and licences

See [CREDITS.md](CREDITS.md). The only code of others AddonSim carries is LibDeflate (zlib License); its base64, hex,
CBOR and gzip are its own (`lua/encoding.lua`). It has no licence of its own yet (no LICENSE file). The game's art,
tables and interface source are fetched or read locally and never shipped with it.
