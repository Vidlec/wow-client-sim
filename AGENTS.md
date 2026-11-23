# AddonSim for agents

AddonSim simulates the WoW: Forever client (1.60.1): addons run in LuaJIT against the game's own interface code.
This file is for an agent (Claude Code or another) that develops addons with it, or develops AddonSim itself.
Commands run from a project's folder (one with `addonsim.config.ts`, or any folder below it). In a project that
depends on AddonSim the command is `bun addonsim ...`; from this checkout, `bun src/cli/main.ts ...` (with no
project around, it tests itself: `scenarios/` with the SimFixture addon).

**Depending on AddonSim.** A project uses a checkout of it, linked: `cd AddonSim && bun install && bun link`, then in
the project `bun link addonsim` (its package.json gets `"addonsim": "link:addonsim"`, and node_modules/addonsim points
at the checkout) and `bun install`. Once AddonSim is published, a git dependency does the same
(`"addonsim": "github:<owner>/AddonSim"`). `bun addonsim init` makes a project's config, a first scenario, a
CLAUDE.md and a .luarc.json; a project without the package can still use the CLI from the checkout.

## The loop

```
bun addonsim run <scenario>        # one scenario, in a warm game: PASSED/FAILED, failures as file:line
bun addonsim ui [text]             # what is on screen, as text (cheap)
bun addonsim shot [--frame <ref>]  # a PNG of it (prints the path; read it to see it)
bun addonsim eval '<lua>'          # poke the game: steps, G (the game's globals)
bun addonsim test                  # the whole suite, before you finish
```

- **The daemon.** Commands that need a game talk to the project's daemon, which keeps a game booted. The first
  command starts it and pays the boot (about 2.7 s, said on stderr); after that, `eval`, `ui`, `state`, `click`
  answer in about 0.1 s (the CLI's own start), and `run` starts a scenario at once. It ends itself after 30 minutes
  unused. `bun addonsim daemon` shows it, `daemon stop` ends it.
- **The live game.** `run` plays the scenario in a fresh game, which then stays up: `ui`, `shot`, `state`, `eval`
  look at where it ended. `reset` gives a fresh game with nothing played; `reload` is /reload in it.
- **Time** passes only in steps: `wait(1)`, and 0.1 s after each step. Between commands the game stands still.
- **Edits.** The daemon watches the addons' files (and the project's plugins, Lua modules, the simulator's lua/).
  After an edit it boots a new game at once, so a `run` a few seconds after a save is warm (1 s instead of 3 s). A
  command that runs code in a live game older than the files makes a fresh game first and says so; `ui`, `shot` and
  `state` keep the old one (to look at where a run ended) and say it is old.

## Commands

`bun addonsim help` lists them; `bun addonsim docs` lists every scenario step. All take `--project <dir>` and
`--json` (the SDK's types, for scripts). Exit code 1 when something failed.

| Command | What it does |
| --- | --- |
| `test [name\|pattern ...]` | The suite, or scenarios by name, path or pattern (`map-*`; with a folder, that folder's: `audits/marks-*`), each in a fresh game side by side. Prints failing runs, then `N of M passed`. `--update` rewrites reference snapshots, `--login race=Orc,class=WARRIOR,level=12`, `--each-character`, `--jobs N`, `--coverage`. |
| `run <scenario>` | One scenario in a warm game, left up afterwards. `--update`, `--login`. |
| `eval '<lua>'`, `eval -f file.lua`, `eval -` | Lua in the live game, in a scenario's environment. One expression prints its value (`=> ...`; frames as `<Button Name #id>`). |
| `ui [text]` | The shown frames of the project's addons: `label [ref] [Type] x,y WxH [mouse] "text"`, indented under the frames they hang in. With text: frames of any addon whose name or text holds it. `--all`: every frame. `--frame <ref>`: one frame in detail (anchors, scripts, children). `--at x,y`: the frames under a point. |
| `state` | Character, position, quest log with counts, target, game clock, last chat lines. |
| `shot` | A PNG of the screen (about 1 s). `--frame <ref>` cuts it to a frame, `--scene <scenario>/<name>` draws a scene a scenario saved, `--out file.png`, `--scale 2`. |
| `click <target>` | A frame (`#id`, `Name`, `Name.key`), text on screen (the topmost that says it), or `x,y`. `--right`. |
| `key <KEY>`, `event <EVENT> [args]`, `slash <command>` | A key (`M`, `ESCAPE`, `SHIFT-1`), an event fired at the addons, a slash command (`slash reload` is `/reload`). |
| `reload`, `reset` | /reload in the live game; a fresh game. |
| `data <Table> [text]` | A DB2 table of the client (`SpellEffect`, `ItemSparse`, `UiMap`...), rows holding text. `data quests <text>`, `data npcs <text>`: the game's quest and creature data. |
| `docs [step]`, `docs cli` | The scenario API, one line a step; one step whole. |
| `serve` | The simulator's page for this project, to play in a browser (port from the settings, 8765). |
| `mcp` | The MCP server on stdio (below). |
| `init [dir]` | A new project: config, `sim/scenarios/first.lua`, CLAUDE.md, .luarc.json. |

Coordinates are screen pixels from the top left (1366x768 by default), as `ui` prints them and `click x,y` takes them.

## Scenarios

A scenario is a Lua file in the project's scenarios folder (`sim/scenarios`). It runs top to bottom on the game's
clock; any Lua error or failed check fails it, and it goes on to its end. Its globals are the steps (`addonsim docs`,
or `types/addonsim.lua` with signatures), `G` (the game's globals) and `require` (the simulator's modules: `game`,
`widgets`...). First lines may say how it runs: `--@login race=Orc,class=WARRIOR,level=12`, `--@addons A, B`,
`--@locale deDE`, `--@interface light`, `--@shards 4`.

```lua
setProfile({ level = 14, race = "Scourge", class = "MAGE" })
moveTo(1413, 0.52, 0.31)                 -- the Barrens (a UiMap id, x and y from 0 to 1)
accept(844)
wait(1)
expect(G.MyAddonFrame:IsShown(), "the addon's frame shows the quest")
expectText("Plainstrider Menace")        -- text anywhere on screen
click("Plainstrider Menace")
snapshot("tracker", "MyAddonFrame")      -- compared with sim/scenarios/golden/<scenario>/tracker.txt
saveScene("after-click")                 -- a picture to look at: addonsim shot --scene <scenario>/after-click
```

## Recipes

- **Reproduce a bug.** Write the steps into a scenario (or try them with `eval` first), with an `expect` of what
  should hold. `bun addonsim run that-scenario` shows the failure as `file:line: expected: ...`; Lua errors as
  `Addon/File.lua:123: Lua error: ...` with the addon's frames of the traceback under it.
- **Check a frame's text.** `bun addonsim ui "Quest name"`, or `eval 'return G.MyAddonFrame.Title:GetText()'`.
- **Make a screenshot.** `bun addonsim shot --frame MyAddonFrame` and read the PNG it prints. A whole screen at
  scale 1 is 1366x768; a frame is cheaper.
- **Add a scenario.** A new `sim/scenarios/<name>.lua`; `bun addonsim run <name>`; then `bun addonsim test`.
  Snapshots are written by their first run; `--update` accepts a changed one (look at it first: `shot --scene`).
- **Look up an id.** `bun addonsim data quests "Plainstrider"`, `data npcs Kobold`, `data ItemSparse "Linen Cloth"`.
- **A script over the game's data or the game:** the SDK (below), with `bun some-script.ts`.

## Pitfalls

- The game's globals answer by their bare names (`UIParent`, `UnitName("player")`) and through `G` (`G.UIParent`), in eval and scenarios alike; a step of the same name (`click`, `key`, `wait`...) wins over a game global, so reach the game's one as `G.<name>`. Assignments stay the scenario's own: set a game global with `G.<name> = value`.
- Time does not pass by itself: after a `click` that starts an animation or a timer, `wait(0.5)`.
- A step that cannot be done does not stop the scenario; it fails it at the end. Read every failure, not only the first.
- In Git Bash a lone `/word` argument is turned into a path: write `slash myaddon` (the slash is added), or quote code
  that starts with `/`.
- A frame without a global name is clicked by its `#id` from `ui`; the id changes between games, so scenarios click
  by name or text.
- `ui` shows only shown frames, and by default only the project's addons': use a filter or `--all` for others.
- Each game has its own fresh saved variables (a temporary folder): your own and the page's are never touched.
- After changing AddonSim's own TypeScript, the next command restarts the daemon by itself (it compares the code's age).

## The SDK (TypeScript, for scripts and `bun test`)

```ts
import { connect, createSim } from "addonsim";
const sim = await connect();               // the project's daemon (the CLI's warm game); createSim(): one of its own
const run = await sim.run("smoke");        // RunResult: passed, failures [{ kind, message, file, line }], scenes
await sim.accept(844);                     // steps as methods (setProfile, moveTo, kill, spawn, click, key...),
await sim.step("walkTo", 1413, 0.5, 0.3);  // or any step by name
const { frames } = await sim.frames({ filter: "Quest" });
const value = await sim.eval("return G.GetMoney()");
const shot = await sim.shot({ frame: "MyAddonFrame" });
const rows = await sim.db2("SpellEffect"); // the client's tables, no game needed
await sim.close();
```

`src/sdk/sdk.test.ts` is a test written so; `~/WowAddons/tools/make-crafted-items.ts` a script.

## MCP

`bun addonsim mcp` is an MCP server on stdio with the tools `eval`, `ui`, `screenshot` (an image), `click`, `key`,
`event`, `slash`, `run`, `test`, `reload`, `state`, `docs`, `data`. It shares the daemon's game with the CLI (or is
the daemon while it runs). A project's `.mcp.json`:

```json
{ "mcpServers": { "addonsim": { "command": "bun", "args": ["addonsim", "mcp"] } } }
```

## Working on AddonSim itself

- `bun test` (the TypeScript's tests, the SDK's among them), `bun run typecheck`, `bun run lint` must stay clean.
- `bun src/cli/main.ts test` in this folder plays the simulator's own scenarios (`scenarios/`, the SimFixture addon).
- Code: `src/sdk/` (engine, daemon, SDK), `src/mcp/`, `src/cli/main.ts`; `lua/sdkplay.lua` (play.lua kept up as a
  live game) and `lua/sdkui.lua` (frames and state as data). The design and its costs: `docs/sdk.md`.
- Arrow functions only in TypeScript; Lua follows each file's style.
