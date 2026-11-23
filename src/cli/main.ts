#!/usr/bin/env bun
// addonsim: the simulator's one command, run from a project's folder (it finds the project: src/project/select.ts).
// `addonsim help` lists the commands; AGENTS.md says how they fit together. The commands that need a game talk to the
// project's daemon (src/sdk/daemon.ts), which keeps one warm, and start it when none runs (saying so on stderr).
import { existsSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import type { Project } from "../project/config.ts";
import { selectProject, takeProjectFlag } from "../project/select.ts";
import type { Sim } from "../sdk/sim.ts";

const HELP = `addonsim <command> [arguments] [--project <dir>] [--json]

Scenarios
  test [name|pattern ...]     the suite (or the scenarios named; a pattern: tracker, map-*), each in a fresh game
                              side by side; prints failures as file:line and a summary  (--update, --jobs N,
                              --login race=Orc,class=WARRIOR, --each-character, --coverage)
  run <scenario>              one scenario in a warm game, which stays up afterwards to look at  (--update, --login)
The live game (the daemon's: kept between commands; its clock moves only in steps such as wait)
  eval <lua> | eval -f <file> Lua in the game, in a scenario's environment (steps, G, require); prints what it returns
  ui [text] [--all]           the shown frames: where, what they say, what a click takes (#id or a name); text: only
                              frames whose name or text holds it; --all: every addon's (default: the project's)
                              --frame <ref>: one frame in detail; --at x,y: the frames under a point; --limit N
  state                       the character, the quest log, the game's clock, the last chat lines
  shot [--frame <ref>] [--scene <saved>] [--out file.png] [--scale 2]   a PNG of the screen (prints its path)
  click <target> [--right]    a frame (#id, Name, Name.key), text on screen, or x,y
  key <KEY>  |  event <EVENT> [args...]  |  slash </command ...>
  reload                      /reload in the game (saved variables kept)
  reset                       a fresh game, nothing played
Other
  data <Table> [text]         a table of the game's data (DB2: SpellEffect, ItemSparse...), rows holding text
  data quests|npcs <text>     quests or creatures by name or id, as the game's data has them
  docs [step|topic]           the scenario API reference (steps, globals); docs cli: this help
  serve                       the simulator's page for this project, to play in the browser
  daemon [status|start|stop|run]   the warm game's process (started by itself when needed)
  mcp                         the MCP server (stdio), for an agent to drive the game with tools
  init [dir]                  a new project: its config, a first scenario, CLAUDE.md, .luarc.json`;

type Args = { positional: string[]; flags: Map<string, string | true> };

const VALUE_FLAGS = new Set(["--frame", "--scene", "--out", "--scale", "--at", "--limit", "--jobs", "--login", "-f"]);

const parseArgs = (args: string[]): Args => {
  const positional: string[] = [];
  const flags = new Map<string, string | true>();
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (arg === "--") {
      positional.push(...args.slice(index + 1));
      break;
    }
    if (arg.startsWith("--") && arg.includes("=")) {
      const at = arg.indexOf("=");
      flags.set(arg.slice(0, at), arg.slice(at + 1));
    } else if (VALUE_FLAGS.has(arg) && index + 1 < args.length) {
      flags.set(arg, args[index + 1] ?? "");
      index += 1;
    } else if (arg.startsWith("--") || (arg.startsWith("-") && arg.length === 2 && !/^-\d/.test(arg))) {
      flags.set(arg, true);
    } else {
      positional.push(arg);
    }
  }
  return { positional, flags };
};

const text = (args: Args, name: string): string | undefined => {
  const value = args.flags.get(name);
  return typeof value === "string" ? value : undefined;
};

const say = (line: string): void => {
  process.stdout.write(`${line}\n`);
};

const note = (line: string): void => {
  process.stderr.write(`${line}\n`);
};

/** The project's daemon, started when none runs (said on stderr: the first command pays the boot) */
const connectSim = async (project: Project, args: Args): Promise<Sim> => {
  if (args.flags.has("--local")) {
    const { createSim } = await import("../sdk/index.ts");
    return createSim({ project });
  }
  const { connectDaemon } = await import("../sdk/remote.ts");
  const sim = await connectDaemon(project);
  if (sim.info.daemon?.started)
    note(`(started the daemon for ${project.root}: this command boots the game, the next ones find it warm)`);
  return sim;
};

const printOr = (args: Args, value: unknown, asText: () => string): void => {
  say(args.flags.has("--json") ? JSON.stringify(value, null, 1) : asText());
};

/** A scenario path from the working folder, absolute (the daemon's working folder is the project's) */
const scenarioArg = (name: string): string => {
  const path = isAbsolute(name) ? name : resolve(name);
  return existsSync(path) ? path : name;
};

const runTest = async (project: Project, args: Args): Promise<number> => {
  const [{ playScenarios, matchScenarios, findScenario }, { formatRun, formatSuite }] = await Promise.all([
    import("./suite.ts"),
    import("../sdk/format.ts"),
  ]);
  // Names as they are; a pattern (no such file or scenario) as the scenarios whose names match it (* any text; with a
  // folder before it, that folder's: audits/marks-*)
  const scenarios: string[] = [];
  for (const name of args.positional) {
    if (existsSync(findScenario(project, name))) {
      scenarios.push(findScenario(project, name));
      continue;
    }
    const matching = matchScenarios(project, name);
    if (matching.length === 0) {
      note(`no scenario matches ${name}`);
      return 2;
    }
    scenarios.push(...matching);
  }
  const isJson = args.flags.has("--json");
  const login = text(args, "--login");
  const jobs = Number(text(args, "--jobs")) || 0;
  const suite = await playScenarios({
    project,
    scenarios,
    update: args.flags.has("--update"),
    coverage: args.flags.has("--coverage"),
    eachCharacter: args.flags.has("--each-character"),
    ...(login ? { login } : {}),
    ...(jobs > 0 ? { jobs } : {}),
    // (a failure as soon as its run ends: a long suite need not be waited out to start reading)
    onRunDone: (run) => {
      if (!isJson && !run.passed) say(formatRun(run));
    },
  });
  if (isJson) say(JSON.stringify(suite, null, 1));
  else say(formatSuite({ ...suite, runs: [] }));
  return suite.failed > 0 ? 1 : 0;
};

const readDocs = async (args: Args): Promise<number> => {
  const topic = args.positional[0];
  if (topic === "cli") {
    say(HELP);
    return 0;
  }
  const { renderDocs } = await import("../sdk/docs.ts");
  const docs = renderDocs(topic);
  if (!docs) {
    note(`no step or topic ${topic} (addonsim docs lists them)`);
    return 2;
  }
  say(docs);
  return 0;
};

const runData = async (project: Project, args: Args): Promise<number> => {
  const [what = "", ...rest] = args.positional;
  const query = rest.join(" ");
  if (!what) {
    note("addonsim data <Table> [text] | data quests <text> | data npcs <text>");
    return 2;
  }
  const limit = Number(text(args, "--limit")) || 20;
  if (what === "quests" || what === "npcs") {
    const sim = await connectSim(project, args);
    const rows = what === "quests" ? await sim.findQuests(query, limit) : await sim.findNpcs(query, limit);
    printOr(args, rows, () => rows.map((row) => JSON.stringify(row)).join("\n") || "nothing found");
    return 0;
  }
  const { createSim } = await import("../sdk/index.ts");
  const sim = await createSim({ project });
  const rows = await sim.db2(what);
  const needle = query.toLowerCase();
  const found = needle
    ? rows.filter((row) => Object.values(row).some((value) => value.toLowerCase().includes(needle)))
    : rows;
  const shown = found.slice(0, limit);
  printOr(args, shown, () =>
    [
      ...shown.map((row) => JSON.stringify(row)),
      `${found.length} of ${rows.length} rows${found.length > limit ? ` (the first ${limit}: --limit N)` : ""}`,
    ].join("\n"),
  );
  return 0;
};

const runLive = async (command: string, project: Project, args: Args): Promise<number> => {
  const format = await import("../sdk/format.ts");
  const sim = await connectSim(project, args);
  try {
    const evalDone = (result: Awaited<ReturnType<Sim["eval"]>>): number => {
      printOr(args, result, () => format.formatEval(result));
      return result.ok && result.failures.length === 0 ? 0 : 1;
    };
    switch (command) {
      case "run": {
        const name = args.positional[0];
        if (!name) {
          note("addonsim run <scenario>");
          return 2;
        }
        const login = text(args, "--login");
        const run = await sim.run(scenarioArg(name), {
          update: args.flags.has("--update"),
          ...(login ? { login } : {}),
        });
        printOr(args, run, () => format.formatRun(run));
        return run.passed ? 0 : 1;
      }
      case "eval": {
        const file = text(args, "-f");
        if (file) return evalDone(await sim.evalFile(resolve(file)));
        const code = args.positional.join(" ");
        if (!code) {
          note("addonsim eval <lua> | eval -f <file>");
          return 2;
        }
        return evalDone(await sim.eval(code === "-" ? await Bun.stdin.text() : code));
      }
      case "ui": {
        const frame = text(args, "--frame");
        if (frame) {
          const info = await sim.frame(frame);
          printOr(args, info, () => JSON.stringify(info));
          return 0;
        }
        const at = text(args, "--at");
        if (at) {
          const [x = 0, y = 0] = at.split(",").map(Number);
          const answer = await sim.host({ op: "inspect", x, y, drawnOnly: !args.flags.has("--all") });
          const frames = (answer.frames as Record<string, unknown>[] | undefined) ?? [];
          printOr(args, frames, () =>
            frames
              .map((row) => {
                const name = String(row.name);
                const ref = name.includes(`#${row.id}`) ? "" : ` #${row.id}`;
                const box = [row.x, row.y, row.w, row.h].map((value) => Math.round(Number(value)));
                return `${name}${ref} ${row.type} ${box[0]},${box[1]} ${box[2]}x${box[3]}${row.mouse ? " mouse" : ""}`;
              })
              .join("\n"),
          );
          return 0;
        }
        const filter = args.positional.join(" ");
        const limit = Number(text(args, "--limit")) || 0;
        const result = await sim.frames({
          ...(filter ? { filter } : {}),
          all: args.flags.has("--all"),
          ...(limit > 0 ? { limit } : {}),
        });
        const what = filter
          ? `with "${filter}"`
          : args.flags.has("--all")
            ? ""
            : "of the project's addons (--all: every addon's)";
        printOr(args, result, () => format.formatFrames(result, what));
        return 0;
      }
      case "state": {
        const state = await sim.state();
        printOr(args, state, () => format.formatState(state));
        return 0;
      }
      case "shot": {
        const frame = text(args, "--frame");
        const scene = text(args, "--scene");
        const out = text(args, "--out");
        const scale = Number(text(args, "--scale")) || 0;
        const shot = await sim.shot({
          ...(frame ? { frame } : {}),
          ...(scene ? { scene } : {}),
          ...(out ? { out: resolve(out) } : {}),
          ...(scale > 0 ? { scale } : {}),
        });
        printOr(args, shot, () => format.formatShot(shot));
        return 0;
      }
      case "click": {
        const target = args.positional.join(" ");
        const point = /^(\d+(?:\.\d+)?),\s*(\d+(?:\.\d+)?)$/.exec(target);
        const button = args.flags.has("--right") ? "RightButton" : "LeftButton";
        return evalDone(await sim.click(point ? { x: Number(point[1]), y: Number(point[2]) } : target, button));
      }
      case "key":
        return evalDone(await sim.key(args.positional[0] ?? ""));
      case "event": {
        const [event = "", ...rest] = args.positional;
        const values = rest.map((value) =>
          /^-?\d+(\.\d+)?$/.test(value) ? Number(value) : value === "true" ? true : value === "false" ? false : value,
        );
        return evalDone(await sim.fire(event, ...values));
      }
      case "slash": {
        // "dance" is "/dance"; and Git Bash turns a lone "/dance" into a path ("C:/Program Files/Git/dance"): taken back
        const typed = args.positional.join(" ").replace(/^[A-Za-z]:[/\\].*?[/\\]Git[/\\]/, "/");
        return evalDone(await sim.slash(typed.startsWith("/") ? typed : `/${typed}`));
      }
      case "reload":
        return evalDone(await sim.reload());
      case "reset": {
        const reset = await sim.reset();
        say(`a fresh game (${reset.wasWarm ? "warm" : "booted"}, ${reset.seconds.toFixed(2)} s)`);
        return 0;
      }
    }
    return 2;
  } finally {
    await sim.close();
  }
};

const runDaemonCommand = async (project: Project, args: Args): Promise<number> => {
  const action = args.positional[0] ?? "status";
  const remote = await import("../sdk/remote.ts");
  if (action === "run") {
    const { runDaemon } = await import("../sdk/daemon.ts");
    await runDaemon(project);
    return -1; // (keeps running)
  }
  if (action === "stop") {
    say((await remote.stopDaemon(project)) ? "stopping the daemon" : "no daemon runs for this project");
    return 0;
  }
  if (action === "start") {
    const running = await remote.findDaemon(project);
    const file = running?.file ?? (await remote.startDaemon(project));
    say(`daemon on port ${file.port} (pid ${file.pid})${running ? ", already running" : ""}`);
    return 0;
  }
  const running = await remote.findDaemon(project);
  printOr(args, running?.status ?? null, () => {
    if (!running) return "no daemon runs for this project (the next command that needs a game starts one)";
    const { status } = running;
    const live = status.live.running
      ? `live game: ${status.live.scenario} (${status.live.ageSeconds} s${status.live.stale ? ", older than the addons' files" : ""})`
      : "no live game";
    const warm = status.warm.map((game) => `${game.key}${game.ready ? "" : " (booting)"}`).join(", ") || "none";
    return `daemon pid ${status.pid} port ${status.port} since ${status.startedAt}\n${live}\nbooted ahead: ${warm}`;
  });
  return 0;
};

const serve = async (project: Project): Promise<number> => {
  const { SOURCE_ROOT, IS_STANDALONE } = await import("../server/paths.ts");
  const command = IS_STANDALONE
    ? [process.execPath, "--project", project.root]
    : [process.execPath, "run", resolve(SOURCE_ROOT, "src", "server", "main.ts"), "--project", project.root];
  const child = Bun.spawn(command, {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
    // From the sources, Bun reads the page's Tailwind plugin from bunfig.toml in the working directory, so the server
    // runs in AddonSim's own folder (the project comes from --project); without it the page loads with no styles
    cwd: IS_STANDALONE ? project.root : SOURCE_ROOT,
    windowsHide: true,
  });
  return child.exited;
};

const main = async (): Promise<number> => {
  const { projectDir, rest } = takeProjectFlag(process.argv.slice(2));
  const [command = "help", ...commandArgs] = rest;
  const args = parseArgs(commandArgs);
  if (command === "help" || command === "--help" || command === "-h") {
    say(HELP);
    return 0;
  }
  if (command === "docs") return readDocs(args);
  if (command === "init") {
    const { initProject } = await import("../sdk/init.ts");
    return initProject(resolve(args.positional[0] ?? "."));
  }
  const project = await selectProject(projectDir);
  switch (command) {
    case "test":
      return runTest(project, args);
    case "data":
      return runData(project, args);
    case "daemon":
      return runDaemonCommand(project, args);
    case "serve":
      return serve(project);
    case "mcp": {
      const { runMcpServer } = await import("../mcp/server.ts");
      await runMcpServer(project);
      return -1;
    }
    case "run":
    case "eval":
    case "ui":
    case "state":
    case "shot":
    case "click":
    case "key":
    case "event":
    case "slash":
    case "reload":
    case "reset":
      return runLive(command, project, args);
  }
  note(`no command ${command} (addonsim help)`);
  return 2;
};

try {
  const code = await main();
  if (code >= 0) process.exit(code);
} catch (error) {
  note(`addonsim: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
