// The app as the server holds it: the settings, the config the simulator runs with, the game's art, the Lua host and
// the scene stream, and the setup that changes them. The simulator starts only once the setup is done (the interface
// source and LuaJIT; the AddOns folder is optional); until then the page shows its setup screen. Each start is told
// part by part (src/server/startProgress.ts), for the setup to show.
//
// A project served (bun run start --project <dir>, or a project found from the working folder) adds its own addon
// folders, plugins and Lua path to what the simulator runs with (src/project/load.ts projectRuntime), and its addons
// are the ones switched on; switching them on the Addons tab lasts for the session (the settings' list is the plain
// server's). Without a project the settings say everything, as before.
import { existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import type { Project } from "../project/config.ts";
import { projectRuntime } from "../project/load.ts";
import type {
  ArtInfo,
  DetectedFolder,
  ResetAnswer,
  ResetChoice,
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
import { ensureNativeCore } from "./nativeCore.ts";
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
import { type ListfileLook, StartTracker } from "./startProgress.ts";
import { updateWowless } from "./wowless.ts";

/** Looking for folders reads the registry and every drive: done again only this often, or when asked */
const DETECT_SECONDS = 30;
/** How long a start waits for the game's file list to be built (it is told as it stands meanwhile) */
const LISTFILE_WAIT_MS = 30 * 60 * 1000;
/** The settings that change nothing the running simulator was started with */
const LIVE_KEYS = new Set(["autoReload", "openBrowser", "port", "fps"]);

const isFolder = (path: string): boolean => {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
};

const formatCount = (count: number): string => count.toLocaleString("en-US");
const formatMegabytes = (bytes: number): string => `${(bytes / 1_048_576).toFixed(1)} MB`; // (as the page writes them)

/** A folder's files, counted and summed, everything below it too (none: nothing) */
const measureFolder = (folder: string): { count: number; bytes: number } => {
  const measured = { count: 0, bytes: 0 };
  if (!isFolder(folder)) return measured;
  for (const entry of readdirSync(folder, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile()) continue;
    try {
      measured.bytes += statSync(join(entry.parentPath, entry.name)).size;
      measured.count += 1;
    } catch {
      // (gone meanwhile: a download's temporary file)
    }
  }
  return measured;
};

/**
 * Everything in a folder deleted, the folder itself kept (in the Docker image cache/, saved/ and interface/ are links
 * into the data volume); what could not be deleted (a file another program has open: the CLI's daemon, on Windows)
 * is named in failures
 */
const emptyFolder = (folder: string, failures: string[]): void => {
  if (!isFolder(folder)) return;
  for (const name of readdirSync(folder)) {
    try {
      rmSync(join(folder, name), { recursive: true, force: true, maxRetries: 3 });
    } catch (error) {
      failures.push(`${join(folder, name)}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
};

type Detected = { at: number; flavour: string; addonsRoots: DetectedFolder[]; interfaceRoots: DetectedFolder[] };

export class App {
  settings: StoredSettings;
  readonly config: Config;
  readonly host: LuaHost;
  readonly stream = new SceneStream();
  readonly interfaceDownload = new InterfaceDownloader();
  /** The last start, part by part */
  readonly start = new StartTracker(() => this.#lookAtListfile());
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
    this.host.progress = this.start;
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
    return new Assets(CACHE_DIR, {
      build: this.config.build,
      locale: this.config.locale ?? "enUS",
      product: findFlavour(this.settings.flavour).product,
      atlasVariant: findFlavour(this.settings.flavour).atlasVariant ?? false,
    });
  }

  get art(): Assets {
    return this.host.art as Assets;
  }

  /** The game's file list as it stands: built (the paths it holds), building (how much has come), or failed */
  #lookAtListfile(): ReturnType<ListfileLook> {
    const status = this.art.getStatus();
    if (status.ready) return { state: "done", detail: status.rows ? `${formatCount(status.rows)} paths` : undefined };
    const progress = this.art.getListfileProgress();
    if (progress) {
      return {
        state: "running",
        detail: `${formatMegabytes(progress.downloadedBytes)} fetched, ${formatCount(progress.rows)} paths indexed`,
      };
    }
    if (status.error) return { state: "failed", detail: `${status.error} (tried again in a moment)` };
    return null;
  }

  /** What the cache holds of the game's art and tables (the settings show it; reads the cache's folders) */
  readArtInfo(): ArtInfo {
    const art = this.art;
    const status = art.getStatus();
    const product = typeof this.config.wowlessProduct === "string" ? this.config.wowlessProduct : "";
    return {
      build: art.build,
      locale: art.locale,
      cacheDir: CACHE_DIR,
      listfile: {
        isReady: status.ready,
        rows: status.rows,
        downloadedBytes: status.downloadedBytes,
        builtAt: status.builtAt,
        error: status.error,
      },
      tables: measureFolder(join(CACHE_DIR, "db2", art.db2Folder)),
      files: measureFolder(join(CACHE_DIR, "casc", art.build)),
      pictures: measureFolder(join(CACHE_DIR, "png", art.build)),
      wowless: { product, isFetched: product !== "" && existsSync(join(CACHE_DIR, "wowless", product, "source.json")) },
      blizzardIndexes: measureFolder(join(CACHE_DIR, "tact")),
      totalBytes: measureFolder(CACHE_DIR).bytes,
    };
  }

  get isReady(): boolean {
    return this.problems().length === 0;
  }

  /** What the setup still lacks, in the order the setup screen asks for it */
  problems(): SetupProblem[] {
    const problems: SetupProblem[] = [];
    const { addonsRoot, interfaceRoot, luajitPath } = this.settings;
    // (the AddOns folder is optional: without one the game runs with its own interface, and it is chosen later in the
    // Addons tab)
    if (addonsRoot && !isFolder(addonsRoot)) {
      problems.push({ key: "addonsRoot", message: `There is no folder ${addonsRoot}` });
    }
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
    this.start.reset();
    // (the native core, built first when it is missing or older than its sources: src/server/nativeCore.ts)
    this.start.begin("native");
    const nativeProblem = await ensureNativeCore();
    if (nativeProblem) {
      this.start.fail("native", nativeProblem);
      if (this.host.isRunning) await this.host.stop(true);
      this.host.status = { state: "failed", error: nativeProblem };
      return this.host.status;
    }
    this.start.finish("native");
    // Blizzard's CDN, when it is the source: the build's indexes, fetched and built the first time. When it cannot be
    // had, the start goes on and the files fail to come (said in the step)
    // Blizzard's CDN, where the game's files come from: the build's indexes, fetched and built the first time. When it
    // cannot be had, the start goes on, and the art comes once it can (tried again at the next start)
    this.start.begin("blizzard");
    try {
      await this.art.prepareFiles((stage, done, total) => this.start.count("blizzard", done, total, stage));
      this.start.finish("blizzard", "ready");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.start.fail("blizzard", `${message}: the game's art cannot come until it can be had`);
    }
    this.start.begin("listfile");
    // The game's file list (built on the first start) is waited for, wowless's data fetched meanwhile: until the list
    // is there no texture is found by its path, and a game entered then draws without its art. A list that cannot be
    // had (no network) does not stop the start: the step says so, and the art comes once it is built
    const listfileReady = this.art.waitReady(LISTFILE_WAIT_MS).then((isReady) => {
      if (isReady) this.start.finish("listfile");
    });
    await Promise.all([listfileReady, this.#fetchWowless()]);
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
    this.start.begin("wowless");
    if (!product) {
      this.start.finish("wowless", "none for this game");
      return;
    }
    if (existsSync(join(CACHE_DIR, "wowless", product, "source.json"))) {
      this.start.finish("wowless", "from the cache");
      return;
    }
    const flavour = findFlavour(this.settings.flavour);
    try {
      await updateWowless(CACHE_DIR, product, flavour.wowlessRef);
      console.log(`Fetched wowless's data for ${product}`);
      this.start.finish("wowless", "fetched");
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      process.stderr.write(`wowless: ${message}\n`);
      this.start.fail("wowless", `${message} (the game runs with the simulator's own stand-ins)`);
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
      if (this.config.build !== previousBuild || this.config.locale !== previousLocale) {
        (this.host.art as Assets).close();
        this.host.art = this.#makeArt();
      }
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

  /**
   * Back to a fresh setup: the simulator stopped, what was chosen deleted (the downloaded interface source, the game's
   * art and tables, the saved variables), every setting back to its default; then started again when the setup is
   * still done (the interface source kept)
   */
  async reset(choice: ResetChoice): Promise<ResetAnswer> {
    const downloadState = this.interfaceDownload.status.state;
    if (downloadState === "downloading" || downloadState === "unpacking") {
      return {
        ...this.setupState(false),
        deleted: [],
        failures: ["The interface source is downloading: reset once it is done"],
      };
    }
    // (its saved variables written first, unless they are what goes)
    await this.host.stop(!choice.saved);
    const deleted: string[] = [];
    const failures: string[] = [];
    if (choice.cache) {
      this.art.close();
      emptyFolder(CACHE_DIR, failures);
      deleted.push("the game's art and tables");
    }
    if (choice.interface) {
      emptyFolder(join(ROOT, "interface"), failures);
      this.interfaceDownload.status = { state: "idle", receivedBytes: 0 };
      deleted.push("the downloaded interface source");
    }
    if (choice.saved) {
      emptyFolder(SAVED_DIR, failures);
      deleted.push("the saved variables");
    }
    this.start.clear();
    this.#detected = null;
    this.settings = defaultSettings();
    writeSettings(this.settings);
    applySettings(this.config, this.settings);
    this.#applyProject();
    // (a store of the game's art afresh: the old one's index is closed, or its folder gone)
    this.host.art = this.#makeArt();
    this.host.status = { state: "stopped" };
    if (this.isReady) void this.startSimulator().catch((error: unknown) => this.#noteFailure(error));
    return { ...this.setupState(false), deleted, failures };
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
      platform: process.platform,
      start: this.start.read(),
    };
    if (this.interfaceDownload.status.state !== "idle") state.interfaceDownload = { ...this.interfaceDownload.status };
    return state;
  }
}
