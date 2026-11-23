// What a game the SDK starts runs with: the simulator's runtime config (the settings, the game's data) with the
// project's keys over it (src/project/load.ts), and what a scenario's first lines ask for (its language, addons,
// interface, character). Games booted for the same of these are interchangeable: that is a pool's key.
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readDirectives } from "../cli/scenarioFile.ts";
import type { Project } from "../project/config.ts";
import { loginText, projectRuntime } from "../project/load.ts";
import { Assets } from "../server/assets/index.ts";
import { CACHE_DIR, type Config, loadConfig } from "../server/config.ts";
import { findLuajit } from "../server/luajit.ts";
import { writeRuntimeConfig } from "../server/runtimeConfig.ts";
import { loadSettings } from "../server/settings.ts";

/** What a game is booted for */
export type GameSpec = {
  locale: string;
  /** The addons that load (null: the project's) */
  addons: string[] | null;
  interface: "whole" | "light" | null;
  /** The character, in the runner's form ("race=Orc,class=WARRIOR"), "" for the default */
  login: string;
};

export type Runtime = Record<string, unknown>;

export const specKey = (spec: GameSpec): string =>
  [spec.locale, spec.addons?.join("+") ?? "*", spec.interface ?? "", spec.login].join("|");

/** The spec of a scenario file (its --@ lines), the project's default character unless it names one */
export const specOfScenario = (project: Project, config: Config, path: string | null, login?: string): GameSpec => {
  const directives = path ? readDirectives(path) : null;
  return {
    locale: directives?.locale ?? config.locale ?? "enUS",
    addons: directives?.addons ?? null,
    interface: directives?.interface ?? null,
    login: login ?? directives?.login ?? loginText(project.login),
  };
};

/** The runtime configs of a project, one per language (each its own store of the game's tables), made once */
export class RuntimeMaker {
  readonly config: Config;
  readonly luajit: string;
  readonly #bases = new Map<string, Promise<Runtime>>();

  constructor(readonly project: Project) {
    this.config = loadConfig();
    this.luajit = findLuajit(loadSettings().luajitPath) ?? "luajit";
  }

  #base(locale: string): Promise<Runtime> {
    let base = this.#bases.get(locale);
    if (!base) {
      const art = new Assets(CACHE_DIR, { build: this.config.build, locale });
      base = writeRuntimeConfig({ ...this.config, locale }, art, `runtime-sdk-${locale}.json`).then((path) => ({
        ...(JSON.parse(readFileSync(path, "utf8")) as Runtime),
        ...projectRuntime(this.project),
      }));
      this.#bases.set(locale, base);
    }
    return base;
  }

  /** The runtime of a game: its own saved-variables folder (fresh, temporary), the spec's addons and interface */
  async make(spec: GameSpec): Promise<{ runtime: Runtime; savedDir: string }> {
    const runtime: Runtime = { ...(await this.#base(spec.locale)) };
    if (spec.addons) runtime.addons = spec.addons;
    if (spec.interface === "light") delete runtime.blizzardAddons;
    else if (spec.interface === "whole") runtime.blizzardAddons ??= "all";
    const savedDir = mkdtempSync(join(tmpdir(), "addonsim-sdk-"));
    runtime.savedDir = savedDir;
    return { runtime, savedDir };
  }
}
