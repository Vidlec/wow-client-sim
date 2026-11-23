// The Lua host process (LuaJIT running lua/host.lua, the game's Lua 5.1 with the addons): one JSON request line in,
// one JSON line out, one at a time. A start (or /reload) stops the old process, saving its variables first.
import { join } from "node:path";
import type { Subprocess } from "bun";
import type { SimulatorStatus } from "../shared/setup.ts";
import type { ArtSource } from "./art.ts";
import { type Config, ROOT } from "./config.ts";
import { createLineReader, type LineReader } from "./lineReader.ts";
import { createMutex } from "./mutex.ts";
import { writeRuntimeConfig } from "./runtimeConfig.ts";

export type HostRequest = { op: string; [key: string]: unknown };
export type HostAnswer = Record<string, unknown>;

type Running = {
  process: Subprocess<"pipe", "pipe", "pipe">;
  lines: LineReader;
};

const STOP_SECONDS = 3;

const drainStderr = async (stream: ReadableStream<Uint8Array>): Promise<void> => {
  const lines = createLineReader(stream);
  for (let line = await lines.next(); line !== null; line = await lines.next()) {
    process.stderr.write(`[lua] ${line}\n`);
  }
};

const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));

export class LuaHost {
  /** What the host said as it started (its addons, timings), or { error } */
  boot: HostAnswer = {};
  /** Counts the starts: a page seeing it change knows the scene it has is gone */
  generation = 0;
  speed = 1;
  isPaused = false;
  /** How long the last raw request waited for another one to finish, in seconds */
  lastLockWait = 0;
  /** Whether it runs, is starting (the game's files may be fetched first, which takes minutes the first time) or failed */
  status: SimulatorStatus = { state: "stopped" };
  /** LuaJIT's executable */
  luajit = "luajit";
  /** The runtime config's file in the cache (a served project has its own) */
  runtimeName = "runtime.json";
  /** Why it may not start now (the setup is not done), or null */
  guard: () => string | null = () => null;

  readonly #mutex = createMutex();
  #running: Running | null = null;
  #nextId = 0;

  constructor(
    readonly config: Config,
    /** The game's art and tables (another store when the build or the language changes) */
    public art: ArtSource,
  ) {}

  get isRunning(): boolean {
    return this.#running !== null && this.#running.process.exitCode === null;
  }

  /** Starts the host again (stopping the one running, its variables saved): its boot answer */
  start(): Promise<HostAnswer> {
    const refused = this.guard();
    if (refused) {
      this.status = { state: "stopped", error: refused };
      return Promise.resolve({ error: refused });
    }
    this.status = { state: "starting" };
    return this.#mutex.run(async () => {
      await this.#stopLocked(true);
      try {
        const runtimePath = await writeRuntimeConfig(this.config, this.art, this.runtimeName);
        const process = Bun.spawn([this.luajit, join(ROOT, "lua", "host.lua"), ROOT, runtimePath], {
          cwd: ROOT,
          stdin: "pipe",
          stdout: "pipe",
          stderr: "pipe",
          windowsHide: true, // (no console window for it, whoever started the server)
        });
        const lines = createLineReader(process.stdout);
        this.#running = { process, lines };
        void drainStderr(process.stderr);
        const first = await lines.next();
        try {
          this.boot = JSON.parse(first ?? "") as HostAnswer;
        } catch {
          this.boot = { error: first ?? "the simulator did not start" };
        }
      } catch (error) {
        this.boot = { error: `the simulator could not start: ${messageOf(error)}` };
      }
      this.generation += 1;
      const failure = typeof this.boot.error === "string" ? this.boot.error : null;
      this.status =
        failure || !this.isRunning
          ? { state: "failed", error: failure ?? "the simulator stopped" }
          : { state: "running" };
      return this.boot;
    });
  }

  /** Stops the host; save: its addons' variables are written first (as at a logout) */
  stop(save = true): Promise<void> {
    return this.#mutex.run(async () => {
      await this.#stopLocked(save);
      this.status = { state: "stopped" };
    });
  }

  /** An answer read into an object */
  async request(request: HostRequest): Promise<HostAnswer> {
    const text = await this.requestRaw(request);
    try {
      return JSON.parse(text) as HostAnswer;
    } catch {
      return { error: "the simulator answered with something that is not JSON" };
    }
  }

  /** The answer as the JSON text the host wrote: a scene is tens of kilobytes, many times a second, and passed on as is */
  requestRaw(request: HostRequest): Promise<string> {
    const asked = performance.now();
    return this.#mutex.run(async () => {
      this.lastLockWait = (performance.now() - asked) / 1000;
      return this.#requestLocked(request);
    });
  }

  async #requestLocked(request: HostRequest): Promise<string> {
    const running = this.#running;
    if (!running || running.process.exitCode !== null) {
      return JSON.stringify({ error: "the simulator is not running", boot: this.boot });
    }
    this.#nextId += 1;
    running.process.stdin.write(`${JSON.stringify({ ...request, id: this.#nextId })}\n`);
    await running.process.stdin.flush();
    const line = await running.lines.next();
    return line ?? JSON.stringify({ error: "the simulator stopped", boot: this.boot });
  }

  async #stopLocked(save: boolean): Promise<void> {
    const running = this.#running;
    this.#running = null;
    if (!running || running.process.exitCode !== null) return;
    if (save) {
      this.#running = running;
      await this.#requestLocked({ op: "save" }).catch(() => undefined);
      this.#running = null;
    }
    running.process.kill();
    const exited = await Promise.race([
      running.process.exited.then(() => true),
      Bun.sleep(STOP_SECONDS * 1000).then(() => false),
    ]);
    if (!exited) running.process.kill(9);
  }
}
