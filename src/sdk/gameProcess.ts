// One game: LuaJIT running lua/sdkplay.lua (play.lua, booted before it knows what to play). It boots, says it is
// ready, is given its scenario (or none: a live game), then answers commands one at a time. Its answers are the
// stdout lines that start with \x1e; every other line (stdout and stderr) is what it printed, kept for the report.
// When the SDK goes away its pipe closes, and the game ends by itself (it reads end of input), so none is left over.
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Subprocess } from "bun";
import { ROOT } from "../server/config.ts";
import { createLineReader } from "../server/lineReader.ts";
import { createMutex } from "../server/mutex.ts";
import type { GameSpec, Runtime } from "./runtime.ts";

const ANSWER = "\x1e";
const LOG_LIMIT = 4000;

export type Answer = Record<string, unknown>;

export type FinishResult = { output: string; code: number };

let nextGameId = 0;

export class GameProcess {
  readonly id = ++nextGameId;
  readonly bootedAt = Date.now();
  /** Resolves once the game has booted (its boot seconds), or rejects when it could not */
  readonly ready: Promise<{ bootSeconds: number }>;
  /** What it printed, every line (the boot's, the steps' notes, the report) */
  readonly log: string[] = [];
  /** Booted and waiting for its scenario (or given one since) */
  isBooted = false;
  /** The scenario it was given (null: not yet; "" a live game with none) */
  scenario: string | null = null;
  readonly #process: Subprocess<"pipe", "pipe", "pipe">;
  readonly #answers: ((answer: Answer | null) => void)[] = [];
  readonly #mutex = createMutex();
  readonly #savedDir: string;
  #nextId = 0;
  #isEnded = false;

  constructor(
    readonly spec: GameSpec,
    readonly key: string,
    luajit: string,
    runtime: Runtime,
    savedDir: string,
  ) {
    this.#savedDir = savedDir;
    const runtimePath = join(savedDir, "runtime.json");
    writeFileSync(runtimePath, JSON.stringify(runtime));
    this.#process = Bun.spawn([luajit, join(ROOT, "lua", "sdkplay.lua"), ROOT, runtimePath], {
      cwd: ROOT,
      env: { ...process.env, ADDONSIM_LOGIN: spec.login },
      // (no window: a daemon has no console, and a console program it starts would get one of its own, as would
      // whatever LuaJIT runs through the shell: folder listings)
      windowsHide: true,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    let onReady: (value: { bootSeconds: number }) => void = () => {};
    let onFailed: (error: Error) => void = () => {};
    this.ready = new Promise((resolve, reject) => {
      onReady = resolve;
      onFailed = reject;
    });
    this.ready.catch(() => undefined); // (a game no one waits for may fail quietly)
    let isReady = false;
    this.#answers.push((answer) => {
      if (answer && answer.ready === true) {
        isReady = true;
        this.isBooted = true;
        onReady({ bootSeconds: Number(answer.bootSeconds) || 0 });
      } else {
        onFailed(new Error(`the game did not boot:\n${this.log.slice(-40).join("\n")}`));
      }
    });
    void this.#pump(this.#process.stdout, true);
    void this.#pump(this.#process.stderr, false);
    void this.#process.exited.then(() => {
      this.#isEnded = true;
      if (!isReady) onFailed(new Error(`the game ended as it booted:\n${this.log.slice(-40).join("\n")}`));
      for (const waiter of this.#answers.splice(0)) waiter(null);
      rmSync(this.#savedDir, { recursive: true, force: true, maxRetries: 3 });
    });
  }

  get isRunning(): boolean {
    return !this.#isEnded && this.#process.exitCode === null;
  }

  get exited(): Promise<number> {
    return this.#process.exited;
  }

  async #pump(stream: ReadableStream<Uint8Array>, isStdout: boolean): Promise<void> {
    const lines = createLineReader(stream);
    for (let line = await lines.next(); line !== null; line = await lines.next()) {
      if (isStdout && line.startsWith(ANSWER)) {
        let answer: Answer;
        try {
          answer = JSON.parse(line.slice(1)) as Answer;
        } catch {
          answer = { error: "the game answered with something that is not JSON" };
        }
        this.#answers.shift()?.(answer);
        continue;
      }
      this.log.push(line);
      if (this.log.length > LOG_LIMIT) this.log.splice(0, this.log.length - LOG_LIMIT);
    }
  }

  #send(message: Record<string, unknown>): Promise<Answer | null> {
    return new Promise((resolve) => {
      if (!this.isRunning) {
        resolve(null);
        return;
      }
      this.#answers.push(resolve);
      this.#process.stdin.write(`${JSON.stringify(message)}\n`);
      void this.#process.stdin.flush();
    });
  }

  /** Gives the booted game its scenario: a path (played in it, or naming the live game's scenes) and its switches */
  start(scenarioPath: string, env: Record<string, string> = {}): void {
    this.scenario = scenarioPath;
    this.#process.stdin.write(`${JSON.stringify({ path: scenarioPath, env })}\n`);
    void this.#process.stdin.flush();
  }

  /** One command, after the one before has been answered; null when the game has ended */
  command(op: string, fields: Record<string, unknown> = {}): Promise<Answer | null> {
    return this.#mutex.run(async () => {
      this.#nextId += 1;
      return this.#send({ ...fields, op, id: this.#nextId });
    });
  }

  /** Ends the scenario: play.lua writes its report and the process ends. What it printed, and its exit code */
  async finish(): Promise<FinishResult> {
    const before = this.log.length;
    await this.command("finish");
    this.#process.stdin.end();
    const code = await this.#process.exited;
    // (its last lines may still be on their way through the pipe)
    await Bun.sleep(20);
    return { output: this.log.slice(before).join("\n"), code };
  }

  /** Ends the game; resolves once it has ended and its saved-variables folder is gone */
  async kill(): Promise<void> {
    if (!this.#isEnded) {
      try {
        this.#process.stdin.end();
      } catch {
        // (already closed)
      }
      this.#process.kill();
    }
    await this.#process.exited;
    rmSync(this.#savedDir, { recursive: true, force: true, maxRetries: 3 });
  }
}
