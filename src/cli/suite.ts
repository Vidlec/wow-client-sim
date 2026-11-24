// The suite runner as a function: playScenarios(options) plays a project's scenarios headless, side by side, and
// returns what came of each run as data (src/project/results.ts). The CLI (play.ts) prints from it; the SDK and the
// MCP server hand it on.
//
// Each run is its own LuaJIT (lua/play.lua), booting the simulator with the project's addons and plugins in a fresh,
// temporary saved-variables folder, so nobody's own saves are touched. A run never outlives the runner: one past its
// time limit is ended and counted as failed. A boot takes about 2 s (the boot cache), the rest is the scenario's.
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { availableParallelism, tmpdir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import type { LoginSpec, Project } from "../project/config.ts";
import { loginText, projectRuntime } from "../project/load.ts";
import type { Failure, PlayOptions, RunResult, SuiteResult } from "../project/results.ts";
import { Assets } from "../server/assets/index.ts";
import { CACHE_DIR, type Config, loadConfig, ROOT, readJsonFile } from "../server/config.ts";
import { findLuajit } from "../server/luajit.ts";
import { requireNativeCore } from "../server/nativeCore.ts";
import { writeRuntimeConfig } from "../server/runtimeConfig.ts";
import { loadSettings } from "../server/settings.ts";
import { coverageFolder, coveragePaths, writeReport } from "./coverage.ts";
import { runLuajit, runningProcesses } from "./runLuajit.ts";
import { readDirectives } from "./scenarioFile.ts";

// The races and the classes each may be, as the game allows them
const CHARACTERS: [string, string[]][] = [
  ["Human", ["WARRIOR", "PALADIN", "ROGUE", "PRIEST", "MAGE", "WARLOCK"]],
  ["Dwarf", ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST"]],
  ["NightElf", ["WARRIOR", "HUNTER", "ROGUE", "PRIEST", "DRUID"]],
  ["Gnome", ["WARRIOR", "ROGUE", "MAGE", "WARLOCK"]],
  ["Orc", ["WARRIOR", "HUNTER", "ROGUE", "SHAMAN", "WARLOCK"]],
  ["Scourge", ["WARRIOR", "ROGUE", "PRIEST", "MAGE", "WARLOCK"]],
  ["Tauren", ["WARRIOR", "HUNTER", "SHAMAN", "DRUID"]],
  ["Troll", ["WARRIOR", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE"]],
];

export const DEFAULT_TIME_LIMIT = 900; // seconds a scenario may run before it is ended as failed
const UNTIMED_SECONDS = 1000; // a run with no time from the last suite goes first
const PLAY_LUA = join(ROOT, "lua", "play.lua");

type Runtime = Record<string, unknown>;
type Job = { scenario: string; login: string; runtime: Runtime; shard: string };

/** A path as results give it: relative to the project's root, forward slashes */
const fromRoot = (project: Project, path: string): string =>
  relative(project.root, resolve(path)).replaceAll("\\", "/");

/** The name a run has in the timings file and the report: the same on every system (forward slashes) */
export const runName = (run: Pick<RunResult, "scenario" | "login" | "shard">): string =>
  run.scenario + (run.login ? ` as ${run.login}` : "") + (run.shard ? `, part ${run.shard}` : "");

const timingsPath = (project: Project): string => join(project.scenariosDir, ".timings.json");

const readTimings = (project: Project): Record<string, number> => {
  try {
    return readJsonFile<Record<string, number>>(timingsPath(project));
  } catch {
    return {};
  }
};

/** Written with sorted keys and an indent of one (json.dump's indent=1, sort_keys=True), so its diffs stay small */
const writeTimings = (project: Project, timings: Record<string, number>): void => {
  const sorted = Object.fromEntries(Object.entries(timings).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  try {
    writeFileSync(timingsPath(project), JSON.stringify(sorted, null, 1));
  } catch {
    // A read-only checkout still plays
  }
};

/** Every *.lua straight in the scenarios folder (not in its subfolders: audits, shots, fixtures) */
export const listScenarios = (project: Project): string[] =>
  existsSync(project.scenariosDir)
    ? readdirSync(project.scenariosDir, { withFileTypes: true })
        .filter((entry) => entry.isFile() && entry.name.endsWith(".lua") && !entry.name.startsWith("."))
        .map((entry) => entry.name)
        .sort()
        .map((name) => join(project.scenariosDir, name))
    : [];

/**
 * The scenarios a pattern names (`*` any text, matched anywhere in the name): by name in the scenarios folder, or, with
 * a folder before it (`audits/marks-*`, `sim/scenarios/audits/marks-*.lua`), in that folder (from the working folder,
 * the project's root or the scenarios folder)
 */
export const matchScenarios = (project: Project, name: string): string[] => {
  const slash = Math.max(name.lastIndexOf("/"), name.lastIndexOf("\\"));
  const filePart = (slash >= 0 ? name.slice(slash + 1) : name).replace(/\.lua$/i, "");
  const pattern = new RegExp(filePart.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*"), "i");
  const baseName = (path: string): string => path.replace(/^.*[/\\]/, "").slice(0, -4);
  if (slash < 0) return listScenarios(project).filter((path) => pattern.test(baseName(path)));
  const folderPart = name.slice(0, slash);
  const folder = [resolve(folderPart), resolve(project.root, folderPart), join(project.scenariosDir, folderPart)].find(
    (path) => existsSync(path) && statSync(path).isDirectory(),
  );
  if (!folder) return [];
  return readdirSync(folder, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".lua") && !entry.name.startsWith("."))
    .map((entry) => join(folder, entry.name))
    .filter((path) => pattern.test(baseName(path)))
    .sort();
};

/** A scenario named as a path (from the working folder, or the project's root) or by name in the scenarios folder */
export const findScenario = (project: Project, name: string): string => {
  const withLua = name.endsWith(".lua") ? name : `${name}.lua`;
  const candidates = isAbsolute(name)
    ? [name]
    : [resolve(name), resolve(project.root, name), join(project.scenariosDir, withLua), resolve(withLua)];
  return candidates.find((path) => existsSync(path)) ?? resolve(name);
};

// Temporary saved-variables folders still in use, taken away on Ctrl+C too
const tempFolders = new Set<string>();

const withTempFolder = async <T>(use: (folder: string) => Promise<T>): Promise<T> => {
  const folder = mkdtempSync(join(tmpdir(), "addonsim-play-"));
  tempFolders.add(folder);
  try {
    return await use(folder);
  } finally {
    tempFolders.delete(folder);
    rmSync(folder, { recursive: true, force: true, maxRetries: 3 });
  }
};

/** Ends every run and takes their folders away (the CLI's Ctrl+C) */
export const stopRuns = (): void => {
  for (const child of runningProcesses) child.kill();
  for (const folder of tempFolders) rmSync(folder, { recursive: true, force: true });
};

const asLoginText = (login: string | LoginSpec | undefined): string =>
  login === undefined ? "" : typeof login === "string" ? login : loginText(login);

// What play.lua's report says, read back into failures with where they happened:
//   "Failed: <message>" (more lines may follow), then "  at <file>:<line>" for a check of the scenario's
//   "Lua error (3x): <file>:<line>: <message>", then the traceback, up to a blank line
const AT_LINE = /^ {2}at (.+):(\d+)$/;
const FILE_LINE = /([^\s"'()]+\.(?:lua|xml)):(\d+):/;
const REPORT_END = /^(PASSED|FAILED): \d+ steps/;

/** Interface/AddOns/<Addon>/... (as the simulator names an addon's files) as the file on disk, when the addon is the project's */
const addonFile = (project: Project, file: string): string => {
  const found = /^Interface\/AddOns\/([^/]+)\/(.+)$/i.exec(file.replaceAll("\\", "/"));
  const addon = found && project.addons.find((candidate) => candidate.name.toLowerCase() === found[1]?.toLowerCase());
  return addon && found ? join(addon.dir, found[2] ?? "") : file;
};

const withPlace = (project: Project, failure: Failure, file: string, line: string): Failure => {
  const absolute = addonFile(project, file);
  return { ...failure, file: absolute, line: Number.parseInt(line, 10) };
};

/** The traceback's own frames: those of the addons and the scenario, not the simulator's or LuaJIT's */
const trimTraceback = (lines: string[]): string => {
  const simulator = join(ROOT, "lua").replaceAll("\\", "/").toLowerCase();
  return lines
    .filter((line) => {
      const plain = line.replaceAll("\\", "/").toLowerCase();
      return !plain.includes(simulator) && !plain.includes("[c]:") && line.trim() !== "stack traceback:";
    })
    .join("\n");
};

export const readFailures = (project: Project, output: string): Failure[] => {
  const failures: Failure[] = [];
  const lines = output.replace(/\r\n/g, "\n").split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const text = lines[index] ?? "";
    const error = /^Lua error(?: \(\d+x\))?: (.*)$/.exec(text);
    if (text.startsWith("Failed: ")) {
      const message = [text.slice("Failed: ".length)];
      let place: RegExpExecArray | null = null;
      while (index + 1 < lines.length) {
        const next = lines[index + 1] ?? "";
        if (next === "" || next.startsWith("Failed: ") || REPORT_END.test(next)) break;
        index += 1;
        const at = AT_LINE.exec(next);
        if (at) place = at;
        else message.push(next);
      }
      const joined = message.join("\n");
      // "the scenario itself failed": a Lua error in the scenario's own code, its file and line in the message
      const isLua = joined.startsWith("the scenario itself failed") || joined.startsWith("the after-check failed");
      let failure: Failure = { kind: isLua ? "lua" : "check", message: joined };
      const inMessage = FILE_LINE.exec(joined);
      if (place) failure = withPlace(project, failure, place[1] ?? "", place[2] ?? "");
      else if (isLua && inMessage) failure = withPlace(project, failure, inMessage[1] ?? "", inMessage[2] ?? "");
      failures.push(failure);
    } else if (error) {
      const message = error[1] ?? "";
      const stack: string[] = [];
      while (index + 1 < lines.length && (lines[index + 1] ?? "") !== "") {
        index += 1;
        stack.push(lines[index] ?? "");
      }
      let failure: Failure = { kind: "lua", message };
      const traceback = trimTraceback(stack);
      if (traceback) failure.traceback = traceback;
      const place = FILE_LINE.exec(message);
      if (place) failure = withPlace(project, failure, place[1] ?? "", place[2] ?? "");
      failures.push(failure);
    }
  }
  return failures;
};

const SCENE_LINE = /^picture: \S*\?compare=(\S+)$/;

const readResult = (project: Project, job: Job, output: string, code: number, seconds: number): RunResult => {
  const failures = readFailures(project, output);
  if (code !== 0 && failures.length === 0) {
    // Ended without its report (a crash, a time limit without a "Failed:" line): its last words are the failure
    const tail = output.trim().split("\n").slice(-10).join("\n");
    failures.push({ kind: "lua", message: tail || `the run ended with code ${code}` });
  }
  const scenes: string[] = [];
  let steps = 0;
  for (const line of output.replace(/\r\n/g, "\n").split("\n")) {
    const scene = SCENE_LINE.exec(line);
    if (scene) scenes.push(join(project.scenariosDir, `${decodeURIComponent(scene[1] ?? "")}.scene.json`));
    const report = /^(?:PASSED|FAILED): (\d+) steps/.exec(line);
    if (report) steps = Number.parseInt(report[1] ?? "0", 10);
  }
  return {
    scenario: fromRoot(project, job.scenario),
    login: job.login,
    shard: job.shard,
    passed: code === 0,
    steps,
    failures,
    seconds,
    scenes,
    output,
  };
};

/** Plays a project's scenarios (or those named), side by side; every run's result, the longest first in the order run */
export const playScenarios = async (options: PlayOptions): Promise<SuiteResult> => {
  const { project } = options;
  await requireNativeCore(); // (built first when it is missing or older than its sources)
  const config = loadConfig();
  // LuaJIT as the server finds it: the settings' own, else the PATH's or one in a known place
  const luajit = findLuajit(loadSettings().luajitPath) ?? "luajit";
  const projectKeys = projectRuntime(project);

  // One runtime config per language: the game's tables in that language, each its own asset store (written as a
  // file of the runner's own, never the server's runtime.json)
  const runtimes = new Map<string, Promise<Runtime>>();
  const runtimeFor = (locale: string): Promise<Runtime> => {
    let runtime = runtimes.get(locale);
    if (!runtime) {
      const localConfig: Config = { ...config, locale };
      const art = new Assets(CACHE_DIR, { build: config.build, locale });
      runtime = writeRuntimeConfig(localConfig, art, `runtime-play-${locale}.json`).then((path) => ({
        ...readJsonFile<Runtime>(path),
        ...projectKeys,
      }));
      runtimes.set(locale, runtime);
    }
    return runtime;
  };

  const coverage = coveragePaths(project);
  const environment: Record<string, string | undefined> = {
    ...process.env,
    ADDONSIM_UPDATE: options.update ? "1" : "0",
    ADDONSIM_COVERAGE_ADDON: project.coverageAddon ?? "",
  };
  if (options.coverage) {
    mkdirSync(coverage.dir, { recursive: true });
    rmSync(coverage.records, { force: true });
    environment.ADDONSIM_COVERAGE = coverage.records;
  }
  // Set by the option, or already in the environment: either way each run records into its own file, merged here
  const isRecording = environment.ADDONSIM_COVERAGE !== undefined && environment.ADDONSIM_COVERAGE !== "";

  const scenarios =
    options.scenarios && options.scenarios.length > 0
      ? options.scenarios.map((name) => findScenario(project, name))
      : listScenarios(project);
  // Each scenario once per login: by default the scenario's own (or the project's); with eachCharacter, every race
  // and class; a login given for all, that one
  const forced = asLoginText(options.login);
  const logins = options.eachCharacter
    ? CHARACTERS.flatMap(([race, classes]) => classes.map((characterClass) => `race=${race},class=${characterClass}`))
    : [forced];
  const projectLogin = loginText(project.login);
  const jobs: Job[] = [];
  for (const scenario of scenarios) {
    const directives = readDirectives(scenario);
    const base = await runtimeFor(directives.locale ?? config.locale ?? "enUS");
    for (const login of logins) {
      const runtime: Runtime = directives.addons ? { ...base, addons: directives.addons } : { ...base };
      // The stand-in interface: none of the game's own addons loaded (the whole one is the settings' blizzardAddons)
      if (directives.interface === "light") delete runtime.blizzardAddons;
      else if (directives.interface === "whole") runtime.blizzardAddons ??= "all";
      const scenarioLogin = login || directives.login || projectLogin;
      for (let shard = 1; shard <= directives.shards; shard += 1) {
        const part = directives.shards > 1 ? `${shard}/${directives.shards}` : "";
        jobs.push({ scenario, login: scenarioLogin, runtime, shard: part });
      }
    }
  }

  const timeLimit = Math.max(1, options.timeLimit ?? DEFAULT_TIME_LIMIT);
  const onLive = jobs.length === 1 ? options.onLiveOutput : undefined;
  const play = (job: Job): Promise<RunResult> =>
    // Each run its own saved-variables folder and its own coverage records, so runs can go side by side
    withTempFolder(async (saved) => {
      const runtimePath = join(saved, "runtime.json");
      writeFileSync(runtimePath, JSON.stringify({ ...job.runtime, savedDir: saved }));
      const coveragePath = join(saved, "coverage.tsv");
      const runEnvironment = {
        ...environment,
        ADDONSIM_LOGIN: job.login,
        ADDONSIM_SHARD: job.shard,
        ...(isRecording ? { ADDONSIM_COVERAGE: coveragePath } : {}),
      };
      const started = performance.now();
      const { output, code } = await runLuajit(
        [luajit, PLAY_LUA, ROOT, runtimePath, job.scenario],
        runEnvironment,
        timeLimit,
        onLive,
      );
      const seconds = (performance.now() - started) / 1000;
      if (isRecording && existsSync(coveragePath)) {
        mkdirSync(coverage.dir, { recursive: true }); // (recording asked for by the environment alone: not made yet)
        appendFileSync(coverage.records, await Bun.file(coveragePath).text());
      }
      return readResult(project, job, output, code, seconds);
    });

  // The longest first (the last run's times), so the slowest never start last
  const timings = readTimings(project);
  const keyOf = (job: Job): string => runName({ ...job, scenario: fromRoot(project, job.scenario) });
  jobs.sort((a, b) => (timings[keyOf(b)] ?? UNTIMED_SECONDS) - (timings[keyOf(a)] ?? UNTIMED_SECONDS));

  // Side by side, one per processor (or as many as asked)
  const workerCount = Math.max(1, options.jobs ?? (availableParallelism() || 4));
  const suiteStarted = performance.now();
  const runs: RunResult[] = [];
  let next = 0;
  const worker = async (): Promise<void> => {
    for (let job = jobs[next++]; job; job = jobs[next++]) {
      const run = await play(job);
      runs.push(run);
      timings[runName(run)] = Math.round(run.seconds * 100) / 100;
      options.onRunDone?.(run);
    }
  };
  await Promise.all(Array.from({ length: Math.min(workerCount, jobs.length) }, worker));

  writeTimings(project, timings);
  const folder = coverageFolder(project);
  if (options.coverage && folder && existsSync(coverage.records)) writeReport(folder, coverage);
  const failed = runs.filter((run) => !run.passed).length;
  return { passed: runs.length - failed, failed, seconds: (performance.now() - suiteStarted) / 1000, runs };
};
