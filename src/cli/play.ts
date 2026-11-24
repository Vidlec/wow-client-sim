// Plays scenarios headless against the addons, without the browser:
//
//   bun run src/cli/play.ts                      every scenario of the project (its scenarios folder)
//   bun run src/cli/play.ts smoke scenarios/a.lua  these (by name, or as paths)
//   ... --project <dir>      another project than the working folder's (in the simulator's own checkout, without a
//                            project: the simulator's self-test, scenarios/ with its fixture addon)
//   ... --update             rewrite the reference snapshots (<scenarios>/golden/) from this run
//   ... --each-character x   play x once for every race and class, each a fresh login
//   ... --coverage           also record what of the project's coverage addon ran: <scenarios>/.coverage/report.txt
//   ... --time-limit=600     end a scenario that runs longer than this many seconds (default 900)
//   ... --jobs=4             how many play side by side (default: one per processor)
//
// A single scenario prints as it goes; several print each report whole as it ends. A run never outlives this script:
// a scenario past its time limit is ended and counted as failed, and when whatever started this script is stopped
// (a shell closed, a task stopped), the script ends and its LuaJIT runs with it. The runner itself is
// playScenarios (suite.ts), which the SDK calls too.
//
// Exits non-zero when a scenario hits a Lua error or a failed check.
import { relative } from "node:path";
import type { RunResult } from "../project/results.ts";
import { selectProject, takeProjectFlag } from "../project/select.ts";
import { pyFixed } from "./format.ts";
import { guardRuns } from "./guardRuns.ts";
import { DEFAULT_TIME_LIMIT, findScenario, playScenarios, runName, stopRuns } from "./suite.ts";

const FLAGS = new Set(["--update", "--each-character", "--coverage"]);

const say = (text: string): void => {
  process.stdout.write(text);
};

/** A number from "--name=N", at least 1; the fallback when it is not there (or not a number) */
const numberFlag = (args: string[], prefix: string, fallback: number): number => {
  let value = fallback;
  for (const arg of args) {
    if (!arg.startsWith(prefix)) continue;
    const parsed = Number.parseInt(arg.slice(prefix.length), 10);
    if (!Number.isNaN(parsed)) value = Math.max(1, parsed);
  }
  return value;
};

const title = (run: RunResult): string => `== ${runName(run)} (${pyFixed(run.seconds, 1)} s)`;

const main = async (): Promise<number> => {
  guardRuns("play");
  const { projectDir, rest: args } = takeProjectFlag(process.argv.slice(2));
  const project = await selectProject(projectDir);
  const named = args.filter((arg) => !FLAGS.has(arg) && !arg.startsWith("--jobs=") && !arg.startsWith("--time-limit="));
  const isEachCharacter = args.includes("--each-character");
  // One scenario played once: its lines as they come, under its name
  let isLive = named.length === 1 && !isEachCharacter;
  let isLiveStarted = false;
  const jobs = numberFlag(args, "--jobs=", 0);
  const result = await playScenarios({
    project,
    scenarios: named,
    update: args.includes("--update"),
    coverage: args.includes("--coverage"),
    eachCharacter: isEachCharacter,
    timeLimit: numberFlag(args, "--time-limit=", DEFAULT_TIME_LIMIT),
    ...(jobs > 0 ? { jobs } : {}),
    onLiveOutput: (text) => {
      if (!isLiveStarted) {
        isLiveStarted = true;
        const path = relative(project.root, findScenario(project, named[0] ?? ""));
        say(`== ${path.replaceAll("\\", "/")}\n`);
      }
      say(text);
    },
    onRunDone: (run) => {
      // (a scenario in parts is several runs: each printed whole)
      if (isLive && !isLiveStarted) isLive = false;
      if (!isLive) say(`${title(run)}\n${run.output}`);
    },
  });

  const runs = result.runs;
  const scenarioCount = new Set(runs.map((run) => `${run.scenario}\0${run.login}`)).size;
  const parts = runs.length !== scenarioCount ? ` (${runs.length} runs)` : "";
  say(`\n${result.passed} of ${runs.length} scenarios passed${parts} in ${pyFixed(result.seconds, 0)} s\n`);
  if (runs.length > 1) {
    // As Python's sorted(reverse=True) on (seconds, name): the longest first, a tie by name backwards
    const times = runs.map((run): [number, string] => [run.seconds, runName(run)]);
    times.sort(([aSeconds, aName], [bSeconds, bName]) => bSeconds - aSeconds || (bName < aName ? -1 : 1));
    const slowest = times
      .slice(0, 5)
      .map(([seconds, name]) => `${name} ${pyFixed(seconds, 0)} s`)
      .join(", ");
    say(`Slowest: ${slowest}\n`);
  }
  return result.failed ? 1 : 0;
};

if (import.meta.main) {
  process.on("SIGINT", () => {
    stopRuns();
    process.exit(130);
  });
  process.exitCode = await main();
}
