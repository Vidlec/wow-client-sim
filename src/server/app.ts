// The app as the server holds it: the settings, the config the simulator runs with, the game's art, the Lua host and
// the scene stream, and the setup that changes them. The simulator starts only once the setup is done (an AddOns
// folder, the interface source, LuaJIT); until then the page shows its setup screen.
//
// A project served (bun run start --project <dir>, or a project found from the working folder) adds its own addon
// folders, plugins and Lua path to what the simulator runs with (src/project/load.ts projectRuntime), and its addons
// are the ones switched on; switching them on the Addons tab lasts for the session (the settings' list is the plain
// server's). Without a project the settings say everything, as before.
import { existsSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { Project } from "../project/config.ts";
import { projectRuntime } from "../project/load.ts";
import type {
  DetectedFolder,
  SettingsChange,
  SetupAnswer,
  SetupProblem,
  SetupState,
  SimulatorStatus,
} from "../shared/setup.ts";
import { Assets } from "./assets/index.ts";
import { applySettings, type Config, resolveConfig, resolveInterfaceRoot } from "./config.ts";
import { describeFlavour, FLAVOURS, findFlavour } from "./flavours/index.ts";
import { LuaHost } from "./luaHost.ts";
import { describeLuajit, findLuajit, forgetLuajitVersions, readLuajitVersion } from "./luajit.ts";
import { APP_VERSION, CACHE_DIR, downloadedInterfaceRoot, ROOT, SAVED_DIR, SETTINGS_PATH } from "./paths.ts";
import { SceneStream } from "./sceneStream.ts";
import {
  checkChange,
  defaultSettings,
  loadSettings,
  publicSettings,
  readProjectAddons,
  type StoredSettings,
  writeSettings,
} from "./settings.ts";
import { detectAddonsRoots, detectInterfaceRoots } from "./setup/detect.ts";
import { InterfaceDownloader } from "./setup/interfaceDownload.ts";
import { updateWowless } from "./wowless.ts";

/** Looking for folders reads the registry and every drive: done again only this often, or when asked */
const DETECT_SECONDS = 30;
/** The settings that change nothing the running simulator was started with */
const LIVE_KEYS = new Set(["autoReload", "openBrowser", "port", "fps"]);

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

type Detected = { at: number; flavour: string; addonsRoots: DetectedFolder[]; interfaceRoots: DetectedFolder[] };

export class App {
  settings: StoredSettings;
  readonly config: Config;
  readonly host: LuaHost;
  readonly stream = new SceneStream();
  readonly interfaceDownload = new InterfaceDownloader();
  #detected: Detected | null = null;
  /** The project's addons switched on now: the Addons tab's choice for it, kept in the settings by the project's folder
   * (projectAddons), else its config's load */
  #projectAddons: string[] | null = null;

  constructor(readonly project: Project | null = null) {
    this.settings = loadSettings();
    const kept = project ? readProjectAddons(this.settings)[project.root] : undefined;
    if (kept) this.#projectAddons = kept;
    this.config = resolveConfig(this.settings);
    this.#applyProject();
    this.host = new LuaHost(this.config, this.#makeArt());
    this.host.guard = () => this.problems()[0]?.message ?? null;
    // A runtime file of its own, so a plain server beside it never writes over the one it is about to read
    if (project) this.host.runtimeName = `runtime-project-${basename(project.root).replace(/[^\w.-]/g, "_")}.json`;
  }

  /** The project's keys over the settings' (again after each change of settings, which makes the config afresh) */
  #applyProject(): void {
    if (!this.project) return;
    Object.assign(this.config, projectRuntime(this.project));
    this.config.addons = this.#projectAddons ?? this.project.load;
  }

  /** The game's art and tables, for the build and language of the settings */
  #makeArt(): Assets {
    return new Assets(CACHE_DIR, { build: this.config.build, locale: this.config.locale ?? "enUS" });
  }

  get art(): Assets {
    return this.host.art as Assets;
  }

  get isReady(): boolean {
    return this.problems().length === 0;
  }

  /** What the setup still lacks, in the order the setup screen asks for it */
  problems(): SetupProblem[] {
    const problems: SetupProblem[] = [];
    const { addonsRoot, interfaceRoot, luajitPath } = this.settings;
    if (!addonsRoot) problems.push({ key: "addonsRoot", message: "Choose the game's Interface\\AddOns folder" });
    else if (!isFolder(addonsRoot)) problems.push({ key: "addonsRoot", message: `There is no folder ${addonsRoot}` });
    if (interfaceRoot && !isFolder(interfaceRoot)) {
      problems.push({ key: "interfaceRoot", message: `There is no folder ${interfaceRoot}` });
    } else if (!resolveInterfaceRoot(this.settings)) {
      problems.push({ key: "interface", message: "Download the game's interface source, or choose a checkout of it" });
    }
    const luajit = findLuajit(luajitPath);
    if (!luajit || !readLuajitVersion(luajit)) {
      problems.push({ key: "luajit", message: describeLuajit(luajitPath).instructions ?? "LuaJIT is needed" });
    }
    return problems;
  }

  /** Starts (or starts again) the simulator when the setup is done; stops it when it is not */
  async startSimulator(): Promise<SimulatorStatus> {
    const luajit = findLuajit(this.settings.luajitPath);
    if (luajit) this.host.luajit = luajit;
    if (!this.isReady) {
      if (this.host.isRunning) await this.host.stop(true);
      this.host.status = { state: "stopped", error: this.problems()[0]?.message ?? "" };
      return this.host.status;
    }
    this.host.status = { state: "starting" };
    this.art.isReady(); // the listfile's index is built in the background on the first run
    await this.#fetchWowless();
    await this.art.loadAtlases(); // (the /atlas route answers from them)
    const boot = await this.host.start();
    console.log(`Simulator started: ${JSON.stringify(boot).slice(0, 300)}`);
    return this.host.status;
  }

  /**
   * wowless's data about the client (its functions' answers, console variables, the secure namespaces), fetched
   * once as the game's other files are: without it the game's interface meets functions that answer nothing. A
   * failure (no network) is not the start's: the simulator runs with its own stand-ins and says so
   */
  async #fetchWowless(): Promise<void> {
    const product = typeof this.config.wowlessProduct === "string" ? this.config.wowlessProduct : "";
    if (!product || existsSync(join(CACHE_DIR, "wowless", product, "source.json"))) return;
    const flavour = findFlavour(this.settings.flavour);
    try {
      await updateWowless(CACHE_DIR, product, flavour.wowlessRef);
      console.log(`Fetched wowless's data for ${product}`);
    } catch (error) {
      process.stderr.write(`wowless: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }

  /** The settings changed, checked and saved; the simulator started again when the change needs it */
  change(change: SettingsChange): SetupAnswer {
    const { accepted, errors } = checkChange(change);
    const before = this.settings;
    const changedKeys = Object.keys(accepted).filter(
      (key) => JSON.stringify(accepted[key as keyof typeof accepted]) !== JSON.stringify(before[key]),
    );
    const wasReady = this.isReady;
    let saved = false;
    if (changedKeys.length > 0) {
      this.settings = { ...before, ...accepted };
      writeSettings(this.settings);
      saved = true;
      const previousBuild = this.config.build;
      const previousLocale = this.config.locale;
      applySettings(this.config, this.settings);
      this.#applyProject();
      if (this.config.build !== previousBuild || this.config.locale !== previousLocale) this.host.art = this.#makeArt();
      if (changedKeys.includes("flavour")) this.#detected = null;
    }
    const needsStart = changedKeys.some((key) => !LIVE_KEYS.has(key)) || (!wasReady && this.isReady);
    if (needsStart) void this.startSimulator().catch((error: unknown) => this.#noteFailure(error));
    return {
      ...this.setupState(false),
      saved,
      errors,
      restarted: needsStart && this.isReady,
      needsAppRestart: changedKeys.includes("port"),
    };
  }

  /** The addons switched on (the Addons tab), kept in the settings; the caller reloads the simulator */
  keepAddons(addons: string[]): void {
    this.config.addons = addons;
    if (this.project) {
      // (kept between runs, for this project alone: a server restarted brings back what was switched on)
      this.#projectAddons = addons;
      this.settings = {
        ...this.settings,
        projectAddons: { ...readProjectAddons(this.settings), [this.project.root]: addons },
      };
      writeSettings(this.settings);
      return;
    }
    this.settings = { ...this.settings, addons };
    writeSettings(this.settings);
  }

  #noteFailure(error: unknown): void {
    const message = error instanceof Error ? error.message : String(error);
    this.host.status = { state: "failed", error: message };
    process.stderr.write(`simulator: ${message}\n`);
  }

  /** The flavour's interface source fetched into the data folder; the simulator started with it when it uses it */
  downloadInterface(): SetupState {
    const flavour = findFlavour(this.settings.flavour);
    this.interfaceDownload.start(flavour, () => {
      this.#detected = null;
      applySettings(this.config, this.settings); // (interfaceRoot "" now finds the downloaded one)
      this.#applyProject();
      if (!this.settings.interfaceRoot) void this.startSimulator().catch((error: unknown) => this.#noteFailure(error));
    });
    return this.setupState(false);
  }

  #detect(isRefresh: boolean): Detected {
    const flavour = findFlavour(this.settings.flavour);
    const known = this.#detected;
    if (!isRefresh && known && known.flavour === flavour.id && performance.now() - known.at < DETECT_SECONDS * 1000) {
      return known;
    }
    if (isRefresh) forgetLuajitVersions();
    this.#detected = {
      at: performance.now(),
      flavour: flavour.id,
      addonsRoots: detectAddonsRoots(flavour),
      interfaceRoots: detectInterfaceRoots(flavour),
    };
    return this.#detected;
  }

  setupState(isRefresh: boolean): SetupState {
    const detected = this.#detect(isRefresh);
    const problems = this.problems();
    const state: SetupState = {
      isReady: problems.length === 0,
      problems,
      settings: publicSettings(this.settings),
      defaults: defaultSettings(),
      flavours: FLAVOURS.map(describeFlavour),
      detected: {
        addonsRoots: detected.addonsRoots,
        interfaceRoots: detected.interfaceRoots,
        luajit: describeLuajit(this.settings.luajitPath),
      },
      simulator: this.host.status,
      paths: {
        settingsFile: SETTINGS_PATH,
        dataDir: ROOT,
        cacheDir: CACHE_DIR,
        savedDir: SAVED_DIR,
        downloadedInterface: downloadedInterfaceRoot(this.settings.flavour),
      },
      version: APP_VERSION,
    };
    if (this.interfaceDownload.status.state !== "idle") state.interfaceDownload = { ...this.interfaceDownload.status };
    return state;
  }
}
