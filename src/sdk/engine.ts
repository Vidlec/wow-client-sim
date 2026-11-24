// The SDK's engine: the project's live game and its pool of games booted ahead, in this process. createSim() hands
// it out as it is; the daemon (daemon.ts) serves it to the CLI, the MCP server and connect(). Every way in reaches
// the same few things: Lua run in the live game (and the steps, which are Lua), scenarios run in a fresh game that
// then stays the live one, what is on screen as data or as a picture, the suite, and the game's tables.
import { existsSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import type { Project } from "../project/config.ts";
import { createMutex } from "../server/mutex.ts";
import { checkFailure, luaFailure, showPath } from "./failures.ts";
import type { Answer, GameProcess } from "./gameProcess.ts";
import { Pool } from "./pool.ts";
import { type GameSpec, RuntimeMaker, specOfScenario } from "./runtime.ts";
import { Shooter } from "./shots.ts";
import type {
  EvalResult,
  Failure,
  FramesOptions,
  FramesResult,
  GameState,
  LuaError,
  RunOptions,
  RunResult,
  Scene,
  ShotOptions,
  ShotResult,
} from "./types.ts";

export type EngineOptions = {
  /** Boot games ahead (true by default; createSim in a test may want none but its own) */
  warm?: boolean;
  /** Watch the addons' files, so a game never runs code older than them (true by default) */
  watch?: boolean;
};

const STALE_NOTICE = "the addons' files changed since this game booted: it still runs the old code";
const FRESH_NOTICE = "the addons' files changed: this is a fresh game (the old one's state is gone)";

const stringList = (value: unknown): string[] => (Array.isArray(value) ? value.map((item) => String(item)) : []);

export class Engine {
  readonly maker: RuntimeMaker;
  readonly pool: Pool;
  #live: GameProcess | null = null;
  // (the daemon serves the CLI and MCP at once: what makes or uses the live game goes one at a time, or a run would
  // end the game another command is in the middle of)
  readonly #lock = createMutex();
  #liveScenario = "";
  #liveStartedAt = 0;
  #shooter: Shooter | null = null;

  constructor(
    readonly project: Project,
    options: EngineOptions = {},
  ) {
    this.maker = new RuntimeMaker(project);
    this.pool = new Pool(this.maker, options);
  }

  get defaultSpec(): GameSpec {
    return specOfScenario(this.project, this.maker.config, null);
  }

  /** Boots a game of the project's default kind ahead (the daemon does it as it starts) */
  prewarm(): void {
    this.pool.prewarm(this.defaultSpec);
  }

  // -- the live game ------------------------------------------------------

  /** The scenario file a name means: a path (absolute, or from the working folder or the project), or a scenario's name */
  resolveScenario(name: string, cwd: string = process.cwd()): string {
    const withLua = name.endsWith(".lua") ? name : `${name}.lua`;
    const candidates = isAbsolute(name)
      ? [name]
      : [resolve(cwd, name), resolve(this.project.root, name), join(this.project.scenariosDir, withLua)];
    const found = candidates.find((path) => existsSync(path) && path.endsWith(".lua"));
    if (!found) throw new Error(`no scenario ${name} (looked in ${showPath(this.project, this.project.scenariosDir)})`);
    return found;
  }

  async #newLive(spec: GameSpec, scenarioPath: string, env: Record<string, string> = {}): Promise<boolean> {
    const { game, wasWarm } = await this.pool.take(spec);
    void this.#live?.kill();
    game.start(scenarioPath, env);
    this.#live = game;
    this.#liveScenario = scenarioPath;
    this.#liveStartedAt = Date.now();
    return wasWarm;
  }

  /**
   * The live game, made when there is none. toRun: code is about to run in it, so a game older than the addons'
   * files is made afresh (looking at one is left to see the old one: the end of a run, before the edit)
   */
  async #game(toRun: boolean): Promise<{ game: GameProcess; notice?: string }> {
    const live = this.#live;
    if (live?.isRunning && !this.pool.isStale(live)) return { game: live };
    if (live?.isRunning && !toRun) return { game: live, notice: STALE_NOTICE };
    const hadOne = live !== null;
    await this.#newLive(this.defaultSpec, join(this.project.scenariosDir, "live.lua"));
    const game = this.#live as GameProcess | null;
    if (!game) throw new Error("the game did not start");
    return hadOne ? { game, notice: FRESH_NOTICE } : { game };
  }

  #command(op: string, fields: Record<string, unknown>, toRun: boolean): Promise<Answer & { notice?: string }> {
    return this.#lock.run(async () => {
      const { game, notice } = await this.#game(toRun);
      const answer = await game.command(op, fields);
      if (!answer) throw new Error(`the game ended:\n${game.log.slice(-30).join("\n")}`);
      if (typeof answer.error === "string" && answer.ok === undefined) throw new Error(answer.error);
      return notice ? { ...answer, notice } : answer;
    });
  }

  #evalResult(answer: Answer & { notice?: string }): EvalResult {
    const failures = stringList(answer.failures).map((text) => checkFailure(this.project, text));
    const errors = (Array.isArray(answer.errors) ? answer.errors : []) as LuaError[];
    for (const error of errors) failures.push(luaFailure(this.project, this.maker.config, error));
    const result: EvalResult = {
      ok: answer.ok === true,
      failures,
      chat: stringList(answer.chat),
      output: stringList(answer.output),
      steps: Number(answer.steps) || 0,
      gameSeconds: Number(answer.gameSeconds) || 0,
      seconds: Number(answer.seconds) || 0,
    };
    if ("result" in answer && answer.result !== undefined && answer.result !== null) result.result = answer.result;
    if (typeof answer.error === "string") result.error = answer.error;
    if (typeof answer.traceback === "string") result.traceback = answer.traceback;
    if (typeof answer.file === "string") result.file = showPath(this.project, answer.file);
    if (typeof answer.line === "number") result.line = answer.line;
    if (answer.notice) result.notice = answer.notice;
    return result;
  }

  /** Lua in the live game, in a scenario's environment: its steps, G (the game's globals), require */
  async eval(code: string): Promise<EvalResult> {
    return this.#evalResult(await this.#command("eval", { code }, true));
  }

  /** A Lua file run in the live game, as eval runs code (its state kept: a script, not a scenario) */
  async evalFile(path: string): Promise<EvalResult> {
    return this.#evalResult(await this.#command("eval", { file: resolve(path) }, true));
  }

  /** A fresh live game (from the pool: at once when one is booted), nothing played in it */
  async reset(): Promise<{ wasWarm: boolean; seconds: number }> {
    const started = performance.now();
    const wasWarm = await this.#lock.run(() =>
      this.#newLive(this.defaultSpec, join(this.project.scenariosDir, "live.lua")),
    );
    return { wasWarm, seconds: (performance.now() - started) / 1000 };
  }

  /**
   * A scenario played in a fresh game (booted ahead when one is), which then stays the live game: what it ended on
   * can be looked at and poked. The report as the suite's (failures with their lines)
   */
  async run(scenario: string, options: RunOptions = {}): Promise<RunResult & { wasWarm: boolean }> {
    const path = this.resolveScenario(scenario);
    const started = performance.now();
    const spec = specOfScenario(this.project, this.maker.config, path, options.login);
    const { wasWarm, answer, game } = await this.#lock.run(async () => {
      const isWarm = await this.#newLive(spec, path, options.update ? { ADDONSIM_UPDATE: "1" } : {});
      const live = this.#live as GameProcess | null;
      if (!live) throw new Error("the game did not start");
      return { wasWarm: isWarm, answer: await live.command("eval", { file: path, draw: true }), game: live };
    });
    if (!answer) throw new Error(`the game ended:\n${game.log.slice(-30).join("\n")}`);
    const result = this.#evalResult(answer);
    const failures: Failure[] = [...result.failures];
    if (result.error) {
      const failure: Failure = { kind: "lua", message: `the scenario itself failed: ${result.error}` };
      if (result.file) failure.file = result.file;
      if (result.line) failure.line = result.line;
      if (result.traceback) failure.traceback = result.traceback;
      failures.push(failure);
    }
    // Lua shortens a long file name in its messages to its last 60 characters ("...ios/x.lua"): the scenario's own
    const shown = showPath(this.project, path);
    for (const failure of failures) {
      if (failure.file?.startsWith("...") && shown.endsWith(failure.file.slice(3))) failure.file = shown;
    }
    const scenes = result.output
      .map((line) => /\?compare=(\.last-run\/[^\s|]+)/.exec(line)?.[1])
      .filter((scene): scene is string => scene !== undefined)
      .map((scene) => showPath(this.project, join(this.project.scenariosDir, `${scene}.scene.json`)));
    return {
      scenario: showPath(this.project, path),
      login: spec.login,
      shard: "",
      passed: failures.length === 0,
      steps: result.steps,
      failures,
      seconds: (performance.now() - started) / 1000,
      scenes,
      output: result.output.join("\n"),
      wasWarm,
    };
  }

  // -- looking ------------------------------------------------------------

  /** The shown frames as rows: the project's addons' by default, everything's with all, or those matching a filter */
  async frames(options: FramesOptions = {}): Promise<FramesResult> {
    const creators = options.all ? [] : this.project.addons.map((addon) => addon.name);
    const answer = await this.#command(
      "frames",
      { filter: options.filter ?? null, creators, limit: options.limit ?? 300 },
      false,
    );
    return answer as unknown as FramesResult;
  }

  /** One frame in detail (its anchors, scripts, children...), by name, Name.key or #id */
  async frame(ref: string): Promise<Record<string, unknown>> {
    return this.#command("findFrame", { ref }, false);
  }

  async state(): Promise<GameState> {
    return (await this.#command("state", {}, false)) as unknown as GameState;
  }

  /** The drawn scene, as the page draws it */
  async scene(): Promise<Scene> {
    return (await this.#command("scene", {}, false)) as unknown as Scene;
  }

  /** One of the simulator's own requests (lua/boot.lua's handlers: inspect, frameInfo, findQuests, findNpcs...) */
  host(request: Record<string, unknown> & { op: string }): Promise<Answer> {
    return this.#command("host", { request }, false);
  }

  /** A picture of the live game's screen (or of a frame of it), or of a scene a scenario saved */
  async shot(options: ShotOptions = {}): Promise<ShotResult> {
    this.#shooter ??= new Shooter(this.project, this.maker.config);
    let scene: Scene;
    let notice: string | undefined;
    if (options.scene) {
      scene = this.#shooter.readScene(options.scene);
    } else {
      const answer = await this.#command("scene", {}, false);
      notice = answer.notice;
      scene = answer as unknown as Scene;
    }
    let crop: [number, number, number, number] | null = null;
    if (options.frame) {
      const info = await this.frame(options.frame);
      const rect = info.rect as number[] | undefined;
      if (!rect || rect.length < 4) throw new Error(`the frame ${options.frame} is not on screen`);
      crop = [rect[0] ?? 0, rect[1] ?? 0, rect[2] ?? 0, rect[3] ?? 0];
    }
    const shot = await this.#shooter.draw(scene, { ...options, crop });
    return notice ? { ...shot, notice } : shot;
  }

  describeLive(): { running: boolean; scenario?: string; ageSeconds?: number; stale?: boolean } {
    const live = this.#live;
    if (!live?.isRunning) return { running: false };
    return {
      running: true,
      scenario: showPath(this.project, this.#liveScenario),
      ageSeconds: Math.round((Date.now() - this.#liveStartedAt) / 1000),
      stale: this.pool.isStale(live),
    };
  }

  async close(): Promise<void> {
    const live = this.#live;
    this.#live = null;
    await Promise.all([live?.kill(), this.pool.close()]);
    await this.#shooter?.close();
  }
}
