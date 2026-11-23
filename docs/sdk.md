# The SDK, the CLI and the MCP server: design and costs (2026-11-23)

The developer is often an agent. Its loop: edit addon Lua, run a scenario, read what failed and where, look at the
screen, poke the game, repeat. Each turn of that loop should cost little time and few tokens, and say one thing
plainly.

## What there is

- **One CLI**, `addonsim` (`src/cli/main.ts`, package `bin`): `test`, `run`, `eval`, `ui`, `state`, `shot`, `click`,
  `key`, `event`, `slash`, `reload`, `reset`, `data`, `docs`, `serve`, `daemon`, `mcp`, `init`. It finds the project
  from the working folder (`src/project/select.ts`). Text by default (one fact a line, failures as `file:line:
  message`), `--json` for the SDK's types.
- **A TypeScript SDK** (`src/sdk/`, package export `.`): `connect()` (the project's daemon) and `createSim()` (games in
  this process), both a `Sim`: `eval`, `run`, the steps as methods (and `step(name, ...args)` for any), `frames`,
  `frame`, `state`, `scene`, `shot`, `host` (the simulator's own requests), `test` (the suite runner's
  `playScenarios`), `db2`, `findQuests`, `findNpcs`, `close`. Types in `src/sdk/types.ts`.
- **An MCP server** (`addonsim mcp`, `src/mcp/`): the CLI's commands as tools, the screenshot as an image.
- **The reference** from one source: `types/addonsim.lua` (LuaLS `---@meta`) gives editors the signatures, and
  `addonsim docs` and the MCP `docs` tool print it.

## Why this shape

- **A daemon with a live game, not the page's server.** The page's server ticks its game 60 times a second for a
  person watching; an agent wants a game that stands still between commands (an answer does not depend on when it
  was asked) and that runs the scenario steps. The daemon (`src/sdk/daemon.ts`) holds such games and answers over
  HTTP on localhost, with a token from its file (`cache/sdk/daemons/<hash>.json`) so a web page cannot drive it. It
  starts by itself when a command needs it, ends itself after 30 minutes unused, and restarts by itself when the
  simulator's TypeScript is newer than it. The person's own server is never touched.
- **play.lua itself is the live game.** `lua/sdkplay.lua` runs play.lua unchanged, but boots it before telling it
  what to play, and hands it, as its "scenario", a loop that takes commands. So `eval` runs in exactly a scenario's
  environment, with play.lua's own steps (a step added to play.lua or by a plugin is in eval at once), and a
  failed check in eval is reported as in a scenario. Nothing in the existing Lua changed: **no require line was
  added anywhere**; the SDK's Lua is `lua/sdkplay.lua` (an entry point of its own) and `lua/sdkui.lua` (frames and
  state as data, required by it).
- **Games booted ahead.** The boot is most of a short scenario's cost, and it can be done before the scenario is
  known. The pool (`src/sdk/pool.ts`) keeps one game booted for each kind last asked for (language, addons,
  interface, character), at most two. `run` takes one, plays the scenario in it, and the game stays the live one, so
  the agent looks at where it ended. A file watcher on the addons, the project's plugins and modules and the
  simulator's `lua/` drops games booted before a change and boots new ones at once: an edit followed seconds later by
  a `run` still finds a warm game.
- **Not a reload of the addons alone.** Reloading only an addon's files into a running game would leave its old
  frames, hooks and saved state behind: fast, but not what the client does, and a test passing so would mean
  little. `reload` (the game's /reload, 2 s) and a fresh booted-ahead game are the faithful ways.
- **Text for the eyes, pictures when needed.** `ui` lists the shown frames (label, what a click takes, place, size,
  text) for a few hundred tokens; a picture costs about a second and many more tokens, and is there when the look
  itself matters.
- **MCP without the official SDK.** A tools-only server answers four methods (`initialize`, `tools/list`,
  `tools/call`, `ping`); written against the protocol it is some 150 lines and needs no new dependency.
- **Pictures** reuse the page's renderer (`src/ui/engine/picture.ts`, the `?shot=` page) in headless Chrome or Edge,
  served by the SDK itself (`src/sdk/shots.ts`: the art, fonts and atlases from the cache, the scene from memory), so
  no page server need run.

## Measured (this machine, 20 threads, a project with the whole game interface, a quest database and one large addon)

| What | Time |
| --- | --- |
| Cold boot of a game (LuaJIT, boot cache warm) | 2.1 s; first CLI command, starting the daemon: 2.7 s |
| `eval` in a warm game | 0.2 ms in the game; 0.06 s from `bun src/cli/main.ts`, 0.1 s from `bun addonsim` |
| `ui`, `state`, `click`, `key` | about 0.1 s each from the CLI |
| `reset` (a fresh game, booted ahead) | 0.01 s |
| `reload` (/reload in the game) | 2.3 s |
| One scenario, cold (the suite runner) vs warm (`run`) | quest-items 3.2 s vs 1.0 s; kill-counter 3.2 vs 1.2; commands 3.8 vs 1.6 (the rest is the scenario's own game time) |
| Edit, then `run` | warm when the run comes 2.5 s or more after the save (1.0 s); right after it, cold (3.0 s) |
| `shot` (whole screen or a frame) | 0.9 to 1.2 s (Chrome's start, the page's first draw) |
| The suite (`test`, 40 runs side by side) | 20 s (60 s once with the machine busy with other runs) |
| `bun test` (all TypeScript tests, the SDK's included) | 5.7 s |
| A booted game's memory | about 530 MB (working set; a daemon holds the live game and at most two booted ahead) |
