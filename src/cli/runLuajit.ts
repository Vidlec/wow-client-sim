// One scenario's LuaJIT: its output whole and its exit code; handed on line by line as it comes when live. Past the
// time limit the run is ended, and reported as failed with what it printed so far.
import type { Subprocess } from "bun";
import { ROOT } from "../server/config.ts";
import { createLineReader } from "../server/lineReader.ts";
import { pyFixed } from "./format.ts";

export type LuajitRun = { output: string; code: number };

/** How long to wait for the rest of a run's output once it has ended (a grandchild may hold the pipe open) */
const DRAIN_MS = 5000;
/** A live run longer than this says how long it took */
const LONG_RUN_SECONDS = 60;

/** Every run still going, so Ctrl+C can end them all */
export const runningProcesses = new Set<Subprocess>();

/**
 * @param onLive each piece of output as it comes (a line with its "\n"), for a run shown live; none: only the whole
 */
export const runLuajit = async (
  command: string[],
  environment: Record<string, string | undefined>,
  timeLimitSeconds: number,
  onLive?: (text: string) => void,
): Promise<LuajitRun> => {
  const isLive = onLive !== undefined;
  const say = (text: string): void => onLive?.(text);
  const child = Bun.spawn(command, {
    cwd: ROOT,
    env: environment,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true,
  });
  runningProcesses.add(child);
  const lines: string[] = [];
  // Its two streams, merged line by line as they come (a whole line at a time: the report reads as one stream)
  const pump = async (stream: ReadableStream<Uint8Array>): Promise<void> => {
    const reader = createLineReader(stream);
    for (let line = await reader.next(); line !== null; line = await reader.next()) {
      lines.push(`${line}\n`);
      if (isLive) say(`${line}\n`);
    }
  };
  const reading = Promise.all([pump(child.stdout), pump(child.stderr)]).catch(() => undefined);
  // (A timer cleared once the output is in: a pending one would hold the runner open for its whole length)
  const drained = async (): Promise<void> => {
    let timer: Timer | undefined;
    const waited = new Promise<void>((done) => {
      timer = setTimeout(done, DRAIN_MS);
    });
    await Promise.race([reading, waited]);
    clearTimeout(timer);
  };
  const started = performance.now();
  let isOverTime = false;
  const timer = setTimeout(() => {
    isOverTime = true;
    child.kill();
  }, timeLimitSeconds * 1000);
  const exitCode = await child.exited;
  clearTimeout(timer);
  runningProcesses.delete(child);
  await drained();
  if (isOverTime) {
    const message = `Failed: the scenario ran past its time limit (${timeLimitSeconds} s) and was ended\n`;
    lines.push(message);
    if (isLive) say(message);
    return { output: lines.join(""), code: 1 };
  }
  const seconds = (performance.now() - started) / 1000;
  if (isLive && seconds > LONG_RUN_SECONDS) say(`(${pyFixed(seconds, 0)} s)\n`);
  return { output: lines.join(""), code: exitCode };
};
