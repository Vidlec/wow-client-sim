// The Sim the SDK hands out: the same for a game in this process (local.ts) and the project's daemon's (remote.ts).
// The few things each must do itself are abstract; the steps are Lua run with eval, and the suite and the game's
// tables are read in this process either way (neither needs a running game).
import type { Project } from "../project/config.ts";
import type { PlayOptions } from "../project/results.ts";
import type { Assets } from "../server/assets/index.ts";
import { toLua } from "./failures.ts";
import type {
  EvalResult,
  FramesOptions,
  FramesResult,
  GameState,
  RunOptions,
  RunResult,
  Scene,
  ShotOptions,
  ShotResult,
  SuiteResult,
} from "./types.ts";

export type SimInfo = {
  root: string;
  scenariosDir: string;
  addons: string[];
  /** "local": games in this process (createSim); "daemon": the project's daemon's (connect) */
  mode: "local" | "daemon";
  /** The daemon's address, and whether this call started it */
  daemon?: { port: number; pid: number; started: boolean };
};

/** Where a pointing step points: a frame ("Name", "Name.key", "#id"), text shown on screen, or a point { x, y } */
export type Target = string | { x: number; y: number };

/** A pointing step's target as Lua: "#123" and "Name.key" are frames found by sdkui, else a name or text, or a point */
export const targetLua = (target: Target): string => {
  if (typeof target !== "string") return toLua(target);
  if (/^#\d+$/.test(target) || /^[A-Za-z_]\w*(\.[A-Za-z_]\w*)+$/.test(target)) {
    return `require("sdkui").findFrame(nil, ${toLua(target)})`;
  }
  return toLua(target);
};

export type KillOptions = { loot?: boolean; isTappedByOthers?: boolean; via?: "target" | "nameplate" | "unseen" };
export type SpawnOptions = {
  count?: number;
  distance?: number;
  bearing?: number;
  level?: number;
  aggro?: boolean;
  spellId?: number;
};
export type Profile = {
  name?: string;
  race?: string;
  class?: string;
  level?: number;
  money?: number;
  [key: string]: unknown;
};

export abstract class SimBase {
  abstract readonly info: SimInfo;
  abstract readonly project: Project;

  // -- what each kind does itself -----------------------------------------

  /** Lua in the live game, in a scenario's environment (its steps, G for the game's globals, require) */
  abstract eval(code: string): Promise<EvalResult>;
  /** A Lua file run in the live game as a script (the game's state kept) */
  abstract evalFile(path: string): Promise<EvalResult>;
  /** A scenario in a fresh game (booted ahead when one is), which then stays the live game */
  abstract run(scenario: string, options?: RunOptions): Promise<RunResult & { wasWarm: boolean }>;
  /** A fresh live game, nothing played in it */
  abstract reset(): Promise<{ wasWarm: boolean; seconds: number }>;
  /** The shown frames: the project's addons' by default */
  abstract frames(options?: FramesOptions): Promise<FramesResult>;
  /** One frame in detail: its anchors, scripts, children, rect */
  abstract frame(ref: string): Promise<Record<string, unknown>>;
  abstract state(): Promise<GameState>;
  abstract scene(): Promise<Scene>;
  /** One of the simulator's own requests (lua/boot.lua's handlers: inspect, frameInfo, findQuests, findNpcs...) */
  abstract host(request: Record<string, unknown> & { op: string }): Promise<Record<string, unknown>>;
  /** A PNG of the live screen, a frame of it, or a saved scene */
  abstract shot(options?: ShotOptions): Promise<ShotResult>;
  abstract close(): Promise<void>;

  // -- steps (Lua, run with eval) ------------------------------------------

  /** Any step of the scenarios by name, with these arguments (JSON values, passed as Lua values) */
  step(name: string, ...args: unknown[]): Promise<EvalResult> {
    if (!/^[A-Za-z_]\w*$/.test(name)) return Promise.reject(new Error(`no step ${name}`));
    return this.eval(`return ${name}(${args.map(toLua).join(", ")})`);
  }

  click(target: Target, button = "LeftButton"): Promise<EvalResult> {
    return this.eval(`click(${targetLua(target)}, ${toLua(button)})`);
  }

  hover(target: Target): Promise<EvalResult> {
    return this.eval(`hover(${targetLua(target)})`);
  }

  key(name: string): Promise<EvalResult> {
    return this.step("key", name);
  }

  slash(text: string): Promise<EvalResult> {
    return this.step("slash", text);
  }

  /** An event fired at the addons, as the game fires it */
  fire(event: string, ...args: unknown[]): Promise<EvalResult> {
    return this.step("fire", event, ...args);
  }

  /** The game's clock run on (timers, OnUpdate): the only way time passes in a live game */
  wait(seconds: number): Promise<EvalResult> {
    return this.step("wait", seconds);
  }

  /** The interface reloaded, as /reload does (saved variables, the character and moved frames carried over) */
  reload(): Promise<EvalResult> {
    return this.step("reload");
  }

  setProfile(profile: Profile): Promise<EvalResult> {
    return this.step("setProfile", profile);
  }

  moveTo(uiMapId: number, x: number, y: number): Promise<EvalResult> {
    return this.step("moveTo", uiMapId, x, y);
  }

  accept(questId: number): Promise<EvalResult> {
    return this.step("accept", questId);
  }

  complete(questId: number): Promise<EvalResult> {
    return this.step("complete", questId);
  }

  turnIn(questId: number): Promise<EvalResult> {
    return this.step("turnIn", questId);
  }

  kill(npcId: number, options: KillOptions = {}): Promise<EvalResult> {
    return this.step("kill", npcId, options);
  }

  spawn(npc: number | string, options: SpawnOptions = {}): Promise<EvalResult> {
    return this.step("spawn", npc, options);
  }

  expectText(text: string): Promise<EvalResult> {
    return this.step("expectText", text);
  }

  // -- read in this process --------------------------------------------------

  /** The suite (or the scenarios named), each in its own fresh game side by side: the suite runner's own */
  async test(options: Omit<PlayOptions, "project"> = {}): Promise<SuiteResult> {
    const { playScenarios } = await import("../cli/suite.ts");
    return playScenarios({ ...options, project: this.project });
  }

  readonly #assets = new Map<string, Assets>();

  /** A table of the game's data (DB2: SpellEffect, ItemSparse, UiMap...), rows keyed by column, as wago.tools has it.
   * Downloaded once for the build (the simulator's by default) and cached; no game needed */
  async db2(table: string, options: { build?: string; locale?: string } = {}): Promise<Record<string, string>[]> {
    // (loaded when first asked: a command that only talks to the daemon loads none of this)
    const [{ Assets }, { CACHE_DIR, loadConfig }] = await Promise.all([
      import("../server/assets/index.ts"),
      import("../server/config.ts"),
    ]);
    const config = loadConfig();
    const build = options.build ?? config.build;
    const locale = options.locale ?? config.locale ?? "enUS";
    const key = `${build}|${locale}`;
    let assets = this.#assets.get(key);
    if (!assets) {
      assets = new Assets(CACHE_DIR, { build, locale });
      this.#assets.set(key, assets);
    }
    const rows = await assets.getDb2Rows(table);
    if (!rows) throw new Error(`the table ${table} cannot be had for build ${build}`);
    return rows;
  }

  /** The client build the simulator matches ("1.60.1.71037"): its art, tables and API (the settings') */
  async build(): Promise<string> {
    const { loadConfig } = await import("../server/config.ts");
    return loadConfig().build;
  }

  /** Quests by name or id, as the game's data (QuestieDB) has them */
  async findQuests(text: string, limit = 20): Promise<unknown[]> {
    const answer = await this.host({ op: "findQuests", text, limit });
    return Array.isArray(answer.results) ? answer.results : [];
  }

  /** Creatures by name or id */
  async findNpcs(text: string, limit = 20): Promise<unknown[]> {
    const answer = await this.host({ op: "findNpcs", text, limit });
    return Array.isArray(answer.results) ? answer.results : [];
  }
}

export type Sim = SimBase;
