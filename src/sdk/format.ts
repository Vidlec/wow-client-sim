// The SDK's answers as text, for the CLI and the MCP server: short, one fact a line, failures first as
// "file:line: message" (a reader opens the line straight from it), nothing printed that says nothing.
import { failureLine } from "./failures.ts";
import type {
  EvalResult,
  Failure,
  FrameRow,
  FramesResult,
  GameState,
  RunResult,
  ShotResult,
  SuiteResult,
} from "./types.ts";

const TRACEBACK_LINES = 4;

const seconds = (value: number): string => (value < 10 ? value.toFixed(2) : value.toFixed(1));

/** A traceback's lines worth reading: not the simulator's runner's, not Lua's own */
const SKIPPED_FRAME = /^stack traceback:|^\[C\]|[/\\]lua[/\\](play|sdkplay|sim|boot)\.lua:/;

const tracebackLines = (traceback: string | undefined): string[] =>
  (traceback ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line !== "" && !SKIPPED_FRAME.test(line))
    .slice(0, TRACEBACK_LINES)
    .map((line) => `    ${line}`);

export const formatFailure = (failure: Failure): string =>
  [failureLine(failure), ...tracebackLines(failure.traceback)].join("\n");

/** A value as compact JSON (strings as they are) */
const show = (value: unknown): string => (typeof value === "string" ? value : JSON.stringify(value));

export const formatEval = (result: EvalResult): string => {
  const lines: string[] = [];
  if (result.notice) lines.push(`(${result.notice})`);
  if (result.error) {
    const where = result.file ? `${result.file}:${result.line ?? "?"}` : "";
    // (the message often starts with the same place: said once)
    const message =
      where && result.error.startsWith(`${where}: `) ? result.error.slice(where.length + 2) : result.error;
    lines.push(`error${where ? ` at ${where}` : ""}: ${message}`, ...tracebackLines(result.traceback));
  } else if (result.result !== undefined) {
    lines.push(`=> ${show(result.result)}`);
  }
  for (const failure of result.failures) lines.push(`FAIL ${formatFailure(failure)}`);
  for (const line of result.output) lines.push(`print: ${line}`);
  for (const line of result.chat) lines.push(`chat: ${line}`);
  const isClean = result.ok && result.failures.length === 0;
  if (lines.length === 0 || result.steps > 0) {
    const steps =
      result.steps > 0
        ? `, ${result.steps} step${result.steps === 1 ? "" : "s"}` +
          (result.gameSeconds >= 0 ? `, game +${result.gameSeconds}s` : ", game clock restarted")
        : "";
    lines.push(`${isClean ? "ok" : "FAILED"}${steps}`);
  } else if (!isClean && !result.error) {
    lines.push("FAILED");
  }
  return lines.join("\n");
};

const frameLine = (row: FrameRow): string => {
  const parts = [`${"  ".repeat(row.depth)}${row.label}`];
  if (row.ref !== row.label) parts.push(row.ref);
  if (row.type !== "Frame") parts.push(row.type);
  if (row.x !== undefined) parts.push(`${row.x},${row.y} ${row.w}x${row.h}`);
  else parts.push("(no place)");
  if (row.mouse) parts.push("mouse");
  if (row.alpha !== undefined) parts.push(`alpha ${row.alpha}`);
  if (row.text) parts.push(JSON.stringify(row.text.length > 120 ? `${row.text.slice(0, 117)}...` : row.text));
  return parts.join(" ");
};

export const formatFrames = (result: FramesResult, what: string): string => {
  const lines: string[] = [];
  if (result.notice) lines.push(`(${result.notice})`);
  if (result.frames.length === 0) lines.push(`no shown frames ${what}`);
  for (const row of result.frames) lines.push(frameLine(row));
  if (result.isCut) lines.push("... more (narrow it with a filter, or --limit N)");
  return lines.join("\n");
};

export const formatState = (state: GameState): string => {
  const lines: string[] = [];
  if (state.notice) lines.push(`(${state.notice})`);
  const where = state.position;
  lines.push(
    `${state.name}: level ${state.level} ${state.race} ${state.class}, ${state.money} copper, ` +
      `map ${where.uiMapId} at ${where.x}, ${where.y}${where.zone ? ` (${where.zone})` : ""}`,
  );
  lines.push(
    `game time ${state.now}s, screen ${state.screen.width}x${state.screen.height}` +
      `${state.inCombat ? ", in combat" : ""}${state.errors > 0 ? `, ${state.errors} Lua errors` : ""}`,
  );
  if (state.target) {
    const target = state.target;
    lines.push(`target: ${target.name} (level ${target.level}, ${target.health}/${target.healthMax})`);
  }
  lines.push(`quests: ${state.questLog.length} in the log, ${state.completedQuests} done`);
  for (const quest of state.questLog) {
    const objectives = quest.objectives.length > 0 ? `: ${quest.objectives.join("; ")}` : "";
    lines.push(`  ${quest.id} [${quest.level}] ${quest.title}${quest.complete ? " (complete)" : ""}${objectives}`);
  }
  for (const line of state.lastChat) lines.push(`chat: ${line}`);
  return lines.join("\n");
};

export const formatRun = (run: RunResult & { wasWarm?: boolean }): string => {
  const how = run.wasWarm === undefined ? "" : run.wasWarm ? ", warm game" : ", cold boot";
  const who = run.login ? ` as ${run.login}` : "";
  // What the scenario printed comes first (an audit's measurements are its whole point), the verdict last
  const lines = run.output ? [run.output.trimEnd()] : [];
  lines.push(
    `${run.passed ? "PASSED" : "FAILED"} ${run.scenario}${who}${run.shard ? ` part ${run.shard}` : ""} ` +
      `(${run.steps} steps, ${seconds(run.seconds)} s${how})`,
  );
  for (const failure of run.failures) lines.push(formatFailure(failure));
  for (const scene of run.scenes) lines.push(`scene: ${scene}`);
  return lines.join("\n");
};

export const formatSuite = (suite: SuiteResult): string => {
  const lines: string[] = [];
  // (a suite's runs: the verdict and failures only; their whole output is the runner's own log)
  for (const run of suite.runs) if (!run.passed) lines.push(formatRun({ ...run, output: "" }));
  lines.push(`${suite.passed} of ${suite.passed + suite.failed} passed in ${seconds(suite.seconds)} s`);
  return lines.join("\n");
};

export const formatShot = (shot: ShotResult): string =>
  `${shot.notice ? `(${shot.notice})\n` : ""}${shot.path} (${shot.width}x${shot.height}, ${seconds(shot.seconds)} s)`;
