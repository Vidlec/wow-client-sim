// The project's daemon: one engine (engine.ts: the live game and the games booted ahead) kept running between
// commands, so `addonsim eval` answers in milliseconds and `addonsim run` starts a scenario at once. The CLI starts it
// when a command needs a game and none runs (and says so); the MCP server is one too, for as long as it runs. It ends
// itself after a while unused (ADDONSIM_DAEMON_IDLE minutes, 30 by default).
//
// Its API: POST /rpc { method, args } -> { value } or { error }, GET /status, POST /stop; each with the token of its
// file (a page in a browser cannot read it, so cannot drive the daemon, which runs any Lua it is given). Where it is, per project: cache/sdk/daemons/<hash>.json.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import type { Project } from "../project/config.ts";
import { codeStamp, DAEMONS_DIR, type DaemonFile, daemonFilePath, pingDaemon, readDaemonFile } from "./daemonFile.ts";
import { Engine } from "./engine.ts";
import type { DaemonStatus } from "./types.ts";

const DEFAULT_IDLE_MINUTES = 30;

type Method = (engine: Engine, args: unknown[]) => Promise<unknown>;

/** What the daemon does, by name: the engine's own, with its arguments as JSON gave them */
const METHODS: Record<string, Method> = {
  eval: (engine, [code]) => engine.eval(String(code ?? "")),
  evalFile: (engine, [path]) => engine.evalFile(String(path ?? "")),
  run: (engine, [scenario, options]) => engine.run(String(scenario ?? ""), (options ?? {}) as never),
  reset: (engine) => engine.reset(),
  frames: (engine, [options]) => engine.frames((options ?? {}) as never),
  frame: (engine, [ref]) => engine.frame(String(ref ?? "")),
  state: (engine) => engine.state(),
  scene: (engine) => engine.scene(),
  host: (engine, [request]) => engine.host(request as never),
  shot: (engine, [options]) => engine.shot((options ?? {}) as never),
};

export type DaemonHandle = { file: DaemonFile; stop: () => Promise<void> };

/**
 * Serves an engine as the project's daemon: its file written, its API on a free port. The engine is the caller's (the
 * MCP server shares its own); stop() ends the API and removes the file
 */
export const serveDaemon = (
  project: Project,
  engine: Engine,
  /** onEnd: called when the daemon is unused for its idle time, or asked to stop (POST /stop) */
  options: { idleMinutes?: number; onEnd?: () => void } = {},
): DaemonHandle => {
  const token = crypto.randomUUID();
  const startedAt = new Date().toISOString();
  const idleMinutes = options.idleMinutes ?? (Number(process.env.ADDONSIM_DAEMON_IDLE) || DEFAULT_IDLE_MINUTES);
  let idleTimer: Timer | null = null;
  const touch = (): void => {
    if (idleTimer) clearTimeout(idleTimer);
    if (options.onEnd && idleMinutes > 0) idleTimer = setTimeout(options.onEnd, idleMinutes * 60_000);
  };
  touch();
  const status = (): DaemonStatus => ({
    root: project.root,
    pid: process.pid,
    port: server.port ?? 0,
    startedAt,
    live: engine.describeLive(),
    warm: engine.pool.describe(),
  });
  const isAllowed = (request: Request): boolean =>
    request.headers.get("X-AddonSim-Token") === token && request.headers.get("Origin") === null;
  const refused = (): Response => new Response("refused", { status: 403 });
  const answerStop = (request: Request): Response => {
    if (!isAllowed(request)) return refused();
    setTimeout(() => options.onEnd?.(), 50);
    return Response.json({ stopping: true });
  };
  const answerCall = async (request: Request): Promise<Response> => {
    if (!isAllowed(request)) return refused();
    touch();
    const body = (await request.json()) as { method?: string; args?: unknown[] };
    const method = METHODS[body.method ?? ""];
    if (!method) return Response.json({ error: `no method ${body.method}` }, { status: 404 });
    try {
      return Response.json({ value: await method(engine, body.args ?? []) });
    } catch (error) {
      return Response.json({ error: error instanceof Error ? error.message : String(error) });
    } finally {
      touch();
    }
  };
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    // (a scenario may run for minutes: no timeout of the request's own)
    idleTimeout: 0,
    routes: {
      "/status": (request) => (isAllowed(request) ? Response.json(status()) : refused()),
      "/stop": { POST: answerStop },
      "/rpc": { POST: answerCall },
    },
    fetch: () => new Response("not found", { status: 404 }),
  });
  const file: DaemonFile = {
    root: project.root,
    port: server.port ?? 0,
    pid: process.pid,
    token,
    startedAt,
    codeStamp: codeStamp(),
  };
  mkdirSync(DAEMONS_DIR, { recursive: true });
  writeFileSync(daemonFilePath(project.root), JSON.stringify(file));
  return {
    file,
    stop: async () => {
      if (idleTimer) clearTimeout(idleTimer);
      // (only our own file: another daemon may have taken the project's place)
      if (readDaemonFile(project.root)?.token === token) rmSync(daemonFilePath(project.root), { force: true });
      await server.stop(true);
    },
  };
};

/** The daemon as a process of its own (`addonsim daemon run`): until stopped, or unused for its idle time */
export const runDaemon = async (project: Project): Promise<void> => {
  const running = readDaemonFile(project.root);
  if (running && (await pingDaemon(running))) {
    process.stdout.write(`a daemon already runs for ${project.root} (pid ${running.pid}, port ${running.port})\n`);
    return;
  }
  const engine = new Engine(project);
  engine.prewarm();
  let handle: DaemonHandle | null = null;
  const stop = async (): Promise<void> => {
    await handle?.stop();
    await engine.close();
    process.exit(0);
  };
  handle = serveDaemon(project, engine, { onEnd: () => void stop() });
  process.on("SIGINT", () => void stop());
  process.on("SIGTERM", () => void stop());
  process.stdout.write(`addonsim daemon for ${project.root} on port ${handle.file.port} (pid ${process.pid})\n`);
};
