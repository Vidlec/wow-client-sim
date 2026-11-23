# Splitting the simulator from our addons, and making it fast to develop with (2026-11-23)

The user asked: "detach everything related to OMQ and other addons we did, and put them to a project together with
OMQ, I want to have those two separated, and I want OMQ to use the sim, also make the sim AI development friendly:
implement the best way for scripts and tests to use the sim (sdk, api - figure out what is the best way) - so that
AI development is fast". They chose a monorepo for our addons.

## Where things are now

- **~/AddonSim**: the simulator (Bun + TypeScript, LuaJIT, React page). Not a git repo. Read README.md and the
  memory notes in the brief you were given. `bun run play` runs the suite (58 scenarios, about 25 s); `bun test`,
  `bun run typecheck` (TS 7), `bun run lint` (Biome 2.6) must stay clean.
- **~/WowAddons**: the new monorepo, already made. It is the old ~/Trailhead git repo, and its history is kept. The
  renames are staged, not committed: never run git commands, because the user commits.
  - `addons/OneMoreQuest/`: OMQ. The game's AddOns\OneMoreQuest is a junction to this folder. Its unit tests:
    `cd addons/OneMoreQuest && luajit tests/run.lua` (365 pass). They use their own FakeGame and stay as they are.
  - `addons/QuestieProfit/`: our other addon.
  - `tools/`: release zip (build-zip.py), board and design generators, gathering-nodes.lua (a sim script),
    make-crafted-items.py (broken: it imported AddonSim's deleted Python `assets` module).
- The user's sim settings (%APPDATA%\AddonSim\settings.json, from config.json):
  - addonsRoot: R:\World of Warcraft\_forever_\Interface\AddOns
  - addons: QuestieDB, OneMoreQuest, ForeverDungeonJournal
  - ForeverDungeonJournal is a third-party addon. So is Questie.

## The contract (already written, both of you build on it)

- `src/project/config.ts`: `defineProject`, `ProjectConfig`, `Project`. A project is a folder with an
  `addonsim.config.ts`. It lists the project's own addon folders, the installed addons it also loads, its scenarios
  folder, its Lua plugins, its Lua module path, a coverage addon and a default login.
- `src/project/load.ts`: `findProjectRoot`, `loadProject(cwd)` (a folder without a config is an implicit project of
  the addons in it), and `projectRuntime(project)`, the keys a project adds to the Lua runtime config:
  - `addonDirs`: absolute addon folders, discovered besides addonsRoot.
  - `addons`
  - `plugins`
  - `luaPath`
  - `projectRoot`
  - `scenariosDir`
  - `coverageAddon`
- `src/project/results.ts`: `SuiteResult`, `RunResult` and `Failure` (with file and line). The suite runner returns
  these and every reporter (text, JSON, SDK, MCP) prints from them.

Change the contract only if you must. If you do, keep both sides compiling and say so in your report.

## Ownership (two agents work at the same time; stay in your lane)

**Split agent:** AddonSim made generic, the project mechanics, the migration.
- It owns:
  - `src/project/*` (may extend)
  - `src/cli/play.ts`, `coverage.ts`, `shots.ts`, `scenarioFile.ts`, `format.ts`, `guardRuns.ts`, `runLuajit.ts`
  - `src/server/*`
  - `src/ui/*`
  - every `lua/*` file except new `lua/sdk*.lua`
  - `scenarios/`
  - `README.md`
  - in WowAddons: `package.json`, `addonsim.config.ts`, `sim/`, `.gitignore`
- The suite runner must be callable as a function: `playScenarios(options) => Promise<SuiteResult>`, exported from
  `src/cli/play.ts` or a module beside it. Options:
  - `project`
  - `scenarios?` (paths or names)
  - `login?`
  - `jobs?`
  - `timeLimit?`
  - `update?`
  - `coverage?`
  - `eachCharacter?`
  - `onRunDone?(run)` for live output

  The CLI keeps printing what it prints now. The SDK agent's `addonsim test` calls this function.
- The server must serve a project: a `--project <dir>` flag, or a project found from the working folder. Its
  `addonDirs` and plugins load, and the page shows its addons.

**SDK agent:** the AI-facing surface.
- It owns:
  - `src/sdk/*`
  - `src/mcp/*`
  - `src/cli/main.ts` (the single `addonsim` bin that dispatches subcommands)
  - new `lua/sdk*.lua`, plus at most one `require` line to hook it in. Say where in your report.
  - `docs/` (except this file)
  - `AGENTS.md` / `CLAUDE.md` in AddonSim
  - LuaLS definition files for the scenario API
  - `package.json`'s `bin`, `exports`, `name` and `private`
  - in WowAddons: `CLAUDE.md`, plus `tools/` scripts it ports to the SDK
- Until `playScenarios` lands, code against the contract. Re-read play.ts before you wire it up.

**package.json** is shared. Re-read it right before editing, and change only your keys with the Edit tool.

## Rules (the user's standing preferences)

- Arrow functions only, never the `function` keyword in TS or JS. In Lua, follow each file's existing style.
- TypeScript 7 strict:
  - noUncheckedIndexedAccess
  - exactOptionalPropertyTypes
  - verbatimModuleSyntax
- Biome clean, Bun APIs first, modular and readable. Comments explain why, in the files' existing voice.
- No git commands anywhere.
- Performance matters: say what things cost (boot time, call latency) and keep the fast paths fast.
- Never hardcode quest IDs in OMQ rules. Scenarios may name the quests they test.
- Bun in Git Bash:
  `export PATH="$PATH:/c/Users/vidle/AppData/Local/Microsoft/WinGet/Packages/Oven-sh.Bun_Microsoft.Winget.Source_8wekyb3d8bbwe/bun-windows-x64"`.
  Use `bun x tsc` / `bun x biome` (no `bunx`).
- The user's server runs on port 8765, started by the lead. Don't stop it. If you need a server, start your own with
  `ADDONSIM_PORT=87xx`, `ADDONSIM_SAVED_DIR=<temp>` and `ADDONSIM_NO_BROWSER=1`, and stop it when done.
- Don't delete anything that can't be recovered. A backup of everything is in
  ~/AddonSim-backups/before-split-2026-11-23.
