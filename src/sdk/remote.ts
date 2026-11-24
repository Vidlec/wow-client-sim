// A Sim whose games are the project's daemon's (connect): started when none runs, as a process of its own that
// outlives this one, so the next command finds the game warm. Light on purpose: a CLI command that only talks to the
// daemon loads none of the simulator's own code.
import { spawn } from "node:child_process";
import { join } from "node:path";
import type { Project } from "../project/config.ts";
import { SOURCE_ROOT } from "../server/paths.ts";
import { codeStamp, type DaemonFile, pingDaemon, readDaemonFile } from "./daemonFile.ts";
import { SimBase, type SimInfo } from "./sim.ts";
import type {
  DaemonStatus,
  EvalResult,
  FramesOptions,
  FramesResult,
  GameState,
  RunOptions,
  RunResult,
  Scene,
  ShotOptions,
  ShotResult,
} from "./types.ts";

const START_TIMEOUT_MS = 60_000;

export class RemoteSim extends SimBase {
  readonly info: SimInfo;

  constructor(
    readonly project: Project,
    readonly file: DaemonFile,
    started: boolean,
  ) {
    super();
    this.info = {
      root: project.root,
      scenariosDir: project.scenariosDir,
      addons: project.addons.map((addon) => addon.name),
      mode: "daemon",
      daemon: { port: file.port, pid: file.pid, started },
    };
  }

  async #call<T>(method: string, ...args: unknown[]): Promise<T> {
    const response = await fetch(`http://127.0.0.1:${this.file.port}/rpc`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-AddonSim-Token": this.file.token },
      body: JSON.stringify({ method, args }),
    });
    const body = (await response.json()) as { value?: T; error?: string };
    if (body.error !== undefined) throw new Error(body.error);
    return body.value as T;
  }

  eval(code: string): Promise<EvalResult> {
    return this.#call("eval", code);
  }
  evalFile(path: string): Promise<EvalResult> {
    return this.#call("evalFile", path);
  }
  run(scenario: string, options?: RunOptions): Promise<RunResult & { wasWarm: boolean }> {
    return this.#call("run", scenario, options ?? {});
  }
  reset(): Promise<{ wasWarm: boolean; seconds: number }> {
    return this.#call("reset");
  }
  frames(options?: FramesOptions): Promise<FramesResult> {
    return this.#call("frames", options ?? {});
  }
  frame(ref: string): Promise<Record<string, unknown>> {
    return this.#call("frame", ref);
  }
  state(): Promise<GameState> {
    return this.#call("state");
  }
  scene(): Promise<Scene> {
    return this.#call("scene");
  }
  host(request: Record<string, unknown> & { op: string }): Promise<Record<string, unknown>> {
    return this.#call("host", request);
  }
  shot(options?: ShotOptions): Promise<ShotResult> {
    return this.#call("shot", options ?? {});
  }
  /** (the daemon keeps running: other commands use it) */
  close(): Promise<void> {
    return Promise.resolve();
  }
}

/** The command that runs the daemon in the foreground: the CLI from the sources */
const daemonCommand = (project: Project): string[] => [
  process.execPath,
  "run",
  join(SOURCE_ROOT, "src", "cli", "main.ts"),
  "daemon",
  "run",
  "--project",
  project.root,
];

/** Starts the project's daemon as a process of its own (it outlives this one); its file once it answers */
export const startDaemon = async (project: Project): Promise<DaemonFile> => {
  const [command = "", ...args] = daemonCommand(project);
  const child = spawn(command, args, { cwd: project.root, detached: true, stdio: "ignore", windowsHide: true });
  child.unref();
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const file = readDaemonFile(project.root);
    if (file && (await pingDaemon(file))) return file;
    await Bun.sleep(100);
  }
  throw new Error(`the daemon did not start in ${START_TIMEOUT_MS / 1000} s (try: addonsim daemon run)`);
};

/** The running daemon of a project, or null */
export const findDaemon = async (project: Project): Promise<{ file: DaemonFile; status: DaemonStatus } | null> => {
  const file = readDaemonFile(project.root);
  const status = file ? await pingDaemon(file) : null;
  return file && status ? { file, status } : null;
};

export const connectDaemon = async (project: Project): Promise<RemoteSim> => {
  const running = await findDaemon(project);
  if (running && (running.file.codeStamp ?? 0) >= codeStamp()) return new RemoteSim(project, running.file, false);
  // (one running the simulator's code from before it changed: ended, and started afresh)
  if (running) await stopAndWait(project, running.file);
  return new RemoteSim(project, await startDaemon(project), true);
};

const stopAndWait = async (project: Project, file: DaemonFile): Promise<void> => {
  await fetch(`http://127.0.0.1:${file.port}/stop`, {
    method: "POST",
    headers: { "X-AddonSim-Token": file.token },
  }).catch(() => undefined);
  for (let tries = 0; tries < 50 && readDaemonFile(project.root)?.token === file.token; tries += 1)
    await Bun.sleep(100);
};

/** Asks the project's daemon to end; false when none ran */
export const stopDaemon = async (project: Project): Promise<boolean> => {
  const running = await findDaemon(project);
  if (!running) return false;
  await stopAndWait(project, running.file);
  return true;
};
