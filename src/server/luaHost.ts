// The Lua host process (LuaJIT running lua/host.lua, the game's Lua 5.1 with the addons): one JSON request line in,
// one JSON line out, one at a time. A start (or /reload) stops the old process, saving its variables first.
import { join } from "node:path";
import type { Subprocess } from "bun";
import type { SimulatorStatus } from "../shared/setup.ts";
import type { ArtSource } from "./art.ts";
import { type Config, ROOT } from "./config.ts";
import { createFrameReader, type FrameReader, type HostReply } from "./frameReader.ts";
import { createLineReader } from "./lineReader.ts";
import { createMutex } from "./mutex.ts";
import { writeRuntimeConfig } from "./runtimeConfig.ts";
import type { StartReporter } from "./startProgress.ts";

export type HostRequest = { op: string; [key: string]: unknown };
export type HostAnswer = Record<string, unknown>;

type Running = {
  process: Subprocess<"pipe", "pipe", "pipe">;
  answers: FrameReader;
};

const STOP_SECONDS = 3;
// The longest a request may take before the simulator counts as hung (an addon's endless loop sent to /api/exec): it
// is stopped, so the clock, the routes and a reload are not held forever behind it
const REQUEST_SECONDS = 60;
// The longest the variables' save may take at a stop, before the simulator is stopped without it
const SAVE_SECONDS = 3;

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
  /** Told how the start goes, part by part (the setup shows it): src/server/startProgress.ts */
  progress: StartReporter | null = null;

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
        const progress = this.progress ?? undefined;
        const runtimePath = await writeRuntimeConfig(this.config, this.art, this.runtimeName, progress);
        progress?.begin("boot", "the game's interface and the addons loading");
        const process = Bun.spawn([this.luajit, join(ROOT, "lua", "host.lua"), ROOT, runtimePath], {
          cwd: ROOT,
          stdin: "pipe",
          stdout: "pipe",
          stderr: "pipe",
          windowsHide: true, // (no console window for it, whoever started the server)
        });
        const answers = createFrameReader(process.stdout);
        this.#running = { process, answers };
        void drainStderr(process.stderr);
        const first = (await answers.next())?.text;
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
      if (this.status.state === "failed") this.progress?.fail("boot", this.status.error ?? "it did not start");
      else {
        // (its time is the step's own: the detail says how it went)
        const errors = typeof this.boot.errors === "number" ? this.boot.errors : 0;
        this.progress?.finish("boot", errors === 0 ? "no errors" : `${errors} ${errors === 1 ? "error" : "errors"}`);
      }
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
  async requestRaw(request: HostRequest): Promise<string> {
    return (await this.requestWithBinary(request)).text;
  }

  /**
   * The answer's JSON text, and the binary frame that followed it when there was one (the scene stream's: a frame or a
   * whole scene; lua/stream.lua)
   */
  requestWithBinary(request: HostRequest): Promise<HostReply> {
    const asked = performance.now();
    return this.#mutex.run(async () => {
      this.lastLockWait = (performance.now() - asked) / 1000;
      return this.#requestLocked(request);
    });
  }

  async #requestLocked(request: HostRequest, seconds = REQUEST_SECONDS): Promise<HostReply> {
    const running = this.#running;
    if (!running || running.process.exitCode !== null) {
      return { text: JSON.stringify({ error: "the simulator is not running", boot: this.boot }) };
    }
    this.#nextId += 1;
    running.process.stdin.write(`${JSON.stringify({ ...request, id: this.#nextId })}\n`);
    await running.process.stdin.flush();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const answer = await Promise.race([
      running.answers.next(),
      new Promise<"late">((resolve) => {
        timer = setTimeout(() => resolve("late"), seconds * 1000);
      }),
    ]);
    clearTimeout(timer);
    if (answer === "late") {
      // (hung: stopped, and said so; its answers are not waited for again)
      if (this.#running === running) this.#running = null;
      running.process.kill(9);
      const error = `the simulator did not answer "${String(request.op)}" within ${seconds} s and was stopped (reload to start it again)`;
      this.status = { state: "failed", error };
      return { text: JSON.stringify({ error, boot: this.boot }) };
    }
    return answer ?? { text: JSON.stringify({ error: "the simulator stopped", boot: this.boot }) };
  }

  async #stopLocked(save: boolean): Promise<void> {
    const running = this.#running;
    this.#running = null;
    if (!running || running.process.exitCode !== null) return;
    if (save) {
      this.#running = running;
      await this.#requestLocked({ op: "save" }, SAVE_SECONDS).catch(() => undefined);
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
