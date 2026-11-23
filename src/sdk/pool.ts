// Games booted ahead. A boot is most of what a scenario costs (2 s of 2.5), and it can be done before the scenario is
// known: the pool keeps one game booted for each kind last asked for (src/sdk/runtime.ts's key), so the next run
// starts at once. A change to the code the game loaded (the addons, the project's plugins and modules, the
// simulator's own Lua) makes the games booted before it stale: they are dropped and booted afresh, right after the
// change, so an edit and then a run still finds a warm game (an editor's save to the next command is seconds).
import { type FSWatcher, watch } from "node:fs";
import { join } from "node:path";
import { ROOT } from "../server/config.ts";
import { GameProcess } from "./gameProcess.ts";
import { type GameSpec, type RuntimeMaker, specKey } from "./runtime.ts";

/** Games kept booted at most (each holds the game's whole interface: some 530 MB) */
const MAX_WARM = 2;
const SETTLE_MS = 300; // an editor saving several files: boot again after the last
const WATCHED = /\.(lua|xml|toc)$/i;
const IGNORED = /(^|[/\\])(tests|\.git|node_modules)([/\\]|$)/i;

export class Pool {
  /** When the code last changed (ms since the epoch): a game booted before it is stale */
  changedAt = 0;
  /** Off: nothing is booted ahead (createSim's default in a test, which wants its games and no others) */
  isWarming: boolean;
  readonly #warm: GameProcess[] = [];
  /** Kinds being made now (their runtime config written): not made twice */
  readonly #booting = new Set<string>();
  readonly #watchers: FSWatcher[] = [];
  /** The kinds last asked for, the latest last: booted again after a change */
  readonly #wanted: GameSpec[] = [];
  #settleTimer: Timer | null = null;
  #onChange: ((path: string) => void) | null = null;

  constructor(
    readonly maker: RuntimeMaker,
    options: { warm?: boolean; watch?: boolean } = {},
  ) {
    this.isWarming = options.warm ?? true;
    if (options.watch ?? true) this.#watch();
  }

  /** Told of each change to the code (the engine marks its live game stale) */
  onChange(listener: (path: string) => void): void {
    this.#onChange = listener;
  }

  #watchedFolders(): string[] {
    const project = this.maker.project;
    const config = this.maker.config;
    const folders = new Set<string>([
      join(ROOT, "lua"),
      ...project.addons.map((addon) => addon.dir),
      ...project.luaPath,
    ]);
    for (const plugin of project.plugins) folders.add(join(plugin, ".."));
    // The installed addons the project loads (QuestieDB...): they change rarely, but a game must see it when they do
    for (const name of project.installed) folders.add(join(config.addonsRoot, name));
    return [...folders];
  }

  #watch(): void {
    for (const folder of this.#watchedFolders()) {
      try {
        const watcher = watch(folder, { recursive: true }, (_event, name) => {
          const file = typeof name === "string" ? name : "";
          if (!WATCHED.test(file) || IGNORED.test(file)) return;
          this.#changed(join(folder, file));
        });
        this.#watchers.push(watcher);
      } catch {
        // (a folder not there: an installed addon missing, which the game reports itself)
      }
    }
  }

  #changed(path: string): void {
    this.changedAt = Date.now();
    this.#onChange?.(path);
    for (const game of this.#warm.splice(0)) void game.kill();
    if (this.#settleTimer) clearTimeout(this.#settleTimer);
    this.#settleTimer = setTimeout(() => {
      this.#settleTimer = null;
      // (the latest kind first: the one most likely asked for next)
      for (const spec of [...this.#wanted].reverse()) this.#boot(spec);
    }, SETTLE_MS);
  }

  isStale(game: GameProcess): boolean {
    return game.bootedAt <= this.changedAt;
  }

  async #make(spec: GameSpec): Promise<GameProcess> {
    const { runtime, savedDir } = await this.maker.make(spec);
    return new GameProcess(spec, specKey(spec), this.maker.luajit, runtime, savedDir);
  }

  #boot(spec: GameSpec): void {
    if (!this.isWarming) return;
    const key = specKey(spec);
    if (this.#booting.has(key) || this.#warm.some((game) => game.key === key && game.isRunning)) return;
    this.#booting.add(key);
    void this.#make(spec).then(
      (game) => {
        this.#booting.delete(key);
        this.#warm.push(game);
        // (the oldest kind goes when there are too many)
        while (this.#warm.length > MAX_WARM) void this.#warm.shift()?.kill();
        game.ready.catch(() => {
          const index = this.#warm.indexOf(game);
          if (index >= 0) this.#warm.splice(index, 1);
        });
      },
      () => this.#booting.delete(key),
    );
  }

  /** A game of this kind as booted ahead, else one booting now; another is booted ahead for the next time */
  async take(spec: GameSpec): Promise<{ game: GameProcess; wasWarm: boolean }> {
    const key = specKey(spec);
    this.#want(spec);
    const index = this.#warm.findIndex((game) => game.key === key && game.isRunning && !this.isStale(game));
    const found = index >= 0 ? this.#warm.splice(index, 1)[0] : undefined;
    const game = found ?? (await this.#make(spec));
    // (warm: booted already; one still booting saved some of the time, not all)
    const wasWarm = found?.isBooted === true;
    this.#boot(spec);
    await game.ready;
    return { game, wasWarm };
  }

  #want(spec: GameSpec): void {
    const key = specKey(spec);
    const index = this.#wanted.findIndex((wanted) => specKey(wanted) === key);
    if (index >= 0) this.#wanted.splice(index, 1);
    this.#wanted.push(spec);
    while (this.#wanted.length > MAX_WARM) this.#wanted.shift();
  }

  /** Boots a game of this kind ahead, if none is (the daemon does at its start, for the project's default kind) */
  prewarm(spec: GameSpec): void {
    this.#want(spec);
    this.#boot(spec);
  }

  describe(): { key: string; ready: boolean }[] {
    return this.#warm.map((game) => ({ key: game.key, ready: game.isRunning && game.scenario === null }));
  }

  async close(): Promise<void> {
    for (const watcher of this.#watchers.splice(0)) watcher.close();
    if (this.#settleTimer) clearTimeout(this.#settleTimer);
    await Promise.all(this.#warm.splice(0).map((game) => game.kill()));
  }
}
